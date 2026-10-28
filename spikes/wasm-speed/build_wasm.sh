#!/bin/sh
# Build the cores as standalone Wasm modules (the spike's ".rfm1" payload): build/<id>.wasm
#   ./build_wasm.sh [felucca|choralroot]...    (default: felucca)
# OPT (-O3) and FEATURES (-mcpu=mvp plus what wasm3 0.5.0 runs) can be overridden from the environment.
# The generated headers come from the app's own core build (scripts/build_cores.sh): copied once into build/gen.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
V=$REPO/vendor/FM1VST
OUT=$HERE/build
OPT=${OPT:--O3}
# wasm3 0.5.0 parses the MVP plus sign-extension, saturating float-to-int and multi-value; bulk memory (memory.copy /
# fill) it runs too. Emscripten's default target adds reference types and the like, which it does not: pin the set.
FEATURES=${FEATURES:--mcpu=mvp -msign-ext -mnontrapping-fptoint -mbulk-memory -mmutable-globals}
mkdir -p "$OUT"

COMMON="-std=gnu11 -ffp-contract=off -fno-common -I$V/core-api -I$V/core-glue/common"
LINK="--no-entry -sSTANDALONE_WASM -sFILESYSTEM=0 -sSTACK_SIZE=1048576 -sINITIAL_MEMORY=8388608 -sALLOW_MEMORY_GROWTH=0
      -sEXPORTED_FUNCTIONS=[] -Wl,--gc-sections"

gen_copy() {   # $1 id, $2 source gen dir (under build/cores)
    [ -d "$OUT/gen/$1" ] && return 0
    [ -d "$2" ] || { echo "no $2: run scripts/build_cores.sh once (the app's core build)"; exit 1; }
    mkdir -p "$OUT/gen" && cp -R "$2" "$OUT/gen/$1"
}

build_felucca() {
    gen_copy felucca "$REPO/build/cores/src/cores/Felucca/build/gen"
    G=$V/core-glue/felucca_web
    S=$V/cores/Felucca
    # shellcheck disable=SC2086
    emcc $OPT $FEATURES $COMMON -include "$HERE/cores/felucca_defs.h" -w -I"$OUT/gen/felucca" -I"$S/firmware/src" \
        "$G/core_felucca.c" "$G/core_felucca_desc.c" "$V/core-glue/common/nor.c" "$V/core-glue/common/fifo.c" \
        "$HERE/wasm/shim.c" $LINK -o "$OUT/felucca.wasm"
    echo "felucca.wasm: $(wc -c < "$OUT/felucca.wasm" | tr -d ' ') bytes"
}

# ChoralRoot: its emulator unit (tools/emu/emu_fw.c) includes <os/lock.h> (the core-1 thread's lock, never started in
# a core): cores/wasm_compat stands in for it. Its <pthread.h> is Emscripten's single-threaded stubs.
build_choralroot() {
    gen_copy choralroot "$REPO/build/cores/src/cores/ChoralRootFM1/build/gen"
    G=$V/core-glue/choralroot
    S=$V/cores/ChoralRootFM1
    # shellcheck disable=SC2086
    emcc $OPT $FEATURES $COMMON -include "$HERE/cores/choralroot_defs.h" -w -I"$HERE/cores/wasm_compat" \
        -I"$OUT/gen/choralroot" -I"$S/firmware/src" -I"$S/tools/emu" \
        "$G/core_choralroot.c" "$G/core_choralroot_desc.c" "$V/core-glue/common/nor.c" "$V/core-glue/common/fifo.c" \
        "$HERE/wasm/shim.c" $LINK -o "$OUT/choralroot.wasm"
    echo "choralroot.wasm: $(wc -c < "$OUT/choralroot.wasm" | tr -d ' ') bytes"
}

[ $# -eq 0 ] && set -- felucca choralroot
for c in "$@"; do "build_$c"; done
