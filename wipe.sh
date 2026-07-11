#!/bin/bash
# wipe.sh — pre-cloning WIPE / generalize for a golden Shaker machine.
#
# Loads its own latest body from GitHub each run (like bootstrap.sh), so you can edit the
# behaviour on GitHub (shakeradmin/scripts/wipe.sh) at any moment and every machine picks it
# up on the next run. If GitHub can't be reached it falls back to this local copy's body.
#
# Removes ALL telemetry identity + every per-unit identity (Tailscale, AnyDesk, RustDesk,
# machine-id, SSH host keys, logs/history) so a cloned SSD does not ship the golden's identity
# to every client. Companion of bootstrap.sh (which re-mints identity on each clone's first run).
#
# 🔴 RUN ON-CONSOLE (physical keyboard / AnyDesk) AS THE LAST STEP before imaging — the Tailscale
#    step severs remote access. References: rmSSH.sh, rmAnydesk.sh, rmRustdesk.sh, preclone_scrub.sh.
#
# USAGE (on the machine):   sudo bash wipe.sh
#   TAILSCALE=0 sudo bash wipe.sh   # keep Tailscale identity (skip the network-severing step)
#   ANYDESK=0 RUSTDESK=0 ...        # keep those remote-desktop IDs
#   WIFI=1 ...                       # also delete saved Wi-Fi (do it truly last; cuts network)
#
set -uo pipefail

# ─────────────────────────── LOADER: fetch latest body from GitHub ───────────────────────────
if [ -z "${WIPE_BODY:-}" ]; then
  SD="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
  for e in "$SD/.env" "$HOME/Desktop/credentials/.env" "$HOME/.env" /home/*/Desktop/credentials/.env; do
    [ -f "$e" ] && . "$e" 2>/dev/null && break
  done
  if [ -n "${GITHUB_TOKEN:-}" ] && command -v curl >/dev/null 2>&1; then
    _body="$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github.raw" \
      "https://api.github.com/repos/shakeradmin/scripts/contents/wipe.sh" 2>/dev/null || true)"
    if printf '%s' "$_body" | head -1 | grep -q '^#!/bin/bash'; then
      echo "[wipe] loaded latest body from github (shakeradmin/scripts/wipe.sh)"
      WIPE_BODY=1 GITHUB_TOKEN="${GITHUB_TOKEN:-}" SUDO_PASS="${SUDO_PASS:-123}" \
        TAILSCALE="${TAILSCALE:-1}" ANYDESK="${ANYDESK:-1}" RUSTDESK="${RUSTDESK:-1}" WIFI="${WIFI:-}" \
        bash -c "$_body" -- "$@"
      exit $?
    fi
    echo "[wipe] github fetch failed — running this local copy's embedded body" >&2
  else
    echo "[wipe] no GITHUB_TOKEN/curl — running this local copy's embedded body" >&2
  fi
  WIPE_BODY=1   # fall through to the embedded body below
fi

# ─────────────────────────────────────── BODY ────────────────────────────────────────────────
SUDO_PASS="${SUDO_PASS:-123}"
runsudo() { if [ "$(id -u)" = 0 ]; then "$@"; else printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null; fi; }
say() { printf '[wipe] %s\n' "$1"; }

echo "############ wipe.sh — $(hostname) — $(date) ############"
echo "############ pre-cloning generalize. Image the disk right after this. ############"

# 1) TELEMETRY — clear the impersonation secret AND the machine identity (keep server addresses).
n=0
for tj in /home/*/ShakerView2.0Linux*/ShakerView2.0_Data/Config/telemetry.json; do
  [ -e "$tj" ] || continue
  cp -a "$tj" "${tj}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
  TJ="$tj" python3 - <<'PY' && n=$((n+1))
import json,os
p=os.environ["TJ"]
try: d=json.load(open(p,encoding="utf-8-sig"))
except Exception as e: raise SystemExit(f"  unreadable: {e}")
for k in ("MachineKey","SnackKey"):
    if k in d: d[k]=""
for k in ("MachineId","OrganizationId","OutletId","MachineModelId"):
    if k in d: d[k]=None
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
print("  generalized",p)
PY
done
say "telemetry.json identity cleared in $n file(s) — server addresses kept, backups (.bak-*) left"

# 2) Bootstrap logs + credential dumps carried in the image.
rm -f /home/*/bootstrap_device_*.log /home/*/bootstrap-credentials-*.txt \
      /home/*/anydesk_removal_*.log /home/*/rustdesk_removal_*.log 2>/dev/null
say "removed bootstrap/*_removal logs + credential dumps"

# 3) Shell history (all human users + root).
HOMES=$(getent passwd | awk -F: '$6 ~ /^\/home\// {print $6}' | sort -u)
for h in $HOMES /root; do [ -f "$h/.bash_history" ] && { : > "$h/.bash_history" 2>/dev/null || runsudo truncate -s0 "$h/.bash_history"; }; done
history -c 2>/dev/null || true
say "shell history cleared"

# 4) App + system logs.
rm -f /home/*/ShakerView2.0Linux*/ShakerView2.0_Data/Logs/*.log /home/*/appmanager.log 2>/dev/null
rm -f /home/*/.config/unity3d/*/*/Player*.log 2>/dev/null
runsudo journalctl --rotate 2>/dev/null; runsudo journalctl --vacuum-time=1s 2>/dev/null
say "app + journal logs vacuumed"

# 5) systemd machine-id — emptied so each clone regenerates a unique one on first boot.
runsudo truncate -s0 /etc/machine-id
runsudo rm -f /var/lib/dbus/machine-id
runsudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
say "machine-id emptied (regenerates uniquely on next boot)"

# 6) SSH host keys — replace with a FRESH set; regenerate immediately so socket-activated sshd is
#    never left keyless (that would brick remote access). bootstrap.sh regenerates again per clone.
runsudo sh -c 'rm -f /etc/ssh/ssh_host_* && ssh-keygen -A'
runsudo systemctl restart ssh.socket 2>/dev/null; runsudo systemctl restart ssh 2>/dev/null
say "SSH host keys regenerated fresh (bootstrap re-mints per clone)"

# 7) AnyDesk identity (ref rmAnydesk.sh) — keep the package, drop the ID so first start mints a new one.
if [ "${ANYDESK:-1}" = "1" ]; then
  runsudo systemctl stop anydesk 2>/dev/null
  runsudo sh -c 'rm -f /etc/anydesk/service.conf /etc/anydesk/*.conf' 2>/dev/null
  rm -rf /home/*/.anydesk 2>/dev/null
  say "AnyDesk identity purged (set ANYDESK=0 to keep)"
fi

# 8) RustDesk identity (ref rmRustdesk.sh).
if [ "${RUSTDESK:-1}" = "1" ]; then
  runsudo systemctl stop rustdesk 2>/dev/null
  runsudo rm -rf /etc/rustdesk 2>/dev/null
  rm -rf /home/*/.config/rustdesk 2>/dev/null
  say "RustDesk identity purged (set RUSTDESK=0 to keep)"
fi

# 9) Saved Wi-Fi (opt-in) — cuts the network, so only if explicitly asked, before Tailscale.
if [ "${WIFI:-}" = "1" ] && command -v nmcli >/dev/null 2>&1; then
  nmcli -t -f UUID,TYPE connection show 2>/dev/null | awk -F: '$2 ~ /wireless/ {print $1}' \
    | while read -r u; do runsudo nmcli connection delete uuid "$u" >/dev/null 2>&1; done
  say "saved Wi-Fi profiles deleted (WIFI=1)"
fi

# 10) 🔴 Tailscale identity (ref rmSSH.sh) — LAST: a clone must not hijack the golden's node.
#     This severs Tailscale/SSH reachability until re-auth (bootstrap.sh / setup_tailscale_clone.sh).
if [ "${TAILSCALE:-1}" = "1" ]; then
  runsudo tailscale logout 2>/dev/null || true
  runsudo systemctl stop tailscaled 2>/dev/null || true
  runsudo rm -f /var/lib/tailscale/tailscaled.state /var/lib/tailscale/tailscaled.state.conf 2>/dev/null
  say "Tailscale identity removed (set TAILSCALE=0 to keep) — machine now OFF the tailnet"
fi

echo "############ wipe done — power off and image the disk now. Re-run if the machine is used again. ############"
