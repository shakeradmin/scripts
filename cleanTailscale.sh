#!/bin/bash

set -euo pipefail

log() {
  echo "[$(date '+%F %T')] $1"
}

if [ "${EUID}" -ne 0 ]; then
  log "ERROR: run this script with sudo or as root"
  exit 1
fi

if command -v tailscale >/dev/null 2>&1; then
  log "Logging out of Tailscale on the golden image"
  tailscale logout || true
  systemctl stop tailscaled || true
  rm -f /var/lib/tailscale/tailscaled.state /var/lib/tailscale/tailscaled.state.conf
fi

log "Removing any baked-in SSH host keys"
rm -f /etc/ssh/ssh_host_*

log "Golden image state is cleaned. Run setupTailscaleSsh.sh on each clone."
