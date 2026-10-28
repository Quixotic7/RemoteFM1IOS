// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The render kernel's state, shared by RFMKernel.cpp and the render block (RFMKernelBlock.mm).
#pragma once
#include "RFMKernel.h"
#include "RFMProbe.h"

#include <atomic>
#include <cstdint>
#include <vector>

struct rfmk {
    // set by allocate / deallocate (never while rendering)
    double sampleRate = 44100;
    uint32_t channels = 2, maxFrames = 0;
    std::vector<float> storage;                 // channels x maxFrames
    std::vector<float *> bufs;

    // read by any thread
    std::atomic<uint64_t> renders{0}, frames{0}, midiEvents{0};
    std::atomic<uint32_t> lastMidi{0};          // bytes 0..2, length in bits 24..31

    // the session thread's stand-in (M4 puts RemoteLink's thread here)
    rfmp_ticker_t *ticker = nullptr;
    int threadOk = 0;

    // the render thread's work: silence, and the MIDI counted. Lock-free and allocation-free.
    void midi(const uint8_t *b, uint32_t n)
    {
        midiEvents.fetch_add(1, std::memory_order_relaxed);
        uint32_t v = (n > 3 ? 3u : n) << 24;
        for (uint32_t i = 0; i < n && i < 3; i++)
            v |= (uint32_t)b[i] << (8 * i);
        lastMidi.store(v, std::memory_order_relaxed);
    }

    void counted(uint32_t n)
    {
        renders.fetch_add(1, std::memory_order_relaxed);
        frames.fetch_add(n, std::memory_order_relaxed);
    }
};
