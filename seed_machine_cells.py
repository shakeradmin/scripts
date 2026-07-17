#!/usr/bin/env python3
"""
seed_machine_cells.py — backfill Strapi machine-cell rows from a machine's CURRENT
physical layout (config.json Containers), so a machine can be switched to explicit,
client-controlled cell assignment WITHOUT wiping its live assortment.

For every container on the machine it creates one machine-cell row:
  position      = container ContainerNumber
  product       = the Strapi product matching the container's current taste
                  (client-owned product preferred over a root template; null if none)
  isActive      = container IsActive
  cell_category = CellCategoryId 1->powder, 2->concentrate

Idempotent: a (machine, position) that already has a row is left untouched (never
duplicated, never overwritten). Run once per machine before exposing the portal UI.

USAGE
  STRAPI_BASE_URL=http://localhost:1338 python3 seed_machine_cells.py --machine 62
  python3 seed_machine_cells.py --machine 62 --dry-run
"""
import argparse, json, os, re, sys, urllib.parse, urllib.request

import sync_machine_cells as smc  # reuse load_env / login / ssh / read_json helpers

STRAPI = os.environ.get("STRAPI_BASE_URL", smc.STRAPI)
smc.STRAPI = STRAPI  # keep helper module in sync with our base url
UA = "Mozilla/5.0 seed_machine_cells/1.0"
CATEGORY = {1: "powder", 2: "concentrate"}


def norm(s):
    """Normalize a taste name/slug for matching: 'Chocolate Hazelnut' == 'chocolate-hazelnut'."""
    return re.sub(r"[^a-z0-9]", "", str(s or "").lower())


def strapi_post(path, token, payload):
    body = json.dumps({"data": payload}).encode()
    req = urllib.request.Request(f"{STRAPI}{path}", data=body,
                                 headers={"Authorization": f"Bearer {token}",
                                          "Content-Type": "application/json", "User-Agent": UA})
    return json.load(urllib.request.urlopen(req, timeout=30))


def resolve_machine(machine_arg, token):
    """machine id/serial -> (id, 'user@ip')."""
    if str(machine_arg).isdigit():
        a = smc.strapi_get(f"/api/machines/{machine_arg}?fields[0]=ssh_user"
                           f"&fields[1]=tailscale_ip&fields[2]=serial_number", token)["data"]
        mid, at = int(machine_arg), a["attributes"]
    else:
        d = smc.strapi_get(f"/api/machines?filters[serial_number][$eq]={machine_arg}"
                           f"&fields[0]=ssh_user&fields[1]=tailscale_ip", token)["data"]
        if not d:
            sys.exit(f"no machine for {machine_arg}")
        mid, at = d[0]["id"], d[0]["attributes"]
    ip = (at.get("tailscale_ip") or "").strip()
    if not ip:
        sys.exit("machine has no tailscale_ip")
    return mid, f"{at.get('ssh_user') or 'shaker'}@{ip}"


def build_product_index(token):
    """normalized taste/product name -> product id, client-owned preferred over root template."""
    idx = {}  # norm-key -> (product_id, is_root)
    page = 1
    while True:
        r = smc.strapi_get(f"/api/products?populate[author]=*&populate[taste]=*"
                           f"&pagination[page]={page}&pagination[pageSize]=100", token)
        for row in r["data"]:
            a = row["attributes"]
            au = (a.get("author") or {}).get("data")
            is_root = bool(au and au["attributes"].get("username") == "root")
            keys = set()
            if a.get("name"):
                keys.add(norm(a["name"]))
            t = (a.get("taste") or {}).get("data")
            if t and t["attributes"].get("name"):
                keys.add(norm(t["attributes"]["name"]))
            for k in keys:
                if not k:
                    continue
                # keep first seen, but let a client (non-root) product replace a root one
                if k not in idx or (idx[k][1] and not is_root):
                    idx[k] = (row["id"], is_root)
        meta = r["meta"]["pagination"]
        if page >= meta["pageCount"]:
            break
        page += 1
    return {k: v[0] for k, v in idx.items()}


def find_product(index, taste_name):
    return index.get(norm(taste_name))


def existing_positions(token, machine_id):
    rows = smc.strapi_get(f"/api/machine-cells?filters[machine][id][$eq]={machine_id}"
                          f"&fields[0]=position&pagination[pageSize]=200", token)["data"]
    return {r["attributes"]["position"] for r in rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", required=True, help="Strapi machine id or serial")
    ap.add_argument("--password", help="ssh password (omit for key auth)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    env = smc.load_env()
    ident = env.get("STRAPI_MACHINE_USER_USERNAME") or env.get("STRAPI_MACHINE_USER_LOGIN")
    token = smc.strapi_login(ident, env["STRAPI_MACHINE_USER_PASSWORD"])

    machine_id, target = resolve_machine(args.machine, token)
    cfg = smc.read_json(target, "config.json", args.password)
    have = existing_positions(token, machine_id)
    index = build_product_index(token)

    created, skipped, unmatched = 0, 0, []
    for c in cfg.get("Containers", []):
        pos = c.get("ContainerNumber")
        if pos in have:
            skipped += 1
            continue
        prod = (c.get("Product") or {})
        taste_name = ((prod.get("Taste") or {}).get("Name"))
        pid = find_product(index, taste_name)
        if taste_name and pid is None:
            unmatched.append((pos, taste_name))
        payload = {
            "machine": machine_id,
            "position": pos,
            "product": pid,
            "isActive": bool(c.get("IsActive", True)),
            "cell_category": CATEGORY.get(prod.get("CellCategoryId")),
        }
        print(f"  pos {pos}: taste={taste_name!r} -> product={pid} "
              f"active={payload['isActive']} cat={payload['cell_category']}")
        if not args.dry_run:
            strapi_post("/api/machine-cells", token, payload)
        created += 1

    print(f"\nmachine {machine_id} ({target}): "
          f"{'DRY-RUN ' if args.dry_run else ''}+{created} cells, {skipped} already seeded")
    if unmatched:
        print(f"WARNING: {len(unmatched)} cell(s) had no matching Strapi product "
              f"(seeded with product=null): {unmatched}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
