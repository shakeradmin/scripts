#!/bin/bash
# unlockScreen.sh — re-enable the physical touchscreen that lockScreen.sh disabled, WITHOUT a reboot.
# (A reboot also restores touch on its own, since xinput changes are runtime-only.)
# GitHub-loaded (edit shakeradmin/scripts/unlockScreen.sh anytime).
set -uo pipefail

# ─────────────── LOADER: pull latest body from GitHub, else embedded ───────────────
if [ -z "${UNLOCK_BODY:-}" ]; then
  SD="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
  for e in "$SD/.env" "$HOME/Desktop/credentials/.env" "$HOME/.env" /home/*/Desktop/credentials/.env; do
    [ -f "$e" ] && . "$e" 2>/dev/null && break
  done
  if [ -n "${GITHUB_TOKEN:-}" ] && command -v curl >/dev/null 2>&1; then
    _b="$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github.raw" \
      "https://api.github.com/repos/shakeradmin/scripts/contents/unlockScreen.sh" 2>/dev/null || true)"
    if printf '%s' "$_b" | head -1 | grep -q '^#!/bin/bash'; then
      echo "[unlock] loaded latest body from github"
      UNLOCK_BODY=1 bash -c "$_b" -- "$@"; exit $?
    fi
    echo "[unlock] github fetch failed — using embedded body" >&2
  fi
  UNLOCK_BODY=1
fi

# ─────────────────────────────────────────── BODY ───────────────────────────────────────────────
export DISPLAY="${DISPLAY:-:0}"
if [ -z "${XAUTHORITY:-}" ] || [ ! -f "${XAUTHORITY:-/nonexistent}" ]; then
  for x in "/run/user/$(id -u)/gdm/Xauthority" "$HOME/.Xauthority" /run/user/1000/gdm/Xauthority; do
    [ -f "$x" ] && export XAUTHORITY="$x" && break
  done
fi
command -v xinput >/dev/null 2>&1 || { echo "[unlock] xinput not installed" >&2; exit 1; }

STATE="$HOME/.lockscreen_disabled"
TOUCH_RE='touch|touchscreen|ILITEK|eGalax|Goodix|Weida|Silead|Raydium|Melfas|Cypress|Atmel|maXTouch|multitouch|ILI[0-9]|GT[0-9]{3}|FT[0-9]{4}'
n=0

enable_id() { xinput enable "$1" 2>/dev/null && { echo "[unlock] touchscreen ENABLED: id=$1  ${2:-}"; return 0; }; return 1; }

# 1) Re-enable exactly what lockScreen recorded (ids stable within the same X session).
if [ -f "$STATE" ]; then
  while IFS=$'\t' read -r id name; do
    [ -n "${id:-}" ] || continue
    enable_id "$id" "$name" && n=$((n+1))
  done < "$STATE"
  : > "$STATE"
fi

# 2) Belt-and-suspenders: re-detect any touch device still marked disabled and enable it.
while IFS= read -r line; do
  id="$(printf '%s' "$line" | grep -oE 'id=[0-9]+' | head -1 | tr -dc 0-9)"
  name="$(printf '%s' "${line%%id=*}" | tr -cd 'A-Za-z0-9 ._-' | sed 's/^ *//; s/ *$//; s/  */ /g')"
  [ -n "$id" ] || continue
  printf '%s' "$name" | grep -qiE 'XTEST|Virtual core|Keyboard' && continue
  if printf '%s' "$name" | grep -qiE "$TOUCH_RE" || xinput list-props "$id" 2>/dev/null | grep -qi 'Calibration Matrix'; then
    if xinput list-props "$id" 2>/dev/null | grep -qiE 'Device Enabled.*:[[:space:]]*0'; then
      enable_id "$id" "$name" && n=$((n+1))
    fi
  fi
done < <(xinput list 2>/dev/null | grep -iE 'slave[[:space:]]+pointer')

if [ "$n" -eq 0 ]; then echo "[unlock] nothing to re-enable (touch already on)."; else
  echo "[unlock] $n device(s) re-enabled — touch is back ON."
fi
