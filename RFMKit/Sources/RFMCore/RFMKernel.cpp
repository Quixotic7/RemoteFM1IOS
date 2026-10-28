// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMKernel: see include/RFMKernel.h. The render block itself is in RFMKernelBlock.mm.
#include "RFMKernelImpl.h"

#include <cstring>

rfmk_t *rfmk_new(void)
{
    auto *k = new rfmk;
    k->ticker = rfmp_ticker_start(&k->threadOk);
    return k;
}

void rfmk_free(rfmk_t *k)
{
    if (!k)
        return;
    rfmp_ticker_stop(k->ticker);
    delete k;
}

int rfmk_allocate(rfmk_t *k, double sample_rate, uint32_t channels, uint32_t max_frames)
{
    if (channels == 0 || channels > 8 || max_frames == 0)
        return 0;
    k->sampleRate = sample_rate;
    k->channels = channels;
    k->maxFrames = max_frames;
    k->storage.assign((size_t)channels * max_frames, 0.0f);
    k->bufs.resize(channels);
    for (uint32_t c = 0; c < channels; c++)
        k->bufs[c] = k->storage.data() + (size_t)c * max_frames;
    return 1;
}

void rfmk_deallocate(rfmk_t *k)
{
    k->storage.clear();
    k->storage.shrink_to_fit();
    k->bufs.clear();
    k->maxFrames = 0;
}

void rfmk_stats(rfmk_t *k, rfmk_stats_t *out)
{
    std::memset(out, 0, sizeof *out);
    out->renders = k->renders.load(std::memory_order_relaxed);
    out->frames = k->frames.load(std::memory_order_relaxed);
    out->midi_events = k->midiEvents.load(std::memory_order_relaxed);
    out->ticks = rfmp_ticker_ticks(k->ticker);
    const uint32_t m = k->lastMidi.load(std::memory_order_relaxed);
    out->last_midi_len = m >> 24;
    for (int i = 0; i < 3; i++)
        out->last_midi[i] = (uint8_t)(m >> (8 * i));
    out->sample_rate = k->sampleRate;
    out->max_frames = k->maxFrames;
    out->channels = k->channels;
    out->thread_ok = k->threadOk;
}

void rfmk_render_test(rfmk_t *k, float *const *bufs, uint32_t channels, uint32_t frames, const uint8_t *midi,
                      uint32_t midi_len)
{
    if (midi && midi_len)
        k->midi(midi, midi_len);
    for (uint32_t c = 0; c < channels; c++)
        std::memset(bufs[c], 0, frames * sizeof(float));
    k->counted(frames);
}
