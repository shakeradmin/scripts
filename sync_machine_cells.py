#!/usr/bin/env python3
"""
sync_machine_cells.py — reconcile a ShakerView machine's cell assignments
(config.json Containers) with its own product database (dataBase.json), which the
FleetCatalog patch already keeps in sync with Strapi.

WHY: the FleetCatalog patch refreshes dataBase.json from Strapi every ~5 min, but the
sales screen only shows products ASSIGNED TO CELLS (Containers). This closes that gap:
whenever a client edits product lines / products on the portal, the new/edited tastes
appear on the machine automatically — cells are remapped and the app is restarted only
when the resulting config actually changes.

RECONCILIATION (stable — physical cell↔powder mapping is preserved where possible):
  * A cell whose taste still exists in the DB keeps its cell number; its Product block is
    REBUILT from the DB, so nutrition/dosage edits reach the screen. Existing price kept.
  * A DB taste not yet on any cell is placed in the lowest-numbered free/inactive cell
    (same CellCategory) up to the machine's physical cell count.
  * A cell whose taste vanished from the DB is deactivated (IsActive=false).
Prices are NOT in the catalog: an existing cell keeps its dPrices; a newly-placed taste
gets a default (--default-price, 5.0) until real pricing arrives (telemetry cellStore).

Idempotent + hash-guarded: if the reconciled config equals the current one, nothing is
written and the app is NOT restarted. Safe to run on a short loop / cron.

USAGE
  STRAPI_BASE_URL=http://localhost:1338 python3 sync_machine_cells.py --machine 62
  python3 sync_machine_cells.py --ssh shaker@100.90.99.98 --dry-run
  # loop mode (all catalog-enabled machines listed by --machines):
  python3 sync_machine_cells.py --machine 62 --quiet

Restart is a single-PID SIGKILL (no exit-time config save can clobber the edit);
AppManager relaunches the app in ~15 s. NEVER pattern-kills.
"""
import argparse, hashlib, json, os, re, subprocess, sys, urllib.request

STRAPI = os.environ.get("STRAPI_BASE_URL", "https://admin.ishaker.xyz")
UA = "Mozilla/5.0 sync_machine_cells/1.0"
CFG_DIR = "/home/shaker/ShakerView2.0Linux/ShakerView2.0_Data/Config"


def load_env(path=os.path.expanduser("~/Desktop/credentials/.env")):
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def strapi_login(ident, pw):
    body = json.dumps({"identifier": ident, "password": pw}).encode()
    req = urllib.request.Request(f"{STRAPI}/api/auth/local", data=body,
                                 headers={"Content-Type": "application/json", "User-Agent": UA})
    return json.load(urllib.request.urlopen(req, timeout=30))["jwt"]


def strapi_get(path, token):
    req = urllib.request.Request(f"{STRAPI}{path}",
                                 headers={"Authorization": f"Bearer {token}", "User-Agent": UA})
    return json.load(urllib.request.urlopen(req, timeout=30))


def resolve_ssh(machine_arg):
    """machine id/serial -> 'user@ip' from Strapi."""
    env = load_env()
    ident = env.get("STRAPI_MACHINE_USER_USERNAME") or env.get("STRAPI_MACHINE_USER_LOGIN")
    token = strapi_login(ident, env["STRAPI_MACHINE_USER_PASSWORD"])
    if str(machine_arg).isdigit():
        d = strapi_get(f"/api/machines/{machine_arg}?fields[0]=ssh_user&fields[1]=tailscale_ip"
                       f"&fields[2]=serial_number", token)["data"]
        a = d["attributes"]
    else:
        d = strapi_get(f"/api/machines?filters[serial_number][$eq]={machine_arg}"
                       f"&fields[0]=ssh_user&fields[1]=tailscale_ip", token)["data"]
        if not d:
            sys.exit(f"no machine for {machine_arg}")
        a = d[0]["attributes"]
    ip = (a.get("tailscale_ip") or "").strip()
    if not ip:
        sys.exit("machine has no tailscale_ip")
    return f"{a.get('ssh_user') or 'shaker'}@{ip}"


def ssh_run(target, cmd, password=None, input_bytes=None, timeout=40):
    base = ["ssh", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"]
    if password:
        base = ["sshpass", "-p", password] + base + [
            "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"]
    return subprocess.run(base + [target, cmd], input=input_bytes,
                          capture_output=True, timeout=timeout)


def read_json(target, name, password):
    r = ssh_run(target, f"cat {CFG_DIR}/{name}", password)
    if r.returncode != 0:
        sys.exit(f"read {name} failed: {r.stderr.decode()[:200]}")
    return json.loads(r.stdout.decode("utf-8-sig"))


def db_tastes(db):
    """Ordered [(company, product, taste_dict)] across the DB."""
    out = []
    for company in db.get("ProducingCompanies", {}).values():
        for product in company.get("Products", {}).values():
            for taste in product.get("Tastes", {}).values():
                out.append((company, product, taste))
    return out


def build_product_block(company, product, taste, dprices):
    return {
        "Name": product["Name"],
        "Taste": {"Name": taste["Name"], "ID": taste["Id"],
                  "TasteID": taste.get("TasteId"), "mediaKey": taste["MediaKey"]},
        "ProducingCompany": {"Name": company["Name"], "mediaKey": company["MediaKey"],
                             "ID": company["Id"]},
        "ComponentOnAmount": taste["ComponentOnAmount"],
        "Components": taste["SupplimentFacts"],
        "CellCategoryId": product["CellCategoryId"],
        "Condition": product["Condition"],
        "dPrices": dprices,
        "Dosage": taste["Dosage"],
        "ID": product["Id"], "ProductId": 0, "IsCalibrated": False,
    }


def reconcile(cfg, db, default_price):
    containers = cfg.get("Containers", [])
    tastes = db_tastes(db)
    # taste-name -> (company, product, taste)
    by_name = {t[2]["Name"]: t for t in tastes}
    placed = set()
    # Pass 1: keep existing cells whose taste still exists, refresh their Product block.
    for c in containers:
        cur = (((c.get("Product") or {}).get("Taste") or {}).get("Name"))
        if cur in by_name and cur not in placed:
            company, product, taste = by_name[cur]
            # category must match the physical cell (dry vs syrup)
            if product["CellCategoryId"] == (c.get("Product") or {}).get("CellCategoryId", product["CellCategoryId"]):
                dprices = (c.get("Product") or {}).get("dPrices") or [
                    {"Volume": taste["Dosage"]["DrinkVolume"], "Price": default_price}]
                c["Product"] = build_product_block(company, product, taste, dprices)
                c["Cup"] = dict(product["Cup"])
                c["IsActive"] = True
                placed.add(cur)
                continue
        # will be reconsidered for new tastes / deactivation below
        c["_free"] = True
    # Pass 2: assign not-yet-placed tastes to free/inactive cells (by category).
    remaining = [t for t in tastes if t[2]["Name"] not in placed]
    for c in containers:
        if not c.get("_free"):
            continue
        cell_cat = (c.get("Product") or {}).get("CellCategoryId")
        pick = None
        for t in remaining:
            if cell_cat is None or t[1]["CellCategoryId"] == cell_cat:
                pick = t
                break
        if pick:
            company, product, taste = pick
            remaining.remove(pick)
            dprices = [{"Volume": taste["Dosage"]["DrinkVolume"], "Price": default_price}]
            c["Product"] = build_product_block(company, product, taste, dprices)
            c["Cup"] = dict(product["Cup"])
            c["IsActive"] = True
            placed.add(taste["Name"])
        else:
            c["IsActive"] = False  # taste vanished, nothing to put here
        c.pop("_free", None)
    cfg["Containers"] = containers
    return cfg, placed, [t[2]["Name"] for t in remaining]


def fetch_explicit_cells(machine_arg, ssh_target):
    """Return the machine's explicit cell assignments from Strapi, or None.

    None => Strapi unreachable / machine not identifiable => caller uses auto-assign.
    []   => machine identified but has no machine-cell rows => caller uses auto-assign
            (the 'Keep auto-assign' fallback). A non-empty list is AUTHORITATIVE.
    """
    env = load_env()
    ident = env.get("STRAPI_MACHINE_USER_USERNAME") or env.get("STRAPI_MACHINE_USER_LOGIN")
    try:
        token = strapi_login(ident, env["STRAPI_MACHINE_USER_PASSWORD"])
    except Exception:
        return None
    mid = None
    try:
        if machine_arg and str(machine_arg).isdigit():
            mid = int(machine_arg)
        elif machine_arg:
            d = strapi_get(f"/api/machines?filters[serial_number][$eq]={machine_arg}"
                           f"&fields[0]=id", token)["data"]
            if d:
                mid = d[0]["id"]
        if mid is None and ssh_target:
            ip = ssh_target.split("@")[-1]
            d = strapi_get(f"/api/machines?filters[tailscale_ip][$eq]={ip}&fields[0]=id",
                           token)["data"]
            if d:
                mid = d[0]["id"]
        if mid is None:
            return None
        q = (f"/api/machine-cells?filters[machine][id][$eq]={mid}"
             f"&populate[product][populate][taste]=*&pagination[pageSize]=200")
        rows = strapi_get(q, token)["data"]
    except Exception:
        return None
    cells = []
    for r in rows:
        a = r["attributes"]
        prod = (a.get("product") or {}).get("data")
        names = []
        if prod:
            pa = prod["attributes"]
            if pa.get("name"):
                names.append(pa["name"])
            t = (pa.get("taste") or {}).get("data")
            if t and t["attributes"].get("name"):
                names.append(t["attributes"]["name"])
        cells.append({"position": a["position"], "active": bool(a.get("isActive", True)),
                      "category": a.get("cell_category"), "taste_names": names})
    return cells


def reconcile_explicit(cfg, db, cells, default_price):
    """AUTHORITATIVE reconcile: containers follow the Strapi machine-cell rows exactly.

    Matched by physical container number == cell.position.
      * product set + active  -> rebuild that container's Product block from the DB taste
        (keeps existing dPrices), IsActive=True.
      * product null / inactive -> IsActive=False (client emptied the slot).
      * product assigned but not yet in the machine DB (catalog lag) -> left untouched,
        reported as 'missing'; the next run places it once FleetCatalog syncs the DB.
      * a physical container with NO cell row -> left untouched (not yet seeded).
    """
    containers = cfg.get("Containers", [])
    # Match on a normalized key: the machine DB stores taste names as slugs
    # ('chocolate-hazelnut') while Strapi carries display names ('Chocolate Hazelnut').
    norm = lambda s: re.sub(r"[^a-z0-9]", "", str(s or "").lower())
    by_name = {norm(t[2]["Name"]): t for t in db_tastes(db)}
    cellmap = {c["position"]: c for c in cells}
    placed, missing, cleared = [], [], []
    for c in containers:
        pos = c.get("ContainerNumber")
        spec = cellmap.get(pos)
        if spec is None:
            continue  # unseeded physical container — leave as-is
        names = spec["taste_names"]
        if not spec["active"] or not names:
            if c.get("IsActive"):
                c["IsActive"] = False
                cleared.append(pos)
            continue
        match = next((by_name[norm(n)] for n in names if norm(n) in by_name), None)
        if not match:
            missing.append((pos, names))
            continue  # catalog lag — never wipe the cell
        company, product, taste = match
        dprices = (c.get("Product") or {}).get("dPrices") or [
            {"Volume": taste["Dosage"]["DrinkVolume"], "Price": default_price}]
        c["Product"] = build_product_block(company, product, taste, dprices)
        c["Cup"] = dict(product["Cup"])
        c["IsActive"] = True
        placed.append((pos, taste["Name"]))
    cfg["Containers"] = containers
    return cfg, placed, missing, cleared


def assign_sig(containers):
    """Semantic signature of cell assignment: (cell, active, taste id) per container.
    Ignores JSON formatting and the component/dosage fields the APP rewrites on save."""
    sig = []
    for c in containers:
        taste = ((c.get("Product") or {}).get("Taste") or {})
        sig.append((c.get("ContainerNumber"), bool(c.get("IsActive")), taste.get("ID")))
    return tuple(sorted(sig, key=lambda x: (x[0] is None, x[0])))


def db_hash(db):
    """Canonical hash of the product DB (order-independent) — changes only on a real
    product/nutrition/dosage edit, stable across app restarts."""
    return hashlib.md5(json.dumps(db, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


STATE_FILE = "/home/shaker/ShakerView-diag/last_cellsync_dbhash.txt"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", help="Strapi machine id or serial (resolves ssh via Strapi)")
    ap.add_argument("--ssh", help="explicit ssh target user@ip (skips Strapi resolve)")
    ap.add_argument("--password", help="ssh password (omit for key auth)")
    ap.add_argument("--default-price", type=float, default=5.0)
    ap.add_argument("--dry-run", action="store_true", help="print diff, don't write/restart")
    ap.add_argument("--no-restart", action="store_true", help="write config but don't restart app")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    target = args.ssh or (resolve_ssh(args.machine) if args.machine else None)
    if not target:
        sys.exit("need --machine or --ssh")

    def log(*a):
        if not args.quiet:
            print(*a)

    cfg = read_json(target, "config.json", args.password)
    db = read_json(target, "dataBase.json", args.password)
    before_sig = assign_sig(cfg.get("Containers", []))
    before_cells = [(c["ContainerNumber"], (((c.get("Product") or {}).get("Taste") or {}).get("Name")),
                     c.get("IsActive")) for c in cfg.get("Containers", [])]

    # Explicit machine-cell rows in Strapi are authoritative; absent them, auto-assign.
    cells = fetch_explicit_cells(args.machine, target)
    if cells:
        cfg, placed, missing, cleared = reconcile_explicit(cfg, db, cells, args.default_price)
        mode, leftover = "explicit", []
        if missing:
            log(f"[{target}] {len(missing)} assigned product(s) not in machine DB yet "
                f"(catalog lag, cells untouched): {missing}")
        if cleared:
            log(f"[{target}] {len(cleared)} cell(s) emptied by client: positions {cleared}")
    else:
        cfg, placed, leftover = reconcile(cfg, db, args.default_price)
        mode = "auto"
    log(f"[{target}] mode={mode}")
    after_sig = assign_sig(cfg["Containers"])
    after_cells = [(c["ContainerNumber"], c["Product"]["Taste"]["Name"], c["IsActive"])
                   for c in cfg["Containers"]]

    assignment_changed = before_sig != after_sig

    # Did the product DB itself change (nutrition/dosage/rename) since our last sync?
    # The app repopulates Container components from dataBase.json on restart, so a DB
    # change needs a restart even when the cell assignment is identical.
    cur_hash = db_hash(db)
    last_hash = ssh_run(target, f"cat {STATE_FILE} 2>/dev/null", args.password).stdout.decode().strip()
    db_changed = cur_hash != last_hash

    if not assignment_changed and not db_changed:
        log(f"[{target}] no change — cells match DB, DB unchanged ({sum(1 for _,_,a in after_cells if a)} active)")
        return 0

    if assignment_changed:
        log(f"[{target}] assignment: {before_cells} -> {after_cells}")
    if db_changed:
        log(f"[{target}] product DB changed ({last_hash[:8] or 'none'} -> {cur_hash[:8]}) — restart to reload")
    if leftover:
        log(f"[{target}] WARNING: {len(leftover)} taste(s) had no free cell: {leftover}")
    if args.dry_run:
        log("dry-run — not writing")
        return 0

    ts = subprocess.run(["date", "+%Y%m%d-%H%M%S"], capture_output=True, text=True).stdout.strip()
    kill = "" if args.no_restart else (
        "PID=$(ps -eo pid,comm | awk '$2 ~ /^ShakerView2.0/ {print $1}'); "
        "[ -n \"$PID\" ] && kill -9 $PID; ")
    # Persist the DB hash we've now applied, so an unchanged DB won't trigger restarts.
    save_state = f"mkdir -p $(dirname {STATE_FILE}); printf %s {cur_hash} > {STATE_FILE}; "

    # Always write the reconciled config: the app does NOT repopulate a cell's
    # components/dosage from dataBase.json on load — the container holds a snapshot
    # until reassigned. So nutrition/dosage edits (db_changed) must be written into
    # each kept cell's Product block, which reconcile() already rebuilt from the DB.
    # kill FIRST so the app can't save its in-memory config over ours on exit.
    payload = json.dumps(cfg, ensure_ascii=False, indent=2).encode()
    cmd = (f"{kill}{save_state}"
           f"cp -a {CFG_DIR}/config.json {CFG_DIR}/config.json.pre-cellsync-{ts}; "
           f"cat > {CFG_DIR}/config.json")
    r = ssh_run(target, cmd, args.password, input_bytes=payload)
    if r.returncode != 0:
        sys.exit(f"apply failed: {r.stderr.decode()[:200]}")
    note = "assignment + product data" if assignment_changed else "product data (nutrition/dosage)"
    log(f"[{target}] config.json updated: {note} (backup .pre-cellsync-{ts})"
        + ("" if args.no_restart else "; app restarting"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
