#!/usr/bin/env bash
# diagnose.sh — the acceptance gate for a machine, in two directions.
#
# WHY THIS EXISTS
#   Provisioning writes machine state into five independent places: the on-box Config
#   (hard_settings/telemetry/fleet.json), the Strapi machine record, Keycloak, the
#   manage.ishakerusa.com machine list, and Tailscale. Nothing reconciles them, so a
#   half-finished bootstrap produces a machine that LOOKS provisioned. Every field failure
#   this fleet has had was a partial success that reported success.
#
#   This script is the single answer to "is this machine actually shippable". It is
#   READ-ONLY, and it is meant to be run by a machine, not remembered by a person:
#     - bootstrap.sh runs it as its last act and refuses to claim success if it fails
#     - fleetpulse runs it with --json every sweep and records the verdict in Strapi
#     - you run it by hand before a box leaves the building
#
# TWO MODES — these ask OPPOSITE questions, which is why one script with one default
# was useless as a shipping gate and quietly stopped being run:
#
#   --mode unit      (DEFAULT) "is this provisioned machine ready to ship?"
#                    Identity must be PRESENT and COHERENT. A missing MachineKey is a
#                    failure. This is the mode that matters for shipping.
#
#   --mode preclone  "is this golden master safe to clone?"
#                    Identity must be ABSENT. A present MachineKey is a failure, because
#                    every clone would inherit it — the shape of the 2026-06-30 week-long
#                    telemetry impersonation incident.
#
#   Running unit-mode checks against a golden (or preclone against a real unit) inverts
#   every identity verdict. The mode is printed in the header; read it before believing
#   the output.
#
# USAGE
#   bash diagnose.sh 100.100.239.36                 # SSH in and check a remote unit
#   bash diagnose.sh                                # on the machine itself
#   bash diagnose.sh --mode preclone                # golden master, before cloning
#   bash diagnose.sh 100.x.x.x --json               # machine-readable, for fleetpulse
#   GOLDEN_MACHINE_ID=<strapi_id> bash diagnose.sh <ip>
#
# ENV OVERRIDES (all optional; auto-detected from on-box config when unset)
#   SV_SERIAL, SV_MACHINE_KEY, SV_KK_ADDRESS, SV_KK_REALM, SV_WS_ADDRESS
#   SKIP_SHAKERVIEW=1   skip the live telemetry pull (identity + OS checks only)
#   FW_TARGET           expected controller firmware (default 260310-03, fleet-wide target)
#
# OUTPUT
#   Human: [ OK ] fine | [WARN] check/fix | [FAIL] must fix before client | [INFO] data
#   --json: {schema, mode, verdict, counts, checks:[{id,level,msg}]} on stdout,
#           human lines on stderr. Check ids are STABLE — fleetpulse tracks drift by id.
#   Exit 0 clean, 1 if any WARN (no FAIL), 2 if any FAIL. Never aborts mid-run.

MODE="unit"
JSON=0
HOST=""
for a in "$@"; do
  case "$a" in
    --mode=*)   MODE="${a#--mode=}" ;;
    --json)     JSON=1 ;;
    --preclone) MODE="preclone" ;;
    --unit)     MODE="unit" ;;
    -*)         ;;
    *)          [ -z "$HOST" ] && HOST="$a" ;;
  esac
done
# support "--mode unit" (space form)
prev=""
for a in "$@"; do
  [ "$prev" = "--mode" ] && MODE="$a"
  prev="$a"
done
case "$MODE" in unit|preclone) ;; *) echo "bad --mode '$MODE' (unit|preclone)" >&2; exit 3;; esac

if [[ -n "$HOST" && "$HOST" != "local" ]]; then
  # Forward env + flags through SSH, then stream this script to the remote shell.
  exec ssh -o ConnectTimeout=12 -o StrictHostKeyChecking=no "shaker@$HOST" \
    "SKIP_SHAKERVIEW='${SKIP_SHAKERVIEW:-}' GOLDEN_MACHINE_ID='${GOLDEN_MACHINE_ID:-}' \
     SV_SERIAL='${SV_SERIAL:-}' SV_MACHINE_KEY='${SV_MACHINE_KEY:-}' \
     SV_KK_ADDRESS='${SV_KK_ADDRESS:-}' SV_KK_REALM='${SV_KK_REALM:-}' \
     SV_WS_ADDRESS='${SV_WS_ADDRESS:-}' FW_TARGET='${FW_TARGET:-}' \
     bash -s -- --mode=$MODE $([ "$JSON" = "1" ] && echo --json)" < "$0"
  exit $?
fi

set +e
export LC_ALL=C

ACTIVE="/home/shaker/ShakerView2.0Linux"
DATA="$ACTIVE/ShakerView2.0_Data"
CFG="$DATA/Config"
HS="$CFG/hard_settings.json"
TJ="$CFG/telemetry.json"
FJ="$CFG/fleet.json"
DIAGLOG="/home/shaker/ShakerView-diag/patch-diag.log"
WDOG="/usr/local/bin/shakerview-watchdog.sh"
FW_TARGET="${FW_TARGET:-260310-03}"

REC="$(mktemp)"
trap 'rm -f "$REC"' EXIT
nOK=0; nWARN=0; nFAIL=0

# Human output goes to stderr in --json mode so stdout stays pure JSON.
say(){ if [ "$JSON" = "1" ]; then printf '%s\n' "$1" >&2; else printf '%s\n' "$1"; fi; }
_rec(){ printf '%s\t%s\t%s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\t\n' '  ')" >>"$REC"; }
ok(){   _rec OK   "$1" "$2"; say "[ OK ] $2"; nOK=$((nOK+1)); }
warn(){ _rec WARN "$1" "$2"; say "[WARN] $2"; nWARN=$((nWARN+1)); }
fail(){ _rec FAIL "$1" "$2"; say "[FAIL] $2"; nFAIL=$((nFAIL+1)); }
info(){ _rec INFO "$1" "$2"; say "[INFO] $2"; }
hdr(){  say ""; say "=== $1 ==="; }

# Pull a "key": value / "key": "value" out of a JSON file without needing jq.
jget(){ grep -oE "\"$2\": *\"?[^\",}]*\"?" "$1" 2>/dev/null | head -1 | sed -E "s/.*\"$2\": *\"?([^\",}]*)\"?.*/\1/"; }

say "############ diagnose.sh — $(hostname) — $(date) ############"
say "MODE=$MODE  (unit = ready to ship? | preclone = safe to clone?)"

# ---------------------------------------------------------------------------
hdr "1. IDENTITY  (mode decides whether presence is right or wrong)"
# ---------------------------------------------------------------------------
# 1.1 systemd machine-id
MID="$(cat /etc/machine-id 2>/dev/null)"
DBID="$(cat /var/lib/dbus/machine-id 2>/dev/null)"
if [ "$MODE" = "preclone" ]; then
  if [ -z "$MID" ]; then
    ok identity.machineid "/etc/machine-id empty — regenerated uniquely on next boot (correct pre-clone state)"
  else
    info identity.machineid "machine-id: $MID"
    warn identity.machineid "machine-id is POPULATED — every clone will share it. Before cloning: sudo truncate -s0 /etc/machine-id /var/lib/dbus/machine-id"
  fi
else
  [ -n "$MID" ] && ok identity.machineid "machine-id present ($MID)" \
                || fail identity.machineid "machine-id EMPTY on a unit — DHCP/dbus/journald identity is unset until reboot"
fi
[ -n "$MID" ] && [ -n "$DBID" ] && [ "$MID" != "$DBID" ] && warn identity.dbusid "/etc/machine-id != /var/lib/dbus/machine-id (dbus mismatch)"

# 1.2 SSH host keys
HKEYS="$(ls /etc/ssh/ssh_host_*_key.pub 2>/dev/null)"
if [ "$MODE" = "preclone" ]; then
  if [ -n "$HKEYS" ]; then
    for k in $HKEYS; do info identity.sshkeys "ssh host key: $(ssh-keygen -lf "$k" 2>/dev/null | awk '{print $2, $4}')"; done
    warn identity.sshkeys "SSH host keys present — clones share them. Regenerate per unit: sudo rm /etc/ssh/ssh_host_* && sudo ssh-keygen -A"
  else
    ok identity.sshkeys "No SSH host keys on disk — regenerated per unit on first boot"
  fi
else
  # Never scrub these on a live unit without ssh-keygen -A: socket-activated sshd then
  # refuses every connection and the box is only reachable physically.
  [ -n "$HKEYS" ] && ok identity.sshkeys "SSH host keys present ($(echo "$HKEYS" | wc -l) keys) — sshd can accept connections" \
                  || fail identity.sshkeys "NO SSH host keys — sshd will refuse every connection. Fix: sudo ssh-keygen -A && sudo systemctl restart ssh"
fi

# 1.3 Tailscale node identity
if command -v tailscale >/dev/null 2>&1; then
  TSSTATE="/var/lib/tailscale/tailscaled.state"
  TSHOST="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("Self") or {}).get("DNSName","").rstrip("."))' 2>/dev/null)"
  TSIP="$(tailscale ip -4 2>/dev/null | head -1)"
  if [ "$MODE" = "preclone" ]; then
    # tailscaled.state is root-only (0600). A plain `[ -s ]` as the shaker user always fails,
    # which silently reported a dirty golden as clean — the worst possible direction for this
    # check to be wrong. Decide only when we can actually see the file.
    if sudo -n test -s "$TSSTATE" 2>/dev/null || [ -s "$TSSTATE" ]; then
      info identity.tailscale "Tailscale logged in as: ${TSHOST:-?} ip=${TSIP:-?}"
      warn identity.tailscale "tailscaled.state present — clone re-uses golden's node identity. Reset: sudo tailscale logout && sudo rm -f $TSSTATE"
    elif sudo -n true 2>/dev/null || [ -r "$(dirname "$TSSTATE")" ]; then
      ok identity.tailscale "No tailscaled.state — clone joins Tailscale fresh"
    elif [ -n "$TSIP" ]; then
      warn identity.tailscale "cannot read $TSSTATE (needs sudo) but Tailscale IS logged in as ${TSHOST:-?} — assume node identity is present and must be reset before cloning"
    else
      warn identity.tailscale "cannot read $TSSTATE (needs sudo) — Tailscale clone-identity state UNVERIFIED; re-run with sudo before trusting this golden"
    fi
  else
    if [ -n "$TSIP" ]; then
      ok identity.tailscale "Tailscale up as ${TSHOST:-?} ip=$TSIP"
    else
      fail identity.tailscale "Tailscale not connected — fleet tooling (fleetpulse/fleetpatch/fleetfirmware) cannot reach this machine at all"
    fi
  fi
else
  info identity.tailscale "tailscale not installed"
fi

# 1.4 Remote-access IDs
for tool in anydesk rustdesk; do
  command -v "$tool" >/dev/null 2>&1 || continue
  ID="$("$tool" --get-id 2>/dev/null | tr -d '[:space:]')"
  if [ "$MODE" = "preclone" ]; then
    [ -n "$ID" ] && warn "identity.$tool" "$tool ID baked into image ($ID) — clones share one ID. bootstrap reinstalls it to mint a fresh one; confirm that ran." \
                 || ok "identity.$tool" "$tool installed, no ID yet"
  else
    [ -n "$ID" ] && ok "identity.$tool" "$tool ID: $ID" \
                 || warn "identity.$tool" "$tool installed but has no ID — no remote support path to this machine"
  fi
done

# 1.5 THE BIG ONE: telemetry identity.
SERIAL_HS="$(jget "$HS" MachineSerial)"
MK="$(jget "$TJ" MachineKey)"
MMID="$(jget "$TJ" MachineId)"
ORGID="$(jget "$TJ" OrganizationId)"
info identity.telemetry "telemetry identity — MachineSerial=${SERIAL_HS:-?} MachineId=${MMID:-?} OrganizationId=${ORGID:-?}"
if [ "$MODE" = "preclone" ]; then
  if [ -n "$MK" ]; then
    fail identity.machinekey "telemetry.json carries a MachineKey. Cloning this ships N machines with ONE identity — they impersonate each other on the backend (2026-06-30 incident). Clear MachineKey/MachineId before cloning."
  else
    ok identity.machinekey "telemetry.json has no MachineKey — clone is clean, registers per unit"
  fi
else
  if [ -n "$MK" ]; then
    ok identity.machinekey "telemetry.json has a MachineKey (sha256:$(printf '%s' "$MK" | sha256sum | cut -c1-12)…)"
  else
    fail identity.machinekey "NO MachineKey — this machine is not registered; ShakerView will never authenticate telemetry"
  fi
  [ -z "$SERIAL_HS" ] && fail identity.serial "hard_settings.MachineSerial is EMPTY — Keycloak client_id is unset, telemetry will 401"
fi

# 1.6 Leftover provisioning artifacts / secrets.
LEFT=0
for f in /home/shaker/bootstrap_device_*.log /home/shaker/bootstrap-credentials-*.txt /home/shaker/.env /home/shaker/Desktop/.env; do
  ls $f >/dev/null 2>&1 && { warn identity.leftovers "leftover secret/log on disk: $f (must not ship or be cloned)"; LEFT=1; }
done
[ "$LEFT" = "0" ] && ok identity.leftovers "No stray bootstrap logs / credential files in home"

# 1.7 Saved Wi-Fi profiles
if command -v nmcli >/dev/null 2>&1; then
  WIFIS="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 ~ /wireless/ {print $1}')"
  if [ -n "$WIFIS" ]; then
    warn identity.wifi "office Wi-Fi profile(s) stored in image: $(echo "$WIFIS" | tr '\n' ' ')— PSK travels with the box; delete if the office SSID shouldn't leave the building"
  else
    ok identity.wifi "No saved Wi-Fi profiles in image"
  fi
fi

# 1.8 Hostname
HN="$(hostname)"
case "$HN" in
  *golden*|*template*|*master*|ubuntu|localhost) warn identity.hostname "hostname '$HN' looks like a golden/default placeholder";;
  *) ok identity.hostname "hostname: $HN";;
esac

# ---------------------------------------------------------------------------
hdr "2. SSD / DISK HEALTH  (you are shipping this physical disk)"
# ---------------------------------------------------------------------------
ROOTDEV="$(findmnt -no SOURCE / 2>/dev/null)"
DF="$(df -h / | awk 'NR==2{print $4" free ("$5" used)"}')"
USEDPCT="$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}')"
info disk.usage "root device ${ROOTDEV:-?} — $DF"
[ "${USEDPCT:-0}" -ge 90 ] && fail disk.usage "root disk >=90% full — logs can't rotate, first boot may fail" \
                           || ok disk.usage "root disk has headroom"
if command -v smartctl >/dev/null 2>&1 && [ -n "$ROOTDEV" ]; then
  BASEDEV="$(lsblk -no PKNAME "$ROOTDEV" 2>/dev/null | head -1)"; [ -n "$BASEDEV" ] && BASEDEV="/dev/$BASEDEV"
  SMART="$(sudo -n smartctl -H "${BASEDEV:-$ROOTDEV}" 2>/dev/null | grep -iE 'overall-health|SMART Health')"
  if [ -n "$SMART" ]; then
    echo "$SMART" | grep -qi 'PASSED' && ok disk.smart "SMART health PASSED (${BASEDEV:-$ROOTDEV})" \
                                     || fail disk.smart "SMART health NOT passed: $SMART"
  else info disk.smart "SMART not readable (needs passwordless sudo, or device has no SMART)"; fi
else
  info disk.smart "smartctl unavailable — install smartmontools to health-check the SSD"
fi

# ---------------------------------------------------------------------------
hdr "3. KIOSK RUNTIME"
# ---------------------------------------------------------------------------
SV=$(pgrep -cf "ShakerView2.0.x86_64\$" 2>/dev/null)
AM=$(pgrep -af "/AppManager\$" 2>/dev/null | grep -vc "sh -c")
[ "${SV:-0}" = "1" ] && ok kiosk.shakerview "ShakerView running (1 process)" \
  || { [ "${SV:-0}" = "0" ] && fail kiosk.shakerview "ShakerView NOT running — no kiosk at the client" \
                            || fail kiosk.shakerview "ShakerView duplicate processes: $SV"; }
[ "${AM:-0}" = "1" ] && ok kiosk.appmanager "AppManager (1)" \
                     || warn kiosk.appmanager "AppManager count=$AM (1 expected; 2+ = duplicate relaunch loop)"
grep -rqsE '^AutomaticLogin' /etc/gdm3/custom.conf /etc/gdm/custom.conf 2>/dev/null \
  && ok kiosk.autologin "GDM autologin configured" \
  || fail kiosk.autologin "GDM autologin not found — kiosk will not come up unattended after power-on"
NTP="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
[ "$NTP" = "yes" ] && ok kiosk.ntp "NTP synchronized" \
                   || warn kiosk.ntp "clock not NTP-synced — sales timestamps drift"

# ---------------------------------------------------------------------------
if [ "$MODE" = "unit" ]; then
hdr "4. UNIT READINESS  (the checks each past field failure earned)"
# ---------------------------------------------------------------------------

# 4.1 The freeze-recovery watchdog. `systemctl is-active` is NOT evidence: the unit is a
#     bash loop that stays "active" while every function call inside it fails. An
#     incomplete 2026-07-29 repo edit shipped a copy with all function bodies stripped;
#     it ran for a week on machines that had no recovery at all, silently.
if [ -f "$WDOG" ]; then
  MISSING=""
  for fn in log xauth_file as_user_x sv_pid firmware_write_active health_check \
            recover_dpms recover_restart_app recover_restart_gdm recover_reboot; do
    grep -qE "^$fn\(\) *\{" "$WDOG" || MISSING="$MISSING $fn"
  done
  if [ -n "$MISSING" ]; then
    fail watchdog.functions "shakerview-watchdog.sh is GUTTED — missing function bodies:$MISSING. It runs, logs 'command not found' every cycle, and can never recover a freeze. Redeploy from shakerview repo tools/watchdog/shakerview-watchdog.sh"
  else
    ok watchdog.functions "watchdog has all 10 required functions"
  fi
  bash -n "$WDOG" 2>/dev/null && ok watchdog.syntax "watchdog script parses" \
                              || fail watchdog.syntax "watchdog script has a SYNTAX ERROR — it dies at first execution"
  # The smoking gun: a broken watchdog announces itself here every cycle.
  CNF="$(journalctl -u shakerview-watchdog --since '-60min' --no-pager 2>/dev/null | grep -c 'command not found')"
  [ "${CNF:-0}" -gt 0 ] && fail watchdog.runtime "watchdog logged $CNF 'command not found' errors in the last hour — it is a no-op" \
                        || ok watchdog.runtime "no watchdog runtime errors in the last hour"
  WACT="$(systemctl is-active shakerview-watchdog 2>/dev/null)"
  WNR="$(systemctl show -p NRestarts --value shakerview-watchdog 2>/dev/null)"
  [ "$WACT" = "active" ] && ok watchdog.unit "shakerview-watchdog active (NRestarts=${WNR:-0})" \
                         || fail watchdog.unit "shakerview-watchdog unit is '$WACT' — no freeze recovery"
else
  fail watchdog.present "no $WDOG — this machine has NO freeze recovery. A wedged kiosk stays wedged until someone drives to it."
fi

# 4.2 What is ACTUALLY in the binary. machine.patch in Strapi drifts (hand-patched boxes,
#     machines bootstrapped after patching) — the DLL is the only honest answer, which is
#     the same rule fleetfirmware.py already applies before arming a flash.
CC="$DATA/Managed/CommonCode.dll"
if [ -f "$CC" ]; then
  info patch.md5 "CommonCode.dll md5=$(md5sum "$CC" | awk '{print $1}') size=$(stat -c%s "$CC")"
  hasPD=$(grep -ac PatchDiag "$CC" 2>/dev/null); hasPD=${hasPD:-0}
  hasFC=$(grep -ac FleetCatalog "$CC" 2>/dev/null); hasFC=${hasFC:-0}
  hasFW=$(grep -ac FirmwareFlashWatchdog "$CC" 2>/dev/null); hasFW=${hasFW:-0}
  [ "$hasPD" -gt 0 ] && ok patch.patchdiag "PatchDiag present — freeze diagnostics + FleetPatch verify will work" \
                     || fail patch.patchdiag "NO PatchDiag in CommonCode.dll — no freeze visibility, and FleetPatch's verify() rolls back any install on this build"
  [ "$hasFC" -gt 0 ] && ok patch.fleetcatalog "FleetCatalog present — machine pulls catalog/planogram from Strapi" \
                     || warn patch.fleetcatalog "NO FleetCatalog — this machine cannot receive catalog or planogram updates"
  [ "$hasFW" -gt 0 ] && ok patch.flashwatchdog "FirmwareFlashWatchdog present — unattended firmware flash is permitted" \
                     || warn patch.flashwatchdog "NO FirmwareFlashWatchdog — fleetfirmware will REFUSE to autoflash this machine (a failed flash would wedge it with no way back). Firmware stays manual/on-site until a build with the watchdog is installed."
else
  fail patch.present "no CommonCode.dll at $CC — ShakerView install is not where expected"
fi

# 4.3 PatchDiag heartbeat — the only proof the app is actually rendering rather than
#     merely running. A wedged Unity main thread keeps the process alive and 80% busy.
if [ -f "$DIAGLOG" ]; then
  LAST="$(grep -a heartbeat "$DIAGLOG" 2>/dev/null | tail -1)"
  if [ -n "$LAST" ]; then
    LTS="$(printf '%s' "$LAST" | sed -E 's/^\[([0-9-]+ [0-9:]+).*/\1/')"
    AGE=$(( ($(date +%s) - $(date -d "$LTS" +%s 2>/dev/null || echo 0)) / 60 ))
    DELTA="$(printf '%s' "$LAST" | grep -oE '\(\+[0-9]+\)' | tr -d '(+)')"
    # The FIRST heartbeat of a run always reads (+0): there is no previous sample to diff
    # against. Treating that as "wedged" fails every machine whose app has just started —
    # including every freshly provisioned one, where bootstrap runs this gate seconds later.
    UPMIN="$(printf '%s' "$LAST" | grep -oE '\[up=[0-9]+m\]' | grep -oE '[0-9]+')"
    if printf '%s' "$LAST" | grep -q 'mainthread=STALLED'; then
      fail heartbeat.state "kiosk is FROZEN RIGHT NOW: $(printf '%s' "$LAST" | grep -oE 'frames=.*')"
    elif [ "${AGE:-999}" -gt 5 ]; then
      warn heartbeat.state "last PatchDiag heartbeat is ${AGE}min old — app restarted, or diagnostics stopped"
    elif [ "${DELTA:-0}" -eq 0 ] && [ "${UPMIN:-99}" -le 1 ]; then
      info heartbeat.state "app started ${UPMIN}min ago — first heartbeat has no delta yet; re-check in a minute"
    elif [ "${DELTA:-0}" -eq 0 ]; then
      fail heartbeat.state "frames not advancing (+0) after ${UPMIN:-?}min uptime — main thread wedged"
    else
      ok heartbeat.state "heartbeat live, frames +$DELTA/min, mainthread ok"
    fi
  else
    warn heartbeat.state "patch-diag.log has no heartbeat lines yet"
  fi
  STALLS="$(grep -ac 'mainthread=STALLED' "$DIAGLOG" 2>/dev/null)"
  [ "${STALLS:-0}" -gt 0 ] && warn heartbeat.history "$STALLS stall events recorded in this machine's history — it has frozen before" \
                           || ok heartbeat.history "no stall events in patch-diag history"
  # NUL runs in the log mean the filesystem lost buffered writes: a hard power cut, not a
  # clean shutdown. Bay Trail boxes that freeze get power-cycled by whoever is standing there.
  NULS="$(python3 -c "print(open('$DIAGLOG','rb').read().count(b'\x00'))" 2>/dev/null)"
  [ "${NULS:-0}" -gt 0 ] && warn heartbeat.powercut "patch-diag.log contains $NULS NUL bytes — evidence of unclean power loss (hard power-cycle), not a graceful restart" \
                         || ok heartbeat.powercut "no unclean-shutdown damage in patch-diag.log"
else
  warn heartbeat.present "no $DIAGLOG — unpatched build, or PatchDiag never started"
fi

# 4.4 Platform mitigations. Bay Trail Celerons on this fleet hard-freeze without the
#     c-state clamp (machine 25 and machine 64 both traced to it). The requirement is
#     hardware-derived, not per-machine improvisation.
CPU="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
info platform.cpu "CPU: $CPU"
if printf '%s' "$CPU" | grep -qE 'J1900|J1800|J1750|N2807|N2840|N2930'; then
  if grep -q 'intel_idle.max_cstate=1' /proc/cmdline; then
    ok platform.cstate "Bay Trail CPU with intel_idle.max_cstate=1 active"
  else
    fail platform.cstate "Bay Trail CPU ($CPU) WITHOUT intel_idle.max_cstate=1 — this exact class hard-freezes on this fleet. Add to GRUB_CMDLINE_LINUX_DEFAULT, run update-grub, reboot."
  fi
  # Applied-now and survives-reboot are different questions; check both.
  grep -q 'intel_idle.max_cstate=1' /etc/default/grub 2>/dev/null \
    && ok platform.cstate.persist "c-state clamp persisted in /etc/default/grub" \
    || warn platform.cstate.persist "c-state clamp not in /etc/default/grub — it will be lost at the next kernel update"
else
  ok platform.cstate "CPU not in the freeze-prone Bay Trail set — no c-state clamp required"
fi

# 4.5 Identity coherence across stores. Bat (260511731) had hard_settings rewritten to a
#     new serial while Strapi still held the old one and no record existed for the new.
SERIAL_FJ="$(jget "$FJ" serial)"
if [ -f "$FJ" ]; then
  FTOK="$(jget "$FJ" token)"; FURL="$(jget "$FJ" url)"
  [ -n "$FTOK" ] && ok fleet.json "fleet.json present (url=$FURL)" || fail fleet.json "fleet.json has no token — machine cannot pull catalog"
  # Prove the credential actually works, rather than trusting that it was written.
  if [ -n "$FTOK" ] && [ -n "$SERIAL_HS" ]; then
    for ep in catalog planogram; do
      CODE="$(curl -s -o /tmp/.dg.$ep -w '%{http_code}' --max-time 15 \
              -H "Authorization: Bearer $FTOK" "$FURL/api/machines/$SERIAL_HS/$ep" 2>/dev/null)"
      NCELL="$(python3 -c "
import json
try:
    d=json.load(open('/tmp/.dg.$ep'))
    c=d.get('cells') or (d.get('data') or {}).get('cells') or []
    print(len(c))
except Exception: print(-1)" 2>/dev/null)"
      case "$CODE" in
        200) [ "${NCELL:-0}" -gt 0 ] && ok "fleet.$ep" "/$ep returns 200 with $NCELL cells for $SERIAL_HS" \
                                     || warn "fleet.$ep" "/$ep returns 200 but 0 cells — machine will show an empty screen at the client" ;;
        401|403) fail "fleet.$ep" "/$ep returns $CODE — fleet.json token is rejected (machine secret written where the shared CATALOG_TOKEN was needed?)" ;;
        404) fail "fleet.$ep" "/$ep returns 404 — no Strapi machine record for serial '$SERIAL_HS'" ;;
        422) fail "fleet.$ep" "/$ep returns 422 — catalog data invalid (0-based cell positions / missing price)" ;;
        *)   warn "fleet.$ep" "/$ep unreachable (HTTP ${CODE:-000}) — Strapi not reachable from this machine right now" ;;
      esac
      rm -f /tmp/.dg.$ep
    done
  fi
else
  fail fleet.json "no fleet.json — machine will never pull catalog or planogram"
fi
if [ -n "$SERIAL_FJ" ] && [ -n "$SERIAL_HS" ] && [ "$SERIAL_FJ" != "$SERIAL_HS" ]; then
  fail identity.coherence "serial mismatch: hard_settings=$SERIAL_HS but fleet.json=$SERIAL_FJ — the machine authenticates as one identity and fetches catalog as another"
fi

# 4.6 Controller firmware against the one fleet-wide target.
FWRAW="$(grep -hoE 'ControllerVersionAnswer[[:space:]]+[0-9A-F]{12,}' "$DATA"/Logs/*.log 2>/dev/null | tail -1 | awk '{print $2}')"
if [ -n "$FWRAW" ]; then
  FWVER="$(python3 -c "
b=bytes.fromhex('$FWRAW'.strip())
print('%02d%02d%02d-%02d'%(b[3],b[4],b[5],b[6]) if len(b)>=7 and b[:3]==b'\xd5\x06\x49' else '')" 2>/dev/null)"
  if [ "$FWVER" = "$FW_TARGET" ]; then
    ok firmware.version "controller firmware $FWVER (= fleet target)"
  elif [ -n "$FWVER" ]; then
    warn firmware.version "controller firmware $FWVER != fleet target $FW_TARGET — needs flashing (autoflash requires FirmwareFlashWatchdog, see patch.flashwatchdog)"
  else
    info firmware.version "controller version raw '$FWRAW' not decodable"
  fi
else
  warn firmware.version "no ControllerVersionAnswer in ShakerView logs — controller never announced itself (not connected?)"
fi

# 4.7 Reboot churn. Six reboots in a day is a machine fighting something, not a healthy box.
# `journalctl --list-boots` ignores -S/--since, so filter on the parsed start column:
#   " -1 <bootid> Mon 2026-08-03 20:33:30 +05—Mon 2026-08-03 23:19:15 +05"
# ISO dates compare correctly as strings.
BOOTS="$(journalctl --list-boots --no-pager 2>/dev/null \
         | awk -v c="$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S')" \
               '($4 " " $5) > c { n++ } END { print n+0 }')"
if [ "${BOOTS:-0}" -gt 3 ]; then
  warn stability.reboots "$BOOTS boots in the last 24h — machine is power-cycling or crash-looping"
else
  ok stability.reboots "${BOOTS:-?} boots in the last 24h"
fi

fi  # end unit-only section

# ---------------------------------------------------------------------------
hdr "5. LIVE TELEMETRY  (machine's own backend view)"
# ---------------------------------------------------------------------------
if [ "${SKIP_SHAKERVIEW:-}" = "1" ]; then
  info telemetry.skipped "SKIP_SHAKERVIEW=1 — skipping live telemetry pull"
else
  SERIAL="${SV_SERIAL:-$SERIAL_HS}"
  MACHINE_KEY="${SV_MACHINE_KEY:-$MK}"
  KK="${SV_KK_ADDRESS:-$(jget "$HS" KKAddress)}"; KK="${KK:-$(jget "$TJ" KKAddress)}"
  # The MACHINE authenticates as itself in machine-realm (client_id == hard_settings.MachineSerial),
  # which is what bootstrap's TELEMETRY_KEYCLOAK_TOKEN_URL uses and what ShakerView actually does.
  # The configs carry no KKRealm key at all, so the old `shaker-realm` fallback made this check
  # report invalid_client on machines whose telemetry was perfectly fine.
  KKREALM="${SV_KK_REALM:-$(jget "$HS" KKRealm)}"; KKREALM="${KKREALM:-machine-realm}"
  WS="${SV_WS_ADDRESS:-$(jget "$HS" WebSocketAddress)}"; WS="${WS:-$(jget "$TJ" WebSocketAddress)}"
  info telemetry.endpoint "KK=${KK:-?} realm=$KKREALM WS=${WS:-?} client_id=${SERIAL:-?}"

  if [ -z "$SERIAL" ] || [ -z "$MACHINE_KEY" ] || [ -z "$KK" ] || [ -z "$WS" ]; then
    [ "$MODE" = "unit" ] \
      && fail telemetry.config "missing serial/MachineKey/KKAddress/WebSocketAddress — machine cannot reach its telemetry backend" \
      || info telemetry.config "no telemetry identity (expected on a clean golden)"
  else
    TOKRESP="$(curl -sS --max-time 12 "$KK/realms/$KKREALM/protocol/openid-connect/token" \
      --data-urlencode grant_type=client_credentials \
      --data-urlencode "client_id=$SERIAL" \
      --data-urlencode "client_secret=$MACHINE_KEY" \
      --data-urlencode scope=profile 2>/dev/null)"
    ACCESS="$(printf '%s' "$TOKRESP" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("access_token","") or "")
except Exception: print("")' 2>/dev/null)"
    if [ -z "$ACCESS" ]; then
      fail telemetry.auth "Keycloak auth FAILED as client_id=$SERIAL — not registered, or MachineKey/MachineSerial mismatch. Backend rejects it at the client site. Resp: $(printf '%s' "$TOKRESP" | head -c 160)"
    else
      ok telemetry.auth "Keycloak client_credentials OK — machine authenticates as itself"

      # One short-lived WebSocket per request (single req/response then close), so this never
      # collides with the machine's own live connection.
      PYOUT="$(SV_QUERY="$ACCESS|$SERIAL|$WS" python3 - <<'PY' 2>/dev/null
import base64, json, os, socket, ssl, struct, time
from urllib.parse import urlparse

access, serial, ws = os.environ["SV_QUERY"].split("|", 2)
u = urlparse(ws)
host = u.hostname; port = u.port or (443 if u.scheme == "wss" else 80)
path = u.path or "/"

def ws_request(msg_type, body=None, expect=None, timeout=10):
    expect = expect or {msg_type}
    s = socket.create_connection((host, port), timeout=8)
    if u.scheme == "wss":
        s = ssl.create_default_context().wrap_socket(s, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
           f"Authorization: Bearer {access}\r\n\r\n")
    s.sendall(req.encode())
    buf = b""; s.settimeout(8)
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk: raise RuntimeError("handshake closed")
        buf += chunk
    if b" 101 " not in buf.split(b"\r\n", 1)[0]:
        raise RuntimeError("no 101: " + buf.split(b"\r\n",1)[0].decode("latin1"))
    payload = json.dumps({"type": msg_type, "clientId": serial, **({"body": body} if body is not None else {})}).encode()
    hdr = bytearray([0x81]); n = len(payload); mask = os.urandom(4)
    if n < 126: hdr.append(0x80 | n)
    elif n < 65536: hdr.append(0x80 | 126); hdr += struct.pack(">H", n)
    else: hdr.append(0x80 | 127); hdr += struct.pack(">Q", n)
    hdr += mask
    s.sendall(bytes(hdr) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
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
            if (b0 & 0x0F) == 0x8: break
            try: msg = json.loads(data.decode("utf-8"))
            except Exception: continue
            if msg.get("type") in expect: return msg
    finally:
        try: s.close()
        except Exception: pass
    return None

def out(m, level, text): print(f"::{level}::{m}::{text}")

try:
    mi = ws_request("machineInfo")
    if mi is None: out("machineinfo","WARN","no response (backend reachable but silent)")
    else: out("machineinfo","OK", json.dumps(mi.get("body", mi))[:200])
    stt = ws_request("machineInfo", expect={"statusMachineImportTopic"}, timeout=6)
    if stt:
        c = (stt.get("body") or {}).get("color","")
        lvl = {"SUCCESS":"OK","WARNING":"WARN","ERROR":"FAIL"}.get(str(c).upper(),"INFO")
        out("status", lvl, f"{(stt.get('body') or {}).get('text','')} [{c}]")
except Exception as e:
    out("machineinfo","WARN", f"telemetry query error: {e}")

try:
    cs = ws_request("cellStoreRequestExport", expect={"cellStoreRequestExport","cellStoreImportTopic"})
    if cs:
        cells = (cs.get("body") or {}).get("cells") or []
        out("cellstore","OK" if cells else "WARN", f"{len(cells)} cells configured")
    else: out("cellstore","WARN","no cell config returned")
except Exception as e: out("cellstore","WARN", str(e))

try:
    cv = ws_request("cellVolumeExport", expect={"cellVolumeExport","cellVolumeImportTopic"})
    if cv:
        cells = (cv.get("body") or {}).get("cells") or []
        zero = sum(1 for c in cells if (c.get("currentValue") in (0,0.0,None)))
        out("remains","OK" if cells else "WARN", f"{len(cells)} cells, {zero} at zero/empty")
    else: out("remains","WARN","no remains returned (inventory uninitialized)")
except Exception as e: out("remains","WARN", str(e))

try:
    ks = ws_request("getKioskCellsTopic", expect={"importCellKiosk"})
    if ks:
        cells = (ks.get("body") or {}).get("cells") or ks.get("body") or []
        if isinstance(cells, dict): cells = cells.get("cells", [])
        prices = [c.get("price") for c in cells if isinstance(c, dict)]
        bad = [p for p in prices if p in (0,0.0,50,50.0,100,100.0)]
        out("kioskprices","FAIL" if bad else ("OK" if prices else "WARN"),
            f"{len(prices)} priced cells; suspicious(0/50/100)={len(bad)}")
except Exception as e: out("kioskprices","WARN", str(e))
PY
      )"
      # Fold the python sub-checks into the same counters/JSON as everything else. The old
      # version printed them loose, so they never affected the verdict.
      while IFS= read -r line; do
        case "$line" in
          ::*)
            L="$(printf '%s' "$line" | awk -F'::' '{print $2}')"
            I="$(printf '%s' "$line" | awk -F'::' '{print $3}')"
            M="$(printf '%s' "$line" | awk -F'::' '{for(i=4;i<=NF;i++) printf "%s%s", $i, (i<NF?"::":"")}')"
            case "$L" in
              OK)   ok   "telemetry.$I" "$M" ;;
              WARN) warn "telemetry.$I" "$M" ;;
              FAIL) fail "telemetry.$I" "$M" ;;
              *)    info "telemetry.$I" "$M" ;;
            esac ;;
        esac
      done <<< "$PYOUT"
    fi
  fi
fi

# ---------------------------------------------------------------------------
hdr "SUMMARY"
# ---------------------------------------------------------------------------
say "  mode=$MODE  OK=$nOK  WARN=$nWARN  FAIL=$nFAIL"
if [ "$nFAIL" -gt 0 ]; then VERDICT="DO_NOT_SHIP"; RC=2
elif [ "$nWARN" -gt 0 ]; then VERDICT="REVIEW"; RC=1
else VERDICT="SHIP"; RC=0; fi
say "############ VERDICT: $VERDICT ############"
[ "$MODE" = "unit" ] && say "  Deep config/price/locale audit: run check_machine.sh as well."

if [ "$JSON" = "1" ]; then
  REC="$REC" MODE="$MODE" VERDICT="$VERDICT" HOSTNAME_="$(hostname)" \
  nOK=$nOK nWARN=$nWARN nFAIL=$nFAIL python3 - <<'PY'
import json, os, datetime
checks = []
for line in open(os.environ["REC"]):
    parts = line.rstrip("\n").split("\t", 2)
    if len(parts) == 3:
        checks.append({"level": parts[0], "id": parts[1], "msg": parts[2]})
print(json.dumps({
    "schema": 1,
    "mode": os.environ["MODE"],
    "host": os.environ["HOSTNAME_"],
    "at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "verdict": os.environ["VERDICT"],
    "counts": {"ok": int(os.environ["nOK"]), "warn": int(os.environ["nWARN"]), "fail": int(os.environ["nFAIL"])},
    "checks": checks,
}, ensure_ascii=False))
PY
fi
exit $RC
