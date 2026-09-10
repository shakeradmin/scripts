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
import argparse, base64, datetime, hashlib, importlib.util, json, os, re, shlex, subprocess, sys
import time
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
OPS_PUBKEY = ""           # filled from the Strapi cred entity in main()
# Readiness gate (diagnose.sh --mode unit --json). Answers "is this machine shippable" as a
# whole, which no single sweep check does. Deliberately throttled: a full run costs ~18s of SSH
# per machine, so running it every 3-minute sweep would spend the whole sweep on it. Once an
# hour is far more often than the things it watches (a gutted watchdog, a lost c-state clamp, a
# patch that silently reverted) actually drift.
READINESS_INTERVAL = int(os.environ.get("READINESS_INTERVAL", "3600"))
READINESS_TIMEOUT = 90
_readiness_field_missing = False   # set once if Strapi rejects the field, to stop log spam
_health_field_missing = False      # same, for machine.health
_health_field_checked = False      # first health write of a run is read back — see put_health()

# Health (machine.health) — remains read straight off the machine, no telemetry involved.
# int.MaxValue in remains.data is the kiosk's "not tracked at all" sentinel, not a huge
# reading: a machine plumbed to mains water reports 2147483647 for both current and max.
INT_MAX = 2147483647
# The kiosk's own low-cups threshold, hardcoded in RemainsController.lowCupsStatus.
# Cups.MinValue in the file cannot be used — it ships as 200 against a MaxValue of 100.
LOW_CUPS = 10
# A PatchDiag heartbeat is written every 60s from a background thread, so the line keeps
# appearing even when the main thread is wedged; what stops is the frame delta. Give it
# five minutes of slack before treating the log as too old to judge by.
DIAG_FRESH_S = 300
# A kiosk that has just been relaunched has not counted a frame yet, and its first diag
# heartbeat therefore always reads (+0) — there is no previous sample to subtract. We restart
# the kiosk ourselves on every media push, so this window is hit routinely; treating it as a
# fault put an "App error" badge in front of a client whose machine was merely booting
# (bone / 26041826, 2026-08-18). Grace covers the first heartbeat; the re-check covers the
# ~20 s AppManager needs to bring the process back after our own kill.
STARTUP_GRACE_S = 120
APP_RECHECK_S = 20

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


def select_machines(token, patched_only=True):
    """Machines with FleetCatalog patch (id >= MIN_PATCH_ID) — the sweep set.

    patched_only=False drops the patch filter and returns every machine that has a
    tailscale_ip. Only the health pass uses that: remains.data is a stock kiosk file,
    present long before any of our patches, so health has no reason to inherit a gate
    that exists for catalog and media delivery.
    """
    q = ("/api/machines?populate[patch][fields][0]=id"
         "&fields[0]=serial_number&fields[1]=tailscale_ip&fields[2]=ssh_user"
         "&fields[3]=name&fields[4]=fleet_status&pagination[pageSize]=200")
    if patched_only:
        q += "&filters[patch][id][$gte]=%d" % MIN_PATCH_ID
    out = []
    for row in lpm.api(q, token)["data"]:
        a = row["attributes"]
        patch = ((a.get("patch") or {}).get("data") or {})
        if not patched_only and not a.get("tailscale_ip"):
            continue
        out.append({"id": row["id"], "serial": a.get("serial_number"),
                    "name": a.get("name"), "ip": a.get("tailscale_ip"),
                    "user": a.get("ssh_user") or "shaker",
                    "patch_id": patch.get("id"),
                    "prev": a.get("fleet_status") or {}})
    return out


# These three describe the MACHINE, not this sweep, so an unreachable pass must not erase
# them: they are read over SSH, and a machine that does not answer returns None for all of
# them. The door-QR issuer needs device_serial precisely when the machine is offline —
# wiping it on every failed sweep made the field useless for its one job. Carried values are
# stamped with identity_at so a reader can tell a fresh reading from a remembered one.
STICKY_IDENTITY = ("device_serial", "scanner_ok", "scanner_dev")


def carry_identity(status, prev):
    prev = prev or {}
    # A machine that answered gets to say "no scanner device" — None from a reachable
    # machine is a reading, not a gap, and must not be papered over with an old value.
    if status.get("ssh_ok") is True:
        if any(status.get(k) is not None for k in STICKY_IDENTITY):
            status["identity_at"] = status.get("at")
        return status
    for k in STICKY_IDENTITY:
        if prev.get(k) is not None:
            status[k] = prev[k]
    if any(status.get(k) is not None for k in STICKY_IDENTITY):
        status["identity_at"] = prev.get("identity_at") or prev.get("at")
    return status


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
echo "CPU=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
echo "CSTATE=$(grep -o 'intel_idle.max_cstate=[0-9]' /proc/cmdline || echo none)"
echo "CSTATEGRUB=$(grep -c 'intel_idle.max_cstate=1' /etc/default/grub 2>/dev/null || echo 0)"
# Function count, not mere presence: an incomplete 2026-07-29 edit shipped a copy with every
# body stripped, and the unit stays "active" while each call inside it fails.
echo "WDFN=$([ -f /usr/local/bin/shakerview-watchdog.sh ] && grep -c '^[a-z_]*() *{' /usr/local/bin/shakerview-watchdog.sh || echo 0)"
echo "WDACT=$(systemctl is-active shakerview-watchdog 2>&1)"
# Health inputs, carried on this same round trip rather than a second SSH session.
# remains.data goes over base64 so it stays one line: the file is UTF-8 *with BOM* and
# multi-line JSON, either of which would derail the KEY=VALUE parsing below.
echo "NOW=$(date +%s)"
echo "DIAGMT=$(stat -c %Y ~/ShakerView-diag/patch-diag.log 2>/dev/null)"
echo "FRAMES=$(tail -30 ~/ShakerView-diag/patch-diag.log 2>/dev/null | grep -a -o 'frames=[0-9]* (+[0-9]*)' | tail -1)"
echo "REMAINSMT=$(stat -c %Y ~/ShakerView2.0Linux/ShakerView2.0_Data/remains.data 2>/dev/null)"
echo "REMAINSB64=$(base64 -w0 ~/ShakerView2.0Linux/ShakerView2.0_Data/remains.data 2>/dev/null)"
# The serial the KIOSK actually answers to (hard_settings.MachineSerial), which is not
# always machines.serial_number in Strapi — a cloned SSD keeps the golden's serial, and a
# typo in the record is invisible until /catalog 404s. The door-QR key is derived from
# THIS string, so an issuer that used the record's value would hand out a code the lock
# rejects. Reported, never corrected here: FleetPulse does not write machine config.
echo "DEVSERIAL=$(cat ~/ShakerView*/ShakerView*_Data/Config/hard_settings.json 2>/dev/null | grep -a -o '"MachineSerial"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
# Can this machine read a QR at all? The kiosk logs its own verdict on the scanner port once
# per start ("is Scanner is Avaliable True|False"), which is stronger than hard_settings:
# ScannerPortInfo.IsEnabled is true on every machine, the port is not always there. Whole file,
# not a tail: the line is written at startup and a long-running kiosk buries it.
echo "SCANNER=$(grep -a 'is Scanner is Avaliable' ~/.config/unity3d/*/*/Player.log 2>/dev/null | tail -1 | grep -o 'True\|False')"
echo "SCANDEV=$(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null | head -1)"
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
            "device_serial": kv.get("DEVSERIAL", "").strip() or None,
            "scanner_ok": {"True": True, "False": False}.get(kv.get("SCANNER", "").strip()),
            "scanner_dev": kv.get("SCANDEV", "").strip() or None,
            "auto_updates": {"apt_timer": kv.get("APTTIMER", "").strip() or None,
                             "snap_hold": kv.get("SNAPHOLD", "").strip() or None},
            "freeze_protection": {
                "cpu": kv.get("CPU", "").strip() or None,
                "cstate_active": kv.get("CSTATE", "").strip() not in ("", "none"),
                "cstate_in_grub": kv.get("CSTATEGRUB", "").strip() == "1",
                "watchdog_functions": int(kv.get("WDFN", "0").strip() or 0),
                "watchdog_unit": kv.get("WDACT", "").strip() or None},
            # Raw probe output for build_health(); popped before fleet_status is written.
            "_hb": kv}


def _int_or_none(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _tracked(value):
    """A reading the kiosk actually maintains, as opposed to its not-tracked sentinel."""
    return value is not None and value != INT_MAX


def build_health(status):
    """machine.health from the machine's own remains.data — no telemetry in this path.

    The timestamp is the moment of *this sweep*, not the file's mtime, and that is
    deliberate. remains.data is only rewritten when a sale moves a counter, so on a machine
    that sold nothing today the file is hours old while its contents are still exactly
    right. Stamping the mtime would make every quiet machine read as stale in the portal
    and hide perfectly good numbers. What we are asserting here is "we read this off the
    machine just now", which is true; the file's own age travels alongside as remains_at
    for anyone debugging.
    """
    kv = status.get("_hb") or {}
    blob = (kv.get("REMAINSB64") or "").strip()
    if not blob:
        return None
    try:
        # utf-8-sig: the kiosk writes the file with a BOM.
        data = json.loads(base64.b64decode(blob).decode("utf-8-sig"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None

    # frames_ok. Claiming False lights an "App error" badge in the portal, so only assert it
    # on evidence: either no process at all, or a fresh diag heartbeat whose frame counter
    # did not move for a whole minute — the exact signature of a wedged main thread. A live
    # process with no PatchDiag (pre-patch-2 builds) is reported as fine, not as broken.
    # A kiosk still inside STARTUP_GRACE_S is neither: it is starting, and says so in
    # app.state, which the portal renders as its own badge.
    uptime = re.search(r"\[up=(\d+)m\]", status.get("diag_last") or "")
    uptime_s = int(uptime.group(1)) * 60 if uptime else None

    running = status.get("app_pid") is not None
    frames_ok = running
    app_state = "ok" if running else "down"
    machine_now = _int_or_none(kv.get("NOW"))
    diag_mtime = _int_or_none(kv.get("DIAGMT"))
    delta = re.search(r"\(\+(\d+)\)", kv.get("FRAMES") or "")
    if (frames_ok and delta and machine_now and diag_mtime
            and machine_now - diag_mtime <= DIAG_FRESH_S and int(delta.group(1)) == 0):
        if uptime_s is not None and uptime_s <= STARTUP_GRACE_S:
            app_state = "starting"
        else:
            frames_ok = False
            app_state = "stalled"
    elif running and uptime_s is not None and uptime_s <= STARTUP_GRACE_S:
        app_state = "starting"

    containers = []
    for cell in data.get("ContainerRemains") or []:
        if not isinstance(cell, dict):
            continue
        current = cell.get("CurrentValue")
        maximum = cell.get("MaxValue")
        minimum = cell.get("MinValue")
        containers.append({
            "position": cell.get("ContainerNumber"),
            "current": current if _tracked(current) else None,
            "max": maximum if _tracked(maximum) else None,
            # Condition 1 = powder, 2 = concentrate — the same split as the cabinet's
            # cellCategoryId. Product names are not in this file; the portal joins them
            # from our own /planogram by cell number.
            "condition": cell.get("Condition"),
            "runs_out": bool(_tracked(current) and minimum is not None
                             and current <= minimum),
        })

    bottle = data.get("WaterBottle") or {}
    water_current = bottle.get("CurrentValue")
    water_max = bottle.get("MaxValue")
    water_min = bottle.get("MinValue")
    water_tracked = _tracked(water_current)

    cup = data.get("Cups") or {}
    cups_current = cup.get("CurrentValue")
    cups_tracked = _tracked(cups_current)

    health = {
        "at": now_iso(),
        "source": "remains.data",
        "app": {"uptime_s": uptime_s,
                "frames_ok": frames_ok,
                "state": app_state},
        "water": {
            "current": water_current if water_tracked else None,
            "max": water_max if _tracked(water_max) else None,
            "low": bool(water_tracked and water_min is not None
                        and water_current <= water_min),
        },
        "cups": {
            "current": cups_current if cups_tracked else None,
            "low": bool(cups_tracked and cups_current <= LOW_CUPS),
            "tracked": cups_tracked,
        },
        "containers": containers,
    }
    remains_mtime = _int_or_none(kv.get("REMAINSMT"))
    if remains_mtime:
        health["remains_at"] = datetime.datetime.fromtimestamp(
            remains_mtime, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    return health


def put_health(machine_id, token, health):
    """Write machine.health, confirming once per run that the field actually exists.

    Strapi does not reject an attribute that is missing from the content type: the PUT
    returns 200 and the value is silently dropped. Without a read-back the sweep would
    report a healthy write forever while nothing was ever stored — which is exactly what
    happens until the schema change is deployed. So the first write of each run is read
    back, and if it did not stick the rest of the run says so once and skips the writes.

    Returns None if nothing was attempted, otherwise a message worth logging (or "").
    """
    global _health_field_missing, _health_field_checked
    if _health_field_missing:
        return None
    try:
        api_put(f"/api/machines/{machine_id}", token, {"health": health})
    except Exception as e:
        _health_field_missing = True
        return f"WARN: health write failed ({str(e)[:90]}) — skipping it for the rest of this run"
    if _health_field_checked:
        return ""
    _health_field_checked = True
    try:
        stored = lpm.api(f"/api/machines/{machine_id}", token)["data"]["attributes"]
    except Exception:
        return ""   # cannot confirm; assume it worked rather than disable on a read blip
    if "health" not in stored:
        _health_field_missing = True
        return ("WARN: machine.health is not in the deployed Strapi schema — the write was "
                "accepted and discarded; skipping health writes for the rest of this run "
                "(the reading is still in fleet_status)")
    return ""


def health_only_pass(machines, token, dry_run=False):
    """Collect machine.health from machines the main sweep does not visit.

    The sweep is deliberately gated on the FleetCatalog patch and runs one machine after
    another, which is affordable because the set is small. Health has to cover more ground
    than that — the client machines the portal actually renders (Brandon's, Matt's, Artem's)
    are older installs below the gate — and extending the sequential sweep to reach them
    would add a couple of minutes of dead SSH timeouts to a job that runs every three.
    So this pass is separate and concurrent: it is pure read (one heartbeat probe, no
    enforcement, no media, no readiness gate) and SSH waiting is what it spends its time on.
    """
    from concurrent.futures import ThreadPoolExecutor

    def probe(m):
        try:
            status = heartbeat(f"{m['user']}@{m['ip']}")
        except subprocess.TimeoutExpired:
            return m, None
        return (m, build_health(status)) if status.get("ssh_ok") else (m, None)

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(probe, machines))

    done = 0
    for m, health in results:
        if not health:
            continue
        done += 1
        if dry_run:
            print(f"machine {m['id']} ({m['serial']}): health-only "
                  f"cups:{(health.get('cups') or {}).get('current')} "
                  f"water:{(health.get('water') or {}).get('current')}")
            continue
        note = put_health(m["id"], token, health)
        if note:
            print(f"machine {m['id']} ({m['serial']}): {note}")
    return done, len(results)


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


def ops_pubkey(token):
    """The ops SSH public key, from the same Strapi cred entity bootstrap reads."""
    try:
        creds = (lpm.api("/api/cred", token)["data"]["attributes"] or {}).get("creds") or {}
        return (creds.get("OPS_SSH_PUBKEY") or "").strip()
    except Exception:
        return ""


def enforce_tailscale_ssh(target):
    """Make sure Tailscale SSH is on. Returns (ok, detail) or (None, why) when not applicable.

    This is the PRIMARY access guarantee and the ops key is only the fallback. With RunSSH on,
    a connection over the tailnet is authorised by tailnet IDENTITY and sshd's authorized_keys
    is not consulted at all — so there is no key that can go stale, which is the property the
    fleet actually needs.

    Measured 2026-09-10, and the correlation was exact, 13 machines out of 13: every machine
    still reachable after the workstation key was regenerated had RunSSH true (Raven's
    authorized_keys was literally 0 bytes and it let us straight in); every machine refusing
    had RunSSH false and a stale key in authorized_keys. bootstrap.sh defaulted
    ENABLE_TAILSCALE_SSH to false, which is why the fleet was split down that line; the default
    is now true.

    --accept-risk=lose-ssh is required because enabling this reroutes the very session issuing
    the command. The reroute is what we want, and the session survives it in practice — but the
    flag has to be explicit or tailscale refuses.
    """
    if not SUDO_PASS:
        return None, "no SUDO_PASS in env"
    rc, out = ssh_run(target, 'tailscale debug prefs 2>/dev/null | grep -o \'"RunSSH": [a-z]*\'')
    if rc != 0 or not out.strip():
        return None, "could not read tailscale prefs"
    if "true" in out:
        return True, "on"
    rc, _ = ssh_run(target, "sudo -S -p '' tailscale set --ssh --accept-risk=lose-ssh",
                    stdin=SUDO_PASS + "\n")
    if rc != 0:
        return False, f"tailscale set --ssh failed (rc={rc})"
    rc, out = ssh_run(target, 'tailscale debug prefs 2>/dev/null | grep -o \'"RunSSH": [a-z]*\'')
    return ("true" in out), ("enabled" if "true" in out else "still off")


def enforce_ops_key(target, pubkey):
    """Make sure Strapi's OPS_SSH_PUBKEY is in this machine's authorized_keys. (ok, detail).

    Why this belongs in the sweep and not only in bootstrap.sh: bootstrap writes the key ONCE,
    at provisioning, and nothing ever reconciled it afterwards. So the value in Strapi was
    documentation, not enforcement, and rotating the workstation key silently de-synchronised
    the whole fleet — with no way back in over SSH, which is the one channel that just broke.
    That happened on 2026-09-09 and locked the fleet out of key auth.

    Reconciling here closes the loop: rotation becomes "change the value in Strapi" and the
    fleet converges within one sweep, while the OLD key still works. Which is also the rule
    this cannot fix by itself: NEVER remove the old key before the fleet has converged. This
    only ever APPENDS — it must not be the thing that decides a key is no longer wanted.
    """
    if not pubkey:
        return None, "no OPS_SSH_PUBKEY in the Strapi cred entity"
    # fgrep -x on the whole line: a key differing only in its trailing comment is a different
    # authorized_keys entry, and matching loosely would silently accept a stale one.
    cmd = ("install -d -m 700 ~/.ssh && touch ~/.ssh/authorized_keys && "
           "chmod 600 ~/.ssh/authorized_keys && "
           "if grep -qxF %s ~/.ssh/authorized_keys; then echo PRESENT; "
           "else cp -a ~/.ssh/authorized_keys ~/.ssh/authorized_keys.pre-opskey-$(date +%%Y%%m%%d-%%H%%M%%S) && "
           "printf '%%s\\n' %s >> ~/.ssh/authorized_keys && echo ADDED; fi") % (
               shlex.quote(pubkey), shlex.quote(pubkey))
    rc, out = ssh_run(target, cmd)
    if rc != 0:
        return False, f"could not write authorized_keys (rc={rc})"
    out = out.strip()
    return (out in ("PRESENT", "ADDED")), out


# CPUs with the Bay Trail deep-C-state erratum that hard-freezes this fleet (machines 25, 64,
# 260511731, 260511736, 260511737 all traced to it). Kept identical to bootstrap.sh's list.
CSTATE_CPU_PATTERN = ("J1900", "J1800", "J1750", "N2807", "N2840", "N2930")
WATCHDOG_FUNCTIONS = 10   # a complete shakerview-watchdog.sh defines exactly this many

# Writing the c-state clamp. update-grub is only run after checking /boot for a vmlinuz with no
# matching initrd: an interrupted apt leaves one behind, and update-grub would make that orphan
# the default menu entry and panic the machine on its next boot.
ENFORCE_CSTATE_CMD = r"""sudo -S -p '' bash -c '
for k in /boot/vmlinuz-*; do
  [ -e "$k" ] || continue
  v="${k#/boot/vmlinuz-}"
  [ -f "/boot/initrd.img-$v" ] || { echo "ORPHAN_KERNEL=$v"; exit 3; }
done
grep -q "intel_idle.max_cstate=1" /etc/default/grub && { echo "ALREADY_IN_GRUB"; exit 0; }
cp -a /etc/default/grub /etc/default/grub.pre-cstate-$(date +%Y%m%d-%H%M%S)
if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then
  sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 intel_idle.max_cstate=1\"/" /etc/default/grub
else
  printf "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash intel_idle.max_cstate=1\"\n" >> /etc/default/grub
fi
grep -q "intel_idle.max_cstate=1" /etc/default/grub || { echo "EDIT_FAILED"; exit 4; }
update-grub >/dev/null 2>&1 || { echo "UPDATE_GRUB_FAILED"; exit 5; }
grep -q "intel_idle.max_cstate=1" /boot/grub/grub.cfg && echo "WRITTEN_NEEDS_REBOOT" || echo "NOT_IN_GRUBCFG"
exit 0'
"""


def freeze_protection_gaps(status):
    """What this machine is missing. Empty list = nothing to do.

    Neither defence can live in the app -- the freeze is a CPU erratum -- so no patch can
    deliver them, and before bootstrap.sh learned to install them (2026-08-05) every machine
    needed hand-treatment after provisioning. Machines imaged earlier still have neither, and
    they are exactly the ones that keep freezing.
    """
    fp = status.get("freeze_protection") or {}
    gaps = []
    if fp.get("watchdog_functions", 0) < WATCHDOG_FUNCTIONS or fp.get("watchdog_unit") != "active":
        gaps.append("watchdog")
    cpu = fp.get("cpu") or ""
    if any(c in cpu for c in CSTATE_CPU_PATTERN) and not fp.get("cstate_active"):
        gaps.append("cstate")
    return gaps


def enforce_watchdog(target):
    """Install/repair the freeze watchdog. Returns (ok, detail). Restarts nothing but its unit."""
    if not SUDO_PASS:
        return False, "no SUDO_PASS in env"
    src = os.path.join(SCRIPTS, "watchdog")
    for f in ("shakerview-watchdog.sh", "shakerview-watchdog.service"):
        if not os.path.exists(os.path.join(src, f)):
            return False, f"missing {f} in {src}"
    r = subprocess.run(["scp", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                        "-o", "ConnectTimeout=8",
                        os.path.join(src, "shakerview-watchdog.sh"),
                        os.path.join(src, "shakerview-watchdog.service"),
                        f"{target}:/tmp/"], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        return False, f"scp failed: {(r.stderr or '').strip()[:120]}"
    # Verify the delivered copy before installing it: a truncated transfer must never replace a
    # working watchdog with a no-op.
    cmd = (r"""sudo -S -p '' bash -c '
N=$(grep -c "^[a-z_]*() *{" /tmp/shakerview-watchdog.sh)
[ "$N" -ge %d ] || { echo "INCOMPLETE=$N"; exit 3; }
bash -n /tmp/shakerview-watchdog.sh || { echo "SYNTAX_ERROR"; exit 4; }
[ -f /usr/local/bin/shakerview-watchdog.sh ] && cp -a /usr/local/bin/shakerview-watchdog.sh   /usr/local/bin/shakerview-watchdog.sh.bak-$(date +%%Y%%m%%d-%%H%%M%%S)
install -m 755 -o root -g root /tmp/shakerview-watchdog.sh /usr/local/bin/shakerview-watchdog.sh
install -m 644 -o root -g root /tmp/shakerview-watchdog.service   /etc/systemd/system/shakerview-watchdog.service
systemctl daemon-reload
systemctl enable shakerview-watchdog >/dev/null 2>&1
systemctl restart shakerview-watchdog
rm -f /tmp/shakerview-watchdog.sh /tmp/shakerview-watchdog.service
sleep 3
echo "STATE=$(systemctl is-active shakerview-watchdog)"
exit 0'
""" % WATCHDOG_FUNCTIONS)
    rc, out = ssh_run(target, cmd, timeout=60, stdin=SUDO_PASS + "\n")
    out = (out or "").strip()
    if rc != 0 or "STATE=active" not in out:
        return False, out.replace("\n", "/")[:150] or f"rc={rc}"
    return True, "installed and active"


def enforce_cstate(target):
    """Write intel_idle.max_cstate=1 to GRUB. Returns (ok, detail).

    Deliberately does NOT reboot: that is a decision for whoever owns the machine's uptime, and
    the clamp is inert until then. The gap keeps being reported until a reboot picks it up.
    """
    if not SUDO_PASS:
        return False, "no SUDO_PASS in env"
    rc, out = ssh_run(target, ENFORCE_CSTATE_CMD, timeout=90, stdin=SUDO_PASS + "\n")
    out = (out or "").strip()
    if "ORPHAN_KERNEL" in out:
        return False, f"{out} — refused to run update-grub, it would arm an unbootable default entry"
    if "WRITTEN_NEEDS_REBOOT" in out:
        return True, "written to GRUB — inert until the machine reboots"
    if "ALREADY_IN_GRUB" in out:
        return True, "already in GRUB — inert until the machine reboots"
    return False, out.replace("\n", "/")[:150] or f"rc={rc}"


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
        # Our own media restart kills the kiosk and lets AppManager relaunch it, which takes
        # ~20 s. A sweep landing in that gap used to write "no process" straight into
        # machine.health, i.e. a red badge at the client for a machine that was already
        # coming back up. Look once more before saying it.
        time.sleep(APP_RECHECK_S)
        try:
            again = heartbeat(target)
        except subprocess.TimeoutExpired:
            again = {}
        if again.get("ssh_ok") and again.get("app_pid") is not None:
            status.update(again)
            notes.append("app was relaunching, up on re-check")
        else:
            notes.append("WARN: app not running")

    # 1a) health from the machine's own remains.data — the client-facing counterpart of
    # fleet_status, and the reason the portal no longer needs the telemetry cabinet for
    # water/powders/cups. Carried inside status as well as written to its own field, the
    # same way readiness is, so the reading is still visible in fleet_status if the field
    # write is rejected. An unreachable machine returns above without one, leaving the
    # previous value in place rather than overwriting it with a guess.
    health = build_health(status)
    status.pop("_hb", None)
    if health:
        status["health"] = health
    else:
        notes.append("WARN: no readable remains.data — health not updated")

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

    # 1b2) The ops SSH key. Reconciled every sweep for the same reason as the block above —
    # state that drifts and that nothing else re-checks. See enforce_ops_key's docstring for
    # why bootstrap's one-shot copy was not enough.
    if not dry_run:
        okk, detk = enforce_ops_key(target, OPS_PUBKEY)
        if okk is False:
            notes.append(f"ops key: FAILED to reconcile authorized_keys: {detk}")
        elif detk == "ADDED":
            status["ops_key"] = "added"
            notes.append("ops key was MISSING from authorized_keys — added")

    # 1b3) Tailscale SSH — the primary way in, and the one that cannot expire. Reconciled here
    # so a machine that comes back from a long offline spell, or is imaged from an older golden,
    # does not sit on the key-only path where a workstation re-key can strand it.
    if not dry_run:
        okt, dett = enforce_tailscale_ssh(target)
        if okt is False:
            notes.append(f"tailscale ssh: FAILED to enable: {dett}")
        elif dett == "enabled":
            status["tailscale_ssh"] = "enabled"
            notes.append("tailscale SSH was OFF — enabled (machine no longer depends on the ops key)")

    # 1c) Freeze protection. Same shape as the block above and for the same reason: a machine
    # provisioned before bootstrap.sh started installing these (2026-08-05), or imaged from an
    # older golden, arrives with no defence against the Bay Trail c-state erratum and freezes.
    # Five machines needed hand-treatment for this before it was automated. Neither action
    # touches the kiosk binary and neither reboots.
    gaps = freeze_protection_gaps(status)
    if gaps and not dry_run:
        for gap in gaps:
            ok, detail = (enforce_watchdog(target) if gap == "watchdog"
                          else enforce_cstate(target))
            status.setdefault("freeze_protection", {})[f"{gap}_enforced"] = ok
            notes.append(f"freeze protection: {gap} was MISSING — "
                         + (f"fixed ({detail})" if ok else f"FAILED to fix: {detail}"))
    elif gaps:
        notes.append(f"freeze protection MISSING ({', '.join(gaps)}) — dry-run, not touched")

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

    global OPS_PUBKEY
    OPS_PUBKEY = ops_pubkey(token)
    if not OPS_PUBKEY:
        print("WARN: no OPS_SSH_PUBKEY in the Strapi cred entity — authorized_keys not reconciled")

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

    swept = set()
    for m in machines:
        status, notes = sweep_machine(m, token, args.dry_run, args.verbose)
        status = carry_identity(status, m.get("prev"))
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

            # Same separate-write reasoning for health; put_health() also confirms the
            # field survived the write, which a plain PUT does not tell you.
            health = status.get("health")
            if health:
                note = put_health(m["id"], token, health)
                if note:
                    notes.append(note)
        idle = (status.get("sweep") == "ok" and not notes
                and not (status.get("media") or {}).get("changed")
                and not (status.get("media_keys") or {}).get("missing"))
        h = status.get("health") or {}
        low = [str(c["position"]) for c in (h.get("containers") or []) if c.get("runs_out")]
        swept.add(m["id"])
        line = (f"machine {m['id']} ({m['serial']}): sweep={status.get('sweep')} "
                f"app={'up' if status.get('app_pid') else 'DOWN'} "
                f"ws={status.get('telemetry_ws')} cat={status.get('catalog_md5')}"
                + (f" health=cups:{(h.get('cups') or {}).get('current')}"
                   f",water:{(h.get('water') or {}).get('current')}"
                   f",low:{','.join(low) if low else '-'}" if h else "")
                + (f" | {'; '.join(notes)}" if notes else ""))
        print(("IDLE " if idle else "") + line)

    # Health for everything the sweep did not reach — see health_only_pass().
    if not args.machine:
        rest = [m for m in select_machines(token, patched_only=False)
                if m["id"] not in swept]
        if rest:
            got, tried = health_only_pass(rest, token, args.dry_run)
            print(f"{'IDLE ' if not got else ''}health-only pass: "
                  f"{got}/{tried} machines outside the sweep set reported remains")


if __name__ == "__main__":
    main()
