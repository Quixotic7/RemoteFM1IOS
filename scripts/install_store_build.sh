#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# Builds the store configuration (Release, RFM_STORE_BUILD=YES: the cores in cores/store-cores.txt, as
# scripts/testflight.sh archives it) and installs it on a connected iPhone, so the owner can try what testers get
# before uploading. It is development-signed, not the App Store signature: the code, the cores and the settings are the
# same as the TestFlight build; for the very binary testers get, install that build from TestFlight.
#
#   ASC_KEY_ID=... ASC_ISSUER_ID=... scripts/install_store_build.sh [device-udid]
#
# The API key (as in testflight.sh) lets xcodebuild sign from the command line. The device must be unlocked to launch.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY=$(ls ~/.appstoreconnect/private_keys/*AuthKey_"$ASC_KEY_ID".p8 | head -1)
DEV=${1:-00008110-0018695122F9801E}
DD=$ROOT/build/store-device
AUTH=(-authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

# Homebrew's rsync 3.x breaks Xcode's packaging (see testflight.sh)
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

xcodebuild -project "$ROOT/RemoteFM1.xcodeproj" -scheme RemoteFM1 -configuration Release \
    -destination "generic/platform=iOS" -derivedDataPath "$DD" \
    -allowProvisioningUpdates "${AUTH[@]}" RFM_STORE_BUILD=YES build

APP=$DD/Build/Products/Release-iphoneos/RemoteFM1.app
FW=$APP/Frameworks
have=$(cd "$FW" && ls -d FM1Core_*.framework | sed -E 's/^FM1Core_(.*)_[0-9]+\.framework$/\1/' | sort -u)
want=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ROOT/cores/store-cores.txt" | grep -v '^$' | sort -u)
echo "cores in the build: $(echo $have)"
[ "$have" = "$want" ] || { echo "error: the build's cores are not cores/store-cores.txt's ($(echo $want))"; exit 1; }

xcrun devicectl device install app --device "$DEV" "$APP"
echo "installed the store build ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Info.plist"))) on $DEV"
