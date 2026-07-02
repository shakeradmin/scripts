#!/bin/bash

set -uo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo: sudo ./rmSSH.sh"
  exit 1
fi

echo "Logging out of Tailscale and wiping local identity state..."

tailscale logout >/dev/null 2>&1 || true
systemctl stop tailscaled || true
rm -f /var/lib/tailscale/tailscaled.state /var/lib/tailscale/tailscaled.state.conf

echo "Done. Tailscale identity removed — this machine will not be reachable over Tailscale/SSH until re-authenticated (e.g. via bootstrap.sh)."
