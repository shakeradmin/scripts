#!/bin/bash

LOGFILE="$HOME/rustdesk_removal_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "========================================"
echo "RustDesk Removal Started"
echo "Date: $(date)"
echo "Log: $LOGFILE"
echo "========================================"

echo "[1/5] Stopping RustDesk service..."
sudo systemctl stop rustdesk 2>/dev/null || true

echo "[2/5] Removing RustDesk package..."
sudo apt remove --purge rustdesk -y 2>/dev/null || true

echo "[3/5] Removing unused dependencies..."
sudo apt autoremove -y

echo "[4/5] Removing system configuration..."
sudo rm -rf /etc/rustdesk /usr/share/rustdesk /var/log/rustdesk

echo "[5/5] Removing user configuration..."
rm -rf "$HOME/.config/rustdesk"

echo
echo "========================================"
echo "RustDesk removal completed successfully"
echo "Date: $(date)"
echo "Log saved to: $LOGFILE"
echo "========================================"
