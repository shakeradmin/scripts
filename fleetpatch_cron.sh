#!/usr/bin/env bash
# FleetPatch sweep: install stable patches on machines that opted in (isAutoupdate).
#
# Resting state is "no stable patches — nothing to roll out": with every patch at
# isStable=false this does nothing at all. Flipping one patch to isStable=true is the
# release action, and this picks it up within one interval.
#
# --max 2 per run on purpose: the first wave is a canary. A failure aborts the whole run
# (fleetpatch rolls that machine back), so a bad patch cannot walk the fleet between ticks.
# Re-runs continue the rollout two machines at a time.
export STRAPI_BASE_URL=http://localhost:1338
LOG=/home/ishaker/fleetpatch/fleetpatch-cron.log
mkdir -p /home/ishaker/fleetpatch

# Never overlap: an install restarts a kiosk and waits ~2 min to verify it. A second run
# stepping into that would read a half-restarted app as a failed patch and roll it back.
exec 9>/tmp/fleetpatch.lock; flock -n 9 || exit 0

python3 /home/ishaker/Desktop/scripts/fleetpatch.py --max 2 2>&1 \
  | grep -vE "no stable patches|no machines with isAutoupdate" \
  | while IFS= read -r l; do [ -n "$l" ] && echo "$l"; done >> "$LOG"
exit 0
