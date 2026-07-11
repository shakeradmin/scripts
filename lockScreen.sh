#!/bin/bash
# lockScreen.sh — disable the physical TOUCHSCREEN until the next reboot.
# The mouse and AnyDesk remote control (which inject via XTEST) keep working — only the real
# touch panel is turned off. xinput changes are runtime-only, so a reboot restores touch by itself.
# Undo without rebooting: unlockScreen.sh. GitHub-loaded (edit shakeradmin/scripts/lockScreen.sh anytime).
set -uo pipefail

# ─────────────── LOADER: pull latest body from GitHub (like bootstrap/wipe), else embedded ───────────────
if [ -z "${LOCK_BODY:-}" ]; then
  SD="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
  for e in "$SD/.env" "$HOME/Desktop/credentials/.env" "$HOME/.env" /home/*/Desktop/credentials/.env; do
    [ -f "$e" ] && . "$e" 2>/dev/null && break
  done
  if [ -n "${GITHUB_TOKEN:-}" ] && command -v curl >/dev/null 2>&1; then
    _b="$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github.raw" \
      "https://api.github.com/repos/shakeradmin/scripts/contents/lockScreen.sh" 2>/dev/null || true)"
    if printf '%s' "$_b" | head -1 | grep -q '^#!/bin/bash'; then
      echo "[lock] loaded latest body from github"
      LOCK_BODY=1 bash -c "$_b" -- "$@"; exit $?
    fi
    echo "[lock] github fetch failed — using embedded body" >&2
  fi
  LOCK_BODY=1
fi

# ─────────────────────────────────────────── BODY ───────────────────────────────────────────────
# Resolve an X display + auth so this also works when launched over SSH / from the loader.
export DISPLAY="${DISPLAY:-:0}"
if [ -z "${XAUTHORITY:-}" ] || [ ! -f "${XAUTHORITY:-/nonexistent}" ]; then
  for x in "/run/user/$(id -u)/gdm/Xauthority" "$HOME/.Xauthority" /run/user/1000/gdm/Xauthority; do
    [ -f "$x" ] && export XAUTHORITY="$x" && break
  done
fi
command -v xinput >/dev/null 2>&1 || { echo "[lock] xinput not installed: sudo apt install -y xinput" >&2; exit 1; }

STATE="$HOME/.lockscreen_disabled"
# Known touch-controller names / generic touch terms. XTEST/virtual/mouse/keyboard are excluded below.
TOUCH_RE='touch|touchscreen|ILITEK|eGalax|Goodix|Weida|Silead|Raydium|Melfas|Cypress|Atmel|maXTouch|multitouch|ILI[0-9]|GT[0-9]{3}|FT[0-9]{4}'

is_touch() { # $1=id $2=name -> 0 if this is a physical touchscreen
  local id="$1" name="$2"
  # never touch AnyDesk/synthetic/virtual/keyboard devices
  printf '%s' "$name" | grep -qiE 'XTEST|Virtual core|AnyDesk|Consumer Control|Keyboard|System Control|Power Button|Sleep Button|Video Bus' && return 1
  printf '%s' "$name" | grep -qiE "$TOUCH_RE" && return 0
  # capability fallback: real touchscreens expose a libinput Calibration Matrix (mice do not)
  xinput list-props "$id" 2>/dev/null | grep -qi 'Calibration Matrix' && return 0
  return 1
}

: > "$STATE"
n=0
while IFS= read -r line; do
  id="$(printf '%s' "$line"  | grep -oE 'id=[0-9]+' | head -1 | tr -dc 0-9)"
  name="$(printf '%s' "${line%%id=*}" | tr -cd 'A-Za-z0-9 ._-' | sed 's/^ *//; s/ *$//; s/  */ /g')"
  [ -n "$id" ] || continue
  if is_touch "$id" "$name"; then
    if xinput disable "$id" 2>/dev/null; then
      printf '%s\t%s\n' "$id" "$name" >> "$STATE"; n=$((n+1))
      echo "[lock] touchscreen DISABLED: id=$id  $name"
    fi
  fi
done < <(xinput list 2>/dev/null | grep -iE 'slave[[:space:]]+pointer')

if [ "$n" -eq 0 ]; then
  echo "[lock] no touchscreen device found — nothing disabled." >&2; exit 2
fi
echo "[lock] $n device(s) off. Touch is LOCKED until reboot. Mouse + AnyDesk still work. Undo now: unlockScreen.sh"
