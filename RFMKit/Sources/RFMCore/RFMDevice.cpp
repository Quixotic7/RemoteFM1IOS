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
    const uint32_t ch = b_.audio_out_channels();
    aux_n_ = ch > 2 ? (ch - 2 < CoreBackend::kMaxAux ? ch - 2 : CoreBackend::kMaxAux) : 0;
    if (aux_n_ && !aux_ring_)
        aux_ring_.reset(new int16_t[(size_t)RING * CoreBackend::kMaxAux]());
    rs_rate_ = 0;                           // (the resampler again, for this core's channels)
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
    bool frame = ms == 0 || ms - last_frame_ >= frame_ms_.load(std::memory_order_relaxed);
    if (frame && behind_ && ms != 0 && ms - last_frame_ < 200u) {   // (the sound first: the redraw waits)
        frame = false;
        deferred_++;
    }
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
        int16_t aux[FM1P_BLOCK * CoreBackend::kMaxAux];   // (aout1: used when the core has channels 3..N)
        if (aux_n_) {
            std::memset(aux, 0, sizeof aux);
            b_.audio_ex(blk, aux, FM1P_BLOCK);
        } else {
            b_.audio(blk, FM1P_BLOCK);
        }
        if (ring_w_ - ring_r_ > RING - FM1P_BLOCK)
            ring_r_ = ring_w_ - (RING - FM1P_BLOCK);   // (overrun: nobody takes the audio; the oldest goes)
        for (uint32_t k = 0; k < FM1P_BLOCK; k++) {
            const uint32_t i = ring_w_++ % RING;
            ring_[2 * i] = blk[2 * k];
            ring_[2 * i + 1] = blk[2 * k + 1];
            if (aux_n_)
                std::memcpy(&aux_ring_[(size_t)i * CoreBackend::kMaxAux], &aux[k * CoreBackend::kMaxAux],
                            CoreBackend::kMaxAux * sizeof(int16_t));
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

void CoreDevice::pop(float &l, float &r, float *aux)   // one device frame, the clock run until it exists
{
    while (ring_r_ == ring_w_)
        run_ms();
    const uint32_t i = ring_r_++ % RING;
    l = (float)ring_[2 * i] * (1.0f / 32768.0f);
    r = (float)ring_[2 * i + 1] * (1.0f / 32768.0f);
    if (aux)                                // (aout1: aux_n_ channels)
        for (uint32_t c = 0; c < aux_n_; c++)
            aux[c] = (float)aux_ring_[(size_t)i * CoreBackend::kMaxAux + c] * (1.0f / 32768.0f);
}

void CoreDevice::render(float *L, float *R, float *const *aux, uint32_t n, double host_rate)
{
    const uint32_t na = aux ? aux_n_ : 0;   // (the channels made; the rest of aux silent)
    if (aux)
        for (uint32_t c = na; c < CoreBackend::kMaxAux; c++)
            if (aux[c])
                std::memset(aux[c], 0, n * sizeof(float));
    if (!booted_) {
        std::memset(L, 0, n * sizeof *L);
        std::memset(R, 0, n * sizeof *R);
        for (uint32_t c = 0; c < na; c++)
            if (aux[c])
                std::memset(aux[c], 0, n * sizeof(float));
        return;
    }
    float x[LagrangeN::MAXCH], y[LagrangeN::MAXCH];
    if (host_rate == (double)FM1P_FS) {     // bypass: the device's samples as they are
        rs_rate_ = 0;
        for (uint32_t k = 0; k < n; k++) {
            at_ = k;
            pop(L[k], R[k], na ? x + 2 : nullptr);
            for (uint32_t c = 0; c < na; c++)
                if (aux[c])
                    aux[c][k] = x[2 + c];
        }
        return;
    }
    // (the channels: the master, and the core's own when someone takes them; a change resets the resampler)
    const int ch = 2 + (int)na;
    if (rs_rate_ != host_rate || rs_.channels() != ch) {
        rs_.reset((double)FM1P_FS, host_rate, ch);
        rs_rate_ = host_rate;
    }
    for (uint32_t k = 0; k < n; k++) {
        at_ = k;
        while (rs_.need()) {
            pop(x[0], x[1], na ? x + 2 : nullptr);
            rs_.push(x);
        }
        rs_.take(y);
        L[k] = y[0];
        R[k] = y[1];
        for (uint32_t c = 0; c < na; c++)
            if (aux[c])
                aux[c][k] = y[2 + c];
    }
}

uint32_t CoreDevice::latency_frames(double host_rate)
{
    if (host_rate == (double)FM1P_FS)
        return FM1P_BLOCK;
    return (uint32_t)((double)(FM1P_BLOCK + Lagrange4::LOOKAHEAD) * host_rate / (double)FM1P_FS + 0.999999);
}

} // namespace rfm
