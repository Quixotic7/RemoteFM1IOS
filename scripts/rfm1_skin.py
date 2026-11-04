#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
"""Add a skin to an .rfm1 firmware (docs/RFM1-FORMAT.md section 8), or show the one it has.

  rfm1_skin.py add firmware.rfm1 -o skinned.rfm1 --background bg.png [--landscape bg-wide.png]
               [--theme theme.json] [--dim 0.2]
  rfm1_skin.py show firmware.rfm1

The skin goes in custom sections at the end of the file; the code is untouched. An existing skin is replaced.
theme.json: {"body": "#RRGGBB", "key": ..., "knob": ..., "led": ..., "bezel": ...} or all fourteen roles.
"""
import argparse
import json
import sys

SKIN = "rfm1.skin"
MAX_IMAGE = 4 << 20


def leb(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def read_leb(b, at):
    v = shift = 0
    while True:
        c = b[at]
        at += 1
        v |= (c & 0x7F) << shift
        if not c & 0x80:
            return v, at
        shift += 7


def sections(b):
    """(id, name or None, start, end) for each section"""
    if b[:8] != b"\0asm\1\0\0\0":
        sys.exit("not a WebAssembly module (version 1)")
    at, out = 8, []
    while at < len(b):
        start = at
        sid = b[at]
        size, at = read_leb(b, at + 1)
        end = at + size
        name = None
        if sid == 0:
            n, p = read_leb(b, at)
            name = b[p:p + n].decode("utf-8", "replace")
        out.append((sid, name, start, end))
        at = end
    return out


def custom(name, payload):
    n = name.encode()
    body = leb(len(n)) + n + payload
    return b"\0" + leb(len(body)) + body


def image(path):
    d = open(path, "rb").read()
    if len(d) > MAX_IMAGE:
        sys.exit(f"{path}: {len(d)} bytes; a skin image may be at most {MAX_IMAGE} (4 MiB)")
    if not (d[:8] == b"\x89PNG\r\n\x1a\n" or d[:3] == b"\xff\xd8\xff"):
        sys.exit(f"{path}: not a PNG or JPEG")
    return d


def add(a):
    b = open(a.firmware, "rb").read()
    keep = b[:8] + b"".join(b[s:e] for sid, nm, s, e in sections(b) if not (nm or "").startswith(SKIN))
    meta = {"skin": 1}
    if a.dim is not None:
        meta["dim"] = max(0.0, min(0.8, a.dim))
    if a.theme:
        meta["theme"] = json.load(open(a.theme))
    if not (a.background or a.landscape or a.theme):
        sys.exit("give --background, --landscape or --theme")
    out = keep + custom(SKIN, json.dumps(meta, separators=(",", ":")).encode())
    if a.background:
        out += custom(SKIN + ".background", image(a.background))
    if a.landscape:
        out += custom(SKIN + ".background.landscape", image(a.landscape))
    open(a.output, "wb").write(out)
    print(f"{a.output}: {len(out)} bytes (skin {len(out) - len(keep)})")


def show(a):
    b = open(a.firmware, "rb").read()
    found = False
    for sid, nm, s, e in sections(b):
        if (nm or "").startswith(SKIN):
            found = True
            n, p = read_leb(b, s + 1)
            ln, p = read_leb(b, p)
            payload = b[p + ln:e]
            print(f"{nm}: {len(payload)} bytes" + (f" {payload.decode()}" if nm == SKIN else ""))
    if not found:
        print("no skin")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("add")
    p.add_argument("firmware")
    p.add_argument("-o", "--output", required=True)
    p.add_argument("--background")
    p.add_argument("--landscape")
    p.add_argument("--theme")
    p.add_argument("--dim", type=float)
    s = sub.add_parser("show")
    s.add_argument("firmware")
    a = ap.parse_args()
    (add if a.cmd == "add" else show)(a)


if __name__ == "__main__":
    main()
