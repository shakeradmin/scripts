#!/bin/bash

set -uo pipefail

PASSWORD="25410201ubuntu"
LOGFILE="$HOME/anydesk_reinstall_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "=============================================================="
echo "AnyDesk Full Reinstall Started"
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

log "Stopping AnyDesk service..."
sudo systemctl stop anydesk 2>/dev/null || true

log "Disabling AnyDesk service..."
sudo systemctl disable anydesk 2>/dev/null || true

log "Removing AnyDesk package..."
sudo apt-get purge -y anydesk || true

log "Removing unused packages..."
sudo apt-get autoremove -y || true

log "Removing AnyDesk configuration..."
sudo rm -rf /etc/anydesk
sudo rm -rf /var/lib/anydesk
sudo rm -rf /var/log/anydesk

log "Removing user configuration..."
sudo rm -rf "$HOME/.anydesk"

log "Removing old repository configuration..."
sudo rm -f /etc/apt/sources.list.d/anydesk.list
sudo rm -f /etc/apt/keyrings/anydesk.gpg

##############################################################################

# INSTALL REQUIREMENTS

##############################################################################

log "Updating package index..."
sudo apt-get update

log "Installing prerequisites..."
sudo apt-get install -y curl gnupg ca-certificates

log "Creating keyring directory..."
sudo mkdir -p /etc/apt/keyrings

##############################################################################

# ADD ANYDESK REPOSITORY

##############################################################################

log "Downloading AnyDesk GPG key..."

curl -fsSL https://keys.anydesk.com/repos/DEB-GPG-KEY | 
sudo gpg --dearmor -o /etc/apt/keyrings/anydesk.gpg

log "Adding AnyDesk repository..."

echo "deb [signed-by=/etc/apt/keyrings/anydesk.gpg] http://deb.anydesk.com/ all main" | 
sudo tee /etc/apt/sources.list.d/anydesk.list >/dev/null

##############################################################################

# INSTALL ANYDESK

##############################################################################

log "Refreshing package lists..."
sudo apt-get update

log "Installing AnyDesk..."
sudo apt-get install -y anydesk

##############################################################################

# START SERVICE

##############################################################################

log "Reloading systemd..."
sudo systemctl daemon-reload

log "Enabling service..."
sudo systemctl enable anydesk

log "Starting service..."
sudo systemctl restart anydesk

log "Waiting for startup..."
sleep 15

SERVICE_STATUS=$(sudo systemctl is-active anydesk 2>/dev/null || echo inactive)

echo
echo "Service Status: $SERVICE_STATUS"
echo

if [ "$SERVICE_STATUS" != "active" ]; then
log "WARNING: AnyDesk service is not active."

echo
echo "===== SERVICE STATUS ====="
sudo systemctl status anydesk --no-pager || true

echo
echo "===== JOURNAL LOGS ====="
journalctl -u anydesk -n 50 --no-pager || true
echo

fi

##############################################################################

# PASSWORD CONFIGURATION

##############################################################################

if [ "$SERVICE_STATUS" = "active" ]; then
log "Setting unattended-access password..."

echo "$PASSWORD" | sudo anydesk --set-password || \
log "WARNING: Password command returned an error."

fi

##############################################################################

# GET ID (NON-FATAL)

##############################################################################

ANYDESK_ID=""

log "Attempting ID retrieval..."

ANYDESK_ID=$(anydesk --get-id 2>/dev/null || true)

##############################################################################

# SUMMARY

##############################################################################

echo
echo "=============================================================="
echo "INSTALLATION SUMMARY"
echo "=============================================================="
echo "Service Status : $SERVICE_STATUS"
echo "Password       : $PASSWORD"

if [ -n "$ANYDESK_ID" ]; then
echo "AnyDesk ID     : $ANYDESK_ID"
else
echo "AnyDesk ID     : CLI retrieval failed"
fi

echo "Log File       : $LOGFILE"
echo "=============================================================="

echo
echo "If the ID is missing, run:"
echo
echo "    anydesk"
echo
echo "or"
echo
echo "    sudo systemctl status anydesk"
echo

