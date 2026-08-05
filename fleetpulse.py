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
  3. cells    — NOT handled here. The machine pulls its planogram from Strapi itself
     (/api/machines/<serial>/planogram, 5 min). Pushing cells from here too would put
     two writers on config.json. Left in the status line as a marker only.
  4. restart  — if media changed: canonical single-PID kill (AppManager relaunches in
     ~15 s). NEVER pattern-kills.
  5. autoupd  — Ubuntu's own update channels must stay shut (apt-daily timers, snap
     auto-refresh). Reported every cycle, and re-shut if a machine comes back with them
     open. Idempotent, touches no binary and restarts nothing.

NOT here either: patch rollout. That is fleetpatch.py — a health sweep that also swaps
binaries is a sweep you stop trusting. Shutting an OS update channel is deliberately on
the other side of that line: it only ever *prevents* changes to the machine.

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
# Machines pull over Tailscale-direct: admin.ishaker.xyz is behind Cloudflare, which 403s
# non-browser user agents. Check against the same URL the machine itself uses.
FLEET_URL = os.environ.get("FLEET_CATALOG_URL", "http://100.101.29.104:1338")
MEDIA = "~/ShakerView2.0Linux/ShakerView2.0_Data/Media"
SUDO_PASS = ""            # filled from the creds .env in main(); never hardcode it here
# Readiness gate (diagnose.sh --mode unit --json). Answers "is this machine shippable" as a
# whole, which no single sweep check does. Deliberately throttled: a full run costs ~18s of SSH
# per machine, so running it every 3-minute sweep would spend the whole sweep on it. Once an
# hour is far more often than the things it watches (a gutted watchdog, a lost c-state clamp, a
# patch that silently reverted) actually drift.
READINESS_INTERVAL = int(os.environ.get("READINESS_INTERVAL", "3600"))
READINESS_TIMEOUT = 90
_readiness_field_missing = False   # set once if Strapi rejects the field, to stop log spam

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


def ssh_run(target, cmd, timeout=SSH_TIMEOUT, stdin=None):
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=8",
                        "-o", "StrictHostKeyChecking=accept-new", target, cmd],
                       input=stdin, capture_output=True, text=True, timeout=timeout + 20)
    return r.returncode, r.stdout


HEARTBEAT_CMD = r"""
PID=$(ps -eo pid,comm | awk '$2 ~ /^ShakerView2.0/ {print $1}')
echo "PID=$PID"
[ -n "$PID" ] && echo "RSS_KB=$(awk '/VmRSS/{print $2}' /proc/$PID/status 2>/dev/null)"
echo "DIAG=$(tail -1 ~/ShakerView-diag/patch-diag.log 2>/dev/null | cut -c1-60)"
echo "CATMD5=$(grep -a -o 'catalog loaded from Strapi for [^ ]* (md5 [0-9a-f]*' ~/ShakerView-diag/patch-diag.log 2>/dev/null | tail -1 | grep -o '[0-9a-f]*$')"
echo "WS=$(tail -c 40000 ~/.config/unity3d/*/*/Player.log 2>/dev/null | grep -a 'isConnected' | tail -1 | grep -o 'True\|False')"
echo "DISK=$(df -h /home | awk 'NR==2{print $4}')"
echo "APTTIMER=$(systemctl is-enabled apt-daily.timer 2>&1)"
echo "SNAPHOLD=$(command -v snap >/dev/null 2>&1 && { snap refresh --time 2>/dev/null | awk '/^hold:/{print $2}' | grep . || echo none; } || echo nosnapd)"
"""

# Closing Ubuntu's update channels. `snap get system refresh.hold` stays "none" after a
# --hold and will lie to an auditor, so the check above reads `snap refresh --time`, which
# is authoritative. All four operations are idempotent — re-running costs nothing.
ENFORCE_AUTOUPD_CMD = r"""sudo -S -p '' bash -c '
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
systemctl mask apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
systemctl mask unattended-upgrades.service >/dev/null 2>&1
command -v snap >/dev/null 2>&1 && snap refresh --hold >/dev/null 2>&1
exit 0'
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
            "disk_free": kv.get("DISK", "").strip() or None,
            "auto_updates": {"apt_timer": kv.get("APTTIMER", "").strip() or None,
                             "snap_hold": kv.get("SNAPHOLD", "").strip() or None}}


def auto_updates_open(status):
    """Which Ubuntu update channels are still live on this machine? (list of names)"""
    au = status.get("auto_updates") or {}
    open_ch = []
    if au.get("apt_timer") not in ("masked", "disabled", None):
        open_ch.append("apt-daily.timer")
    # An UNHELD snap drops the "hold:" line from `snap refresh --time` entirely, so an empty
    # answer must never be read as "fine" — the probe emits the literal "nosnapd" when there
    # is genuinely no snapd, and "none" when snapd is there and unheld. Anything that is not
    # "forever" or "nosnapd" is an open channel.
    if au.get("snap_hold") not in ("forever", "nosnapd", None):
        open_ch.append("snap-refresh")
    return open_ch


def enforce_auto_updates_off(target):
    """Re-shut the OS update channels. Returns (ok, detail).

    Runs when a machine turns up with them open — typically one that was offline when the
    fleet-wide pass ran, or freshly imaged from a golden that predates bootstrap.sh doing it.
    """
    if not SUDO_PASS:
        return False, "no SUDO_PASS in env"
    rc, _ = ssh_run(target, ENFORCE_AUTOUPD_CMD, stdin=SUDO_PASS + "\n")
    if rc != 0:
        return False, f"enforce command failed (rc={rc})"
    rc, out = ssh_run(target, "systemctl is-enabled apt-daily.timer 2>&1; "
                              "snap refresh --time 2>/dev/null | awk '/^hold:/{print $2}'")
    return ("masked" in out and "forever" in out), out.replace("\n", "/").strip("/")


def media_manifest(token, machine_id):
    """(manifest_md5, items) — Strapi upload URLs embed a content hash, so the
    sorted (dest, url) set fully identifies the media payload without downloads."""
    _, lines = lpm.machine_lines(token, str(machine_id))
    items, _skips = lpm.collect(lines)
    blob = json.dumps(sorted(items), sort_keys=True).encode()
    return hashlib.md5(blob).hexdigest(), items


def catalog_token(token):
    """Shared catalog bearer, read from the Strapi cred entity (same place bootstrap gets it)."""
    try:
        creds = (lpm.api("/api/cred", token)["data"]["attributes"] or {}).get("creds") or {}
        return creds.get("CATALOG_TOKEN") or ""
    except Exception:
        return ""


def _served_keys(serial, ctoken):
    """Media keys the machine will actually ASK for, taken from what the server serves.

    Deriving them here rather than from Strapi relations means we check exactly what the
    endpoints produce — the same strings that end up in Container.Product.Taste.mediaKey.
    """
    keys = {"tastes": set(), "cups": set(), "brands": set()}
    for ep in ("catalog", "planogram"):
        req = urllib.request.Request(f"{FLEET_URL}/api/machines/{serial}/{ep}",
                                     headers={"Authorization": f"Bearer {ctoken}", "User-Agent": UA})
        try:
            d = json.load(urllib.request.urlopen(req, timeout=25))
        except Exception:
            continue                      # 404 = nothing configured yet; not a media fault
        if ep == "catalog":
            for b in d.get("body") or []:
                if b.get("mediaKey"):
                    keys["brands"].add(b["mediaKey"])
                for line in b.get("ingredientLines") or []:
                    for i in line.get("ingredients") or []:
                        if i.get("mediaKey"):
                            keys["tastes"].add(i["mediaKey"])
                        if (i.get("view") or {}).get("name"):
                            keys["cups"].add(i["view"]["name"])
        else:
            body = d.get("body") or {}
            for pr in body.get("products") or []:
                if (pr.get("taste") or {}).get("name"):
                    keys["tastes"].add(pr["taste"]["name"])   # consumed as MediaKey
                if (pr.get("sportPit") or {}).get("name"):
                    keys["cups"].add(pr["sportPit"]["name"])
                if (pr.get("brand") or {}).get("mediaKey"):
                    keys["brands"].add(pr["brand"]["mediaKey"])
    return keys


def check_media_keys(target, serial, ctoken):
    """Every key the server serves must resolve to a file on the machine.

    A missing one is invisible until somebody looks at the kiosk and sees a blank tile —
    exactly how the mango-peach case was found. One ls of three directories catches it.
    """
    if not ctoken:
        return {"error": "no CATALOG_TOKEN in cred"}, []
    keys = _served_keys(serial, ctoken)
    if not any(keys.values()):
        return {"checked": 0}, []
    rc, out = ssh_run(target, f"ls {MEDIA}/Tastes; echo ---; ls {MEDIA}/Cups; echo ---; ls {MEDIA}/CompanyLogos")
    if rc != 0:
        return {"error": "could not list Media/"}, []
    parts = out.split("---")
    have_t = set(parts[0].split())
    have_c = set(parts[1].split()) if len(parts) > 1 else set()
    have_l = set(x[:-len("-logo.png")] for x in parts[2].split() if x.endswith("-logo.png")) if len(parts) > 2 else set()

    missing = []
    for k in sorted(keys["tastes"]):
        if k not in have_t:
            missing.append(f"taste:{k}")
    for k in sorted(keys["cups"]):
        if k not in have_c:
            missing.append(f"cup:{k}")
    for k in sorted(keys["brands"]):
        if k not in have_l:
            missing.append(f"brand:{k}")

    st = {"checked": sum(len(v) for v in keys.values()), "missing": missing}
    notes = [f"MEDIA MISSING on machine: {', '.join(missing[:6])}"
             + (f" (+{len(missing)-6} more)" if len(missing) > 6 else "")] if missing else []
    return st, notes


def firmware_write_active(target):
    """Is the machine mid-way through writing its controller firmware? (reason, or (False, ''))

    Mirrors shakerview-watchdog.sh's firmware_write_active(). Two independent signals, because
    they cover different halves of the window:

      * fleet_flash_armed.json — fleetfirmware has armed a flash but the app has not restarted
        into it yet. The marker is renamed to .consumed.json the moment the app reads it, so its
        presence means "about to flash", not "flashed once, long ago".
      * a staged .hex plus ControllerUpdatePage in the Player log — the write itself is running.

    Deliberately fails SAFE: if the probe cannot answer, say busy. A missed media restart costs
    one sweep; a kill -9 through a half-written MCU costs the board.
    """
    probe = (
        "D=~/ShakerView2.0Linux/ShakerView2.0_Data; "
        "test -f $D/Config/fleet_flash_armed.json && { echo ARMED; exit 0; }; "
        "if compgen -G \"$D\"/*.hex >/dev/null 2>&1 && "
        "tail -c 200000 ~/.config/unity3d/*/*/Player.log 2>/dev/null | grep -qa ControllerUpdatePage; "
        "then echo WRITING; else echo IDLE; fi")
    rc, out = ssh_run(target, probe)
    out = (out or "").strip()
    if rc != 0:
        return True, "could not check whether a firmware write is in progress"
    if "ARMED" in out:
        return True, "a controller-firmware flash is armed and about to run"
    if "WRITING" in out:
        return True, "a controller-firmware write is in progress"
    return False, ""


def readiness_check(target, mdir, force=False):
    """Run diagnose.sh --mode unit --json against the machine; throttled to READINESS_INTERVAL.

    Returns (report_dict, ran_now). report_dict is the stored one when throttled, or None if the
    gate has never run and it is not due yet. Never raises: a gate that cannot run must not
    abort a sweep that is otherwise fine.
    """
    cache = os.path.join(mdir, "readiness.json")
    prev = None
    if os.path.exists(cache):
        try:
            prev = json.load(open(cache))
        except Exception:
            prev = None
    if not force and prev:
        try:
            last = datetime.datetime.strptime(prev["at"], "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc)
            if (datetime.datetime.now(datetime.timezone.utc) - last).total_seconds() < READINESS_INTERVAL:
                return prev, False
        except Exception:
            pass

    host = target.split("@", 1)[-1]
    try:
        r = subprocess.run(["bash", os.path.join(SCRIPTS, "diagnose.sh"), host,
                            "--mode=unit", "--json"],
                           capture_output=True, text=True, timeout=READINESS_TIMEOUT)
    except subprocess.TimeoutExpired:
        return prev, False
    # Exit code is the verdict (0 ship / 1 review / 2 do-not-ship), so a non-zero exit is a
    # RESULT, not an error. Only unparseable stdout means the gate failed to run.
    try:
        report = json.loads(r.stdout)
    except Exception:
        return prev, False
    try:
        json.dump(report, open(cache, "w"))
    except Exception:
        pass
    return report, True


def readiness_summary(report):
    """The shape stored on the machine record: verdict plus what is actually wrong."""
    if not report:
        return None
    return {
        "at": report.get("at"),
        "verdict": report.get("verdict"),
        "counts": report.get("counts"),
        "failed": [c["id"] for c in report.get("checks", []) if c.get("level") == "FAIL"],
        "warned": [c["id"] for c in report.get("checks", []) if c.get("level") == "WARN"],
        # Keep the messages for the failures only — enough to act on without storing the
        # whole 37-check report on every machine row.
        "detail": {c["id"]: c["msg"] for c in report.get("checks", [])
                   if c.get("level") == "FAIL"},
    }


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

    # 1b) Ubuntu update channels must stay shut. A machine that was offline during the
    # fleet-wide pass (2026-08-01) reappears with them open; close them on first sight.
    open_ch = auto_updates_open(status)
    if open_ch and not dry_run:
        ok, detail = enforce_auto_updates_off(target)
        status["auto_updates"]["enforced"] = ok
        notes.append(f"auto-updates were OPEN ({', '.join(open_ch)}) — "
                     + (f"closed: {detail}" if ok else f"FAILED to close: {detail}"))
    elif open_ch:
        notes.append(f"auto-updates OPEN ({', '.join(open_ch)}) — dry-run, not touched")

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

    # 2b) media keys actually resolve on the machine
    try:
        st, ns = check_media_keys(target, m["serial"], m.get("ctoken") or "")
        status["media_keys"] = st
        notes += ns
    except Exception as e:
        status["media_keys"] = {"error": str(e)[:200]}

    # 3) cells — NOT OURS ANY MORE (2026-07-28).
    # sync_machine_cells.py used to reconcile config.json Containers by auto-placing
    # database tastes into free cells. The machine now PULLS its planogram from
    # /api/machines/<serial>/planogram every 5 min and writes the same file itself, so
    # running the old push here means two writers racing over config.json — the pushed
    # layout would be silently reverted on the next pull, or worse, interleave with it.
    # Cell assignment is explicit operator data (machine-cell) served by that endpoint;
    # FleetPulse must not second-guess it.
    cells_restarted = False
    status["cells"] = "owned by /planogram (pull)"

    # 4) restart for media-only changes
    if restart_needed and not cells_restarted and not dry_run:
        # Never interrupt a controller-firmware write. Since fleetfirmware can arm one
        # unattended (2026-08-01), a media change landing mid-write would kill -9 the app
        # partway through programming the MCU — the one restart on this machine that can leave
        # hardware in a state no software fix reaches. shakerview-watchdog.sh already holds off
        # for this; the sweeper had no such check.
        #
        # Skipping only defers the restart: the manifest was already written, so the media is on
        # disk and the app picks it up on the restart the flash itself performs, or on the next
        # change. Losing a restart is cheap; losing a controller is not.
        busy, why = firmware_write_active(target)
        if busy:
            notes.append(f"restart HELD OFF — {why}")
        else:
            rcmd = ("PID=$(ps -eo pid,comm | awk '$2 ~ /^ShakerView2.0/ {print $1}'); "
                    "[ -n \"$PID\" ] && kill -9 $PID && echo restarted")
            rc, out = ssh_run(target, rcmd)
            notes.append("app restarted (media)" if "restarted" in out else "WARN: restart kill failed")

    # 5) readiness gate — the whole-machine verdict, throttled to once an hour.
    try:
        report, ran = readiness_check(target, mdir)
        summary = readiness_summary(report)
        if summary:
            status["readiness"] = summary
            if ran:
                notes.append(f"readiness: {summary['verdict']}"
                             + (f" — FAIL: {', '.join(summary['failed'])}" if summary["failed"] else ""))
            if summary["verdict"] == "DO_NOT_SHIP" and summary["failed"]:
                notes.append("NOT SHIPPABLE: " + "; ".join(
                    f"{k}: {v}" for k, v in summary["detail"].items()))
    except Exception as e:
        notes.append(f"readiness gate error: {str(e)[:120]}")

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

    global SUDO_PASS
    SUDO_PASS = env.get("SUDO_PASS") or ""
    if not SUDO_PASS:
        print("WARN: no SUDO_PASS in the creds .env — auto-update channels will be "
              "reported but not re-closed")

    ctoken = catalog_token(token)
    if not ctoken:
        print("WARN: no CATALOG_TOKEN in the Strapi cred entity — media-key check disabled")
    machines = select_machines(token)
    for _m in machines:
        _m["ctoken"] = ctoken
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
            # Separate write: `readiness` is a new field, and until it is deployed Strapi
            # rejects the whole payload containing it. Sending it on its own keeps
            # fleet_status landing on every sweep regardless, and one refusal disables the
            # attempt for the rest of the run instead of logging the same failure per machine.
            global _readiness_field_missing
            summary = status.get("readiness")
            if summary and not _readiness_field_missing:
                try:
                    api_put(f"/api/machines/{m['id']}", token, {"readiness": summary})
                except Exception as e:
                    _readiness_field_missing = True
                    notes.append(f"WARN: readiness field not writable yet ({str(e)[:90]}) — "
                                 "skipping it for the rest of this run; the verdict is still "
                                 "in the log and in fleetpulse state")
        idle = (status.get("sweep") == "ok" and not notes
                and not (status.get("media") or {}).get("changed")
                and not (status.get("media_keys") or {}).get("missing"))
        line = (f"machine {m['id']} ({m['serial']}): sweep={status.get('sweep')} "
                f"app={'up' if status.get('app_pid') else 'DOWN'} "
                f"ws={status.get('telemetry_ws')} cat={status.get('catalog_md5')}"
                + (f" | {'; '.join(notes)}" if notes else ""))
        print(("IDLE " if idle else "") + line)


if __name__ == "__main__":
    main()
