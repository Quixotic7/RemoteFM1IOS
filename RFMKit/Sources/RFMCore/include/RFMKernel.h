// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMKernel: the AUv3's render kernel. In M2 it writes silence and counts what it sees (renders, frames, MIDI); M3/M4
// put the core here. The render block is an Objective-C++ block calling plain C++: no allocation, no locks and no
// Swift on the render thread. allocate/deallocate run on the host's thread, never while rendering.
#ifndef RFMKERNEL_H
#define RFMKERNEL_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rfmk rfmk_t;
rfmk_t *rfmk_new(void);
void rfmk_free(rfmk_t *k);
// buffers for hosts that pass NULL mData (channels x max_frames floats)
int rfmk_allocate(rfmk_t *k, double sample_rate, uint32_t channels, uint32_t max_frames);
void rfmk_deallocate(rfmk_t *k);

typedef struct {
    uint64_t renders, frames, midi_events, ticks;
    uint8_t last_midi[3];       // the last MIDI 1.0 message (or MIDI 2 channel voice word, as MIDI 1)
    uint32_t last_midi_len;
    double sample_rate;
    uint32_t max_frames, channels;
    int thread_ok;              // the kernel's own thread started
} rfmk_stats_t;
void rfmk_stats(rfmk_t *k, rfmk_stats_t *out);

// one render with no host (the Mac tests): frames into `channels` buffers, plus up to one MIDI message
void rfmk_render_test(rfmk_t *k, float *const *bufs, uint32_t channels, uint32_t frames, const uint8_t *midi,
                      uint32_t midi_len);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <AudioToolbox/AudioToolbox.h>
#ifdef __cplusplus
extern "C" {
#endif
// the AUInternalRenderBlock for k (k must outlive the block's use: the AU frees it in deinit)
AUInternalRenderBlock rfmk_render_block(rfmk_t *k);
#ifdef __cplusplus
}
#endif
#endif
#endif
