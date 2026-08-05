#!/usr/bin/env bash
# ShakerView freeze watchdog -- graduated recovery ladder.
#
# Deployed 2026-07-26 for Vlad's machine (Strapi id 25) after the 07-26 freeze, where the
# kernel, network and the ShakerView process all stayed alive for ~20h while the screen was
# dead. Blanket periodic reboots were rejected as a mitigation; this only acts when a freeze
# is actually detected, and escalates cheapest-first so a recoverable stall costs seconds
# instead of a full boot cycle.
#
# IMPORTANT -- what this can and cannot see:
#   It detects an unresponsive X server, a dead/stalled ShakerView, and a wedged Unity main
#   thread (via the render-thread heartbeat added to PatchDiag in the same patch).
#   It CANNOT detect a pure display-controller/scanout wedge: if the app keeps rendering
#   correctly and only the physical scanout is frozen, every software signal still reads
#   healthy. The PatchDiag "frames=N (+delta) mainthread=ok|STALLED" line is what tells us
#   afterwards which of those two cases actually happened.
#
# Policy: restarts ShakerView by killing its EXACT pid and letting AppManager relaunch it
# canonically. Never pkill-by-mask (the mask matches AppManager's own script text) and never
# nohup the relaunch.

set -uo pipefail

DIAG_DIR="/home/shaker/ShakerView-diag"
DIAG_LOG="$DIAG_DIR/patch-diag.log"
WD_LOG="$DIAG_DIR/watchdog.log"
SV_BIN="/home/shaker/ShakerView2.0Linux/ShakerView2.0.x86_64"
SV_USER="shaker"
SV_UID="1000"

BOOT_GRACE=120         # settle time before the first check, so a still-starting kiosk is not
                       # mistaken for a frozen one. Deliberately here and NOT an ExecStartPre=
                       # sleep: that runs under systemd's TimeoutStartSec (90s by default), so
                       # it gets SIGTERMed at 90s and the unit restart-loops forever.
CHECK_INTERVAL=60      # seconds between health checks
BAD_THRESHOLD=3        # consecutive bad checks before acting (~3 min, avoids false positives)
SETTLE=90              # seconds to wait for a recovery step to take effect
DIAG_STALE=300         # patch-diag.log considered stale after this many seconds
COOLDOWN=900           # quiet period after a successful recovery
FW_HOLD_GRACE=300      # while a controller-firmware write is PROGRESSING the watchdog holds
                       # off entirely; once it has made no progress for this long it is
                       # treated as wedged and the normal ladder resumes.

SV_DATA="/home/shaker/ShakerView2.0Linux/ShakerView2.0_Data"
PLAYER_LOG="/home/shaker/.config/unity3d/ShakerTechnology/ShakerView2.0/Player.log"
fw_last_line=0
fw_last_progress=0

bad_count=0
step=0
last_recovery=0

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$WD_LOG"
}

# Resolve the live X authority file for the autologin session.
xauth_file() {
    local f="/run/user/$SV_UID/gdm/Xauthority"
    [[ -f "$f" ]] && { echo "$f"; return; }
    f=$(find "/run/user/$SV_UID" -maxdepth 2 -name 'Xauthority' -o -maxdepth 2 -name '.mutter-Xwaylandauth*' 2>/dev/null | head -1)
    echo "$f"
}

as_user_x() {
    local xa
    xa="$(xauth_file)"
    [[ -n "$xa" ]] || return 1
    timeout 15 setpriv --reuid="$SV_UID" --regid="$SV_UID" --clear-groups \
        env DISPLAY=:0 XAUTHORITY="$xa" HOME="/home/$SV_USER" "$@"
}

# Exact-match the ShakerView pid; never a mask that could also hit AppManager or ourselves.
sv_pid() {
    ps -eo pid=,cmd= | awk -v bin="$SV_BIN" -v me="$$" '$1 != me && $2 == bin { print $1; exit }'
}

# A controller-firmware update makes this watchdog's own stall detector lie.
#
# AutoUpdater.StartUpdatingFirmware() loads ControllerUpdatePage and then UNLOADS the active
# scene -- which destroys MainThreadWorker, the MonoBehaviour that stamps PatchDiag.FrameTick().
# So the frame counter freezes and PatchDiag reports "mainthread=STALLED" even though the app is
# perfectly healthy and writing the controller. Measured on 260511735: frames stuck at 363 while
# 2015 of 2837 lines were written successfully.
#
# On 2026-07-29 that false positive made this watchdog restart ShakerView mid-write and abort a
# healthy flash (the controller survived, falling back to its old image, but the update was
# lost). So: once an update session is underway -- a .hex is staged AND ControllerUpdatePage has
# been entered -- hold off. Keep holding while the line counter climbs; release FW_HOLD_GRACE
# after it stops climbing, so a genuinely wedged flash cannot disable the watchdog forever.
firmware_write_active() {
    compgen -G "$SV_DATA"/*.hex >/dev/null 2>&1 || return 1     # nothing staged -> no session
    grep -q 'ControllerUpdatePage' "$PLAYER_LOG" 2>/dev/null || return 1

    local line now
    now=$(date +%s)
    line=$(grep -oE '^[0-9]+ CommandManager.IsControllerReadyToReadNextLineOfFirmware' \
           "$PLAYER_LOG" 2>/dev/null | tail -1 | awk '{print $1}')
    line=${line:-0}

    if (( line > fw_last_line )); then          # writing -- hold off, restart the clock
        fw_last_line=$line
        fw_last_progress=$now
        return 0
    fi
    (( fw_last_progress == 0 )) && fw_last_progress=$now
    (( now - fw_last_progress < FW_HOLD_GRACE ))
}

# Returns 0 (healthy) or 1 (frozen), printing the reason when frozen.
health_check() {
    local now diag_age last_hb pid
    now=$(date +%s)

    pid="$(sv_pid)"
    if [[ -z "$pid" ]]; then
        echo "ShakerView process not running"
        return 1
    fi

    if [[ -f "$DIAG_LOG" ]]; then
        diag_age=$(( now - $(stat -c %Y "$DIAG_LOG") ))
        if (( diag_age > DIAG_STALE )); then
            echo "patch-diag.log stale (${diag_age}s, no heartbeat)"
            return 1
        fi
        last_hb="$(grep -a 'heartbeat' "$DIAG_LOG" | tail -1)"
        if [[ "$last_hb" == *"mainthread=STALLED"* ]]; then
            echo "Unity main thread stalled: ${last_hb##*] }"
            return 1
        fi
    fi

    if ! as_user_x xset q >/dev/null 2>&1; then
        echo "X server unresponsive (xset q failed)"
        return 1
    fi

    return 0
}

# --- recovery ladder, cheapest first ---

recover_dpms() {
    log "STEP 1: DPMS off/on modeset cycle"
    as_user_x xset dpms force off >/dev/null 2>&1
    sleep 3
    as_user_x xset dpms force on  >/dev/null 2>&1
    as_user_x xset -dpms          >/dev/null 2>&1
    as_user_x xset s off          >/dev/null 2>&1
}

recover_restart_app() {
    local pid
    pid="$(sv_pid)"
    if [[ -z "$pid" ]]; then
        log "STEP 2: ShakerView already gone, leaving relaunch to AppManager"
        return
    fi
    log "STEP 2: restarting ShakerView (exact pid $pid; AppManager will relaunch)"
    kill "$pid" 2>/dev/null
    sleep 10
    if kill -0 "$pid" 2>/dev/null; then
        log "STEP 2: pid $pid still alive after TERM, sending KILL"
        kill -9 "$pid" 2>/dev/null
    fi
}

recover_restart_gdm() {
    log "STEP 3: restarting gdm (rebuilds X + autologin + AppManager)"
    systemctl restart gdm
}

recover_reboot() {
    log "STEP 4: rebooting -- all lighter recovery steps failed"
    systemctl reboot
}

log "=== watchdog started (grace=${BOOT_GRACE}s interval=${CHECK_INTERVAL}s threshold=${BAD_THRESHOLD}) ==="
sleep "$BOOT_GRACE"
log "grace period over, monitoring"

while true; do
    sleep "$CHECK_INTERVAL"

    now=$(date +%s)
    if (( now - last_recovery < COOLDOWN )); then
        continue
    fi

    if reason="$(health_check)"; then
        if (( bad_count > 0 )); then
            log "recovered -- healthy again after $bad_count bad check(s)"
        fi
        bad_count=0
        step=0
        continue
    fi

    if firmware_write_active; then
        log "holding off ($reason) -- controller firmware write in progress at line $fw_last_line"
        bad_count=0
        continue
    fi

    bad_count=$(( bad_count + 1 ))
    log "unhealthy ($bad_count/$BAD_THRESHOLD): $reason"

    if (( bad_count < BAD_THRESHOLD )); then
        continue
    fi

    step=$(( step + 1 ))
    case "$step" in
        1) recover_dpms ;;
        2) recover_restart_app ;;
        3) recover_restart_gdm ;;
        4) recover_reboot ;;
        *) log "ladder exhausted, restarting sequence"; step=0 ;;
    esac

    sleep "$SETTLE"

    if reason="$(health_check)"; then
        log "RECOVERED after step $step"
        bad_count=0
        step=0
        last_recovery=$(date +%s)
    else
        log "still unhealthy after step $step: $reason"
        bad_count=$BAD_THRESHOLD
    fi
done
