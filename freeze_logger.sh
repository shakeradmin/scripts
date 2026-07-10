#!/usr/bin/env bash
# freeze_logger.sh — diagnose & capture ShakerView "freeze after a while" (memory-leak → OOM /
# self-fork duplicates → load spike → hard reboot). Hard reboots wipe volatile logs, so this both
# READS what's already on disk AND turns on PERSISTENT logging + a resource sampler so the NEXT
# freeze is captured across the reboot.
#
# USAGE
#   bash freeze_logger.sh 100.x.y.z            # SSH in (key auth): read logs + install capture
#   bash freeze_logger.sh 100.x.y.z --read     # only read current logs, install nothing
#   bash freeze_logger.sh                       # run locally on the machine
#   SUDO_PASS=123 bash freeze_logger.sh <ip>    # sudo password (default 123)
#
# What it installs (survives reboots):
#   - persistent journald (Storage=persistent) so kernel OOM-killer / systemd-oomd kills are kept
#   - /usr/local/bin/shaker_freeze_sampler.sh + cron @reboot: every 20s appends load / RAM / swap /
#     ShakerView instance count + RSS to /var/log/shaker_freeze.log (the tail = state just before a freeze)
# Related: known root cause + memory-cap backstop in memory 'matt-machine-oom-leak'.

HOST="${1:-}"; MODE="${2:-}"
if [[ -n "$HOST" && "$HOST" != "local" ]]; then
  exec ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    "shaker@$HOST" "SUDO_PASS='${SUDO_PASS:-123}' MODE='$MODE' bash -s" < "$0"
fi

set +e
SUDO_PASS="${SUDO_PASS:-123}"
runsudo(){ if [ "$(id -u)" = 0 ]; then "$@"; else printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null; fi; }
hdr(){ printf '\n=== %s ===\n' "$1"; }

echo "############ freeze_logger.sh — $(hostname) — $(date) ############"

# ---------------- READ: what the box can already tell us ----------------
hdr "Uptime / load / memory / swap (now)"
uptime
free -h
echo "MemAvailable: $(awk '/MemAvailable/{printf "%.0f MB\n",$2/1024}' /proc/meminfo)"

hdr "ShakerView processes (instance count + RSS) — duplicates are a known freeze cause"
ps -eo pid,ppid,rss,etime,cmd | grep -E "ShakerView2.0.x86_64$|/AppManager$" | grep -v grep \
  | awk '{printf "  pid=%s ppid=%s rss=%.0fMB etime=%s %s\n",$1,$2,$3/1024,$4,$5}'
echo "  ShakerView instances: $(pgrep -cf 'ShakerView2.0.x86_64$')  (expect 1) | AppManager: $(pgrep -af '/AppManager$' | grep -vc 'sh -c')"

hdr "Kernel OOM-killer / out-of-memory (dmesg)"
runsudo dmesg -T 2>/dev/null | grep -iE "out of memory|oom-kill|killed process|oom_reaper" | tail -15 \
  || echo "  (none in current dmesg buffer — may have been lost to reboot; persistent capture below)"

hdr "systemd-oomd kills (journal, if persistent)"
runsudo journalctl -k -b -1 --no-pager 2>/dev/null | grep -iE "oom|killed process" | tail -10
runsudo journalctl -u systemd-oomd --no-pager 2>/dev/null | tail -10 | sed 's/^/  /'

hdr "Reboot history — unclean hard reboots (boot with no matching shutdown) = freeze/OOM signature"
runsudo journalctl --list-boots 2>/dev/null | tail -8
echo "-- last reboots --"; last -x reboot shutdown 2>/dev/null | head -8

hdr "ShakerView own state log (tail) — look for OOM/update-loop/MDB errors"
SVLOG=$(ls -t /home/*/ShakerView2.0Linux/ShakerView2.0_Data/Logs/*.log 2>/dev/null | head -1)
if [ -n "$SVLOG" ]; then
  echo "  $SVLOG"
  grep -aiE "error|exception|out of memory|ErrorWhileUpdate|404|WrongMDBLevel|PaymentSystemsExist" "$SVLOG" 2>/dev/null | tail -15 | sed 's/^/  /'
else
  echo "  (no ShakerView Logs/*.log found)"
fi

hdr "Existing capture log (if this ran before)"
[ -f /var/log/shaker_freeze.log ] && tail -8 /var/log/shaker_freeze.log | sed 's/^/  /' || echo "  (none yet)"

if [ "${MODE:-}" = "--read" ]; then
  echo; echo "############ read-only mode — nothing installed ############"; exit 0
fi

# ---------------- INSTALL: persistent logging + sampler ----------------
hdr "Enabling PERSISTENT journald (kernel OOM / oomd kills survive the next hard reboot)"
runsudo mkdir -p /var/log/journal
if ! grep -qs '^Storage=persistent' /etc/systemd/journald.conf; then
  runsudo sh -c 'sed -i "s/^#\?Storage=.*/Storage=persistent/" /etc/systemd/journald.conf; grep -q "^Storage=persistent" /etc/systemd/journald.conf || echo "Storage=persistent" >> /etc/systemd/journald.conf'
fi
runsudo systemctl restart systemd-journald 2>/dev/null
echo "  journald Storage: $(grep -s '^Storage=' /etc/systemd/journald.conf || echo default)"

hdr "Installing resource sampler (every 20s -> /var/log/shaker_freeze.log)"
runsudo tee /usr/local/bin/shaker_freeze_sampler.sh >/dev/null <<'SAMP'
#!/usr/bin/env bash
LOG=/var/log/shaker_freeze.log
while true; do
  read -r l1 l5 l15 _ < /proc/loadavg
  memav=$(awk '/MemAvailable/{printf "%.0f",$2/1024}' /proc/meminfo)
  swfree=$(awk '/SwapFree/{printf "%.0f",$2/1024}' /proc/meminfo)
  n=$(pgrep -cf 'ShakerView2.0.x86_64$')
  rss=$(ps -eo rss,cmd | awk '/ShakerView2.0.x86_64$/{s+=$1} END{printf "%.0f", s/1024}')
  printf '%s load=%s/%s/%s memAvailMB=%s swapFreeMB=%s SVcount=%s SVrssMB=%s\n' \
    "$(date '+%F %T')" "$l1" "$l5" "$l15" "$memav" "$swfree" "${n:-0}" "${rss:-0}" >> "$LOG"
  # keep last ~5000 lines (~28h at 20s)
  [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 5200 ] && tail -5000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  sleep 20
done
SAMP
runsudo chmod +x /usr/local/bin/shaker_freeze_sampler.sh
# start now (background, detached) and on every boot via root cron
runsudo pkill -f shaker_freeze_sampler.sh 2>/dev/null
runsudo sh -c 'setsid /usr/local/bin/shaker_freeze_sampler.sh >/dev/null 2>&1 &'
CRON="@reboot root /usr/local/bin/shaker_freeze_sampler.sh >/dev/null 2>&1 &"
runsudo sh -c "grep -q shaker_freeze_sampler /etc/cron.d/shaker_freeze 2>/dev/null || echo '$CRON' > /etc/cron.d/shaker_freeze"
echo "  sampler running: $(pgrep -cf shaker_freeze_sampler.sh) | cron: $(ls /etc/cron.d/shaker_freeze 2>/dev/null || echo none)"

echo
echo "############ capture armed. Let it run; after the next freeze/reboot re-run:"
echo "  bash freeze_logger.sh $(hostname -I | awk '{print $1}') --read"
echo "and read the TAIL of /var/log/shaker_freeze.log + persistent journal for the OOM/oomd kill. ############"
