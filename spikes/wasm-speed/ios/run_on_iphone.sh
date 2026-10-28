#!/bin/sh
# Install and run the bench on the iPhone, then copy its results back: build/iphone_results.txt
#   ios/run_on_iphone.sh [SPEC words..]     (the device must be unlocked; the app keeps the screen on while it runs)
# Takes turns with other device users through a lock directory (IPHONE_LOCK); gives up after 30 min of waiting.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
DEV=${DEVICE:-00008110-0018695122F9801E}
APP=$HERE/build/xcode/Build/Products/Release-iphoneos/RFMBenchWasm.app
ID=com.quixotic7.rfmbench.wasm
LOCK=${IPHONE_LOCK:-/private/tmp/claude-501/-Volumes-Q7Media-2025-Projects-Github-ChoralRootFM1-RemoteFM1IOS/b4b42474-569a-42e5-8a1d-11bac8277434/scratchpad/iphone.lock}
n=0
until mkdir "$LOCK" 2>/dev/null; do
    n=$((n + 1)); [ $n -gt 90 ] && { echo "the iPhone lock stayed taken for 30 min"; exit 1; }
    sleep 20
done
trap 'rmdir "$LOCK"' EXIT
if xcrun devicectl device info lockState --device "$DEV" 2>&1 | grep -q "passcodeRequired: true"; then
    echo "the iPhone is locked: unlock it and run this again"; exit 1
fi
xcrun devicectl device install app --device "$DEV" "$APP" > /dev/null
# shellcheck disable=SC2068
xcrun devicectl device process launch --device "$DEV" --terminate-existing --console "$ID" $@ > "$HERE/build/iphone_console.txt" 2>&1 &
CON=$!
t=0
until grep -q "^DONE" "$HERE/build/iphone_console.txt" 2>/dev/null; do
    if grep -qE "failed to launch|Locked" "$HERE/build/iphone_console.txt" 2>/dev/null; then
        cat "$HERE/build/iphone_console.txt"; exit 1
    fi
    t=$((t + 5)); [ $t -gt 1200 ] && { echo "no DONE after 20 min"; break; }
    sleep 5
done
kill $CON 2>/dev/null || true
xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$ID" \
    --source Documents/results.txt --destination "$HERE/build/iphone_results.txt" > /dev/null
grep -vE "^  pass|^boot:|^pool:|^touch:|^chord:" "$HERE/build/iphone_results.txt"
