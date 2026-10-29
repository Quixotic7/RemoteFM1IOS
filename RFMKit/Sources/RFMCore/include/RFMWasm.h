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

#ifdef __cplusplus
}
#endif
#endif
