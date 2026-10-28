// SPDX-License-Identifier: GPL-3.0-only
// A core in a Wasm module, seen by the host as an ordinary fm1core_t (core-api/fm1core.h), so FM1VST's Device drives
// it exactly as it drives a native core. The module exports the ABI as flat functions (wasm/shim.c: fm1w_*); the
// host-side descriptor's entry points are trampolines into the interpreter.
//
// The descriptor's panel and keymap point into the instance's linear memory (the module is built without memory
// growth, so the base never moves). The trampolines take no context, as the ABI's entry points don't: they act on the
// selected instance (wcore_select), so every call to one instance's descriptor must follow its select. One thread.
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include "fm1core.h"

struct WCore;

enum WEngine { W_WASM3 = 0, W_WAMR = 1 };

// load and instantiate: parse, link the imports (four WASI stubs), compile every function up front (no compile
// inside the clock), run _initialize, fm1w_get(FM1CORE_ABI), check the layout. nullptr and *err on failure.
// bytes must outlive the instance.
WCore *wcore_load(WEngine e, const uint8_t *bytes, size_t n, std::string *err);
void wcore_free(WCore *w);
void wcore_select(WCore *w);                  // the instance the trampolines act on
const fm1core_t *wcore_desc(WCore *w);        // the host-side descriptor (valid while w lives)
const char *wcore_error(WCore *w);            // the last trap, "" none
uint32_t wcore_mem_bytes(WCore *w);           // the instance's linear memory
bool wcore_has(WEngine e);                    // compiled in
const char *wcore_engine_name(WEngine e);
