#!/bin/bash

set -Eeuo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_OWNER_USER="${SUDO_USER:-$(id -un)}"
LOG_OWNER_HOME="$(getent passwd "$LOG_OWNER_USER" | cut -d: -f6)"
LOGFILE="${LOG_OWNER_HOME:-$HOME}/bootstrap_device_$(date +%Y%m%d_%H%M%S).log"

# .env lookup. SCRIPT_DIR alone is wrong for the normal launch path: the ~/Desktop/scripts/*.sh
# on machines are thin GitHub loaders that fetch this file into /tmp and `exec bash` it, so
# SCRIPT_DIR is /tmp and a .env sitting next to the loader was silently ignored (every run
# logged "WARNING: .env not found at /tmp/.env" and then registered with default settings --
# e.g. MANAGE_ORG_ID=2 on machines that belong to another organization). Search the operator's
# scripts folder too, and let BOOTSTRAP_ENV_FILE override everything.
resolve_env_file() {
  local candidate
  for candidate in \
    "${BOOTSTRAP_ENV_FILE:-}" \
    "$SCRIPT_DIR/.env" \
    "${LOG_OWNER_HOME:-$HOME}/Desktop/scripts/.env" \
    "${LOG_OWNER_HOME:-$HOME}/.config/ishaker/bootstrap.env"
  do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  printf '%s' "$SCRIPT_DIR/.env"
}
ENV_FILE="$(resolve_env_file)"

WIFI_NETWORK="${WIFI_NETWORK:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
STRAPI_BASE_URL="${STRAPI_BASE_URL:-https://admin.ishaker.xyz}"
STRAPI_IDENTIFIER="${STRAPI_IDENTIFIER:-registrator}"
STRAPI_PASSWORD="${STRAPI_PASSWORD:-}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-${TS_AUTHKEY:-}}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"
TAILSCALE_EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"
TAILSCALE_ADVERTISE_TAGS="${TAILSCALE_ADVERTISE_TAGS:-}"
RESET_TAILSCALE_STATE="${RESET_TAILSCALE_STATE:-false}"
ENABLE_TAILSCALE_SSH="${ENABLE_TAILSCALE_SSH:-false}"
SSH_LOGIN_USER="${SSH_LOGIN_USER:-}"
SSH_AUTH_MODE="${SSH_AUTH_MODE:-password}"
SSH_PORT="${SSH_PORT:-22}"
ANYDESK_PASSWORD="${ANYDESK_PASSWORD:-}"
RUSTDESK_PASSWORD="${RUSTDESK_PASSWORD:-}"
MACHINE_TYPE="${MACHINE_TYPE:-small}"
MACHINE_STATUS="${MACHINE_STATUS:-new}"
MACHINE_SERIAL_NUMBER="${MACHINE_SERIAL_NUMBER:-}"
MACHINE_NICKNAME="${MACHINE_NICKNAME:-}"
UNITY_VERSION="${UNITY_VERSION:-}"
SSD_VERSION="${SSD_VERSION:-}"
BOOTSTRAP_VERSION="${BOOTSTRAP_VERSION:-0.1.0}"
# Bring the kiosk back up at the very end, the way run.sh does. Set to anything but "true" to
# leave the machine at the desktop instead (useful when more work follows the bootstrap run).
START_APP_AFTER_BOOTSTRAP="${START_APP_AFTER_BOOTSTRAP:-true}"
MANAGE_API_BASE="${MANAGE_API_BASE:-https://manage.ishakerusa.com}"
# FleetCatalog (Config/fleet.json): the machine PULLS its catalog + planogram from Strapi.
# Tailscale-direct on purpose — admin.ishaker.xyz sits behind Cloudflare, which 403s the
# app's user-agent (error 1010). CATALOG_TOKEN is the shared bearer the endpoints check.
FLEET_CATALOG_URL="${FLEET_CATALOG_URL:-http://100.101.29.104:1338}"
FLEET_CATALOG_TOKEN="${FLEET_CATALOG_TOKEN:-${CATALOG_TOKEN:-}}"
FLEET_REFRESH_MINUTES="${FLEET_REFRESH_MINUTES:-5}"
OPS_SSH_PUBKEY="${OPS_SSH_PUBKEY:-}"
# Readiness gate. Every step below verifies only itself, so a machine can pass all of them
# and still be unshippable — no working freeze watchdog, /catalog returning 0 cells, Keycloak
# rejecting the serial that was just registered. diagnose.sh --mode unit is the one check that
# asks "is this shippable" as a whole, and bootstrap must not claim success without it.
DIAGNOSE_URL="${DIAGNOSE_URL:-https://raw.githubusercontent.com/shakeradmin/scripts/main/diagnose.sh}"
SKIP_READINESS_GATE="${SKIP_READINESS_GATE:-0}"
READINESS_VERDICT="NOT_RUN"
READINESS_REPORT=""
# Freeze protection. Bay Trail Celerons on this fleet hard-freeze on deep C-states (machines 25,
# 64, 260511731, 260511736 all traced to it). Neither defence lives in the app, so no patch can
# deliver them and every machine used to need hand-treatment after bootstrap -- which is exactly
# why machines kept shipping with none:
#   prevention -> intel_idle.max_cstate=1 kernel parameter
#   recovery   -> shakerview-watchdog.sh systemd service (graduated ladder, see the script)
SCRIPTS_RAW_URL="${SCRIPTS_RAW_URL:-https://raw.githubusercontent.com/shakeradmin/scripts/main}"
SKIP_FREEZE_PROTECTION="${SKIP_FREEZE_PROTECTION:-0}"
# CPUs with the erratum. Matched against /proc/cpuinfo "model name".
CSTATE_CPU_PATTERN="${CSTATE_CPU_PATTERN:-J1900|J1800|J1750|N2807|N2840|N2930}"
CSTATE_REBOOT_REQUIRED=0
MANAGE_KEYCLOAK_TOKEN_URL="${MANAGE_KEYCLOAK_TOKEN_URL:-https://kk.ishakerusa.com/realms/shaker-realm/protocol/openid-connect/token}"
# Realm the MACHINE authenticates against (client_credentials, client_id == its serial). Used to
# VERIFY that telemetry registration produced credentials ShakerView can actually authenticate with.
TELEMETRY_KEYCLOAK_TOKEN_URL="${TELEMETRY_KEYCLOAK_TOKEN_URL:-https://kk.ishakerusa.com/realms/machine-realm/protocol/openid-connect/token}"
MANAGE_CLIENT_ID="${MANAGE_CLIENT_ID:-shaker-client}"
MANAGE_USERNAME="${MANAGE_USERNAME:-root}"
MANAGE_PASSWORD="${MANAGE_PASSWORD:-}"
MANAGE_ORG_ID="${MANAGE_ORG_ID:-2}"
# Set to 1 by verify_telemetry_auth() once machine-realm auth is proven to work end-to-end.
TELEMETRY_AUTH_VERIFIED=0
# manage.ishakerusa.com's machine/registration/<regcode> endpoint can mint a working Keycloak
# client (secretKey comes back, auth works) while silently failing to create the machine record
# in the org's own machine list — see [[manage-registration-mints-keycloak-not-machine-record]].
# Retrying with the SAME serial only ever gets a "REFRESH" of the existing (still orphaned)
# client, never a fresh attempt. So on a confirmed silent-drop we burn that serial and retry with
# a new one, up to this many times, instead of getting stuck re-confirming the same dead client.
TELEMETRY_REGISTER_MAX_ATTEMPTS="${TELEMETRY_REGISTER_MAX_ATTEMPTS:-6}"
# How long to give manage's machine-list a chance to reflect a fresh registration before deciding
# it silently dropped it (observed: real drops never showed up even a day later, so this is just
# slack for normal replication lag, not an attempt to wait out the actual bug).
TELEMETRY_VERIFY_POLL_ATTEMPTS="${TELEMETRY_VERIFY_POLL_ATTEMPTS:-3}"
TELEMETRY_VERIFY_POLL_DELAY="${TELEMETRY_VERIFY_POLL_DELAY:-5}"

STRAPI_PASSWORD_FILE="$(mktemp /tmp/.bootstrap_strapi_pw.XXXXXX)"
chmod 600 "$STRAPI_PASSWORD_FILE"
cleanup_strapi_password_file() {
  rm -f "$STRAPI_PASSWORD_FILE"
}
trap on_exit EXIT

# Transient DNS/connect failures are the single biggest cause of aborted runs on these
# machines: the client router is the only resolver and drops roughly one lookup in twenty,
# which is plenty to kill a run that makes dozens of calls. Two failures on 2026-08-06 were
# exactly this -- "Could not resolve host: keys.anydesk.com" and curl exit 6 on
# admin.ishaker.xyz/api/auth/local. The per-call retry loops that already existed could not
# help: under `set -e` the failing status="$(curl ...)" assignment aborted the script before
# the loop got to look at the status. So every such call now retries inside curl AND falls
# back to "000" instead of killing the run.
CURL_NET_OPTS="--connect-timeout 15 --max-time 90 --retry 3 --retry-delay 2"
if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
  CURL_NET_OPTS="$CURL_NET_OPTS --retry-all-errors"   # curl >= 7.71; also retries DNS failures
fi

SETUP_WARNINGS=()
record_warning() {
  SETUP_WARNINGS+=("$1")
  log "WARNING: $1"
}

exec > >(tee -a "$LOGFILE") 2>&1

log() {
  echo "[$(date '+%F %T')] $1" >&2
}

log_section() {
  log "--------------------------------------------------------------"
  log "$1"
  log "--------------------------------------------------------------"
}

# Failure state, so the run can report at the END what went wrong instead of leaving the
# operator to scroll back through several thousand lines of apt output.
BOOTSTRAP_FAILED=0
FAILURE_LINE=""
FAILURE_COMMAND=""
FAILURE_EXIT=""
BOOTSTRAP_SERIAL=""
STRAPI_MACHINE_ID=""
STAGE="starting up"

# Human-readable label of what bootstrap was doing, so the failure report names the step and
# not just a line number.
set_stage() {
  STAGE="$1"
}

on_error() {
  local line_no="$1"
  local command="$2"
  local exit_code="$3"

  BOOTSTRAP_FAILED=1
  FAILURE_LINE="$line_no"
  FAILURE_COMMAND="$command"
  FAILURE_EXIT="$exit_code"

  log "ERROR: bootstrap failed"
  log "Stage: $STAGE"
  log "Exit code: $exit_code"
  log "Line: $line_no"
  log "Command: $command"
  log "Log file: $LOGFILE"

  log "Recent system state:"
  log "Current user: $(id -un 2>/dev/null || true)"
  log "Hostname: $(hostname 2>/dev/null || true)"
  log "NetworkManager state: $(nmcli -t -f STATE general 2>/dev/null || echo unavailable)"
  log "Default route: $(ip route show default 2>/dev/null | head -n1 || echo unavailable)"
  log "SSH service: $(systemctl is-active ssh 2>/dev/null || echo unavailable)"
  log "AnyDesk service: $(systemctl is-active anydesk 2>/dev/null || echo unavailable)"
  log "RustDesk service: $(systemctl is-active rustdesk 2>/dev/null || echo unavailable)"
  log "Tailscale service: $(systemctl is-active tailscaled 2>/dev/null || echo unavailable)"
}

trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

# What the operator actually needs the moment a run dies: can this machine still be reached,
# and by which of the three channels. Printed on the console at the very end, not buried.
print_remote_access() {
  local ad_id ad_state rd_id rd_state ts_ip ts_host ts_state
  ad_state="$(systemctl is-active anydesk 2>/dev/null || echo inactive)"
  rd_state="$(systemctl is-active rustdesk 2>/dev/null || echo inactive)"
  ts_state="$(systemctl is-active tailscaled 2>/dev/null || echo inactive)"
  ad_id="$(get_anydesk_id 2>/dev/null || true)"
  rd_id="$(get_rustdesk_id 2>/dev/null || true)"
  ts_ip="$(get_tailscale_ip 2>/dev/null || true)"
  ts_host="$(get_tailscale_hostname 2>/dev/null || true)"

  echo "REMOTE ACCESS AVAILABLE ON THIS MACHINE"
  printf '  AnyDesk    : %-10s id=%s\n'  "$ad_state" "${ad_id:-<none>}"
  printf '  RustDesk   : %-10s id=%s\n'  "$rd_state" "${rd_id:-<none>}"
  printf '  Tailscale  : %-10s ip=%s host=%s\n' "$ts_state" "${ts_ip:-<none>}" "${ts_host:-<none>}"
  printf '  SSH        : %-10s user=%s port=%s\n' \
    "$(systemctl is-active ssh 2>/dev/null || echo inactive)" "$SSH_LOGIN_USER" "$SSH_PORT"

  if [ -z "$ad_id" ] && [ -z "$rd_id" ] && [ -z "$ts_ip" ]; then
    echo "  !! NO REMOTE ACCESS CHANNEL CAME UP — this machine can only be reached on site."
  fi
}

# A failed run used to leave no trace anywhere but the machine's own disk, so a box that died
# mid-provisioning was invisible to the fleet. Register it anyway, with the reason in
# admin_comment, so it shows up as a machine that needs attention.
register_failed_machine() {
  local serial reason ad_id rd_id ts_ip ts_host secret

  [ -n "$STRAPI_MACHINE_ID" ] && return 0          # main() already created the record

  serial="${BOOTSTRAP_SERIAL:-$(onbox_serial 2>/dev/null || true)}"
  if [ -z "$serial" ]; then
    log "no serial known — cannot register the failed run in Strapi"
    return 0
  fi
  if [ -z "$STRAPI_PASSWORD" ] && [ ! -s "$STRAPI_PASSWORD_FILE" ]; then
    log "no Strapi credentials available — cannot register the failed run in Strapi"
    return 0
  fi

  reason="$(failure_report_text)"
  ad_id="$(get_anydesk_id 2>/dev/null || true)"
  rd_id="$(get_rustdesk_id 2>/dev/null || true)"
  ts_ip="$(get_tailscale_ip 2>/dev/null || true)"
  ts_host="$(get_tailscale_hostname 2>/dev/null || true)"
  secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || echo "")"

  # status stays "new" on purpose: the Strapi enum only knows new/working/ready, and a record
  # rejected with a 400 would defeat the point of registering the failure at all. The reason
  # lives in admin_comment.
  log "Registering the FAILED bootstrap run in Strapi (serial $serial)"
  if STRAPI_MACHINE_ID="$(ADMIN_COMMENT="$reason" \
        register_machine_in_strapi "$serial" "$ad_id" "$ts_ip" "" "$rd_id" \
        "$ts_host" "$(hostname)" "" "" "$secret" "${MACHINE_NICKNAME:-}" 2>/dev/null)"; then
    log "Strapi machine created with the failure reason: id $STRAPI_MACHINE_ID"
  else
    STRAPI_MACHINE_ID=""
    log "WARNING: could not register the failed run in Strapi either"
  fi
}

failure_report_text() {
  local out
  out="bootstrap FAILED at stage: $STAGE"
  [ -n "$FAILURE_COMMAND" ] && out="$out"$'\n'"failing command (line ${FAILURE_LINE}, exit ${FAILURE_EXIT}): $FAILURE_COMMAND"
  if [ "${#SETUP_WARNINGS[@]}" -gt 0 ]; then
    local w
    out="$out"$'\n'"warnings:"
    for w in "${SETUP_WARNINGS[@]}"; do out="$out"$'\n'"  - $w"; done
  fi
  printf '%s' "$out"
}

# Runs on every exit path, including the abort ones, so a failed run always ends with a
# readable verdict on the console instead of the last apt error scrolling past.
on_exit() {
  local rc="$?"
  set +u                               # the trap can fire before every global is assigned
  cleanup_strapi_password_file
  if [ "${BOOTSTRAP_FAILED:-0}" = "1" ] || { [ "$rc" -ne 0 ] && [ "${FINISHED_CLEANLY:-0}" != "1" ]; }; then
    register_failed_machine || true
    echo
    echo "=============================================================="
    echo "BOOTSTRAP FAILED"
    echo "=============================================================="
    echo "Stage           : ${STAGE:-unknown}"
    [ -n "${FAILURE_COMMAND:-}" ] && echo "Failing command : $FAILURE_COMMAND"
    [ -n "${FAILURE_LINE:-}" ]    && echo "Line / exit code: $FAILURE_LINE / $FAILURE_EXIT"
    echo "Serial          : ${BOOTSTRAP_SERIAL:-<not entered>}"
    echo "Strapi machine  : ${STRAPI_MACHINE_ID:-<not created>}"
    echo "Log file        : $LOGFILE"
    if [ "${#SETUP_WARNINGS[@]}" -gt 0 ]; then
      echo
      echo "WARNINGS (${#SETUP_WARNINGS[@]}):"
      local w
      for w in "${SETUP_WARNINGS[@]}"; do echo "  - $w"; done
    fi
    echo
    print_remote_access
    echo "=============================================================="
  fi
  set -u
}
FINISHED_CLEANLY=0

run_logged() {
  log "Running: $*"
  "$@"
}

protect_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    log "WARNING: .env not found at $ENV_FILE"
    return
  fi

  chmod 600 "$ENV_FILE" || {
    log "ERROR: failed to protect .env with chmod 600"
    return 1
  }
  log "Protected .env permissions: $(stat -c '%a %U:%G' "$ENV_FILE" 2>/dev/null || echo unknown)"
}

load_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  else
    log "WARNING: .env not found at $ENV_FILE"
  fi

  WIFI_NETWORK="${WIFI_NETWORK:-}"
  WIFI_PASSWORD="${WIFI_PASSWORD:-}"
  STRAPI_BASE_URL="${STRAPI_BASE_URL:-https://admin.ishaker.xyz}"
  STRAPI_IDENTIFIER="${STRAPI_IDENTIFIER:-${login:-registrator}}"
  STRAPI_PASSWORD="${STRAPI_PASSWORD:-${password:-}}"
  TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-${TS_AUTHKEY:-${TAILSCALE_KEY_SHAKER:-}}}"
  TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"
  TAILSCALE_EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"
  TAILSCALE_ADVERTISE_TAGS="${TAILSCALE_ADVERTISE_TAGS:-}"
  RESET_TAILSCALE_STATE="${RESET_TAILSCALE_STATE:-false}"
  ENABLE_TAILSCALE_SSH="${ENABLE_TAILSCALE_SSH:-false}"
  SSH_LOGIN_USER="${SSH_LOGIN_USER:-${SUDO_USER:-$(id -un)}}"
  SSH_AUTH_MODE="${SSH_AUTH_MODE:-password}"
  SSH_PORT="${SSH_PORT:-22}"
  ANYDESK_PASSWORD="${ANYDESK_PASSWORD:-}"
  RUSTDESK_PASSWORD="${RUSTDESK_PASSWORD:-}"
  MACHINE_TYPE="${MACHINE_TYPE:-small}"
  MACHINE_STATUS="${MACHINE_STATUS:-new}"
  MACHINE_SERIAL_NUMBER="${MACHINE_SERIAL_NUMBER:-}"
  MACHINE_NICKNAME="${MACHINE_NICKNAME:-}"
  UNITY_VERSION="${UNITY_VERSION:-}"
  SSD_VERSION="${SSD_VERSION:-}"
  BOOTSTRAP_VERSION="${BOOTSTRAP_VERSION:-0.1.0}"
  START_APP_AFTER_BOOTSTRAP="${START_APP_AFTER_BOOTSTRAP:-true}"
  MANAGE_API_BASE="${MANAGE_API_BASE:-https://manage.ishakerusa.com}"
  # MUST be re-defaulted here, not only at the top of the script: the top-level assignment
  # runs before .env is sourced, so CATALOG_TOKEN placed in .env would never reach it.
  FLEET_CATALOG_URL="${FLEET_CATALOG_URL:-http://100.101.29.104:1338}"
  FLEET_CATALOG_TOKEN="${FLEET_CATALOG_TOKEN:-${CATALOG_TOKEN:-}}"
  FLEET_REFRESH_MINUTES="${FLEET_REFRESH_MINUTES:-5}"
  OPS_SSH_PUBKEY="${OPS_SSH_PUBKEY:-}"
  MANAGE_KEYCLOAK_TOKEN_URL="${MANAGE_KEYCLOAK_TOKEN_URL:-https://kk.ishakerusa.com/realms/shaker-realm/protocol/openid-connect/token}"
  MANAGE_CLIENT_ID="${MANAGE_CLIENT_ID:-shaker-client}"
  MANAGE_USERNAME="${MANAGE_USERNAME:-root}"
  MANAGE_PASSWORD="${MANAGE_PASSWORD:-}"
  MANAGE_ORG_ID="${MANAGE_ORG_ID:-2}"
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    log "ERROR: run with sudo: sudo ./bootstrap-device.sh"
    exit 1
  fi
}

read_tty() {
  local prompt="$1"
  local value

  if [ -r /dev/tty ]; then
    printf "%s" "$prompt" >/dev/tty
    IFS= read -r value </dev/tty
  else
    IFS= read -r -p "$prompt" value
  fi

  printf "%s" "$value"
}

read_secret_tty() {
  local prompt="$1"
  local value

  if [ -r /dev/tty ]; then
    printf "%s" "$prompt" >/dev/tty
    IFS= read -rs value </dev/tty
    printf "\n" >/dev/tty
  else
    IFS= read -rs -p "$prompt" value
    echo
  fi

  printf "%s" "$value"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "ERROR: required command not found: $1"
    exit 1
  fi
}

apt_install() {
  log "Installing packages: $*"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

internet_is_online() {
  curl -fsS --max-time 8 "$STRAPI_BASE_URL/admin/init" >/dev/null 2>&1 ||
    curl -fsS --max-time 8 https://www.google.com/generate_204 >/dev/null 2>&1
}

try_wifi_connect() {
  if [ -z "$WIFI_NETWORK" ] || ! command -v nmcli >/dev/null 2>&1; then
    log "Wi-Fi auto-connect skipped: WIFI_NETWORK is empty or nmcli is missing"
    return 1
  fi

  log "Trying Wi-Fi auto-connect to SSID: $WIFI_NETWORK"
  nmcli radio wifi on >/dev/null 2>&1 || true
  nmcli dev wifi rescan >/dev/null 2>&1 || true

  if [ -n "$WIFI_PASSWORD" ]; then
    nmcli dev wifi connect "$WIFI_NETWORK" password "$WIFI_PASSWORD" >/dev/null 2>&1
  else
    nmcli dev wifi connect "$WIFI_NETWORK" >/dev/null 2>&1
  fi
}

open_wifi_settings() {
  log "Opening Wi-Fi settings. Connect manually, then return to this terminal."

  if command -v gnome-control-center >/dev/null 2>&1; then
    log "Launching gnome-control-center wifi"
    sudo -u "${SUDO_USER:-$USER}" env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" gnome-control-center wifi >/dev/null 2>&1 &
  elif command -v nm-connection-editor >/dev/null 2>&1; then
    log "Launching nm-connection-editor"
    sudo -u "${SUDO_USER:-$USER}" env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" nm-connection-editor >/dev/null 2>&1 &
  elif command -v xdg-open >/dev/null 2>&1; then
    log "Launching xdg-open settings://network"
    sudo -u "${SUDO_USER:-$USER}" env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" xdg-open "settings://network" >/dev/null 2>&1 &
  else
    log "No graphical network settings command was found."
  fi
}

wait_for_online() {
  log_section "Network Check"
  log "WIFI_NETWORK=${WIFI_NETWORK:-unset}"
  log "nmcli available: $(command -v nmcli >/dev/null 2>&1 && echo yes || echo no)"

  if internet_is_online; then
    log "Internet is already online"
    return
  fi

  if try_wifi_connect; then
    log "Connected to Wi-Fi using saved credentials"
  else
    log "Automatic Wi-Fi connection failed or is not configured"
  fi

  local opened_settings=false
  until internet_is_online; do
    if [ "$opened_settings" = "false" ]; then
      open_wifi_settings
      opened_settings=true
    fi

    log "Waiting for internet. Finish Wi-Fi setup, then press Enter to check again."
    if command -v nmcli >/dev/null 2>&1; then
      log "NetworkManager summary:"
      nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null || true
    fi
    read_tty "" >/dev/null || true
  done

  log "Internet is online"
}

# The serial typed here becomes the Keycloak client_id, the hard_settings.MachineSerial and
# the Strapi record -- get it wrong and the machine's telemetry identity is overwritten with
# someone else's. On 2026-08-06 an operator typed an AnyDesk ID (1855932134) at this prompt on
# a working machine, and bootstrap wrote it straight into hard_settings, breaking a serial
# (25010056) that had been authenticating fine. So: show what the machine says about itself,
# offer it as the default, and refuse the shapes that are obviously not serials.
onbox_serial() {
  local hs
  for hs in /home/*/ShakerView2.0Linux*/ShakerView2.0_Data/Config/hard_settings.json; do
    [ -e "$hs" ] || continue
    HS="$hs" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    with open(os.environ["HS"], encoding="utf-8-sig") as fh:
        print((json.load(fh).get("MachineSerial") or "").strip())
except Exception:
    pass
PY
    return
  done
}

# THE serial format, and the only one accepted: digits, optionally followed by "-" and a
# tail. The tail exists because register_telemetry_with_retry() appends "-r<hex>" when a
# serial has to be burned and retried (260511737-r1722, 004-r5b6c) -- so whatever this
# function accepts has to survive its own output.
#
# Model-prefixed forms like S-25011715S / T2-25110041S are NOT valid here: the same physical
# machine then appears under two different identities (bare digits in Strapi, prefixed in the
# cabinet), and the serial is also the Keycloak client_id, so the mismatch is not cosmetic.
serial_is_valid() {
  [[ "$1" =~ ^[0-9]+(-[A-Za-z0-9]+)?$ ]]
}

# Best-effort normalisation of a legacy on-device value, offered as a SUGGESTION only --
# never applied silently. "T2-25110041S" -> "25110041", "S-25011715S" -> "25011715".
serial_suggestion() {
  local s="$1"
  s="${s#*-}"                       # drop a leading model prefix up to the first "-"
  s="$(printf '%s' "$s" | sed 's/[A-Za-z]*$//')"   # drop a trailing letter suffix
  serial_is_valid "$s" && printf '%s' "$s"
}

serial_looks_wrong() {
  local s="$1"
  # Format-valid but almost certainly an AnyDesk ID: those are 9-10 bare digits and never
  # start with 2, while fleet serials are year-prefixed 24/25/26 (25010056, 260511734).
  [[ "$s" =~ ^[0-9]{9,10}$ ]] && [[ "$s" != 2* ]]
}

# Console output that belongs NEXT TO the prompt. read_tty writes its prompt to /dev/tty, so
# anything explaining that prompt has to go to the same place or it lands in the log only.
say_tty() {
  if [ -r /dev/tty ]; then
    printf '%s\n' "$*" >/dev/tty
  else
    printf '%s\n' "$*" >&2
  fi
}

prompt_for_serial_number() {
  local serial="" onbox="" default="" answer="" suggested=""
  onbox="$(onbox_serial)"

  # The default offered at the prompt must itself be a legal serial. A legacy prefixed value
  # on the machine (T2-25110041S) is shown, but only its normalised form can be the default.
  if [ -n "$MACHINE_SERIAL_NUMBER" ] && serial_is_valid "$MACHINE_SERIAL_NUMBER"; then
    default="$MACHINE_SERIAL_NUMBER"
  elif [ -n "$onbox" ] && serial_is_valid "$onbox"; then
    default="$onbox"
  else
    suggested="$(serial_suggestion "${MACHINE_SERIAL_NUMBER:-$onbox}")"
    default="$suggested"
  fi

  # Always SHOW both serials and always let the operator confirm, even when .env supplies one.
  # Silently trusting MACHINE_SERIAL_NUMBER meant the run never displayed the value that was
  # about to be written into hard_settings and registered in the cabinet -- the one field
  # nobody can check afterwards without opening the machine.
  say_tty ""
  say_tty "  ------------------------------------------------------------"
  say_tty "  serial in configuration : ${MACHINE_SERIAL_NUMBER:-<not set>}"
  say_tty "  serial on this machine  : ${onbox:-<none found>}"
  if [ -n "$MACHINE_SERIAL_NUMBER" ] && ! serial_is_valid "$MACHINE_SERIAL_NUMBER"; then
    say_tty "  !! the configured serial is not a legal serial and will NOT be used as-is"
    record_warning "MACHINE_SERIAL_NUMBER=$MACHINE_SERIAL_NUMBER is not digits or digits-tail — operator had to enter a valid serial"
  fi
  if [ -n "$onbox" ] && ! serial_is_valid "$onbox"; then
    say_tty "  !! the on-device serial carries a model prefix/suffix — it will be replaced"
  fi
  [ -n "$suggested" ] && say_tty "  suggested (normalised)  : $suggested"
  if [ -n "$MACHINE_SERIAL_NUMBER" ] && [ -n "$onbox" ] && [ "$MACHINE_SERIAL_NUMBER" != "$onbox" ]; then
    say_tty "  !! THEY DISAGREE — what you confirm below overwrites hard_settings.MachineSerial"
    record_warning "MACHINE_SERIAL_NUMBER=$MACHINE_SERIAL_NUMBER differs from on-device hard_settings.MachineSerial=$onbox — the on-device value gets overwritten"
  fi
  say_tty "  format: digits only, or digits-tail (25110041, 260511737-r1722)"
  say_tty "  ------------------------------------------------------------"
  log "serial from configuration: ${MACHINE_SERIAL_NUMBER:-<unset>}; on-device: ${onbox:-<none>}; default offered: ${default:-<none>}"

  # No terminal to confirm on (cron, piped install): fall back to the configured value rather
  # than blocking forever on a read that can never be answered -- but only if it is legal.
  if [ ! -r /dev/tty ] && [ ! -t 0 ]; then
    if [ -n "$MACHINE_SERIAL_NUMBER" ] && serial_is_valid "$MACHINE_SERIAL_NUMBER"; then
      log "no TTY to confirm on — using MACHINE_SERIAL_NUMBER unattended"
      printf "%s" "$MACHINE_SERIAL_NUMBER"
      return
    fi
    log "ERROR: no TTY and no valid MACHINE_SERIAL_NUMBER — refusing to invent a serial"
    return 1
  fi

  local tries=0
  while [ -z "$serial" ]; do
    tries=$((tries + 1))
    # Bounded: if the terminal goes away mid-run, read returns empty forever and the old
    # unbounded loop spun at 100% CPU with nobody watching.
    if [ "$tries" -gt 10 ]; then
      say_tty "  no valid serial entered after 10 attempts — aborting"
      log "ERROR: no serial number could be read from the terminal"
      return 1
    fi
    if [ -n "$default" ]; then
      answer="$(read_tty "  Serial to register [$default]: " | xargs)"
      serial="${answer:-$default}"
    else
      serial="$(read_tty "  Serial to register: " | xargs)"
    fi

    # Hard rule, no override: anything but digits (optionally digits-tail) is rejected.
    if [ -n "$serial" ] && ! serial_is_valid "$serial"; then
      say_tty ""
      say_tty "  \"$serial\" is not a valid serial."
      say_tty "  Allowed: digits only (25110041), or digits + \"-\" + tail (260511737-r1722)."
      serial=""
      continue
    fi

    # Format-legal but suspicious: soft guard, operator can override deliberately.
    if [ -n "$serial" ] && serial_looks_wrong "$serial"; then
      say_tty ""
      say_tty "  \"$serial\" is ${#serial} bare digits and does not start with 2 — that is the"
      say_tty "  shape of an AnyDesk ID, not of a fleet serial (25010056, 260511734)."
      if [ "$(read_tty "  Use it anyway? (yes/NO): " | xargs)" != "yes" ]; then
        serial=""
      fi
    fi
  done

  log "serial confirmed by operator: $serial"
  printf "%s" "$serial"
}

# Short friendly label (Strapi machine.nickname) — purely for humans telling machines apart at a
# glance in the dashboard; has no bearing on telemetry/Keycloak identity, unlike serial_number.
prompt_for_nickname() {
  local nickname=""

  if [ -n "$MACHINE_NICKNAME" ]; then
    log "Using MACHINE_NICKNAME from environment"
    printf "%s" "$MACHINE_NICKNAME"
    return
  fi

  while [ -z "$nickname" ]; do
    nickname="$(read_tty "Enter machine nickname: " | xargs)"
  done

  printf "%s" "$nickname"
}

prompt_for_machine_type_id() {
  local type_id=""

  if [ -n "${MACHINE_TYPE_ID:-}" ]; then
    log "Using MACHINE_TYPE_ID from environment"
    printf "%s" "$MACHINE_TYPE_ID"
    return
  fi

  log "Fetching machine types from Strapi..."
  local token types_json
  token="$(strapi_token)"
  types_json="$(curl_json_logged GET "$STRAPI_BASE_URL/api/machine-types?pagination[pageSize]=100" "$token")"

  echo "" >/dev/tty
  echo "Available machine types:" >/dev/tty
  echo "$types_json" | python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", [])
if not data:
    print("  (no machine types found)", file=sys.stderr)
else:
    for item in data:
        mid = item["id"]
        mname = item["attributes"]["name"]
        print(f"  {mid}) {mname}", file=sys.stderr)
' 2>/dev/tty
  echo "" >/dev/tty

  while [ -z "$type_id" ]; do
    type_id="$(read_tty "Enter machine type ID: " | xargs)"
  done

  printf "%s" "$type_id"
}

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '\n'
  else
    date +%s%N | sha256sum | cut -c1-24
  fi
}

set_anydesk_password() {
  local password="$1"
  local attempt rc delay=5

  for attempt in 1 2 3 4 5; do
    rc=0
    printf "%s\n" "$password" | anydesk --set-password || rc=$?
    if [ "$rc" -eq 0 ]; then
      log "AnyDesk password set successfully (attempt $attempt)"
      return 0
    fi
    if [ "$attempt" -eq 5 ]; then
      break
    fi
    log "AnyDesk password attempt $attempt failed (exit $rc); AnyDesk rate-limits rapid password changes — retrying in ${delay}s"
    sleep "$delay"
    delay=$((delay * 2))
  done

  record_warning "AnyDesk password command failed after 5 attempts"
  return 1
}

install_base_packages() {
  log_section "Base Packages"
  log "Updating package index"
  apt-get update || {
    log "ERROR: apt-get update failed"
    log "Current apt sources:"
    find /etc/apt/sources.list /etc/apt/sources.list.d -maxdepth 1 -type f -print -exec sed -n '1,120p' {} \; 2>/dev/null || true
    return 1
  }

  log "Installing base packages"
  apt_install curl ca-certificates gnupg openssl openssh-server python3
}

disable_auto_updates() {
  log_section "Automatic Updates"
  # A kiosk must only ever be updated deliberately, by fleetpatch/fleetfirmware. There are four
  # independent channels and closing fewer than all four is a false sense of safety: machine 64
  # lost 1.5 days on 2026-08-01 to a kernel panic that traced back to an unsupervised apt run.
  # See Strapi knowledge rule-fleet-auto-updates-disabled-apt-and-snap.

  log "Disabling APT periodic jobs"
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

  systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  systemctl mask apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 \
    || record_warning "could not mask apt-daily timers"
  systemctl mask unattended-upgrades.service >/dev/null 2>&1 || true

  # snapd refreshes itself ~4x/day regardless of every apt setting above, and restarts services
  # under a running kiosk while it does. Needs snapd >= 2.58 for an indefinite hold.
  if command -v snap >/dev/null 2>&1; then
    log "Holding snap auto-refresh"
    snap refresh --hold >/dev/null 2>&1 \
      || record_warning "snap refresh --hold failed — snaps will keep auto-refreshing"
  fi

  # Verify rather than assume. `snap get system refresh.hold` stays "none" after --hold and will
  # happily lie to you; `snap refresh --time` is the only authoritative check.
  log "apt-daily.timer: $(systemctl is-enabled apt-daily.timer 2>&1)"
  log "apt-daily-upgrade.timer: $(systemctl is-enabled apt-daily-upgrade.timer 2>&1)"
  if command -v snap >/dev/null 2>&1; then
    local snap_hold
    snap_hold="$(snap refresh --time 2>/dev/null | awk '/^hold:/ {print $2}')"
    log "snap hold: ${snap_hold:-not held}"
    [ "$snap_hold" = "forever" ] || record_warning "snap auto-refresh is not held indefinitely"
  fi
}

# Fetch a file from the scripts repo, preferring a copy sitting next to this script (so a local
# checkout can be tested without pushing first). Echoes the path to use; empty on failure.
fetch_repo_file() {
  local relpath="$1" dest="$2"
  local sibling="$(dirname "${BASH_SOURCE[0]}")/$relpath"
  if [ -f "$sibling" ]; then
    cp -f "$sibling" "$dest" && { printf '%s' "$dest"; return 0; }
  fi
  if curl -fsSL --max-time 30 "$SCRIPTS_RAW_URL/$relpath" -o "$dest" && [ -s "$dest" ]; then
    printf '%s' "$dest"; return 0
  fi
  return 1
}

install_freeze_protection() {
  log_section "Freeze protection (c-state clamp + ShakerView watchdog)"
  if [ "$SKIP_FREEZE_PROTECTION" = "1" ]; then
    record_warning "freeze protection SKIPPED by SKIP_FREEZE_PROTECTION=1 — a wedged kiosk will stay wedged until someone drives to it"
    return 0
  fi

  # ---- 1. Recovery: the watchdog service ---------------------------------------------------
  # Installed unconditionally, on every CPU: the c-state clamp only addresses the Bay Trail
  # erratum, while a Unity main-thread stall can happen for other reasons entirely.
  local tmp_sh tmp_svc tmp_test
  tmp_sh="$(mktemp)"; tmp_svc="$(mktemp)"; tmp_test="$(mktemp)"
  if fetch_repo_file "watchdog/shakerview-watchdog.sh" "$tmp_sh" >/dev/null \
     && fetch_repo_file "watchdog/shakerview-watchdog.service" "$tmp_svc" >/dev/null; then
    # Never overwrite a good copy with a broken download: an incomplete 2026-07-29 edit once
    # shipped a script with every function body stripped, and it ran for a week as a silent
    # no-op because the unit stays "active" while each call inside it fails.
    local missing=""
    local fn
    for fn in log xauth_file as_user_x sv_pid firmware_write_active health_check \
              recover_dpms recover_restart_app recover_restart_gdm recover_reboot; do
      grep -qE "^$fn\(\) *\{" "$tmp_sh" || missing="$missing $fn"
    done
    if [ -n "$missing" ] || ! bash -n "$tmp_sh" 2>/dev/null; then
      record_warning "fetched watchdog script is unusable (missing:${missing:-none}, syntax $(bash -n "$tmp_sh" 2>&1 | head -c 80)) — NOT installed, machine has no freeze recovery"
    else
      [ -f /usr/local/bin/shakerview-watchdog.sh ] \
        && cp -a /usr/local/bin/shakerview-watchdog.sh "/usr/local/bin/shakerview-watchdog.sh.bak-$(date +%Y%m%d-%H%M%S)"
      install -m 755 -o root -g root "$tmp_sh" /usr/local/bin/shakerview-watchdog.sh
      install -m 644 -o root -g root "$tmp_svc" /etc/systemd/system/shakerview-watchdog.service
      systemctl daemon-reload
      # WantedBy=graphical.target, not multi-user.target -- pairing the unit's
      # After=graphical.target with multi-user.target forms an ordering cycle that systemd
      # breaks by dropping the start job, leaving the watchdog dead at boot.
      systemctl enable shakerview-watchdog >/dev/null 2>&1 \
        || record_warning "could not enable shakerview-watchdog — it will not start at boot"
      systemctl restart shakerview-watchdog \
        || record_warning "shakerview-watchdog failed to start"
      sleep 3
      local wstate
      wstate="$(systemctl is-active shakerview-watchdog 2>&1)"
      if [ "$wstate" = "active" ]; then
        log "watchdog installed and running (md5 $(md5sum /usr/local/bin/shakerview-watchdog.sh | awk '{print $1}'))"
      else
        record_warning "shakerview-watchdog is '$wstate' after install — no freeze recovery on this machine"
      fi
      # Prove it actually DETECTS faults rather than merely running. The suite feeds synthetic
      # conditions to health_check and touches only /tmp.
      if fetch_repo_file "watchdog/shakerview-watchdog.test.sh" "$tmp_test" >/dev/null; then
        if bash "$tmp_test" >/tmp/wd_test_out 2>&1; then
          log "watchdog self-test: $(grep -oE '[0-9]+ passed, [0-9]+ failed' /tmp/wd_test_out | tail -1)"
        else
          record_warning "watchdog SELF-TEST FAILED ($(grep -oE '[0-9]+ passed, [0-9]+ failed' /tmp/wd_test_out | tail -1)) — it runs but may not detect a real freeze"
        fi
        rm -f /tmp/wd_test_out
      fi
    fi
  else
    record_warning "could not obtain the watchdog script (local copy or $SCRIPTS_RAW_URL) — machine has NO freeze recovery"
  fi
  rm -f "$tmp_sh" "$tmp_svc" "$tmp_test"

  # ---- 2. Prevention: the c-state clamp ----------------------------------------------------
  local cpu
  cpu="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
  log "CPU: $cpu"
  if ! printf '%s' "$cpu" | grep -qE "$CSTATE_CPU_PATTERN"; then
    log "CPU is not in the freeze-prone Bay Trail set — no c-state clamp needed"
    return 0
  fi

  if grep -q 'intel_idle.max_cstate=1' /proc/cmdline; then
    log "c-state clamp already active on the running kernel"
    grep -q 'intel_idle.max_cstate=1' /etc/default/grub 2>/dev/null \
      || record_warning "c-state clamp is active now but missing from /etc/default/grub — it will be lost at the next kernel update"
    return 0
  fi

  # An interrupted apt can leave a vmlinuz with no matching initrd. update-grub happily makes
  # that orphan the default menu entry, and the machine kernel-panics on its next boot.
  local orphan=0 k v
  for k in /boot/vmlinuz-*; do
    [ -e "$k" ] || continue
    v="${k#/boot/vmlinuz-}"
    [ -f "/boot/initrd.img-$v" ] || { record_warning "/boot has an orphaned kernel $v (no initrd) — SKIPPING update-grub, it would arm an unbootable default entry. Fix with: apt-get install --reinstall linux-image-$v"; orphan=1; }
  done
  [ "$orphan" = "1" ] && return 0

  cp -a /etc/default/grub "/etc/default/grub.pre-cstate-$(date +%Y%m%d-%H%M%S)"
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
    sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 intel_idle.max_cstate=1"/' /etc/default/grub
  else
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_idle.max_cstate=1"\n' >>/etc/default/grub
  fi

  if ! grep -q 'intel_idle.max_cstate=1' /etc/default/grub; then
    record_warning "failed to add intel_idle.max_cstate=1 to /etc/default/grub — this Bay Trail machine stays freeze-prone"
    return 0
  fi
  if update-grub >/dev/null 2>&1 && grep -q 'intel_idle.max_cstate=1' /boot/grub/grub.cfg; then
    CSTATE_REBOOT_REQUIRED=1
    log "c-state clamp written to GRUB — takes effect on the next reboot"
  else
    record_warning "update-grub did not apply the c-state clamp — check /boot/grub/grub.cfg by hand"
  fi
}

configure_ssh() {
  log_section "SSH Setup"
  local password_auth="yes"
  local kbd_interactive_auth="yes"

  case "$SSH_AUTH_MODE" in
    key-only)
      password_auth="no"
      kbd_interactive_auth="no"
      ;;
    password|both)
      password_auth="yes"
      kbd_interactive_auth="yes"
      ;;
    *)
      log "ERROR: SSH_AUTH_MODE must be one of: key-only, password, both"
      exit 1
      ;;
  esac

  if ! id "$SSH_LOGIN_USER" >/dev/null 2>&1; then
    log "ERROR: SSH_LOGIN_USER does not exist: $SSH_LOGIN_USER"
    exit 1
  fi

  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/10-bootstrap-device.conf <<EOF
Port $SSH_PORT
PasswordAuthentication $password_auth
KbdInteractiveAuthentication $kbd_interactive_auth
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
EOF

  log "Linux password will NOT be changed by this script."

  # Generate host keys if missing. A golden image is scrubbed of host keys (so clones don't all
  # share one identity); ssh-keygen -A gives THIS unit its own fresh keys. Without this, a
  # keyless clone's sshd refuses every connection (socket-activated sshd needs keys on disk).
  log "Ensuring SSH host keys exist (unique per unit)"
  ssh-keygen -A || record_warning "ssh-keygen -A failed — SSH may be unreachable until host keys exist"

  log "Enabling SSH service"
  systemctl enable ssh
  if ! systemctl restart ssh; then
    log "ERROR: failed to restart ssh"
    systemctl status ssh --no-pager || true
    journalctl -u ssh -n 80 --no-pager || true
    return 1
  fi
  log "SSH service status: $(systemctl is-active ssh 2>/dev/null || echo unknown)"
}

reinstall_anydesk() {
  log_section "AnyDesk Setup"

  # Fetch the repository key BEFORE touching the working installation. The old order was
  # purge-then-download, so any transient DNS/network blip left the machine with no AnyDesk
  # at all -- and since main() called this step bare under `set -e`, the whole bootstrap
  # aborted right here and Tailscale, registration and the readiness gate never ran.
  # Observed on S-25011715S 2026-08-06: "curl: (6) Could not resolve host: keys.anydesk.com"
  # one minute after the purge succeeded. Remote access is the one thing provisioning must
  # never take away on its way to failing.
  local keyring_tmp attempt
  keyring_tmp="$(mktemp)"
  for attempt in 1 2 3; do
    # --batch --yes is required: mktemp has already created keyring_tmp, and gpg refuses to
    # write over an existing file, which would fail every attempt for a reason that has
    # nothing to do with the network.
    if curl -fsSL --connect-timeout 15 --max-time 60 https://keys.anydesk.com/repos/DEB-GPG-KEY 2>/dev/null \
         | gpg --batch --yes --dearmor -o "$keyring_tmp" 2>/dev/null && [ -s "$keyring_tmp" ]; then
      log "AnyDesk repository key downloaded (attempt $attempt)"
      break
    fi
    log "WARNING: AnyDesk repository key download failed (attempt $attempt/3)"
    : >"$keyring_tmp"
    [ "$attempt" -lt 3 ] && sleep 5
  done

  if [ ! -s "$keyring_tmp" ]; then
    rm -f "$keyring_tmp"
    record_warning "could not download the AnyDesk repository key — existing AnyDesk installation left UNTOUCHED and bootstrap continues"
    return 0
  fi

  log "Removing any existing AnyDesk installation (always reinstalling from scratch)"
  systemctl stop anydesk 2>/dev/null || true
  systemctl disable anydesk 2>/dev/null || true
  apt-get purge -y anydesk || true
  apt-get autoremove -y || true
  rm -rf /etc/anydesk /var/lib/anydesk /var/log/anydesk
  rm -rf "/home/${SUDO_USER:-$SSH_LOGIN_USER}/.anydesk"
  rm -f /etc/apt/sources.list.d/anydesk.list /etc/apt/keyrings/anydesk.gpg

  log "Adding AnyDesk repository"
  mkdir -p /etc/apt/keyrings
  install -m 0644 "$keyring_tmp" /etc/apt/keyrings/anydesk.gpg
  rm -f "$keyring_tmp"
  echo "deb [signed-by=/etc/apt/keyrings/anydesk.gpg] http://deb.anydesk.com/ all main" >/etc/apt/sources.list.d/anydesk.list

  log "Installing AnyDesk"
  apt-get update || {
    record_warning "apt-get update failed after adding the AnyDesk repository — AnyDesk NOT reinstalled"
    sed -n '1,120p' /etc/apt/sources.list.d/anydesk.list 2>/dev/null || true
    return 0
  }
  apt_install anydesk || {
    record_warning "AnyDesk package installation failed — machine has no AnyDesk, use RustDesk/Tailscale to reach it"
    apt-cache policy anydesk 2>/dev/null || true
    return 0
  }

  systemctl daemon-reload
  systemctl enable anydesk
  if ! systemctl restart anydesk; then
    record_warning "failed to restart AnyDesk after installing it"
    systemctl status anydesk --no-pager || true
    journalctl -u anydesk -n 100 --no-pager || true
    return 0
  fi
  sleep 15

  if [ -z "$ANYDESK_PASSWORD" ]; then
    ANYDESK_PASSWORD="$(generate_password)"
    log "No ANYDESK_PASSWORD available; generated a random one"
  fi

  if systemctl is-active anydesk >/dev/null 2>&1; then
    log "Setting AnyDesk unattended-access password"
    set_anydesk_password "$ANYDESK_PASSWORD" || true
  else
    record_warning "AnyDesk service is not active — cannot set password"
    systemctl status anydesk --no-pager || true
    journalctl -u anydesk -n 100 --no-pager || true
  fi
}

get_anydesk_id() {
  local id_value
  id_value="$(anydesk --get-id 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -z "$id_value" ]; then
    log "WARNING: AnyDesk ID is unavailable from anydesk --get-id"
  else
    log "AnyDesk ID detected: $id_value"
  fi
  printf "%s" "$id_value"
}

set_rustdesk_password() {
  local password="$1"
  local attempt rc delay=5

  for attempt in 1 2 3 4 5; do
    rc=0
    rustdesk --password "$password" 2>/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      log "RustDesk password set successfully (attempt $attempt)"
      return 0
    fi
    if [ "$attempt" -eq 5 ]; then
      break
    fi
    log "RustDesk password attempt $attempt failed (exit $rc); retrying in ${delay}s"
    sleep "$delay"
    delay=$((delay * 2))
  done

  log "WARNING: RustDesk password command failed after 5 attempts (non-critical)"
  return 1
}

reinstall_rustdesk() {
  log_section "RustDesk Setup"

  log "Removing any existing RustDesk installation (always reinstalling from scratch)"
  systemctl stop rustdesk 2>/dev/null || true
  systemctl disable rustdesk 2>/dev/null || true
  apt-get purge -y rustdesk || true
  apt-get autoremove -y || true
  rm -rf /etc/rustdesk /usr/share/rustdesk /var/log/rustdesk
  rm -rf "/home/${SUDO_USER:-$SSH_LOGIN_USER}/.config/rustdesk"
  rm -f /tmp/rustdesk-install.deb

  local arch rd_arch deb_url
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64) rd_arch="x86_64" ;;
    arm64) rd_arch="aarch64" ;;
    armhf) rd_arch="armv7" ;;
    *) rd_arch="x86_64" ;;
  esac

  log "Fetching latest RustDesk release metadata (arch: $rd_arch)"
  deb_url="$(
    curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest |
      RD_ARCH="$rd_arch" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
arch = os.environ["RD_ARCH"]
best = ""
for asset in data.get("assets", []):
    name = asset["name"]
    if name.endswith(".deb") and arch in name and "sciter" not in name:
        best = asset["browser_download_url"]
        break
print(best)
'
  )"

  if [ -z "$deb_url" ]; then
    log "ERROR: could not determine RustDesk .deb download URL"
    return 1
  fi

  log "Downloading RustDesk package from: $deb_url"
  if ! curl -fsSL "$deb_url" -o /tmp/rustdesk-install.deb; then
    log "ERROR: failed to download RustDesk package"
    return 1
  fi

  log "Installing RustDesk"
  apt-get update || true
  apt_install /tmp/rustdesk-install.deb || {
    log "ERROR: RustDesk package installation failed"
    return 1
  }

  systemctl daemon-reload
  systemctl enable rustdesk 2>/dev/null || true
  systemctl restart rustdesk 2>/dev/null || true
  sleep 10

  local service_status
  service_status="$(systemctl is-active rustdesk 2>/dev/null || echo inactive)"
  log "RustDesk service status: $service_status"

  if [ "$service_status" != "active" ]; then
    log "RustDesk service is not active (may be normal on builds without a system service — continuing)"
    systemctl status rustdesk --no-pager || true
    journalctl -u rustdesk -n 100 --no-pager || true
  fi

  if [ -z "$RUSTDESK_PASSWORD" ]; then
    RUSTDESK_PASSWORD="25410201ubuntu"
    log "No RUSTDESK_PASSWORD available (env/Strapi cred); using fleet default"
  fi

  log "Setting RustDesk unattended-access password"
  set_rustdesk_password "$RUSTDESK_PASSWORD" || true
}

get_rustdesk_id() {
  local id_value
  id_value="$(rustdesk --get-id 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -z "$id_value" ]; then
    log "WARNING: RustDesk ID is unavailable from rustdesk --get-id"
  else
    log "RustDesk ID detected: $id_value"
  fi
  printf "%s" "$id_value"
}

install_tailscale() {
  log "Removing any existing Tailscale installation (always reinstalling from scratch)"
  tailscale logout >/dev/null 2>&1 || true
  systemctl stop tailscaled 2>/dev/null || true
  apt-get purge -y tailscale || true
  apt-get autoremove -y || true
  rm -rf /var/lib/tailscale /etc/default/tailscaled
  rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg

  local os_codename
  os_codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-jammy}")"

  log "Installing Tailscale"
  install -d -m 0755 /usr/share/keyrings
  if ! curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${os_codename}.noarmor.gpg" >/usr/share/keyrings/tailscale-archive-keyring.gpg; then
    log "ERROR: failed to download Tailscale repository key for Ubuntu codename: $os_codename"
    return 1
  fi
  if ! curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${os_codename}.tailscale-keyring.list" >/etc/apt/sources.list.d/tailscale.list; then
    log "ERROR: failed to download Tailscale apt source for Ubuntu codename: $os_codename"
    return 1
  fi
  apt-get update || {
    log "ERROR: apt-get update failed after adding Tailscale repository"
    sed -n '1,120p' /etc/apt/sources.list.d/tailscale.list 2>/dev/null || true
    return 1
  }
  apt_install tailscale || {
    log "ERROR: Tailscale package installation failed"
    apt-cache policy tailscale 2>/dev/null || true
    return 1
  }
}

configure_tailscale() {
  log_section "Tailscale Setup"

  install_tailscale

  local up_args=()

  if [ -z "$TAILSCALE_AUTHKEY" ]; then
    log "ERROR: no Tailscale auth key available — refusing interactive login"
    return 1
  fi

  systemctl enable tailscaled
  if ! systemctl restart tailscaled; then
    log "ERROR: failed to restart tailscaled"
    systemctl status tailscaled --no-pager || true
    journalctl -u tailscaled -n 100 --no-pager || true
    return 1
  fi

  if [ "$ENABLE_TAILSCALE_SSH" = "true" ]; then
    up_args+=(--ssh)
  fi
  if [ -n "$TAILSCALE_ADVERTISE_TAGS" ]; then
    up_args+=(--advertise-tags="$TAILSCALE_ADVERTISE_TAGS")
  fi
  up_args+=(--authkey="$TAILSCALE_AUTHKEY")
  if [ -n "$TAILSCALE_HOSTNAME" ]; then
    up_args+=(--hostname="$TAILSCALE_HOSTNAME")
  fi
  if [ -n "$TAILSCALE_EXTRA_ARGS" ]; then
    # shellcheck disable=SC2206
    up_args+=($TAILSCALE_EXTRA_ARGS)
  fi

  if ! tailscale up "${up_args[@]}"; then
    log "ERROR: tailscale up failed"
    tailscale status || true
    journalctl -u tailscaled -n 100 --no-pager || true
    return 1
  fi

  log "Tailscale status after setup:"
  tailscale status || true
}

get_tailscale_ip() {
  tailscale ip -4 2>/dev/null | head -n1 || true
}

get_tailscale_hostname() {
  tailscale status --json 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("Self") or {}).get("DNSName","").rstrip("."))' 2>/dev/null || true
}

strapi_token() {
  local auth_payload response_file status

  if [ -z "$STRAPI_PASSWORD" ] && [ -s "$STRAPI_PASSWORD_FILE" ]; then
    STRAPI_PASSWORD="$(cat "$STRAPI_PASSWORD_FILE")"
  fi

  if [ -z "$STRAPI_PASSWORD" ]; then
    STRAPI_PASSWORD="$(read_secret_tty "Enter Strapi password for $STRAPI_IDENTIFIER: ")"
    printf "%s" "$STRAPI_PASSWORD" >"$STRAPI_PASSWORD_FILE"
  fi

  log "Authenticating to Strapi as $STRAPI_IDENTIFIER"
  auth_payload="$(
    STRAPI_IDENTIFIER="$STRAPI_IDENTIFIER" STRAPI_PASSWORD="$STRAPI_PASSWORD" python3 - <<'PY'
import json
import os
print(json.dumps({
    "identifier": os.environ["STRAPI_IDENTIFIER"],
    "password": os.environ["STRAPI_PASSWORD"],
}))
PY
  )"

  response_file="$(mktemp)"
  local attempt delay=5
  for attempt in 1 2 3 4; do
    status="$(curl $CURL_NET_OPTS -sS -o "$response_file" -w '%{http_code}' "$STRAPI_BASE_URL/api/auth/local" \
      -H 'Content-Type: application/json' \
      --data-binary "$auth_payload" || echo 000)"; status="${status: -3}"

    if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
      python3 -c 'import json,sys; print(json.load(sys.stdin)["jwt"])' <"$response_file"
      rm -f "$response_file"
      return 0
    fi

    if [ "$status" -lt 500 ] || [ "$attempt" -eq 4 ]; then
      log "ERROR: Strapi auth failed with HTTP $status"
      log "Response body:"
      sed -n '1,240p' "$response_file" >&2 || true
      rm -f "$response_file"
      return 1
    fi

    log "Strapi auth got HTTP $status (server-side/transient) — retrying in ${delay}s (attempt $attempt/4)"
    sleep "$delay"
    delay=$((delay * 2))
  done
}

curl_json_logged() {
  local method="$1"
  local url="$2"
  local token="$3"
  local payload="${4:-}"
  local response_file status attempt delay=5

  response_file="$(mktemp)"
  log "Strapi request: $method $url"

  for attempt in 1 2 3 4; do
    if [ -n "$payload" ]; then
      status="$(curl --globoff $CURL_NET_OPTS -sS -o "$response_file" -w '%{http_code}' -X "$method" "$url" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary "$payload" || echo 000)"; status="${status: -3}"
    else
      status="$(curl --globoff $CURL_NET_OPTS -sS -o "$response_file" -w '%{http_code}' -X "$method" "$url" \
        -H "Authorization: Bearer $token" || echo 000)"; status="${status: -3}"
    fi

    if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
      cat "$response_file"
      rm -f "$response_file"
      return 0
    fi

    if [ "$status" -lt 500 ] || [ "$attempt" -eq 4 ]; then
      log "ERROR: Strapi request failed with HTTP $status"
      log "Response body:"
      sed -n '1,240p' "$response_file" >&2 || true
      rm -f "$response_file"
      return 1
    fi

    log "Strapi request got HTTP $status (server-side/transient) — retrying in ${delay}s (attempt $attempt/4)"
    sleep "$delay"
    delay=$((delay * 2))
  done
}

load_creds_from_strapi() {
  local token creds_json ts_key anydesk_password rustdesk_password telemetry_password catalog_token ops_pubkey

  log "Fetching TS_KEY/ANYDESK_PASSWORD/RUSTDESK_PASSWORD/TELEMETRY_PASSWORD/CATALOG_TOKEN from Strapi cred entity"
  token="$(strapi_token)"
  creds_json="$(curl_json_logged GET "$STRAPI_BASE_URL/api/cred" "$token")" || {
    log "ERROR: failed to fetch Strapi cred entity"
    return 1
  }

  ts_key="$(echo "$creds_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((((d.get("data") or {}).get("attributes") or {}).get("creds") or {}).get("TS_KEY") or "")')"
  anydesk_password="$(echo "$creds_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((((d.get("data") or {}).get("attributes") or {}).get("creds") or {}).get("ANYDESK_PASSWORD") or "")')"
  rustdesk_password="$(echo "$creds_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((((d.get("data") or {}).get("attributes") or {}).get("creds") or {}).get("RUSTDESK_PASSWORD") or "")')"
  telemetry_password="$(echo "$creds_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((((d.get("data") or {}).get("attributes") or {}).get("creds") or {}).get("TELEMETRY_PASSWORD") or "")')"
  catalog_token="$(echo "$creds_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((((d.get("data") or {}).get("attributes") or {}).get("creds") or {}).get("CATALOG_TOKEN") or "")')"
  ops_pubkey="$(echo "$creds_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((((d.get("data") or {}).get("attributes") or {}).get("creds") or {}).get("OPS_SSH_PUBKEY") or "")')"

  if [ -z "$TAILSCALE_AUTHKEY" ] && [ -n "$ts_key" ]; then
    TAILSCALE_AUTHKEY="$ts_key"
    log "Loaded TAILSCALE_AUTHKEY from Strapi cred entity"
  fi

  if [ -z "$ANYDESK_PASSWORD" ] && [ -n "$anydesk_password" ]; then
    ANYDESK_PASSWORD="$anydesk_password"
    log "Loaded ANYDESK_PASSWORD from Strapi cred entity"
  fi

  if [ -z "$RUSTDESK_PASSWORD" ] && [ -n "$rustdesk_password" ]; then
    RUSTDESK_PASSWORD="$rustdesk_password"
    log "Loaded RUSTDESK_PASSWORD from Strapi cred entity"
  fi

  if [ -z "$MANAGE_PASSWORD" ] && [ -n "$telemetry_password" ]; then
    MANAGE_PASSWORD="$telemetry_password"
    log "Loaded MANAGE_PASSWORD (TELEMETRY_PASSWORD) from Strapi cred entity"
  fi

  # Same treatment as every other secret: an operator should never have to paste this
  # into a per-machine .env. Without it write_fleet_json() skips, and the machine ships
  # unable to pull its catalog or planogram -- which is exactly what happened on the
  # 2026-07-28 rebuild of serial 004.
  if [ -z "$FLEET_CATALOG_TOKEN" ] && [ -n "$catalog_token" ]; then
    FLEET_CATALOG_TOKEN="$catalog_token"
    log "Loaded FLEET_CATALOG_TOKEN (CATALOG_TOKEN) from Strapi cred entity"
  fi

  if [ -z "$OPS_SSH_PUBKEY" ] && [ -n "$ops_pubkey" ]; then
    OPS_SSH_PUBKEY="$ops_pubkey"
    log "Loaded OPS_SSH_PUBKEY from Strapi cred entity"
  fi
}

# Install the ops public key so the fleet tooling can reach this machine.
#
# fleetpulse.py and fleetpatch.py both connect with BatchMode=yes (no password prompt, by
# design — an interactive prompt in a cron sweep would hang it). A machine with only
# password auth therefore reports as "unreachable" and silently drops out of health
# monitoring and patch rollout. Every machine bootstrapped before this needed the key
# added by hand afterwards, which is exactly the per-machine step this removes.
#
# Additive: appends only if absent, never rewrites authorized_keys, and does not disturb
# password auth.
install_ops_ssh_key() {
  log_section "Install ops SSH public key (fleet tooling access)"
  if [ -z "$OPS_SSH_PUBKEY" ]; then
    record_warning "OPS_SSH_PUBKEY not set — fleet tooling (fleetpulse/fleetpatch) will see this machine as unreachable"
    return 0
  fi
  local home_dir
  home_dir="$(getent passwd "$SSH_LOGIN_USER" | cut -d: -f6)"
  if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
    record_warning "Home directory for $SSH_LOGIN_USER not found — ops SSH key not installed"
    return 0
  fi
  install -d -m 700 -o "$SSH_LOGIN_USER" -g "$SSH_LOGIN_USER" "$home_dir/.ssh"
  local ak="$home_dir/.ssh/authorized_keys"
  touch "$ak"
  if grep -qF "$OPS_SSH_PUBKEY" "$ak" 2>/dev/null; then
    log "ops SSH key already present in $ak"
  else
    printf '%s\n' "$OPS_SSH_PUBKEY" >>"$ak"
    log "ops SSH key appended to $ak"
  fi
  chown "$SSH_LOGIN_USER":"$SSH_LOGIN_USER" "$ak"
  chmod 600 "$ak"
}

json_payload() {
  MACHINE_SERIAL="$1" \
  ANYDESK_ID="$2" \
  TAILSCALE_IP_VALUE="$3" \
  MACHINE_TYPE_ID_VALUE="$4" \
  RUSTDESK_ID_VALUE="$5" \
  TAILSCALE_HOSTNAME_VALUE="$6" \
  HOSTNAME_VALUE="$7" \
  REG_CODE_VALUE="$8" \
  MACHINE_KEY_VALUE="$9" \
  MACHINE_SECRET_VALUE="${10}" \
  NICKNAME_VALUE="${11}" \
  RUSTDESK_PASSWORD_VALUE="$RUSTDESK_PASSWORD" \
  SSH_USER_VALUE="$SSH_LOGIN_USER" \
  SSH_PORT_VALUE="$SSH_PORT" \
  BOOTSTRAP_VERSION_VALUE="$BOOTSTRAP_VERSION" \
  UNITY_VERSION_VALUE="$UNITY_VERSION" \
  SSD_VERSION_VALUE="$SSD_VERSION" \
  ADMIN_COMMENT_VALUE="${ADMIN_COMMENT:-}" \
  MACHINE_STATUS_VALUE="${MACHINE_STATUS:-new}" \
  python3 - <<'PY'
import json
import os


def env_or_none(key):
    return os.environ.get(key) or None


data = {
    "status": os.environ.get("MACHINE_STATUS_VALUE") or "new",
    "admin_comment": env_or_none("ADMIN_COMMENT_VALUE"),
    "nickname": env_or_none("NICKNAME_VALUE"),
    "anydesk_id": env_or_none("ANYDESK_ID"),
    "serial_number": os.environ["MACHINE_SERIAL"],
    "tailscale_ip": env_or_none("TAILSCALE_IP_VALUE"),
    "machine_type": int(os.environ["MACHINE_TYPE_ID_VALUE"]) if os.environ["MACHINE_TYPE_ID_VALUE"] else None,
    "rustdesk_id": env_or_none("RUSTDESK_ID_VALUE"),
    "tailscale_hostname": env_or_none("TAILSCALE_HOSTNAME_VALUE"),
    "hostname": env_or_none("HOSTNAME_VALUE"),
    "ssh_user": env_or_none("SSH_USER_VALUE"),
    "ssh_port": int(os.environ["SSH_PORT_VALUE"]) if os.environ.get("SSH_PORT_VALUE") else None,
    "bootstrap_version": env_or_none("BOOTSTRAP_VERSION_VALUE"),
    "unity_version": env_or_none("UNITY_VERSION_VALUE"),
    "ssd_version": env_or_none("SSD_VERSION_VALUE"),
    "telemetry_reg_code": env_or_none("REG_CODE_VALUE"),
    "machine_key": env_or_none("MACHINE_KEY_VALUE"),
    "rustdesk_password": env_or_none("RUSTDESK_PASSWORD_VALUE"),
    "secret": os.environ["MACHINE_SECRET_VALUE"],
}

print(json.dumps({"data": data}))
PY
}

register_machine_in_strapi() {
  local serial_number="$1"
  local anydesk_id="$2"
  local tailscale_ip="$3"
  local machine_type_id="$4"
  local rustdesk_id="$5"
  local tailscale_hostname="$6"
  local hostname_value="$7"
  local reg_code="$8"
  local machine_key="$9"
  local machine_secret="${10}"
  local nickname="${11}"
  local token payload response

  require_command python3

  token="$(strapi_token)"

  payload="$(json_payload "$serial_number" "$anydesk_id" "$tailscale_ip" "$machine_type_id" "$rustdesk_id" "$tailscale_hostname" "$hostname_value" "$reg_code" "$machine_key" "$machine_secret" "$nickname")"

  log "Creating new Strapi machine (bootstrap never edits existing machine records)"
  response="$(curl_json_logged POST "$STRAPI_BASE_URL/api/machines" "$token" "$payload")"

  echo "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d["id"])'
}

manage_token() {
  if [ -z "$MANAGE_PASSWORD" ]; then
    MANAGE_PASSWORD="$(read_secret_tty "Enter manage.ishakerusa.com password for $MANAGE_USERNAME: ")"
  fi

  local response_file status
  response_file="$(mktemp)"
  status="$(curl $CURL_NET_OPTS -sS -o "$response_file" -w '%{http_code}' "$MANAGE_KEYCLOAK_TOKEN_URL" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=$MANAGE_CLIENT_ID" \
    --data-urlencode "username=$MANAGE_USERNAME" \
    --data-urlencode "password=$MANAGE_PASSWORD" || echo 000)"; status="${status: -3}"

  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' <"$response_file"
    rm -f "$response_file"
    return 0
  fi

  log "ERROR: manage.ishakerusa.com auth failed with HTTP $status"
  rm -f "$response_file"
  return 1
}

# The only source of truth for "did manage.ishakerusa.com actually create the machine": the same
# list the manage dashboard/mcp_telemetry reads from. secretKey coming back from the registration
# endpoint is NOT proof of this — see TELEMETRY_REGISTER_MAX_ATTEMPTS comment above.
manage_machine_registered() {
  local org_id="$1"
  local serial_number="$2"
  local token response_file status found

  token="$(manage_token)" || return 1

  response_file="$(mktemp)"
  status="$(curl $CURL_NET_OPTS -sS -o "$response_file" -w '%{http_code}' \
    "$MANAGE_API_BASE/api/telemetry-machine-control/machine/list-serial-number/$org_id" \
    -H "Authorization: Bearer $token" || echo 000)"; status="${status: -3}"

  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    log "WARNING: could not fetch manage machine list for org $org_id (HTTP $status) — treating as not-yet-registered"
    rm -f "$response_file"
    return 1
  fi

  found="$(SERIAL="$serial_number" python3 -c '
import json, os, sys
target = os.environ["SERIAL"]
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get("data", [])
for item in items:
    if item.get("serialNumber") == target:
        print("yes")
        break
' <"$response_file")"
  rm -f "$response_file"
  [ "$found" = "yes" ]
}

fetch_reg_code() {
  log_section "Telemetry REG Code (org $MANAGE_ORG_ID)"
  local token response_file status code

  token="$(manage_token)" || {
    record_warning "Could not authenticate to manage.ishakerusa.com — skipping REG code fetch"
    return 1
  }

  response_file="$(mktemp)"
  status="$(curl $CURL_NET_OPTS -sS -o "$response_file" -w '%{http_code}' -X POST \
    "$MANAGE_API_BASE/api/telemetry-machine-control/registration-code/create-or-get/$MANAGE_ORG_ID" \
    -H "Authorization: Bearer $token" || echo 000)"; status="${status: -3}"

  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    code="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("code") or "")' <"$response_file")"
    rm -f "$response_file"
    if [ -n "$code" ]; then
      log "Telemetry REG code for org $MANAGE_ORG_ID: $code"
      printf "%s" "$code"
      return 0
    fi
    record_warning "manage.ishakerusa.com returned no REG code"
    return 1
  fi

  log "ERROR: REG code fetch failed with HTTP $status"
  sed -n '1,120p' "$response_file" >&2 || true
  rm -f "$response_file"
  record_warning "Could not fetch telemetry REG code from manage.ishakerusa.com"
  return 1
}

telemetry_model_name_for_type() {
  local machine_type_id="$1"
  local token types_json strapi_name lower

  token="$(strapi_token)"
  types_json="$(curl_json_logged GET "$STRAPI_BASE_URL/api/machine-types?pagination[pageSize]=100" "$token")" || {
    printf "Shaker S"
    return 0
  }

  strapi_name="$(echo "$types_json" | MACHINE_TYPE_ID="$machine_type_id" python3 -c '
import json, os, sys
data = json.load(sys.stdin).get("data", [])
target = os.environ["MACHINE_TYPE_ID"]
for item in data:
    if str(item["id"]) == target:
        print(item["attributes"]["name"])
        break
')"

  lower="$(echo "$strapi_name" | tr "[:upper:]" "[:lower:]")"
  case "$lower" in
    *milkshaker*|*milk*) printf "Milkshaker S" ;;
    *touch*) printf "ShakerTouch" ;;
    *) printf "Shaker S" ;;
  esac
}

redeem_reg_code() {
  log_section "Telemetry Machine Registration (redeem REG code)"
  local reg_code="$1"
  local serial_number="$2"
  local machine_type_id="$3"
  local model_name payload response_file status secret_key message telemetry_machine_id reg_type

  model_name="$(telemetry_model_name_for_type "$machine_type_id")"
  log "Resolved telemetry model name: $model_name"

  payload="$(MODEL_NAME="$model_name" SERIAL="$serial_number" python3 -c '
import json
import os
import datetime

model = os.environ["MODEL_NAME"]
print(json.dumps({
    "modelName": model,
    "machineName": f"{model} {datetime.datetime.now():%d.%m.%Y}",
    "serialNumber": os.environ["SERIAL"],
}))
')"

  response_file="$(mktemp)"
  status="$(curl $CURL_NET_OPTS -sS -o "$response_file" -w '%{http_code}' -X POST \
    "$MANAGE_API_BASE/api/telemetry-machine-control/machine/registration/$reg_code" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload" || echo 000)"; status="${status: -3}"

  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    secret_key="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("secretKey") or "")' <"$response_file")"
    # Registration also creates the machine on the manage.ishakerusa.com side — pull its id back
    # out so it can be written into the on-device telemetry.json alongside the MachineKey. Field
    # name isn't nailed down from docs, so try the plausible candidates rather than assume one.
    telemetry_machine_id="$(python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("machineId", "id"):
    v = d.get(k)
    if v:
        print(v)
        break
else:
    nested = d.get("machine") or d.get("data") or {}
    print(nested.get("id") or "")
' <"$response_file")"
    message="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("message") or "")' <"$response_file")"
    reg_type="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("type") or "")' <"$response_file")"
    rm -f "$response_file"
    if [ -n "$secret_key" ]; then
      log "Telemetry MachineKey obtained automatically (no on-device REG entry needed), type=${reg_type:-unknown}"
      if [ -n "$telemetry_machine_id" ]; then
        log "Telemetry MachineId: $telemetry_machine_id"
      else
        log "Registration response had no recognizable machineId field — MachineId will be left null in telemetry.json"
      fi
      # Three lines on stdout (secret_key, telemetry_machine_id, reg_type) — this function's return
      # value is captured via $(...) by the caller, so nothing else may write to stdout from in
      # here. apply_telemetry_credentials() is deliberately NOT called from this function: it's a
      # plain function (not a subshell) that logs via log()/prints via python, and calling it
      # inside a command-substitution context would leak that output into the captured return
      # value (this bit us once already — see
      # [[bug-bootstrap-telemetry-machinekey-not-written-to-device-plus-wrong-default-org]]
      # follow-up). The caller applies the credentials after capturing all three values.
      printf '%s\n%s\n%s\n' "$secret_key" "$telemetry_machine_id" "$reg_type"
      return 0
    fi
    log "Telemetry registration response had no secretKey (message: ${message:-none})"
    record_warning "Telemetry auto-registration did not return a MachineKey (${message:-no message}) — on-device REG entry still needed"
    return 1
  fi

  log "ERROR: telemetry registration failed with HTTP $status"
  sed -n '1,200p' "$response_file" >&2 || true
  rm -f "$response_file"
  record_warning "Could not redeem telemetry REG code via API — on-device REG entry still needed"
  return 1
}

# Wraps redeem_reg_code() with the verify-or-burn-and-retry loop: a secretKey coming back is not
# proof manage.ishakerusa.com actually created the machine (see
# [[manage-registration-mints-keycloak-not-machine-record]]), and retrying the SAME serial only
# ever gets a "REFRESH" of the already-orphaned client, never a fresh registration attempt. So each
# failed-to-verify attempt burns that serial for good and moves to a new one (base serial suffixed
# with a random tag) until manage's own machine list actually shows it, or attempts run out.
#
# On success prints THREE lines: the serial_number that actually worked (may differ from
# $base_serial — callers must use this one for everything downstream: Strapi record,
# hard_settings.MachineSerial, credentials file), machine_key, telemetry_machine_id.
register_telemetry_with_retry() {
  local base_serial="$1"
  local machine_type_id="$2"
  local org_id="$MANAGE_ORG_ID"
  local reg_code attempt candidate_serial redeem_output machine_key telemetry_machine_id reg_type
  local poll verified

  log_section "Telemetry registration (verify-or-retry, up to $TELEMETRY_REGISTER_MAX_ATTEMPTS attempts)"

  reg_code="$(fetch_reg_code)" || return 1

  for attempt in $(seq 1 "$TELEMETRY_REGISTER_MAX_ATTEMPTS"); do
    if [ "$attempt" -eq 1 ]; then
      candidate_serial="$base_serial"
    else
      candidate_serial="${base_serial}-r$(python3 -c 'import secrets; print(secrets.token_hex(2))')"
    fi
    log "Attempt $attempt/$TELEMETRY_REGISTER_MAX_ATTEMPTS: redeeming reg code $reg_code for serial $candidate_serial"

    redeem_output="$(redeem_reg_code "$reg_code" "$candidate_serial" "$machine_type_id" || true)"
    machine_key="$(printf '%s\n' "$redeem_output" | sed -n '1p')"
    telemetry_machine_id="$(printf '%s\n' "$redeem_output" | sed -n '2p')"
    reg_type="$(printf '%s\n' "$redeem_output" | sed -n '3p')"

    if [ -z "$machine_key" ]; then
      log "Attempt $attempt: no MachineKey returned for $candidate_serial — trying a fresh serial"
      continue
    fi

    verified=0
    for poll in $(seq 1 "$TELEMETRY_VERIFY_POLL_ATTEMPTS"); do
      if manage_machine_registered "$org_id" "$candidate_serial"; then
        verified=1
        break
      fi
      sleep "$TELEMETRY_VERIFY_POLL_DELAY"
    done

    if [ "$verified" = "1" ]; then
      log "CONFIRMED: $candidate_serial (type=${reg_type:-unknown}) is visible in manage org $org_id machine list"
      printf '%s\n%s\n%s\n' "$candidate_serial" "$machine_key" "$telemetry_machine_id"
      return 0
    fi

    log "Attempt $attempt: $candidate_serial got a Keycloak client (type=${reg_type:-unknown}) but never showed up in manage org $org_id's machine list after ${TELEMETRY_VERIFY_POLL_ATTEMPTS}x${TELEMETRY_VERIFY_POLL_DELAY}s — burning this serial, trying a new one"
  done

  record_warning "Exhausted $TELEMETRY_REGISTER_MAX_ATTEMPTS telemetry registration attempts — none produced a manage machine record (known manage.ishakerusa.com-side gap). Falling back to on-device manual REG entry with base serial $base_serial."
  return 1
}

# redeem_reg_code() gets a real MachineKey (and, when the API returns it, a MachineId) from
# manage.ishakerusa.com and records them in Strapi + the local credentials file — but ShakerView
# itself only ever reads its identity from the on-device telemetry.json, so without this step the
# app has no way to authenticate telemetry even though registration "succeeded". Mirrors
# scrub_clone_identity()'s file glob/backup pattern.
apply_telemetry_credentials() {
  log_section "Apply telemetry credentials to on-device Config"
  local machine_key="$1"
  local telemetry_machine_id="${2:-}"
  local org_id="${3:-}"
  local tj found=0

  for tj in /home/*/ShakerView2.0Linux*/ShakerView2.0_Data/Config/telemetry.json; do
    [ -e "$tj" ] || continue
    found=1
    cp -a "$tj" "${tj}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    if TJ="$tj" MACHINE_KEY="$machine_key" TELEMETRY_MACHINE_ID="$telemetry_machine_id" ORG_ID="$org_id" python3 - <<'PY'
import json, os, sys
p = os.environ["TJ"]
try:
    with open(p, encoding="utf-8-sig") as fh:
        d = json.load(fh)
except Exception as e:
    print(f"unreadable {p}: {e}", file=sys.stderr)
    sys.exit(1)

d["MachineKey"] = os.environ["MACHINE_KEY"]

mid = os.environ.get("TELEMETRY_MACHINE_ID", "")
d["MachineId"] = int(mid) if mid.isdigit() else None

org = os.environ.get("ORG_ID", "")
d["OrganizationId"] = int(org) if org.isdigit() else None

with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, ensure_ascii=False, indent=2)
print("updated", p)
PY
    then
      log "telemetry MachineKey/MachineId/OrganizationId written to $tj (backup kept alongside)"
    else
      record_warning "Could not write telemetry credentials to $tj — MachineKey exists in Strapi/credentials file but ShakerView won't authenticate until this is applied manually"
    fi
  done
  if [ "$found" = "0" ]; then
    record_warning "No on-device telemetry.json found to apply MachineKey to — ShakerView Config path differs from expected glob, or app not installed yet"
  fi
}

# ShakerView authenticates telemetry to Keycloak with client_id == hard_settings.json "MachineSerial"
# (verified: a working machine's MachineSerial IS its machine-realm client_id). Telemetry registration
# above mints a Keycloak client whose id is the serial_number we just registered, so the on-device
# MachineSerial MUST be set to that same serial — otherwise ShakerView presents a stale/mismatched
# client_id and gets 401 unauthorized_client. This is exactly what breaks cloned goldens that keep the
# master's MachineSerial (e.g. MS-25081725). scrub_clone_identity() clears the master's KEY but not this.
# fleet.json is per-machine only in that it lives on the machine: the CONTENT is identical
# fleet-wide (url + shared token + interval). Everything machine-specific -- which products,
# which container, prices -- is resolved server-side from the serial, so this file never has
# to be regenerated when the client changes anything.
# Probe the live catalog endpoint with a candidate credential.
# Echoes the HTTP status. 200 and 404 both mean AUTHENTICATED: 404 is the normal answer for
# a freshly bootstrapped machine that has no product lines or cells yet. Only 401/403 mean
# the credential itself was rejected.
# Retries, because at this point in bootstrap the Tailscale route to the Strapi box is
# often still settling: machine 78 (260511736) probed both credentials, got a connect
# timeout on each, and fell through to the unverified branch — which then wrote a token
# the server rejects. A transient network state must not decide which credential ships.
probe_catalog_credential() {
  local serial="$1" token="$2" code attempt
  for attempt in 1 2 3 4 5; do
    # curl prints "000" itself on failure AND exits non-zero, so a `|| echo 000` here
    # concatenates into "000000" and matches no case branch. Swallow the exit code instead.
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      -H "Authorization: Bearer $token" \
      "$FLEET_CATALOG_URL/api/machines/$serial/catalog" 2>/dev/null)" || true
    [ -n "$code" ] || code=000
    if [ "$code" != "000" ]; then break; fi
    # `cmd && sleep` as the last statement would leave the loop with status 1 on the final
    # attempt, and this script runs under `set -e`.
    if [ "$attempt" -lt 5 ]; then sleep 10; fi
  done
  printf '%s' "$code"
}

# Write Config/fleet.json with a credential PROVEN to work against the server that is
# actually running.
#
# Two credentials can be valid: this machine's own secret (preferred — nothing to
# distribute, and a leak exposes one machine instead of the fleet) and the shared
# CATALOG_TOKEN (older servers only know this one). Rather than assume which the server
# supports, try them in order and keep the first that authenticates. That is what makes
# bootstrap work out of the box against either server version.
write_fleet_json() {
  log_section "Write FleetCatalog config (Config/fleet.json)"
  local machine_secret="${1:-}" serial="${2:-}"

  local -a candidates=() labels=()
  [ -n "$machine_secret" ] && { candidates+=("$machine_secret"); labels+=("this machine's own secret"); }
  [ -n "$FLEET_CATALOG_TOKEN" ] && { candidates+=("$FLEET_CATALOG_TOKEN"); labels+=("shared CATALOG_TOKEN"); }

  if [ "${#candidates[@]}" -eq 0 ]; then
    record_warning "No catalog credential (neither machine secret nor CATALOG_TOKEN) — fleet.json NOT written; the machine will not pull catalog or planogram"
    return 0
  fi

  local fleet_token="" chosen_label="" i code
  if [ -n "$serial" ]; then
    for i in "${!candidates[@]}"; do
      code="$(probe_catalog_credential "$serial" "${candidates[$i]}")"
      case "$code" in
        200|404)
          fleet_token="${candidates[$i]}"; chosen_label="${labels[$i]}"
          log "Catalog credential verified: ${labels[$i]} (HTTP $code$([ "$code" = 404 ] && echo ' — authenticated, no catalog configured yet'))"
          break ;;
        401|403)
          log "Catalog credential rejected: ${labels[$i]} (HTTP $code) — trying next" ;;
        *)
          log "Catalog endpoint unreachable while testing ${labels[$i]} (HTTP $code)" ;;
      esac
    done
  fi

  # Could not prove any of them (server down, or nothing accepted). Write one anyway: an
  # unverified file the operator can see beats no file at all, and the machine retries every
  # refresh_minutes regardless.
  #
  # When guessing, pick the SHARED CATALOG_TOKEN, not the machine secret. Per-machine secret
  # auth exists only on the dev Strapi (commit dc6915f) and is not deployed to prod, so the
  # secret is the one credential guaranteed to fail today, while the shared token is the one
  # every running server accepts. The secret still wins whenever the probe actually proves it,
  # so this fallback expires by itself once per-machine auth ships.
  if [ -z "$fleet_token" ]; then
    local pick=0 j
    for j in "${!labels[@]}"; do
      if [ "${labels[$j]}" = "shared CATALOG_TOKEN" ]; then pick="$j"; break; fi
    done
    fleet_token="${candidates[$pick]}"; chosen_label="${labels[$pick]} (UNVERIFIED)"
    record_warning "Could not verify any catalog credential against $FLEET_CATALOG_URL — writing fleet.json with ${labels[$pick]} (the credential every server version accepts); if the machine logs 401, check $FLEET_CATALOG_URL is reachable from the machine"
  fi

  local found=0
  for cfg in /home/*/ShakerView2.0Linux*/ShakerView2.0_Data/Config; do
    [ -d "$cfg" ] || continue
    found=1
    local owner
    owner="$(stat -c %U "$cfg" 2>/dev/null || echo shaker)"
    [ -f "$cfg/fleet.json" ] && cp -a "$cfg/fleet.json" "$cfg/fleet.json.bak-$(date +%Y%m%d-%H%M%S)"
    cat >"$cfg/fleet.json" <<EOF
{
  "enabled": true,
  "catalog": true,
  "planogram": true,
  "url": "$FLEET_CATALOG_URL",
  "token": "$fleet_token",
  "refresh_minutes": $FLEET_REFRESH_MINUTES
}
EOF
    chown "$owner":"$owner" "$cfg/fleet.json" 2>/dev/null || true
    chmod 600 "$cfg/fleet.json"
    log "fleet.json written to $cfg (credential: $chosen_label, url=$FLEET_CATALOG_URL, refresh=${FLEET_REFRESH_MINUTES}m)"
  done
  if [ "$found" = "0" ]; then
    record_warning "No ShakerView Config directory found — fleet.json not written"
  fi
}

apply_hard_settings_serial() {
  log_section "Align on-device hard_settings MachineSerial with registered serial"
  local serial_number="$1"
  local hs found=0
  for hs in /home/*/ShakerView2.0Linux*/ShakerView2.0_Data/Config/hard_settings.json; do
    [ -e "$hs" ] || continue
    found=1
    cp -a "$hs" "${hs}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    if HS="$hs" SERIAL="$serial_number" python3 - <<'PY'
import json, os, sys
p = os.environ["HS"]
try:
    with open(p, encoding="utf-8-sig") as fh:
        d = json.load(fh)
except Exception as e:
    print(f"unreadable {p}: {e}", file=sys.stderr)
    sys.exit(1)
old = d.get("MachineSerial")
d["MachineSerial"] = os.environ["SERIAL"]
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, ensure_ascii=False, indent=2)
print(f"MachineSerial {old!r} -> {os.environ['SERIAL']!r}")
PY
    then
      log "hard_settings MachineSerial set to $serial_number in $hs (backup kept alongside)"
    else
      record_warning "Could not set MachineSerial in $hs — ShakerView Keycloak client_id stays stale and telemetry will 401"
    fi
  done
  if [ "$found" = "0" ]; then
    record_warning "No on-device hard_settings.json found to set MachineSerial — telemetry client_id may be wrong"
  fi
}

# Prove the registration actually works: request a machine-realm token exactly as ShakerView will
# (client_credentials, client_id=serial, client_secret=MachineKey). A 2xx with an access_token means
# telemetry auth is guaranteed to succeed on-device; anything else is surfaced loudly (warning) so it
# gets fixed before the machine is cloned/handed off. This is the "make sure it registers" guarantee.
verify_telemetry_auth() {
  log_section "Verify telemetry authentication (machine-realm token)"
  local serial_number="$1"
  local machine_key="$2"
  if [ -z "$machine_key" ]; then
    record_warning "Skipping telemetry auth verification — no MachineKey was obtained"
    return 1
  fi
  local response_file status
  response_file="$(mktemp)"
  status="$(curl $CURL_NET_OPTS -sS -o "$response_file" -w '%{http_code}' "$TELEMETRY_KEYCLOAK_TOKEN_URL" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=$serial_number" \
    --data-urlencode "client_secret=$machine_key" || echo 000)"; status="${status: -3}"
  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ] && \
     python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("access_token") else 1)' <"$response_file"; then
    rm -f "$response_file"
    log "Telemetry auth VERIFIED: client_id=$serial_number authenticates in machine-realm — ShakerView telemetry will connect"
    TELEMETRY_AUTH_VERIFIED=1
    return 0
  fi
  log "ERROR: telemetry auth verification failed with HTTP $status"
  sed -n '1,50p' "$response_file" >&2 || true
  rm -f "$response_file"
  record_warning "Telemetry auth verification FAILED (HTTP $status) for client_id=$serial_number — ShakerView will 401; check the registered serial matches hard_settings.MachineSerial and the MachineKey is valid"
  TELEMETRY_AUTH_VERIFIED=0
  return 1
}

write_credentials_file() {
  local machine_id="$1"
  local serial_number="$2"
  local anydesk_id="$3"
  local tailscale_ip="$4"
  local tailscale_hostname="$5"
  local rustdesk_id="$6"
  local reg_code="${7:-}"
  local machine_secret="${8:-}"
  local credentials_file="$SCRIPT_DIR/bootstrap-credentials-${serial_number}.txt"

  umask 077
  {
    echo "Created: $(date -Is)"
    echo "Strapi machine id: $machine_id"
    echo "Serial number: $serial_number"
    echo "Hostname: $(hostname)"
    echo "SSH user: $SSH_LOGIN_USER"
    echo "Linux password changed by bootstrap: no"
    echo "SSH port: $SSH_PORT"
    echo "Tailscale IPv4: $tailscale_ip"
    echo "Tailscale hostname: $tailscale_hostname"
    echo "AnyDesk ID: $anydesk_id"
    echo "AnyDesk password: $ANYDESK_PASSWORD"
    echo "RustDesk ID: $rustdesk_id"
    echo "RustDesk password: $RUSTDESK_PASSWORD"
    echo "Telemetry REG code (org $MANAGE_ORG_ID): ${reg_code:-unavailable, fetch manually from manage.ishakerusa.com}"
    echo "Strapi machine secret: $machine_secret"
    echo "(secret is a private Strapi field — this file is the only place it will ever be readable again)"
    echo "Bootstrap log: $LOGFILE"
  } >"$credentials_file"

  chmod 600 "$credentials_file"
  if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    chown "$SUDO_USER:$SUDO_USER" "$credentials_file" || true
  fi
  log "Credentials saved to $credentials_file"
}

# When a machine is prepared by cloning a "golden" SSD, the clone carries the golden's identity.
# Two pieces would otherwise ship unchanged and cause harm:
#   - the golden's ShakerView telemetry secret (MachineKey/SnackKey) in telemetry.json — a clone
#     that keeps it authenticates to the telemetry backend AS the golden (impersonation, the
#     2026-06-30 incident shape);
#   - stale bootstrap_device_*.log files from the golden build, which contain credentials.
# Scrub both at the start of every bootstrap run so each unit registers cleanly as itself.
# Telemetry files are backed up (.bak-<ts>) before editing, never blind-deleted.
scrub_clone_identity() {
  log_section "Scrub cloned-golden identity (telemetry secret + old bootstrap logs)"

  # 1) Remove old bootstrap logs carried in the image (keep THIS run's log).
  local home_dir="${LOG_OWNER_HOME:-$HOME}" removed=0 f
  if [ -n "$home_dir" ] && [ -d "$home_dir" ]; then
    for f in "$home_dir"/bootstrap_device_*.log; do
      [ -e "$f" ] || continue
      [ "$f" = "$LOGFILE" ] && continue
      rm -f "$f" && removed=$((removed + 1))
    done
  fi
  log "Removed $removed old bootstrap_device_*.log file(s)"

  # 2) Clear the golden's telemetry secret from any on-machine telemetry.json (back up first).
  local tj found=0
  for tj in /home/*/ShakerView2.0Linux*/ShakerView2.0_Data/Config/telemetry.json; do
    [ -e "$tj" ] || continue
    found=1
    cp -a "$tj" "${tj}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    if TJ="$tj" python3 - <<'PY'
import json, os, sys
p = os.environ["TJ"]
try:
    with open(p, encoding="utf-8-sig") as fh:
        d = json.load(fh)
except Exception as e:
    print(f"unreadable {p}: {e}", file=sys.stderr)
    sys.exit(1)
changed = False
for k in ("MachineKey", "SnackKey"):  # the per-machine auth secrets — clearing kills impersonation
    if d.get(k):
        d[k] = ""
        changed = True
if changed:
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(d, fh, ensure_ascii=False, indent=2)
print("scrubbed" if changed else "already-clean", p)
PY
    then
      log "telemetry secret scrubbed in $tj (backup kept alongside)"
    else
      record_warning "Could not scrub telemetry.json at $tj — clear MachineKey manually before cloning"
    fi
  done
  if [ "$found" = "0" ]; then
    log "No telemetry.json found to scrub (fresh install, nothing carried over)"
  fi
}

# Blocking acceptance test. READ-ONLY: it changes nothing, it only decides whether this
# machine may be called finished. Sets READINESS_VERDICT to SHIP / REVIEW / DO_NOT_SHIP /
# UNVERIFIED, and records a warning (which makes bootstrap exit non-zero) for anything but SHIP.
run_readiness_gate() {
  log_section "Readiness gate (diagnose.sh --mode unit)"
  if [ "$SKIP_READINESS_GATE" = "1" ]; then
    READINESS_VERDICT="SKIPPED"
    record_warning "readiness gate SKIPPED by SKIP_READINESS_GATE=1 — this machine ships unverified"
    return 0
  fi

  local script="" tmp=""
  local sibling="$(dirname "${BASH_SOURCE[0]}")/diagnose.sh"
  if [ -f "$sibling" ]; then
    script="$sibling"
    log "using local diagnose.sh: $sibling"
  else
    tmp="$(mktemp)"
    if curl -fsSL --max-time 30 "$DIAGNOSE_URL" -o "$tmp" && [ -s "$tmp" ]; then
      script="$tmp"
      log "fetched diagnose.sh from $DIAGNOSE_URL"
    else
      rm -f "$tmp"
      READINESS_VERDICT="UNVERIFIED"
      record_warning "could not fetch diagnose.sh from $DIAGNOSE_URL — readiness gate did not run, machine is UNVERIFIED"
      return 0
    fi
  fi

  local home_dir jf
  home_dir="$(getent passwd "$SSH_LOGIN_USER" | cut -d: -f6)"
  [ -d "$home_dir" ] || home_dir="/tmp"
  jf="$home_dir/readiness-$(date +%Y%m%d-%H%M%S).json"
  READINESS_REPORT="$jf"

  # stdout is the JSON report; the human-readable lines come out on stderr and land in the
  # bootstrap log through the tee at the top of this script.
  bash "$script" local --mode=unit --json >"$jf"
  local rc=$?
  [ -n "$tmp" ] && rm -f "$tmp"
  chown "$SSH_LOGIN_USER":"$SSH_LOGIN_USER" "$jf" 2>/dev/null || true

  READINESS_VERDICT="$(python3 -c "import json;print(json.load(open('$jf'))['verdict'])" 2>/dev/null)"
  [ -n "$READINESS_VERDICT" ] || READINESS_VERDICT="UNVERIFIED"
  log "readiness gate exit=$rc verdict=$READINESS_VERDICT report=$jf"

  local failed
  failed="$(python3 -c "
import json
d=json.load(open('$jf'))
print(', '.join(c['id'] for c in d['checks'] if c['level']=='FAIL'))" 2>/dev/null)"

  case "$READINESS_VERDICT" in
    SHIP)
      log "Readiness gate PASSED — machine is shippable" ;;
    REVIEW)
      record_warning "readiness gate: REVIEW (warnings only, no hard failures) — read $jf before shipping" ;;
    DO_NOT_SHIP)
      record_warning "READINESS GATE FAILED — machine is NOT shippable. Failing checks: ${failed:-see report}. Full report: $jf" ;;
    *)
      record_warning "readiness gate produced no usable verdict — machine is UNVERIFIED (report: $jf)" ;;
  esac
}

# Bring the kiosk back up once provisioning is done, the same way run.sh does.
#
# run.sh is just `DISPLAY=:0 exec /home/shaker/AppManager`, but bootstrap runs as root, so
# copying that line verbatim would start the watchdog in root's session with no X credentials
# and nothing would appear on the screen. The launch has to be handed back to the desktop user
# with a full X/D-Bus environment.
#
# Deliberately NOT nohup or a systemd unit: AppManager is terminal-attached by design so a
# technician on site can stop the kiosk by closing the window. Nothing is ever killed here
# either — if the watchdog is already up, a second copy would only fight it for the app.
start_kiosk_app() {
  log_section "Start kiosk app (AppManager)"

  if [ "$START_APP_AFTER_BOOTSTRAP" != "true" ]; then
    log "START_APP_AFTER_BOOTSTRAP=$START_APP_AFTER_BOOTSTRAP — leaving the kiosk stopped"
    return 0
  fi

  local user home uid appmanager xauth running
  user="${SUDO_USER:-$(id -un)}"
  home="$(getent passwd "$user" | cut -d: -f6)"
  uid="$(id -u "$user" 2>/dev/null || true)"
  appmanager="$home/AppManager"

  if [ -z "$uid" ] || [ ! -x "$appmanager" ]; then
    record_warning "AppManager missing or not executable at $appmanager — kiosk NOT started"
    return 0
  fi

  # comm-based, never `pgrep -f`: AppManager's own command line embeds the ShakerView binary
  # path, so a full-cmdline match counts the watchdog as though it were the app itself.
  running="$(ps -eo comm | grep -c '^AppManager$' || true)"
  if [ "$running" -gt 0 ]; then
    log "AppManager already running ($running instance(s)) — its own loop will pick up ShakerView"
    return 0
  fi

  xauth="/run/user/$uid/gdm/Xauthority"
  [ -f "$xauth" ] || xauth="$home/.Xauthority"

  log "Launching $appmanager as $user (DISPLAY=:0, XAUTHORITY=$xauth)"
  if sudo -u "$user" env \
      DISPLAY=:0 \
      XAUTHORITY="$xauth" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      gnome-terminal --working-directory="$home" -- "$appmanager" >/dev/null 2>&1; then
    sleep 5
    running="$(ps -eo comm | grep -c '^AppManager$' || true)"
    if [ "$running" -gt 0 ]; then
      log "AppManager is up"
    else
      record_warning "AppManager was launched but is not running 5s later — check the kiosk screen"
    fi
  else
    record_warning "could not launch AppManager — start the kiosk manually with run.sh"
  fi
}

main() {
  set_stage "loading configuration"
  protect_env_file
  load_env
  set_stage "checking for root privileges"
  require_root
  set_stage "scrubbing cloned-golden identity"
  scrub_clone_identity

  echo "=============================================================="
  echo "Device Bootstrap Started"
  echo "Date: $(date)"
  echo "Host: $(hostname)"
  echo "SSH user target: $SSH_LOGIN_USER"
  echo "Log: $LOGFILE"
  echo "=============================================================="
  log "Config summary:"
  log "STRAPI_BASE_URL=$STRAPI_BASE_URL"
  log "STRAPI_IDENTIFIER=$STRAPI_IDENTIFIER"
  log "MACHINE_TYPE=$MACHINE_TYPE"
  log "MACHINE_STATUS=$MACHINE_STATUS"
  log "MACHINE_SERIAL_NUMBER present: $([ -n "$MACHINE_SERIAL_NUMBER" ] && echo yes || echo no)"
  log "MACHINE_NICKNAME present: $([ -n "$MACHINE_NICKNAME" ] && echo yes || echo no)"
  log "SSH_AUTH_MODE=$SSH_AUTH_MODE"
  log "Linux password changes: disabled"
  log "ENABLE_TAILSCALE_SSH=$ENABLE_TAILSCALE_SSH"
  log "RESET_TAILSCALE_STATE=$RESET_TAILSCALE_STATE"
  log "TAILSCALE_AUTHKEY present: $([ -n "$TAILSCALE_AUTHKEY" ] && echo yes || echo no)"
  log "STRAPI_PASSWORD present: $([ -n "$STRAPI_PASSWORD" ] && echo yes || echo no)"
  log "MANAGE_ORG_ID=$MANAGE_ORG_ID"
  log "MANAGE_USERNAME=$MANAGE_USERNAME"
  log "MANAGE_PASSWORD present: $([ -n "$MANAGE_PASSWORD" ] && echo yes || echo no)"

  set_stage "waiting for the network"
  wait_for_online
  set_stage "asking the operator for serial / nickname / machine type"
  local serial_number
  serial_number="$(prompt_for_serial_number)"
  BOOTSTRAP_SERIAL="$serial_number"
  local nickname
  nickname="$(prompt_for_nickname)"
  MACHINE_NICKNAME="${MACHINE_NICKNAME:-$nickname}"
  local machine_type_id
  machine_type_id="$(prompt_for_machine_type_id)"

  set_stage "loading shared credentials from Strapi"
  load_creds_from_strapi || record_warning "could not load creds from Strapi cred entity — falling back to any locally-provided TAILSCALE_AUTHKEY/ANYDESK_PASSWORD"

  set_stage "installing base packages"
  install_base_packages
  set_stage "disabling unattended upgrades"
  disable_auto_updates
  set_stage "installing freeze protection (c-state + watchdog)"
  install_freeze_protection
  set_stage "configuring SSH"
  configure_ssh
  install_ops_ssh_key
  # Non-fatal on purpose: a remote-access step that fails must not abort provisioning before
  # Tailscale, telemetry registration, fleet.json and the readiness gate have run.
  set_stage "installing AnyDesk"
  reinstall_anydesk || record_warning "AnyDesk setup failed — continuing bootstrap without it"
  set_stage "installing RustDesk"
  reinstall_rustdesk || log "RustDesk setup failed — non-critical, continuing bootstrap without it"
  set_stage "configuring Tailscale"
  configure_tailscale

  local anydesk_id rustdesk_id tailscale_ip tailscale_hostname now_iso machine_id reg_code machine_key machine_secret telemetry_machine_id redeem_output
  machine_secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  anydesk_id="$(get_anydesk_id)"
  if [ -z "$anydesk_id" ]; then
    record_warning "AnyDesk ID is unavailable from anydesk --get-id"
  fi
  rustdesk_id="$(get_rustdesk_id)"
  if [ -z "$rustdesk_id" ]; then
    log "WARNING: RustDesk ID is unavailable from rustdesk --get-id (non-critical)"
  fi
  tailscale_ip="$(get_tailscale_ip)"
  if [ -z "$tailscale_ip" ]; then
    record_warning "Tailscale IPv4 address is unavailable — Tailscale may not be connected"
  fi
  tailscale_hostname="$(get_tailscale_hostname)"
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  set_stage "registering the machine in telemetry (manage.ishakerusa.com org $MANAGE_ORG_ID)"
  reg_code="$(fetch_reg_code || true)"
  machine_key=""
  telemetry_machine_id=""
  redeem_output="$(register_telemetry_with_retry "$serial_number" "$machine_type_id" || true)"
  if [ -n "$redeem_output" ]; then
    # register_telemetry_with_retry() may have burned the originally-entered serial and settled on
    # a suffixed one instead — everything from here on (Strapi record, on-device MachineSerial,
    # credentials file) MUST use the serial that's actually confirmed registered, not the one the
    # operator typed in.
    serial_number="$(printf '%s\n' "$redeem_output" | sed -n '1p')"
    machine_key="$(printf '%s\n' "$redeem_output" | sed -n '2p')"
    telemetry_machine_id="$(printf '%s\n' "$redeem_output" | sed -n '3p')"
    log "Telemetry-confirmed serial_number: $serial_number"
    apply_telemetry_credentials "$machine_key" "$telemetry_machine_id" "$MANAGE_ORG_ID"
    # Registration mints a Keycloak client id == serial_number; point ShakerView's client_id
    # (hard_settings.MachineSerial) at it, then prove the pair actually authenticates.
    apply_hard_settings_serial "$serial_number"
    verify_telemetry_auth "$serial_number" "$machine_key" || true
  fi
  set_stage "creating the Strapi machine record"
  BOOTSTRAP_SERIAL="$serial_number"
  # Carry whatever went wrong so far into the record, so a machine that limped through
  # provisioning is visibly flagged instead of looking identical to a clean one.
  if [ "${#SETUP_WARNINGS[@]}" -gt 0 ]; then
    ADMIN_COMMENT="bootstrap completed with ${#SETUP_WARNINGS[@]} warning(s):$(printf '\n  - %s' "${SETUP_WARNINGS[@]}")"
  else
    ADMIN_COMMENT=""
  fi
  machine_id="$(ADMIN_COMMENT="$ADMIN_COMMENT" register_machine_in_strapi "$serial_number" "$anydesk_id" "$tailscale_ip" "$machine_type_id" "$rustdesk_id" "$tailscale_hostname" "$(hostname)" "$reg_code" "$machine_key" "$machine_secret" "$nickname")"
  STRAPI_MACHINE_ID="$machine_id"

  # Unconditional and AFTER registration: the secret in this file is only valid once the
  # server has stored it, and the file must be written even when telemetry registration
  # failed — the catalog path does not depend on telemetry at all.
  if [ -n "$machine_id" ]; then
    write_fleet_json "$machine_secret" "$serial_number"
  else
    record_warning "Strapi registration produced no machine id — fleet.json NOT written (its secret would not authenticate)"
  fi

  write_credentials_file "$machine_id" "$serial_number" "$anydesk_id" "$tailscale_ip" "$tailscale_hostname" "$rustdesk_id" "$reg_code" "$machine_secret"
  if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    chown "$SUDO_USER:$SUDO_USER" "$LOGFILE" || true
  fi

  # Last, and blocking: provisioning is not "done" until something has verified the result
  # as a whole. Runs after every write above so it sees the machine exactly as it will ship.
  set_stage "running the readiness gate"
  run_readiness_gate

  echo
  echo "=============================================================="
  if [ "$READINESS_VERDICT" = "SHIP" ] && [ "${#SETUP_WARNINGS[@]}" -eq 0 ]; then
    echo "BOOTSTRAP SUCCEEDED — READY TO SHIP"
  elif [ "$READINESS_VERDICT" = "DO_NOT_SHIP" ]; then
    echo "BOOTSTRAP FINISHED — MACHINE IS NOT SHIPPABLE (readiness gate failed)"
  else
    echo "BOOTSTRAP COMPLETED WITH ERRORS (${#SETUP_WARNINGS[@]}) — readiness: $READINESS_VERDICT"
  fi
  echo "=============================================================="
  echo "Strapi machine id : $machine_id"
  echo "Serial number     : $serial_number"
  echo "Hostname          : $(hostname)"
  echo "AnyDesk ID        : ${anydesk_id:-unavailable}"
  echo "RustDesk ID       : ${rustdesk_id:-unavailable}"
  echo "Tailscale IPv4    : ${tailscale_ip:-unavailable}"
  echo "Tailscale hostname: ${tailscale_hostname:-unavailable}"
  echo "SSH user          : $SSH_LOGIN_USER"
  echo "SSH port          : $SSH_PORT"
  echo "Telemetry REG code: ${reg_code:-unavailable}"
  if [ -n "$machine_key" ] && [ "${TELEMETRY_AUTH_VERIFIED:-0}" = "1" ]; then
    echo "Telemetry status  : fully registered AND VERIFIED (client_id=$serial_number authenticates in machine-realm)"
  elif [ -n "$machine_key" ]; then
    echo "Telemetry status  : MachineKey obtained but auth verification FAILED — ShakerView will 401; check MachineSerial/key (see warnings above)"
  elif [ -n "$reg_code" ]; then
    echo "Telemetry status  : REG code fetched, but automatic redemption failed — on-device entry still required"
  else
    echo "Telemetry status  : not registered — fetch REG code manually from manage.ishakerusa.com"
  fi
  echo "Log file          : $LOGFILE"
  echo "Readiness verdict : $READINESS_VERDICT${READINESS_REPORT:+  (report: $READINESS_REPORT)}"
  if [ "$CSTATE_REBOOT_REQUIRED" = "1" ]; then
    echo
    echo "ACTION REQUIRED: this is a Bay Trail CPU and the c-state clamp was just written to GRUB."
    echo "                 It is INERT until you reboot. Freeze prevention starts after: sudo reboot"
  fi
  if [ -n "$reg_code" ] && [ -z "$machine_key" ]; then
    echo
    echo "Remaining manual step: enter '$reg_code' on-device via Service Menu > Telemetry > Activation key, then restart ShakerView."
  fi

  # Deliberately after the summary, so the operator gets to read it before ShakerView takes the
  # screen — but before the exit below, which would otherwise skip the kiosk on any warning.
  start_kiosk_app

  # The run reached its own summary: `exit 2` below is "finished with warnings", not a crash,
  # and must not make the EXIT trap print the BOOTSTRAP FAILED block on top of it.
  FINISHED_CLEANLY=1

  if [ "${#SETUP_WARNINGS[@]}" -gt 0 ]; then
    echo
    echo "Errors encountered during setup:"
    local w
    for w in "${SETUP_WARNINGS[@]}"; do
      echo "  - $w"
    done
    exit 2
  fi
}

main "$@"
