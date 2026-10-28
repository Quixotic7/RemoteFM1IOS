#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# M4's headless check on one simulator: build, boot (simctl only: Simulator.app stays closed), install, launch with
# -aucoretest (App/AUCoreTest.swift: two AU instances out of process playing ChoralRoot and Felucca, the panel moved
# between them on the extension's shared fake unit, fullState with the flash, a duplicate, the app against the
# extension), take a screenshot at each of the test's markers, print the summary, save the log, and shut the
# simulator down again if this script booted it.
#
#   scripts/sim_aucoretest.sh [UDID]    (default: the first booted simulator, else an iPhone 17)
#   OUT=dir   where the results go (default $TMPDIR/remotefm1-aucoretest); NOBUILD=1 reuses the last build
#
# Only fake units: the test tells the extension to use its shared fake (au-backend.txt in the App Group) before it
# instantiates anything, and the app's own link is its in-process fake.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE=com.quixotic7.remotefm1
GROUP=group.com.quixotic7.remotefm1
UDID=${1:-$(xcrun simctl list devices booted | grep -Eo '[0-9A-F-]{36}' | head -1 || true)}
UDID=${UDID:-$(xcrun simctl list devices available | grep -E 'iPhone 17 \(' | grep -Eo '[0-9A-F-]{36}' | head -1)}
OUT=${OUT:-${TMPDIR:-/tmp}/remotefm1-aucoretest}
DD=$OUT/dd
RES=$OUT/$UDID
mkdir -p "$RES"
rm -f "$RES"/*.json "$RES"/*.png "$RES"/*.txt

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
GDIR=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" "$GROUP" 2>/dev/null || true)
echo "data: $DATA"
echo "group: ${GDIR:-none}"
if [ -n "$GDIR" ]; then rm -f "$GDIR"/aucoretest*.json "$GDIR"/lease.bin "$GDIR"/au-backend.txt; fi

say "launch -aucoretest"
T0=$(date +%s)
xcrun simctl launch "$UDID" "$BUNDLE" -aucoretest
shot=1
for _ in $(seq 1 180); do
    if [ -f "$DATA/Documents/aucoretest-shot-$shot.json" ]; then
        xcrun simctl io "$UDID" screenshot "$RES/shot-$shot.png" >/dev/null 2>&1 && \
            echo "screenshot $shot ($(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["what"])' \
                "$DATA/Documents/aucoretest-shot-$shot.json")): $RES/shot-$shot.png"
        shot=$((shot + 1))
    fi
    if [ -f "$DATA/Documents/aucoretest.json" ] && grep -q '"done" : true' "$DATA/Documents/aucoretest.json"; then break; fi
    sleep 1
done
[ -f "$DATA/Documents/aucoretest.json" ] || echo "no summary after 180 s"
sleep 1
xcrun simctl io "$UDID" screenshot "$RES/end.png" >/dev/null 2>&1 && echo "screenshot (end): $RES/end.png"

say "collect"
cp "$DATA"/Documents/aucoretest*.json "$RES/" 2>/dev/null || true
xcrun simctl spawn "$UDID" log show --info --style compact --start "$(date -r "$T0" '+%Y-%m-%d %H:%M:%S')" \
    --predicate 'subsystem == "com.quixotic7.remotefm1" OR (process == "RemoteFM1AU" AND messageType == error)' \
    >"$RES/log.txt" 2>&1 || true
echo "log: $RES/log.txt ($(wc -l <"$RES/log.txt" | tr -d ' ') lines)"

say "summary"
if [ -f "$RES/aucoretest.json" ]; then
    /usr/bin/python3 -I - "$RES/aucoretest.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(f"{s['device']} / {s['system']}, simulator {s['simulator']}, app pid {s['appPid']}, done {s['done']}")
for st in s['steps']:
    ok = {True: 'ok', False: 'NO', None: '--'}[st.get('ok')]
    print(f"[{ok}] {st['name']}: {st['detail']}")
bad = [st['name'] for st in s['steps'] if st.get('ok') is False]
print('result:', 'all ok' if not bad else 'FAILED: ' + ', '.join(bad))
PY
else
    echo "no aucoretest.json"
fi

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
if [ "$booted_here" = 1 ]; then say "shutdown"; xcrun simctl shutdown "$UDID"; fi
echo "results: $RES"
