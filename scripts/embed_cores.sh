#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# The app target's "Embed core slots" build phase: builds the cores for this platform if needed
# (scripts/build_cores.sh, incremental, in a clean environment so Xcode's settings don't reach CMake), then copies
# the slot frameworks into the app's Frameworks folder and signs each one (ad hoc on the simulator, or with no
# signing identity). A slot is copied and signed again only when its build changed.
#
# Which cores: every core built (build/cores/<plat>/cores.txt), or with the build setting RFM_STORE_BUILD=YES (App
# Store / TestFlight: scripts/testflight.sh) only those in cores/store-cores.txt. The build fails if that list names a
# core that wasn't built, or if a core outside it would end up in the app. Slots of cores not in this build's set
# (left by the other mode, or a core no longer built) are removed from the app's Frameworks. A store build takes a
# core's store variant (build/cores/<plat>/frameworks-store, the same slot names: Saadet without its vendor factory
# banks) when there is one, else its normal slots; a full build never does. A slot whose source changed (the other
# variant) is copied again.
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
STORE_LIST=$ROOT/cores/store-cores.txt
NSLOTS=4

env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    ${CR_PYTHON:+CR_PYTHON="$CR_PYTHON"} "$ROOT/scripts/build_cores.sh" "$P"

SRC=$ROOT/build/cores/$P/frameworks
SRC_STORE=$ROOT/build/cores/$P/frameworks-store
DST=$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH
STAMPS=$DERIVED_FILE_DIR/core-slots
IDENTITY=${EXPANDED_CODE_SIGN_IDENTITY:--}

built=$(awk '$1 !~ /_store$/ {print $1}' "$ROOT/build/cores/$P/cores.txt")   # (<id>_store: a variant, not a core)
if [ "${RFM_STORE_BUILD:-NO}" = YES ]; then
    mode=store
    want=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$STORE_LIST" | grep -v '^$' || true)
    [ -n "$want" ] || { echo "error: embed_cores.sh: $STORE_LIST names no core"; exit 1; }
    for id in $want; do
        printf '%s\n' "$built" | grep -qxF "$id" \
            || { echo "error: embed_cores.sh: store core '$id' ($STORE_LIST) was not built for $P"; exit 1; }
    done
else
    mode=full
    want=$built
fi
in_set() { printf '%s\n' "$want" | grep -qxF "$1"; }

mkdir -p "$DST" "$STAMPS"
removed=0
# slots of cores outside this build's set: removed (exact paths; the stamp goes too)
for f in "$DST"/FM1Core_*.framework; do
    [ -d "$f" ] || continue
    name=$(basename "$f" .framework)
    id=${name#FM1Core_}
    n=${id##*_}
    id=${id%_*}
    if ! in_set "$id" || [ "$n" -lt 1 ] || [ "$n" -gt $NSLOTS ]; then
        rm -r "$f"
        rm -f "$STAMPS/$name".*
        echo "embed_cores: removed $name (not in this $mode build)"
        removed=$((removed + 1))
    fi
done

n=0
variants=""
for id in $want; do
    from=$SRC variant=full
    if [ $mode = store ] && [ -f "$SRC_STORE/FM1Core_${id}_1.framework/FM1Core_${id}_1" ]; then
        from=$SRC_STORE variant=store
        variants="$variants $id"
    fi
    for s in $(seq 1 $NSLOTS); do
        name=FM1Core_${id}_$s
        f=$from/$name.framework
        [ -f "$f/$name" ] || { echo "error: embed_cores.sh: $f is missing"; exit 1; }
        stamp=$STAMPS/$name.$variant.$(printf '%s' "$IDENTITY" | shasum | cut -c1-12)
        if [ -f "$stamp" ] && [ -d "$DST/$name.framework" ] && [ ! "$f/$name" -nt "$stamp" ] && [ ! "$f/Info.plist" -nt "$stamp" ]; then
            continue
        fi
        if [ -d "$DST/$name.framework" ]; then rm -r "$DST/$name.framework"; fi
        ditto "$f" "$DST/$name.framework"
        codesign --force --sign "$IDENTITY" --timestamp=none "$DST/$name.framework"
        rm -f "$STAMPS/$name".*                     # (the other variant's stamp: its copy is gone)
        touch "$stamp"
        n=$((n + 1))
    done
done

# what is in the app now: this build's set, nothing else
have=$(cd "$DST" && ls -d FM1Core_*.framework | sed -E 's/^FM1Core_(.*)_[0-9]+\.framework$/\1/' | sort -u)
for id in $have; do
    in_set "$id" || { echo "error: embed_cores.sh: $id is in $DST but not in this $mode build"; exit 1; }
done
# FM1CoreSlots.txt (the phase's declared output): rewritten when a slot changed, so Xcode signs the app again (it does
# not see the slots themselves; a stale seal fails codesign --verify and a device install)
MANIFEST=$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/FM1CoreSlots.txt
if [ $n -gt 0 ] || [ $removed -gt 0 ] || [ ! -f "$MANIFEST" ]; then
    { echo "# the core slots embedded ($mode build), scripts/embed_cores.sh"; echo "# store variants:$variants"
      (cd "$DST" && ls -d FM1Core_*.framework); } \
        >"$MANIFEST"
fi
echo "embed_cores: $P, $mode build: $(echo $have)${variants:+ (store variants:$variants)} ($(ls -d "$DST"/FM1Core_*.framework | wc -l | tr -d ' ') slots in $DST, $n copied and signed)"
