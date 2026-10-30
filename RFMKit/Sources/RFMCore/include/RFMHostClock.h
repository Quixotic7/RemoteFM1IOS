// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The host's clock and transport as MIDI (PLAN.md section 11). Hosts don't send MIDI clock to instruments, so the AU
// makes it from the host's musical context (tempo, beat position) and transport state, once per render buffer:
//
//   0xF8           every 1/24 beat while the transport moves, at its frame in the buffer
//   start          0xFA at beat 0; else Song Position (0xF2, sixteenths) then 0xFB (Continue), and the clock from
//                  that sixteenth on. Moving at a negative beat (a count-in): 0xFA when beat 0 comes
//   stop           0xFC
//   a jump         (a relocate, a loop wrapping) while moving: 0xFC, 0xF2, 0xFB. A wrap inside the buffer
//                  (cycling, the cycle's end inside it) happens at its frame
//
// The beat comes from the host every buffer (not counted here); a tick already sent is never sent again and one a
// small jitter skipped is sent at frame 0. A position more than a tick away from where the last buffer ended is a
// jump. No tempo, no context or no transport: nothing (and whatever ran is forgotten). Plain data, no allocation:
// it runs on the render thread.
#ifndef RFMHOSTCLOCK_H
#define RFMHOSTCLOCK_H
#include <stdint.h>

#include "RFMEngine.h"

#ifdef __cplusplus
extern "C" {
#endif

// one buffer's host information
typedef struct {
    int has_context;            // the host's musicalContextBlock answered (tempo, beat)
    int has_transport;          // its transportStateBlock answered
    double tempo;               // BPM
    double beat;                // the beat position at the buffer's first frame
    int moving;                 // AUHostTransportStateMoving
    int cycling;                // AUHostTransportStateCycling, with the cycle in beats
    double cycle_start, cycle_end;
    double sample_rate;
    uint32_t frames;
} rfmhc_input_t;

// the generator's state (rfmhc_reset first)
typedef struct {
    int running;                // Start or Continue sent: clocking
    int pending;                // moving at a negative beat: Start at beat 0
    int valid;                  // next_beat is known (moving last buffer)
    double next_beat;           // where the last buffer ended
    int64_t last_tick;          // the last 0xF8 sent (beat x 24)
} rfmhc_t;

void rfmhc_reset(rfmhc_t *c);
// one buffer: its messages, in frame order, into out (at most max); returns how many
uint32_t rfmhc_run(rfmhc_t *c, const rfmhc_input_t *in, rfme_midi_t *out, uint32_t max);

#ifdef __cplusplus
}
#endif
#endif
