# sourced by build_host.sh: ChoralRoot's native core (core-glue/choralroot/core_choralroot.cmake's units); on iOS the
# app's cores/ios/libproc.h stands in for <libproc.h> (as cores/CMakeLists.txt does)
CORE_INC="-I$HERE/build/gen/choralroot -I$V/cores/ChoralRootFM1/firmware/src -I$V/cores/ChoralRootFM1/tools/emu"
[ "$PLAT" != mac ] && CORE_INC="-I$REPO/cores/ios $CORE_INC"
G=$V/core-glue/choralroot
native choralroot "$G/core_choralroot.c" "$G/core_choralroot_desc.c" "$V/core-glue/common/nor.c" \
    "$V/core-glue/common/fifo.c" &
PIDS="$PIDS $!"
