#!/usr/bin/env bash
# Positive-detection test for the watchdog: feed it synthetic fault conditions and confirm
# health_check reports them. Touches only /tmp files -- never the real system.
sed '/^log "=== watchdog started/,$d' /usr/local/bin/shakerview-watchdog.sh > /tmp/wd_funcs.sh
source /tmp/wd_funcs.sh

pass=0; fail=0
check() { # name expected_substring
    local name="$1" want="$2" got
    if got="$(health_check)"; then got="HEALTHY"; fi
    if [[ "$got" == *"$want"* ]]; then echo "  PASS  $name -> $got"; pass=$((pass+1));
    else echo "  FAIL  $name -> got '$got', wanted '*$want*'"; fail=$((fail+1)); fi
}

echo "== 1. real system, unmodified (should be HEALTHY) =="
check "healthy baseline" "HEALTHY"

echo "== 2. main-thread stall line in diag log =="
DIAG_LOG=/tmp/wd_fake_diag.log
cat > "$DIAG_LOG" <<'EOF'
[2026-07-26 21:00:00.000][up=60m][tid=8][thr=45][fd=41][rss=582MB][gc=98MB] heartbeat frames=100 (+1800) mainthread=ok
[2026-07-26 21:01:00.000][up=61m][tid=8][thr=45][fd=41][rss=582MB][gc=98MB] heartbeat frames=1900 (+0) mainthread=STALLED 340s
EOF
check "mainthread STALLED" "main thread stalled"

echo "== 3. stale diag log (no heartbeat for >5min) =="
touch -d '30 minutes ago' "$DIAG_LOG"
check "stale log" "stale"

echo "== 4. ShakerView process missing =="
DIAG_LOG=/tmp/wd_fake_diag.log; touch "$DIAG_LOG"
SV_BIN=/nonexistent/ShakerView-that-is-not-running
check "process missing" "not running"

echo "== 5. healthy again after restoring real values =="
DIAG_LOG="/home/shaker/ShakerView-diag/patch-diag.log"
SV_BIN="/home/shaker/ShakerView2.0Linux/ShakerView2.0.x86_64"
check "healthy restored" "HEALTHY"

rm -f /tmp/wd_fake_diag.log /tmp/wd_funcs.sh
echo "== RESULT: $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
