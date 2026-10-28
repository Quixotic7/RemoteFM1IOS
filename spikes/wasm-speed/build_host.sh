#!/bin/sh
# Build the bench's native side: wasm3, the Wasm host (host/wcore.cpp), FM1VST's Device, the bench, and the native
# cores (the same sources as the Wasm modules, compiled for the CPU).
#   ./build_host.sh mac   ->  build/mac/rfmbench           (the CLI: build/mac/rfmbench build [spec words..])
#   ./build_host.sh ios   ->  build/ios/librfmbench.a      (arm64 iOS 17+, linked by ios/RFMBenchWasm.xcodeproj)
# NATIVE_CORES (felucca) and WAMR=1 (WAMR's fast interpreter: third_party/wamr, see README.md) from the environment.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
V=$REPO/vendor/FM1VST
PLAT=${1:-mac}
O=$HERE/build/$PLAT
mkdir -p "$O/obj"
case $PLAT in
    mac) SDK=macosx; TARGET="-arch arm64 -mmacosx-version-min=14.0" ;;
    ios) SDK=iphoneos; TARGET="-arch arm64 -miphoneos-version-min=17.0" ;;
    sim) SDK=iphonesimulator; TARGET="-arch arm64 -mios-simulator-version-min=17.0" ;;
    *) echo "usage: $0 mac|ios|sim"; exit 2 ;;
esac
CC="xcrun -sdk $SDK clang $TARGET"
CXX="xcrun -sdk $SDK clang++ $TARGET"
NATIVE_CORES=${NATIVE_CORES:-felucca}
OBJS=""
PIDS=""

cc() {   # $1 out.o, the rest: the compiler command
    out=$1; shift
    OBJS="$OBJS $out"
    "$@" -c -o "$out" &
    PIDS="$PIDS $!"
}

# wasm3 (its release flags)
W3=$HERE/third_party/wasm3/source
for f in bind code compile core emit env exec function info module optimize parse; do
    cc "$O/obj/m3_$f.o" $CC -std=gnu11 -O3 -fomit-frame-pointer -fno-stack-check -fno-stack-protector -w -I"$W3" "$W3/m3_$f.c"
done
DEFS=""
WAMR_INC=""
if [ "${WAMR:-0}" = 1 ]; then
    DEFS="-DWCORE_WAMR"
    WAMR_INC="-I$HERE/third_party/wamr/core/iwasm/include"
fi
CXXF="-std=c++17 -O2 -Wall -Wextra -I$V/core-api -I$V/engine -I$W3 $WAMR_INC"
for c in $NATIVE_CORES; do DEFS="$DEFS -DBENCH_NATIVE_$(echo "$c" | tr a-z A-Z)"; done
cc "$O/obj/wcore.o" $CXX $CXXF $DEFS "$HERE/host/wcore.cpp"
cc "$O/obj/bench.o" $CXX $CXXF $DEFS "$HERE/host/bench.cpp"
cc "$O/obj/device.o" $CXX $CXXF -w "$V/engine/device.cpp"

# the native cores: as cmake/FM1Cores.cmake builds them (-O2, hidden), plus -ffp-contract=off as the Wasm build (the
# two then render the same samples: the bench's hash compares them); one relocatable object each, exporting only
# fm1core_get_<id> (ld -r makes the rest local: two cores' firmware globals never meet)
native() {   # $1 id, the rest: the units
    id=$1; shift
    NO=""
    for u in "$@"; do
        b=$(basename "$u" .c)
        $CC -std=gnu11 -O2 -ffp-contract=off -fvisibility=hidden -fno-common -w -include "$HERE/cores/${id}_defs.h" \
            -Dfm1core_get=fm1core_get_$id -I"$V/core-api" -I"$V/core-glue/common" $CORE_INC -c "$u" -o "$O/obj/${id}_$b.o"
        NO="$NO $O/obj/${id}_$b.o"
    done
    # shellcheck disable=SC2086
    xcrun -sdk $SDK ld -r -arch arm64 -exported_symbol "_fm1core_get_$id" $NO -o "$O/obj/native_$id.o"
}
for c in $NATIVE_CORES; do
    case $c in
        felucca)
            CORE_INC="-I$HERE/build/gen/felucca -I$V/cores/Felucca/firmware/src"
            G=$V/core-glue/felucca_web
            native felucca "$G/core_felucca.c" "$G/core_felucca_desc.c" "$V/core-glue/common/nor.c" \
                "$V/core-glue/common/fifo.c" &
            PIDS="$PIDS $!" ;;
        choralroot)
            . "$HERE/cores/choralroot_native.sh" ;;
    esac
    OBJS="$OBJS $O/obj/native_$c.o"
done
for p in $PIDS; do wait "$p"; done

if [ "${WAMR:-0}" = 1 ]; then
    OBJS="$OBJS $HERE/build/$PLAT/wamr/libiwasm.a"
fi
# shellcheck disable=SC2086
xcrun -sdk $SDK libtool -static -o "$O/librfmbench.a" $OBJS 2>/dev/null   # (WAMR's archive merged in)
if [ "$PLAT" = mac ]; then
    LIBS="$O/librfmbench.a"
    # shellcheck disable=SC2086
    $CXX $CXXF "$HERE/host/main_cli.cpp" $LIBS -o "$O/rfmbench"
    echo "built $O/rfmbench"
else
    echo "built $O/librfmbench.a"
fi
