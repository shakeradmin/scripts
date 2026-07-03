#!/bin/bash

set -uo pipefail

PASSWORD="25410201ubuntu"
LOGFILE="$HOME/rustdesk_reinstall_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "=============================================================="
echo "RustDesk Full Reinstall Started"
echo "Date: $(date)"
echo "Host: $(hostname)"
echo "User: $(whoami)"
echo "Log : $LOGFILE"
echo "=============================================================="

log() {
echo "[$(date '+%F %T')] $1"
}

##############################################################################

# REMOVE OLD INSTALLATION

##############################################################################

log "Stopping RustDesk service..."
sudo systemctl stop rustdesk 2>/dev/null || true

log "Disabling RustDesk service..."
sudo systemctl disable rustdesk 2>/dev/null || true

log "Removing RustDesk package..."
sudo apt-get purge -y rustdesk 2>/dev/null || true

log "Removing unused packages..."
sudo apt-get autoremove -y || true

log "Removing RustDesk configuration..."
sudo rm -rf /etc/rustdesk
sudo rm -rf /usr/share/rustdesk
sudo rm -rf /var/log/rustdesk

log "Removing user configuration..."
rm -rf "$HOME/.config/rustdesk"

log "Removing leftover install artifacts..."
rm -f /tmp/rustdesk-install.deb

##############################################################################

# INSTALL REQUIREMENTS

##############################################################################

log "Updating package index..."
sudo apt-get update

log "Installing prerequisites..."
sudo apt-get install -y curl ca-certificates python3

##############################################################################

# DOWNLOAD LATEST RUSTDESK PACKAGE

##############################################################################

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) RD_ARCH="x86_64" ;;
  arm64) RD_ARCH="aarch64" ;;
  armhf) RD_ARCH="armv7" ;;
  *) RD_ARCH="x86_64" ;;
esac

log "Fetching latest RustDesk release metadata (arch: $RD_ARCH)..."

DEB_URL="$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest |
  RD_ARCH="$RD_ARCH" python3 -c '
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
')"

if [ -z "$DEB_URL" ]; then
  log "ERROR: could not determine RustDesk .deb download URL"
  exit 1
fi

log "Downloading RustDesk package from: $DEB_URL"
if ! curl -fsSL "$DEB_URL" -o /tmp/rustdesk-install.deb; then
  log "ERROR: failed to download RustDesk package"
  exit 1
fi

##############################################################################

# INSTALL RUSTDESK

##############################################################################

log "Installing RustDesk..."
sudo apt-get install -y /tmp/rustdesk-install.deb

##############################################################################

# START SERVICE

##############################################################################

log "Reloading systemd..."
sudo systemctl daemon-reload

log "Enabling service..."
sudo systemctl enable rustdesk 2>/dev/null || true

log "Starting service..."
sudo systemctl restart rustdesk 2>/dev/null || true

log "Waiting for startup..."
sleep 10

SERVICE_STATUS=$(sudo systemctl is-active rustdesk 2>/dev/null || echo inactive)

echo
echo "Service Status: $SERVICE_STATUS"
echo

if [ "$SERVICE_STATUS" != "active" ]; then
log "WARNING: RustDesk service is not active (this can be normal on older RustDesk builds without a system service — the app may still work under the desktop session)."

echo
echo "===== SERVICE STATUS ====="
sudo systemctl status rustdesk --no-pager || true

echo
echo "===== JOURNAL LOGS ====="
journalctl -u rustdesk -n 50 --no-pager || true
echo

fi

##############################################################################

# PASSWORD CONFIGURATION

##############################################################################

log "Setting unattended-access password..."

PASSWORD_SET=0
DELAY=5
for attempt in 1 2 3 4 5; do
  if sudo rustdesk --password "$PASSWORD" 2>/dev/null; then
    log "Password set successfully (attempt $attempt)"
    PASSWORD_SET=1
    break
  fi
  log "Password attempt $attempt failed; retrying in ${DELAY}s"
  sleep "$DELAY"
  DELAY=$((DELAY * 2))
done

if [ "$PASSWORD_SET" -ne 1 ]; then
  log "WARNING: Password command failed after 5 attempts."
fi

##############################################################################

# GET ID (NON-FATAL)

##############################################################################

RUSTDESK_ID=""

log "Attempting ID retrieval..."

RUSTDESK_ID=$(rustdesk --get-id 2>/dev/null | tr -d '[:space:]' || true)

##############################################################################

# SUMMARY

##############################################################################

echo
echo "=============================================================="
echo "INSTALLATION SUMMARY"
echo "=============================================================="
echo "Service Status : $SERVICE_STATUS"
echo "Password       : $PASSWORD"

if [ -n "$RUSTDESK_ID" ]; then
echo "RustDesk ID    : $RUSTDESK_ID"
else
echo "RustDesk ID    : CLI retrieval failed"
fi

echo "Log File       : $LOGFILE"
echo "=============================================================="

echo
echo "If the ID is missing, run:"
echo
echo "    rustdesk --get-id"
echo
echo "or"
echo
echo "    sudo systemctl status rustdesk"
echo
