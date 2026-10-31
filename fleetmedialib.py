#!/usr/bin/env python3
"""FleetMediaLib — keep the WHOLE Strapi media library on every online machine, in advance.

FleetPulse only delivers the art of the products a machine currently stocks, and only right
after the catalog changes (then restarts the kiosk). Anything else the kiosk can be pointed
at — a cup picked in the portal, the on-machine Change Drinks library, a machine outside the
sweep set, a machine that was offline when the change was made — showed up as a white tile
until somebody pushed the art by hand (koala 147, 28.09.2026: 57 of 95 cups missing).

This pass closes that: every cup, taste and brand logo in Strapi — everything the portal
lets you pick for a product — is staged once here and topped up on every ONLINE machine.

Rules:
  * Keys come from load_product_media.collect() — the same derivation FleetPulse and the
    Strapi controller use, so the folder the kiosk asks for is the folder we write.
  * ADD-ONLY. A file already on the machine is never replaced — it may be factory art or a
    per-machine push by FleetPulse. The one exception is a file THIS script delivered whose
    size no longer matches (a transfer torn on a flapping link): that one is re-sent.
  * Every pushed file is md5-verified on the machine; a file is recorded as delivered only
    after it verified, so anything that failed is retried on the next run.
  * FleetPulse owns what a machine actually sells. Any file FleetPulse stages for that
    machine, and every frame in a splash folder it stages, is left alone here: the cup's
    default splash must never overwrite (or re-add frames to) the line splash picked in
    the portal. ankara 108, 31.10.2026: this pass put the cup's "Apple" splash back over
    the line's "Color hot pink" every hour, and FleetPulse put it back again.
  * Never restarts the kiosk. The art is there before anyone needs it; FleetPulse restarts
    the app anyway whenever a catalog change makes a machine start using it.
  * Machines in fleet_manual.txt are skipped, like every other fleet pass.

Cron: ~/fleetmedialib_cron.sh (hourly). Log: ~/fleetmedia/fleetmedialib.log.
"""
import argparse, hashlib, importlib.util, io, json, os, subprocess, sys, tarfile, time, urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

os.environ.setdefault("STRAPI_BASE_URL", "http://localhost:1338")
SCRIPTS = os.path.dirname(os.path.abspath(__file__))


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, fname))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


lpm = _load("lpm", "load_product_media.py")
fleet_manual = _load("fleet_manual", "fleet_manual.py")

HOME = os.path.expanduser("~/fleetmedia")
LIB = os.path.join(HOME, "library")               # mirrors machine Media/
INDEX = os.path.join(HOME, "library.json")        # rel -> {url, size, md5}
STATE = os.path.join(HOME, "delivered")           # <machine id>.json: rel -> md5 we delivered
MEDIA = lpm.SV_MEDIA
DIRS = ("Cups", "Tastes", "CompanyLogos")
CHUNK_BYTES = 8 * 1024 * 1024                     # small tars: a torn chunk costs little
DISK_RESERVE_KB = 1024 * 1024                     # leave 1 GB free on the machine
PULSE_STATE = os.path.expanduser(os.environ.get("FLEETPULSE_STATE", "~/fleetpulse/state"))


def pulse_owned(machine_id):
    """(rels, splash dirs) FleetPulse stages for this machine — off limits for this pass."""
    root = os.path.join(PULSE_STATE, str(machine_id), "media-stage", "Media")
    rels, dirs = set(), set()
    for d, _, files in os.walk(root):
        for f in files:
            rel = os.path.relpath(os.path.join(d, f), root)
            rels.add(rel)
            if os.path.basename(d).endswith("_splash"):
                dirs.add(os.path.dirname(rel))
    return rels, dirs


def log(msg):
    print(msg, flush=True)


def all_pages(path, token, size=100):
    out, page = [], 1
    sep = "&" if "?" in path else "?"
    while True:
        d = lpm.api(f"{path}{sep}pagination[page]={page}&pagination[pageSize]={size}", token)
        out += d["data"]
        meta = (d.get("meta") or {}).get("pagination") or {}
        if page >= (meta.get("pageCount") or 1):
            return out
        page += 1


def library_items(token):
    """[(rel, url)] for everything the kiosk could be asked to draw."""
    # Small pages: every entry drags its splash frames along, and a big populate stalls prod
    # Strapi for every client (a 100-line product-lines populate froze /_health for ~17 s).
    cups = all_pages("/api/cups?populate[image]=true"
                     "&populate[default_splash][populate][images]=true", token, size=20)
    tastes = all_pages("/api/tastes?populate[main]=true"
                       "&populate[default_splash][populate][images]=true"
                       "&populate[default_circle][populate][images]=true", token, size=20)
    brands = all_pages("/api/brands?populate[logo]=true", token, size=50)
    # Library entries go through collect() as synthetic lines, so they get exactly the keys
    # a real line holding them would get. One line per cup: collect() applies a line-level
    # splash override only to single-cup lines, and these carry none, so nothing is lost.
    # Product-specific art (custom_main/custom_splash, media_key) is NOT library: it belongs
    # to one client's product and FleetPulse delivers it to that product's machines.
    synth = [{"name": f"lib:cup:{c['id']}", "cups": {"data": [c]}, "products": {"data": []}}
             for c in cups]
    synth.append({"name": "lib:brands", "brands": {"data": brands}, "cups": {"data": []},
                  "products": {"data": [{"id": -t["id"], "attributes": {
                      "name": t["attributes"].get("name"), "taste": {"data": t}}} for t in tastes]}})
    items, _ = lpm.collect(synth)
    return [(rel, url) for rel, url in items if rel.split("/", 1)[0] in DIRS]


def md5_file(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


FINGERPRINT_COLLECTIONS = ("cups", "tastes", "brands", "splashes", "circles")
FINGERPRINT = os.path.join(HOME, "fingerprint.json")


def fingerprint(token):
    """count + newest updatedAt of every collection the library is built from. Five one-row
    queries — cheap enough to run every hour, unlike the populated listing."""
    fp = {}
    for c in FINGERPRINT_COLLECTIONS:
        d = lpm.api(f"/api/{c}?fields[0]=updatedAt&sort=updatedAt:desc&pagination[pageSize]=1", token)
        fp[c] = [d["meta"]["pagination"]["total"],
                 d["data"][0]["attributes"]["updatedAt"] if d["data"] else None]
    return fp


def stage(token, workers=4):
    """Download new/changed library files. Strapi upload URLs carry a content hash, so an
    unchanged URL means an unchanged file and is never fetched again. The populated listing
    itself only runs when the collections' fingerprint moved. Few download workers: the
    uploads are served by prod Strapi itself."""
    old = json.load(open(INDEX)) if os.path.exists(INDEX) else {}
    fp = fingerprint(token)
    if old and os.path.exists(FINGERPRINT) and json.load(open(FINGERPRINT)) == fp \
            and all(os.path.exists(os.path.join(LIB, r)) for r in old):
        log(f"library: unchanged in Strapi, {len(old)} files")
        return old
    items = library_items(token)
    new, todo = {}, []
    for rel, url in items:
        dest = os.path.join(LIB, rel)
        o = old.get(rel)
        if o and o["url"] == url and os.path.exists(dest) and os.path.getsize(dest) == o["size"]:
            new[rel] = o
        else:
            todo.append((rel, url))

    def fetch(rel, url):
        dest = os.path.join(LIB, rel)
        lpm.download(url, dest)
        return rel, {"url": url, "size": os.path.getsize(dest), "md5": md5_file(dest)}

    failed = 0
    with ThreadPoolExecutor(workers) as ex:
        for fut in as_completed([ex.submit(fetch, r, u) for r, u in todo]):
            try:
                rel, meta = fut.result()
                new[rel] = meta
            except Exception as e:
                failed += 1
                log(f"stage: download failed: {e}")
    tmp = INDEX + ".tmp"
    json.dump(new, open(tmp, "w"), indent=0, sort_keys=True)
    os.replace(tmp, INDEX)
    if not failed:                                # a failed fetch must re-list next run
        json.dump(fp, open(FINGERPRINT, "w"))
    log(f"library: {len(new)} files ({sum(m['size'] for m in new.values()) >> 20} MB), "
        f"{len(todo) - failed} fetched, {failed} failed")
    return new


def ssh(target, cmd, timeout=120, stdin=None):
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes",
                        "-o", "StrictHostKeyChecking=accept-new", target, cmd],
                       input=stdin, capture_output=True, timeout=timeout)
    return r.returncode, r.stdout.decode(errors="replace"), r.stderr.decode(errors="replace")


def online_ips():
    st = json.loads(subprocess.run(["tailscale", "status", "--json"],
                                   capture_output=True, text=True, timeout=30).stdout)
    ips = set()
    for p in (st.get("Peer") or {}).values():
        if p.get("Online"):
            ips.update(p.get("TailscaleIPs") or [])
    return ips


def machines(token):
    rows = all_pages("/api/machines?fields[0]=name&fields[1]=tailscale_ip"
                     "&fields[2]=ssh_user&fields[3]=serial_number", token)
    out = [{"id": r["id"], "name": r["attributes"].get("name"),
            "serial": r["attributes"].get("serial_number"),
            "ip": r["attributes"].get("tailscale_ip"),
            "user": r["attributes"].get("ssh_user") or "shaker"}
           for r in rows if r["attributes"].get("tailscale_ip")]
    return fleet_manual.filter_rows(out, get_nick=lambda r: r.get("name"), log=log)


def sync_machine(m, index, dry=False):
    tag = f"machine {m['id']} ({m['name'] or m['serial']})"
    target = f"{m['user']}@{m['ip']}"
    rc, out, err = ssh(target, f"cd {MEDIA} 2>/dev/null || exit 7; "
                               f"df -Pk . | awk 'NR==2{{print \"AVAIL\", $4}}'; "
                               f"find {' '.join(DIRS)} -type f -printf '%s %p\\n' 2>/dev/null; true")
    if rc == 7:
        return f"{tag}: no Media/ dir — not a kiosk, skipped"
    if rc != 0:
        return f"{tag}: ssh failed ({(err or '').strip()[:80]})"
    have, avail = {}, 0
    for ln in out.splitlines():
        a, _, b = ln.partition(" ")
        if a == "AVAIL":
            avail = int(b)
        elif b:
            have[b] = int(a)

    spath = os.path.join(STATE, f"{m['id']}.json")
    delivered = json.load(open(spath)) if os.path.exists(spath) else {}
    owned, owned_dirs = pulse_owned(m["id"])
    need = []
    for rel, meta in index.items():
        if rel in owned or os.path.dirname(rel) in owned_dirs:
            continue
        size = have.get(rel)
        if size is None or size == 0:
            need.append(rel)
        elif rel in delivered and size != meta["size"]:
            need.append(rel)                      # our own torn transfer — re-send
    if not need:
        return f"{tag}: complete ({len(index)} library files present)"
    total = sum(index[r]["size"] for r in need)
    if dry:
        return f"{tag}: would push {len(need)} files ({total >> 20} MB)"
    if avail * 1024 - total < DISK_RESERVE_KB * 1024:
        return f"{tag}: SKIPPED — needs {total >> 20} MB, only {avail >> 10} MB free"

    # Chunked tars into Media/. Paths come straight from the library index, never from the
    # machine, so nothing outside Cups/Tastes/CompanyLogos can be written.
    ok, bad, chunk, size, why = 0, 0, [], 0, ""
    chunks = []
    for rel in sorted(need):
        chunk.append(rel)
        size += index[rel]["size"]
        if size >= CHUNK_BYTES:
            chunks.append(chunk)
            chunk, size = [], 0
    if chunk:
        chunks.append(chunk)
    def save():
        os.makedirs(STATE, exist_ok=True)
        json.dump(delivered, open(spath + ".tmp", "w"))
        os.replace(spath + ".tmp", spath)

    def push(ch):
        """-> (verified rels, error or ''). A torn tar may leave a truncated file behind,
        which is why every rel is claimed as ours ("pending") BEFORE it is sent: a claimed
        file whose size is wrong gets re-sent next run, an unclaimed one never would."""
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tf:
            for rel in ch:
                tf.add(os.path.join(LIB, rel), arcname=rel)
        rc, _, err = ssh(target, f"tar -C {MEDIA} --no-same-owner -xf -", timeout=300,
                         stdin=buf.getvalue())
        if rc != 0:
            return [], ((err or "").strip().splitlines() or [f"tar rc={rc}"])[-1][:100]
        rc, out, err = ssh(target, f"cd {MEDIA} && xargs -d '\\n' md5sum",
                           stdin=("\n".join(ch) + "\n").encode())
        got = dict(reversed(ln.split("  ", 1)) for ln in out.splitlines() if "  " in ln)
        good = [r for r in ch if got.get(r) == index[r]["md5"]]
        return good, "" if len(good) == len(ch) else f"md5 mismatch/unverified ({rc})"

    for ch in chunks:
        for rel in ch:
            delivered.setdefault(rel, "pending")
        save()
        good, err = push(ch)
        if err:
            # Flapping link (Matt 20: rc=255 mid-transfer): retry what is left in ~256 KB
            # pieces, twice each, before leaving it to the next run.
            left = [r for r in ch if r not in good]
            sub, subs, sz = [], [], 0
            for rel in left:
                sub.append(rel)
                sz += index[rel]["size"]
                if sz >= 256 * 1024:
                    subs.append(sub)
                    sub, sz = [], 0
            if sub:
                subs.append(sub)
            for piece in subs:
                for attempt in range(2):
                    g, err = push(piece)
                    good += g
                    piece = [r for r in piece if r not in g]
                    if not piece:
                        break
                    time.sleep(3)
                if piece:
                    why = why or err
        for rel in good:
            delivered[rel] = index[rel]["md5"]
        ok += len(good)
        bad += len(ch) - len(set(good))
        save()
    if not bad:
        return f"{tag}: pushed {ok} files ({total >> 20} MB), md5 verified"
    return (f"{tag}: pushed {ok}/{len(need)} files, {bad} FAILED ({why or 'md5 mismatch'})"
            " — retried next run")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="report what would be pushed")
    ap.add_argument("--only", help="comma-separated Strapi machine ids")
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()

    env = lpm.load_env()
    token = lpm.strapi_login(env.get("STRAPI_MACHINE_USER_USERNAME") or env["STRAPI_MACHINE_USER_LOGIN"],
                             env["STRAPI_MACHINE_USER_PASSWORD"])
    os.makedirs(LIB, exist_ok=True)
    index = stage(token)
    live = online_ips()
    ms = machines(token)
    if args.only:
        want = {int(x) for x in args.only.split(",")}
        ms = [m for m in ms if m["id"] in want]
    up = [m for m in ms if m["ip"] in live]
    log(f"machines: {len(ms)} with tailscale_ip, {len(up)} online")
    with ThreadPoolExecutor(args.workers) as ex:
        futs = {ex.submit(sync_machine, m, index, args.dry_run): m for m in up}
        for fut in as_completed(futs):
            try:
                log(fut.result())
            except Exception as e:
                m = futs[fut]
                log(f"machine {m['id']} ({m['name']}): ERROR {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
