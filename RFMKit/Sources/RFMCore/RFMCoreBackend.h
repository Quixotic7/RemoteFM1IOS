// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The core backend (M7): one running firmware image behind one interface, so the engine (RFMEngine.cpp) and its
// device clock (RFMDevice.h) don't care what runs the firmware. Two kinds:
//
//   NativeCore   a slot framework's fm1core_t (core-api/fm1core.h, ABI 5..6), dlopen'd by the slot loader
//                (RFMSlots.h): the entry points are the descriptor's function pointers, the panel is the module's
//   WasmCore     an .rfm1 module (docs/RFM1-FORMAT.md) in an interpreter: the entry points are its rfm1_*
//                exports, the panel lives in the module's linear memory
//
// THREADING: fm1core.h's contract, unchanged. Every method that runs firmware code, and every read or write through
// panel() or flash(), is made from ONE thread at a time: the engine's core thread while a clock runs, the control
// thread while the clock is stopped (rfme_set_clock / load / boot / power cycle). info() and slot() are plain data,
// read from any thread.
//
// THE PANEL: panel() returns the firmware's fm1panel_t (fm1core.h's layout: for Wasm the module's own struct, whose
// wasm32 layout is the same, checked against rfm1_layout). The pointer stays valid until the backend is destroyed
// (a Wasm module's memory has a fixed size and never moves: format section 6), and the host reads and writes it
// directly between entry points, as fm1core.h says. The same holds for flash(): flash_size() bytes valid until the
// backend goes.
//
// LIFETIME: the backend is made by a factory (CoreFactory) on the control thread, then the engine calls options /
// boot_options / flash_stage / init through RFMDevice, runs the clock, and destroys the backend, which shuts the
// firmware down (fm1core.h: shutdown()) and frees what it holds (a slot is given back to the loader). A power cycle
// destroys the backend and makes a new one with the same factory.
#pragma once
#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "fm1core.h"

struct rfme;                                // the engine (include/RFMEngine.h's rfme_t)

namespace rfm {

class SlotLoader;

// the descriptor's data, copied out once when the backend is made (strings never point into the firmware)
struct CoreDesc {
    std::string id, name, version, source_url, family, license, gated, credits;
    uint32_t abi = 0;                       // the fm1core ABI the firmware was built for (5..6)
    uint32_t flash_size = 0;                // bytes in the flash image (0: none)
    std::array<std::string, FM1P_NB> button_names;
    bool has_keymap = false;
    std::array<int8_t, 6 * FM1P_NCOL> keymap{};   // [row][column] key id (fm1core.h keymap), -1 none
};

// one Tier 2 parameter as the host sees it (fm1param_t's data; its functions are reached through the backend)
struct CoreParam {
    std::string name, unit;
    int32_t min = 0, max = 0, def = 0;
    uint32_t flags = 0;                     // FM1P_ENUM, FM1P_META, FM1P_PERSIST, ...
    bool readable = false, writable = false;
};

// the same, as plain data read on the clock's thread (param_desc)
struct ParamDesc {
    char name[24];
    int32_t min, max, def;
    uint32_t flags;
};

class CoreBackend {
public:
    virtual ~CoreBackend() = default;

    // ---- data (any thread)
    virtual const CoreDesc &info() const = 0;
    virtual int slot() const { return 0; }              // the slot number 1..4 of a native core; 0 (Wasm): none
    virtual const char *kind() const = 0;               // "native", "wasm", ...

    // ---- the panel and the flash image (the clock's thread; see THE PANEL above)
    virtual fm1panel_t *panel() = 0;
    virtual uint8_t *flash() = 0;                       // flash_size() bytes, or nullptr: no flash
    uint32_t flash_size() const { return info().flash_size; }

    // ---- fm1core.h's entry points (the clock's thread, one at a time), same meaning and arguments
    virtual void options(const char *flash_path, int no_flash, int save_on_exit, int headless) = 0;
    virtual bool has_boot_options() const = 0;
    virtual int boot_options(int fail, const char *reason, int stage) = 0;   // (has_boot_options() false: 1)
    virtual void init(int demo) = 0;
    virtual void tick(uint32_t ms) = 0;
    virtual void frame() = 0;
    virtual void idle() = 0;
    virtual void audio(int16_t *stereo, uint32_t frames) = 0;               // frames: a multiple of FM1P_BLOCK
    virtual int midi_in(uint32_t pkt) = 0;                                   // 0: no room, retry later
    virtual int midi_out_take(uint32_t *pkt) = 0;                            // 0: none
    virtual bool stats(uint32_t *shed, uint32_t *cpu_pct) = 0;               // false: the core has no stats()
    virtual void ui_info(char *buf, uint32_t n) = 0;                         // "" when none
    virtual void dump() {}
    virtual void shutdown() = 0;                                             // idempotent
    virtual int halted() = 0;                                                // 0 running; 0x100 | exit code
    virtual int flash_stage(const uint8_t *bytes, uint32_t n) = 0;           // 1: staged
    virtual uint32_t flash_dirty() = 0;                                      // 0 when the core has none
    virtual int flash_sync() = 0;                                            // 1: current (also: no flash)
    virtual uint32_t param_epoch() { return 0; }
    virtual int32_t knob_target(int /*role*/) { return -1; }

    // ---- the Tier 2 parameter map (the clock's thread; a Wasm core: none in .rfm1 version 1, nor knob_target or
    // param_epoch: its knobs are relative host parameters and its Tier 2 slots unused)
    virtual uint32_t param_count() const { return 0; }
    virtual const CoreParam *param(uint32_t /*i*/) const { return nullptr; }
    virtual bool param_get(uint32_t /*i*/, int32_t * /*v*/) { return false; }
    virtual bool param_set(uint32_t /*i*/, int32_t /*v*/) { return false; }
    // the index of the parameter named `name`, -1 none
    int param_find(const char *name) const;
    // (the clock's thread) entry i as the firmware has it now: a meta entry's target is rewritten (name, range)
    // when param_epoch moves, so param()'s copy from the load may be old. No allocation. false: none
    virtual bool param_desc(uint32_t /*i*/, ParamDesc * /*out*/) { return false; }
    // (the clock's thread) a meta entry's target() now, -1 none
    virtual int32_t param_target(uint32_t /*i*/) { return -1; }
    // (any thread: fm1core.h lets text() be called from any) v as the firmware writes it ("1/8", "120 ms");
    // false: no entry i
    virtual bool param_text(uint32_t /*i*/, int32_t /*v*/, char * /*buf*/, uint32_t /*n*/) { return false; }
};

// makes a backend (the control thread); nullptr with a message in *err when it can't
using CoreFactory = std::function<std::unique_ptr<CoreBackend>(std::string *err)>;

// a native core in a slot of `id` (the slot loader's first free one)
CoreFactory nativeCoreFactory(const std::string &id);

// an .rfm1 file (docs/RFM1-FORMAT.md) read and checked once (RFMWasmCore.cpp; cached by path, size and modification
// time), and a factory that makes a WasmCore over it: its own wasm3 instance per call (each engine, each power cycle)
struct WasmFile;
std::shared_ptr<const WasmFile> wasmOpen(const std::string &path, std::string *err);
CoreFactory wasmCoreFactory(std::shared_ptr<const WasmFile> file);

// rfme_load with any backend (the control thread): the clock stopped, the old core unloaded, `factory` kept for power
// cycles, the clock given back (rfme_boot next). false: the factory failed (err)
bool engineLoad(::rfme *e, CoreFactory factory, std::string *err);

// (tests) a backend that forwards to `inner` and makes every frame() take at least `stall_us` longer: a busy wait,
// as an interpreted firmware's screen redraw costs the core thread CPU time
std::unique_ptr<CoreBackend> stallingCore(std::unique_ptr<CoreBackend> inner, uint32_t stall_us);

} // namespace rfm
