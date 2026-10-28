// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMLease (M4): who may run a session with the FM-1, shared by every RemoteLink owner on the device (each AUv3
// instance, the standalone app): PLAN.md section 4. One record in an mmap'd file (the App Group container), atomic
// fields only, no file lock (a suspended process holding a lock in a shared container is killed: 0xdead10cc), and a
// Darwin notification on every change.
//
//   claim     epoch + 1 (compare-and-swap), this client written as the owner, the notification; then up to wait_ms
//             for the old owner's ack (released >= the old epoch), unless the old owner was nobody, stale, or this
//             client. Blocking: never on the main thread's critical path, never on the render thread.
//   current   the epoch is still this client's (a relaxed atomic load: the session thread's check before it sends)
//   ack       released = this client's epoch: it has let go (its links closed)
//   heartbeat the owner's wall-clock time, about once a second while its link runs; older than stale_ms (3000): stale
//
// The owner's UUID, pid and name are guarded by a sequence word ((epoch << 1) | writing): a reader that sees it odd,
// changed, or of another epoch, reports the record as not consistent (a claim being written).
#ifndef RFMLEASE_H
#define RFMLEASE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rfml rfml_t;

typedef struct {
    uint64_t epoch, released, my_epoch;
    uint8_t owner[16];          // the owner's UUID (all zero: nobody ever claimed)
    int32_t pid;                // the owner's pid (0: the owner instance is gone, its owner field kept)
    int64_t heartbeat_ms;       // the owner's last heartbeat, wall clock (ms since 1970)
    int64_t age_ms;             // now - heartbeat_ms
    int consistent;             // 0: a claim is being written (owner fields may be the previous owner's)
    int empty;                  // nobody ever claimed
    int stale;                  // the owner's heartbeat is older than stale_ms (or empty)
    int mine;                   // this client holds the current epoch
    int owner_is_me;            // the owner UUID is this client's identity (whatever the epoch)
    char name[128];             // "<host or context> / <core>"
} rfml_view_t;

typedef struct {
    uint64_t epoch;             // the new epoch
    uint64_t previous;          // the epoch taken over
    int waited;                 // 1: an ack was waited for
    int acked;                  // 1: the old owner acknowledged (or there was none to wait for)
    uint32_t wait_ms;           // how long the wait took
} rfml_claim_t;

// the record at path (created if missing, 4096 bytes); notify_name: the Darwin notification ("<group>.lease").
// NULL on failure (err: errno)
rfml_t *rfml_open(const char *path, const char *notify_name, int *err);
void rfml_close(rfml_t *l);

// this client: its UUID (16 bytes) and display name. A new identity forgets the epoch held by the old one.
void rfml_set_identity(rfml_t *l, const uint8_t *uuid, const char *name);
void rfml_set_name(rfml_t *l, const char *name);   // also into the record while this client is the owner
void rfml_set_stale_ms(rfml_t *l, uint32_t ms);    // (tests) default 3000

void rfml_view(rfml_t *l, rfml_view_t *out);
int rfml_claim(rfml_t *l, uint32_t wait_ms, rfml_claim_t *out);    // 1: claimed
int rfml_current(rfml_t *l);                        // lock-free, allocation-free
void rfml_heartbeat(rfml_t *l);                     // only while current
void rfml_ack(rfml_t *l);                           // this client's epoch let go (idempotent)
void rfml_detach(rfml_t *l);                        // the instance is gone: pid 0 if current (owner field kept)
void rfml_release(rfml_t *l);                       // an explicit disconnect: heartbeat 0 if current (stale at once)
uint64_t rfml_my_epoch(rfml_t *l);

// the notification, delivered on a private serial queue (cb may be NULL to stop); counted either way
void rfml_observe(rfml_t *l, void (*cb)(void *ctx), void *ctx);
uint32_t rfml_notifications(rfml_t *l);
void rfml_post(rfml_t *l);

int64_t rfml_wall_ms(void);
// (tests) the owner's heartbeat moved back by ms, as if it had stopped that long ago
void rfml_test_age(rfml_t *l, int64_t ms);
// (tests) a second process: fork()s a child that maps the record at path itself, claims it as uuid (no wait, no
// notification), heartbeats every 20 ms, and when the epoch moves acks and exits; it exits after ms anyway. The child
// only uses system calls and atomics (no allocation: the parent is multithreaded). Returns its pid, -1 on failure.
int rfml_test_child(const char *path, const uint8_t *uuid, uint32_t ms);

#ifdef __cplusplus
}
#endif
#endif
