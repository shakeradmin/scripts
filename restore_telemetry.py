#!/usr/bin/env python3
"""
restore_telemetry.py — re-populate a ShakerView machine's telemetry MachineKey after it was
scrubbed (e.g. by preclone_scrub.sh / bootstrap.sh clone-hygiene), by fetching a fresh credential
through the Strapi `cred` entity's TELEMETRY_PASSWORD — never by re-using a golden's old key.

FLOW (same path bootstrap.sh uses, but it WRITES the key into the on-machine telemetry.json):
  1. Strapi auth (machine user) -> GET /api/cred -> TELEMETRY_PASSWORD
  2. manage.ishakerusa.com Keycloak token  (grant_type=password, client_id=shaker-client, user=root)
  3. registration-code/create-or-get/<org>  -> REG code
  4. machine/registration/<REG code>  {modelName, machineName, serialNumber} -> secretKey (= MachineKey)
  5. back up telemetry.json (.bak-<ts>) and write MachineKey into it
  6. optional: restart ShakerView

Runs from the operator laptop (which has ~/Desktop/credentials/.env and internet); talks to the
machine only over SSH to read serial/org and write telemetry.json.

USAGE
  python3 restore_telemetry.py --machine shaker@100.112.118.51 --password 123 --restart
  python3 restore_telemetry.py --machine shaker@<ip> --password 123 --org 2 --model "Milkshaker S"
  python3 restore_telemetry.py --local            # run ON the machine itself (reads local files)

Reads STRAPI_MACHINE_USER_LOGIN/PASSWORD from ~/Desktop/credentials/.env (or --identifier/--pw-strapi).
"""
import argparse, json, os, re, subprocess, sys, urllib.parse, urllib.request

STRAPI = os.environ.get("STRAPI_BASE_URL", "https://admin.ishaker.xyz")
KK_TOKEN = os.environ.get("MANAGE_KEYCLOAK_TOKEN_URL",
                          "https://kk.ishakerusa.com/realms/shaker-realm/protocol/openid-connect/token")
MANAGE = os.environ.get("MANAGE_API_BASE", "https://manage.ishakerusa.com")
MANAGE_CLIENT_ID = os.environ.get("MANAGE_CLIENT_ID", "shaker-client")
MANAGE_USERNAME = os.environ.get("MANAGE_USERNAME", "root")
UA = "Mozilla/5.0 (X11; Linux x86_64) restore_telemetry/1.0"  # Cloudflare 403s urllib's default UA
SV_CFG = "/home/shaker/ShakerView2.0Linux/ShakerView2.0_Data/Config"


def load_env(path=os.path.expanduser("~/Desktop/credentials/.env")):
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def http(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, headers={**(headers or {}), "User-Agent": UA}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def strapi_json(path, token=None, data=None, ct=None):
    h = {}
    if token:
        h["Authorization"] = f"Bearer {token}"
    if ct:
        h["Content-Type"] = ct
    st, body = http(f"{STRAPI}{path}", data=data, headers=h, method=("POST" if data else None))
    if st < 200 or st >= 300:
        sys.exit(f"Strapi {path} failed: HTTP {st} {body[:200]}")
    return json.loads(body)


def ssh_run(machine, password, script):
    cmd = ["ssh", "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=accept-new",
           "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
           machine, "bash -s"]
    if password:
        cmd = ["sshpass", "-p", password] + cmd
    p = subprocess.run(cmd, input=script, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"SSH to {machine} failed: {p.stderr.strip() or p.stdout.strip()}")
    return p.stdout


def read_machine_facts(args):
    """Return (serial, org, model_name, telemetry_path). Local or over SSH."""
    probe = r'''
CFG="%s"
python3 - "$CFG" <<'PY'
import json,sys,glob,os
cfg=sys.argv[1]
def load(p):
    try: return json.load(open(p,encoding="utf-8-sig"))
    except Exception: return {}
hs=load(f"{cfg}/hard_settings.json"); tj=load(f"{cfg}/telemetry.json")
serial=hs.get("MachineSerial") or tj.get("MachineSerial") or ""
org=tj.get("OrganizationId") or ""
if hs.get("IsMilkVersion"): model="Milkshaker S"
elif hs.get("IsTouch2"): model="ShakerTouch"
else: model="Shaker S"
print(json.dumps({"serial":serial,"org":org,"model":model,"tj":f"{cfg}/telemetry.json"}))
PY
''' % SV_CFG
    out = subprocess.run(["bash", "-c", probe], capture_output=True, text=True).stdout if args.local \
        else ssh_run(args.machine, args.password, probe)
    facts = json.loads(out.strip().splitlines()[-1])
    return facts


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--machine", help="ssh target e.g. shaker@100.112.118.51")
    g.add_argument("--local", action="store_true", help="run on the machine itself")
    ap.add_argument("--password", help="ssh password (with --machine; uses sshpass)")
    ap.add_argument("--identifier", help="Strapi identifier (else from .env)")
    ap.add_argument("--pw-strapi", help="Strapi password (else from .env)")
    ap.add_argument("--org", help="override OrganizationId")
    ap.add_argument("--serial", help="override machine serial")
    ap.add_argument("--model", help="override model name (Shaker S / Milkshaker S / ShakerTouch)")
    ap.add_argument("--restart", action="store_true", help="restart ShakerView after writing the key")
    args = ap.parse_args()

    env = load_env()
    ident = args.identifier or env.get("STRAPI_MACHINE_USER_LOGIN")
    spw = args.pw_strapi or env.get("STRAPI_MACHINE_USER_PASSWORD")
    if not ident or not spw:
        sys.exit("Missing Strapi credentials (--identifier/--pw-strapi or ~/Desktop/credentials/.env)")

    facts = read_machine_facts(args)
    serial = args.serial or facts["serial"]
    org = args.org or facts["org"]
    model = args.model or facts["model"]
    tj_path = facts["tj"]
    if not serial or not org:
        sys.exit(f"Could not determine serial/org (serial={serial!r} org={org!r}); pass --serial/--org")
    print(f"Machine: serial={serial} org={org} model={model}")

    # 1) Strapi -> TELEMETRY_PASSWORD
    jwt = strapi_json("/api/auth/local",
                      data=json.dumps({"identifier": ident, "password": spw}).encode(),
                      ct="application/json")["jwt"]
    creds = (((strapi_json("/api/cred", jwt).get("data") or {}).get("attributes") or {}).get("creds") or {})
    tp = creds.get("TELEMETRY_PASSWORD")
    if not tp:
        sys.exit("TELEMETRY_PASSWORD not present in Strapi /api/cred")
    print("Loaded TELEMETRY_PASSWORD from Strapi cred")

    # 2) manage Keycloak token
    st, body = http(KK_TOKEN, data=urllib.parse.urlencode({
        "grant_type": "password", "client_id": MANAGE_CLIENT_ID,
        "username": MANAGE_USERNAME, "password": tp}).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    if st != 200:
        sys.exit(f"manage Keycloak auth failed: HTTP {st} {body[:200]}")
    access = json.loads(body)["access_token"]

    # 3) create-or-get REG code
    st, body = http(f"{MANAGE}/api/telemetry-machine-control/registration-code/create-or-get/{org}",
                    headers={"Authorization": f"Bearer {access}"}, method="POST")
    if st < 200 or st >= 300:
        sys.exit(f"REG code fetch failed: HTTP {st} {body[:200]}")
    reg_code = json.loads(body).get("code")
    print(f"REG code for org {org}: {reg_code}")

    # 4) redeem -> secretKey (MachineKey)
    from datetime import datetime
    payload = json.dumps({"modelName": model,
                          "machineName": f"{model} {datetime.now():%d.%m.%Y}",
                          "serialNumber": serial}).encode()
    st, body = http(f"{MANAGE}/api/telemetry-machine-control/machine/registration/{reg_code}",
                    data=payload, headers={"Content-Type": "application/json"}, method="POST")
    if st < 200 or st >= 300:
        sys.exit(f"REG redemption failed: HTTP {st} {body[:300]}")
    secret = json.loads(body).get("secretKey")
    if not secret:
        sys.exit(f"Registration returned no secretKey: {body[:300]}")
    print("Obtained fresh MachineKey (secretKey) from telemetry backend")

    # 5) write MachineKey into telemetry.json (backup first)
    writer = r'''
TJ="%s" MK="%s" python3 - <<'PY'
import json,os,shutil,datetime
p=os.environ["TJ"]; mk=os.environ["MK"]
shutil.copy2(p, p+".bak-"+datetime.datetime.now().strftime("%%Y%%m%%d-%%H%%M%%S"))
d=json.load(open(p,encoding="utf-8-sig"))
d["MachineKey"]=mk
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
print("MachineKey written to",p)
PY
''' % (tj_path, secret)
    out = subprocess.run(["bash", "-c", writer], capture_output=True, text=True).stdout if args.local \
        else ssh_run(args.machine, args.password, writer)
    print(out.strip())

    # 6) optional restart
    if args.restart:
        restart = "pkill -f ShakerView2.0.x86_64 2>/dev/null; echo 'ShakerView killed (AppManager restarts it)'"
        out = subprocess.run(["bash", "-c", restart], capture_output=True, text=True).stdout if args.local \
            else ssh_run(args.machine, args.password, restart)
        print(out.strip())

    print("\nDone — telemetry restored. Verify ShakerView connects (status turns green).")


if __name__ == "__main__":
    main()
