// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMRealtime.h: the time-constraint policy and the workgroup hand-over.
#include "RFMRealtime.h"

#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <os/object.h>
#include <pthread.h>

namespace rfm {

bool setRealtime(double period_s)
{
    if (!(period_s > 0))
        period_s = 128.0 / 48000.0;
    if (period_s > 0.05)
        period_s = 0.05;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    const double ticks = 1e9 * (double)tb.denom / (double)tb.numer;   // mach ticks per second
    thread_time_constraint_policy_data_t p;
    p.period = (uint32_t)(period_s * ticks);
    p.computation = (uint32_t)(period_s * 0.5 * ticks);
    p.constraint = p.period;
    p.preemptible = 1;
    return thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                             reinterpret_cast<thread_policy_t>(&p), THREAD_TIME_CONSTRAINT_POLICY_COUNT) == KERN_SUCCESS;
}

WorkgroupSlot::~WorkgroupSlot()
{
    const os_workgroup_t p = pending_.exchange(none());
    if (p != none() && p)
        os_release(p);
    if (cur_)                                           // (the thread left it; only the reference is ours)
        os_release(cur_);
}

void WorkgroupSlot::offer(os_workgroup_t wg)
{
    if (wg)
        os_retain(wg);
    const os_workgroup_t old = pending_.exchange(wg, std::memory_order_acq_rel);
    if (old != none() && old)                           // (offered and never adopted: ours to let go)
        os_release(old);
}

bool WorkgroupSlot::adopt()
{
    const os_workgroup_t wg = pending_.exchange(none(), std::memory_order_acq_rel);
    if (wg == none())
        return false;
    if (wg == cur_ && joined_.load(std::memory_order_relaxed)) {
        if (wg)
            os_release(wg);                             // (the same one again: our extra reference)
        return false;
    }
    leave();
    if (!wg)
        return true;
    cur_ = wg;
    const int r = os_workgroup_join(wg, &token_);
    err_.store(r, std::memory_order_relaxed);
    if (r == 0) {
        joined_.store(true, std::memory_order_relaxed);
        joins_.fetch_add(1, std::memory_order_relaxed);
    }
    return true;
}

void WorkgroupSlot::leave()
{
    if (cur_ && joined_.load(std::memory_order_relaxed))
        os_workgroup_leave(cur_, &token_);
    joined_.store(false, std::memory_order_relaxed);
    if (cur_)
        os_release(cur_);
    cur_ = nullptr;
}

} // namespace rfm
