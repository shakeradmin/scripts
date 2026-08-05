#!/usr/bin/env python3
"""
controller_fw — read (and optionally pre-stage) the MCU controller firmware of the fleet.

The machine's controller (an AVR board on /dev/ttyS1, NOT the Linux box and NOT ShakerView)
announces its firmware version to ShakerView on every connect. The app logs it verbatim:

    ControllerVersionAnswer D506491A030A0300
                            ^^^^^^ ^^ ^^ ^^ ^^ ^^
                            magic  YY MM DD BB pad

All fields are BCD-ish hex bytes: 0x1A=2026, 0x03=March, 0x0A=10th, 0x03=build 3.
That maps 1:1 onto Mikhail's own naming, "YYMMDD-BB" — e.g. D50649 1A 04 18 05 is the
`260424-05` build the KB records on Lift ATX. So the whole fleet's controller version is
readable over ssh, without Service Mode and without anyone standing at the machine.

Usage:
    controller_fw.py                      # read + decode the fleet (default)
    controller_fw.py --model S            # only Shaker S (IsSModel true)
    controller_fw.py --stage FILE.hex     # ALSO copy FILE.hex into _Data/ on each match

--stage only PLACES the file. It does not flash anything: the controller is only written
when a human opens Service Mode -> Engineering Menu -> Load Firmware, and the new image is
only activated by the physical CONTROLLER REBOOT button inside the door. Staging days ahead
of an on-site visit is therefore risk-free and is the intended pattern.

Do NOT stage Shkr_M_Con_V3.hex on a Touch 2 — those run the MDRV controller and take
MDRV_TOUCH.hex / MDRV_TOUCH_FWP.hex, chosen by water-pump type (KB 13 sec.1).
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request

STRAPI = "https://admin.ishaker.xyz"
ENV = os.path.expanduser("~/Desktop/credentials/.env")
SV_DATA = "/home/shaker/ShakerView2.0Linux/ShakerView2.0_Data"
SSH = ["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
       "-i", os.path.expanduser("~/.ssh/id_ed25519"), "-o", "StrictHostKeyChecking=no"]

VER_RE = re.compile(r"ControllerVersionAnswer\s+([0-9A-Fa-f]{12,})")


def decode(raw):
    """D506491A030A0300 -> ('260310-03', '2026-03-10 build 3'). None if unrecognised."""
    if not raw:
        return None
    b = bytes.fromhex(raw.strip())
    if len(b) < 7 or b[:3] != b"\xd5\x06\x49":
        return None
    yy, mm, dd, bb = b[3], b[4], b[5], b[6]
    return ("%02d%02d%02d-%02d" % (yy, mm, dd, bb),
            "20%02d-%02d-%02d build %d" % (yy, mm, dd, bb))


def strapi_machines():
    for line in open(ENV):
        if line.startswith("STRAPI_MACHINE_USER_LOGIN="):
            user = line.split("=", 1)[1].strip()
        elif line.startswith("STRAPI_MACHINE_USER_PASSWORD="):
            pw = line.split("=", 1)[1].strip()
    # Cloudflare 403s urllib's UA on admin.ishaker.xyz -> curl, per KB.
    jwt = json.loads(subprocess.check_output([
        "curl", "-s", "-X", "POST", STRAPI + "/api/auth/local",
        "-H", "Content-Type: application/json",
        "-d", json.dumps({"identifier": user, "password": pw})]))["jwt"]
    out = subprocess.check_output([
        "curl", "-s", "-H", "Authorization: Bearer " + jwt,
        STRAPI + "/api/machines?pagination[pageSize]=200"
        "&fields[0]=title&fields[1]=serial_number&fields[2]=tailscale_ip"])
    return [dict(id=m["id"], **m["attributes"]) for m in json.loads(out)["data"]
            if m["attributes"].get("tailscale_ip")]


PROBE = r'''
C=%(d)s/Config/hard_settings.json
S=$(grep -o '"MachineSerial": *"[^"]*"' $C 2>/dev/null | head -1 | cut -d'"' -f4)
M=$(grep -o '"IsSModel": *[a-z]*' $C 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')
# -a: logs carry NUL bytes after unclean power cuts; without it grep prints nothing.
V=$(grep -ahoE 'ControllerVersionAnswer[[:space:]]+[0-9A-F]{12,}' %(d)s/Logs/*.log 2>/dev/null | tail -1 | awk '{print $2}')
H=$(md5sum %(d)s/*.hex 2>/dev/null | head -1)
echo "$S|$M|$V|$H"
''' % {"d": SV_DATA}


def probe(m):
    try:
        out = subprocess.run(SSH + ["shaker@" + m["tailscale_ip"], PROBE],
                             capture_output=True, text=True, timeout=30).stdout.strip()
        serial, is_s, ver, staged = (out.split("|") + ["", "", "", ""])[:4]
    except Exception:
        serial = is_s = ver = staged = ""
        out = ""
    return dict(m, ok=bool(out), serial=serial, is_s=(is_s == "true"),
                raw=ver, ver=decode(ver), staged=staged)


def stage(m, path, md5):
    """Copy the .hex into _Data/, backing up whatever is there. Never flashes."""
    dst = "%s/%s" % (SV_DATA, os.path.basename(path))
    subprocess.run(SSH + ["shaker@" + m["tailscale_ip"],
                          "test -f %s && cp -n %s %s.bak-$(date +%%Y%%m%%d-%%H%%M%%S) || true" % (dst, dst, dst)],
                   capture_output=True, timeout=30)
    scp = ["scp", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
           "-i", os.path.expanduser("~/.ssh/id_ed25519"), path,
           "shaker@%s:%s" % (m["tailscale_ip"], dst)]
    if subprocess.run(scp, capture_output=True, timeout=120).returncode != 0:
        return "scp failed"
    got = subprocess.run(SSH + ["shaker@" + m["tailscale_ip"], "md5sum " + dst],
                         capture_output=True, text=True, timeout=30).stdout.split()
    return "staged ok" if got and got[0] == md5 else "MD5 MISMATCH"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=["S", "touch", "all"], default="all")
    ap.add_argument("--stage", metavar="FILE.hex")
    a = ap.parse_args()

    md5 = None
    if a.stage:
        md5 = hashlib.md5(open(a.stage, "rb").read()).hexdigest()
        print("staging %s (md5 %s)\n" % (a.stage, md5))
        if "MDRV" not in os.path.basename(a.stage).upper() and a.model != "S":
            sys.exit("refusing: %s looks like a Shaker-S image; re-run with --model S "
                     "so it cannot land on a Touch 2 (they use MDRV_TOUCH*.hex)."
                     % os.path.basename(a.stage))

    machines = strapi_machines()
    with concurrent.futures.ThreadPoolExecutor(16) as ex:
        rows = list(ex.map(probe, machines))

    print("%-5s %-22s %-16s %-11s %-22s %s" %
          ("id", "serial", "ip", "version", "decoded", "note"))
    for r in sorted(rows, key=lambda r: (not r["ok"], r["ver"] is None)):
        if not r["ok"]:
            print("%-5s %-22s %-16s %s" % (r["id"], (r["serial_number"] or "")[:22],
                                           r["tailscale_ip"], "offline / no ssh"))
            continue
        if a.model == "S" and not r["is_s"]:
            continue
        if a.model == "touch" and r["is_s"]:
            continue
        short, long_ = r["ver"] or ("?", "unknown — no ControllerVersionAnswer in logs")
        note = ("staged: " + r["staged"].split()[0][:8]) if r["staged"] else ""
        if a.stage and (a.model != "S" or r["is_s"]):
            note = stage(r, a.stage, md5)
        print("%-5s %-22s %-16s %-11s %-22s %s" %
              (r["id"], r["serial"] or r["serial_number"], r["tailscale_ip"],
               short, long_, note))


if __name__ == "__main__":
    main()
