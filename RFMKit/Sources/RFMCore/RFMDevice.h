// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The device clock and resampler over a core backend (RFMCoreBackend.h). FM1VST v0.6.2's engine/device.{h,cpp}
// (web/emu_web.c's run_ms: tick; frame at ms 0 and every 15 ms, idle otherwise; then every 128-frame audio block due
// at 44.1 kHz into a ring; render() resamples to the host rate), with the core reached through CoreBackend instead
// of an fm1core_t, so a native slot and a Wasm module run on the same clock. Also new here: the time each frame()
// took (the screen redraw: what the render-ahead thread must absorb). FM1VST's pacing (set_pace_ms) is left out:
// nothing here used it.
//
// Threading: all calls on one thread at a time (the core's), as core-api/fm1core.h requires.
#pragma once
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <utility>

#include "RFMCoreBackend.h"
#include "resampler.h"

namespace rfm {

// (aout1) Lagrange4's interpolation (vendor/FM1VST/engine/resampler.h) over up to 10 channels in step: the master
// and channels 3..N resampled alike, so the extra outputs stay sample-aligned with it
class LagrangeN {
public:
    static constexpr int MAXCH = 10;
    void reset(double in_rate, double out_rate, int ch)
    {
        step_ = in_rate / out_rate;
        frac_ = 0.0;
        primed_ = 0;
        ch_ = ch < 1 ? 1 : ch > MAXCH ? MAXCH : ch;
        for (auto &c : h_)
            for (float &v : c)
                v = 0.0f;
    }
    int channels() const { return ch_; }
    int need() const { return primed_ < 3 ? 3 - primed_ : frac_ >= 1.0 ? 1 : 0; }
    void push(const float *x)
    {
        for (int c = 0; c < ch_; c++) {
            float *h = h_[c];
            h[0] = h[1];
            h[1] = h[2];
            h[2] = h[3];
            h[3] = x[c];
        }
        if (primed_ < 3)
            primed_++;
        else
            frac_ -= 1.0;
    }
    void take(float *y)
    {
        const float t = (float)frac_;
        const float c0 = -t * (t - 1.0f) * (t - 2.0f) * (1.0f / 6.0f);
        const float c1 = (t + 1.0f) * (t - 1.0f) * (t - 2.0f) * 0.5f;
        const float c2 = -(t + 1.0f) * t * (t - 2.0f) * 0.5f;
        const float c3 = (t + 1.0f) * t * (t - 1.0f) * (1.0f / 6.0f);
        for (int c = 0; c < ch_; c++) {
            const float *h = h_[c];
            y[c] = c0 * h[0] + c1 * h[1] + c2 * h[2] + c3 * h[3];
        }
        frac_ += step_;
    }

private:
    float h_[MAXCH][4] = {};
    double step_ = 1.0, frac_ = 0.0;
    int primed_ = 0, ch_ = 2;
};

class CoreDevice {
public:
    explicit CoreDevice(CoreBackend &core);

    CoreBackend &core() const { return b_; }
    fm1panel_t *panel() const { return b_.panel(); }

    // power-on from a flash image in memory (ABI 2 flash_stage): n bytes (short: padded with 0xFF; nullptr / 0: a
    // fresh flash); nothing is written to any file
    void boot_from(const uint8_t *bytes, uint32_t n);
    bool booted() const { return booted_; }
    bool halted() const { return b_.halted() != 0; }

    // ---- input (Device's)
    void keys(uint32_t mask);               // bit n: note key n held; a key newly down taps
    void key_vel(int key, int vel);         // 1..127 for its next press (0: the firmware's default)
    void buttons(uint32_t label_mask);      // bit i: label FM1P_B_i held, via panel->btn_id
    void enc(int role, int32_t detents);    // FM1P_E_* role, + clockwise; MASTER: detents x 16 of 1023
    int32_t enc_total(int role) const { return role >= 0 && role < FM1P_NE - 1 ? enc_total_[role] : 0; }
    void master(int32_t v);                 // the MASTER pot, 0..1023
    int midi_in(uint32_t pkt) { return booted_ ? b_.midi_in(pkt) : 0; }
    int midi_out_take(uint32_t *pkt) { return booted_ ? b_.midi_out_take(pkt) : 0; }

    // ---- output
    const uint16_t *lcd() const { return b_.panel()->lcd; }

    // ---- the flash image
    uint8_t *flash() const { return b_.flash(); }
    uint32_t flash_size() const { return b_.flash_size(); }   // (data: any thread)
    uint32_t flash_dirty() const { return b_.flash_dirty(); }
    bool flash_sync() { return booted_ ? b_.flash_sync() != 0 : true; }

    // ---- the clock
    uint32_t ms() const { return dev_ms_; }
    // one device millisecond; `between` (set_between) runs after the tick and before the frame / idle
    using Between = std::function<void(uint32_t ms, bool frame)>;
    void run_ms();
    void set_between(Between b) { between_ = std::move(b); }
    // (the battery) the screen's frame() every this many device ms (15 by default; slower when nobody sees it)
    void set_frame_ms(uint32_t ms) { frame_ms_.store(ms < 15u ? 15u : ms, std::memory_order_relaxed); }
    // (the engine, before each chunk) the audio is running low: a due frame() waits (idle instead), up to 200 ms,
    // so a slow screen redraw never starves the sound
    void set_behind(bool b) { behind_ = b; }
    uint32_t frames_deferred() const { return deferred_; }
    uint32_t take_s16(int16_t *stereo, uint32_t max_frames);
    void discard() { ring_r_ = ring_w_; }   // drop what nobody took (the timer clock)
    // n host frames at host_rate (the device runs as far as needed; bypassed at exactly 44100). aux (aout1):
    // kMaxAux channel buffers (3..10, nullptr: not wanted), silent where the core gives none
    void render(float *L, float *R, uint32_t n, double host_rate) { render(L, R, nullptr, n, host_rate); }
    void render(float *L, float *R, float *const *aux, uint32_t n, double host_rate);
    // (aout1) the core's channels beyond the master (0..8), known from boot
    uint32_t aux_channels() const { return aux_n_; }
    // inside render (`between`): the host frame of this render the device clock is running for (its audio from then
    // on starts there), so what the core does in that millisecond can be placed at that frame
    uint32_t render_frame() const { return at_; }
    static uint32_t latency_frames(double host_rate);

    // frame()'s time: the longest since reset_frame_stats, and the last (mach ticks)
    uint64_t frame_ticks_max() const { return frame_max_; }
    uint64_t frame_ticks_last() const { return frame_last_; }
    void reset_frame_stats() { frame_max_ = 0; }

    static constexpr uint32_t RING = 8192;  // stereo frames

private:
    void pop(float &l, float &r, float *aux);

    CoreBackend &b_;
    bool booted_ = false;
    uint32_t dev_ms_ = 0, last_frame_ = 0;
    std::atomic<uint32_t> frame_ms_{15};
    uint64_t frames_done_ = 0;
    int32_t enc_total_[FM1P_NE - 1] = {};
    int16_t ring_[RING * 2];
    uint32_t ring_w_ = 0, ring_r_ = 0;
    uint32_t aux_n_ = 0;                    // (aout1) the core's channels beyond the master
    std::unique_ptr<int16_t[]> aux_ring_;   // RING x kMaxAux, from the boot of a core that has them
    LagrangeN rs_;
    double rs_rate_ = 0;
    uint64_t frame_max_ = 0, frame_last_ = 0;
    uint32_t at_ = 0;
    bool behind_ = false;
    uint32_t deferred_ = 0;
    Between between_;
};

} // namespace rfm
