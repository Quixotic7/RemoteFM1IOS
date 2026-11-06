#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# aout_cart.c (the ten-channel output test cart, docs/RFM1-FORMAT.md section 9) built as aout_cart.rfm1, with its
# manifest; committed. A test fixture only.   RFMKit/Tests/RFMKitTests/Fixtures/build_aout.sh   (emcc on PATH)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
emcc -O2 "$HERE/aout_cart.c" -o "$HERE/aout_cart.wasm" --no-entry -sSTANDALONE_WASM -sINITIAL_MEMORY=2MB \
     -sALLOW_MEMORY_GROWTH=0 -sSTACK_SIZE=65536 -sERROR_ON_UNDEFINED_SYMBOLS=0
python3 -I - "$HERE/aout_cart.wasm" "$HERE/aout_cart.rfm1" <<'PY'
import json, sys
wasm, out = sys.argv[1:]
def leb(v):
    o = bytearray()
    while True:
        c = v & 0x7F; v >>= 7
        o.append(c | (0x80 if v else 0))
        if not v: return bytes(o)
m = {"rfm1": 1, "abi": 6, "id": "aouttest", "name": "Audio Out Test", "version": "1.0", "license": "GPL-3.0-only",
     "source_url": "https://github.com/Quixotic7/RemoteFM1IOS@0000000000000000000000000000000000000000",
     "authors": ["RemoteFM1 tests"]}
nm, js = b"rfm1", json.dumps(m, separators=(",", ":")).encode()
body = leb(len(nm)) + nm + js
open(out, "wb").write(open(wasm, "rb").read() + b"\0" + leb(len(body)) + body)
PY
rm -f "$HERE/aout_cart.wasm"
echo "build_aout: $HERE/aout_cart.rfm1"
