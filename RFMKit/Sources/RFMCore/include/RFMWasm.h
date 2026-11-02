// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Imported firmware (M7): .rfm1 files (docs/RFM1-FORMAT.md, version 1), FM-1 firmware compiled to WebAssembly, run by
// wasm3 behind the engine's core backend (RFMWasmCore.cpp: WasmCore). Each engine that loads one gets its own
// instance (its own linear memory): no slots, no per-core cap.
//
// A file is read once per path (and size and modification time) and kept while an engine uses it, so a power cycle
// re-instantiates from the same bytes even if the file is gone. Plain C (Swift imports it); control thread only, as
// rfme_load.
#ifndef RFMWASM_H
#define RFMWASM_H
#include <stdint.h>

#include "RFMEngine.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char id[32], name[64], version[48], family[32];
    char license[128];          // the manifest's SPDX expression
    char sha256[65];            // the file's SHA-256, lowercase hex
    uint32_t abi;               // the descriptor's ABI (6)
    uint32_t flash_size;        // bytes in the flash image (0: none)
    uint32_t memory_bytes;      // the module's fixed linear memory
    uint32_t file_size;
    uint32_t load_us;           // one instantiation (parse, link, compile, _initialize, the checks)
    // a Fantasy CFW (FM1VST docs/VIRTUAL-CARTS.md): its manifest's "virtual"; it uses the RemoteFM1 folder
    // (rfm1_host_1); what its manifest's "folders" allow ("audio:r code:r data:rw")
    uint32_t is_virtual, uses_folder;
    char folders[40];
    // (ain1, live audio input: RemoteFM1 web/engine/API.md section 6) 0 none, 1 its manifest "wants" it, 2 "needs" it
    uint32_t audio_in;
} rfmw_info_t;

// the format's every check (section 7 step 1: the magic, the manifest, the imports, the exports, the memory) and one
// instantiation (rfm1_version, rfm1_layout, the descriptor against the manifest). 1: valid, out filled; 0: refused,
// the reason in err (one line)
int rfmw_check(const char *path, rfmw_info_t *out, char *err, uint32_t n);

// a text of the file: "manifest" (the rfm1 section's JSON), "credits" (rfm1.credits), "license.<n>" (rfm1.license.<n>).
// Copied into buf (n bytes, NUL-terminated); returns the full length (0: none, or not a valid file)
uint32_t rfmw_text(const char *path, const char *what, char *buf, uint32_t n);

// the file's SHA-256 (lowercase hex, 65 bytes with the NUL) without the format's checks; 1: read
int rfmw_sha256(const char *path, char out[65]);

// rfme_load with an .rfm1 core: the file checked, then a WasmCore made for this engine (and again by each power
// cycle, from the same bytes). 0: failed (err)
int rfme_load_wasm(rfme_t *e, const char *path, char *err, uint32_t n);

// ---- the RemoteFM1 folder a Fantasy CFW reads (and writes its data/<id>/ in); NULL: none (its requests end in
// FS_ENOFOLDER). Any thread; every instance's next request uses it
void rfmw_set_folder(const char *path);
// the folder's files changed (fs_changed() moves: a cart rescans)
void rfmw_folder_changed(void);
// READs answered with bytes since launch, every Fantasy CFW (diagnostics)
uint64_t rfmw_folder_reads(void);
// (tests) the memory an instance may have, instead of what the system says is left; 0: the system's
void rfmw_set_memory_budget(uint64_t bytes);

// ---- one instance outside an engine, for tests: any export called by name (i32 / i64 arguments), the memory, the
// file API's answers applied (as before each tick). folder: that folder instead of rfmw_set_folder's
typedef struct rfmw_inst rfmw_inst;
rfmw_inst *rfmw_inst_open(const char *path, const char *folder, char *err, uint32_t n);
void rfmw_inst_close(rfmw_inst *i);
int rfmw_inst_call(rfmw_inst *i, const char *name, const uint64_t *args, uint32_t nargs, int64_t *ret);
uint8_t *rfmw_inst_memory(rfmw_inst *i, uint32_t *size);
void rfmw_inst_apply(rfmw_inst *i);
// waits until every queued request is answered (1), or the timeout (0); then applies
int rfmw_inst_settle(rfmw_inst *i, uint32_t timeout_ms);
// waits as rfmw_inst_settle, without applying (the answers stay out of memory until the next apply)
int rfmw_inst_wait(rfmw_inst *i, uint32_t timeout_ms);
void rfmw_inst_bump(rfmw_inst *i);
void rfmw_inst_tick(rfmw_inst *i, uint32_t ms);

#ifdef __cplusplus
}
#endif
#endif
