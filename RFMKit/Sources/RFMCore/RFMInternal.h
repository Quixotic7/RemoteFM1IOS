// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMCore's internal pieces shared by RFMCore.cpp (the link and its pattern producer) and RFMEngine.cpp (the core):
// a single-producer single-consumer queue and a triple buffer (the same as RemoteLink's and fm1remote's engine.h),
// and how an engine reaches an rfmc_t's link.
#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <memory>

#include "RFMCore.h"
#include "rfm/codec.h"
#include "rfm/panel.h"

class RemoteLink;

namespace rfm {

// one producer thread, one consumer thread; lock-free, allocation-free
template <typename T, uint32_t N> class Spsc {
public:
    bool push(const T &e)
    {
        const uint32_t w = w_.load(std::memory_order_relaxed);
        if (w - r_.load(std::memory_order_acquire) >= N)
            return false;
        buf_[w % N] = e;
        w_.store(w + 1, std::memory_order_release);
        return true;
    }
    bool pop(T &e)
    {
        const uint32_t r = r_.load(std::memory_order_relaxed);
        if (r == w_.load(std::memory_order_acquire))
            return false;
        e = buf_[r % N];
        r_.store(r + 1, std::memory_order_release);
        return true;
    }

private:
    std::array<T, N> buf_{};
    std::atomic<uint32_t> w_{0}, r_{0};
};

// one writer, one reader; the reader gets the newest published buffer
template <typename T> class Triple {
public:
    Triple()
    {
        for (auto &p : s_)
            p = std::make_unique<T>();
    }
    T &back() { return *s_[back_]; }
    void publish() { back_ = mid_.exchange(back_ | kFresh, std::memory_order_acq_rel) & 3; }
    const T *take()
    {
        if (!(mid_.load(std::memory_order_acquire) & kFresh))
            return nullptr;
        front_ = mid_.exchange(front_, std::memory_order_acq_rel) & 3;
        return s_[front_].get();
    }
    const T *front() const { return s_[front_].get(); }   // the reader's last taken

private:
    static constexpr int kFresh = 4;
    std::unique_ptr<T> s_[3];
    int back_ = 0, front_ = 2;
    std::atomic<int> mid_{1};
};

// RGB565 with each pixel's bytes big-endian in memory (emu_hal_t.lcd, fm1panel_t.lcd) -> RGBA8888
inline void lcdToRGBA(const uint16_t *lcd, uint8_t *rgba, uint32_t pixels)
{
    const uint8_t *p = reinterpret_cast<const uint8_t *>(lcd);
    for (uint32_t i = 0; i < pixels; i++, p += 2, rgba += 4) {
        const uint32_t v = (uint32_t)p[0] << 8 | p[1];
        const uint32_t r = v >> 11, g = (v >> 5) & 63u, b = v & 31u;
        rgba[0] = (uint8_t)(r << 3 | r >> 2);
        rgba[1] = (uint8_t)(g << 2 | g >> 4);
        rgba[2] = (uint8_t)(b << 3 | b >> 2);
        rgba[3] = 255;
    }
}

} // namespace rfm

// ---- an engine on an rfmc_t (RFMCore.cpp)
RemoteLink *rfmc_link(rfmc_t *c);
// external on: an engine drives the link (pops its events, publishes its frames); the pattern producer stops doing
// either before this returns. Off: the producer takes over again.
void rfmc_set_external(rfmc_t *c, int on);
// the engine's clock thread: an event it applied (the app's Panel card) and the panel it holds now
void rfmc_external_event(rfmc_t *c, const rfm_event_t &e);
void rfmc_external_panel(rfmc_t *c, uint32_t keys, uint32_t buttons, int32_t master);
