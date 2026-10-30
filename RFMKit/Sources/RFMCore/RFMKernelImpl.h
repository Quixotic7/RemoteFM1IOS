// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The render kernel's state, shared by RFMKernel.cpp and the render block (RFMKernelBlock.mm).
#pragma once
#include "RFMEngine.h"
#include "RFMHostClock.h"
#include "RFMKernel.h"
#include "RFMProbe.h"

#include <atomic>
#include <cstdint>
#include <vector>

struct rfmk {
    static constexpr uint32_t kMaxEvents = 512;
    static constexpr uint32_t kSysExMax = 4096;
    static constexpr uint32_t kMaxClock = 128;      // the host clock's messages in one buffer
    static constexpr uint32_t kMaxParams = 256;     // the host's parameter changes in one buffer

    // set by allocate / deallocate / set_* (never while rendering)
    double sampleRate = 44100;
    uint32_t channels = 2, maxFrames = 0;
    std::vector<float> storage;                 // channels x maxFrames
    std::vector<float *> bufs;
    std::vector<float> scratch;                 // the second channel of a mono output
    rfme_t *engine = nullptr;
    void *midiOut = nullptr;                    // the host's AUMIDIOutputEventBlock (retained; RFMKernelBlock.mm)
    void *musical = nullptr, *transport = nullptr;  // its musicalContextBlock, transportStateBlock (retained)

    // the render thread's own
    rfme_midi_t ev[kMaxEvents] = {};
    uint32_t nev = 0;
    uint8_t sysex[kSysExMax] = {};
    uint32_t sysexLen = 0;
    bool sysexOverflow = false;
    rfmhc_t hc{};                               // the host's clock as MIDI (RFMHostClock.h)
    rfme_midi_t clk[kMaxClock] = {};
    rfme_param_ev_t pev[kMaxParams] = {};       // the host's parameter changes (the AU's tree), in order
    uint32_t npev = 0;
    bool dropClock = false;                     // this buffer: the host's own clock bytes dropped (ours replace them)

    // read by any thread
    std::atomic<uint64_t> renders{0}, frames{0}, midiEvents{0}, sounding{0};
    std::atomic<uint32_t> lastMidi{0};          // bytes 0..2, length in bits 24..31
    std::atomic<uint32_t> midiOutMsgs{0};
    std::atomic<double> levelSum{0};            // (one writer: the render thread)
    std::atomic<uint64_t> levelFrames{0};
    std::atomic<bool> levelReset{false};
    std::atomic<bool> hostClockOn{true};        // (AUSettings.hostClock)
    std::atomic<uint32_t> clockMsgs{0}, clockDropped{0};
    std::atomic<int> hostState{0};              // rfmk_stats_t.host_clock
    std::atomic<double> hostTempo{0}, hostBeat{0};
    std::atomic<uint32_t> paramEvents{0};       // the host's parameter changes seen in renders

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
        if (dropClock && (b[0] == 0xF8 || b[0] == 0xFA || b[0] == 0xFB || b[0] == 0xFC || b[0] == 0xF2)) {
            clockDropped.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        rfme_midi_t &e = ev[nev++];
        e.offset = offset;
        e.len = (uint8_t)n;
        for (uint32_t i = 0; i < 3; i++)
            e.data[i] = i < n ? b[i] : 0;
    }

    // the host clock's messages for this buffer (in) merged into the queued MIDI by frame (the clock first at a
    // frame); off: a Stop if it was running. Render thread.
    void hostClock(const rfmhc_input_t &in, bool on)
    {
        uint32_t nc = 0;
        if (on) {
            nc = rfmhc_run(&hc, &in, clk, kMaxClock);
            hostTempo.store(in.tempo, std::memory_order_relaxed);
            hostBeat.store(in.beat, std::memory_order_relaxed);
            hostState.store(!in.has_context || !in.has_transport ? 1 : in.moving ? 3 : 2, std::memory_order_relaxed);
        } else {
            if (hc.running)
                clk[nc++] = rfme_midi_t{0, 1, {0xFC, 0, 0}};
            rfmhc_reset(&hc);
            hostState.store(0, std::memory_order_relaxed);
        }
        if (nc > kMaxEvents - nev)
            nc = kMaxEvents - nev;
        uint32_t i = nev, j = nc, w = nev + nc;
        while (j > 0) {
            if (i > 0 && ev[i - 1].offset >= clk[j - 1].offset)
                ev[--w] = ev[--i];
            else
                ev[--w] = clk[--j];
        }
        nev += nc;
        clockMsgs.fetch_add(nc, std::memory_order_relaxed);
    }

    // one host parameter change (a render event; a ramp's end value at its start). Lock-free and allocation-free.
    void param(uint64_t address, float value, uint32_t offset)
    {
        paramEvents.fetch_add(1, std::memory_order_relaxed);
        if (address >= RFME_HP_COUNT || npev >= kMaxParams)
            return;
        pev[npev++] = rfme_param_ev_t{offset, (uint32_t)address, value};
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

// RFMKernelBlock.mm: the retained MIDI output block let go (rfmk_free); the host's context blocks too
void rfmk_drop_midi_out(rfmk *k);
void rfmk_drop_host_blocks(rfmk *k);
