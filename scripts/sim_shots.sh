#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# Screenshots of the on-screen FM-1 for comparing with design/canvas, headless (simctl only: Simulator.app stays
# closed): builds, then on an iPhone and an iPad simulator launches the app once per state with its launch arguments
# (-view, -deck, -knobs, -source, -sheet, -sheetpage, -themeeditor, -theme, -orientation, -steps; M8: -demomap,
# -learn, -learnpick, -sheetscroll; Get firmware: -sheetpage getfirmware, and in Debug builds -catalogitem <id> and
# -catalogget <id>, which download from the live list; the installer: -sheetpage install, -installdemo; the cartridge page: -sheetpage cart, DEBUG's -cartdemo) and saves a PNG
# per state ("name@s": that shot waits s seconds). The iPhone fixes: -sheetpage keychannel | midimode, DEBUG's
# -firmwareedit [ask], -askreset, -safetydemo, -statesdemo, -statessave (a "-fwedit" shot first copies the AMB test file into Documents/Firmware) and -fm1prompt
# install | unanswered | bluetooth | update. The core runs (ChoralRoot by default) so the real framebuffer shows;
# "-source fm1" uses the fake unit (the simulator's default backend), whose demo input presses keys by itself. A
# simulator this script booted is shut
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
    "phone-names-choralroot|-source phone -core choralroot -view controls -deck buttons -orientation portrait"
    "phone-names-fizz|-source phone -core fizz -view controls -deck buttons -orientation portrait"
    "phone-names-choralroot-full|-source phone -core choralroot -view full -orientation portrait"
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
    "phone-sheet-keychannel|-source phone -view full -sheetpage keychannel -orientation portrait"
    "phone-sheet-midimode|-source phone -view full -sheetpage midimode -demomap -orientation portrait"
    "phone-firmware-fwedit|-source phone -view full -firmwareedit -orientation portrait"
    # PLAN.md section 18: Reset firmware… asked; the Safety copies page (DEBUG -safetydemo: made-up copies)
    "phone-firmware-reset|-source phone -view full -sheetpage firmware -sheetscroll reset -askreset -orientation portrait"
    "phone-safety-copies|-source phone -view full -sheetpage safetycopies -safetydemo -orientation portrait"
    # section 18 step 2: the States page (DEBUG -statesdemo: made-up states, one of another version; -statessave: Save as… open)
    "phone-states|-source phone -view full -sheetpage states -statesdemo -orientation portrait"
    "phone-states-save|-source phone -view full -sheetpage states -statessave -orientation portrait"
    "phone-firmware-fwedit-ask|-source phone -view full -firmwareedit ask -orientation portrait"
    "phone-prompt-install|-source fm1 -view full -fm1prompt install -orientation portrait"
    "phone-prompt-unanswered|-source fm1 -view full -fm1prompt unanswered -orientation portrait"
    "phone-prompt-bluetooth|-source fm1 -view full -fm1prompt bluetooth -orientation portrait"
    "phone-prompt-update|-source fm1 -view full -fm1prompt update -orientation portrait"
    # Get firmware (the live list; the last two after -catalogget has installed S1Vave)
    "phone-getfw-list|-source phone -view full -sheetpage getfirmware -orientation portrait"
    "phone-getfw-detail|-source phone -view full -catalogitem s1vave -orientation portrait"
    "phone-getfw-footer|-source phone -view full -sheetpage getfirmware -sheetscroll footer -orientation portrait"
    "phone-getfw-installed-firmware|-source phone -view full -sheetpage firmware -catalogget s1vave -orientation portrait"
    "phone-getfw-installed-detail|-source phone -view full -catalogitem s1vave -orientation portrait"
    # Install RemoteFM1 on the FM-1 (DEBUG's -installdemo on FM1Kit's SimulatedFM1; the list and the package come
    # from remotefm1.com); "@s": this shot's wait
    "phone-install@4|-source fm1 -view full -sheetpage install -orientation portrait"
    "phone-install-check@10|-source fm1 -view full -sheetpage install -installdemo check -orientation portrait"
    "phone-install-writing@9|-source fm1 -view full -sheetpage install -installdemo writing -orientation portrait"
    "phone-install-finished@45|-source fm1 -view full -sheetpage install -installdemo finished -orientation portrait"
    "phone-cart|-source fm1 -view full -sheetpage cart -cartdemo -orientation portrait"
    "phone-install-cutoff@25|-source fm1 -view full -sheetpage install -installdemo cutoff -orientation portrait"
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
        local name=${s%%|*} args=${s#*|} wait=$WAIT
        if [[ $name == *@* ]]; then wait=${name#*@}; name=${name%@*}; fi
        [[ -z ${MATCH:-} || $name == *"$MATCH"* ]] || continue
        xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
        if [[ $name == *-fwedit* ]]; then                # (an imported file to delete)
            local data
            data=$(xcrun simctl get_app_container "$udid" "$BUNDLE" data)
            mkdir -p "$data/Documents/Firmware"
            cp "$ROOT/RFMKit/Tests/RFMKitTests/Fixtures/amb-1.3.rfm1" "$data/Documents/Firmware/"
        fi
        # shellcheck disable=SC2086
        xcrun simctl launch "$udid" "$BUNDLE" $args >/dev/null
        sleep "$wait"
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
