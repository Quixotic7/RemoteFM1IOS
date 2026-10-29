#!/usr/bin/env python3
"""Dropouts in an fm1loop recording (a steady sine played to the FM-1's USB audio output, recorded from its USB
audio input).

Firmware 0.2.2's USB audio input is itself broken while RemoteFM1's main loop polls USB (README.md, "The input
path"): the recording is mostly zeros, with short valid slices (2-15 ms) of the FM-1's master output. So this does
not look for gaps in the whole recording. It cuts the recording into those slices ("segments": runs of nonzero
samples), and checks inside each one that the sine is continuous:

  each segment (edges trimmed, held samples at its end dropped) is fitted with one sinusoid at the run's frequency;
  a segment whose fit leaves a residual over 25 % of the amplitude, and that two fits with a break at some sample
  explain at least 4x better, has a discontinuity at that break (the output skipped or repeated samples there).

The tone (fm1loop --freq 1503) is chosen so that a lost USB packet (44 or 45 frames) turns the phase by about
half a cycle: 44 x 1503 / 44100 = 1.50 cycles, 45 x ... = 1.53.
Reported: the segments' total length (observed seconds), segments, discontinuities, and their rate per observed
minute; the share of the recording that is valid (on fraction); the segment lengths.

  analyze.py run.wav [--json]
"""
import json
import sys

import numpy as np

FS = 44100


def load(path):
    with open(path, 'rb') as f:
        b = f.read()
    i = b.index(b'data') + 8
    return np.frombuffer(b[i:], dtype=np.float32).reshape(-1, 2)[:, 0].astype(np.float64)


def segments(x, join=8):
    nz = np.flatnonzero(x != 0)
    if len(nz) == 0:
        return []
    br = np.flatnonzero(np.diff(nz) > join)
    st = np.r_[nz[0], nz[br + 1]]
    en = np.r_[nz[br], nz[-1]] + 1
    return list(zip(st, en))


def fit(y, w):
    n = np.arange(len(y))
    m = np.c_[np.sin(w * n), np.cos(w * n), np.ones(len(y))]
    c, *_ = np.linalg.lstsq(m, y, rcond=None)
    r = y - m @ c
    return float(np.hypot(c[0], c[1])), float(np.sum(r * r))


def freq(x, segs):
    # the frequency from the longest segments' zero crossings (the FM-1 plays at the host's rate, adaptively)
    best = sorted(segs, key=lambda s: s[0] - s[1])[:50]
    per = []
    for a, b in best:
        y = x[a:b]
        zc = np.flatnonzero((y[:-1] < 0) & (y[1:] >= 0))
        if len(zc) > 3:
            fr = zc[:-1] + y[zc[:-1]] / (y[zc[:-1]] - y[zc[:-1] + 1])
            per.append((fr[-1] - fr[0]) / (len(fr) - 1))
    return FS / float(np.median(per))


def analyze(x):
    x = x[FS:len(x) - FS // 4]                              # priming and the end
    segs = segments(x)
    f0 = freq(x, segs)
    w = 2 * np.pi * f0 / FS
    total = 0
    n_ok = 0
    disc = []
    lens = []
    for a, b in segs:
        y = x[a:b]
        k = len(y)
        while k > 2 and y[k - 1] == y[k - 2]:               # an input underrun holds the last sample
            k -= 1
        y = y[3:k - 3]
        if len(y) < 40:
            continue
        lens.append(len(y))
        total += len(y)
        amp, e1 = fit(y, w)
        rel = np.sqrt(e1 / len(y)) / (amp / np.sqrt(2) + 1e-12)
        if rel < 0.25:
            n_ok += 1
            continue
        best = (e1, None)
        for m in range(12, len(y) - 12, 2):
            e = fit(y[:m], w)[1] + fit(y[m:], w)[1]
            if e < best[0]:
                best = (e, m)
        if best[1] is not None and best[0] * 4 < e1:
            disc.append({'t_s': round((FS + a + 3 + best[1]) / FS, 4), 'seg_len': len(y), 'resid': round(rel, 2)})
        else:
            disc.append({'t_s': round((FS + a) / FS, 4), 'seg_len': len(y), 'resid': round(rel, 2), 'unclear': 1})
    obs = total / FS
    on = sum(b - a for a, b in segs) / len(x)
    return {
        'freq_hz': round(f0, 2), 'recorded_s': round(len(x) / FS, 1), 'on_fraction': round(on, 3),
        'observed_s': round(obs, 2), 'segments': len(lens), 'seg_ms_median': round(float(np.median(lens)) / 44.1, 1)
        if lens else 0, 'discontinuities': len(disc), 'per_obs_min': round(len(disc) * 60 / obs, 1) if obs else 0,
        'events': disc,
    }


def main():
    r = analyze(load(sys.argv[1]))
    if '--json' in sys.argv:
        print(json.dumps(r))
        return
    ev = r.pop('events')
    print(' '.join(f'{k}={v}' for k, v in r.items()))
    for e in ev[:30]:
        print('  ', e)
    if len(ev) > 30:
        print(f'   ... {len(ev) - 30} more')


if __name__ == '__main__':
    main()
