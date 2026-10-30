// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The host's clock and transport as MIDI: see include/RFMHostClock.h.
#include "RFMHostClock.h"

#include <cmath>

namespace {

constexpr double kTick = 1.0 / 24.0;    // beats per MIDI clock
constexpr double kJump = kTick;         // a beat this far from where the last buffer ended: a jump
constexpr double kSnap = kTick / 2;     // a start this little after a sixteenth starts on it
constexpr double kEps = 1e-6;           // frames (rounding)
constexpr int64_t kMaxSpp = 16383;      // Song Position's 14 bits

struct Out {
    rfme_midi_t *p;
    uint32_t max, n;
    void put(uint32_t at, uint8_t st, uint8_t len = 1, uint8_t d1 = 0, uint8_t d2 = 0)
    {
        if (n >= max)
            return;
        rfme_midi_t &m = p[n++];
        m.offset = at;
        m.len = len;
        m.data[0] = st;
        m.data[1] = d1;
        m.data[2] = d2;
    }
};

// Start (beat 0, not after a jump) or Song Position + Continue at frame `at`, for beat b; a negative beat waits for 0
void begin(rfmhc_t *c, double b, uint32_t at, bool jump, Out &o)
{
    if (b < -kSnap) {
        c->running = 0;
        c->pending = 1;
        return;
    }
    int64_t s = (int64_t)std::ceil((b - kSnap) * 4.0);     // the first sixteenth at or after b
    if (s < 0)
        s = 0;
    if (s == 0 && !jump) {
        o.put(at, 0xFA);
    } else {
        const int64_t p = s < kMaxSpp ? s : kMaxSpp;
        o.put(at, 0xF2, 3, (uint8_t)(p & 0x7F), (uint8_t)((p >> 7) & 0x7F));
        o.put(at, 0xFB);
    }
    c->running = 1;
    c->pending = 0;
    c->last_tick = s <= kMaxSpp ? 6 * s - 1 : (int64_t)std::ceil((b - kSnap) * 24.0) - 1;
}

// the clock for frames [f0, f1), the beat at f0 being b0
void ticks(rfmhc_t *c, double b0, uint32_t f0, uint32_t f1, double bpf, Out &o)
{
    const double len = (double)(f1 - f0);
    if (c->pending) {                                       // a count-in: Start where beat 0 is
        const double x = std::ceil((0.0 - b0) / bpf - kEps);
        if (x >= len)
            return;
        o.put(f0 + (x > 0 ? (uint32_t)x : 0u), 0xFA);
        c->running = 1;
        c->pending = 0;
        c->last_tick = -1;
    }
    if (!c->running)
        return;
    if ((double)(c->last_tick + 1) * kTick < b0 - kJump)     // (never a burst of late ticks)
        c->last_tick = (int64_t)std::ceil((b0 - kJump) * 24.0) - 1;
    while (o.n < o.max) {
        const int64_t k = c->last_tick + 1;
        const double x = std::ceil(((double)k * kTick - b0) / bpf - kEps);
        if (x >= len)
            break;
        o.put(f0 + (x > 0 ? (uint32_t)x : 0u), 0xF8);         // (one a jitter skipped: at the first frame)
        c->last_tick = k;
    }
}

} // namespace

extern "C" {

void rfmhc_reset(rfmhc_t *c)
{
    c->running = c->pending = c->valid = 0;
    c->next_beat = 0;
    c->last_tick = -1;
}

uint32_t rfmhc_run(rfmhc_t *c, const rfmhc_input_t *in, rfme_midi_t *out, uint32_t max)
{
    Out o{out, max, 0};
    if (!in || in->frames == 0)
        return 0;
    if (!in->has_context || !in->has_transport || !(in->tempo > 0) || !(in->sample_rate > 0) ||
        !std::isfinite(in->tempo) || !std::isfinite(in->beat)) {
        rfmhc_reset(c);                                     // (nothing known: nothing sent, nothing kept)
        return 0;
    }
    const uint32_t n = in->frames;
    const double bpf = in->tempo / 60.0 / in->sample_rate;  // beats per frame
    const double b0 = in->beat, b1 = b0 + (double)n * bpf;
    if (!in->moving) {
        if (c->running)
            o.put(0, 0xFC);
        c->running = c->pending = c->valid = 0;
        return o.n;
    }
    if (!c->running && !c->pending) {
        begin(c, b0, 0, false, o);
    } else if (c->valid && std::fabs(b0 - c->next_beat) > kJump) {   // a relocate, or a loop the host wrapped
        if (c->running)
            o.put(0, 0xFC);
        begin(c, b0, 0, true, o);
    }
    const double cs = in->cycle_start, ce = in->cycle_end;
    const double w = in->cycling && ce > cs && std::isfinite(cs) && std::isfinite(ce) && b1 > ce
                         ? std::ceil((ce - b0) / bpf - kEps) : -1.0;
    if (w >= 1 && w < (double)n) {                          // the loop wraps inside this buffer, at frame w
        const uint32_t at = (uint32_t)w;
        ticks(c, b0, 0, at, bpf, o);
        if (c->running)
            o.put(at, 0xFC);
        begin(c, cs, at, true, o);
        ticks(c, cs, at, n, bpf, o);
        c->next_beat = cs + (double)(n - at) * bpf;
    } else {
        ticks(c, b0, 0, n, bpf, o);
        c->next_beat = b1;
    }
    c->valid = 1;
    return o.n;
}

} // extern "C"
