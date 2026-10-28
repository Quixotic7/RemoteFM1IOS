#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# M3's headless check on one simulator: build, boot (simctl only: Simulator.app stays closed), install, and for each
# core launch the app with -coretest -fake -core <id> (the fake unit's demo input plays it), wait for coretest.json,
# take a screenshot, print the summary; shut the simulator down again if this script booted it.
#
#   scripts/sim_coretest.sh [UDID] [core ...]     (default: RFM iPhone 17, CEB2B846-...;
#                                                  choralroot felucca melodee fizz)
#   OUT=dir   where the results go (default $TMPDIR/remotefm1-coretest); NOBUILD=1 reuses the last build
#
# The app's link is the in-process fake unit: nothing touches CoreMIDI or a real FM-1.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE=com.quixotic7.remotefm1
UDID=${1:-}
[ $# -gt 0 ] && shift
UDID=${UDID:-CEB2B846-457C-4A33-AA1A-A287D30CDE2F}   # (RFM iPhone 17, this project's own simulator)
CORES=("$@")
[ ${#CORES[@]} -gt 0 ] || CORES=(choralroot felucca melodee fizz)
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

for core in "${CORES[@]}"; do
    say "launch -coretest -fake -core $core"
    rm -f "$DATA/Documents/coretest.json" "$RES/coretest-$core.json" "$RES/core-$core.png"
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    T0=$(date +%s)
    xcrun simctl launch "$UDID" "$BUNDLE" -coretest -fake -core "$core" >/dev/null
    for _ in $(seq 1 60); do
        if [ -f "$DATA/Documents/coretest.json" ] && grep -q '"done" : true' "$DATA/Documents/coretest.json"; then break; fi
        sleep 1
    done
    sleep 1
    xcrun simctl io "$UDID" screenshot "$RES/core-$core.png" >/dev/null 2>&1 && echo "screenshot: $RES/core-$core.png"
    if [ -f "$DATA/Documents/coretest.json" ]; then
        cp "$DATA/Documents/coretest.json" "$RES/coretest-$core.json"
        /usr/bin/python3 -I - "$RES/coretest-$core.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(f"{s['device']} / {s['system']}: {s['name']} {s['version']} ({s['license']}), slot {s['slot']} of {s['slots']}")
for st in s['steps']:
    ok = {True: 'ok', False: 'NO', None: '--'}[st.get('ok')]
    print(f"[{ok}] {st['name']}: {st['detail']}")
PY
    else
        echo "no coretest.json after 60 s"
    fi
    xcrun simctl spawn "$UDID" log show --info --style compact --start "$(date -r "$T0" '+%Y-%m-%d %H:%M:%S')" \
        --predicate 'subsystem == "com.quixotic7.remotefm1" OR (process == "RemoteFM1" AND messageType == error)' \
        >"$RES/log-$core.txt" 2>&1 || true
done

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
if [ "$booted_here" = 1 ]; then say "shutdown"; xcrun simctl shutdown "$UDID"; fi
echo "results: $RES"
