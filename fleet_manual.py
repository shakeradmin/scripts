"""Manual-support machines: excluded from every unattended fleet sweep.

/home/ishaker/fleet_manual.txt lists machines that live by their own rules and are
serviced by hand only. One entry per line — a Strapi machine id, a serial_number, a
nickname or a tailscale_ip; `#` starts a comment. Every fleet cron (fleetpulse,
fleetpatch, fleetfirmware, fleetsales, network-watchdog rollout, rustdesk heal)
drops a listed machine from its sweep set, so nothing pushes media, patches,
firmware, watchdogs or restarts at it.

First entry: 96 white (25081725-rfaa8), 2026-09-12 — hand-built milkshake kiosk;
its shakerview-watchdog is masked and the app's own daily restart is off, so the
box must never be re-armed by a sweep.

Override for a deliberate hand-run of a fleet tool against a listed machine:
    FLEET_MANUAL_OVERRIDE=1 python3 fleetpatch.py --machine 96 --patch 40
"""
import os

MANUAL_FILE = os.environ.get("FLEET_MANUAL_FILE", "/home/ishaker/fleet_manual.txt")


def load():
    """Set of tokens (ids/serials/nicknames/ips as lower-case strings)."""
    if os.environ.get("FLEET_MANUAL_OVERRIDE") == "1":
        return set()
    try:
        with open(MANUAL_FILE, encoding="utf-8") as f:
            out = set()
            for line in f:
                line = line.split("#", 1)[0].strip()
                if line:
                    out.add(line.lower())
            return out
    except FileNotFoundError:
        return set()


def is_manual(machine_id=None, serial=None, nickname=None, ip=None, manual=None):
    """True when any identifier of the machine is listed."""
    manual = load() if manual is None else manual
    if not manual:
        return False
    for v in (machine_id, serial, nickname, ip):
        if v is not None and str(v).strip().lower() in manual:
            return True
    return False


def filter_rows(rows, *, get_id=lambda r: r.get("id"), get_serial=lambda r: r.get("serial"),
                get_nick=lambda r: r.get("nickname"), get_ip=lambda r: r.get("ip"), log=None):
    """Drop listed machines from a list of dicts; log one line per drop when `log` is given."""
    manual = load()
    if not manual:
        return rows
    kept = []
    for r in rows:
        if is_manual(get_id(r), get_serial(r), get_nick(r), get_ip(r), manual):
            if log:
                log(f"machine {get_id(r)} ({get_serial(r) or get_nick(r) or get_ip(r)}): "
                    f"MANUAL-SUPPORT (fleet_manual.txt) — excluded from the sweep")
            continue
        kept.append(r)
    return kept


if __name__ == "__main__":
    import sys
    m = load()
    if len(sys.argv) > 1:
        print("manual" if is_manual(*sys.argv[1:2], serial=sys.argv[1], nickname=sys.argv[1],
                                    ip=sys.argv[1], manual=m) else "fleet")
    else:
        print("\n".join(sorted(m)) or "(empty)")
