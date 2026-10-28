// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMProbe: the C pieces of M2's probes (RFMKit's Probes.swift runs them in the app and in the AUv3 extension).
// Nothing here sends MIDI or connects to an endpoint: the CoreMIDI part only reads the endpoint list.
#ifndef RFMPROBE_H
#define RFMPROBE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- CoreMIDI: the endpoints FM1VST's back end would offer HELLO to (RemoteMidi.c's cm_scan, read-only)
typedef struct {
    char name[64];              // the destination's display name
    int32_t uid;
} rfmp_candidate_t;
int rfmp_midi_candidates(rfmp_candidate_t *out, int max);   // how many were copied

// ---- memory: os_proc_available_memory() (-1 where the call doesn't exist: macOS) and phys_footprint (-1: failed)
int64_t rfmp_available_memory(void);
int64_t rfmp_footprint(void);

// ---- a shared mmap'd file (what the lease in PLAN.md section 4 will use): no file lock, only atomics
#define RFMP_SHM_SIZE 4096u
#define RFMP_SHM_MAGIC 0x524D3150u     // 'RM1P'
#define RFMP_SHM_SLOTS 8
typedef struct {
    int32_t pid, role;
    uint64_t seq, time_ms;      // seq: the counter after this writer's bump (0: never written)
} rfmp_shm_slot_t;
typedef struct {
    uint32_t magic, version;
    uint64_t counter;           // bumped by every rfmp_shm_bump
    rfmp_shm_slot_t slot[RFMP_SHM_SLOTS];       // the last writer of each role
} rfmp_shm_view_t;
// slot i of a view (Swift sees the array as a tuple)
static inline rfmp_shm_slot_t rfmp_shm_slot(const rfmp_shm_view_t *v, int i) { return v->slot[i]; }
typedef struct rfmp_shm rfmp_shm_t;
rfmp_shm_t *rfmp_shm_open(const char *path, int *err);       // err: errno on failure
void rfmp_shm_close(rfmp_shm_t *s);
// counter + 1, and slot[role] = this pid / the new counter / now; returns the new counter
uint64_t rfmp_shm_bump(rfmp_shm_t *s, int role);
void rfmp_shm_read(rfmp_shm_t *s, rfmp_shm_view_t *out);

// ---- Darwin notifications (CFNotificationCenterGetDarwinNotifyCenter): counted per name, delivered on the main
// thread's run loop
void rfmp_darwin_observe(const char *name);
uint32_t rfmp_darwin_count(const char *name);
void rfmp_darwin_post(const char *name);

// ---- notify(3) state: 64 bits per name, held by notifyd while a token is registered (the setter keeps its own)
uint32_t rfmp_notify_set(const char *name, uint64_t v);     // NOTIFY_STATUS_OK (0) or the error
uint32_t rfmp_notify_get(const char *name, uint64_t *v);

// ---- a plain std::thread (the future session thread's stand-in): ticks every 5 ms until stopped
typedef struct rfmp_ticker rfmp_ticker_t;
rfmp_ticker_t *rfmp_ticker_start(int *ok);
uint64_t rfmp_ticker_ticks(rfmp_ticker_t *t);
void rfmp_ticker_stop(rfmp_ticker_t *t);

#ifdef __cplusplus
}
#endif
#endif
