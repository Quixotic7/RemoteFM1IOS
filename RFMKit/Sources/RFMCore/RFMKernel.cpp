// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMKernel: see include/RFMKernel.h. The render block itself is in RFMKernelBlock.mm.
#include "RFMKernelImpl.h"

#include <cmath>
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
    rfmk_drop_midi_out(k);
    rfmk_drop_host_blocks(k);
    delete k;
}

void rfmk_set_engine(rfmk_t *k, rfme_t *e) { k->engine = e; }

int rfmk_allocate(rfmk_t *k, double sample_rate, uint32_t channels, uint32_t max_frames)
{
    if (channels == 0 || channels > 8 || max_frames == 0)
        return 0;
    k->sampleRate = sample_rate;
    k->channels = channels;
    k->maxFrames = max_frames;
    k->storage.assign((size_t)channels * max_frames, 0.0f);
    k->scratch.assign(max_frames, 0.0f);
    rfmhc_reset(&k->hc);                        // (not rendering: the render thread's state)
    k->bufs.resize(channels);
    for (uint32_t c = 0; c < channels; c++)
        k->bufs[c] = k->storage.data() + (size_t)c * max_frames;
    return 1;
}

void rfmk_deallocate(rfmk_t *k)
{
    k->storage.clear();
    k->storage.shrink_to_fit();
    k->scratch.clear();
    k->scratch.shrink_to_fit();
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
    out->sounding = k->sounding.load(std::memory_order_relaxed);
    out->midi_out_msgs = k->midiOutMsgs.load(std::memory_order_relaxed);
    const uint64_t f = k->levelFrames.load(std::memory_order_relaxed);
    out->level_frames = f;
    out->level_rms = f ? std::sqrt(k->levelSum.load(std::memory_order_relaxed) / (2.0 * (double)f)) : 0.0;
    out->host_clock = k->hostState.load(std::memory_order_relaxed);
    out->host_tempo = k->hostTempo.load(std::memory_order_relaxed);
    out->host_beat = k->hostBeat.load(std::memory_order_relaxed);
    out->clock_msgs = k->clockMsgs.load(std::memory_order_relaxed);
    out->clock_dropped = k->clockDropped.load(std::memory_order_relaxed);
}

void rfmk_set_host_clock(rfmk_t *k, int on) { k->hostClockOn.store(on != 0, std::memory_order_relaxed); }

void rfmk_reset_level(rfmk_t *k) { k->levelReset.store(true, std::memory_order_relaxed); }

int rfmk::process(float *L, float *R, uint32_t n)
{
    int played = 0;
    if (engine) {
        played = rfme_render_midi(engine, L, R, n, sampleRate, ev, nev);
    } else {
        std::memset(L, 0, n * sizeof *L);
        std::memset(R, 0, n * sizeof *R);
    }
    nev = 0;
    if (played)
        sounding.fetch_add(1, std::memory_order_relaxed);
    if (levelReset.exchange(false, std::memory_order_relaxed)) {
        levelSum.store(0, std::memory_order_relaxed);
        levelFrames.store(0, std::memory_order_relaxed);
    }
    double s = 0;
    for (uint32_t i = 0; i < n; i++)
        s += (double)L[i] * L[i] + (double)R[i] * R[i];
    levelSum.store(levelSum.load(std::memory_order_relaxed) + s, std::memory_order_relaxed);
    levelFrames.fetch_add(n, std::memory_order_relaxed);
    return played;
}

// FM1VST's decodePacket (plugin/Processor.cpp): USB-MIDI packets -> whole messages; SysEx reassembled up to 4 KiB
void rfmk::drainMidiOut(Emit emit, void *ctx)
{
    static const uint8_t LEN[16] = {0, 0, 2, 3, 3, 1, 2, 3, 3, 3, 3, 3, 2, 2, 3, 1};
    if (!engine)
        return;
    auto sx = [this](const uint8_t *s, uint32_t k) {
        for (uint32_t i = 0; i < k; i++) {
            if (sysexLen >= kSysExMax)
                sysexOverflow = true;
            else
                sysex[sysexLen++] = s[i];
        }
    };
    uint32_t at = 0;
    auto sxEnd = [&]() {
        if (!sysexOverflow && sysexLen >= 2 && sysex[0] == 0xF0 && sysex[sysexLen - 1] == 0xF7) {
            emit(ctx, sysex, sysexLen, at);
            midiOutMsgs.fetch_add(1, std::memory_order_relaxed);
        }
        sysexLen = 0;
        sysexOverflow = false;
    };
    for (uint32_t p; rfme_midi_out_take_at(engine, &p, &at);) {
        const uint32_t cin = p & 15u;
        const uint8_t b[3] = {(uint8_t)(p >> 8), (uint8_t)(p >> 16), (uint8_t)(p >> 24)};
        switch (cin) {
        case 0x4:
            if (b[0] == 0xF0)
                sysexLen = 0, sysexOverflow = false;
            sx(b, 3);
            continue;
        case 0x5:
            if (b[0] == 0xF7 || sysexLen) {
                sx(b, 1);
                sxEnd();
            } else if (b[0] >= 0xF0) {
                emit(ctx, b, 1, at);
                midiOutMsgs.fetch_add(1, std::memory_order_relaxed);
            }
            continue;
        case 0x6:
            sx(b, 2);
            sxEnd();
            continue;
        case 0x7:
            sx(b, 3);
            sxEnd();
            continue;
        default:
            break;
        }
        const uint32_t len = LEN[cin];
        if (!len || !(b[0] & 0x80))
            continue;
        if (cin >= 0x8 && (uint32_t)(b[0] >> 4) != cin)
            continue;
        if (cin >= 0x8 && ((len > 1 && (b[1] & 0x80)) || (len > 2 && (b[2] & 0x80))))
            continue;
        emit(ctx, b, len, at);
        midiOutMsgs.fetch_add(1, std::memory_order_relaxed);
    }
}

void rfmk_render_test(rfmk_t *k, float *const *bufs, uint32_t channels, uint32_t frames, const uint8_t *midi,
                      uint32_t midi_len)
{
    if (midi && midi_len)
        k->midi(midi, midi_len, 0);
    float *R = channels > 1 ? bufs[1] : k->scratch.data();
    k->process(bufs[0], R, frames);
    k->counted(frames);
}
