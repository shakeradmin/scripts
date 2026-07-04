#!/bin/bash

set -Eeuo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_OWNER_USER="${SUDO_USER:-$(id -un)}"
LOG_OWNER_HOME="$(getent passwd "$LOG_OWNER_USER" | cut -d: -f6)"
LOGFILE="${LOG_OWNER_HOME:-$HOME}/bootstrap_device_$(date +%Y%m%d_%H%M%S).log"

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
UNITY_VERSION="${UNITY_VERSION:-}"
SSD_VERSION="${SSD_VERSION:-}"
BOOTSTRAP_VERSION="${BOOTSTRAP_VERSION:-0.1.0}"
MANAGE_API_BASE="${MANAGE_API_BASE:-https://manage.ishakerusa.com}"
MANAGE_KEYCLOAK_TOKEN_URL="${MANAGE_KEYCLOAK_TOKEN_URL:-https://kk.ishakerusa.com/realms/shaker-realm/protocol/openid-connect/token}"
MANAGE_CLIENT_ID="${MANAGE_CLIENT_ID:-shaker-client}"
MANAGE_USERNAME="${MANAGE_USERNAME:-root}"
MANAGE_PASSWORD="${MANAGE_PASSWORD:-}"
MANAGE_ORG_ID="${MANAGE_ORG_ID:-1}"

STRAPI_PASSWORD_FILE="$(mktemp /tmp/.bootstrap_strapi_pw.XXXXXX)"
chmod 600 "$STRAPI_PASSWORD_FILE"
cleanup_strapi_password_file() {
  rm -f "$STRAPI_PASSWORD_FILE"
}
trap cleanup_strapi_password_file EXIT

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

on_error() {
  local line_no="$1"
  local command="$2"
  local exit_code="$3"

  log "ERROR: bootstrap failed"
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
  UNITY_VERSION="${UNITY_VERSION:-}"
  SSD_VERSION="${SSD_VERSION:-}"
  BOOTSTRAP_VERSION="${BOOTSTRAP_VERSION:-0.1.0}"
  MANAGE_API_BASE="${MANAGE_API_BASE:-https://manage.ishakerusa.com}"
  MANAGE_KEYCLOAK_TOKEN_URL="${MANAGE_KEYCLOAK_TOKEN_URL:-https://kk.ishakerusa.com/realms/shaker-realm/protocol/openid-connect/token}"
  MANAGE_CLIENT_ID="${MANAGE_CLIENT_ID:-shaker-client}"
  MANAGE_USERNAME="${MANAGE_USERNAME:-root}"
  MANAGE_PASSWORD="${MANAGE_PASSWORD:-}"
  MANAGE_ORG_ID="${MANAGE_ORG_ID:-1}"
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

prompt_for_serial_number() {
  local serial=""

  if [ -n "$MACHINE_SERIAL_NUMBER" ]; then
    log "Using MACHINE_SERIAL_NUMBER from environment"
    printf "%s" "$MACHINE_SERIAL_NUMBER"
    return
  fi

  while [ -z "$serial" ]; do
    serial="$(read_tty "Enter machine serial_number: " | xargs)"
  done

  printf "%s" "$serial"
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
  if ! curl -fsSL https://keys.anydesk.com/repos/DEB-GPG-KEY | gpg --dearmor -o /etc/apt/keyrings/anydesk.gpg; then
    log "ERROR: failed to download or install AnyDesk repository key"
    return 1
  fi
  echo "deb [signed-by=/etc/apt/keyrings/anydesk.gpg] http://deb.anydesk.com/ all main" >/etc/apt/sources.list.d/anydesk.list

  log "Installing AnyDesk"
  apt-get update || {
    log "ERROR: apt-get update failed after adding AnyDesk repository"
    sed -n '1,120p' /etc/apt/sources.list.d/anydesk.list 2>/dev/null || true
    return 1
  }
  apt_install anydesk || {
    log "ERROR: AnyDesk package installation failed"
    apt-cache policy anydesk 2>/dev/null || true
    return 1
  }

  systemctl daemon-reload
  systemctl enable anydesk
  if ! systemctl restart anydesk; then
    log "ERROR: failed to restart AnyDesk"
    systemctl status anydesk --no-pager || true
    journalctl -u anydesk -n 100 --no-pager || true
    return 1
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

  record_warning "RustDesk password command failed after 5 attempts"
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
    RUSTDESK_PASSWORD="$(generate_password)"
    log "No RUSTDESK_PASSWORD available; generated a random one"
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
    status="$(curl -sS -o "$response_file" -w '%{http_code}' "$STRAPI_BASE_URL/api/auth/local" \
      -H 'Content-Type: application/json' \
      --data-binary "$auth_payload")"

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
      status="$(curl --globoff -sS -o "$response_file" -w '%{http_code}' -X "$method" "$url" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary "$payload")"
    else
      status="$(curl --globoff -sS -o "$response_file" -w '%{http_code}' -X "$method" "$url" \
        -H "Authorization: Bearer $token")"
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
  local token creds_json ts_key anydesk_password rustdesk_password

  log "Fetching TS_KEY/ANYDESK_PASSWORD/RUSTDESK_PASSWORD from Strapi cred entity"
  token="$(strapi_token)"
  creds_json="$(curl_json_logged GET "$STRAPI_BASE_URL/api/cred" "$token")" || {
    log "ERROR: failed to fetch Strapi cred entity"
    return 1
  }

  ts_key="$(echo "$creds_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((((d.get("data") or {}).get("attributes") or {}).get("creds") or {}).get("TS_KEY") or "")')"
  anydesk_password="$(echo "$creds_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((((d.get("data") or {}).get("attributes") or {}).get("creds") or {}).get("ANYDESK_PASSWORD") or "")')"
  rustdesk_password="$(echo "$creds_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((((d.get("data") or {}).get("attributes") or {}).get("creds") or {}).get("RUSTDESK_PASSWORD") or "")')"

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
  SSH_USER_VALUE="$SSH_LOGIN_USER" \
  SSH_PORT_VALUE="$SSH_PORT" \
  BOOTSTRAP_VERSION_VALUE="$BOOTSTRAP_VERSION" \
  UNITY_VERSION_VALUE="$UNITY_VERSION" \
  SSD_VERSION_VALUE="$SSD_VERSION" \
  python3 - <<'PY'
import json
import os


def env_or_none(key):
    return os.environ.get(key) or None


data = {
    "status": "new",
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
  local token payload response

  require_command python3

  token="$(strapi_token)"

  payload="$(json_payload "$serial_number" "$anydesk_id" "$tailscale_ip" "$machine_type_id" "$rustdesk_id" "$tailscale_hostname" "$hostname_value" "$reg_code" "$machine_key")"

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
  status="$(curl -sS -o "$response_file" -w '%{http_code}' "$MANAGE_KEYCLOAK_TOKEN_URL" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=$MANAGE_CLIENT_ID" \
    --data-urlencode "username=$MANAGE_USERNAME" \
    --data-urlencode "password=$MANAGE_PASSWORD")"

  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' <"$response_file"
    rm -f "$response_file"
    return 0
  fi

  log "ERROR: manage.ishakerusa.com auth failed with HTTP $status"
  rm -f "$response_file"
  return 1
}

fetch_reg_code() {
  log_section "Telemetry REG Code (org $MANAGE_ORG_ID)"
  local token response_file status code

  token="$(manage_token)" || {
    record_warning "Could not authenticate to manage.ishakerusa.com — skipping REG code fetch"
    return 1
  }

  response_file="$(mktemp)"
  status="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST \
    "$MANAGE_API_BASE/api/telemetry-machine-control/registration-code/create-or-get/$MANAGE_ORG_ID" \
    -H "Authorization: Bearer $token")"

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
  local model_name payload response_file status secret_key message

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
  status="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST \
    "$MANAGE_API_BASE/api/telemetry-machine-control/machine/registration/$reg_code" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload")"

  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    secret_key="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("secretKey") or "")' <"$response_file")"
    message="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("message") or "")' <"$response_file")"
    rm -f "$response_file"
    if [ -n "$secret_key" ]; then
      log "Telemetry MachineKey obtained automatically (no on-device REG entry needed)"
      printf "%s" "$secret_key"
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

write_credentials_file() {
  local machine_id="$1"
  local serial_number="$2"
  local anydesk_id="$3"
  local tailscale_ip="$4"
  local tailscale_hostname="$5"
  local rustdesk_id="$6"
  local reg_code="${7:-}"
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
    echo "Bootstrap log: $LOGFILE"
  } >"$credentials_file"

  chmod 600 "$credentials_file"
  if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    chown "$SUDO_USER:$SUDO_USER" "$credentials_file" || true
  fi
  log "Credentials saved to $credentials_file"
}

main() {
  protect_env_file
  load_env
  require_root

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
  log "SSH_AUTH_MODE=$SSH_AUTH_MODE"
  log "Linux password changes: disabled"
  log "ENABLE_TAILSCALE_SSH=$ENABLE_TAILSCALE_SSH"
  log "RESET_TAILSCALE_STATE=$RESET_TAILSCALE_STATE"
  log "TAILSCALE_AUTHKEY present: $([ -n "$TAILSCALE_AUTHKEY" ] && echo yes || echo no)"
  log "STRAPI_PASSWORD present: $([ -n "$STRAPI_PASSWORD" ] && echo yes || echo no)"
  log "MANAGE_ORG_ID=$MANAGE_ORG_ID"
  log "MANAGE_USERNAME=$MANAGE_USERNAME"
  log "MANAGE_PASSWORD present: $([ -n "$MANAGE_PASSWORD" ] && echo yes || echo no)"

  wait_for_online
  local serial_number
  serial_number="$(prompt_for_serial_number)"
  local machine_type_id
  machine_type_id="$(prompt_for_machine_type_id)"

  load_creds_from_strapi || record_warning "could not load creds from Strapi cred entity — falling back to any locally-provided TAILSCALE_AUTHKEY/ANYDESK_PASSWORD"

  install_base_packages
  configure_ssh
  reinstall_anydesk
  reinstall_rustdesk
  configure_tailscale

  local anydesk_id rustdesk_id tailscale_ip tailscale_hostname now_iso machine_id reg_code machine_key
  anydesk_id="$(get_anydesk_id)"
  if [ -z "$anydesk_id" ]; then
    record_warning "AnyDesk ID is unavailable from anydesk --get-id"
  fi
  rustdesk_id="$(get_rustdesk_id)"
  if [ -z "$rustdesk_id" ]; then
    record_warning "RustDesk ID is unavailable from rustdesk --get-id"
  fi
  tailscale_ip="$(get_tailscale_ip)"
  if [ -z "$tailscale_ip" ]; then
    record_warning "Tailscale IPv4 address is unavailable — Tailscale may not be connected"
  fi
  tailscale_hostname="$(get_tailscale_hostname)"
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  reg_code="$(fetch_reg_code || true)"
  machine_key=""
  if [ -n "$reg_code" ]; then
    machine_key="$(redeem_reg_code "$reg_code" "$serial_number" "$machine_type_id" || true)"
  fi
  machine_id="$(register_machine_in_strapi "$serial_number" "$anydesk_id" "$tailscale_ip" "$machine_type_id" "$rustdesk_id" "$tailscale_hostname" "$(hostname)" "$reg_code" "$machine_key")"

  write_credentials_file "$machine_id" "$serial_number" "$anydesk_id" "$tailscale_ip" "$tailscale_hostname" "$rustdesk_id" "$reg_code"
  if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    chown "$SUDO_USER:$SUDO_USER" "$LOGFILE" || true
  fi

  echo
  echo "=============================================================="
  if [ "${#SETUP_WARNINGS[@]}" -eq 0 ]; then
    echo "BOOTSTRAP SUCCEEDED"
  else
    echo "BOOTSTRAP COMPLETED WITH ERRORS (${#SETUP_WARNINGS[@]})"
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
  if [ -n "$machine_key" ]; then
    echo "Telemetry status  : fully registered automatically (MachineKey obtained, no on-device step needed)"
  elif [ -n "$reg_code" ]; then
    echo "Telemetry status  : REG code fetched, but automatic redemption failed — on-device entry still required"
  else
    echo "Telemetry status  : not registered — fetch REG code manually from manage.ishakerusa.com"
  fi
  echo "Log file          : $LOGFILE"
  if [ -n "$reg_code" ] && [ -z "$machine_key" ]; then
    echo
    echo "Remaining manual step: enter '$reg_code' on-device via Service Menu > Telemetry > Activation key, then restart ShakerView."
  fi

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
