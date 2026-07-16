#!/usr/bin/env python3
"""
FleetPulse — background fleet sweep for FleetCatalog-patched machines.

The delivery/monitoring layer of the "telemetry exit" project: everything a machine
needs from Strapi (catalog is pulled by the on-machine FleetCatalog patch itself)
gets PUSHED and VERIFIED from the Strapi box by this one orchestrator.

MACHINE SELECTION (hard rule): only Strapi machines whose `patch` relation points to
patch id >= MIN_PATCH_ID (4 = strapi-catalog-source-v2) are swept. Machines without
that patch are NEVER touched — no ssh, nothing.

Per machine, per cycle:
  1. heartbeat — one ssh probe: app pid + RSS, patch-diag freshness, telemetry WS
     state, last FleetCatalog md5, disk free. Written to Strapi machine.fleet_status
     (json) so the portal/admin can show live fleet health.
  2. media    — manifest of the machine's product media (Strapi upload URLs embed a
     content hash, so URL set == content set). Manifest changed → stage + push via
     load_product_media.py (tar over ssh), remember restart is needed.
     First-ever run pushes but does NOT restart (baseline).
  3. cells    — sync_machine_cells.py (writes reconciled config + restarts by itself
     when DB/assignment changed).
  4. restart  — if media changed but cells didn't restart: canonical single-PID kill
     (AppManager relaunches in ~15 s). NEVER pattern-kills.

State: ~/fleetpulse/state/<machine-id>/ (media manifest, staging).
Log:   one summary line per swept machine on stdout; cron wrapper filters idle lines.

USAGE
  STRAPI_BASE_URL=http://localhost:1338 python3 fleetpulse.py            # sweep all
  python3 fleetpulse.py --machine 62 --verbose                           # one machine
  python3 fleetpulse.py --dry-run                                        # no writes
"""
import argparse, datetime, hashlib, importlib.util, json, os, subprocess, sys
import urllib.request

HOME = os.path.expanduser("~")
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
STATE_ROOT = os.path.join(HOME, "fleetpulse", "state")
MIN_PATCH_ID = 4
SSH_TIMEOUT = 10
STRAPI = os.environ.get("STRAPI_BASE_URL", "http://localhost:1338")
UA = "fleetpulse/1.0"

# Reuse load_product_media's Strapi helpers + media collection (same key derivation
# as the catalog controller). Import by path: the script has a __main__ guard.
_spec = importlib.util.spec_from_file_location(
    "lpm", os.path.join(SCRIPTS, "load_product_media.py"))
lpm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lpm)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def api_put(path, token, data):
    body = json.dumps({"data": data}).encode()
    req = urllib.request.Request(f"{STRAPI}{path}", data=body, method="PUT",
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {token}",
                                          "User-Agent": UA})
    return json.load(urllib.request.urlopen(req, timeout=30))


def select_machines(token):
    """Machines with FleetCatalog patch (id >= MIN_PATCH_ID) — the sweep set."""
    q = ("/api/machines?filters[patch][id][$gte]=%d&populate[patch][fields][0]=id"
         "&fields[0]=serial_number&fields[1]=tailscale_ip&fields[2]=ssh_user"
         "&fields[3]=name&pagination[pageSize]=200" % MIN_PATCH_ID)
    out = []
    for row in lpm.api(q, token)["data"]:
        a = row["attributes"]
        patch = ((a.get("patch") or {}).get("data") or {})
        out.append({"id": row["id"], "serial": a.get("serial_number"),
                    "name": a.get("name"), "ip": a.get("tailscale_ip"),
                    "user": a.get("ssh_user") or "shaker",
                    "patch_id": patch.get("id")})
    return out


def ssh_run(target, cmd, timeout=SSH_TIMEOUT):
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=8",
                        "-o", "StrictHostKeyChecking=accept-new", target, cmd],
                       capture_output=True, text=True, timeout=timeout + 20)
    return r.returncode, r.stdout


HEARTBEAT_CMD = r"""
PID=$(ps -eo pid,comm | awk '$2 ~ /^ShakerView2.0/ {print $1}')
echo "PID=$PID"
[ -n "$PID" ] && echo "RSS_KB=$(awk '/VmRSS/{print $2}' /proc/$PID/status 2>/dev/null)"
echo "DIAG=$(tail -1 ~/ShakerView-diag/patch-diag.log 2>/dev/null | cut -c1-60)"
echo "CATMD5=$(grep -a -o 'catalog loaded from Strapi for [^ ]* (md5 [0-9a-f]*' ~/ShakerView-diag/patch-diag.log 2>/dev/null | tail -1 | grep -o '[0-9a-f]*$')"
echo "WS=$(tail -c 40000 ~/.config/unity3d/*/*/Player.log 2>/dev/null | grep -a 'isConnected' | tail -1 | grep -o 'True\|False')"
echo "DISK=$(df -h /home | awk 'NR==2{print $4}')"
"""


def heartbeat(target):
    rc, out = ssh_run(target, HEARTBEAT_CMD)
    if rc != 0:
        return {"ssh_ok": False}
    kv = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    pid = kv.get("PID", "").strip()
    rss = kv.get("RSS_KB", "").strip()
    return {"ssh_ok": True,
            "app_pid": int(pid) if pid.isdigit() else None,
            "app_rss_mb": round(int(rss) / 1024) if rss.isdigit() else None,
            "telemetry_ws": {"True": True, "False": False}.get(kv.get("WS", "").strip()),
            "catalog_md5": kv.get("CATMD5", "").strip() or None,
            "diag_last": kv.get("DIAG", "").strip() or None,
            "disk_free": kv.get("DISK", "").strip() or None}


def media_manifest(token, machine_id):
    """(manifest_md5, items) — Strapi upload URLs embed a content hash, so the
    sorted (dest, url) set fully identifies the media payload without downloads."""
    _, lines = lpm.machine_lines(token, str(machine_id))
    items, _skips = lpm.collect(lines)
    blob = json.dumps(sorted(items), sort_keys=True).encode()
    return hashlib.md5(blob).hexdigest(), items


def sweep_machine(m, token, dry_run=False, verbose=False):
    mdir = os.path.join(STATE_ROOT, str(m["id"]))
    os.makedirs(mdir, exist_ok=True)
    target = f"{m['user']}@{m['ip']}" if m["ip"] else None
    status = {"at": now_iso(), "sweep": "ok", "patch_id": m["patch_id"]}
    notes = []

    # 1) heartbeat
    if not target:
        status.update(ssh_ok=False, sweep="no tailscale_ip")
        return status, ["no tailscale_ip in machine record"]
    try:
        status.update(heartbeat(target))
    except subprocess.TimeoutExpired:
        status.update(ssh_ok=False)
    if not status.get("ssh_ok"):
        status["sweep"] = "unreachable"
        return status, ["unreachable"]
    if status.get("app_pid") is None:
        notes.append("WARN: app not running")

    restart_needed = False

    # 2) media
    manifest_file = os.path.join(mdir, "media_manifest.md5")
    try:
        digest, items = media_manifest(token, m["id"])
        prev = open(manifest_file).read().strip() if os.path.exists(manifest_file) else None
        status["media"] = {"files": len(items), "changed": digest != prev}
        if digest != prev and not dry_run:
            r = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS, "load_product_media.py"),
                 "--machine", str(m["id"]),
                 "--stage", os.path.join(mdir, "media-stage"), "--push", "auto"],
                capture_output=True, text=True, timeout=600)
            if r.returncode == 0:
                open(manifest_file, "w").write(digest)
                restart_needed = prev is not None  # first run = baseline, no restart
                notes.append(f"media pushed ({len(items)} files)"
                             + ("" if prev else " [baseline, no restart]"))
            else:
                status["media"]["error"] = (r.stdout + r.stderr)[-300:]
                notes.append("ERROR: media push failed")
    except Exception as e:
        status["media"] = {"error": str(e)[:200]}
        notes.append(f"ERROR: media manifest: {e}")

    # 3) cells (sync restarts by itself when config changes)
    cells_restarted = False
    if not dry_run:
        r = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS, "sync_machine_cells.py"),
             "--machine", str(m["id"])],
            capture_output=True, text=True, timeout=300,
            env={**os.environ, "STRAPI_BASE_URL": STRAPI})
        cells_out = (r.stdout + r.stderr).strip()
        if "no change" in cells_out:
            status["cells"] = "no change"
        else:
            status["cells"] = cells_out[-300:]
            cells_restarted = r.returncode == 0
            notes.append("cells: " + cells_out.splitlines()[-1][:120] if cells_out else "cells synced")
        if r.returncode != 0:
            notes.append("ERROR: cell sync failed")
    else:
        status["cells"] = "dry-run"

    # 4) restart for media-only changes
    if restart_needed and not cells_restarted and not dry_run:
        rcmd = ("PID=$(ps -eo pid,comm | awk '$2 ~ /^ShakerView2.0/ {print $1}'); "
                "[ -n \"$PID\" ] && kill -9 $PID && echo restarted")
        rc, out = ssh_run(target, rcmd)
        notes.append("app restarted (media)" if "restarted" in out else "WARN: restart kill failed")

    if verbose:
        print(json.dumps(status, indent=1))
    return status, notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", help="sweep only this Strapi machine id")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    env = lpm.load_env()
    ident = env.get("STRAPI_MACHINE_USER_USERNAME") or env.get("STRAPI_MACHINE_USER_LOGIN")
    token = lpm.strapi_login(ident, env["STRAPI_MACHINE_USER_PASSWORD"])

    machines = select_machines(token)
    if args.machine:
        machines = [m for m in machines if str(m["id"]) == args.machine]
        if not machines:
            sys.exit(f"machine {args.machine} is not in the sweep set "
                     f"(needs patch id >= {MIN_PATCH_ID} in Strapi)")

    for m in machines:
        status, notes = sweep_machine(m, token, args.dry_run, args.verbose)
        if not args.dry_run:
            try:
                api_put(f"/api/machines/{m['id']}", token, {"fleet_status": status})
            except Exception as e:
                notes.append(f"WARN: fleet_status write failed: {e}")
        idle = (status.get("sweep") == "ok" and not notes
                and status.get("cells") == "no change"
                and not (status.get("media") or {}).get("changed"))
        line = (f"machine {m['id']} ({m['serial']}): sweep={status.get('sweep')} "
                f"app={'up' if status.get('app_pid') else 'DOWN'} "
                f"ws={status.get('telemetry_ws')} cat={status.get('catalog_md5')}"
                + (f" | {'; '.join(notes)}" if notes else ""))
        print(("IDLE " if idle else "") + line)


if __name__ == "__main__":
    main()
