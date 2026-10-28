#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# Builds the FM-1 cores (ChoralRoot, Felucca, Melodee) with cores/CMakeLists.txt and makes each one's four slot
# frameworks (PLAN.md section 3): FM1Core_<id>_<n>.framework, n = 1..4, the same code with its own install name
# (@rpath/FM1Core_<id>_<n>.framework/FM1Core_<id>_<n>) and bundle id (com.quixotic7.remotefm1.core.<id>.<n>).
#
#   scripts/build_cores.sh [ios] [sim] [macos]     (default: all three)
#
#   ios     iOS device, arm64        -> build/cores/ios/frameworks
#   sim     iOS simulator, arm64     -> build/cores/sim/frameworks
#   macos   macOS, arm64 (the Mac tests: cd RFMKit && swift test) -> build/cores/macos/frameworks
#
# Incremental: the firmware trees are synced (rsync, times kept), CMake rebuilds what changed, and a slot is copied
# again only when its library is newer. The iOS slots are signed by the app's build phase (scripts/embed_cores.sh);
# the macOS ones are signed ad hoc here (arm64 macOS loads signed code only).
#
# vendor/ stays untouched: the generate steps write <tree>/build/gen, so the build runs on a copy of the parts of
# vendor/FM1VST it needs, laid out as there (build/cores/src: cmake/, core-api/, core-glue/, engine/, tests/ and
# cores/<tree>; the glue includes the firmware by relative paths and names the trees ${CMAKE_SOURCE_DIR}/cores/<name>),
# with cores/CMakeLists.txt as its top. Each tree's copy gets a .git file pointing at its submodule's git dir, so
# fm1_add_core reads the right commit. CR_PYTHON=... picks the python with Pillow and fontTools.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FM1VST=$ROOT/vendor/FM1VST
B=$ROOT/build/cores
SRC=$B/src
PY=${CR_PYTHON:-/Library/Frameworks/Python.framework/Versions/3.11/bin/python3}
CMAKE=${CMAKE:-$(command -v cmake || echo /opt/homebrew/bin/cmake)}
MIN_IOS=17.0
MIN_MAC=14.0
NSLOTS=4
JOBS=$(sysctl -n hw.ncpu)

say() { printf '== %s\n' "$*"; }

sync_sources() {
    mkdir -p "$SRC/cores"
    for d in cmake core-api core-glue engine tests; do rsync -a --delete "$FM1VST/$d/" "$SRC/$d/"; done
    for t in ChoralRootFM1 Felucca melodee; do
        local from=$FM1VST/cores/$t
        [ -n "$(ls -A "$from" 2>/dev/null)" ] || { echo "$from is empty: git -C vendor/FM1VST submodule update --init --recursive cores/$t"; exit 1; }
        rsync -a --delete --exclude=/build/ --exclude=.git "$from/" "$SRC/cores/$t/"
        local gd
        gd=$(git -C "$from" rev-parse --absolute-git-dir)
        local want="gitdir: $gd"
        if [ "$(cat "$SRC/cores/$t/.git" 2>/dev/null || true)" != "$want" ]; then echo "$want" >"$SRC/cores/$t/.git"; fi
    done
    cmp -s "$ROOT/cores/CMakeLists.txt" "$SRC/CMakeLists.txt" || cp "$ROOT/cores/CMakeLists.txt" "$SRC/CMakeLists.txt"
}

# a slot's Info.plist (a minimal embedded framework)
plist() {   # id n version platform
    local id=$1 n=$2 ver=$3 plat=$4
    local short
    short=$(printf '%s' "$ver" | sed -E 's/[^0-9.].*$//; s/^$/0/')
    local minkey="MinimumOSVersion" minval=$MIN_IOS
    [ "$plat" = MacOSX ] && minkey="LSMinimumSystemVersion" && minval=$MIN_MAC
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>FM1Core_${id}_${n}</string>
	<key>CFBundleIdentifier</key>
	<string>com.quixotic7.remotefm1.core.${id}.${n}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>FM1Core_${id}_${n}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>${short}</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleGetInfoString</key>
	<string>${id} ${ver}, slot ${n}</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>${plat}</string>
	</array>
	<key>${minkey}</key>
	<string>${minval}</string>
</dict>
</plist>
EOF
}

build_platform() {
    local p=$1 dir=$B/$1 args=() plat
    case $p in
        ios) args=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS); plat=iPhoneOS ;;
        sim) args=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS); plat=iPhoneSimulator ;;
        macos) args=(-DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MAC); plat=MacOSX ;;
        *) echo "unknown platform $p (ios, sim, macos)"; exit 2 ;;
    esac
    say "cores: $p -> $dir"
    if [ ! -f "$dir/CMakeCache.txt" ]; then
        "$CMAKE" -S "$SRC" -B "$dir" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DRFM_OWN="$ROOT/cores" -DCR_PYTHON="$PY" "${args[@]}" \
            >"$dir.configure.log" 2>&1 || { mkdir -p "$dir"; tail -40 "$dir.configure.log"; exit 1; }
    fi
    local ids
    ids=$(awk '{print $1}' "$dir/cores.txt")
    local targets=()
    for id in $ids; do targets+=("FM1Core_$id"); done
    "$CMAKE" --build "$dir" --target "${targets[@]}" -j "$JOBS" >"$dir.build.log" 2>&1 \
        || { tail -40 "$dir.build.log"; exit 1; }

    local fw=$dir/frameworks
    mkdir -p "$fw"
    while read -r id ver _commit; do
        local lib=$dir/lib/libFM1Core_$id.dylib
        for n in $(seq 1 $NSLOTS); do
            local name=FM1Core_${id}_$n
            local f=$fw/$name.framework
            mkdir -p "$f"
            if [ ! -f "$f/$name" ] || [ "$lib" -nt "$f/$name" ]; then
                cp "$lib" "$f/$name.tmp"
                install_name_tool -id "@rpath/$name.framework/$name" "$f/$name.tmp" 2>/dev/null
                [ "$p" = macos ] && codesign --force --sign - "$f/$name.tmp" >/dev/null 2>&1
                mv "$f/$name.tmp" "$f/$name"
            fi
            local pl
            pl=$(plist "$id" "$n" "$ver" "$plat")
            [ "$(cat "$f/Info.plist" 2>/dev/null || true)" = "$pl" ] || printf '%s\n' "$pl" >"$f/Info.plist"
        done
        printf '%-11s %-8s %s  %s\n' "$id" "$ver" "$(du -h "$lib" | cut -f1)" "$fw/FM1Core_${id}_1..$NSLOTS.framework"
    done <"$dir/cores.txt"
}

PLATS=("$@")
[ ${#PLATS[@]} -gt 0 ] || PLATS=(ios sim macos)
[ -x "$PY" ] || { echo "no python at $PY (CR_PYTHON=...)"; exit 1; }
sync_sources
for p in "${PLATS[@]}"; do build_platform "$p"; done
