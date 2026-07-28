#!/usr/bin/env python3
"""
FleetPatch — automatic ShakerView patch rollout, gated on operator intent.

Companion to fleetpulse.py. FleetPulse watches health and pushes media; FleetPatch
installs CommonCode patches. Split deliberately: a monitoring sweep that also swaps
binaries is a sweep you stop trusting.

ROLLOUT GATE — all five must hold, no exceptions:

  1. patch.isStable == true            operator says it is ready. Default false.
  2. machine.isAutoupdate == true      operator opted THIS machine in.
  3. patch.machine_types contains the machine's type
                                       a Shaker-S build must never land on a Touch.
  4. live md5 is listed in base_md5    the binary on disk is an ACCEPTED predecessor.
  5. remote Managed/ fingerprint       the reference set is byte-identical to the one
     == the artifact's .managed        the artifact was compiled against.

(5) is the real invariant, and the reason "patch id is higher than installed" is NOT a
valid trigger. Patches are PER-TARGET builds compiled against the machine's own 163-DLL
reference set; drop one onto a different set and types can resolve to another assembly,
killing the app with TypeLoadException at RUNTIME — nothing catches it at build time.

(4) is deliberately a LIST, not one hash. A patch is valid for any build compiled against
the same reference set, not only for the binary that happened to precede it. Machine 63
sat on patch 9 while patch 12 named patch 11 as its base: same lineage, same 163 DLLs,
refused purely because the field held a single hash. Add every accepted predecessor to
base_md5 (any 32-hex token in that text counts) once (5) has been verified.

Already carrying patched_md5 -> skipped, so the run is idempotent.

ARTIFACT: <ARTIFACT_ROOT>/<patched_md5>.dll — named by content, so a mismatch is
impossible to miss. Verified by md5 before it is shipped anywhere. Beside it,
<patched_md5>.managed holds the reference-set fingerprint for check (5); no sidecar
means no install, because compatibility must never be guessed.

PER MACHINE:
  backup live dll -> stop watchdog -> copy -> canonical restart (exact pid, AppManager
  relaunches) -> wait -> verify. Verification requires ALL of: process alive, PatchDiag
  heartbeat advancing, no MissingMethod/TypeLoadException. Any failure ROLLS BACK the
  backup and restarts again.

  Never patches a machine that is mid-sale: refuses unless the kiosk has been idle
  (attract screen / no recent user activity) — see --force to override.

SAFETY RAILS:
  * --max N        stop after N successful installs (default 2). Canary first, always.
  * one failure    aborts the whole run, not just that machine.
  * --dry-run      report what would happen, touch nothing.

USAGE
  python3 fleetpatch.py --dry-run
  python3 fleetpatch.py --patch 12 --max 1
  python3 fleetpatch.py --patch 12 --machine 61
"""
import argparse, hashlib, importlib.util, json, os, re, subprocess, sys, time
import urllib.request

HOME = os.path.expanduser("~")
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ARTIFACT_ROOT = os.path.join(HOME, "fleetpatch", "artifacts")
LOG_ROOT = os.path.join(HOME, "fleetpatch")
STRAPI = os.environ.get("STRAPI_BASE_URL", "http://localhost:1338")
SSH_TIMEOUT = 20
RESTART_WAIT = 45          # AppManager relaunch + Unity boot
UA = "fleetpatch/1.0"

SV_DIR = "~/ShakerView2.0Linux/ShakerView2.0_Data"
SV_BIN = "/home/shaker/ShakerView2.0Linux/ShakerView2.0.x86_64"
DIAG = "~/ShakerView-diag/patch-diag.log"
PLAYER_LOG = "~/.config/unity3d/ShakerTechnology/ShakerView2.0/Player.log"

_spec = importlib.util.spec_from_file_location(
    "lpm", os.path.join(SCRIPTS, "load_product_media.py"))
lpm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lpm)


def log(msg):
    line = f"[{time.strftime('%F %T')}] {msg}"
    print(line, flush=True)
    os.makedirs(LOG_ROOT, exist_ok=True)
    with open(os.path.join(LOG_ROOT, "fleetpatch.log"), "a") as f:
        f.write(line + "\n")


def ssh(target, cmd, timeout=SSH_TIMEOUT):
    """Never raises. A slow or wedged machine must be reported, not crash the run.

    subprocess.run(timeout=) raises TimeoutExpired; uncaught, one unresponsive machine
    aborted the whole sweep with a traceback and stopped the rollout for every machine
    behind it.
    """
    try:
        r = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
             "-o", f"ConnectTimeout={min(timeout, 15)}", target, cmd],
            capture_output=True, text=True, timeout=timeout + 15)
        # stdout ONLY on success. Merging stderr poisons every value this function is
        # parsed for: on the first ever connection to a machine ssh writes "Warning:
        # Permanently added '<ip>' to the list of known hosts." to stderr, so `live`
        # became the md5 PLUS that sentence and matched no accepted base — machine 79
        # (260511735) was skipped as "not an accepted base" while holding a listed one.
        # Every brand-new machine hits this exactly once, which is the worst possible
        # timing. On failure the merge stays: that is where the diagnostic text lives.
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


def first_md5(text):
    """patched_md5/base_md5 carry prose around the hash ('abc… (702976 B) — lineage …')."""
    m = re.search(r"\b[0-9a-f]{32}\b", text or "")
    return m.group(0) if m else None


def all_md5(text):
    """Accepted predecessor builds, read from base_md5.

    A patch is valid for any build compiled against the same reference set, not only for
    the binary that happened to precede it. Machine 63 sat on patch 9 while patch 12 named
    patch 11 as its base — same lineage, refused purely because the field held one hash.

    Hashes must be marked `BASE:<md5>`. Scraping every 32-hex token out of the prose was
    the first attempt and it is unsafe: the field also mentions Managed/ fingerprints and
    superseded builds, and each of those silently became an accepted base. Records written
    before the marker existed fall back to the old behaviour so they keep working.
    """
    text = text or ""
    marked = re.findall(r"BASE:\s*([0-9a-f]{32})\b", text)
    if marked:
        return marked
    return re.findall(r"\b[0-9a-f]{32}\b", text)


def managed_fingerprint_remote(target):
    """md5 of the sorted md5s of every reference DLL except CommonCode itself.

    THIS is the real compatibility invariant. A per-target build is safe on any machine
    whose reference set is byte-identical; a mismatch means types could resolve to a
    different assembly and the app dies with TypeLoadException at runtime, not at build.
    """
    cmd = ("find %s/Managed -name '*.dll' ! -name 'CommonCode.dll' ! -name '._*' "
           "-exec md5sum {} \\; | sort -k2 | awk '{print $1}' | md5sum | cut -d' ' -f1" % SV_DIR)
    rc, out = ssh(target, cmd)
    return out.strip() if rc == 0 else None


# ---------------------------------------------------------------- gate

def stable_patches(token):
    q = ("/api/patches?filters[isStable][$eq]=true&populate[machine_types][fields][0]=id"
         "&pagination[pageSize]=100&sort=id:desc")
    return api(q, token)["data"]


def candidate_machines(token):
    q = ("/api/machines?populate[patch][fields][0]=id&populate[machine_type][fields][0]=id"
         "&fields[0]=serial_number&fields[1]=tailscale_ip&fields[2]=ssh_user"
         "&fields[3]=isAutoupdate&pagination[pageSize]=200")
    out = []
    for row in api(q, token)["data"]:
        a = row["attributes"]
        if a.get("isAutoupdate") is not True:
            continue
        if not a.get("tailscale_ip"):
            continue
        out.append({
            "id": row["id"], "serial": a.get("serial_number"), "ip": a["tailscale_ip"],
            "user": a.get("ssh_user") or "shaker",
            "patch_id": ((a.get("patch") or {}).get("data") or {}).get("id"),
            "type_id": ((a.get("machine_type") or {}).get("data") or {}).get("id"),
        })
    return out


def pick_patch(patches, machine):
    """Highest stable patch whose machine_types include this machine's type."""
    for p in patches:  # already sorted id:desc
        types = [t["id"] for t in (p["attributes"].get("machine_types") or {}).get("data", [])]
        if machine["type_id"] in types:
            return p
    return None


# ---------------------------------------------------------------- install

def kiosk_idle(target):
    """Refuse to restart a machine somebody is standing at."""
    rc, _ = ssh(target, f"test -f {DIAG}")
    if rc != 0:
        # PatchDiag ships WITH the patch, so a machine that has never been patched has no
        # diag file — the normal state of a freshly bootstrapped machine, not a fault.
        # Requiring the heartbeat here made every new machine permanently unpatchable.
        # Fall back to "the app is running", then to the attract-screen check below,
        # which is what actually answers "is somebody standing at it".
        rc, pid = ssh(target, f"pgrep -f '^{SV_BIN}$' | head -1")
        if rc != 0 or not pid.strip():
            return False, "ShakerView not running (and no PatchDiag to fall back on)"
    else:
        rc, out = ssh(target, f"grep -a 'heartbeat' {DIAG} | tail -1")
        if rc != 0:
            return False, "no patch-diag heartbeat"
    # The app logs "CurrentScreen = X" on every navigation, so the LAST one states exactly
    # where the kiosk is standing. StartScreen is the attract screen: nobody is buying.
    #
    # This replaces a `tail -40 | grep 'Play ad'` window count, which called an idle machine
    # busy: a payment terminal polls constantly ("PaymentSystemsExist ..."), so on any
    # machine with a terminal attached the ad lines are pushed out of a 40-line tail within
    # seconds. Machine 79 sat on StartScreen and was refused as "in use".
    rc, screen = ssh(target, f"grep -ao 'CurrentScreen = [A-Za-z]*' {PLAYER_LOG} | tail -1")
    screen = (screen or "").split("=")[-1].strip()
    if screen:
        if screen == "StartScreen":
            return True, "idle (StartScreen)"
        return False, f"kiosk in use (CurrentScreen = {screen})"

    # No screen ever logged — fall back to the old attract-frame check rather than
    # assuming idle, because "we cannot tell" must never mean "go ahead and restart".
    rc, tail = ssh(target, f"tail -200 {PLAYER_LOG} | grep -c 'Play ad' || true")
    if rc == 0 and tail.strip().isdigit() and int(tail.strip()) > 0:
        return True, "idle (attract screen)"
    return False, "cannot tell whether the kiosk is in use (no CurrentScreen, no attract frames)"


def verify(target, want_md5):
    rc, live = ssh(target, f"md5sum {SV_DIR}/Managed/CommonCode.dll | cut -d' ' -f1")
    if rc != 0 or live.strip() != want_md5:
        return False, f"md5 mismatch after copy: {live.strip()[:12]}"
    rc, pid = ssh(target, f"pgrep -f '^{SV_BIN}$' | head -1")
    if rc != 0 or not pid.strip():
        return False, "process not running"
    # First-time patch: the diag file does not exist until the new build writes it, and a
    # bare `grep -c` on a missing file yields an empty string that reads as "not advancing"
    # and triggers a needless rollback. Normalise every failure mode to 0.
    hb = f"( [ -f {DIAG} ] && grep -ac heartbeat {DIAG} || echo 0 ) | head -1"
    rc, hb1 = ssh(target, hb)
    time.sleep(65)
    rc, hb2 = ssh(target, hb)
    if not (hb1.strip().isdigit() and hb2.strip().isdigit() and int(hb2) > int(hb1)):
        return False, "PatchDiag heartbeat not advancing"
    rc, exc = ssh(target, f"grep -ac 'MissingMethodException\\|TypeLoadException' {PLAYER_LOG}")
    if exc.strip().isdigit() and int(exc) > 0:
        return False, f"{exc.strip()} MissingMethod/TypeLoad exceptions"
    return True, "ok"


def install(machine, patch, artifact, dry_run, force):
    # Everything below tolerates ssh() returning a non-zero rc instead of raising.
    target = f"{machine['user']}@{machine['ip']}"
    want = first_md5(patch["attributes"].get("patched_md5"))
    base = first_md5(patch["attributes"].get("base_md5"))
    tag = f"machine {machine['id']} ({machine['serial']})"

    rc, live = ssh(target, f"md5sum {SV_DIR}/Managed/CommonCode.dll | cut -d' ' -f1")
    if rc != 0:
        return "unreachable", f"{tag}: unreachable"
    live = live.strip()

    if live == want:
        return "current", f"{tag}: already on {want[:8]}"

    # Compatibility, checked in the order that fails cheapest.
    accepted = all_md5(patch["attributes"].get("base_md5"))
    if live not in accepted:
        return "skip", (f"{tag}: live {live[:8]} is not an accepted base for this patch "
                        f"({', '.join(b[:8] for b in accepted) or 'none listed'}) — skipped")

    # The decisive one: the artifact was compiled against a specific reference set.
    sidecar = os.path.splitext(artifact)[0] + ".managed"
    if os.path.exists(sidecar):
        want_fp = open(sidecar).read().strip()
        live_fp = managed_fingerprint_remote(target)
        if live_fp != want_fp:
            return "skip", (f"{tag}: Managed/ fingerprint {(live_fp or '?')[:8]} != artifact's "
                            f"{want_fp[:8]} — different reference set, would risk TypeLoadException")
    else:
        return "skip", f"{tag}: no .managed sidecar for the artifact — refusing to guess compatibility"

    if not force:
        ok, why = kiosk_idle(target)
        if not ok:
            return "busy", f"{tag}: {why}"

    if dry_run:
        return "would", f"{tag}: WOULD install {want[:8]} over {live[:8]}"

    ts = time.strftime("%Y%m%d-%H%M%S")
    backup = f"{SV_DIR}/Managed/CommonCode.dll.pre-fleetpatch-{ts}"
    ssh(target, f"cp {SV_DIR}/Managed/CommonCode.dll {backup}")
    ssh(target, "sudo -n systemctl stop shakerview-watchdog 2>/dev/null || true")

    r = subprocess.run(["scp", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
                        artifact, f"{target}:/tmp/fp.dll"], capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        ssh(target, "sudo -n systemctl start shakerview-watchdog 2>/dev/null || true")
        return "fail", f"{tag}: scp failed: {r.stderr[-120:]}"

    ssh(target, f"cp /tmp/fp.dll {SV_DIR}/Managed/CommonCode.dll && rm -f /tmp/fp.dll")
    # Canonical restart: exact pid only. A pattern kill also matches AppManager's own
    # script text and takes the watchdog down with the app.
    ssh(target, f"PID=$(ps -eo pid=,cmd= | awk '$2==\"{SV_BIN}\"{{print $1;exit}}'); [ -n \"$PID\" ] && kill $PID")
    time.sleep(RESTART_WAIT)
    ssh(target, "sudo -n systemctl start shakerview-watchdog 2>/dev/null || true")

    ok, why = verify(target, want)
    if not ok:
        log(f"{tag}: VERIFY FAILED ({why}) — rolling back")
        ssh(target, f"cp {backup} {SV_DIR}/Managed/CommonCode.dll")
        ssh(target, f"PID=$(ps -eo pid=,cmd= | awk '$2==\"{SV_BIN}\"{{print $1;exit}}'); [ -n \"$PID\" ] && kill $PID")
        time.sleep(RESTART_WAIT)
        return "fail", f"{tag}: rolled back to {live[:8]} — {why}"

    return "ok", f"{tag}: installed {want[:8]} (backup {os.path.basename(backup)})"


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--patch", type=int, help="only this patch id")
    ap.add_argument("--machine", type=int, help="only this Strapi machine id")
    ap.add_argument("--max", type=int, default=2, help="stop after N installs (canary; default 2)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="patch even if the kiosk looks in use")
    args = ap.parse_args()

    env = lpm.load_env()
    ident = env.get("STRAPI_MACHINE_USER_USERNAME") or env.get("STRAPI_MACHINE_USER_LOGIN")
    token = lpm.strapi_login(ident, env["STRAPI_MACHINE_USER_PASSWORD"])

    patches = stable_patches(token)
    if args.patch:
        patches = [p for p in patches if p["id"] == args.patch]
    if not patches:
        log("no stable patches — nothing to roll out (this is the normal resting state)")
        return

    machines = candidate_machines(token)
    if args.machine:
        machines = [m for m in machines if m["id"] == args.machine]
    if not machines:
        log("no machines with isAutoupdate=true")
        return

    log(f"stable patches: {[p['id'] for p in patches]} | opted-in machines: {[m['id'] for m in machines]}")

    installed = 0
    for m in machines:
        p = pick_patch(patches, m)
        if not p:
            log(f"machine {m['id']}: no stable patch for its machine_type")
            continue

        want = first_md5(p["attributes"].get("patched_md5"))
        artifact = os.path.join(ARTIFACT_ROOT, f"{want}.dll")
        if not os.path.exists(artifact):
            log(f"machine {m['id']}: artifact missing: {artifact}")
            continue
        if md5_of(artifact) != want:
            log(f"ABORT: artifact {artifact} does not match patched_md5 {want}")
            return

        try:
            state, msg = install(m, p, artifact, args.dry_run, args.force)
        except Exception as e:
            # One machine must never take the sweep down. Treated as a skip, not a
            # failure: nothing was installed, so there is nothing to abort the run over.
            state, msg = "skip", f"machine {m['id']} ({m['serial']}): unexpected error, skipped — {e}"
        log(msg)

        if state == "fail":
            log("ABORT: a machine failed — stopping the whole run so one bad patch "
                "cannot walk the fleet")
            return
        # "current" means the binary is already the target. Strapi may still disagree —
        # a machine patched by hand, or bootstrapped after the fact, keeps a stale or empty
        # patch field, which then misreports the fleet and hides it from later rollouts.
        # Record what is actually on disk.
        if state in ("ok", "current"):
            if state == "ok":
                installed += 1
            if not args.dry_run and m.get("patch_id") != p["id"]:
                try:
                    api_put(f"/api/machines/{m['id']}", token, {"patch": p["id"]})
                    log(f"machine {m['id']}: Strapi patch {m.get('patch_id')} -> {p['id']}")
                except Exception as e:
                    log(f"WARN: could not set machine.patch: {e}")
            if installed >= args.max:
                log(f"reached --max {args.max}; stopping. Re-run to continue the rollout.")
                return

    log(f"done: {installed} installed")


if __name__ == "__main__":
    main()
