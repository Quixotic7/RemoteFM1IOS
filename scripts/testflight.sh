#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# Archives a Release build and uploads it to App Store Connect for TestFlight (internal and external testers;
# INTERNAL_ONLY=1 marks it internal only). A store build
# (RFM_STORE_BUILD=YES): only the cores in cores/store-cores.txt are embedded (scripts/embed_cores.sh); the archive's
# cores are printed and checked against that list before the upload, and a core's store variant (Saadet's) against
# build/cores/ios/frameworks-store.
#
#   ASC_KEY_ID=... ASC_ISSUER_ID=... scripts/testflight.sh [build-number]
#
# Needs: an App Store Connect API key (.p8) in ~/.appstoreconnect/private_keys (name ending in
# AuthKey_<ASC_KEY_ID>.p8), an Apple Distribution certificate in the keychain, and App Store profiles
# named "RemoteFM1 App Store" and "RemoteFM1 AU App Store" (an App Manager key can't use Xcode's
# cloud signing, so the export signs manually). The build number defaults to CURRENT_PROJECT_VERSION
# and must be higher than the last upload.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY=$(ls ~/.appstoreconnect/private_keys/*AuthKey_"$ASC_KEY_ID".p8 | head -1)
OUT=${OUT:-$ROOT/build/testflight}
AUTH=(-authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
BUILD=()
INTERNAL=false
[ "${INTERNAL_ONLY:-0}" = 1 ] && INTERNAL=true
[ $# -ge 1 ] && BUILD=(CURRENT_PROJECT_VERSION="$1")

# Homebrew's rsync 3.x breaks Xcode's .ipa step (Apple's rsync runs the first rsync on PATH as its server).
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

rm -rf "$OUT" && mkdir -p "$OUT"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>NCX6SLSFQJ</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>com.quixotic7.remotefm1</key><string>RemoteFM1 App Store</string>
		<key>com.quixotic7.remotefm1.au</key><string>RemoteFM1 AU App Store</string>
	</dict>
	<key>uploadSymbols</key><true/>
	<key>testFlightInternalTestingOnly</key><$INTERNAL/>
</dict>
</plist>
EOF

xcodebuild -project "$ROOT/RemoteFM1.xcodeproj" -scheme RemoteFM1 -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$OUT/RemoteFM1.xcarchive" \
    -allowProvisioningUpdates "${AUTH[@]}" ${BUILD[@]+"${BUILD[@]}"} RFM_STORE_BUILD=YES archive

# the cores in the archive: exactly the store list's
FW=$OUT/RemoteFM1.xcarchive/Products/Applications/RemoteFM1.app/Frameworks
have=$(cd "$FW" && ls -d FM1Core_*.framework | sed -E 's/^FM1Core_(.*)_[0-9]+\.framework$/\1/' | sort -u)
want=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ROOT/cores/store-cores.txt" | grep -v '^$' | sort -u)
echo "cores in the archive: $(echo $have) ($(ls -d "$FW"/FM1Core_*.framework | wc -l | tr -d ' ') slots)"
[ "$have" = "$want" ] || { echo "error: the archive's cores are not cores/store-cores.txt's ($(echo $want))"; exit 1; }
# a core with a store variant (build/cores/ios/frameworks-store: Saadet without the vendor banks): its slots are that
for f in "$ROOT"/build/cores/ios/frameworks-store/FM1Core_*.framework; do
    [ -d "$f" ] || continue
    cmp -s "$f/Info.plist" "$FW/$(basename "$f")/Info.plist" \
        || { echo "error: $(basename "$f") in the archive is not the store variant"; exit 1; }
done
xcodebuild -exportArchive -archivePath "$OUT/RemoteFM1.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" "${AUTH[@]}"
