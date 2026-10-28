#!/bin/sh
# Install and run the bench app on the iPhone, then copy Documents/results.txt back to ../build/OUT.
# usage: ios/run_device.sh OUT.txt [launch args: quick, mhz=N, only=felucca,cr027-1core, split=0]
# LOCK: a directory shared with other agents using the same phone (mkdir = take, rmdir = give back).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SPIKE=$(dirname "$HERE")
DEV=00008110-0018695122F9801E
BID=com.quixotic7.rfmbench.emu
OUT="$SPIKE/build/$1"; shift
APP="$SPIKE/build/DerivedData${FORK:+-fork}/Build/Products/Release-iphoneos/RFMBenchEmu.app"
LOCK=${LOCK:-/private/tmp/claude-501/-Volumes-Q7Media-2025-Projects-Github-ChoralRootFM1-RemoteFM1IOS/b4b42474-569a-42e5-8a1d-11bac8277434/scratchpad/iphone.lock}
if xcrun devicectl device info lockState --device $DEV 2>&1 | grep -q "passcodeRequired: true"; then
  echo "iPhone is locked (passcodeRequired: true): not running"; exit 2
fi
i=0
until mkdir "$LOCK" 2>/dev/null; do
  i=$((i + 1)); [ $i -gt 90 ] && { echo "iPhone lock still held after 30 min"; exit 3; }
  sleep 20
done
trap 'rmdir "$LOCK"' EXIT
xcrun devicectl device install app --device $DEV "$APP" > "$OUT.install.log" 2>&1 || { echo "install failed"; cat "$OUT.install.log"; exit 4; }
xcrun devicectl device process launch --device $DEV --terminate-existing --console $BID exit "$@" > "$OUT.console.log" 2>&1
echo "launch rc=$?"
xcrun devicectl device copy from --device $DEV --domain-type appDataContainer --domain-identifier $BID \
  --source Documents/results.txt --destination "$OUT" > "$OUT.copy.log" 2>&1 && echo "results: $OUT"
