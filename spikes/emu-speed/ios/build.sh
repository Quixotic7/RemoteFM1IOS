#!/bin/sh
# Build the iOS bench app: the Rust staticlib for aarch64-apple-ios, then the app (Release, automatic signing).
# The App Store Connect API key lets xcodebuild manage the provisioning profile without an Xcode sign-in.
# Packages: put felucca.fwsc, v15.fwsc, choralroot.fwsc, cr027-1core.fwsc in ../build/fwsc (git-ignored).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SPIKE=$(dirname "$HERE")
RUST=$(rustup which cargo | xargs dirname)
# Homebrew off the PATH: its rsync breaks Xcode's packaging
export PATH="$RUST:/usr/bin:/bin:/usr/sbin:/sbin"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
# FORK=1: link the bench against fm1-emu-fork (the prototype) instead of the unmodified crates
if [ "${FORK:-0}" = 1 ]; then
  (cd "$SPIKE/fm1-emu-fork" && cargo build --release --lib --target aarch64-apple-ios)
  LIB="$SPIKE/fm1-emu-fork/target/aarch64-apple-ios/release/libfm1bench.a"
else
  (cd "$SPIKE" && cargo build --release --lib --target aarch64-apple-ios)
  LIB="$SPIKE/target/aarch64-apple-ios/release/libfm1bench.a"
fi
SUFFIX=""; [ "${FORK:-0}" = 1 ] && SUFFIX="-fork"
KEY="$HOME/.appstoreconnect/private_keys/RemoteFM1_upload-AuthKey_HZ9LYR65Y2.p8"
xcodebuild -project "$HERE/RFMBenchEmu.xcodeproj" -scheme RFMBenchEmu -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$SPIKE/build/DerivedData$SUFFIX" \
  -allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID HZ9LYR65Y2 \
  -authenticationKeyIssuerID cc09f36e-1f30-40ac-a7c6-d7eea27a7bf5 OTHER_LDFLAGS="$LIB" build
echo "app: $SPIKE/build/DerivedData$SUFFIX/Build/Products/Release-iphoneos/RFMBenchEmu.app"
