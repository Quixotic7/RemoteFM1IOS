#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# Screenshots of the on-screen FM-1 for comparing with design/canvas, headless (simctl only: Simulator.app stays
# closed): builds, then on an iPhone and an iPad simulator launches the app once per state with its launch arguments
# (-view, -deck, -knobs, -source, -sheet, -sheetpage, -themeeditor, -theme, -orientation, -steps; M8: -demomap,
# -learn, -learnpick, -sheetscroll; Get firmware: -sheetpage getfirmware, and in Debug builds -catalogitem <id> and
# -catalogget <id>, which download from the live list) and saves a PNG per state. The core runs (ChoralRoot by
# default) so the real framebuffer shows; "-source fm1" uses the fake unit (the simulator's default backend), whose
# demo input presses keys by itself. A simulator this script booted is shut
# down again; one that was booted stays booted.
#
#   scripts/sim_shots.sh [OUT]          (default $TMPDIR/remotefm1-shots)
#   PHONE=udid PAD=udid                 the simulators (default: this project's RFM iPhone 17, RFM iPad Pro 11)
#   NOBUILD=1                           reuse the last build; WAIT=s seconds before each shot (default 5)
#   ONLY="phone"|"pad"                  one device
#   MATCH=text                          only the shots whose name contains it (e.g. MATCH=midi)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE=com.quixotic7.remotefm1
OUT=${1:-${TMPDIR:-/tmp}/remotefm1-shots}
DD=${DD:-$OUT/dd}
WAIT=${WAIT:-5}
PHONE=${PHONE:-CEB2B846-457C-4A33-AA1A-A287D30CDE2F}   # RFM iPhone 17
PAD=${PAD:-807A585A-7B1D-4850-8FF3-D8C4871A2F30}       # RFM iPad Pro 11
mkdir -p "$OUT"

say() { printf '== %s\n' "$*"; }

if [ -z "${NOBUILD:-}" ]; then
    say "build (simulator) -> $DD"
    xcodebuild -project "$ROOT/RemoteFM1.xcodeproj" -scheme RemoteFM1 -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" build >"$OUT/build.log" 2>&1 \
        || { tail -30 "$OUT/build.log"; exit 1; }
fi
APP=$DD/Build/Products/Debug-iphonesimulator/RemoteFM1.app

# name | launch arguments
PHONE_SHOTS=(
    "phone-full|-source phone -view full -orientation portrait"
    "phone-full-landscape|-source phone -view full -orientation landscape"
    "phone-controls-buttons|-source fm1 -view controls -deck buttons -knobs main -orientation portrait"
    "phone-controls-keys|-source fm1 -view controls -deck keys -knobs kn -steps -orientation portrait"
    "phone-controls-landscape|-source phone -view controls -deck buttons -orientation landscape"
    "phone-screen|-source fm1 -view screen -orientation portrait"
    "phone-sheet|-source fm1 -view full -sheet -orientation portrait"
    "phone-sheet-firmware|-source phone -view full -sheetpage firmware -orientation portrait"
    "phone-sheet-settings|-source phone -view full -sheetpage settings -orientation portrait"
    "phone-theme-editor|-source phone -view full -themeeditor -orientation portrait"
    "phone-full-midnight|-source phone -view full -theme Midnight -orientation portrait"
    "phone-full-cream-landscape|-source phone -view full -theme Cream -orientation landscape"
    "phone-sheet-midi|-source phone -view full -sheetpage midi -demomap -orientation portrait"
    "phone-sheet-midi-knobs|-source phone -view full -sheetpage midi -sheetscroll knobs -demomap -orientation portrait"
    "phone-sheet-midi-omx|-source phone -view full -sheetpage midi -sheetscroll omx -orientation portrait"
    "phone-sheet-midiinput|-source phone -view full -sheetpage midiinput -orientation portrait"
    "phone-midi-learn|-source phone -view full -demomap -learn -orientation portrait"
    "phone-midi-learn-kn1|-source phone -view full -demomap -learnpick KN1 -orientation portrait"
    "phone-midi-learn-kn3-controls|-source phone -view controls -knobs kn -learnpick KN3 -orientation portrait"
    "phone-midi-learn-landscape|-source phone -view full -demomap -learnpick SEQ -orientation landscape"
    # Get firmware (the live list; the last two after -catalogget has installed S1Vave)
    "phone-getfw-list|-source phone -view full -sheetpage getfirmware -orientation portrait"
    "phone-getfw-detail|-source phone -view full -catalogitem s1vave -orientation portrait"
    "phone-getfw-footer|-source phone -view full -sheetpage getfirmware -sheetscroll footer -orientation portrait"
    "phone-getfw-installed-firmware|-source phone -view full -sheetpage firmware -catalogget s1vave -orientation portrait"
    "phone-getfw-installed-detail|-source phone -view full -catalogitem s1vave -orientation portrait"
)
PAD_SHOTS=(
    "pad-full-landscape|-source phone -view full -orientation landscape"
    "pad-full-portrait|-source fm1 -view full -theme Midnight -orientation portrait"
    "pad-controls-portrait|-source phone -view controls -deck keys -orientation portrait"
    "pad-screen-landscape|-source phone -view screen -orientation landscape"
    "pad-sheet-landscape|-source phone -view full -sheet -orientation landscape"
    "pad-theme-editor|-source phone -view full -themeeditor -orientation portrait"
    "pad-sheet-midi|-source phone -view full -sheetpage midi -demomap -orientation portrait"
    "pad-sheet-midi-knobs|-source phone -view full -sheetpage midi -sheetscroll knobs -demomap -orientation portrait"
    "pad-midi-learn-kn1|-source phone -view full -demomap -learnpick KN1 -orientation landscape"
)

run_device() {
    local udid=$1 tag=$2
    shift 2
    local shots=("$@")
    local booted_here=0
    if ! xcrun simctl list devices booted | grep -q "$udid"; then
        say "boot $udid"
        xcrun simctl boot "$udid"
        booted_here=1
    fi
    xcrun simctl bootstatus "$udid" >/dev/null
    xcrun simctl list devices | grep "$udid" | sed 's/^ */device: /'
    xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$udid" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl install "$udid" "$APP"
    for s in "${shots[@]}"; do
        local name=${s%%|*} args=${s#*|}
        [[ -z ${MATCH:-} || $name == *"$MATCH"* ]] || continue
        xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        xcrun simctl launch "$udid" "$BUNDLE" $args >/dev/null
        sleep "$WAIT"
        xcrun simctl io "$udid" screenshot "$OUT/$name.png" >/dev/null 2>&1 || { echo "no screenshot: $name"; continue; }
        # an iPad refuses a programmatic rotation (its windowing mode): the app then draws the faceplate turned in
        # the portrait window, and the PNG is turned back here
        if [[ $args == *"-orientation landscape"* ]]; then
            w=$(sips -g pixelWidth "$OUT/$name.png" | awk '/pixelWidth/ {print $2}')
            h=$(sips -g pixelHeight "$OUT/$name.png" | awk '/pixelHeight/ {print $2}')
            [ "$w" -lt "$h" ] && sips -r 90 "$OUT/$name.png" >/dev/null
        fi
        echo "$OUT/$name.png ($args)"
    done
    xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
    if [ "$booted_here" = 1 ]; then say "shutdown $udid"; xcrun simctl shutdown "$udid"; fi
}

[ "${ONLY:-phone}" = pad ] || run_device "$PHONE" phone "${PHONE_SHOTS[@]}"
[ "${ONLY:-pad}" = phone ] || run_device "$PAD" pad "${PAD_SHOTS[@]}"
echo "shots: $OUT"
