#!/bin/sh
# WAMR's fast interpreter as a static library: build/<mac|ios>/wamr/libiwasm.a (then WAMR=1 ./build_host.sh <plat>).
# Interpreter only (no AOT, no JIT: iOS allows neither), no libc (the host links the four WASI calls itself),
# bulk memory on, reference types and SIMD off, and software bounds checks (WAMR_DISABLE_HW_BOUND_CHECK: the
# hardware scheme reserves 8 GiB of address space per instance and traps through signals; wasm3 checks in software too).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PLAT=${1:-mac}
B=$HERE/build/$PLAT/wamr
mkdir -p "$B"
case $PLAT in
    mac) X="-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0" ;;
    ios) X="-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_OSX_SYSROOT=iphoneos" ;;
    *) echo "usage: $0 mac|ios"; exit 2 ;;
esac
# shellcheck disable=SC2086
cmake -S "$HERE/third_party/wamr" -B "$B" $X -DCMAKE_BUILD_TYPE=Release -DWAMR_BUILD_PLATFORM=darwin \
    -DWAMR_BUILD_TARGET=AARCH64 -DWAMR_BUILD_INTERP=1 -DWAMR_BUILD_FAST_INTERP=1 -DWAMR_BUILD_AOT=0 -DWAMR_BUILD_JIT=0 \
    -DWAMR_BUILD_FAST_JIT=0 -DWAMR_BUILD_LIBC_BUILTIN=0 -DWAMR_BUILD_LIBC_WASI=0 -DWAMR_BUILD_BULK_MEMORY=1 \
    -DWAMR_BUILD_SIMD=0 -DWAMR_BUILD_REF_TYPES=0 -DWAMR_BUILD_SHARED_MEMORY=0 -DWAMR_BUILD_MULTI_MODULE=0 \
    -DWAMR_DISABLE_HW_BOUND_CHECK=1 > "$B/configure.log" 2>&1
cmake --build "$B" --target vmlib -j 12 > "$B/build.log"
echo "built $B/libiwasm.a"
