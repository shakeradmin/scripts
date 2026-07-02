#!/bin/bash

LOGFILE="$HOME/anydesk_removal_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "========================================"
echo "AnyDesk Removal Started"
echo "Date: $(date)"
echo "Log: $LOGFILE"
echo "========================================"

echo "[1/5] Stopping AnyDesk service..."
sudo systemctl stop anydesk 2>/dev/null || true

echo "[2/5] Removing AnyDesk package..."
sudo apt remove --purge anydesk -y

echo "[3/5] Removing unused dependencies..."
sudo apt autoremove -y

echo "[4/5] Removing system configuration..."
sudo rm -rf /etc/anydesk

echo "[5/5] Removing user configuration..."
rm -rf "$HOME/.anydesk"

echo
echo "========================================"
echo "AnyDesk removal completed successfully"
echo "Date: $(date)"
echo "Log saved to: $LOGFILE"
echo "========================================"
