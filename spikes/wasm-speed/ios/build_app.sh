#!/bin/sh
# Build the iPhone app (after ../build_wasm.sh, ../build_wamr.sh ios and WAMR=1 ../build_host.sh ios):
# build/xcode/Build/Products/Release-iphoneos/RFMBenchWasm.app, team NCX6SLSFQJ, automatic signing through the App Store
# Connect API key (the CLI has no Xcode sign-in). Homebrew stays off the PATH: its rsync breaks Xcode's packaging.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
KEY=${ASC_KEY:-$HOME/.appstoreconnect/private_keys/RemoteFM1_upload-AuthKey_HZ9LYR65Y2.p8}
cd "$HERE"
PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -project RFMBenchWasm.xcodeproj -scheme RFMBenchWasm -configuration Release \
    -destination "generic/platform=iOS" -derivedDataPath ../build/xcode -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY" -authenticationKeyID HZ9LYR65Y2 \
    -authenticationKeyIssuerID cc09f36e-1f30-40ac-a7c6-d7eea27a7bf5 build > ../build/xcodebuild.log 2>&1 ||
    { grep -E "error" ../build/xcodebuild.log | head; exit 1; }
echo "built $HERE/../build/xcode/Build/Products/Release-iphoneos/RFMBenchWasm.app"
