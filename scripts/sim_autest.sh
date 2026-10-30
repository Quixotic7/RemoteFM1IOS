#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# M2's headless check on one simulator: build, boot (simctl only: Simulator.app stays closed), install, launch with
# -autest, wait for the AU test's summary, print it, take two screenshots (the AU's view, then its Bluetooth panel),
# save the log, and shut the simulator down again if this script booted it.
#
#   scripts/sim_autest.sh [UDID]        (default: RFM iPhone 17, CEB2B846-...)
#   OUT=dir   where the results go (default $TMPDIR/remotefm1-autest); NOBUILD=1 reuses the last build
#   AUPAGE=midi | keychannel | midimode | learn | learn:KN1 | window | sheet:midi   (M8) the second screenshot is
#             that page of the AU's view
#             (au-page.png), not the Bluetooth panel (window: the sheet's Mac-only Window section, in a Debug build)
#
# The app's -autest never starts the FM-1 link; its probes never send MIDI or connect to an endpoint.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE=com.quixotic7.remotefm1
GROUP=group.com.quixotic7.remotefm1
UDID=${1:-CEB2B846-457C-4A33-AA1A-A287D30CDE2F}   # (RFM iPhone 17, this project's own simulator)
OUT=${OUT:-${TMPDIR:-/tmp}/remotefm1-autest}
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
if [ -n "$GDIR" ]; then rm -f "$GDIR"/probe-*.json "$GDIR"/autest*.json "$GDIR"/lease-probe.bin; fi

say "launch -autest${AUPAGE:+ -aupage $AUPAGE}"
T0=$(date +%s)
xcrun simctl launch "$UDID" "$BUNDLE" -autest ${AUPAGE:+-aupage "$AUPAGE"}
for _ in $(seq 1 120); do
    if [ -f "$DATA/Documents/autest.json" ] && grep -q '"done" : true' "$DATA/Documents/autest.json"; then break; fi
    sleep 1
done
[ -f "$DATA/Documents/autest.json" ] || echo "no summary after 120 s"
sleep 2
xcrun simctl io "$UDID" screenshot "$RES/au.png" >/dev/null 2>&1 && echo "screenshot: $RES/au.png"
if [ -n "${AUPAGE:-}" ]; then
    for _ in $(seq 1 20); do [ -f "$DATA/Documents/autest-page.json" ] && break; sleep 1; done
    sleep 2
    xcrun simctl io "$UDID" screenshot "$RES/au-page.png" >/dev/null 2>&1 && echo "screenshot: $RES/au-page.png"
else
    for _ in $(seq 1 20); do [ -f "$DATA/Documents/autest-bt.json" ] && break; sleep 1; done
    sleep 2
    xcrun simctl io "$UDID" screenshot "$RES/bluetooth.png" >/dev/null 2>&1 && echo "screenshot: $RES/bluetooth.png"
fi

say "collect"
cp "$DATA"/Documents/*.json "$RES/" 2>/dev/null || true
if [ -n "$GDIR" ]; then
    for f in "$GDIR"/*.json; do [ -f "$f" ] && cp "$f" "$RES/group-$(basename "$f")"; done
fi
# the extension's own container (where its probe file goes when the App Group doesn't work)
PKP=$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers/Data/PluginKitPlugin
find "$PKP" -name 'probe-ext.json' -newer "$APP/Info.plist" 2>/dev/null | while read -r f; do
    cp "$f" "$RES/ext-container-probe-ext.json"
    echo "extension container: $(dirname "$f")"
done
xcrun simctl spawn "$UDID" log show --info --style compact --start "$(date -r "$T0" '+%Y-%m-%d %H:%M:%S')" \
    --predicate 'subsystem == "com.quixotic7.remotefm1" OR (process == "RemoteFM1AU" AND messageType == error)' \
    >"$RES/log.txt" 2>&1 || true
echo "log: $RES/log.txt ($(wc -l <"$RES/log.txt" | tr -d ' ') lines)"

say "summary"
if [ -f "$RES/autest.json" ]; then
    /usr/bin/python3 -I - "$RES/autest.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(f"{s['device']} / {s['system']}, simulator {s['simulator']}, app pid {s['appPid']}, done {s['done']}")
for c in s.get('components', []):
    print('component:', c)
for st in s['steps']:
    ok = {True: 'ok', False: 'NO', None: '--'}[st.get('ok')]
    print(f"[{ok}] {st['name']}: {st['detail']}")
PY
else
    echo "no autest.json"
fi

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
if [ "$booted_here" = 1 ]; then say "shutdown"; xcrun simctl shutdown "$UDID"; fi
echo "results: $RES"
