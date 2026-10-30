// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The host's parameters (the AU's parameter tree, PLAN.md section 12), on the engine's core thread. FM1VST v0.6.2's
// parameters (plugin/Tier2Parameter.h, Processor.cpp applyHostParameters / readBackParameters), without JUCE:
//
//   Knob Master   the MASTER pot, 0..1023
//   the knobs     Select, Presets, Algo, Knob 1..4: fixed names. The core's knob_target(role) binds a knob to a map
//                 entry (absolute: 0..1 is the entry's range) or to nothing (relative: centred 0.5, a host change is
//                 turned into detents, 24 per full travel, the remainder kept; 400 device ms after the host's last
//                 change the value springs back to 0.5). What the knob does now is in the value text.
//   buttons, keys momentary: held while the host's value is 0.5 or more (merged with the panel's own holds)
//   Tier 2        RFME_HP_T2_SLOTS slots bound in map order to the entries without FM1P_HIDDEN; a meta entry's slot
//                 shows its target (re-read when param_epoch moves). Unused slots are inert ("–").
//
// The state (rfme_hp_param_t per parameter) is what the host should show: the host's own value, or the firmware's
// when it changed by itself (a knob turned on the FM-1, a sound loaded, MASTER moved), or 0.5 for a relative knob
// that sprang back. Host writes are dropped for kGraceMs after a boot (a project's restored values are stale: they
// must not press buttons or turn knobs) and for kSettleMs after a knob's retarget (meant for the old target); a
// dropped write leaves the state as it was, so the host is told the firmware's value again.
//
// Threads: everything here runs on the core thread (or the control thread with the clock stopped). formatText is
// any thread's: it takes the binding from a published state and only calls the backend's param_text.
#pragma once
#include <cstdint>

#include "RFMCoreBackend.h"
#include "RFMDevice.h"
#include "RFMEngine.h"

namespace rfm {

struct HostParamState {
    rfme_hp_info_t info;
    rfme_hp_param_t p[RFME_HP_COUNT];
};

class HostParams {
public:
    // what a host change does to the panel (the engine's side)
    struct Panel {
        virtual void hpButtons(uint32_t labels) = 0;    // the buttons the host holds now (label bits)
        virtual void hpKeys(uint32_t keys) = 0;         // the keys it holds now
        virtual void hpTurn(int role, int32_t detents) = 0;
        virtual void hpMaster(int32_t v) = 0;

    protected:
        ~Panel() = default;
    };

    static constexpr int kDetents = 24;             // a relative knob's detents per full travel
    static constexpr uint32_t kRecentreMs = 400;    // device ms after the host's last change: back to 0.5
    static constexpr uint32_t kSettleMs = 150;      // a knob's host writes dropped after its retarget
    static constexpr uint32_t kGraceMs = 1000;      // every host write dropped after a boot
    static constexpr uint32_t kEveryMs = 33;        // the read-back's period (device ms)
    static constexpr uint8_t kHoldoff = 2;          // read-backs skipped after a host write

    // a boot (core and dev the new ones; seqs: each parameter's writes so far, all taken as done) or, with nullptr,
    // an unload
    void reset(CoreBackend *core, CoreDevice *dev, const uint32_t *seqs, uint32_t ms);
    // one host value (seq: its write number)
    void write(uint32_t index, float x, uint32_t seq, uint32_t ms, Panel &panel);
    // the firmware's values (every kEveryMs)
    void readBack(uint32_t ms);
    bool due(uint32_t ms) const { return core_ && (!started_ || ms - last_ >= kEveryMs); }
    // the state changed since the last take
    bool takeDirty()
    {
        const bool d = dirty_;
        dirty_ = false;
        return d;
    }
    void fill(HostParamState &out) const;
    uint32_t heldButtons() const { return buttons_; }
    uint32_t heldKeys() const { return keys_; }

    // the text for x as `p` binds it (index: which parameter); core: the backend p's entry belongs to (nullptr:
    // the firmware's text is left out)
    static void formatText(const rfme_hp_param_t &p, uint32_t index, float x, CoreBackend *core, char *buf, uint32_t n);
    // the value for a text, as `p` binds it; false: not understood
    static bool parseText(const rfme_hp_param_t &p, uint32_t index, const char *text, CoreBackend *core, float *out);

private:
    struct Bind {                                   // a knob or a Tier 2 slot
        int32_t own = -1;                           // the entry it reads and writes (-1: none)
        bool meta = false;
        int32_t reported = 0;                       // the firmware's value last seen
        bool valid = false;
        uint8_t holdoff = 0;
        double relBase = 0.5;                       // (a relative knob) where the next detent counts from
        uint32_t lastHost = 0;                      // its last host change (device ms)
        uint32_t settleUntil = 0;
        bool settling = false;
        uint32_t sig = 0;                           // (a knob) its target's signature
        bool sigValid = false;
    };

    void text(uint32_t i);
    void bindView(uint32_t i, int32_t view);        // entry, range and name from view (-1: unbound)
    void retargetMeta();
    void retargetKnobs(uint32_t ms);
    void readValue(uint32_t i, Bind &b);

    CoreBackend *core_ = nullptr;
    CoreDevice *dev_ = nullptr;
    rfme_hp_param_t p_[RFME_HP_COUNT] = {};
    Bind k_[7], t_[RFME_HP_T2_SLOTS];
    uint32_t buttons_ = 0, keys_ = 0;
    uint32_t epoch_ = 0;
    bool epochValid_ = false;
    uint32_t graceUntil_ = 0;
    bool grace_ = false, started_ = false, dirty_ = false;
    uint32_t last_ = 0;
    rfme_hp_info_t info_ = {};
};

} // namespace rfm
