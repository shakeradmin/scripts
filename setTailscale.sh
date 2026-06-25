#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
TS_HOSTNAME="${TS_HOSTNAME:-}"
ALLOW_INTERACTIVE_TAILSCALE_LOGIN="${ALLOW_INTERACTIVE_TAILSCALE_LOGIN:-false}"
ENABLE_TAILSCALE_SSH="${ENABLE_TAILSCALE_SSH:-true}"
SSH_LOGIN_USER="${SSH_LOGIN_USER:-}"
SSH_AUTH_MODE="${SSH_AUTH_MODE:-password}"
REINSTALL_OPENSSH_SERVER="${REINSTALL_OPENSSH_SERVER:-false}"
ROTATE_USER_SSH_KEY="${ROTATE_USER_SSH_KEY:-false}"
RESET_AUTHORIZED_KEYS="${RESET_AUTHORIZED_KEYS:-false}"
USER_SSH_KEY_NAME="${USER_SSH_KEY_NAME:-id_ed25519}"

log() {
  echo "[$(date '+%F %T')] $1"
}

load_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    log "ERROR: run this script with sudo or as root"
    exit 1
  fi
}

require_tailscale_login_mode() {
  if [ -n "$TS_AUTHKEY" ]; then
    return
  fi

  if [ "$ALLOW_INTERACTIVE_TAILSCALE_LOGIN" = "true" ]; then
    log "WARNING: TS_AUTHKEY is empty; falling back to interactive Tailscale login"
    return
  fi

  log "ERROR: TS_AUTHKEY is required for clone automation"
  log "Set TS_AUTHKEY to a Tailscale auth key or set ALLOW_INTERACTIVE_TAILSCALE_LOGIN=true"
  exit 1
}

wait_for_apt_lock() {
  local max_wait=120
  local waited=0
  while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend 2>/dev/null; do
    if [ "$waited" -eq 0 ]; then
      log "Waiting for other apt/dpkg processes to finish..."
    fi
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$max_wait" ]; then
      log "Apt lock still held after ${max_wait}s — killing blocking processes"
      for proc in apt-get apt aptd dpkg unattended-upgr; do
        pkill -9 "$proc" 2>/dev/null || true
      done
      sleep 2
      rm -f /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend
      dpkg --configure -a 2>/dev/null || true
      break
    fi
  done
}

apt_install() {
  wait_for_apt_lock
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_ubuntu_repos() {
  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-jammy}")"

  if grep -qE "^deb .*(archive|security)\.ubuntu\.com" /etc/apt/sources.list 2>/dev/null; then
    log "Standard Ubuntu repos already present"
    return
  fi

  log "Standard Ubuntu repos missing — adding for $codename"
  cat >> /etc/apt/sources.list <<EOF

# Added by setTailscale.sh
deb http://archive.ubuntu.com/ubuntu ${codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse
EOF
}

update_apt() {
  wait_for_apt_lock
  log "Updating package lists"
  apt-get update
}

reinstall_openssh_server() {
  log "Reinstalling openssh-server from scratch"
  wait_for_apt_lock
  DEBIAN_FRONTEND=noninteractive apt-get purge -y openssh-server openssh-sftp-server || true
  apt_install openssh-server
}

install_openssh_server() {
  if [ "$REINSTALL_OPENSSH_SERVER" = "true" ]; then
    reinstall_openssh_server
    return
  fi

  if dpkg -s openssh-server >/dev/null 2>&1; then
    log "openssh-server is already installed"
    return
  fi

  log "Installing openssh-server"
  apt_install openssh-server
}

rotate_ssh_host_keys() {
  log "Removing existing SSH host keys"
  rm -f /etc/ssh/ssh_host_*

  log "Generating fresh SSH host keys"
  ssh-keygen -A
}

configure_sshd() {
  local password_auth kbd_interactive_auth

  case "$SSH_AUTH_MODE" in
    key-only)
      password_auth="no"
      kbd_interactive_auth="no"
      ;;
    password)
      password_auth="yes"
      kbd_interactive_auth="yes"
      ;;
    both)
      password_auth="yes"
      kbd_interactive_auth="yes"
      ;;
    *)
      log "ERROR: SSH_AUTH_MODE must be one of: key-only, password, both"
      exit 1
      ;;
  esac

  mkdir -p /etc/ssh/sshd_config.d

  cat >/etc/ssh/sshd_config.d/10-tailscale-hardening.conf <<EOF
PasswordAuthentication $password_auth
KbdInteractiveAuthentication $kbd_interactive_auth
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
EOF

  log "Enabling and restarting SSH service"
  systemctl enable ssh
  systemctl restart ssh
}

rotate_user_ssh_key() {
  local user_name="$1"
  local home_dir
  home_dir="$(getent passwd "$user_name" | cut -d: -f6)"

  if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
    log "ERROR: home directory for user $user_name was not found"
    exit 1
  fi

  log "Rotating user SSH key for $user_name"
  install -d -m 700 -o "$user_name" -g "$user_name" "$home_dir/.ssh"
  if [ "$RESET_AUTHORIZED_KEYS" = "true" ]; then
    log "Resetting authorized_keys for $user_name"
    rm -f "$home_dir/.ssh/authorized_keys"
  fi
  rm -f "$home_dir/.ssh/$USER_SSH_KEY_NAME" "$home_dir/.ssh/$USER_SSH_KEY_NAME.pub"
  runuser -u "$user_name" -- ssh-keygen -t ed25519 -f "$home_dir/.ssh/$USER_SSH_KEY_NAME" -N "" -C "$user_name@$(hostname)-$(date +%F)"
}

install_tailscale() {
  local os_codename

  if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale is already installed"
    return
  fi

  os_codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-jammy}")"

  log "Installing Tailscale"
  apt_install curl ca-certificates gnupg
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${os_codename}.noarmor.gpg" >/usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${os_codename}.tailscale-keyring.list" >/etc/apt/sources.list.d/tailscale.list
  wait_for_apt_lock
  apt-get update
  apt_install tailscale
}

reset_tailscale_state() {
  log "Stopping tailscaled before resetting local state"
  systemctl stop tailscaled || true
  rm -f /var/lib/tailscale/tailscaled.state /var/lib/tailscale/tailscaled.state.conf
  install -d -m 0755 /var/lib/tailscale
}

bring_up_tailscale() {
  local up_args=()

  if [ "${ENABLE_TAILSCALE_SSH}" = "true" ]; then
    up_args+=(--ssh)
  fi

  if [ -n "$TS_AUTHKEY" ]; then
    up_args+=(--authkey="$TS_AUTHKEY")
  fi

  if [ -n "$TS_HOSTNAME" ]; then
    up_args+=(--hostname="$TS_HOSTNAME")
  fi

  if [ -n "$TS_EXTRA_ARGS" ]; then
    # shellcheck disable=SC2206
    up_args+=($TS_EXTRA_ARGS)
  fi

  log "Enabling and starting tailscaled"
  systemctl enable tailscaled
  systemctl restart tailscaled

  if [ -n "$TS_AUTHKEY" ]; then
    log "Bringing Tailscale online with supplied auth key"
  else
    log "Bringing Tailscale online with interactive login"
  fi

  tailscale up "${up_args[@]}"
}

print_summary() {
  local tailscale_ip dns_name
  tailscale_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  dns_name="$(tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName": "\(.*\)",/\1/p' | head -n1 || true)"

  echo
  log "Setup complete"
  echo "SSH auth mode : $SSH_AUTH_MODE"
  if [ -n "$tailscale_ip" ]; then
    echo "Tailscale IPv4: $tailscale_ip"
  fi
  if [ -n "$dns_name" ]; then
    echo "MagicDNS name : ${dns_name%.}"
  fi
  if [ -n "$SSH_LOGIN_USER" ]; then
    echo "SSH command   : ssh $SSH_LOGIN_USER@${dns_name%.}"
  fi
}

main() {
  load_env
  require_root
  require_tailscale_login_mode
  ensure_ubuntu_repos
  update_apt
  install_openssh_server
  rotate_ssh_host_keys
  configure_sshd
  if [ "$ROTATE_USER_SSH_KEY" = "true" ] && [ -n "$SSH_LOGIN_USER" ]; then
    rotate_user_ssh_key "$SSH_LOGIN_USER"
  fi
  install_tailscale
  reset_tailscale_state
  bring_up_tailscale
  print_summary
}

main "$@"
