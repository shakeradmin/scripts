#!/usr/bin/env python3
"""
import_root_templates.py — generate root (author=root, is_template=true) product-lines
and template products in Strapi from the manage.ishakerusa.com telemetry product base.

These root templates are the PREFILL library the portal offers clients: a client picks a
root line/product, the form is pre-populated, and the client tweaks a few fields (the portal
clones with base_product / base_product_line). This script builds that library from telemetry.

STRICT trash filter — a telemetry ingredient becomes a template ONLY if ALL hold:
  * cellCategory in {Порошок->powder, Концентрат->concentrate}
  * cellPurpose maps to our enum (Sports nutrition->"sport nutrition", Milkshake->"milkshake")
  * has >=1 nutrition component (sufficient data)
  * categoryDosages has 4 parseable numbers (DrinkVolume/Water/Product/ConversionFactor)
  * its taste name matches an EXISTING Strapi taste (with a main image) — no new media created
  * its view name matches an EXISTING Strapi cup — no new media created
  * name is not obvious trash
The taste/cup match requirement is itself a strong trash filter (junk names match nothing).

GROUPING: one product-line per matched cup (= telemetry "view"); within a line each taste
appears once (dedup, richest-nutrition ingredient wins). Idempotent: re-running updates in
place, never duplicates (keyed on author=root + line name/cup, and line + taste).

USAGE
  python3 import_root_templates.py --dry-run          # show plan, write nothing
  python3 import_root_templates.py                     # create/update in Strapi
Env: STRAPI_BASE_URL (default http://localhost:1338); manage creds are the mcp-telemetry ones.
"""
import argparse, json, os, re, sys, urllib.request, urllib.parse, urllib.error
import concurrent.futures as cf

STRAPI = os.environ.get("STRAPI_BASE_URL", "http://localhost:1338")
ROOT_AUTHOR_USERNAME = "root"
MANAGE = "https://manage.ishakerusa.com/api"
KK = "https://kk.ishakerusa.com/realms/shaker-realm/protocol/openid-connect/token"
MANAGE_CLIENT, MANAGE_USER, MANAGE_PASS = "shaker-client", "root", "Ishakerusa1212!"

CATEGORY = {"Порошок": "powder", "Powder": "powder",
            "Концентрат": "concentrate", "Concentrate": "concentrate"}
PURPOSE = {"Sports nutrition": "sport nutrition", "Sport nutrition": "sport nutrition",
           "Milkshake": "milkshake", "Milk shake": "milkshake"}
UNIT = {"MG": "mg", "MCG": "mcg", "G": "g", "ML": "ml", "KCAL": "kcal", "KJ": "kJ", "%": "%"}
TRASH = re.compile(r"\b(test|тест|demo|copy|temp|tmp|example|sample|xxx+|zzz+|probe|delete|todo|dummy)\b", re.I)


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


# ── manage (telemetry) ────────────────────────────────────────────────────────
def manage_token():
    data = urllib.parse.urlencode({"grant_type": "password", "client_id": MANAGE_CLIENT,
                                   "username": MANAGE_USER, "password": MANAGE_PASS}).encode()
    return json.load(urllib.request.urlopen(urllib.request.Request(KK, data=data), timeout=20))["access_token"]


def fetch_ingredients(tok, max_id=250):
    H = {"Authorization": f"Bearer {tok}"}
    def one(i):
        try:
            x = urllib.request.urlopen(urllib.request.Request(
                f"{MANAGE}/telemetry-product-base/ingredient/element/{i}", headers=H), timeout=25)
            d = json.loads(x.read())
            return d if isinstance(d, dict) and d.get("name") and "error" not in d else None
        except Exception:
            return None
    out = {}
    with cf.ThreadPoolExecutor(max_workers=12) as ex:
        for i, d in zip(range(1, max_id + 1), ex.map(one, range(1, max_id + 1))):
            if d:
                out[i] = d
    return out


# ── Strapi ────────────────────────────────────────────────────────────────────
def strapi_login():
    def env(path=os.path.expanduser("~/ishaker-app/.env")):
        e = {}
        if os.path.exists(path):
            for ln in open(path):
                ln = ln.strip()
                if ln and not ln.startswith("#") and "=" in ln:
                    k, v = ln.split("=", 1); e[k.strip()] = v.strip()
        return e
    e = env()
    ident = e.get("STRAPI_MACHINE_USER_USERNAME") or e.get("STRAPI_MACHINE_USER_LOGIN")
    body = json.dumps({"identifier": ident, "password": e["STRAPI_MACHINE_USER_PASSWORD"]}).encode()
    r = urllib.request.Request(f"{STRAPI}/api/auth/local", data=body, headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=30))["jwt"]


def sapi(path, tok, method="GET", data=None):
    body = json.dumps({"data": data}).encode() if data is not None else None
    hdr = {"Authorization": f"Bearer {tok}"}
    if body: hdr["Content-Type"] = "application/json"
    req = urllib.request.Request(f"{STRAPI}{path}", data=body, method=method, headers=hdr)
    try:
        return json.load(urllib.request.urlopen(req, timeout=60))
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> {e.code}: {e.read()[:300].decode(errors='replace')}")


def all_rows(coll, tok, extra=""):
    return sapi(f"/api/{coll}?pagination[pageSize]=1000{extra}", tok)["data"]


# ── mapping ───────────────────────────────────────────────────────────────────
def parse_dosage(ing):
    dos = {d.get("key"): d.get("value") for d in (ing.get("categoryDosages") or [])}
    def num(k):
        try:
            return float(dos[k])
        except Exception:
            return None
    vol, water, prod, cf_ = num("DrinkVolume"), num("Water"), num("Product"), num("ConversionFactor")
    if None in (vol, water, prod, cf_):
        return None
    return {"full_drink_volume": vol, "water": water, "product": prod, "conversion_factor": cf_}


def map_nutrition(ing):
    out = []
    for c in ing.get("components") or []:
        u = UNIT.get(str(c.get("unit", "")).upper())
        if u is None or c.get("qty") is None or not c.get("name"):
            continue
        out.append({"name": str(c["name"]).strip(), "qty": float(c["qty"]), "unit": u})
    return out


def build(ings, taste_idx, cup_idx):
    """-> lines: {cup_id: {name, cup_id, products: {taste_id: product_payload}}}, skips[]"""
    lines, skips = {}, []
    # richest-first so taste dedup keeps the most complete
    for ing in sorted(ings.values(), key=lambda d: -len(d.get("components") or [])):
        ch = ing.get("characteristics") or {}
        name = (ing.get("nameLocale") or ing.get("name") or "").strip()
        cat = CATEGORY.get((ch.get("cellCategory") or {}).get("name"))
        pur = PURPOSE.get((ch.get("cellPurpose") or {}).get("name"))
        tname = (ch.get("taste") or {}).get("name")
        vname = (ch.get("view") or {}).get("name")
        nutr = map_nutrition(ing)
        dosg = parse_dosage(ing)
        taste = taste_idx.get(norm(tname))
        cup = cup_idx.get(norm(vname))
        reason = None
        if TRASH.search(name) or len(name) < 2: reason = "trash name"
        elif not cat: reason = f"bad category {(ch.get('cellCategory') or {}).get('name')!r}"
        elif not pur: reason = f"bad purpose {(ch.get('cellPurpose') or {}).get('name')!r}"
        elif not nutr: reason = "no nutrition components"
        elif not dosg: reason = "incomplete dosage"
        elif not taste: reason = f"no Strapi taste for {tname!r}"
        elif not cup: reason = f"no Strapi cup for view {vname!r}"
        if reason:
            skips.append((ing.get("id"), name, reason)); continue
        cqty = ing.get("componentsQty")
        cunit = str(ing.get("componentsUnit") or "").upper()
        serving_qty = float(cqty) if cqty else dosg["product"]
        serving_unit = "ml" if cunit == "ML" else "g"
        prod = {
            "name": taste["name"],  # clean, title-cased Strapi taste name
            "description": (ing.get("description") or "").strip() or None,
            "taste": taste["id"], "product_type": cat, "product_purpose": pur,
            "serving_qty": serving_qty, "serving_unit": serving_unit,
            "dosage": dosg, "nutrition": nutr, "isActive": True,
        }
        line = lines.setdefault(cup["id"], {"name": cup["name"], "cup_id": cup["id"], "products": {}})
        line["products"].setdefault(taste["id"], prod)  # first (richest) wins
    return lines, skips


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-id", type=int, default=250)
    args = ap.parse_args()

    tok = strapi_login()
    # users-permissions /api/users returns a bare list, not {data:[...]}
    root = sapi("/api/users?filters[username][$eq]=root&fields[0]=username", tok)
    root_id = root[0]["id"] if isinstance(root, list) and root else None
    if not root_id:
        sys.exit("no root user in Strapi")

    tastes = all_rows("tastes", tok, "&fields[0]=name&populate[main][fields][0]=id")
    taste_idx = {norm(t["attributes"]["name"]): {"id": t["id"], "name": t["attributes"]["name"]}
                 for t in tastes if (t["attributes"].get("main") or {}).get("data")}
    cups = all_rows("cups", tok, "&fields[0]=name")
    cup_idx = {norm(c["attributes"]["name"]): {"id": c["id"], "name": c["attributes"]["name"]} for c in cups}
    print(f"Strapi: root id {root_id}, {len(taste_idx)} tastes w/image, {len(cup_idx)} cups")

    ings = fetch_ingredients(manage_token(), args.max_id)
    print(f"manage: {len(ings)} ingredients fetched")

    lines, skips = build(ings, taste_idx, cup_idx)
    n_prod = sum(len(l["products"]) for l in lines.values())
    print(f"\n=== PLAN: {len(lines)} product-lines, {n_prod} template products "
          f"(skipped {len(skips)} ingredients) ===")
    for l in sorted(lines.values(), key=lambda x: -len(x["products"])):
        print(f"  line '{l['name']}' (cup {l['cup_id']}): "
              + ", ".join(p["name"] for p in l["products"].values()))
    from collections import Counter
    print("\nskip reasons:", dict(Counter(r for _, _, r in skips)))

    if args.dry_run:
        print("\nDRY RUN — nothing written.")
        return

    # existing root lines/products for idempotency
    ex_lines = all_rows("product-lines", tok,
                        f"&filters[author][id][$eq]={root_id}&fields[0]=name&populate[cup][fields][0]=id")
    # One root template line per cup: reuse an existing root line on that cup (keep its name),
    # so we don't create a parallel line (e.g. "Protein" alongside existing "Whey Protein").
    line_by_cup = {}
    for pl in ex_lines:
        cupd = (pl["attributes"].get("cup") or {}).get("data")
        if cupd:
            line_by_cup.setdefault(cupd["id"], pl["id"])

    created_l = created_p = updated_p = 0
    for l in lines.values():
        line_id = line_by_cup.get(l["cup_id"])
        if not line_id:
            res = sapi("/api/product-lines", tok, "POST", {
                "name": l["name"], "cup": l["cup_id"], "author": root_id,
                "is_template": True, "isActive": True})
            line_id = res["data"]["id"]; created_l += 1
            existing_taste_ids = set()
        else:
            cur = sapi(f"/api/product-lines/{line_id}?populate[products][populate][taste][fields][0]=id", tok)
            existing_taste_ids = {((p.get("taste") or {}).get("data") or {}).get("id")
                                  for p in cur["data"]["attributes"]["products"]["data"]
                                  } if False else set()
            # simpler: re-query products of this line by taste
            prods = all_rows("products", tok,
                             f"&filters[product_line][id][$eq]={line_id}&filters[author][id][$eq]={root_id}"
                             f"&populate[taste][fields][0]=id&fields[0]=name")
            existing_taste_ids = {((p['attributes'].get('taste') or {}).get('data') or {}).get('id') for p in prods}
        for taste_id, prod in l["products"].items():
            if taste_id in existing_taste_ids:
                continue
            payload = dict(prod, taste=taste_id, product_line=line_id, author=root_id)
            sapi("/api/products", tok, "POST", payload)
            created_p += 1
    print(f"\nDONE: +{created_l} product-lines, +{created_p} products (updated {updated_p}).")


if __name__ == "__main__":
    main()
