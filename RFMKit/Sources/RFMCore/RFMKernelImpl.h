// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The render kernel's state, shared by RFMKernel.cpp and the render block (RFMKernelBlock.mm).
#pragma once
#include "RFMEngine.h"
#include "RFMKernel.h"
#include "RFMProbe.h"

#include <atomic>
#include <cstdint>
#include <vector>

struct rfmk {
    static constexpr uint32_t kMaxEvents = 512;
    static constexpr uint32_t kSysExMax = 4096;

    // set by allocate / deallocate / set_* (never while rendering)
    double sampleRate = 44100;
    uint32_t channels = 2, maxFrames = 0;
    std::vector<float> storage;                 // channels x maxFrames
    std::vector<float *> bufs;
    std::vector<float> scratch;                 // the second channel of a mono output
    rfme_t *engine = nullptr;
    void *midiOut = nullptr;                    // the host's AUMIDIOutputEventBlock (retained; RFMKernelBlock.mm)

    // the render thread's own
    rfme_midi_t ev[kMaxEvents] = {};
    uint32_t nev = 0;
    uint8_t sysex[kSysExMax] = {};
    uint32_t sysexLen = 0;
    bool sysexOverflow = false;

    // read by any thread
    std::atomic<uint64_t> renders{0}, frames{0}, midiEvents{0}, sounding{0};
    std::atomic<uint32_t> lastMidi{0};          // bytes 0..2, length in bits 24..31
    std::atomic<uint32_t> midiOutMsgs{0};
    std::atomic<double> levelSum{0};            // (one writer: the render thread)
    std::atomic<uint64_t> levelFrames{0};
    std::atomic<bool> levelReset{false};

    // the session thread's stand-in (M2's probe)
    rfmp_ticker_t *ticker = nullptr;
    int threadOk = 0;

    // one host MIDI message: counted, and queued for the core at its frame. Lock-free and allocation-free.
    void midi(const uint8_t *b, uint32_t n, uint32_t offset)
    {
        midiEvents.fetch_add(1, std::memory_order_relaxed);
        uint32_t v = (n > 3 ? 3u : n) << 24;
        for (uint32_t i = 0; i < n && i < 3; i++)
            v |= (uint32_t)b[i] << (8 * i);
        lastMidi.store(v, std::memory_order_relaxed);
        if (n == 0 || n > 3 || b[0] == 0xF0 || nev >= kMaxEvents)
            return;                             // (SysEx from the host: not passed to the core yet)
        rfme_midi_t &e = ev[nev++];
        e.offset = offset;
        e.len = (uint8_t)n;
        for (uint32_t i = 0; i < 3; i++)
            e.data[i] = i < n ? b[i] : 0;
    }

    void counted(uint32_t n)
    {
        renders.fetch_add(1, std::memory_order_relaxed);
        frames.fetch_add(n, std::memory_order_relaxed);
    }

    // the core into L and R (R non-NULL) with the queued MIDI; 1: the core played. The queue is emptied.
    int process(float *L, float *R, uint32_t n);
    // the core's MIDI out, decoded into whole messages for emit (FM1VST's decodePacket)
    // (offset: the message's frame in this render; the core's MIDI out has the same latency as its audio)
    using Emit = void (*)(void *ctx, const uint8_t *msg, uint32_t len, uint32_t offset);
    void drainMidiOut(Emit emit, void *ctx);
};

// RFMKernelBlock.mm: the retained MIDI output block let go (rfmk_free)
void rfmk_drop_midi_out(rfmk *k);
