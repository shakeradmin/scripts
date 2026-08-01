#!/usr/bin/env python3
"""
FleetFirmware — controller (MCU) firmware sweep. Third sibling of fleetpulse/fleetpatch.

Scope: the AVR controller board on /dev/ttyS1 (pumps, mixers, dosing, MDB). NOT ShakerView
(that is fleetpatch) and NOT the Touch 2 MDRV board unless a firmware record explicitly says
so via machine_types.

WHAT THIS DOES, AND THE ONE THING IT DELIBERATELY DOES NOT
---------------------------------------------------------
  read   every reachable machine reports its controller version to ShakerView on connect and
         the app logs it: `ControllerVersionAnswer D50649 YY MM DD BB 00` = Mikhail's
         `YYMMDD-BB`. Recorded to machine.controller_fw / .controller_fw_status.
  stage  copy the target .hex into the root of ShakerView2.0_Data/ (Settings.ControllerHexFilePath).
         INERT: the controller is written only when the ControllerUpdatePage scene runs.
         Staging days ahead of a visit is the intended pattern and carries no risk.
  verify ShakerView DELETES the hex from _Data on a successful write
         (ControllerFirmwareTestLoader.ExitTheProgrammingMode). So "file gone + version bumped"
         is proof it flashed, and "file gone + version unchanged" is a failed write to re-stage.
  report what still needs a human, and for how long it has been waiting.

  flash  DONE HERE, but only for machines that opted in AND can survive a failed write.

         The TRIGGER is stock and needs no patch: UpdaterHandler.InitAutoUpdate() runs
         `if (UpdaterSettings.NeedToUpdateFirmware) AutoUpdater.StartUpdatingFirmware()` at
         startup, and patch 2 disabled only the scheduled cloud check, not that branch. So
         arming a flash is: stage the .hex, set NeedToUpdateFirmware:true in
         Config/updater_settings.json, restart the app.

         What used to stop this sweeper is that FAILURE was not survivable. Verified on bench
         004 (no controller attached) 2026-07-29: arming a flash wedged the app with the Unity
         main thread STALLED — frames frozen, fd count climbing 375 -> 589 — until it was
         killed. Not merely "parked on a screen": a hung kiosk that stops selling. Patch 13 v1
         was meant to rescue that and could not, because it watched from a main-thread
         coroutine — the one thread that had stopped running.

         The rescue now lives on a background timer (FirmwareFlashWatchdog) and kills the
         process outright, so AppManager relaunches a working kiosk. This sweeper therefore
         refuses to arm unless `FirmwareFlashWatchdog` is present in the machine's own
         CommonCode.dll — the binary's answer, not Strapi's patch relation, which drifts.

         The first real unattended flash (machine 94, 2026-08-01) taught two more things. The
         write took 505s of a 600s absolute deadline, so v3 judges PROGRESS — the flasher's own
         per-line log counter — instead of elapsed time, and holds off as long as it climbs.
         And the SUCCESS path wedges too: the app deletes the hex, then queues its restart onto
         the stalled main thread and never runs it, so the watchdog has to finish the job.

         Second reason, which stands regardless: flashing invalidates the water calibration
         for anything older than 260211-01 (see Strapi knowledge 26 sec.7). That is why
         machine.isFirmwareAutoflash exists, defaults to false, and is deliberately SEPARATE
         from isAutoupdate — an unattended flash must never ride in on the app-update opt-in.

GATE — a machine is staged only when all hold (mirrors fleetpatch):
  1. controller-firmware.isStable == true      operator says the image is ready; default false
  2. firmware.machine_types contains the machine's type    an S image cannot land on a Touch 2
  3. the machine is reachable and has ShakerView
  4. target version > version read off the controller      never downgrades, never re-stages equal

  5. the image fits the machine's own IsTouch2   machine_types is a hand-maintained tag; this
                                                 checks what the app would actually open

FLASH GATE — staging only stages. Arming the write additionally needs ALL of:
  6. machine.isFirmwareAutoflash == true       separate opt-in; default false
  7. FirmwareFlashWatchdog in its CommonCode.dll   it must be able to recover from a failed write
  8. no flash already pending or unconsumed     never arm twice over the same attempt
  9. kiosk idle (CurrentScreen = StartScreen)   never restart a machine somebody is standing at
 10. fewer than MAX_FLASH_ATTEMPTS failures     two failures mean it needs a human, not a third try
 11. MAX_ARMS_PER_SWEEP not yet spent          arm one machine per run, never the whole fleet

Resting state is "no stable firmware — nothing to do": with every record at isStable=false this
prints nothing and touches nothing. Flipping one to isStable=true is the release action.

Usage:
    fleetfirmware.py                 # read + record + stage where the gate allows
    fleetfirmware.py --dry-run       # read + record + say what it WOULD stage
    fleetfirmware.py --report        # read only, print the table, stage nothing
    fleetfirmware.py --machine 61    # one machine
"""

import argparse, hashlib, importlib.util, json, os, re, subprocess, sys, time
import urllib.request

HOME = os.path.expanduser("~")
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
LOG_ROOT = os.path.join(HOME, "fleetfirmware")
CACHE = os.path.join(LOG_ROOT, "images")
STRAPI = os.environ.get("STRAPI_BASE_URL", "http://localhost:1338")
SSH_TIMEOUT = 20
UA = "fleetfirmware/1.0"
STRAPI_HAS_SCHEMA = True   # cleared if api::controller-firmware is not deployed here

SV_DATA = "/home/shaker/ShakerView2.0Linux/ShakerView2.0_Data"
VER_RE = re.compile(r"^([0-9]{6})-([0-9]{2})$")

_spec = importlib.util.spec_from_file_location(
    "lpm", os.path.join(SCRIPTS, "load_product_media.py"))
lpm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lpm)


def log(msg):
    line = f"[{time.strftime('%F %T')}] {msg}"
    print(line, flush=True)
    os.makedirs(LOG_ROOT, exist_ok=True)
    with open(os.path.join(LOG_ROOT, "fleetfirmware.log"), "a") as f:
        f.write(line + "\n")


def ssh(target, cmd, timeout=SSH_TIMEOUT):
    """Never raises — one wedged machine must not abort the sweep. stdout only on success:
    merging stderr poisons parsed values (ssh's 'Permanently added ...' warning on a
    first-ever connection is the classic one, see fleetpatch.ssh)."""
    try:
        r = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
             "-o", f"ConnectTimeout={min(timeout, 15)}", target, cmd],
            capture_output=True, text=True, timeout=timeout + 15)
        if r.returncode == 0:
            return 0, r.stdout.strip()
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "ssh timed out"
    except Exception as e:
        return 125, f"ssh failed: {e}"


def api(path, token):
    req = urllib.request.Request(f"{STRAPI}{path}",
                                 headers={"Authorization": f"Bearer {token}", "User-Agent": UA})
    return json.load(urllib.request.urlopen(req, timeout=30))


def api_put(path, token, data):
    body = json.dumps({"data": data}).encode()
    req = urllib.request.Request(f"{STRAPI}{path}", data=body, method="PUT",
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {token}", "User-Agent": UA})
    return json.load(urllib.request.urlopen(req, timeout=30))


def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------- version handling

def decode_version(raw):
    """'D506491A030A0300' -> '260310-03'. None if it is not a version packet."""
    if not raw:
        return None
    try:
        b = bytes.fromhex(raw.strip())
    except ValueError:
        return None
    if len(b) < 7 or b[:3] != b"\xd5\x06\x49":
        return None
    return "%02d%02d%02d-%02d" % (b[3], b[4], b[5], b[6])


def vkey(v):
    """Sortable key. Returns None for anything unparseable, and callers must treat None as
    'unknown' rather than 'old' — guessing here would mean flashing over a newer image."""
    m = VER_RE.match(v or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


# ---------------------------------------------------------------- strapi reads

def stable_firmwares(token):
    q = ("/api/controller-firmwares?filters[isStable][$eq]=true"
         "&populate[machine_types]=*&populate[hex]=*&pagination[pageSize]=100")
    try:
        return [dict(id=e["id"], **e["attributes"]) for e in api(q, token)["data"]]
    except urllib.error.HTTPError as e:
        # 403 as well as 404: a freshly promoted content-type exists but starts with NO
        # permissions for the machine-client role, so it answers 403 until someone grants
        # find/findOne. Both mean the same thing here — "this Strapi cannot serve firmware
        # records yet" — and neither is worth a traceback every hour from cron.
        if e.code in (403, 404):
            # content-type not promoted to this Strapi yet. Reading versions still works and is
            # useful on its own, so degrade instead of crashing the hourly cron. machine's
            # controller_fw fields ship in the same deploy, so suppress the writes too rather
            # than logging one rejection per machine every hour until someone deploys.
            global STRAPI_HAS_SCHEMA
            STRAPI_HAS_SCHEMA = False
            log("api::controller-firmware unavailable (HTTP %d: not deployed, or no find permission for this role) — read-only sweep" % e.code)
            return []
        raise


def machines(token, only=None):
    q = ("/api/machines?pagination[pageSize]=200&populate[machine_type]=*"
         "&populate[controller_firmware]=*")
    out = []
    for e in api(q, token)["data"]:
        m = dict(id=e["id"], **e["attributes"])
        if not m.get("tailscale_ip"):
            continue
        if only and m["id"] != only:
            continue
        out.append(m)
    return out


def pick_firmware(firmwares, machine):
    """The stable image whose machine_types covers this machine, newest first. Records with no
    machine_types are SKIPPED, not treated as universal — an untagged S image reaching a Touch 2
    is exactly the mistake the tag exists to prevent."""
    mt = (machine.get("machine_type") or {}).get("data")
    mt_id = mt["id"] if mt else None
    hits = []
    for f in firmwares:
        types = (f.get("machine_types") or {}).get("data") or []
        if not types or mt_id is None:
            continue
        if mt_id in [t["id"] for t in types] and vkey(f.get("version")):
            hits.append(f)
    return max(hits, key=lambda f: vkey(f["version"])) if hits else None


def image_path(fw, token):
    """Download the .hex attached to the firmware record once, cache it, verify hex_md5."""
    media = (fw.get("hex") or {}).get("data")
    if not media:
        return None, "record has no hex attached"
    url = media["attributes"]["url"]
    if url.startswith("/"):
        url = STRAPI + url
    os.makedirs(CACHE, exist_ok=True)
    dst = os.path.join(CACHE, f"{fw['version']}_{fw.get('hex_filename') or 'firmware.hex'}")
    if not os.path.exists(dst):
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=120) as r, open(dst, "wb") as f:
            f.write(r.read())
    got = md5_of(dst)
    want = (fw.get("hex_md5") or "").strip().lower()
    if want and got != want:
        os.remove(dst)
        return None, f"hex_md5 mismatch: record says {want}, file is {got}"
    return dst, got


# ---------------------------------------------------------------- machine probe

PROBE = r"""
D=%(d)s
C=$D/Config/hard_settings.json
test -d "$D" || { echo "NO_SHAKERVIEW"; exit 0; }
S=$(grep -o '"MachineSerial": *"[^"]*"' $C 2>/dev/null | head -1 | cut -d'"' -f4)
M=$(grep -o '"IsSModel": *[a-z]*' $C 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')
V=$(grep -hoE 'ControllerVersionAnswer[[:space:]]+[0-9A-F]{12,}' $D/Logs/*.log 2>/dev/null | tail -1 | awk '{print $2}')
H=$(md5sum $D/*.hex 2>/dev/null | head -1 | awk '{print $1}')
N=$(ls $D/*.hex 2>/dev/null | head -1 | xargs -r basename)
T=$(grep -o '"IsTouch2": *[a-z]*' $C 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')
W=$(grep -ac FirmwareFlashWatchdog $D/Managed/CommonCode.dll 2>/dev/null || echo 0)
A=$(test -f $D/Config/fleet_flash_armed.json && echo armed || (test -f $D/Config/fleet_flash_armed.consumed.json && echo consumed || echo none))
F=$(grep -o '"NeedToUpdateFirmware": *[a-z]*' $D/Config/updater_settings.json 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')
P=$(grep -ao 'CurrentScreen = [A-Za-z]*' $HOME/.config/unity3d/ShakerTechnology/ShakerView2.0/Player.log 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
R=$(pgrep -f '^/home/shaker/ShakerView2.0Linux/ShakerView2.0.x86_64$' | head -1)
echo "$S|$M|$V|$H|$N|$T|$W|$A|$F|$P|$R"
""" % {"d": SV_DATA}


def probe(machine):
    target = f"{machine.get('ssh_user') or 'shaker'}@{machine['tailscale_ip']}"
    rc, out = ssh(target, PROBE)
    if rc != 0 or not out:
        return None
    if out.strip() == "NO_SHAKERVIEW":
        return {"no_sv": True}
    f = (out.split("|") + [""] * 11)[:11]
    serial, is_s, raw, staged_md5, staged_name, is_touch2, watchdog, armed, need_flag, screen, pid = f
    return {"no_sv": False, "serial": serial, "is_s": is_s == "true",
            "raw": raw, "version": decode_version(raw),
            "staged_md5": staged_md5, "staged_name": staged_name,
            "is_touch2": is_touch2 == "true",
            # The binary's own answer to "can this machine survive a failed flash", which is
            # what actually matters -- Strapi's patch relation drifts (hand-patched machines,
            # machines bootstrapped after the fact) and would let an unattended flash onto a
            # build with no rescue.
            "has_watchdog": watchdog.strip().isdigit() and int(watchdog) > 0,
            "armed": armed, "need_flag": need_flag == "true",
            "screen": screen, "pid": pid.strip()}


def stage(machine, src, want_md5, filename):
    """Copy the image into _Data/, backing up anything already there. Flashes nothing."""
    target = f"{machine.get('ssh_user') or 'shaker'}@{machine['tailscale_ip']}"
    dst = f"{SV_DATA}/{filename}"
    ssh(target, f"test -f {dst} && cp -n {dst} {dst}.bak-$(date +%Y%m%d-%H%M%S) || true")
    r = subprocess.run(
        ["scp", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
         "-o", "ConnectTimeout=15", src, f"{target}:{dst}"],
        capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        return False, (r.stdout + r.stderr).strip()[:200]
    rc, got = ssh(target, f"md5sum {dst} | awk '{{print $1}}'")
    if rc != 0 or got != want_md5:
        return False, f"md5 after copy is {got!r}, wanted {want_md5}"
    return True, "staged"


# ---------------------------------------------------------------- unattended flash

# On-machine watchdog budget, handed over in the marker file.
#
# These replace a single absolute deadline (600s), which the first real flash showed to be
# dangerous: writing 2838 lines to machine 94 took 505s of that 600s budget, so a slower machine
# or a bigger image would have had a HEALTHY write killed partway through programming the MCU.
#
# The watchdog now judges progress instead: ControllerFirmwareTestLoader logs one line per line
# written, so while that counter climbs it holds off however long it takes. NO_PROGRESS_SECONDS
# is total silence, matching FW_HOLD_GRACE in shakerview-watchdog.sh; MAX_TOTAL_SECONDS is only a
# backstop for a fault that somehow keeps the counter crawling forever.
FLASH_NO_PROGRESS_SECONDS = 300
FLASH_MAX_TOTAL_SECONDS = 3600

# Two attempts, then it needs a human. A flash that fails twice is not going to start working on
# the third unattended try, and each attempt costs the kiosk a restart.
MAX_FLASH_ATTEMPTS = 2

# Canary rule, borrowed from fleetpatch's --max: however many machines qualify, arm ONE per
# sweep. Staging is inert and can safely fan out; arming writes an MCU and restarts a kiosk, and
# the hourly cron runs unattended with no human watching the first one land.
MAX_ARMS_PER_SWEEP = 1

ARM_SCRIPT = r"""
set -e
D=%(d)s
CFG=$D/Config
python3 - <<'PY'
import json, time
p = "%(d)s/Config/updater_settings.json"
raw = open(p, "rb").read()
bom = raw[:3] == b"\xef\xbb\xbf"
d = json.loads(raw.decode("utf-8-sig"))
d["NeedToUpdateFirmware"] = True
open(p + ".pre-autoflash", "wb").write(raw)
open(p, "wb").write((b"\xef\xbb\xbf" if bom else b"") + json.dumps(d, indent=2, ensure_ascii=False).encode())
m = {"armed_at": int(time.time()),
     "no_progress_seconds": %(no_progress)d, "max_total_seconds": %(max_total)d,
     "hex": "%(hexname)s", "target_version": "%(version)s", "armed_by": "fleetfirmware"}
open("%(d)s/Config/fleet_flash_armed.json", "w").write(json.dumps(m, indent=2))
PY
PID=$(pgrep -f '^/home/shaker/ShakerView2.0Linux/ShakerView2.0.x86_64$' | head -1)
[ -n "$PID" ] && kill $PID
echo "armed pid=$PID"
"""


def arm_flash(machine, fw, filename, dry_run):
    """Set the stock trigger and restart the app, so the flash runs with nobody at the machine.

    No DLL change is involved in the TRIGGER: UpdaterHandler.InitAutoUpdate() runs
    `if (UpdaterSettings.NeedToUpdateFirmware) AutoUpdater.StartUpdatingFirmware()` at startup and
    patch 2 disabled only the scheduled cloud check, not this branch.

    What IS required is the rescue, which is why this refuses to run without the on-machine
    watchdog. Every failure path in ControllerFirmwareTestLoader hides the exit button and never
    leaves the update screen, and the live canary showed the real failure is worse still -- the
    Unity main thread stalls outright. Unattended, that is a kiosk that stops selling until
    somebody notices.

    fleet_flash_armed.json is what the watchdog arms from. It is deliberately a separate file
    rather than NeedToUpdateFirmware: ControllerFirmwareTestLoader.Start() clears that flag before
    it begins, so a watchdog reading it would race the very code it is guarding.
    """
    target = f"{machine.get('ssh_user') or 'shaker'}@{machine['tailscale_ip']}"
    if dry_run:
        return True, "would arm"
    cmd = ARM_SCRIPT % {"d": SV_DATA,
                        "no_progress": FLASH_NO_PROGRESS_SECONDS,
                        "max_total": FLASH_MAX_TOTAL_SECONDS,
                        "hexname": filename, "version": fw["version"]}
    rc, out = ssh(target, cmd, timeout=60)
    if rc != 0:
        return False, (out or "arm failed")[:200]
    return True, out.strip()


# What ControllerFirmwareTestLoader.Start() will actually open, per IsTouch2. Names come from
# Settings.ControllerHexFilePath / ControllerHexFileTouch2 / ControllerHexFileTouch2FWP.
S_IMAGE = "shkr_m_con"
TOUCH2_IMAGES = ("mdrv_touch",)


def image_mismatch(filename, p):
    """Refuse an image the machine would never load. Returns a reason, or None if it fits.

    machine_types is an operator-maintained tag and it is the only thing that currently decides
    which image reaches which machine. That is one human mistake away from staging an S image at
    a Touch 2 board, so this cross-checks against the machine's OWN IsTouch2 flag, which is what
    the app actually branches on when it picks the file to open.

    It matters here specifically: machine 94 is a Touch-typed machine whose IsTouch2 is false, so
    it correctly wants the S image, and the shaker-touch tag on the firmware record exists for it.
    Nothing but this check then stops that same record reaching a real Touch 2.
    """
    name = (filename or "").lower()
    is_touch2 = bool(p.get("is_touch2"))
    if is_touch2 and not any(t in name for t in TOUCH2_IMAGES):
        return (f"machine has IsTouch2=true and loads MDRV_TOUCH.hex, but this record ships "
                f"{filename} — refusing, it would never be flashed and only litters _Data/")
    if not is_touch2 and any(t in name for t in TOUCH2_IMAGES):
        return (f"machine has IsTouch2=false and loads {S_IMAGE.upper()}*.hex, but this record "
                f"ships {filename} — refusing")
    return None


def flash_blockers(m, p):
    """Everything that must hold before a flash is armed. Returns a reason, or None to proceed.

    Ordered cheapest first, and deliberately explicit: each of these has a failure mode that ends
    with a technician driving to a machine.
    """
    if not m.get("isFirmwareAutoflash"):
        # Separate from isAutoupdate on purpose: flashing invalidates the water calibration for
        # anything older than 260211-01 (Strapi knowledge 26 sec.7), so it must never ride in on
        # the app-update opt-in.
        return "isFirmwareAutoflash is off"
    if not p.get("has_watchdog"):
        return ("no FirmwareFlashWatchdog in CommonCode.dll — a failed flash would wedge the "
                "kiosk with no way back")
    if p.get("need_flag"):
        return "NeedToUpdateFirmware is already set — a flash is pending, not re-arming"
    if p.get("armed") == "armed":
        return "fleet_flash_armed.json still unconsumed — the app has not restarted yet"
    if not p.get("pid"):
        return "ShakerView is not running"
    screen = p.get("screen") or ""
    if screen and screen != "StartScreen":
        return f"kiosk in use (CurrentScreen = {screen})"
    if not screen:
        return "cannot tell whether the kiosk is in use (no CurrentScreen logged)"
    prev = m.get("controller_fw_status") or {}
    attempts = int(prev.get("flash_attempts") or 0)
    if attempts >= MAX_FLASH_ATTEMPTS:
        return (f"{attempts} unattended flash attempts already failed — needs a human "
                f"(Service Mode -> Engineering Menu -> Load Firmware)")
    return None


def clear_consumed_marker(machine):
    """Drop the watchdog's spent marker so one failed attempt is never counted twice."""
    target = f"{machine.get('ssh_user') or 'shaker'}@{machine['tailscale_ip']}"
    ssh(target, f"rm -f {SV_DATA}/Config/fleet_flash_armed.consumed.json")


def try_arm(m, p, fw, filename, status, dry_run, now, budget):
    """Arm an unattended flash if every gate allows it. Returns a log line, or None.

    Records the blocking reason on `status` either way, so the fleet report says why a machine is
    still waiting on a human rather than silently looking identical to one that is not opted in.

    `budget` is the per-sweep arming allowance, mutated in place so the caller keeps count.
    """
    if budget["left"] <= 0:
        status["flash_blocked_by"] = (f"already armed {MAX_ARMS_PER_SWEEP} machine(s) this sweep "
                                      f"— next one waits for the following run")
        return None
    why = flash_blockers(m, p)
    if why:
        status["flash_blocked_by"] = why
        return None
    ok, msg = arm_flash(m, fw, filename, dry_run)
    if not ok:
        status["action"] = f"arm failed: {msg}"
        return f"ARM FAILED: {msg}"
    if dry_run:
        status["flash_blocked_by"] = "dry run"
        return "would ARM unattended flash"
    status.update(action="armed", armed_at=now, needs_onsite=False,
                  flash_attempts=int(status.get("flash_attempts") or 0),
                  flash_no_progress_seconds=FLASH_NO_PROGRESS_SECONDS,
                  flash_max_total_seconds=FLASH_MAX_TOTAL_SECONDS)
    status.pop("flash_blocked_by", None)
    budget["left"] -= 1
    return (f"ARMED unattended flash and restarted the app — the watchdog puts the kiosk back "
            f"in service if the write goes silent for {FLASH_NO_PROGRESS_SECONDS}s")


# ---------------------------------------------------------------- main

def sweep_one(m, firmwares, token, dry_run, report_only, budget):
    name = f"{m['id']} {m.get('serial_number') or m.get('title') or ''}".strip()
    p = probe(m)
    now = time.strftime("%FT%TZ", time.gmtime())

    if p is None:
        return name, "unreachable", None
    if p["no_sv"]:
        return name, "no ShakerView", None

    prev = m.get("controller_fw_status") or {}
    cur = p["version"]
    status = {"at": now, "read": cur or "unknown", "raw": p["raw"] or None}

    fw = pick_firmware(firmwares, m)
    if not fw:
        status["action"] = "no stable firmware for this machine type"
        return name, f"{cur or '?'} — nothing to roll out", status

    tgt = fw["version"]
    status["target"] = tgt

    if cur is None:
        # Never stage blind. An unknown version could be NEWER than the target, and staging
        # would set up a silent downgrade the next time somebody clicks Load Firmware.
        status["action"] = "version unknown — not staging"
        return name, f"? (no ControllerVersionAnswer in logs) — target {tgt}, skipped", status

    attempts = int(prev.get("flash_attempts") or 0)

    if vkey(cur) >= vkey(tgt):
        # If the previous run staged something and the version has since caught up, the app
        # flashed it and deleted the file — close the loop.
        if prev.get("action") in ("staged", "armed") and not p["staged_md5"]:
            clear_consumed_marker(m)
            status["action"] = "flashed since last sweep"
            status["flash_attempts"] = 0
            how = "unattended" if prev.get("action") == "armed" else "on site"
            return name, f"{cur} — up to date (flashed {how} since last sweep)", status
        status["action"] = "up to date"
        return name, f"{cur} — up to date", status

    # Still below target with a consumed marker sitting there: the app was armed, started, and
    # came back without the version moving. Either the write failed or the watchdog rescued a
    # wedge — both are a failed attempt, and both must be counted, or a machine that can never
    # flash would be restarted every hour forever.
    if p.get("armed") == "consumed":
        attempts += 1
        clear_consumed_marker(m)
        log(f"{name}: unattended flash attempt {attempts} did not take (still {cur}) — "
            f"{'giving up, needs a human' if attempts >= MAX_FLASH_ATTEMPTS else 'will retry next sweep'}")
    status["flash_attempts"] = attempts

    # --- needs the newer image -------------------------------------------------
    if report_only:
        status["action"] = "needs update (report only)"
        return name, f"{cur} -> {tgt} NEEDS UPDATE", status

    src, md5_or_err = image_path(fw, token)
    if not src:
        status["action"] = f"image unavailable: {md5_or_err}"
        return name, f"{cur} -> {tgt} but {md5_or_err}", status
    want_md5 = md5_or_err
    filename = fw.get("hex_filename") or os.path.basename(src)

    # Checked before staging, not just before arming: an image the machine cannot load is dead
    # weight in _Data/ and shows up later as somebody else's "foreign image already staged".
    wrong = image_mismatch(filename, p)
    if wrong:
        status["action"] = f"image does not match the machine: {wrong}"
        return name, f"{cur} -> {tgt} BLOCKED: {wrong}", status

    if p["staged_md5"] == want_md5:
        since = prev.get("staged_at") or now
        waited = int((time.time() - time.mktime(time.strptime(since, "%Y-%m-%dT%H:%M:%SZ"))) / 86400)
        status.update(action="staged", staged_at=since, staged_md5=want_md5,
                      needs_onsite=True, waiting_days=waited)
        armed_line = try_arm(m, p, fw, filename, status, dry_run, now, budget)
        if armed_line:
            return name, f"{cur} -> {tgt} {armed_line}", status
        return name, (f"{cur} -> {tgt} STAGED {waited}d ago, still needs: Service Mode -> "
                      f"Engineering Menu -> Load Firmware -> CONTROLLER REBOOT -> recalibrate water"
                      f" [{status.get('flash_blocked_by', 'autoflash off')}]"), status

    if p["staged_md5"] and p["staged_name"] and p["staged_name"] != filename:
        # A different image is sitting there — almost always a Touch 2 MDRV file. Leave it.
        status["action"] = f"foreign image {p['staged_name']} present — not touching"
        return name, f"{cur} -> {tgt} BLOCKED: {p['staged_name']} already staged", status

    if dry_run:
        status["action"] = "would stage"
        return name, f"{cur} -> {tgt} would stage {filename}", status

    ok, msg = stage(m, src, want_md5, filename)
    if not ok:
        status["action"] = f"stage failed: {msg}"
        return name, f"{cur} -> {tgt} STAGE FAILED: {msg}", status
    status.update(action="staged", staged_at=now, staged_md5=want_md5,
                  needs_onsite=True, waiting_days=0)
    # The hex only just landed, so re-probe rather than trusting the pre-stage snapshot.
    p = probe(m) or p
    armed_line = try_arm(m, p, fw, filename, status, dry_run, now, budget)
    if armed_line:
        return name, f"{cur} -> {tgt} STAGED {filename} + {armed_line}", status
    return name, (f"{cur} -> {tgt} STAGED {filename} — now needs on site: Service Mode -> "
                  f"Engineering Menu -> Load Firmware -> CONTROLLER REBOOT -> recalibrate water"
                  f" [{status.get('flash_blocked_by', 'autoflash off')}]"), status


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="record versions, stage nothing")
    ap.add_argument("--report", action="store_true", help="read only; do not even download images")
    ap.add_argument("--machine", type=int, help="Strapi machine id, one machine only")
    ap.add_argument("--max", type=int, default=0, help="stop after N machines staged (0 = no limit)")
    a = ap.parse_args()

    env = lpm.load_env()
    ident = env.get("STRAPI_MACHINE_USER_USERNAME") or env.get("STRAPI_MACHINE_USER_LOGIN")
    token = lpm.strapi_login(ident, env["STRAPI_MACHINE_USER_PASSWORD"])

    fws = stable_firmwares(token)
    # No early return when there is nothing to roll out. Reading and recording every
    # machine's controller version is useful on its own — it is the only fleet-wide
    # inventory of what is actually on the boards — and it must not be gated on someone
    # having flipped a firmware record to isStable. With fws empty every machine simply
    # reports "no stable firmware for this machine type" and nothing is staged.
    if not fws:
        print("no stable controller firmware — recording versions only")
    if fws:
        log("stable images: " + ", ".join(
            f"{f['version']}({','.join(t['attributes'].get('name') or ('type ' + str(t['id'])) for t in (f.get('machine_types') or {}).get('data') or []) or 'UNTAGGED-skipped'})"
            for f in fws))

    staged = 0
    budget = {"left": MAX_ARMS_PER_SWEEP}
    for m in machines(token, a.machine):
        name, line, status = sweep_one(m, fws, token, a.dry_run, a.report, budget)
        if status and STRAPI_HAS_SCHEMA:
            try:
                api_put(f"/api/machines/{m['id']}", token,
                        {"controller_fw": status.get("read"), "controller_fw_status": status})
            except Exception as e:
                log(f"{name}: strapi write failed: {e}")
        if status and status.get("action") not in (None, "up to date",
                                                   "no stable firmware for this machine type"):
            log(f"{name}: {line}")
        elif a.report or a.dry_run:
            print(f"{name}: {line}")
        if status and status.get("action") == "staged" and status.get("waiting_days") == 0:
            staged += 1
            if a.max and staged >= a.max:
                log(f"--max {a.max} reached, stopping")
                break


if __name__ == "__main__":
    main()
