// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMKernel: the AUv3's render kernel. M2: it counted what it saw (renders, frames, MIDI) and wrote silence. M4: it
// plays the instance's core (RFMEngine's rfme_render_midi) at the host's rate and maximum frames, with the host's MIDI
// at its frame, and passes the core's MIDI out to the host (AUMIDIOutputEventBlock). Without a booted core it writes
// silence. The render block is an Objective-C++ block calling plain C++: no allocation, no locks and no Swift on the
// render thread. allocate/deallocate/set_* run on the host's thread, never while rendering.
#ifndef RFMKERNEL_H
#define RFMKERNEL_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rfmk rfmk_t;
typedef struct rfme rfme_t;
rfmk_t *rfmk_new(void);
// the engine the render block plays (set once, before the first render; it must outlive the kernel's use)
void rfmk_set_engine(rfmk_t *k, rfme_t *e);
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
    uint64_t sounding;          // renders the core played (the rest: silence)
    uint32_t midi_out_msgs;     // MIDI messages given to the host's MIDI output
    double level_rms;           // the output's RMS since the last rfmk_reset_level (full scale 1.0)
    uint64_t level_frames;
} rfmk_stats_t;
void rfmk_reset_level(rfmk_t *k);
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
// the host's MIDI output (AUAudioUnit.MIDIOutputEventBlock, nil: none); set in allocateRenderResources
void rfmk_set_midi_out(rfmk_t *k, AUMIDIOutputEventBlock block);
#ifdef __cplusplus
}
#endif

// The AU's base class: AUAudioUnit's renderContextObserver (unavailable in Swift: it is called on the render thread).
// Its block hands the render context's workgroup to the engine set here (rfme_set_workgroup: the engine's core thread
// joins it), so the core thread rendering ahead runs in the host's audio workgroup. Plain C on the render thread.
@interface RFMAudioUnitBase : AUAudioUnit
// the engine whose core thread joins the host's workgroup (NULL: none; set NULL before freeing the engine)
- (void)rfmSetRenderContextEngine:(rfme_t *)engine;
@end
#endif
#endif
