#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# M3's headless check on one simulator: build, boot (simctl only: Simulator.app stays closed), install, and for each
# core launch the app with -coretest -fake -core <id> (the fake unit's demo input plays it), wait for coretest.json,
# take a screenshot, print the summary; shut the simulator down again if this script booted it.
#
#   scripts/sim_coretest.sh [UDID] [core ...]     (default: RFM iPhone 17, CEB2B846-...;
#                                                  choralroot felucca melodee fizz saadet boardwalk loom)
#   OUT=dir   where the results go (default $TMPDIR/remotefm1-coretest); NOBUILD=1 reuses the last build
#   RFM1="felucca choralroot"   (M7) imported firmware: each <id>-*.rfm1 of $RFM1_DIR (default FM1VST's rfm1 worktree's
#             build-rfm1/rfm1) copied into the app's Documents/Firmware after the install; then name it as a core
#             with rfm1:<id> (e.g. scripts/sim_coretest.sh "" rfm1:felucca rfm1:choralroot). With RFM1 set and no
#             cores named, the imported ones are tested
#
# The app's link is the in-process fake unit: nothing touches CoreMIDI or a real FM-1.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE=com.quixotic7.remotefm1
UDID=${1:-}
[ $# -gt 0 ] && shift
UDID=${UDID:-CEB2B846-457C-4A33-AA1A-A287D30CDE2F}   # (RFM iPhone 17, this project's own simulator)
CORES=("$@")
RFM1_DIR=${RFM1_DIR:-/Volumes/Q7Media-2025/Projects/Github/ChoralRootFM1/FM1VST/.claude/worktrees/rfm1/build-rfm1/rfm1}
if [ ${#CORES[@]} -eq 0 ] && [ -n "${RFM1:-}" ]; then for i in $RFM1; do CORES+=("rfm1:$i"); done; fi
[ ${#CORES[@]} -gt 0 ] || CORES=(choralroot felucca melodee fizz saadet boardwalk loom)
OUT=${OUT:-${TMPDIR:-/tmp}/remotefm1-coretest}
DD=$OUT/dd
RES=$OUT/$UDID
mkdir -p "$RES"

say() { printf '== %s\n' "$*"; }

if [ -z "${NOBUILD:-}" ]; then
    say "build (simulator) -> $DD"
    xcodebuild -project "$ROOT/RemoteFM1.xcodeproj" -scheme RemoteFM1 -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" build >"$OUT/build.log" 2>&1 \
        || { tail -30 "$OUT/build.log"; exit 1; }
fi
APP=$DD/Build/Products/Debug-iphonesimulator/RemoteFM1.app

booted_here=0
if ! xcrun simctl list devices booted | grep -q "$UDID"; then
    say "boot $UDID"
    xcrun simctl boot "$UDID"
    booted_here=1
fi
xcrun simctl bootstatus "$UDID" >/dev/null
xcrun simctl list devices | grep "$UDID" | sed 's/^ */device: /'

say "install"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
echo "data: $DATA"
if [ -n "${RFM1:-}" ]; then
    mkdir -p "$DATA/Documents/Firmware"
    for i in $RFM1; do
        f=$(ls "$RFM1_DIR"/"$i"-*.rfm1 2>/dev/null | head -1)
        [ -n "$f" ] || { echo "no $i-*.rfm1 in $RFM1_DIR"; exit 1; }
        cp "$f" "$DATA/Documents/Firmware/"
        echo "firmware: $(basename "$f") -> Documents/Firmware"
    done
fi

for core in "${CORES[@]}"; do
    say "launch -coretest -fake -core $core"
    name=${core//:/-}
    rm -f "$DATA/Documents/coretest.json" "$RES/coretest-$name.json" "$RES/core-$name.png"
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    T0=$(date +%s)
    xcrun simctl launch "$UDID" "$BUNDLE" -coretest -fake -core "$core" >/dev/null
    for _ in $(seq 1 60); do
        if [ -f "$DATA/Documents/coretest.json" ] && grep -q '"done" : true' "$DATA/Documents/coretest.json"; then break; fi
        sleep 1
    done
    sleep 1
    xcrun simctl io "$UDID" screenshot "$RES/core-$name.png" >/dev/null 2>&1 && echo "screenshot: $RES/core-$name.png"
    if [ -f "$DATA/Documents/coretest.json" ]; then
        cp "$DATA/Documents/coretest.json" "$RES/coretest-$name.json"
        /usr/bin/python3 -I - "$RES/coretest-$name.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
kind = s.get('kind') or 'native'
where = f"slot {s['slot']} of {s['slots']}" if kind == 'native' else f"wasm, {s.get('sha256', '')[:12]}"
print(f"{s['device']} / {s['system']}: {s['name']} {s['version']} ({s['license']}), {where}")
print(f"core thread: {s.get('coreAvgUs')} us avg, {s.get('coreMaxUs')} us max per render ({s.get('coreLoadPct')}%), "
      f"frame() max {s.get('frameMaxUs')} us, {s.get('underruns')} underruns; renders of {s.get('renderFrames')} frames "
      f"at {s.get('sampleRate')} Hz")
for st in s['steps']:
    ok = {True: 'ok', False: 'NO', None: '--'}[st.get('ok')]
    print(f"[{ok}] {st['name']}: {st['detail']}")
PY
    else
        echo "no coretest.json after 60 s"
    fi
    xcrun simctl spawn "$UDID" log show --info --style compact --start "$(date -r "$T0" '+%Y-%m-%d %H:%M:%S')" \
        --predicate 'subsystem == "com.quixotic7.remotefm1" OR (process == "RemoteFM1" AND messageType == error)' \
        >"$RES/log-$name.txt" 2>&1 || true
done

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
if [ "$booted_here" = 1 ]; then say "shutdown"; xcrun simctl shutdown "$UDID"; fi
echo "results: $RES"
