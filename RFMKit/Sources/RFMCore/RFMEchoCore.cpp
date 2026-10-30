// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// (tests) A core that echoes its MIDI in to its MIDI out, packet for packet, and plays silence: the AU's MIDI path
// end to end without a firmware (rfme_test_load_echo). A note-on of note 0 also sends a SysEx (F0 7D 01 02 03 04 05
// F7, three USB-MIDI packets).
// It also has a small parameter map for the host parameters (RFMHostParams.h): Alpha 0..100 ("<v> ms"), Beta (an enum:
// Up, Down, Both), Meta (a meta entry: Alpha's or Beta's), then the hidden Gamma -10..10 (a knob target only) and
// hidden read-outs: Turns (K2's detents taken), Buttons and Keys (the panel's masks), Master, Presses (buttons gone
// down, counted by ticks). Knob 1 turns Alpha, Knob 3 Gamma, the others are relative. From MIDI (CC on any channel):
// CC 20 v: Knob 1's target (0 none, 1 Alpha, 2 Beta), CC 21 v: Alpha = v (the firmware's own change), CC 22 v: Meta
// stands for Beta (v > 0) or Alpha; each moves the epoch.
#include <array>
#include <cstdio>
#include <cstring>

#include "RFMCoreBackend.h"
#include "RFMEngine.h"

namespace rfm {
namespace {

class EchoCore final : public CoreBackend {
public:
    EchoCore()
    {
        d_.id = "echo";
        d_.name = "MIDI echo (tests)";
        d_.version = "1";
        d_.keymap.fill(-1);
        std::memset(&p_, 0, sizeof p_);
    }
    const CoreDesc &info() const override { return d_; }
    const char *kind() const override { return "test"; }
    fm1panel_t *panel() override { return &p_; }
    uint8_t *flash() override { return nullptr; }
    void options(const char *, int, int, int) override {}
    bool has_boot_options() const override { return false; }
    int boot_options(int, const char *, int) override { return 1; }
    void init(int) override
    {
        if (!p_.master)
            p_.master = 724;                            // (a core's default MASTER)
        for (int i = 0; i < FM1P_NB; i++)
            p_.btn_id[i] = (uint8_t)i;
        for (int i = 0; i < FM1P_NE - 1; i++) {
            p_.enc_id[i] = (uint8_t)i;
            p_.enc_dir[i] = 1;
        }
    }
    void tick(uint32_t) override
    {
        for (int i = 0; i < FM1P_NENC; i++) {           // (the encoders' detents taken, as a firmware does)
            if (i == FM1P_E_K2)
                turns_ += p_.enc[i];
            p_.enc[i] = 0;
        }
        presses_ += (int32_t)__builtin_popcount((p_.buttons | p_.buttons_tap) & ~lastButtons_);
        lastButtons_ = p_.buttons;
        p_.buttons_tap = p_.keys_tap = 0;
    }
    void frame() override {}
    void idle() override {}
    void audio(int16_t *s, uint32_t n) override { std::memset(s, 0, n * 2 * sizeof *s); }
    int midi_in(uint32_t pkt) override
    {
        if (w_ - r_ > kRing - 4)
            return 0;
        put(pkt);
        if ((pkt & 0xF) == 0xB) {                       // (the map's controls)
            const uint32_t cc = (pkt >> 16) & 0x7F, v = (pkt >> 24) & 0x7F;
            if (cc == 20) {
                k1_ = v == 0 ? -1 : v == 1 ? 0 : 1;
                epoch_++;
            } else if (cc == 21) {
                alpha_ = (int32_t)(v > 100 ? 100 : v);
            } else if (cc == 22) {
                metaBeta_ = v > 0;
                epoch_++;
            }
        }
        if ((pkt & 0xF) == 0x9 && ((pkt >> 16) & 0x7F) == 0 && (pkt >> 24) != 0) {
            put(0x4u | 0xF0u << 8 | 0x7Du << 16 | 0x01u << 24);
            put(0x4u | 0x02u << 8 | 0x03u << 16 | 0x04u << 24);
            put(0x6u | 0x05u << 8 | 0xF7u << 16);
        }
        return 1;
    }
    int midi_out_take(uint32_t *pkt) override
    {
        if (r_ == w_)
            return 0;
        *pkt = q_[r_++ % kRing];
        return 1;
    }
    bool stats(uint32_t *, uint32_t *) override { return false; }
    void ui_info(char *b, uint32_t n) override
    {
        if (n)
            b[0] = 0;
    }
    void shutdown() override {}
    int halted() override { return 0; }
    int flash_stage(const uint8_t *, uint32_t) override { return 1; }
    uint32_t flash_dirty() override { return 0; }
    int flash_sync() override { return 1; }

    // the parameter map
    uint32_t param_epoch() override { return epoch_; }
    int32_t knob_target(int role) override
    {
        return role == FM1P_E_K1 ? k1_ : role == FM1P_E_K3 ? kGamma : -1;
    }
    uint32_t param_count() const override { return kN; }
    bool param_desc(uint32_t i, ParamDesc *o) override
    {
        if (i >= kN || !o)
            return false;
        static const ParamDesc d[kN] = {
            {"Alpha", 0, 100, 50, 0},          {"Beta", 0, 2, 0, FM1P_ENUM},        {"Meta", 0, 100, 50, FM1P_META},
            {"Gamma", -10, 10, 0, FM1P_HIDDEN}, {"Turns", -10000, 10000, 0, FM1P_HIDDEN},
            {"Buttons", 0, 16383, 0, FM1P_HIDDEN}, {"Keys", 0, 0x7FFFFFF, 0, FM1P_HIDDEN},
            {"Master", 0, 1023, 0, FM1P_HIDDEN}, {"Presses", 0, 100000, 0, FM1P_HIDDEN}};
        *o = d[i == kMeta ? (metaBeta_ ? kBeta : kAlpha) : i];
        if (i == kMeta)
            o->flags |= FM1P_META;
        return true;
    }
    const CoreParam *param(uint32_t i) const override
    {
        static const char *const names[kN] = {"Alpha", "Beta", "Meta", "Gamma", "Turns", "Buttons", "Keys", "Master",
                                               "Presses"};
        static const std::array<CoreParam, kN> ps = [] {
            std::array<CoreParam, kN> a;
            for (uint32_t k = 0; k < kN; k++) {
                a[k].name = names[k];
                a[k].readable = true;
                a[k].writable = k < 4;
            }
            return a;
        }();
        return i < kN ? &ps[i] : nullptr;
    }
    int32_t param_target(uint32_t i) override { return i == kMeta ? (metaBeta_ ? kBeta : kAlpha) : -1; }
    bool param_get(uint32_t i, int32_t *v) override
    {
        if (i == kMeta)
            i = metaBeta_ ? kBeta : kAlpha;
        const int32_t vals[kN] = {alpha_, beta_, 0, gamma_, turns_, (int32_t)p_.buttons, (int32_t)p_.keys, p_.master,
                                  presses_};
        if (i >= kN)
            return false;
        if (v)
            *v = vals[i];
        return true;
    }
    bool param_set(uint32_t i, int32_t v) override
    {
        if (i == kMeta)
            i = metaBeta_ ? kBeta : kAlpha;
        auto clamp = [](int32_t x, int32_t lo, int32_t hi) { return x < lo ? lo : x > hi ? hi : x; };
        switch (i) {
        case kAlpha: alpha_ = clamp(v, 0, 100); return true;
        case kBeta: beta_ = clamp(v, 0, 2); return true;
        case kGamma: gamma_ = clamp(v, -10, 10); return true;
        default: return false;
        }
    }
    bool param_text(uint32_t i, int32_t v, char *b, uint32_t n) override
    {
        if (i == kMeta)
            i = metaBeta_ ? kBeta : kAlpha;
        if (i >= kN || !b || !n)
            return false;
        static const char *const beta[3] = {"Up", "Down", "Both"};
        if (i == kAlpha)
            std::snprintf(b, n, "%d ms", (int)v);
        else if (i == kBeta)
            std::snprintf(b, n, "%s", v >= 0 && v <= 2 ? beta[v] : "?");
        else
            std::snprintf(b, n, "%d", (int)v);
        return true;
    }

private:
    enum : uint32_t { kAlpha, kBeta, kMeta, kGamma, kN = 9 };
    int32_t alpha_ = 50, beta_ = 0, gamma_ = 0, turns_ = 0, presses_ = 0;
    int32_t k1_ = kAlpha;
    bool metaBeta_ = false;
    uint32_t epoch_ = 1, lastButtons_ = 0;
    static constexpr uint32_t kRing = 1024;
    void put(uint32_t p) { q_[w_++ % kRing] = p; }
    CoreDesc d_;
    fm1panel_t p_;
    uint32_t q_[kRing] = {};
    uint32_t r_ = 0, w_ = 0;
};

} // namespace
} // namespace rfm

extern "C" int rfme_test_load_echo(rfme_t *e)
{
    std::string err;
    return rfm::engineLoad(e, [](std::string *) -> std::unique_ptr<rfm::CoreBackend> {
        return std::make_unique<rfm::EchoCore>();
    }, &err) ? 1 : 0;
}
