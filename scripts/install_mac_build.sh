#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# Builds the store configuration for this Mac ("Designed for iPad", development-signed) and installs it as
# /Applications/RemoteFM1.app (the Wrapper layout an iPad app needs on a Mac), registers its AU and makes the AU
# registry rescan, without launching anything. So the AU can be tried in a Mac host (Ableton, Logic) without TestFlight.
#
#   ASC_KEY_ID=... ASC_ISSUER_ID=... scripts/install_mac_build.sh
#
# Once per Mac (and when the development profile is renewed): run the app from Xcode on "My Mac (Designed for iPad)",
# which installs the profiles macOS checks before it starts the AU ("No matching profile found" otherwise). A
# TestFlight copy in /Applications must be moved to the Trash first. Unlike the TestFlight install, this copy runs
# from /Applications itself, where the AU may read the app's folder: sandbox problems of the store install (build 7's
# missing firmwares) don't show here.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY=$(ls ~/.appstoreconnect/private_keys/*AuthKey_"$ASC_KEY_ID".p8 | head -1)
DD=$ROOT/build/mac-local
DEST=/Applications/RemoteFM1.app
export PATH=/usr/bin:/bin:/usr/sbin:/sbin       # (Homebrew's rsync breaks Xcode's packaging: testflight.sh)

xcodebuild -project "$ROOT/RemoteFM1.xcodeproj" -scheme RemoteFM1 -configuration Release \
    -destination 'platform=macOS,arch=arm64,variant=Designed for iPad' -derivedDataPath "$DD" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    RFM_STORE_BUILD=YES build

APP=$DD/Build/Products/Release-iphoneos/RemoteFM1.app
if [ -e "$DEST" ] && [ ! -w "$DEST/Wrapper" ]; then
    echo "error: $DEST is another install (TestFlight?): move it to the Trash first"; exit 1
fi
pkill -f "Wrapper/RemoteFM1.app/RemoteFM1$" || true
mkdir -p "$DEST/Wrapper"
ditto "$APP" "$DEST/Wrapper/RemoteFM1.app"
[ -L "$DEST/WrappedBundle" ] || ln -s Wrapper/RemoteFM1.app "$DEST/WrappedBundle"
pluginkit -a "$DEST/Wrapper/RemoteFM1.app/PlugIns/RemoteFM1AU.appex"
killall -9 AudioComponentRegistrar 2>/dev/null || true   # (the AU registry rescans; launchd starts it again)
echo "installed $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Info.plist")) at $DEST"
