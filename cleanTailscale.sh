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

log "Regenerating SSH host keys"
ssh-keygen -A

log "Ensuring PermitRootLogin and PubkeyAuthentication are enabled"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

log "Restarting SSH daemon"
if systemctl is-active --quiet sshd 2>/dev/null; then
  systemctl restart sshd
elif systemctl is-active --quiet ssh 2>/dev/null; then
  systemctl restart ssh
else
  systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
fi

log "Starting Tailscale and bringing it up with SSH enabled"
systemctl start tailscaled
sleep 2
tailscale up --ssh --accept-routes --accept-dns=true

log "Done. Tailscale is up and SSH is ready for connections."
