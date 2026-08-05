#!/usr/bin/env python3
"""
flash_firmware — actually write the staged controller image, unattended.

This is the step fleetfirmware deliberately stops short of. Proven end to end on machine 81
(260511733) on 2026-07-29: no patch to the app is needed. The trigger is stock —
UpdaterHandler.InitAutoUpdate() runs `if (NeedToUpdateFirmware) StartUpdatingFirmware()` at
startup, and patch 2 disabled only the scheduled cloud check, not that branch. So:

    stage the .hex  ->  set NeedToUpdateFirmware  ->  restart the app  ->  it flashes itself

The app then programs the board line by line (~130 lines/20 s, ~2840 lines for a 45 KB image,
so roughly 6-7 minutes), sends 0A670A, DELETES the hex, and restarts itself. The hex
disappearing is the success signal, and it is the app's own doing — not something we infer.

WHAT THIS REFUSES TO DO
  * flash a machine whose staged hex md5 != the target's                      (wrong image)
  * flash a machine where ShakerView is not running                          (nothing to trigger)
  * flash a machine that is not on the attract screen                        (somebody is buying)
  * flash a machine with no systemd shakerview-watchdog, unless --no-watchdog (no rescue)

WHAT IT CANNOT DO FOR YOU
  Recalibrate the water. Anything coming from 250716-02 or older stored its coefficient
  somewhere else entirely and needs a real recalibration afterwards; 251218-01 is unmeasured.
  See Strapi knowledge 26 sec.7. This script flashes; it does not make the machine correct.

Usage:
    flash_firmware.py --machine 25            # one machine
    flash_firmware.py --all                   # every machine with a matching staged image
    flash_firmware.py --machine 25 --dry-run
"""

import argparse, importlib.util, json, os, re, subprocess, sys, time

HOME = os.path.expanduser("~")
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
LOG_ROOT = os.path.join(HOME, "fleetfirmware")
STRAPI = os.environ.get("STRAPI_BASE_URL", "http://localhost:1338")
SV_DATA = "/home/shaker/ShakerView2.0Linux/ShakerView2.0_Data"
SV_BIN = "/home/shaker/ShakerView2.0Linux/ShakerView2.0.x86_64"
PLAYER_LOG = "~/.config/unity3d/ShakerTechnology/ShakerView2.0/Player.log"
POLL_SECONDS = 30
MAX_WAIT = 900            # 15 min: a 45 KB image takes ~7, so this is a generous ceiling

_ff = importlib.util.spec_from_file_location("ff", os.path.join(SCRIPTS, "fleetfirmware.py"))
ff = importlib.util.module_from_spec(_ff)
_ff.loader.exec_module(ff)
ssh, api, api_put, log = ff.ssh, ff.api, ff.api_put, ff.log


def target_for(machine, firmwares):
    fw = ff.pick_firmware(firmwares, machine)
    return fw


def preflight(target, want_md5, require_watchdog):
    """Every reason not to touch this machine, checked before anything is changed."""
    rc, staged = ssh(target, f"md5sum {SV_DATA}/*.hex 2>/dev/null | head -1 | awk '{{print $1}}'")
    if rc != 0:
        return "unreachable"
    if not staged:
        return "no staged image"
    if staged != want_md5:
        return f"staged image is {staged[:8]}, target is {want_md5[:8]}"

    rc, pid = ssh(target, f"pgrep -f '^{SV_BIN}$' | head -1")
    if rc != 0 or not pid.strip():
        return "ShakerView not running — nothing would consume the flag"

    rc, screen = ssh(target, f"grep -ao 'CurrentScreen = [A-Za-z]*' {PLAYER_LOG} | tail -1")
    screen = (screen or "").split("=")[-1].strip()
    if screen and screen not in ("StartScreen", ""):
        return f"kiosk is on {screen} — somebody is at the machine"

    if require_watchdog:
        rc, wd = ssh(target, "systemctl is-active shakerview-watchdog 2>/dev/null")
        if wd.strip() != "active":
            return "no shakerview-watchdog (pass --no-watchdog to flash without a rescue)"
    return None


def arm_and_restart(target):
    """Set the stock one-shot flag, then the canonical single-PID restart."""
    p = f"{SV_DATA}/Config/updater_settings.json"
    rc, _ = ssh(target, f"cp -a {p} {p}.bak-pre-flash-$(date +%Y%m%d-%H%M%S)")
    py = (
        "python3 -c \"import json,io;"
        f"p='{p}';"
        "d=json.load(io.open(p,encoding='utf-8-sig'));"
        "d['NeedToUpdateFirmware']=True;"
        "io.open(p,'w',encoding='utf-8-sig').write(json.dumps(d,indent=2));"
        "print(json.load(io.open(p,encoding='utf-8-sig'))['NeedToUpdateFirmware'])\""
    )
    rc, out = ssh(target, py)
    if rc != 0 or out.strip() != "True":
        return f"could not arm the flag: {out[:120]}"

    # Single exact PID only. A pattern kill here would take AppManager with it and the
    # machine would never come back on its own.
    rc, pids = ssh(target, f"pgrep -f '^{SV_BIN}$' | tr '\\n' ' '")
    pids = (pids or "").split()
    if len(pids) != 1:
        return f"expected exactly 1 ShakerView pid, got {len(pids)}"
    ssh(target, f"kill {pids[0]}")
    return None


def wait_for_flash(target, label):
    """The app deletes the hex on a successful write — that is the completion signal."""
    started = time.time()
    last_line = 0
    while time.time() - started < MAX_WAIT:
        time.sleep(POLL_SECONDS)
        rc, out = ssh(target, (
            f"H=$(ls {SV_DATA}/*.hex 2>/dev/null | wc -l); "
            f"E=$(grep -c 'Error on write\\|Firmware loader is not available' {PLAYER_LOG} 2>/dev/null); "
            f"L=$(grep -oE '^[0-9]+ CommandManager.IsControllerReadyToReadNextLineOfFirmware' {PLAYER_LOG} 2>/dev/null | tail -1 | awk '{{print $1}}'); "
            f"R=$(pgrep -cf '^{SV_BIN}$'); echo \"$H|$E|$L|$R\""))
        if rc != 0:
            log(f"{label}: probe failed, retrying")
            continue
        h, e, l, r = (out.split("|") + ["", "", "", ""])[:4]
        if l and l.isdigit():
            last_line = int(l)
        if e and e.isdigit() and int(e) > 0:
            return f"write errors reported ({e}) at line {last_line}"
        if h == "0":
            return None                       # hex gone == the app finished and cleaned up
        log(f"{label}: writing, line {last_line} (app running={r})")
    return f"timed out after {MAX_WAIT}s at line {last_line}"


def verify(target):
    rc, out = ssh(target, (
        f"grep -ahoE 'ControllerVersionAnswer[[:space:]]+[0-9A-F]{{12,}}' {SV_DATA}/Logs/*.log "
        "2>/dev/null | tail -1 | awk '{print $2}'"))
    return ff.decode_version(out.strip()) if rc == 0 else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", type=int, help="Strapi id — UNSTABLE, records get recreated")
    ap.add_argument("--serial", help="serial_number — the stable key, prefer this")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-watchdog", action="store_true",
                    help="flash even where no systemd rescue is installed")
    a = ap.parse_args()
    if not (a.machine or a.serial or a.all):
        sys.exit("pick --serial <sn> (preferred), --machine <id>, or --all")

    env = ff.lpm.load_env()
    ident = env.get("STRAPI_MACHINE_USER_USERNAME") or env.get("STRAPI_MACHINE_USER_LOGIN")
    token = ff.lpm.strapi_login(ident, env["STRAPI_MACHINE_USER_PASSWORD"])
    firmwares = ff.stable_firmwares(token)
    if not firmwares:
        sys.exit("no stable controller firmware — nothing to flash")

    # Strapi machine ids are NOT stable: the fleet gets re-enrolled and records are deleted
    # and recreated (260511739 went 73 -> 80, 260511736 went 78 -> 82 -> 84 in one evening).
    # Selecting by id silently matched nothing and the driver exited 0 having done nothing.
    # serial_number is the stable key; --machine stays for convenience but warns.
    picked = [m for m in ff.machines(token)
              if (a.all
                  or (a.serial and str(m.get("serial_number")) == a.serial)
                  or (a.machine and m["id"] == a.machine))]
    if not picked:
        sys.exit(f"no machine matched (serial={a.serial!r} id={a.machine!r}) — "
                 "ids change when the fleet is re-enrolled, try --serial")
    for m in picked:
        label = f"{m['id']} {m.get('serial_number') or ''}".strip()
        fw = target_for(m, firmwares)
        if not fw:
            continue
        src, md5 = ff.image_path(fw, token)
        if not src:
            log(f"{label}: {md5}")
            continue
        target = f"{m.get('ssh_user') or 'shaker'}@{m['tailscale_ip']}"

        why = preflight(target, md5, not a.no_watchdog)
        if why:
            log(f"{label}: SKIP — {why}")
            continue
        if a.dry_run:
            log(f"{label}: would flash {fw['version']}")
            continue

        log(f"{label}: flashing {fw['version']} — arming and restarting")
        err = arm_and_restart(target)
        if err:
            log(f"{label}: ABORT — {err}")
            continue
        err = wait_for_flash(target, label)
        if err:
            log(f"{label}: FAILED — {err}. Image left staged; machine may need a look.")
            continue
        time.sleep(45)                        # the app restarts itself; let it come back
        got = verify(target)
        ok = got == fw["version"]
        log(f"{label}: {'OK' if ok else 'WROTE BUT VERSION READS ' + str(got)} — now {got}")
        try:
            api_put(f"/api/machines/{m['id']}", token,
                    {"controller_fw": got,
                     "controller_fw_status": {"at": time.strftime("%FT%TZ", time.gmtime()),
                                              "read": got, "target": fw["version"],
                                              "action": "flashed" if ok else "flash unverified",
                                              "needs_water_check": True}})
        except Exception as e:
            log(f"{label}: strapi write failed: {e}")


if __name__ == "__main__":
    main()
