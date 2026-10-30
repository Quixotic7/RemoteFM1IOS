// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The device clock (RFMDevice.h): FM1VST v0.6.2's engine/device.cpp over CoreBackend.
#include "RFMDevice.h"

#include <mach/mach_time.h>

#include <cstring>

namespace rfm {

CoreDevice::CoreDevice(CoreBackend &core) : b_(core) { std::memset(ring_, 0, sizeof ring_); }

void CoreDevice::boot_from(const uint8_t *bytes, uint32_t n)
{
    if (booted_)
        return;
    b_.flash_stage(bytes, bytes ? n : 0u);
    b_.options(FM1CORE_FLASH_STAGED, 0, 0, 1);
    if (b_.has_boot_options())
        b_.boot_options(-1, nullptr, -1);   // a power-on with a clean guard record (emu.c's defaults)
    b_.panel()->ready = 2;                  // simulated time (fm1_ticks = the device clock), before init
    b_.init(0);
    booted_ = true;
}

// ------------------------------------------------------------------ input ---
void CoreDevice::keys(uint32_t m)
{
    fm1panel_t *h = b_.panel();
    m &= (1u << FM1P_NKEY) - 1u;
    h->keys_tap |= m & ~h->keys;
    h->keys = m;
}

void CoreDevice::key_vel(int key, int vel)
{
    if (key >= 0 && key < FM1P_NKEY)
        b_.panel()->key_vel[key] = (uint8_t)(vel < 0 ? 0 : vel > 127 ? 127 : vel);
}

void CoreDevice::buttons(uint32_t m)
{
    fm1panel_t *h = b_.panel();
    uint32_t b = 0;                         // label bits -> matrix bits
    for (uint32_t i = 0; i < FM1P_NB; i++)
        if (m & (1u << i))
            b |= 1u << h->btn_id[i];
    h->buttons_tap |= b & ~h->buttons;
    h->buttons = b;
}

void CoreDevice::enc(int role, int32_t n)
{
    fm1panel_t *h = b_.panel();
    if (role == FM1P_E_MASTER) {
        const int32_t m = h->master + n * 16;
        h->master = m < 0 ? 0 : m > 1023 ? 1023 : m;
    } else if (role >= 0 && role < FM1P_NE - 1) {
        h->enc[h->enc_id[role]] += n * h->enc_dir[role];
        enc_total_[role] += n;
    }
}

void CoreDevice::master(int32_t v) { b_.panel()->master = v < 0 ? 0 : v > 1023 ? 1023 : v; }

// ------------------------------------------------------------------ clock ---
void CoreDevice::run_ms()
{
    const uint32_t ms = dev_ms_++;
    b_.tick(ms);
    const bool frame = ms == 0 || ms - last_frame_ >= 15u;
    if (between_)
        between_(ms, frame);
    if (frame) {
        last_frame_ = ms;
        const uint64_t t0 = mach_absolute_time();
        b_.frame();
        frame_last_ = mach_absolute_time() - t0;
        if (frame_last_ > frame_max_)
            frame_max_ = frame_last_;
    } else {
        b_.idle();
    }
    while (frames_done_ + FM1P_BLOCK <= (uint64_t)ms * FM1P_FS / 1000u) {
        int16_t blk[FM1P_BLOCK * 2];
        b_.audio(blk, FM1P_BLOCK);
        if (ring_w_ - ring_r_ > RING - FM1P_BLOCK)
            ring_r_ = ring_w_ - (RING - FM1P_BLOCK);   // (overrun: nobody takes the audio; the oldest goes)
        for (uint32_t k = 0; k < FM1P_BLOCK; k++) {
            const uint32_t i = ring_w_++ % RING;
            ring_[2 * i] = blk[2 * k];
            ring_[2 * i + 1] = blk[2 * k + 1];
        }
        frames_done_ += FM1P_BLOCK;
    }
}

uint32_t CoreDevice::take_s16(int16_t *out, uint32_t max_frames)
{
    uint32_t n = 0;
    while (n < max_frames && ring_r_ != ring_w_) {
        const uint32_t i = ring_r_++ % RING;
        out[2 * n] = ring_[2 * i];
        out[2 * n + 1] = ring_[2 * i + 1];
        n++;
    }
    return n;
}

void CoreDevice::pop(float &l, float &r)    // one device frame, the clock run until it exists
{
    while (ring_r_ == ring_w_)
        run_ms();
    const uint32_t i = ring_r_++ % RING;
    l = (float)ring_[2 * i] * (1.0f / 32768.0f);
    r = (float)ring_[2 * i + 1] * (1.0f / 32768.0f);
}

void CoreDevice::render(float *L, float *R, uint32_t n, double host_rate)
{
    if (!booted_) {
        std::memset(L, 0, n * sizeof *L);
        std::memset(R, 0, n * sizeof *R);
        return;
    }
    if (host_rate == (double)FM1P_FS) {     // bypass: the device's samples as they are
        rs_rate_ = 0;
        for (uint32_t k = 0; k < n; k++) {
            at_ = k;
            pop(L[k], R[k]);
        }
        return;
    }
    if (rs_rate_ != host_rate) {
        rs_.reset((double)FM1P_FS, host_rate);
        rs_rate_ = host_rate;
    }
    for (uint32_t k = 0; k < n; k++) {
        at_ = k;
        while (rs_.need()) {
            float l, r;
            pop(l, r);
            rs_.push(l, r);
        }
        rs_.take(L[k], R[k]);
    }
}

uint32_t CoreDevice::latency_frames(double host_rate)
{
    if (host_rate == (double)FM1P_FS)
        return FM1P_BLOCK;
    return (uint32_t)((double)(FM1P_BLOCK + Lagrange4::LOOKAHEAD) * host_rate / (double)FM1P_FS + 0.999999);
}

} // namespace rfm
