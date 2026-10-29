// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// What the engine's core thread needs to run beside the audio callback (RFMEngine.cpp): a Mach semaphore (signalled
// from the audio thread: no locks, no allocation; waited on with a timeout), the real-time time-constraint policy,
// and an audio workgroup handed over from any thread (the AU's render context observer runs on the render thread)
// and joined on the core thread itself (os_workgroup_join must be called by the joining thread).
#pragma once
#include <mach/mach.h>
#include <os/workgroup.h>

#include <atomic>
#include <cstdint>

namespace rfm {

class Semaphore {
public:
    Semaphore() { semaphore_create(mach_task_self(), &s_, SYNC_POLICY_FIFO, 0); }
    ~Semaphore() { semaphore_destroy(mach_task_self(), s_); }
    Semaphore(const Semaphore &) = delete;
    Semaphore &operator=(const Semaphore &) = delete;
    void signal() { semaphore_signal(s_); }             // real-time safe (one Mach trap)
    // false: timed out
    bool wait_us(uint32_t us)
    {
        mach_timespec_t t{us / 1000000u, (clock_res_t)((us % 1000000u) * 1000u)};
        return semaphore_timedwait(s_, t) == KERN_SUCCESS;
    }

private:
    semaphore_t s_ = MACH_PORT_NULL;
};

// the calling thread as a Mach real-time (time-constraint) thread whose period is `period_s` (the host buffer's
// duration): computation half the period, constraint the period, preemptible. false: refused
bool setRealtime(double period_s);

// An os_workgroup for one thread to join (Apple's AudioWorkInterval.h, cases 1 and 2). offer() from any thread
// (real-time safe: an os_retain and an atomic exchange); adopt() on the joining thread leaves the one it is in and
// joins the newest offered (nullptr: none); leave() on the same thread before it ends.
class WorkgroupSlot {
public:
    ~WorkgroupSlot();
    void offer(os_workgroup_t wg);
    // true when something changed
    bool adopt();
    void leave();
    bool joined() const { return joined_.load(std::memory_order_relaxed); }
    uint32_t joins() const { return joins_.load(std::memory_order_relaxed); }
    int last_error() const { return err_.load(std::memory_order_relaxed); }

private:
    static os_workgroup_t none() { return reinterpret_cast<os_workgroup_t>(uintptr_t(1)); }   // nothing offered
    std::atomic<os_workgroup_t> pending_{none()};
    os_workgroup_t cur_ = nullptr;                      // (the joining thread's)
    os_workgroup_join_token_s token_{};
    std::atomic<bool> joined_{false};
    std::atomic<uint32_t> joins_{0};
    std::atomic<int> err_{0};
};

} // namespace rfm
