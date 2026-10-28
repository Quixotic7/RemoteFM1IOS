// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The lease (include/RFMLease.h): one record in a shared mmap'd file, atomics only.
#include "RFMLease.h"

#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

namespace {

constexpr uint32_t kMagic = 0x4C314D52u;   // 'RM1L'
constexpr uint32_t kVersion = 1;
constexpr size_t kSize = 4096;
constexpr size_t kNameMax = 128;

// The shared record. Lock-free 32- and 64-bit atomics are address-free, so they work across processes.
struct Record {
    std::atomic<uint32_t> magic;
    std::atomic<uint32_t> version;
    std::atomic<uint64_t> epoch;            // bumped by every claim
    std::atomic<uint64_t> seq;              // (epoch << 1) | 1 while that epoch's claimer writes the owner fields
    std::atomic<uint64_t> uuidHi, uuidLo;
    std::atomic<int32_t> pid;
    std::atomic<int32_t> pad;
    std::atomic<int64_t> heartbeat;         // wall clock ms
    std::atomic<uint64_t> released;         // the newest epoch whose owner let go
    std::atomic<uint64_t> name[kNameMax / 8];   // the name, 8 bytes per word
};
static_assert(sizeof(Record) <= kSize, "record");
static_assert(std::atomic<uint64_t>::is_always_lock_free, "64-bit atomics");

uint64_t load64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 0; i < 8; i++)
        v = v << 8 | p[i];
    return v;
}

void store64(uint8_t *p, uint64_t v)
{
    for (int i = 7; i >= 0; i--, v >>= 8)
        p[i] = (uint8_t)v;
}

} // namespace

struct rfml {
    int fd = -1;
    Record *r = nullptr;
    std::string notifyName;
    std::mutex mu;                          // this client's own fields (identity, name)
    uint8_t uuid[16] = {};
    std::string name;
    std::atomic<uint64_t> myEpoch{0};
    std::atomic<uint32_t> staleMs{3000};
    // the notification
    int token = -1;
    dispatch_queue_t q = nullptr;
    std::atomic<void (*)(void *)> cb{nullptr};
    std::atomic<void *> cbCtx{nullptr};
    std::atomic<uint32_t> received{0};

    bool isMe(uint64_t hi, uint64_t lo)
    {
        std::lock_guard<std::mutex> g(mu);
        return load64(uuid) == hi && load64(uuid + 8) == lo;
    }

    // the owner fields, for epoch e (only while e is current)
    void writeOwner(uint64_t e, int32_t pid, int64_t hb)
    {
        uint8_t id[16];
        char nm[kNameMax] = {};
        {
            std::lock_guard<std::mutex> g(mu);
            std::memcpy(id, uuid, 16);
            std::strncpy(nm, name.c_str(), kNameMax - 1);
        }
        if (r->epoch.load() != e)
            return;
        r->seq.store(e << 1 | 1u);
        r->uuidHi.store(load64(id));
        r->uuidLo.store(load64(id + 8));
        r->pid.store(pid);
        r->heartbeat.store(hb);
        for (size_t i = 0; i < kNameMax / 8; i++) {
            uint64_t w;
            std::memcpy(&w, nm + i * 8, 8);
            r->name[i].store(w, std::memory_order_relaxed);
        }
        r->seq.store(e << 1);
    }

    void post()
    {
        if (!notifyName.empty())
            notify_post(notifyName.c_str());
    }
};

extern "C" {

int64_t rfml_wall_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

rfml_t *rfml_open(const char *path, const char *notify_name, int *err)
{
    if (err)
        *err = 0;
    const int fd = ::open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) {
        if (err)
            *err = errno;
        return nullptr;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || ((size_t)st.st_size < kSize && ftruncate(fd, (off_t)kSize) != 0)) {
        if (err)
            *err = errno;
        ::close(fd);
        return nullptr;
    }
    void *m = mmap(nullptr, kSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) {
        if (err)
            *err = errno;
        ::close(fd);
        return nullptr;
    }
    auto *l = new rfml;
    l->fd = fd;
    l->r = static_cast<Record *>(m);
    l->notifyName = notify_name ? notify_name : "";
    uint32_t z = 0;
    if (l->r->magic.compare_exchange_strong(z, kMagic))   // (a new file: all zero, which is an empty lease)
        l->r->version.store(kVersion);
    if (!l->notifyName.empty()) {
        l->q = dispatch_queue_create("com.quixotic7.remotefm1.lease", DISPATCH_QUEUE_SERIAL);
        rfml_t *self = l;
        notify_register_dispatch(l->notifyName.c_str(), &l->token, l->q, ^(int) {
            self->received.fetch_add(1);
            if (auto f = self->cb.load())
                f(self->cbCtx.load());
        });
    }
    return l;
}

void rfml_close(rfml_t *l)
{
    if (!l)
        return;
    if (l->token >= 0)
        notify_cancel(l->token);
    if (l->q) {
        dispatch_sync(l->q, ^{});                 // (a handler running now finishes first)
#if !OS_OBJECT_USE_OBJC
        dispatch_release(l->q);
#endif
    }
    munmap(l->r, kSize);
    ::close(l->fd);
    delete l;
}

void rfml_set_identity(rfml_t *l, const uint8_t *uuid, const char *name)
{
    {
        std::lock_guard<std::mutex> g(l->mu);
        if (std::memcmp(l->uuid, uuid, 16) != 0)
            l->myEpoch.store(0);
        std::memcpy(l->uuid, uuid, 16);
        if (name)
            l->name = name;
    }
}

void rfml_set_name(rfml_t *l, const char *name)
{
    {
        std::lock_guard<std::mutex> g(l->mu);
        l->name = name ? name : "";
    }
    const uint64_t e = l->myEpoch.load();
    if (e && l->r->epoch.load() == e) {
        l->writeOwner(e, getpid(), l->r->heartbeat.load());
        l->post();
    }
}

void rfml_set_stale_ms(rfml_t *l, uint32_t ms) { l->staleMs.store(ms); }

void rfml_view(rfml_t *l, rfml_view_t *out)
{
    std::memset(out, 0, sizeof *out);
    Record *r = l->r;
    for (int tries = 0; tries < 100; tries++) {
        const uint64_t s1 = r->seq.load();
        out->epoch = r->epoch.load();
        const uint64_t hi = r->uuidHi.load(), lo = r->uuidLo.load();
        out->pid = r->pid.load();
        out->heartbeat_ms = r->heartbeat.load();
        char nm[kNameMax];
        for (size_t i = 0; i < kNameMax / 8; i++) {
            const uint64_t w = r->name[i].load(std::memory_order_relaxed);
            std::memcpy(nm + i * 8, &w, 8);
        }
        nm[kNameMax - 1] = 0;
        const uint64_t s2 = r->seq.load();
        store64(out->owner, hi);
        store64(out->owner + 8, lo);
        std::memcpy(out->name, nm, sizeof out->name);
        out->consistent = s1 == s2 && !(s1 & 1u) && (s1 >> 1) == out->epoch;
        out->empty = hi == 0 && lo == 0;
        out->owner_is_me = !out->empty && l->isMe(hi, lo);
        if (out->consistent || out->epoch == 0)
            break;
        std::this_thread::yield();
    }
    out->released = r->released.load();
    out->my_epoch = l->myEpoch.load();
    out->mine = out->my_epoch != 0 && out->my_epoch == out->epoch;
    out->age_ms = rfml_wall_ms() - out->heartbeat_ms;
    out->stale = out->empty || out->age_ms > (int64_t)l->staleMs.load();
}

int rfml_claim(rfml_t *l, uint32_t wait_ms, rfml_claim_t *out)
{
    rfml_claim_t c{};
    rfml_view_t prev;
    uint64_t e;
    for (;;) {
        rfml_view(l, &prev);
        e = prev.epoch;
        if (l->r->epoch.compare_exchange_strong(e, prev.epoch + 1))
            break;
    }
    c.previous = prev.epoch;
    c.epoch = prev.epoch + 1;
    l->myEpoch.store(c.epoch);
    l->writeOwner(c.epoch, getpid(), rfml_wall_ms());
    l->post();
    // the old owner's ack: not for nobody, a stale owner, an owner that let go already, or this same client
    const bool self = prev.owner_is_me && prev.pid == getpid();
    const bool wait = c.previous != 0 && !prev.empty && !prev.stale && !self && prev.released < c.previous;
    c.acked = 1;
    if (wait && wait_ms) {
        c.waited = 1;
        c.acked = 0;
        const auto t0 = std::chrono::steady_clock::now();
        for (;;) {
            if (l->r->released.load() >= c.previous) {
                c.acked = 1;
                break;
            }
            const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0);
            if (ms.count() >= (long long)wait_ms)
                break;
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        c.wait_ms = (uint32_t)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0)
                        .count();
    }
    if (out)
        *out = c;
    return l->r->epoch.load() == c.epoch;
}

int rfml_current(rfml_t *l)
{
    const uint64_t e = l->myEpoch.load(std::memory_order_relaxed);
    return e != 0 && l->r->epoch.load(std::memory_order_acquire) == e;
}

void rfml_heartbeat(rfml_t *l)
{
    if (rfml_current(l))
        l->r->heartbeat.store(rfml_wall_ms());
}

void rfml_ack(rfml_t *l)
{
    const uint64_t e = l->myEpoch.load();
    if (!e)
        return;
    uint64_t r = l->r->released.load();
    bool moved = false;
    while (r < e && !(moved = l->r->released.compare_exchange_weak(r, e))) {
    }
    if (moved)
        l->post();
}

void rfml_detach(rfml_t *l)
{
    const uint64_t e = l->myEpoch.load();
    if (e && l->r->epoch.load() == e) {
        l->writeOwner(e, 0, l->r->heartbeat.load());
        l->post();
    }
}

void rfml_release(rfml_t *l)
{
    if (rfml_current(l)) {
        l->r->heartbeat.store(0);
        l->post();
    }
}

uint64_t rfml_my_epoch(rfml_t *l) { return l->myEpoch.load(); }

void rfml_observe(rfml_t *l, void (*cb)(void *ctx), void *ctx)
{
    if (!cb) {
        l->cb.store(nullptr);
        if (l->q)
            dispatch_sync(l->q, ^{});             // (a handler running now has finished when this returns)
        l->cbCtx.store(nullptr);
        return;
    }
    l->cbCtx.store(ctx);
    l->cb.store(cb);
}

uint32_t rfml_notifications(rfml_t *l) { return l->received.load(); }

void rfml_post(rfml_t *l) { l->post(); }

void rfml_test_age(rfml_t *l, int64_t ms) { l->r->heartbeat.fetch_sub(ms); }

int rfml_test_child(const char *path, const uint8_t *uuid, uint32_t ms)
{
#if !TARGET_OS_OSX
    (void)path, (void)uuid, (void)ms;
    return -1;                                  // (the Mac tests only)
#else
    const int fd = ::open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return -1;
    void *m = mmap(nullptr, kSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    ::close(fd);
    if (m == MAP_FAILED)
        return -1;
    const pid_t pid = fork();
    if (pid != 0) {
        munmap(m, kSize);
        return pid;                             // (the parent; -1: fork failed)
    }
    Record *r = static_cast<Record *>(m);
    uint64_t e = r->epoch.load();
    while (!r->epoch.compare_exchange_weak(e, e + 1)) {
    }
    const uint64_t mine = e + 1;
    r->seq.store(mine << 1 | 1u);
    r->uuidHi.store(load64(uuid));
    r->uuidLo.store(load64(uuid + 8));
    r->pid.store(getpid());
    r->heartbeat.store(rfml_wall_ms());
    const char nm[16] = "test child";
    for (size_t i = 0; i < kNameMax / 8; i++) {
        uint64_t w = 0;
        if (i < 2)
            std::memcpy(&w, nm + i * 8, 8);
        r->name[i].store(w, std::memory_order_relaxed);
    }
    r->seq.store(mine << 1);
    const int64_t end = rfml_wall_ms() + ms;
    while (rfml_wall_ms() < end) {
        if (r->epoch.load() != mine) {          // (taken over: let go)
            uint64_t rel = r->released.load();
            while (rel < mine && !r->released.compare_exchange_weak(rel, mine)) {
            }
            _exit(0);
        }
        r->heartbeat.store(rfml_wall_ms());
        usleep(20000);
    }
    _exit(1);
#endif
}

} // extern "C"
