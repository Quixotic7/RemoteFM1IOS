#!/bin/sh
# Builds fm1loop and sxload into build/ (libremotefm1 from vendor/, unmodified, built with CMake into build/host).
set -e
cd "$(dirname "$0")"
R=../../vendor/FM1VST/remote/RemoteFM1
H=$R/host
mkdir -p build
clang -O2 -Wall -Wextra -o build/fm1loop fm1loop.c -framework AudioToolbox -framework CoreAudio -framework CoreFoundation
cmake -S $H -B build/host -DCMAKE_BUILD_TYPE=Release -DRFM_FM1REMOTE=OFF >/dev/null
cmake --build build/host -j --target remotefm1 >/dev/null
INC="-I$H/include -I$R/proto -I$R/firmware/src -I$H/src/macos -I/opt/homebrew/include/libusb-1.0"
TAP="-Drfm_session_add_link=tap_add_link -Drfm_session_rx=tap_rx"
clang -O2 -w $INC $TAP -c $H/src/macos/host.c -o build/host_tap.o
clang -O2 -w $INC -c $H/src/macos/coremidi.c -o build/coremidi.o
clang -O2 -w $INC -c $H/src/macos/usb.c -o build/usb.o
clang -O2 -Wall -Wextra $INC -o build/sxload sxload.c build/host_tap.o build/coremidi.o build/usb.o \
    build/host/libremotefm1.a -L/opt/homebrew/lib -lusb-1.0 -framework CoreMIDI -framework CoreFoundation
echo built build/fm1loop build/sxload
