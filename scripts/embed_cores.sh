#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# The app target's "Embed core slots" build phase: builds the cores for this platform if needed
# (scripts/build_cores.sh, incremental, in a clean environment so Xcode's settings don't reach CMake), then copies
# the slot frameworks into the app's Frameworks folder and signs each one (ad hoc on the simulator, or with no
# signing identity). A slot is copied and signed again only when its build changed.
#
# M4: the AUv3 extension loads the same frameworks from the app (<app>/PlugIns/RemoteFM1AU.appex/../../Frameworks;
# RFMCore's rfms_scan looks there from inside an appex). Nothing is embedded in the extension itself.
set -euo pipefail

case "${PLATFORM_NAME:-}" in
    iphoneos) P=ios ;;
    iphonesimulator) P=sim ;;
    *) echo "error: embed_cores.sh: unsupported platform '${PLATFORM_NAME:-}'"; exit 1 ;;
esac
ROOT=${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}

env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    ${CR_PYTHON:+CR_PYTHON="$CR_PYTHON"} "$ROOT/scripts/build_cores.sh" "$P"

SRC=$ROOT/build/cores/$P/frameworks
DST=$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH
STAMPS=$DERIVED_FILE_DIR/core-slots
IDENTITY=${EXPANDED_CODE_SIGN_IDENTITY:--}
mkdir -p "$DST" "$STAMPS"
n=0
for f in "$SRC"/FM1Core_*.framework; do
    name=$(basename "$f" .framework)
    stamp=$STAMPS/$name.$(printf '%s' "$IDENTITY" | shasum | cut -c1-12)
    if [ -f "$stamp" ] && [ -d "$DST/$name.framework" ] && [ ! "$f/$name" -nt "$stamp" ] && [ ! "$f/Info.plist" -nt "$stamp" ]; then
        continue
    fi
    rm -rf "$DST/$name.framework"
    ditto "$f" "$DST/$name.framework"
    codesign --force --sign "$IDENTITY" --timestamp=none "$DST/$name.framework"
    touch "$stamp"
    n=$((n + 1))
done
echo "embed_cores: $P, $(ls -d "$DST"/FM1Core_*.framework | wc -l | tr -d ' ') slots in $DST ($n copied and signed)"
