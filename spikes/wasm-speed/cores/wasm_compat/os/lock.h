/* SPDX-License-Identifier: GPL-3.0-only */
/* Apple's os_unfair_lock for ChoralRoot's emulator unit (tools/emu/emu_hal_fw.h: the core-1 thread's lock) in a Wasm
 * build: a core runs on one thread (fm1core.h), the core-1 thread is never started (getenv is NULL: common/env.h), so
 * the lock is a plain flag. Wasm builds only (build_wasm.sh puts this folder on the include path). */
#pragma once
typedef struct { int v; } os_unfair_lock;
#define OS_UNFAIR_LOCK_INIT {0}
static inline void os_unfair_lock_lock(os_unfair_lock *l) { l->v = 1; }
static inline int os_unfair_lock_trylock(os_unfair_lock *l) { if (l->v) return 0; l->v = 1; return 1; }
static inline void os_unfair_lock_unlock(os_unfair_lock *l) { l->v = 0; }
