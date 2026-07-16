#!/usr/bin/env bash
# FleetPulse sweep: heartbeat + product-media delivery + cell sync for every Strapi
# machine carrying the FleetCatalog patch (patch id >= 4). Replaces cell_sync_cron.sh.
export STRAPI_BASE_URL=http://localhost:1338
LOG=/home/ishaker/fleetpulse/fleetpulse.log
mkdir -p /home/ishaker/fleetpulse
exec 9>/tmp/fleetpulse.lock; flock -n 9 || exit 0
python3 /home/ishaker/Desktop/scripts/fleetpulse.py 2>&1 | grep -v '^IDLE ' \
  | while IFS= read -r l; do [ -n "$l" ] && echo "[$(date '+%F %T')] $l"; done >> "$LOG"
exit 0
