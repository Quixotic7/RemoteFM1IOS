// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMProbe: see include/RFMProbe.h.
#include "RFMProbe.h"

#include <CoreFoundation/CoreFoundation.h>
#include <TargetConditionals.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <notify.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>

#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif

extern "C" {
#include "mac_priv.h"       // cm_scan (RemoteMidi.c): reads CoreMIDI's endpoint list, sends nothing
}

// ---- CoreMIDI

int rfmp_midi_candidates(rfmp_candidate_t *out, int max)
{
    cm_cand_t c[32];
    if (max > 32)
        max = 32;
    // cm_scan doesn't use its cm_t (it only enumerates devices and reads their properties), so no client is needed
    const int n = cm_scan(nullptr, c, max, 1, nullptr, nullptr);
    for (int i = 0; i < n; i++) {
        std::snprintf(out[i].name, sizeof out[i].name, "%s", c[i].name);
        out[i].uid = c[i].uid;
    }
    return n;
}

// ---- memory

int64_t rfmp_available_memory(void)
{
#if TARGET_OS_IPHONE
    return (int64_t)os_proc_available_memory();
#else
    return -1;
#endif
}

int64_t rfmp_footprint(void)
{
    task_vm_info_data_t info{};
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) != KERN_SUCCESS)
        return -1;
    return (int64_t)info.phys_footprint;
}

// ---- the shared file

struct rfmp_shm {
    int fd = -1;
    rfmp_shm_view_t *v = nullptr;
};

static uint64_t nowMs()
{
    using namespace std::chrono;
    return (uint64_t)duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

rfmp_shm_t *rfmp_shm_open(const char *path, int *err)
{
    static_assert(sizeof(rfmp_shm_view_t) <= RFMP_SHM_SIZE, "the view fits the file");
    *err = 0;
    const int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) {
        *err = errno;
        return nullptr;
    }
    struct stat st{};
    if (fstat(fd, &st) != 0 || (st.st_size < (off_t)RFMP_SHM_SIZE && ftruncate(fd, RFMP_SHM_SIZE) != 0)) {
        *err = errno;
        close(fd);
        return nullptr;
    }
    void *p = mmap(nullptr, RFMP_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        *err = errno;
        close(fd);
        return nullptr;
    }
    auto *s = new rfmp_shm;
    s->fd = fd;
    s->v = static_cast<rfmp_shm_view_t *>(p);
    uint32_t zero = 0;                              // a new file: claim it (whoever is first)
    if (__atomic_compare_exchange_n(&s->v->magic, &zero, RFMP_SHM_MAGIC, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
        __atomic_store_n(&s->v->version, 1u, __ATOMIC_RELEASE);
    return s;
}

void rfmp_shm_close(rfmp_shm_t *s)
{
    if (!s)
        return;
    munmap(s->v, RFMP_SHM_SIZE);
    close(s->fd);
    delete s;
}

uint64_t rfmp_shm_bump(rfmp_shm_t *s, int role)
{
    const uint64_t c = __atomic_add_fetch(&s->v->counter, 1, __ATOMIC_ACQ_REL);
    if (role >= 0 && role < RFMP_SHM_SLOTS) {
        auto &sl = s->v->slot[role];
        __atomic_store_n(&sl.pid, (int32_t)getpid(), __ATOMIC_RELAXED);
        __atomic_store_n(&sl.role, (int32_t)role, __ATOMIC_RELAXED);
        __atomic_store_n(&sl.time_ms, nowMs(), __ATOMIC_RELAXED);
        __atomic_store_n(&sl.seq, c, __ATOMIC_RELEASE);
    }
    msync(s->v, RFMP_SHM_SIZE, MS_ASYNC);
    return c;
}

void rfmp_shm_read(rfmp_shm_t *s, rfmp_shm_view_t *out)
{
    out->magic = __atomic_load_n(&s->v->magic, __ATOMIC_ACQUIRE);
    out->version = __atomic_load_n(&s->v->version, __ATOMIC_ACQUIRE);
    out->counter = __atomic_load_n(&s->v->counter, __ATOMIC_ACQUIRE);
    for (int i = 0; i < RFMP_SHM_SLOTS; i++) {
        auto &sl = s->v->slot[i];
        out->slot[i].seq = __atomic_load_n(&sl.seq, __ATOMIC_ACQUIRE);
        out->slot[i].pid = __atomic_load_n(&sl.pid, __ATOMIC_RELAXED);
        out->slot[i].role = __atomic_load_n(&sl.role, __ATOMIC_RELAXED);
        out->slot[i].time_ms = __atomic_load_n(&sl.time_ms, __ATOMIC_RELAXED);
    }
}

// ---- Darwin notifications

namespace {
std::mutex gDarwinMu;
std::map<std::string, std::atomic<uint32_t> *> gDarwin;     // (never freed: a handful of names per process)

void darwinCallback(CFNotificationCenterRef, void *observer, CFNotificationName, const void *, CFDictionaryRef)
{
    static_cast<std::atomic<uint32_t> *>(observer)->fetch_add(1, std::memory_order_relaxed);
}
}

void rfmp_darwin_observe(const char *name)
{
    std::lock_guard<std::mutex> g(gDarwinMu);
    if (gDarwin.count(name))
        return;
    auto *count = new std::atomic<uint32_t>(0);
    gDarwin[name] = count;
    CFStringRef n = CFStringCreateWithCString(nullptr, name, kCFStringEncodingUTF8);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), count, darwinCallback, n, nullptr,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFRelease(n);
}

uint32_t rfmp_darwin_count(const char *name)
{
    std::lock_guard<std::mutex> g(gDarwinMu);
    auto it = gDarwin.find(name);
    return it == gDarwin.end() ? 0 : it->second->load(std::memory_order_relaxed);
}

void rfmp_darwin_post(const char *name)
{
    CFStringRef n = CFStringCreateWithCString(nullptr, name, kCFStringEncodingUTF8);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), n, nullptr, nullptr, true);
    CFRelease(n);
}

// ---- notify(3) state

namespace {
std::mutex gNotifyMu;
std::map<std::string, int> gNotifyTokens;               // the setter's tokens, kept so notifyd keeps the state
}

uint32_t rfmp_notify_set(const char *name, uint64_t v)
{
    std::lock_guard<std::mutex> g(gNotifyMu);
    int token = 0;
    auto it = gNotifyTokens.find(name);
    if (it == gNotifyTokens.end()) {
        const uint32_t st = notify_register_check(name, &token);
        if (st != NOTIFY_STATUS_OK)
            return st;
        gNotifyTokens[name] = token;
    } else {
        token = it->second;
    }
    const uint32_t st = notify_set_state(token, v);
    if (st == NOTIFY_STATUS_OK)
        notify_post(name);
    return st;
}

uint32_t rfmp_notify_get(const char *name, uint64_t *v)
{
    int token = 0;
    *v = 0;
    uint32_t st = notify_register_check(name, &token);
    if (st != NOTIFY_STATUS_OK)
        return st;
    st = notify_get_state(token, v);
    notify_cancel(token);
    return st;
}

// ---- the ticker thread

struct rfmp_ticker {
    std::atomic<bool> quit{false};
    std::atomic<uint64_t> ticks{0};
    std::thread th;
};

rfmp_ticker_t *rfmp_ticker_start(int *ok)
{
    auto *t = new rfmp_ticker;
    try {
        t->th = std::thread([t] {
            while (!t->quit.load(std::memory_order_relaxed)) {
                t->ticks.fetch_add(1, std::memory_order_relaxed);
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
        });
        *ok = 1;
    } catch (...) {
        *ok = 0;
    }
    return t;
}

uint64_t rfmp_ticker_ticks(rfmp_ticker_t *t) { return t ? t->ticks.load(std::memory_order_relaxed) : 0; }

void rfmp_ticker_stop(rfmp_ticker_t *t)
{
    if (!t)
        return;
    t->quit = true;
    if (t->th.joinable())
        t->th.join();
    delete t;
}
