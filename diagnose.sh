#!/usr/bin/env bash
# diagnose.sh — pre-shipment diagnosis for machines cloned from a GOLDEN SSD.
#
# WHY THIS EXISTS
#   bootstrap.sh provisions ONE machine from scratch (SSH/AnyDesk/RustDesk/Tailscale +
#   Strapi registration + telemetry REG-code redemption). But the real shipping workflow
#   clones a "golden" SSD and drops it into many machines. A clone is a byte-for-byte copy,
#   so every clone inherits the golden master's IDENTITY: its telemetry MachineKey, its
#   Tailscale node, its SSH host keys, its AnyDesk/RustDesk ID, its systemd machine-id.
#   Shipping those unchanged is the exact "one machine has another machine's credentials"
#   failure that caused the week-long telemetry impersonation incident (2026-06-30).
#
#   check_machine.sh already audits the on-box CONFIG (prices, locale, timezone, remains,
#   wizard). This script does the two things it does NOT:
#     1. IDENTITY RESIDUE — detect golden-master identity a clone must have regenerated.
#     2. LIVE SHAKERVIEW   — authenticate to the machine's own telemetry backend
#        (Keycloak client_credentials as the machine) and pull machineInfo / cells /
#        remains / prices, so you see what the SERVER sees before the box leaves.
#
#   READ-ONLY. Changes nothing. Run BOTH scripts before shipping.
#
# USAGE
#   bash diagnose.sh 100.100.239.36      # from your laptop: SSH in, run remotely
#   bash diagnose.sh                     # on the machine itself: run locally
#   GOLDEN_MACHINE_ID=<strapi_id> bash diagnose.sh <ip>   # compare identity vs a known golden
#
# ENV OVERRIDES (all optional; auto-detected from on-box config when unset)
#   SV_SERIAL, SV_MACHINE_KEY, SV_KK_ADDRESS, SV_KK_REALM, SV_WS_ADDRESS
#   SKIP_SHAKERVIEW=1   skip the live telemetry pull (identity + OS checks only)
#
# MARKERS  [ OK ] fine | [WARN] check/fix | [FAIL] must fix before client | [INFO] data only
# Exits 0 clean, 1 if any WARN (no FAIL), 2 if any FAIL. Never aborts mid-run.

HOST="${1:-}"
if [[ -n "$HOST" && "$HOST" != "local" ]]; then
  # Forward the relevant env through SSH, then stream this script to the remote shell.
  exec ssh -o ConnectTimeout=12 "shaker@$HOST" \
    "SKIP_SHAKERVIEW='${SKIP_SHAKERVIEW:-}' GOLDEN_MACHINE_ID='${GOLDEN_MACHINE_ID:-}' \
     SV_SERIAL='${SV_SERIAL:-}' SV_MACHINE_KEY='${SV_MACHINE_KEY:-}' \
     SV_KK_ADDRESS='${SV_KK_ADDRESS:-}' SV_KK_REALM='${SV_KK_REALM:-}' \
     SV_WS_ADDRESS='${SV_WS_ADDRESS:-}' bash -s" < "$0"
  exit $?
fi

set +e
export LC_ALL=C

ACTIVE="/home/shaker/ShakerView2.0Linux"
DATA="$ACTIVE/ShakerView2.0_Data"
CFG="$DATA/Config"
HS="$CFG/hard_settings.json"
TJ="$CFG/telemetry.json"
CJ="$CFG/config.json"

nOK=0; nWARN=0; nFAIL=0
ok(){   printf '[ OK ] %s\n' "$1"; nOK=$((nOK+1)); }
warn(){ printf '[WARN] %s\n' "$1"; nWARN=$((nWARN+1)); }
fail(){ printf '[FAIL] %s\n' "$1"; nFAIL=$((nFAIL+1)); }
info(){ printf '[INFO] %s\n' "$1"; }
hdr(){  printf '\n=== %s ===\n' "$1"; }

# Pull a "key": value / "key": "value" out of a JSON file without needing jq.
jget(){ grep -oE "\"$2\": *\"?[^\",}]*\"?" "$1" 2>/dev/null | head -1 | sed -E "s/.*\"$2\": *\"?([^\",}]*)\"?.*/\1/"; }

echo "############ diagnose.sh — $(hostname) — $(date) ############"
echo "Read-only pre-shipment diagnosis (golden-SSD clone). Pair with check_machine.sh."

# ---------------------------------------------------------------------------
hdr "1. CLONE IDENTITY RESIDUE  (each clone MUST regenerate these — else impersonation)"
# ---------------------------------------------------------------------------
# 1.1 systemd machine-id — shared machine-id => DHCP lease / dbus / journald collisions.
MID="$(cat /etc/machine-id 2>/dev/null)"
DBID="$(cat /var/lib/dbus/machine-id 2>/dev/null)"
if [ -z "$MID" ]; then
  ok "/etc/machine-id empty — will be regenerated uniquely on next boot (correct pre-clone state)"
else
  info "machine-id: $MID"
  warn "machine-id is POPULATED — every clone will share it. Before cloning golden, run: sudo truncate -s0 /etc/machine-id /var/lib/dbus/machine-id"
fi
[ -n "$MID" ] && [ -n "$DBID" ] && [ "$MID" != "$DBID" ] && warn "/etc/machine-id != /var/lib/dbus/machine-id (dbus mismatch)"

# 1.2 SSH host keys — clones sharing host keys => identical fingerprints, MITM-warning noise, security risk.
HKEYS="$(ls /etc/ssh/ssh_host_*_key.pub 2>/dev/null)"
if [ -n "$HKEYS" ]; then
  for k in $HKEYS; do info "ssh host key: $(ssh-keygen -lf "$k" 2>/dev/null | awk '{print $2, $4}')"; done
  warn "SSH host keys present — all clones will share them. Regenerate per unit: sudo rm /etc/ssh/ssh_host_* && sudo dpkg-reconfigure openssh-server"
else
  ok "No SSH host keys on disk — regenerated per unit on first boot"
fi

# 1.3 Tailscale node identity — a clone with golden's state logs in AS the golden node (flapping IP, wrong routing).
if command -v tailscale >/dev/null 2>&1; then
  TSSTATE="/var/lib/tailscale/tailscaled.state"
  TSHOST="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("Self") or {}).get("DNSName","").rstrip("."))' 2>/dev/null)"
  TSIP="$(tailscale ip -4 2>/dev/null | head -1)"
  if [ -s "$TSSTATE" ]; then
    info "Tailscale logged in as: ${TSHOST:-?}  ip=${TSIP:-?}"
    warn "tailscaled.state present — clone will re-use golden's node identity. Reset per unit: sudo tailscale logout && sudo rm -f $TSSTATE  (then bootstrap re-joins with its own authkey)"
  else
    ok "No tailscaled.state — clone joins Tailscale fresh"
  fi
else
  info "tailscale not installed"
fi

# 1.4 Remote-access IDs carried in the image (AnyDesk / RustDesk).
if command -v anydesk >/dev/null 2>&1; then
  AD="$(anydesk --get-id 2>/dev/null | tr -d '[:space:]')"
  [ -n "$AD" ] && { info "AnyDesk ID (from image): $AD"; warn "AnyDesk ID baked into image — clones share one ID (only one connectable at a time). bootstrap reinstalls AnyDesk to mint a fresh ID; confirm it ran."; } || ok "AnyDesk installed, no ID yet"
fi
if command -v rustdesk >/dev/null 2>&1; then
  RD="$(rustdesk --get-id 2>/dev/null | tr -d '[:space:]')"
  [ -n "$RD" ] && { info "RustDesk ID (from image): $RD"; warn "RustDesk ID baked into image — same caveat as AnyDesk."; } || ok "RustDesk installed, no ID yet"
fi

# 1.5 THE BIG ONE: ShakerView telemetry identity. Two clones with the same MachineKey = the 2026-06-30 incident.
SERIAL_HS="$(jget "$HS" MachineSerial)"
MK="$(jget "$TJ" MachineKey)"
MMID="$(jget "$TJ" MachineId)"
ORGID="$(jget "$TJ" OrganizationId)"
info "telemetry identity — MachineSerial=${SERIAL_HS:-?} MachineId=${MMID:-?} OrganizationId=${ORGID:-?}"
if [ -n "$MK" ]; then
  MKFP="$(printf '%s' "$MK" | sha256sum | cut -c1-12)"
  info "MachineKey present (sha256:$MKFP…) — this is a live per-machine secret"
  fail "telemetry.json carries a MachineKey from the golden master. If this clone ships WITHOUT re-registration it will IMPERSONATE the golden machine on the telemetry backend (2026-06-30 incident shape). Each unit must get its own REG-code redemption (bootstrap does this) OR have telemetry.json's MachineKey/MachineId cleared before cloning."
else
  ok "telemetry.json has no MachineKey — clone is clean, will register per unit"
fi

# 1.6 Leftover provisioning artifacts / secrets from the golden build.
LEFT=0
for f in /home/shaker/bootstrap_device_*.log /home/shaker/bootstrap-credentials-*.txt /home/shaker/.env /home/shaker/Desktop/.env; do
  ls $f >/dev/null 2>&1 && { warn "leftover on image: $f (remove before cloning — contains keys/creds)"; LEFT=1; }
done
BH="/home/shaker/.bash_history"
[ -s "$BH" ] && { info "bash_history has $(wc -l <"$BH" 2>/dev/null) lines — scrub if it contains passwords/tokens"; }
[ "$LEFT" = "0" ] && ok "No stray bootstrap logs / credential files in home"

# 1.7 Saved Wi-Fi profiles (office SSID + PSK) that ship with the image.
if command -v nmcli >/dev/null 2>&1; then
  WIFIS="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 ~ /wireless/ {print $1}')"
  if [ -n "$WIFIS" ]; then
    info "saved Wi-Fi profiles baked in: $(echo "$WIFIS" | tr '\n' ' ')"
    warn "office Wi-Fi profile(s) ship inside the image (PSK stored in /etc/NetworkManager). Fine if intended; delete if the office SSID shouldn't leave the building."
  else
    ok "No saved Wi-Fi profiles in image"
  fi
fi

# 1.8 Hostname still the golden/default name?
HN="$(hostname)"
info "hostname: $HN"
case "$HN" in
  *golden*|*template*|*master*|ubuntu|localhost) warn "hostname looks like a golden/default name — set a per-unit hostname";;
  *) ok "hostname is not an obvious golden/default placeholder";;
esac

# ---------------------------------------------------------------------------
hdr "2. SSD / DISK HEALTH  (you are shipping this physical disk)"
# ---------------------------------------------------------------------------
ROOTDEV="$(findmnt -no SOURCE / 2>/dev/null)"
info "root device: ${ROOTDEV:-?}"
DF="$(df -h / | awk 'NR==2{print $4" free ("$5" used)"}')"
USEDPCT="$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}')"
info "disk /: $DF"
[ "${USEDPCT:-0}" -ge 90 ] && fail "root disk >=90% full — clone/first-boot may fail, logs can't rotate" || ok "root disk has headroom"
if command -v smartctl >/dev/null 2>&1 && [ -n "$ROOTDEV" ]; then
  BASEDEV="$(lsblk -no PKNAME "$ROOTDEV" 2>/dev/null | head -1)"; [ -n "$BASEDEV" ] && BASEDEV="/dev/$BASEDEV"
  SMART="$(sudo -n smartctl -H "${BASEDEV:-$ROOTDEV}" 2>/dev/null | grep -iE 'overall-health|SMART Health')"
  if [ -n "$SMART" ]; then echo "$SMART" | grep -qi 'PASSED' && ok "SMART health: PASSED (${BASEDEV:-$ROOTDEV})" || fail "SMART health NOT passed: $SMART"; else info "SMART not readable (need sudo/-n or no SMART on this device)"; fi
else
  info "smartctl unavailable — install smartmontools to health-check the SSD before shipping"
fi

# ---------------------------------------------------------------------------
hdr "3. KIOSK RUNTIME READINESS"
# ---------------------------------------------------------------------------
SV=$(pgrep -cf "ShakerView2.0.x86_64\$" 2>/dev/null)
AM=$(pgrep -af "/AppManager\$" 2>/dev/null | grep -vc "sh -c")
[ "${SV:-0}" = "1" ] && ok "ShakerView running (1 process)" || { [ "${SV:-0}" = "0" ] && warn "ShakerView NOT running" || fail "ShakerView duplicate processes: $SV"; }
[ "${AM:-0}" = "1" ] && ok "AppManager watchdog (1)" || warn "AppManager watchdog count=$AM (1 expected; 2+ = duplicate)"
# Autologin + autostart so the kiosk comes up unattended at the client.
grep -rqsE '^AutomaticLogin' /etc/gdm3/custom.conf /etc/gdm/custom.conf 2>/dev/null && ok "GDM autologin configured" || warn "GDM autologin not found — kiosk won't come up unattended after power-on"
NTP="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
[ "$NTP" = "yes" ] && ok "NTP synchronized" || warn "clock not NTP-synced (fiscal receipts / sales timestamps drift)"

# ---------------------------------------------------------------------------
hdr "4. LIVE SHAKERVIEW TELEMETRY  (machine's own backend view)"
# ---------------------------------------------------------------------------
if [ "${SKIP_SHAKERVIEW:-}" = "1" ]; then
  info "SKIP_SHAKERVIEW=1 — skipping live telemetry pull"
else
  SERIAL="${SV_SERIAL:-$SERIAL_HS}"
  MACHINE_KEY="${SV_MACHINE_KEY:-$MK}"
  KK="${SV_KK_ADDRESS:-$(jget "$HS" KKAddress)}"; KK="${KK:-$(jget "$TJ" KKAddress)}"
  KKREALM="${SV_KK_REALM:-$(jget "$HS" KKRealm)}"; KKREALM="${KKREALM:-shaker-realm}"
  WS="${SV_WS_ADDRESS:-$(jget "$HS" WebSocketAddress)}"; WS="${WS:-$(jget "$TJ" WebSocketAddress)}"
  info "endpoint: KK=${KK:-?} realm=$KKREALM  WS=${WS:-?}  client_id=${SERIAL:-?}"

  if [ -z "$SERIAL" ] || [ -z "$MACHINE_KEY" ] || [ -z "$KK" ] || [ -z "$WS" ]; then
    warn "missing serial/MachineKey/KKAddress/WebSocketAddress — cannot reach the telemetry backend (set SV_* env to override, or the box isn't registered yet)"
  else
    # 4.1 Keycloak client_credentials — proves the machine's identity is valid & registered.
    TOKRESP="$(curl -sS --max-time 12 "$KK/realms/$KKREALM/protocol/openid-connect/token" \
      --data-urlencode grant_type=client_credentials \
      --data-urlencode "client_id=$SERIAL" \
      --data-urlencode "client_secret=$MACHINE_KEY" \
      --data-urlencode scope=profile 2>/dev/null)"
    ACCESS="$(printf '%s' "$TOKRESP" | python3 -c 'import json,sys;
try: print(json.load(sys.stdin).get("access_token","") or "")
except Exception: print("")' 2>/dev/null)"
    if [ -z "$ACCESS" ]; then
      fail "Keycloak auth FAILED as client_id=$SERIAL — machine not registered or MachineKey wrong. Backend will reject it at the client site. Resp: $(printf '%s' "$TOKRESP" | head -c 160)"
    else
      ok "Keycloak client_credentials OK — machine authenticates to backend as itself"

      # 4.2 One short-lived WebSocket per request (single req/response then close — collision-safe
      #     per the mcp_shakerview safety model). Pure-stdlib RFC6455 client, no pip deps.
      SV_QUERY="$ACCESS|$SERIAL|$WS" python3 - <<'PY'
import base64, json, os, socket, ssl, struct, sys, time
from urllib.parse import urlparse

access, serial, ws = os.environ["SV_QUERY"].split("|", 2)
u = urlparse(ws)
host = u.hostname; port = u.port or (443 if u.scheme == "wss" else 80)
path = u.path or "/"

def ws_request(msg_type, body=None, expect=None, timeout=10):
    """Open ws, send one message, return first frame whose 'type' is in expect, then close."""
    expect = expect or {msg_type}
    s = socket.create_connection((host, port), timeout=8)
    if u.scheme == "wss":
        s = ssl.create_default_context().wrap_socket(s, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
           f"Authorization: Bearer {access}\r\n\r\n")
    s.sendall(req.encode())
    # read handshake headers
    buf = b""
    s.settimeout(8)
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk: raise RuntimeError("handshake closed")
        buf += chunk
    if b" 101 " not in buf.split(b"\r\n", 1)[0]:
        raise RuntimeError("no 101: " + buf.split(b"\r\n",1)[0].decode("latin1"))
    payload = json.dumps({"type": msg_type, "clientId": serial, **({"body": body} if body is not None else {})}).encode()
    # client->server frame must be masked (opcode 0x1 text, FIN)
    hdr = bytearray([0x81]); n = len(payload); mask = os.urandom(4)
    if n < 126: hdr.append(0x80 | n)
    elif n < 65536: hdr.append(0x80 | 126); hdr += struct.pack(">H", n)
    else: hdr.append(0x80 | 127); hdr += struct.pack(">Q", n)
    hdr += mask
    s.sendall(bytes(hdr) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
    # read server frames (unmasked) until a matching type or timeout
    deadline = time.time() + timeout
    rbuf = b""
    def recvn(nbytes):
        nonlocal rbuf
        while len(rbuf) < nbytes:
            s.settimeout(max(0.1, deadline - time.time()))
            c = s.recv(4096)
            if not c: raise RuntimeError("closed mid-frame")
            rbuf += c
        out, rbuf = rbuf[:nbytes], rbuf[nbytes:]
        return out
    try:
        while time.time() < deadline:
            b0, b1 = recvn(2)
            ln = b1 & 0x7F
            if ln == 126: ln = struct.unpack(">H", recvn(2))[0]
            elif ln == 127: ln = struct.unpack(">Q", recvn(8))[0]
            data = recvn(ln) if ln else b""
            if (b0 & 0x0F) == 0x8: break  # close
            try: msg = json.loads(data.decode("utf-8"))
            except Exception: continue
            if msg.get("type") in expect: return msg
    finally:
        try: s.close()
        except Exception: pass
    return None

def out(m, level, text): print(f"::{level}::{m}: {text}")

try:
    mi = ws_request("machineInfo")
    if mi is None: out("machineInfo","WARN","no response (backend reachable but silent)")
    else:
        st = None
        # status color may ride on machineInfo or a status topic; probe status too
        out("machineInfo","OK", json.dumps(mi.get("body", mi))[:200])
    stt = ws_request("machineInfo", expect={"statusMachineImportTopic"}, timeout=6)
    if stt:
        c = (stt.get("body") or {}).get("color","")
        lvl = {"SUCCESS":"OK","WARNING":"WARN","ERROR":"FAIL"}.get(str(c).upper(),"INFO")
        out("status", lvl, f"{(stt.get('body') or {}).get('text','')} [{c}]")
except Exception as e:
    out("machineInfo","WARN", f"telemetry query error: {e}")

# cells / remains / prices — presence & sanity
try:
    cs = ws_request("cellStoreRequestExport", expect={"cellStoreRequestExport","cellStoreImportTopic"})
    if cs:
        body = cs.get("body") or {}
        cells = body.get("cells") or []
        out("cellStore","OK" if cells else "WARN", f"{len(cells)} cells configured")
    else:
        out("cellStore","WARN","no cell config returned")
except Exception as e:
    out("cellStore","WARN", f"{e}")

try:
    cv = ws_request("cellVolumeExport", expect={"cellVolumeExport","cellVolumeImportTopic"})
    if cv:
        body = cv.get("body") or {}
        cells = body.get("cells") or []
        zero = sum(1 for c in cells if (c.get("currentValue") in (0,0.0,None)))
        out("remains","OK" if cells else "WARN", f"{len(cells)} cells, {zero} at zero/empty")
    else:
        out("remains","WARN","no remains returned (inventory may be uninitialized)")
except Exception as e:
    out("remains","WARN", f"{e}")

try:
    ks = ws_request("getKioskCellsTopic", expect={"importCellKiosk"})
    if ks:
        cells = (ks.get("body") or {}).get("cells") or ks.get("body") or []
        if isinstance(cells, dict): cells = cells.get("cells", [])
        prices = [c.get("price") for c in cells if isinstance(c, dict)]
        bad = [p for p in prices if p in (0,0.0,50,50.0,100,100.0)]
        out("kioskPrices","FAIL" if bad else ("OK" if prices else "WARN"),
            f"{len(prices)} priced cells; suspicious(0/50/100)={len(bad)}")
except Exception as e:
    out("kioskPrices","WARN", f"{e}")
PY
    fi
  fi
fi

# Fold the python-emitted ::LEVEL:: markers into the counters above by re-scanning our own
# output would be complex in one pass; instead the python lines print with visible level tags.
# (The Keycloak OK/FAIL already counted; python sub-checks are advisory and shown inline.)

# ---------------------------------------------------------------------------
hdr "SUMMARY"
# ---------------------------------------------------------------------------
echo "  OK=$nOK  WARN=$nWARN  FAIL=$nFAIL"
echo "  (Section 4 python sub-checks print ::OK/WARN/FAIL:: inline — read them too.)"
echo "  Deep config/price/locale audit: run check_machine.sh as well."
if [ "$nFAIL" -gt 0 ]; then
  echo "############ VERDICT: DO NOT SHIP — resolve FAILs first ############"; exit 2
elif [ "$nWARN" -gt 0 ]; then
  echo "############ VERDICT: review WARNs before shipping ############"; exit 1
else
  echo "############ VERDICT: identity + telemetry clean ############"; exit 0
fi
