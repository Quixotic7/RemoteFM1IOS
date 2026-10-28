#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
"""LOOM-8's factory samples header for the core: tools/gen_samples.py (LOOM-8's, unchanged, imported) with the 909
closed hat's row left empty, as the FM-1's image leaves it: its sample, app/samples/909_hat.wav (a render of ER-99
through 9W9, GPL-3.0), is not in LOOM-8's firmware and not in this build (scripts/build_cores.sh does not even copy
it). The row stays (projects name samples by number); n 0 plays the user bank's "hat" if one is installed, as on the
FM-1. Everything else is gen_samples.py's: the 909 kick, snare and clap renders, the sweep, the VSCO 2 CE
recordings, the vinyl loop; the breaks' rows empty as always.

  gen_samples_rfm.py LOOM_TOOLS_DIR OUT.h
"""
import sys
from pathlib import Path

tools = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(tools))
import gen_samples as g  # noqa: E402
import sampleio as sio  # noqa: E402

HAT = "909_hat.wav"
assert any(d[1] == HAT for d in g.DRUMS), "gen_samples.py has no 909_hat.wav row: check this script"
_read = sio.read_any_wav


def read_any_wav(path):
    if Path(path).name == HAT:
        return 22050, [], None                       # the hat: no sample (its row n 0)
    return _read(path)


def empty_ok(fn):
    return lambda x, *a, **k: [] if len(x) == 0 else fn(x, *a, **k)


sio.read_any_wav = read_any_wav
sio.emphasis = empty_ok(sio.emphasis)
sio.to_int16 = empty_ok(sio.to_int16)
sys.argv = [sys.argv[0], sys.argv[2]]
g.main()
