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
#include <cstdint>
#include <functional>
#include <utility>

#include "RFMCoreBackend.h"
#include "resampler.h"

namespace rfm {

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
    uint32_t take_s16(int16_t *stereo, uint32_t max_frames);
    void discard() { ring_r_ = ring_w_; }   // drop what nobody took (the timer clock)
    // n host frames at host_rate (the device runs as far as needed; bypassed at exactly 44100)
    void render(float *L, float *R, uint32_t n, double host_rate);
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
    void pop(float &l, float &r);

    CoreBackend &b_;
    bool booted_ = false;
    uint32_t dev_ms_ = 0, last_frame_ = 0;
    uint64_t frames_done_ = 0;
    int32_t enc_total_[FM1P_NE - 1] = {};
    int16_t ring_[RING * 2];
    uint32_t ring_w_ = 0, ring_r_ = 0;
    Lagrange4 rs_;
    double rs_rate_ = 0;
    uint64_t frame_max_ = 0, frame_last_ = 0;
    uint32_t at_ = 0;
    Between between_;
};

} // namespace rfm
