#!/usr/bin/env python3
"""
load_product_media.py — sync PRODUCT media (client-authored catalog) for ONE machine
onto its ShakerView Media tree, in the exact layout ShakerView expects. Sibling of
load_strapi_media.py (which syncs the global brands/tastes/cups collections); this one
follows the machine's OWN catalog scoping — the same rule as GET /api/machines/:serial/catalog:
machine.product_lines assignment first, else all active lines of the machine's client's users.

PER-PRODUCT MEDIA (visual precedence, matches the catalog controller / portal):
    main   = product.custom_main            else product.taste.main
    circle = product.custom_circle.images[0] else taste.default_circle.images[0]
    splash = product.custom_splash.images    else taste.default_splash.images
The product's mediaKey = product.media_key || custom_main filename stem || taste.main stem
|| slug(name) — same derivation as the catalog controller, so the files land exactly where
the machine will look for them:
    Tastes/<key>/<key>.png
    Tastes/<key>/cicle-<key>.png
    Tastes/<key>/<key>_splash/taste-<key>_NN.png
    CompanyLogos/<brandKey>-logo.png              (brandKey = logo stem sans -logo, as in catalog)
    Cups/<cupKey>/cup-<cupKey>.png + Cups/<cupKey>/<cupKey>_splash/<cupKey>_splash_NN.png

USAGE
    # stage only (inspect what would change):
    python3 load_product_media.py --machine 62 --stage ./_pm_stage

    # stage + push (key auth; add --password 123 for password auth) + restart app:
    python3 load_product_media.py --machine 62 --stage ./_pm_stage --push auto --restart

    --machine takes a Strapi machine id or a serial_number. --push auto reads
    ssh_user/tailscale_ip from the machine record (default user "shaker").

ENV: STRAPI_BASE_URL (default https://admin.ishaker.xyz; use http://localhost:1338 on the
     Strapi box), creds from ~/Desktop/credentials/.env. NOTE: this Strapi instance only
     accepts the USERNAME identifier form — STRAPI_MACHINE_USER_USERNAME is preferred.
Push overwrites files & creates dirs; never deletes extras.
"""
import argparse, json, os, re, shutil, subprocess, sys, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

STRAPI = os.environ.get("STRAPI_BASE_URL", "https://admin.ishaker.xyz")
SV_MEDIA = "/home/shaker/ShakerView2.0Linux/ShakerView2.0_Data/Media"
UA = "Mozilla/5.0 (X11; Linux x86_64) load_product_media/1.0"
VALID_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")


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


def unwrap(rel):
    """Strapi v4 relation/media: {'data': {...}|[...]|None} -> attributes dict/list (id merged)."""
    if rel is None:
        return None
    data = rel.get("data") if isinstance(rel, dict) and "data" in rel else rel
    if data is None:
        return None
    if isinstance(data, list):
        return [dict(d["attributes"], id=d["id"]) for d in data]
    return dict(data["attributes"], id=data["id"])


def stem(name):
    return re.sub(r"\.[^.]+$", "", name or "").strip()


def slug(name):
    s = re.sub(r"\s+", "-", (name or "").lower().strip())
    return re.sub(r"[^a-z0-9_-]", "", s)


def frame_num(name, fallback_idx):
    m = re.search(r"_(\d+)\.(png|jpg|jpeg)$", name or "", re.I)
    return f"{int(m.group(1)):02d}" if m else f"{fallback_idx:02d}"


def product_key(p):
    if p.get("media_key"):
        return p["media_key"]
    main = unwrap(p.get("custom_main"))
    if main and main.get("name"):
        return stem(main["name"])
    taste = unwrap(p.get("taste"))
    if taste:
        tmain = unwrap(taste.get("main"))
        if tmain and tmain.get("name"):
            return stem(tmain["name"])
    return slug(p.get("name"))


def cup_key(cup):
    if not cup:
        return None
    ds = unwrap(cup.get("default_splash"))
    frames = unwrap(ds.get("images")) if ds else None
    if frames:
        m = re.match(r"^(.+?)_splash_\d+", frames[0]["name"], re.I)
        if m and VALID_KEY.match(m.group(1)):
            return m.group(1)
    img = unwrap(cup.get("image"))
    if img and img.get("name"):
        k = re.sub(r"^cup-", "", stem(img["name"]))
        if VALID_KEY.match(k):
            return k
    return slug(cup.get("name"))


LINE_POPULATE = urllib.parse.quote(
    "populate[cup][populate][image]=true&populate[cup][populate][default_splash][populate][images]=true"
    "&populate[custom_splash][populate][images]=true"
    "&populate[brands][populate][logo]=true"
    "&populate[products][populate][taste][populate][main]=true"
    "&populate[products][populate][taste][populate][default_splash][populate][images]=true"
    "&populate[products][populate][taste][populate][default_circle][populate][images]=true"
    "&populate[products][populate][custom_splash][populate][images]=true"
    "&populate[products][populate][custom_circle][populate][images]=true"
    "&populate[products][populate][custom_main]=true", safe="=&[]")


def machine_lines(token, machine_arg):
    """Resolve machine (id or serial) -> (machine attrs, [line entries fully populated])."""
    if re.fullmatch(r"\d+", str(machine_arg)):
        m = api(f"/api/machines/{machine_arg}?populate[product_lines][fields][0]=id"
                f"&populate[client][fields][0]=id", token)["data"]
    else:
        q = urllib.parse.quote(str(machine_arg))
        d = api(f"/api/machines?filters[serial_number][$eq]={q}"
                f"&populate[product_lines][fields][0]=id&populate[client][fields][0]=id", token)["data"]
        if not d:
            sys.exit(f"no machine for serial {machine_arg}")
        m = d[0]
    ma = dict(m["attributes"], id=m["id"])
    assigned = unwrap(ma.get("product_lines")) or []
    lines = []
    if assigned:
        for l in assigned:
            full = api(f"/api/product-lines/{l['id']}?{LINE_POPULATE}", token)["data"]
            lines.append(dict(full["attributes"], id=full["id"]))
    else:
        client = unwrap(ma.get("client"))
        if not client:
            sys.exit("machine has no assigned product lines and no client — nothing to sync")
        d = api(f"/api/product-lines?filters[author][client][id][$eq]={client['id']}"
                f"&filters[is_template][$ne]=true&pagination[pageSize]=200&{LINE_POPULATE}", token)["data"]
        lines = [dict(x["attributes"], id=x["id"]) for x in d if x["attributes"].get("isActive") is not False]
    return ma, lines


def collect(lines):
    """-> (items [(rel_path, url)], skips [(label, reason)])"""
    items, skips = [], []
    seen = set()

    def add(rel, url):
        if rel not in seen:
            seen.add(rel)
            items.append((rel, url))

    for line in lines:
        if line.get("isActive") is False:
            continue
        brands = unwrap(line.get("brands")) or []
        if brands:
            logo = unwrap(brands[0].get("logo"))
            if logo:
                bkey = re.sub(r"-logo$", "", stem(logo["name"]))
                if VALID_KEY.match(bkey):
                    add(f"CompanyLogos/{bkey}-logo.png", logo["url"])
                else:
                    skips.append((f"brand '{brands[0].get('name')}'", f"bad logo name {logo['name']!r}"))
        cup = unwrap(line.get("cup"))
        ck = cup_key(cup)
        if cup and ck and VALID_KEY.match(ck):
            img = unwrap(cup.get("image"))
            if img:
                add(f"Cups/{ck}/cup-{ck}.png", img["url"])
            # Cup splash frames: the line's own custom_splash overrides the cup's
            # default_splash. Frames go into the cup folder keyed by the CUP key (what
            # the app looks up via Cup.mediaKey), regardless of the source frame names.
            line_spl = unwrap(line.get("custom_splash"))
            line_spl_imgs = unwrap(line_spl.get("images")) if line_spl else None
            ds = unwrap(cup.get("default_splash"))
            splash_imgs = line_spl_imgs or (unwrap(ds.get("images")) if ds else None) or []
            for i, f in enumerate(splash_imgs, 1):
                add(f"Cups/{ck}/{ck}_splash/{ck}_splash_{frame_num(f['name'], i)}.png", f["url"])
        elif cup:
            skips.append((f"cup '{cup.get('name')}' (line '{line.get('name')}')", "no clean cup key"))

        for p in unwrap(line.get("products")) or []:
            if p.get("isActive") is False:
                continue
            key = product_key(p)
            if not key or not VALID_KEY.match(key):
                skips.append((f"product '{p.get('name')}'", f"no clean media key ({key!r})"))
                continue
            taste = unwrap(p.get("taste"))
            main = unwrap(p.get("custom_main")) or (unwrap(taste.get("main")) if taste else None)
            if main:
                add(f"Tastes/{key}/{key}.png", main["url"])
            else:
                skips.append((f"product '{p.get('name')}'", "no main image (custom_main or taste.main)"))
            circ = unwrap(p.get("custom_circle")) or (unwrap(taste.get("default_circle")) if taste else None)
            circ_imgs = unwrap(circ.get("images")) if circ else None
            if circ_imgs:
                add(f"Tastes/{key}/cicle-{key}.png", circ_imgs[0]["url"])
            spl = unwrap(p.get("custom_splash")) or (unwrap(taste.get("default_splash")) if taste else None)
            spl_imgs = unwrap(spl.get("images")) if spl else None
            for i, f in enumerate(spl_imgs or [], 1):
                add(f"Tastes/{key}/{key}_splash/taste-{key}_{frame_num(f['name'], i)}.png", f["url"])
    return items, skips


def download(url, dest):
    full = url if url.startswith("http") else f"{STRAPI}{url}"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    req = urllib.request.Request(full, headers={"User-Agent": UA})
    tmp = dest + ".part"
    with urllib.request.urlopen(req, timeout=60) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    os.replace(tmp, dest)


def ssh_cmd(target, password, remote_command):
    cmd = ["ssh", "-o", "StrictHostKeyChecking=accept-new"]
    if password:
        cmd = ["sshpass", "-p", password] + cmd + [
            "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"]
    return cmd + [target, remote_command]


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", required=True, help="Strapi machine id or serial_number")
    ap.add_argument("--stage", required=True, help="local staging dir (mirrors machine Media/ tree)")
    ap.add_argument("--push", help="'auto' (from machine record) or ssh target e.g. shaker@100.90.99.98")
    ap.add_argument("--password", help="ssh password (omit for key auth)")
    ap.add_argument("--restart", action="store_true",
                    help="restart ShakerView after push (single-PID kill; AppManager relaunches)")
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--remote-media", default=SV_MEDIA)
    args = ap.parse_args()

    env = load_env()
    ident = env.get("STRAPI_MACHINE_USER_USERNAME") or env.get("STRAPI_MACHINE_USER_LOGIN")
    pw = env.get("STRAPI_MACHINE_USER_PASSWORD")
    if not ident or not pw:
        sys.exit("Missing Strapi credentials in ~/Desktop/credentials/.env")
    token = strapi_login(ident, pw)
    print(f"Strapi auth OK as {ident}")

    machine, lines = machine_lines(token, args.machine)
    print(f"machine {machine['id']} serial={machine.get('serial_number')} -> {len(lines)} line(s): "
          + ", ".join(repr(l.get('name')) for l in lines))
    items, skips = collect(lines)
    print(f"{len(items)} media files to stage")

    stage = os.path.abspath(args.stage)
    os.makedirs(os.path.join(stage, "Media"), exist_ok=True)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = [pool.submit(download, url, os.path.join(stage, "Media", rel)) for rel, url in items]
        for fut in as_completed(futs):
            fut.result()
    for rel, _ in sorted(items):
        print("  ", rel)

    if skips:
        report = os.path.join(stage, "SKIPPED.txt")
        with open(report, "w") as fh:
            for label, reason in skips:
                fh.write(f"{label}: {reason}\n")
        print(f"⚠ SKIPPED {len(skips)} item(s) — see {report}")
        for label, reason in skips[:10]:
            print(f"   - {label}: {reason}")

    if not args.push:
        print("\nDry stage only (no --push).")
        return

    target = args.push
    if target == "auto":
        user = machine.get("ssh_user") or "shaker"
        ip = machine.get("tailscale_ip")
        if not ip:
            sys.exit("machine record has no tailscale_ip; pass --push user@ip explicitly")
        target = f"{user}@{ip}"

    remote_parent = os.path.dirname(args.remote_media.rstrip("/"))
    print(f"\nPushing to {target}:{args.remote_media} (overwrite in place)…")
    tar = subprocess.Popen(["tar", "-C", stage, "-cf", "-", "Media"], stdout=subprocess.PIPE)
    rc = subprocess.run(ssh_cmd(target, args.password, f"tar -C {shell_quote(remote_parent)} -xf -"),
                        stdin=tar.stdout).returncode
    tar.stdout.close()
    tar.wait()
    if rc != 0:
        sys.exit(f"Push failed (ssh/tar rc={rc})")
    print("Push complete.")

    if args.restart:
        # Canonical restart: kill the specific ShakerView PID; AppManager relaunches in ~15 s.
        # NEVER pattern-kill (team rule) — identify by comm, not pgrep -f.
        rcmd = ("PID=$(ps -eo pid,comm | awk '$2 ~ /^ShakerView2.0/ {print $1}'); "
                "echo \"pid=$PID\"; [ -n \"$PID\" ] && kill $PID && echo restarted")
        subprocess.run(ssh_cmd(target, args.password, rcmd))


if __name__ == "__main__":
    main()
