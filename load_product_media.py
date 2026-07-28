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


class NothingToSync(Exception):
    """This machine has no catalog scope at all.

    Raised, never sys.exit(): FleetPulse imports this module and sweeps every machine in
    one process, and SystemExit sails straight through its `except Exception` — one
    scope-less machine silently aborted the whole sweep, so every machine after it in the
    list was never swept at all.
    """


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


def taste_media_key(p):
    """The key the CONTAINER asks for — tasteMediaKey() in the Strapi machine controller.

    It prefers taste.main where product_key() prefers custom_main, so the two disagree for
    any product carrying both. Machine 78 hit exactly that: /catalog asked for 'protella'
    while its container asked for 'chocolate-hazelnut'. Rather than guess which screen the
    user will look at, media is written under BOTH keys — see collect().
    """
    taste = unwrap(p.get("taste"))
    if taste:
        tmain = unwrap(taste.get("main"))
        if tmain and tmain.get("name"):
            return stem(tmain["name"])
    return product_key(p)


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
    "&populate[products][populate][custom_main]=true"
    # The catalog's company block is built from the PRODUCT's brand, not the line's
    # brands[] — line 9 ('Whey Protein') carries no brands at all, yet serves company
    # 'mc'. Without this the logo is never staged and the kiosk shows a blank brand tile.
    "&populate[products][populate][brand][populate][logo]=true", safe="=&[]")


def brand_logo_item(brand):
    """(rel_path, url) for a brand's logo, or None. Key = filename stem sans '-logo'."""
    if not brand:
        return None
    logo = unwrap(brand.get("logo"))
    if not logo or not logo.get("name"):
        return None
    bkey = re.sub(r"-logo$", "", stem(logo["name"]))
    if not VALID_KEY.match(bkey):
        return None
    return f"CompanyLogos/{bkey}-logo.png", logo["url"]


def resolve_cells(token, machine):
    """The machine's own machine-cells, else its preset's preset-cells.

    Deliberately identical to resolveCells() in the Strapi machine controller: media has
    to be scoped by exactly what /catalog and /planogram serve, or the machine downloads
    art for products it does not stock and misses art for the ones it does.
    """
    own = api(f"/api/machine-cells?filters[machine][id][$eq]={machine['id']}"
              f"&populate[product][fields][0]=id&pagination[pageSize]=100", token)["data"]
    if own:
        return [unwrap(c["attributes"].get("product")) for c in own], "machine"
    preset = unwrap(machine.get("preset"))
    if not preset or preset.get("isActive") is False:
        return [], "machine"
    pc = api(f"/api/preset-cells?filters[preset][id][$eq]={preset['id']}"
             f"&populate[product][fields][0]=id&pagination[pageSize]=100", token)["data"]
    return [unwrap(c["attributes"].get("product")) for c in pc], f"preset:{preset['id']}"


def lines_from_cells(token, products):
    """Cell products -> their product-lines, each trimmed to just those products.

    Trimming matters: collect() walks every product of a line, so an untrimmed line would
    pull media for flavours the machine does not stock. The line itself is still needed —
    the cup and the brand logo live on it, not on the product.
    """
    want = {}                                   # line id -> set(product ids)
    for p in products:
        if not p:
            continue
        full = api(f"/api/products/{p['id']}?populate[product_line][fields][0]=id", token)["data"]
        line = unwrap(dict(full["attributes"]).get("product_line"))
        if not line:
            continue                            # orphan; /planogram rejects it anyway
        want.setdefault(line["id"], set()).add(p["id"])
    lines = []
    for lid, pids in want.items():
        full = api(f"/api/product-lines/{lid}?{LINE_POPULATE}", token)["data"]
        attrs = dict(full["attributes"])
        prods = (attrs.get("products") or {}).get("data") or []
        # Keep Strapi's {'data': [...]} shape — unwrap() in collect() expects the raw entries.
        attrs["products"] = {"data": [e for e in prods if e["id"] in pids]}
        lines.append(dict(attrs, id=full["id"]))
    return lines


def machine_lines(token, machine_arg):
    """Resolve machine (id or serial) -> (machine attrs, [line entries fully populated]).

    Cells first (the source of truth since the 2026-07-28 redesign), then the legacy
    machine.product_lines / client scoping for machines that predate cells. Before this,
    a machine with only a preset bound — the normal state of a just-shipped machine —
    exited with "nothing to sync" and never received any media at all.
    """
    pop = ("populate[product_lines][fields][0]=id&populate[client][fields][0]=id"
           "&populate[preset][fields][0]=id&populate[preset][fields][1]=isActive")
    if re.fullmatch(r"\d+", str(machine_arg)):
        m = api(f"/api/machines/{machine_arg}?{pop}", token)["data"]
    else:
        q = urllib.parse.quote(str(machine_arg))
        d = api(f"/api/machines?filters[serial_number][$eq]={q}&{pop}", token)["data"]
        if not d:
            sys.exit(f"no machine for serial {machine_arg}")
        m = d[0]
    ma = dict(m["attributes"], id=m["id"])

    cells, source = resolve_cells(token, ma)
    if cells:
        lines = lines_from_cells(token, cells)
        if lines:
            ma["_media_source"] = source
            return ma, lines

    assigned = unwrap(ma.get("product_lines")) or []
    lines = []
    if assigned:
        for l in assigned:
            full = api(f"/api/product-lines/{l['id']}?{LINE_POPULATE}", token)["data"]
            lines.append(dict(full["attributes"], id=full["id"]))
        ma["_media_source"] = "legacy:product_lines"
    else:
        client = unwrap(ma.get("client"))
        if not client:
            raise NothingToSync(
                f"machine {ma.get('serial_number') or ma['id']} has no cells, no preset, "
                "no assigned product lines and no client — nothing to sync")
        d = api(f"/api/product-lines?filters[author][client][id][$eq]={client['id']}"
                f"&filters[is_template][$ne]=true&pagination[pageSize]=200&{LINE_POPULATE}", token)["data"]
        lines = [dict(x["attributes"], id=x["id"]) for x in d if x["attributes"].get("isActive") is not False]
        ma["_media_source"] = f"legacy:client:{client['id']}"
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
        # Every brand on the line, not just brands[0]: a line can stock several, and the
        # kiosk asks for whichever one the served product belongs to.
        for b in unwrap(line.get("brands")) or []:
            it = brand_logo_item(b)
            if it:
                add(*it)
            else:
                skips.append((f"brand '{b.get('name')}'", "no usable logo filename"))
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
            # /catalog keys an ingredient by product_key, the container keys its Taste by
            # taste_media_key, and the two differ whenever a product has both custom_main
            # and a taste. Writing both costs a few duplicated PNGs and removes the entire
            # "empty <key>_splash folder, no artwork on screen" failure mode.
            keys = []
            for k in (product_key(p), taste_media_key(p)):
                if k and VALID_KEY.match(k) and k not in keys:
                    keys.append(k)
            if not keys:
                skips.append((f"product '{p.get('name')}'", f"no clean media key ({product_key(p)!r})"))
                continue
            it = brand_logo_item(unwrap(p.get("brand")))
            if it:
                add(*it)
            taste = unwrap(p.get("taste"))
            main = unwrap(p.get("custom_main")) or (unwrap(taste.get("main")) if taste else None)
            if not main:
                skips.append((f"product '{p.get('name')}'", "no main image (custom_main or taste.main)"))
            circ = unwrap(p.get("custom_circle")) or (unwrap(taste.get("default_circle")) if taste else None)
            circ_imgs = unwrap(circ.get("images")) if circ else None
            spl = unwrap(p.get("custom_splash")) or (unwrap(taste.get("default_splash")) if taste else None)
            spl_imgs = unwrap(spl.get("images")) if spl else None
            for key in keys:
                if main:
                    add(f"Tastes/{key}/{key}.png", main["url"])
                if circ_imgs:
                    add(f"Tastes/{key}/cicle-{key}.png", circ_imgs[0]["url"])
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

    try:
        machine, lines = machine_lines(token, args.machine)
    except NothingToSync as e:
        sys.exit(str(e))       # as a CLI this is still a plain, non-zero exit
    print(f"machine {machine['id']} serial={machine.get('serial_number')} "
          f"[{machine.get('_media_source')}] -> {len(lines)} line(s): "
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
