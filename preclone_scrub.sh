#!/usr/bin/env bash
# preclone_scrub.sh — reset a golden machine's per-unit IDENTITY so a cloned SSD does NOT
# ship the golden's identity to every client. RUN THIS AS THE LAST STEP before you image
# the disk (some of what it clears — machine-id, ssh host keys, history — regenerates the
# moment the machine is used/rebooted again, so re-run it right before cloning).
#
# Pairs with diagnose.sh (which only REPORTS this residue). bootstrap.sh already scrubs the
# telemetry secret + old bootstrap logs on each clone's first run; this does the rest up-front.
#
# USAGE
#   bash preclone_scrub.sh 100.112.118.51        # from laptop: SSH in and scrub remotely
#   bash preclone_scrub.sh                        # on the machine itself
#   WIFI=1 bash preclone_scrub.sh <ip>            # ALSO delete saved Wi-Fi (severs network! last of all)
#   ANYDESK=1 RUSTDESK=1 bash preclone_scrub.sh   # also purge AnyDesk/RustDesk IDs (bootstrap re-mints)
#
# Remote sudo password is taken from SUDO_PASS (default 123). READ-then-WRITE: telemetry.json is
# backed up (.bak-<ts>) before editing; nothing else is backed up (it is meant to be discarded).

HOST="${1:-}"
if [[ -n "$HOST" && "$HOST" != "local" ]]; then
  exec sshpass -p "${SSH_PASS:-123}" ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no "shaker@$HOST" \
    "SUDO_PASS='${SUDO_PASS:-123}' WIFI='${WIFI:-}' ANYDESK='${ANYDESK:-}' RUSTDESK='${RUSTDESK:-}' bash -s" < "$0"
  exit $?
fi

set +e
SUDO_PASS="${SUDO_PASS:-123}"
runsudo() {
  if [ "$(id -u)" = 0 ]; then "$@"; else printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null; fi
}
say() { printf '[scrub] %s\n' "$1"; }

echo "############ preclone_scrub.sh — $(hostname) — $(date) ############"

# 1) ShakerView telemetry secret (MachineKey/SnackKey) — the impersonation risk. Back up, then clear.
n=0
for tj in /home/*/ShakerView2.0Linux*/ShakerView2.0_Data/Config/telemetry.json; do
  [ -e "$tj" ] || continue
  cp -a "$tj" "${tj}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
  TJ="$tj" python3 - <<'PY' && n=$((n+1))
import json,os
p=os.environ["TJ"]
try: d=json.load(open(p,encoding="utf-8-sig"))
except Exception as e: raise SystemExit(f"unreadable: {e}")
ch=False
for k in ("MachineKey","SnackKey"):
    if d.get(k): d[k]=""; ch=True
if ch: json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
print("  scrubbed" if ch else "  already clean", p)
PY
done
say "telemetry.json secret cleared in $n file(s) (backups kept)"

# 2) Bootstrap logs + credential files carried in the image.
HOMES=$(getent passwd | awk -F: '$6 ~ /^\/home\// {print $6}' | sort -u)
rm -f /home/*/bootstrap_device_*.log /home/*/bootstrap-credentials-*.txt 2>/dev/null
say "removed bootstrap_device_*.log and bootstrap-credentials-*.txt"

# 3) Shell history for every human user + root.
for h in $HOMES /root; do
  [ -f "$h/.bash_history" ] && { : > "$h/.bash_history" 2>/dev/null || runsudo truncate -s0 "$h/.bash_history"; }
done
history -c 2>/dev/null
say "shell history cleared"

# 4) systemd machine-id — must be empty so each clone regenerates a unique one on first boot.
runsudo truncate -s0 /etc/machine-id
runsudo rm -f /var/lib/dbus/machine-id
runsudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
say "machine-id emptied (regenerates uniquely on next boot)"

# 5) SSH host keys — replace the golden's with a FRESH set. We regenerate immediately (ssh-keygen
#    -A) rather than leaving the machine keyless: socket-activated sshd refuses ALL connections
#    with no host keys on disk, which would brick remote access to the machine. Per-unit uniqueness
#    is then guaranteed by bootstrap.sh (it runs ssh-keygen -A on every clone at provisioning).
runsudo sh -c 'rm -f /etc/ssh/ssh_host_* && ssh-keygen -A'
runsudo systemctl restart ssh.socket 2>/dev/null; runsudo systemctl restart ssh 2>/dev/null
say "SSH host keys regenerated fresh (bootstrap re-generates again per-clone for uniqueness)"

# 6) Optional: AnyDesk / RustDesk IDs (bootstrap normally re-mints these; opt-in here).
if [ "${ANYDESK:-}" = "1" ]; then
  runsudo systemctl stop anydesk 2>/dev/null
  runsudo sh -c 'rm -f /etc/anydesk/service.conf /etc/anydesk/*.conf' 2>/dev/null
  rm -rf /home/*/.anydesk 2>/dev/null
  say "AnyDesk identity purged (ANYDESK=1)"
fi
if [ "${RUSTDESK:-}" = "1" ]; then
  runsudo systemctl stop rustdesk 2>/dev/null
  rm -rf /home/*/.config/rustdesk 2>/dev/null
  say "RustDesk identity purged (RUSTDESK=1)"
fi

# 7) Optional: saved Wi-Fi profiles — LAST, because deleting them drops this machine off the network.
if [ "${WIFI:-}" = "1" ]; then
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f UUID,TYPE connection show 2>/dev/null | awk -F: '$2 ~ /wireless/ {print $1}' \
      | while read -r u; do runsudo nmcli connection delete uuid "$u" >/dev/null 2>&1; done
    say "saved Wi-Fi profiles deleted (WIFI=1) — network now down until reconfigured"
  fi
else
  say "Wi-Fi profiles LEFT in place (set WIFI=1 to delete — do it last, it cuts the network)"
fi

echo "############ scrub done — image the disk now. Re-run right before cloning if the machine is used again. ############"
