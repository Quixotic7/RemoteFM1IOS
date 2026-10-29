#!/bin/sh
# run.sh NAME MODE BPS SECONDS [fm1loop args...]: a session (sxload, SysEx only) with MODE at BPS, and the loopback
# recorded for SECONDS meanwhile. MODE "none": no session, the loopback only. Logs and the WAV in build/runs/.
set -e
cd "$(dirname "$0")"
NAME=$1 MODE=$2 BPS=$3 SECS=$4
shift 4
mkdir -p build/runs
if [ "$MODE" != none ]; then
    build/sxload --mode "$MODE" --bps "$BPS" --seconds $((SECS + 4)) ${SXARGS} >build/runs/$NAME.sx.log 2>&1 &
    SX=$!
    sleep 3
fi
build/fm1loop --seconds "$SECS" --out build/runs/$NAME.wav "$@" >build/runs/$NAME.loop.log 2>&1
[ -n "$SX" ] && wait $SX
python3 analyze.py build/runs/$NAME.wav --json >build/runs/$NAME.json; python3 analyze.py build/runs/$NAME.wav | head -8

grep -h "RESULT\|STATS" build/runs/$NAME.sx.log 2>/dev/null || true
