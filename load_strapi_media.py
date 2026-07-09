#!/usr/bin/env python3
"""
load_strapi_media.py — sync Strapi brands / tastes / cups media onto a ShakerView
machine's Media tree, in the exact layout ShakerView expects, OVERWRITING existing images.

WHY THE FILENAME IS AUTHORITATIVE
    Every Strapi upload's `name` attribute already carries the exact on-machine filename
    (taste main "apple-pie.png", taste splash "taste-apple-pie_01.png", brand
    "AllNutrition-logo.png", cup splash "recover_splash_01.png"). ShakerView keys media by
    that name, so we never slug a display name — we place each file by its own filename and
    derive its folder from that filename. This is why cup "Amino Recover" lands in Cups/recover/.

MACHINE LAYOUT (…/ShakerView2.0_Data/Media/)
    Tastes/<key>/<key>.png                     <- taste.main         (key = main filename stem)
    Tastes/<key>/<key>_splash/taste-<key>_NN.png  <- taste.splash
    CompanyLogos/<name>-logo.png               <- brand.logo         (flat dir)
    Cups/<key>/<key>_splash/<key>_splash_NN.png   <- cup.splash       (key = "<key>_splash_NN.png" prefix)
  NOT sourced from Strapi (left untouched): taste cicle-<key>.png, cup main cup-<key>.png.

USAGE
    # stage everything into a local dir and show what WOULD change (no machine touched):
    python3 load_strapi_media.py --stage ./_media_stage

    # stage, then push to the golden/target machine, overwriting in place:
    python3 load_strapi_media.py --stage ./_media_stage --push shaker@100.112.118.51 --password 123

    # limit while testing:
    python3 load_strapi_media.py --stage ./_media_stage --only tastes --limit 5

ENV: reads STRAPI_MACHINE_USER_LOGIN / STRAPI_MACHINE_USER_PASSWORD from ~/Desktop/credentials/.env
     (or --identifier/--password-strapi). Push overwrites files & creates dirs; never deletes extras.
"""
import argparse, os, re, subprocess, sys, urllib.parse, urllib.request, json, shutil
from concurrent.futures import ThreadPoolExecutor, as_completed

STRAPI = os.environ.get("STRAPI_BASE_URL", "https://admin.ishaker.xyz")
SV_MEDIA = "/home/shaker/ShakerView2.0Linux/ShakerView2.0_Data/Media"  # remote root
# admin.ishaker.xyz sits behind Cloudflare, which 403s urllib's default UA — send a real one.
UA = "Mozilla/5.0 (X11; Linux x86_64) load_strapi_media/1.0"


def load_env(path=os.path.expanduser("~/Desktop/credentials/.env")):
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def api(path, token):
    req = urllib.request.Request(f"{STRAPI}{path}",
                                 headers={"Authorization": f"Bearer {token}", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def strapi_login(identifier, password):
    body = json.dumps({"identifier": identifier, "password": password}).encode()
    req = urllib.request.Request(f"{STRAPI}/api/auth/local", data=body,
                                 headers={"Content-Type": "application/json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["jwt"]


def all_entries(collection, token, populate, limit=None):
    """Yield every entry across pages."""
    page, size, seen = 1, 100, 0
    while True:
        d = api(f"/api/{collection}?populate={populate}"
                f"&pagination[page]={page}&pagination[pageSize]={size}", token)
        for e in d.get("data", []):
            yield e
            seen += 1
            if limit and seen >= limit:
                return
        pg = d.get("meta", {}).get("pagination", {})
        if page >= pg.get("pageCount", 1):
            return
        page += 1


# A ShakerView mediaKey is a slug used as a directory name: letters/digits/_/-, no spaces,
# no " copy", no unicode. Anything else would create a junk folder on every clone, so we skip it.
VALID_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")

# Brand logos are the one collection whose Strapi `key` convention (e.g. "lock-in") can differ from
# the machine's config mediaKey (e.g. "lock_in"), so a `<key>-logo.png` file wouldn't be found by
# ShakerView. When pushing, we list the machine's EXISTING CompanyLogos filenames and match each
# brand to one by a normalized key (lowercase, alphanumerics only), preserving the machine's name.
REMOTE_BRAND_MAP = {}  # norm(existing-logo-stem) -> actual "<name>-logo.png" on the machine


def norm_key(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def build_remote_brand_map(push, password, remote_media):
    cmd = ["ssh", "-o", "StrictHostKeyChecking=accept-new", "-o", "PreferredAuthentications=password",
           "-o", "PubkeyAuthentication=no", push, f"ls {remote_media}/CompanyLogos 2>/dev/null"]
    if password:
        cmd = ["sshpass", "-p", password] + cmd
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return {}
    m = {}
    for fn in out.split():
        if fn.endswith("-logo.png"):
            m[norm_key(fn[:-len("-logo.png")])] = fn
    return m


def media_list(attr_field):
    """Normalize a Strapi media field (single or multiple) to a list of {name,url}."""
    data = (attr_field or {}).get("data")
    if not data:
        return []
    if isinstance(data, dict):
        data = [data]
    return [{"name": m["attributes"]["name"], "url": m["attributes"]["url"]} for m in data]


def frame_num(name):
    """Trailing _NN before .png, zero-padded to 2. None if absent."""
    m = re.search(r"_(\d+)\.png$", name, re.I)
    return f"{int(m.group(1)):02d}" if m else None


def clean_stem(name):
    return re.sub(r"\.png$", "", name, flags=re.I).strip()


def target_paths(collection, entry):
    """Return (items, skips) for one entry.
    items = list of (relative_media_path, url); paths NORMALIZED to ShakerView convention so a
    corrupt Strapi filename ("mango-peach copy.png") still lands correctly. skips = list of
    (label, reason) for media we refuse to place because no clean mediaKey could be derived.
    """
    a = entry["attributes"]
    items, skips = [], []

    if collection == "brands":
        key = (a.get("key") or "").strip()
        logos = media_list(a.get("logo"))
        if not key:  # fall back to logo filename stem sans -logo
            key = re.sub(r"-logo$", "", clean_stem(logos[0]["name"])) if logos else ""
        if not VALID_KEY.match(key or ""):
            for m in logos:
                skips.append((f"brand '{a.get('name')}'", f"bad key {key!r} (logo {m['name']!r})"))
            return items, skips
        # Prefer the machine's existing filename (matched by normalized key) so ShakerView, which
        # looks up "<config-mediaKey>-logo.png", actually finds it. Fall back to "<key>-logo.png".
        fname = REMOTE_BRAND_MAP.get(norm_key(key)) or REMOTE_BRAND_MAP.get(norm_key(a.get("name")))
        if not fname:
            fname = f"{key}-logo.png"
        for m in logos:  # brands are single-logo, but iterate defensively
            items.append((f"CompanyLogos/{fname}", m["url"]))

    elif collection == "tastes":
        mains = media_list(a.get("main"))
        splash = media_list(a.get("splash"))
        # Prefer main-stem key; if corrupt, derive from a splash frame (taste-<key>_NN.png).
        key = clean_stem(mains[0]["name"]) if mains else ""
        if not VALID_KEY.match(key) and splash:
            mm = re.match(r"^taste-(.+?)_\d+\.png$", splash[0]["name"], re.I)
            if mm and VALID_KEY.match(mm.group(1)):
                key = mm.group(1)
        if not VALID_KEY.match(key or ""):
            skips.append((f"taste '{a.get('name')}'", f"no clean key (main {mains[0]['name'] if mains else None!r})"))
            return items, skips
        for m in mains:  # main image is always saved as <key>.png (ShakerView requirement)
            items.append((f"Tastes/{key}/{key}.png", m["url"]))
        for m in splash:  # normalize frame name & number; keep the source frame index
            nn = frame_num(m["name"])
            if nn is None:
                skips.append((f"taste '{a.get('name')}' splash", f"no frame number in {m['name']!r}"))
                continue
            items.append((f"Tastes/{key}/{key}_splash/taste-{key}_{nn}.png", m["url"]))

    elif collection == "cups":
        splash = media_list(a.get("splash"))
        # cup key = prefix of "<key>_splash_NN.png"; reject anything else (e.g. taste-* placeholders)
        key = ""
        for m in splash:
            mm = re.match(r"^(.+?)_splash_\d+\.png$", m["name"], re.I)
            if mm and VALID_KEY.match(mm.group(1)):
                key = mm.group(1)
                break
        if not VALID_KEY.match(key or ""):
            if splash:
                skips.append((f"cup '{a.get('name')}'", f"frames not <key>_splash_NN (e.g. {splash[0]['name']!r})"))
            return items, skips
        for m in splash:
            nn = frame_num(m["name"])
            if nn is None:
                skips.append((f"cup '{a.get('name')}' splash", f"no frame number in {m['name']!r}"))
                continue
            items.append((f"Cups/{key}/{key}_splash/{key}_splash_{nn}.png", m["url"]))

    return items, skips


def download(url, dest, resume=True):
    if resume and os.path.exists(dest) and os.path.getsize(dest) > 0:
        return "skip"
    full = url if url.startswith("http") else f"{STRAPI}{url}"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    req = urllib.request.Request(full, headers={"User-Agent": UA})
    tmp = dest + ".part"
    with urllib.request.urlopen(req, timeout=60) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    os.replace(tmp, dest)  # atomic — a half-written file never looks "done" to --resume
    return "get"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", required=True, help="local staging dir (mirrors machine Media/ tree)")
    ap.add_argument("--push", help="ssh target e.g. shaker@100.112.118.51 (omit to only stage)")
    ap.add_argument("--password", help="ssh password for --push (uses sshpass)")
    ap.add_argument("--identifier", help="Strapi identifier (else from .env)")
    ap.add_argument("--password-strapi", help="Strapi password (else from .env)")
    ap.add_argument("--only", choices=["brands", "tastes", "cups"], help="one collection only")
    ap.add_argument("--limit", type=int, help="max entries per collection (testing)")
    ap.add_argument("--workers", type=int, default=16, help="concurrent downloads")
    ap.add_argument("--remote-media", default=SV_MEDIA, help="remote Media/ root")
    args = ap.parse_args()

    env = load_env()
    ident = args.identifier or env.get("STRAPI_MACHINE_USER_LOGIN")
    pw = args.password_strapi or env.get("STRAPI_MACHINE_USER_PASSWORD")
    if not ident or not pw:
        sys.exit("Missing Strapi credentials (set --identifier/--password-strapi or ~/Desktop/credentials/.env)")
    token = strapi_login(ident, pw)
    print(f"Strapi auth OK as {ident}")

    fields = {"brands": "logo", "tastes": "*", "cups": "splash"}
    collections = [args.only] if args.only else ["brands", "tastes", "cups"]

    # Match brand logos to the machine's existing CompanyLogos filenames (fixes lock-in vs lock_in).
    if args.push and "brands" in collections:
        global REMOTE_BRAND_MAP
        REMOTE_BRAND_MAP = build_remote_brand_map(args.push, args.password, args.remote_media)
        print(f"Matched brand filenames against {len(REMOTE_BRAND_MAP)} existing machine logos")

    stage = os.path.abspath(args.stage)
    os.makedirs(os.path.join(stage, "Media"), exist_ok=True)
    counts = {}
    all_skips = []
    tasks = []  # (collection, dest, url)
    for coll in collections:
        n_ent = 0
        for entry in all_entries(coll, token, fields[coll], args.limit):
            n_ent += 1
            items, skips = target_paths(coll, entry)
            all_skips += skips
            for rel, url in items:
                tasks.append((coll, os.path.join(stage, "Media", rel), url))
        counts[coll] = [n_ent, sum(1 for t in tasks if t[0] == coll)]
        print(f"[{coll}] {n_ent} entries -> {counts[coll][1]} media files")

    # Download concurrently (TLS handshake per file dominates; parallelism is the whole win).
    print(f"\nDownloading {len(tasks)} files with {args.workers} workers (resume=on)…")
    done = got = 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = {pool.submit(download, url, dest): dest for _, dest, url in tasks}
        for fut in as_completed(futs):
            fut.result()  # re-raise download errors
            done += 1
            if done % 500 == 0:
                print(f"  …{done}/{len(tasks)}")

    print("\nStaged under:", os.path.join(stage, "Media"))
    for coll, (e, f) in counts.items():
        print(f"  {coll}: {e} entries, {f} files")

    if all_skips:
        report = os.path.join(stage, "SKIPPED.txt")
        with open(report, "w") as fh:
            fh.write("Media SKIPPED — corrupt/ambiguous Strapi filenames (fix in Strapi admin):\n\n")
            for label, reason in all_skips:
                fh.write(f"  {label}: {reason}\n")
        print(f"\n⚠ SKIPPED {len(all_skips)} item(s) with bad Strapi data — see {report}")
        for label, reason in all_skips[:20]:
            print(f"   - {label}: {reason}")

    if not args.push:
        print("\nDry stage only (no --push). Inspect the staged tree, then re-run with "
              "--push shaker@<ip> --password <pw> to overwrite on the machine.")
        return

    # Stream the staged Media/ subtree onto the machine, overwriting files, creating dirs,
    # NOT deleting anything already there. tar avoids an rsync dependency on the box.
    remote_parent = os.path.dirname(args.remote_media.rstrip("/"))
    print(f"\nPushing to {args.push}:{args.remote_media} (overwrite in place)…")
    tar = subprocess.Popen(["tar", "-C", stage, "-cf", "-", "Media"], stdout=subprocess.PIPE)
    ssh_cmd = ["ssh", "-o", "StrictHostKeyChecking=accept-new",
               "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
               args.push, f"tar -C {shell_quote(remote_parent)} -xf -"]
    if args.password:
        ssh_cmd = ["sshpass", "-p", args.password] + ssh_cmd
    rc = subprocess.run(ssh_cmd, stdin=tar.stdout).returncode
    tar.stdout.close()
    tar.wait()
    if rc == 0:
        print("Push complete — Strapi media overwritten on machine.")
    else:
        sys.exit(f"Push failed (ssh/tar rc={rc})")


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


if __name__ == "__main__":
    main()
