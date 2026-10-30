// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The host's parameters: see RFMHostParams.h.
#include "RFMHostParams.h"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <strings.h>

namespace rfm {

namespace {

// the knob parameters' roles, FM1VST's order (Processor.cpp createKnobParameters)
constexpr int kKnobRole[7] = {FM1P_E_SELECT, FM1P_E_PRESETS, FM1P_E_ALGO, FM1P_E_K1, FM1P_E_K2, FM1P_E_K3, FM1P_E_K4};
const char *const kLabels[FM1P_NB] = {"FX", "SEL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE", "ARP", "SEQ", "PLAY",
                                      "REC", "OCT-", "OCT+"};
const char *const kNotes[12] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};

bool isKnob(uint32_t i) { return i >= RFME_HP_KNOB && i < RFME_HP_KNOB + 7; }
bool isT2(uint32_t i) { return i >= RFME_HP_T2 && i < RFME_HP_COUNT; }
bool isButton(uint32_t i) { return i >= RFME_HP_BUTTON && i < RFME_HP_BUTTON + FM1P_NB; }
bool isKey(uint32_t i) { return i >= RFME_HP_KEY && i < RFME_HP_KEY + FM1P_NKEY; }

int32_t toPlain(float x, int32_t lo, int32_t hi)
{
    const double t = x < 0 ? 0.0 : x > 1 ? 1.0 : (double)x;
    return lo + (int32_t)std::lround(t * (double)(hi - lo));
}

float toNorm(int32_t v, int32_t lo, int32_t hi)
{
    if (hi <= lo)
        return 0.0f;
    const double t = (double)(v - lo) / (double)(hi - lo);
    return (float)(t < 0 ? 0.0 : t > 1 ? 1.0 : t);
}

void copyName(char *dst, uint32_t n, const char *src) { std::snprintf(dst, n, "%s", src ? src : ""); }

uint32_t signature(int32_t t, const ParamDesc *d)
{
    uint32_t h = 2166136261u;
    auto mix = [&h](uint32_t v) { h = (h ^ v) * 16777619u; };
    mix((uint32_t)t);
    if (d) {
        mix((uint32_t)d->min);
        mix((uint32_t)d->max);
        mix(d->flags);
        for (const char *s = d->name; *s; s++)
            mix((uint8_t)*s);
    }
    return h;
}

// a text's part after "Name: " (FM1VST's getValueForText), trimmed
const char *afterName(const char *t, char *buf, size_t n)
{
    const char *c = std::strstr(t, ": ");
    const char *s = c ? c + 2 : t;
    while (*s == ' ')
        s++;
    std::snprintf(buf, n, "%s", s);
    for (size_t k = std::strlen(buf); k > 0 && buf[k - 1] == ' '; k--)
        buf[k - 1] = 0;
    return buf;
}

} // namespace

void HostParams::reset(CoreBackend *core, CoreDevice *dev, const uint32_t *seqs, uint32_t ms)
{
    core_ = core;
    dev_ = dev;
    const uint32_t gen = info_.gen + 1;
    info_ = {};
    info_.gen = gen;
    buttons_ = keys_ = 0;
    epochValid_ = false;
    started_ = false;
    grace_ = core != nullptr;
    graceUntil_ = ms + kGraceMs;
    for (Bind &b : k_)
        b = Bind{};
    for (Bind &b : t_)
        b = Bind{};
    for (uint32_t i = 0; i < RFME_HP_COUNT; i++) {
        rfme_hp_param_t &p = p_[i];
        std::memset(&p, 0, sizeof p);
        p.seq = seqs ? seqs[i] : 0;
        p.entry = -1;
        p.max = 1;
        p.mode = RFME_HP_ABS;
    }
    rfme_hp_param_t &m = p_[RFME_HP_MASTER];
    m.max = 1023;
    m.value = 724.0f;                               // (the emulator's power-on value; the first read-back has the core's)
    m.plain = 724;
    for (int k = 0; k < 7; k++) {
        p_[RFME_HP_KNOB + k].mode = RFME_HP_REL;    // (relative until the first read-back reads knob_target)
        p_[RFME_HP_KNOB + k].value = 0.5f;
    }
    for (int l = 0; l < FM1P_NB; l++) {
        const std::string *fw = core ? &core->info().button_names[(size_t)l] : nullptr;
        copyName(p_[RFME_HP_BUTTON + l].name, sizeof p_[0].name, fw && !fw->empty() ? fw->c_str() : kLabels[l]);
    }
    for (int k = 0; k < FM1P_NKEY; k++) {
        const int note = FM1P_NOTE0 + k;
        std::snprintf(p_[RFME_HP_KEY + k].name, sizeof p_[0].name, "%s%d", kNotes[note % 12], note / 12 - 1);
    }
    // the Tier 2 slots: the visible entries in map order (FM1P_HIDDEN: knob targets only)
    const uint32_t n = core ? core->param_count() : 0;
    uint32_t e = 0;
    for (uint32_t i = 0; i < n; i++) {
        ParamDesc d{};
        if (core->param_desc(i, &d) && !(d.flags & FM1P_HIDDEN))
            info_.t2_visible++;
    }
    for (int s = 0; s < RFME_HP_T2_SLOTS; s++) {
        rfme_hp_param_t &p = p_[RFME_HP_T2 + s];
        p.mode = RFME_HP_UNBOUND;
        ParamDesc d{};
        while (e < n && (!core->param_desc(e, &d) || (d.flags & FM1P_HIDDEN)))
            e++;
        if (e >= n)
            continue;
        Bind &b = t_[s];
        b.own = (int32_t)e++;
        b.meta = (d.flags & FM1P_META) != 0;
        p.mode = RFME_HP_ABS;
        bindView(RFME_HP_T2 + s, b.own);
        p.value = toNorm(d.def, p.min, p.max);
        p.plain = d.def;
        info_.t2_bound++;
    }
    for (uint32_t i = 0; i < RFME_HP_COUNT; i++)
        text(i);
    dirty_ = true;
}

void HostParams::bindView(uint32_t i, int32_t view)
{
    rfme_hp_param_t &p = p_[i];
    ParamDesc d{};
    if (view < 0 || !core_ || !core_->param_desc((uint32_t)view, &d)) {
        p.entry = -1;
        p.min = 0;
        p.max = 1;
        p.name[0] = 0;
        return;
    }
    p.entry = view;
    p.min = d.min;
    p.max = d.max > d.min ? d.max : d.min + 1;
    copyName(p.name, sizeof p.name, d.name);
}

void HostParams::text(uint32_t i) { formatText(p_[i], i, p_[i].value, core_, p_[i].text, sizeof p_[i].text); }

void HostParams::write(uint32_t i, float x, uint32_t seq, uint32_t ms, Panel &panel)
{
    if (i >= RFME_HP_COUNT || !core_)
        return;
    rfme_hp_param_t &p = p_[i];
    if (seq > p.seq) {
        p.seq = seq;
        dirty_ = true;
    }
    if (!std::isfinite(x))
        return;
    if (grace_ && (int32_t)(ms - graceUntil_) < 0) {
        info_.dropped++;                            // (the state stays: the host is told the firmware's value)
        dirty_ = true;
        return;
    }
    grace_ = false;
    if (i == RFME_HP_MASTER) {
        const int32_t v = (int32_t)std::lround(x < 0 ? 0 : x > 1023 ? 1023 : x);
        p.value = x < 0 ? 0 : x > 1023 ? 1023 : x;
        p.plain = v;
        panel.hpMaster(v);                          // (always: the pot may have moved it since the last read-back)
    } else if (isButton(i) || isKey(i)) {
        const bool key = isKey(i);
        const uint32_t bit = 1u << (key ? i - RFME_HP_KEY : i - RFME_HP_BUTTON);
        const bool held = x >= 0.5f;
        p.value = x;
        p.plain = held ? 1 : 0;
        uint32_t &mask = key ? keys_ : buttons_;
        const uint32_t was = mask;
        mask = held ? mask | bit : mask & ~bit;
        if (mask != was) {
            if (key)
                panel.hpKeys(mask);
            else
                panel.hpButtons(mask);
        }
    } else if (isKnob(i)) {
        Bind &b = k_[i - RFME_HP_KNOB];
        if (b.settling && (int32_t)(ms - b.settleUntil) < 0) {
            info_.dropped++;                        // (meant for the old target: told the new one's value)
            dirty_ = true;
            return;
        }
        b.settling = false;
        b.lastHost = ms;
        p.value = x;
        if (p.mode == RFME_HP_REL) {
            const int32_t d = (int32_t)std::lround(((double)x - b.relBase) * kDetents);
            if (d) {
                b.relBase += (double)d / kDetents;   // (the remainder stays for the next change)
                panel.hpTurn(kKnobRole[i - RFME_HP_KNOB], d);
            }
        } else {
            const int32_t v = toPlain(x, p.min, p.max);
            core_->param_set((uint32_t)b.own, v);
            p.plain = b.reported = v;
            b.valid = true;
            b.holdoff = kHoldoff;
        }
    } else if (isT2(i)) {
        Bind &b = t_[i - RFME_HP_T2];
        p.value = x;
        if (p.mode == RFME_HP_UNBOUND)
            return;                                 // (an unused slot: inert)
        const int32_t v = toPlain(x, p.min, p.max);
        core_->param_set((uint32_t)b.own, v);
        p.plain = b.reported = v;
        b.valid = true;
        b.holdoff = kHoldoff;
    } else {
        return;
    }
    info_.applied++;
    text(i);
    dirty_ = true;
}

// a bound knob's or slot's firmware value: told when it moved by itself (not after the host's own write)
void HostParams::readValue(uint32_t i, Bind &b)
{
    rfme_hp_param_t &p = p_[i];
    if (b.holdoff) {
        b.holdoff--;
        return;
    }
    int32_t v = 0;
    if (b.own < 0 || !core_->param_get((uint32_t)b.own, &v))
        return;
    if (b.valid && v == b.reported)
        return;
    b.reported = v;
    b.valid = true;
    if (toPlain(p.value, p.min, p.max) != v)        // (the host's value already that step: left as it is)
        p.value = toNorm(v, p.min, p.max);
    p.plain = v;
    text(i);
    dirty_ = true;
}

void HostParams::retargetMeta()
{
    for (int s = 0; s < RFME_HP_T2_SLOTS; s++) {
        Bind &b = t_[s];
        if (b.own < 0 || !b.meta)
            continue;
        const int32_t t = core_->param_target((uint32_t)b.own);
        const uint32_t i = RFME_HP_T2 + (uint32_t)s;
        bindView(i, t >= 0 && (uint32_t)t < core_->param_count() ? t : b.own);
        if (p_[i].entry < 0)
            bindView(i, b.own);
        b.valid = false;                            // (its value told again, in the new range)
        b.holdoff = 0;
        readValue(i, b);
        p_[i].value = toNorm(p_[i].plain, p_[i].min, p_[i].max);
        text(i);
        dirty_ = true;
    }
}

void HostParams::retargetKnobs(uint32_t ms)
{
    for (int k = 0; k < 7; k++) {
        Bind &b = k_[k];
        const uint32_t i = RFME_HP_KNOB + (uint32_t)k;
        const int32_t t = core_->knob_target(kKnobRole[k]);
        ParamDesc d{};
        const bool bound = t >= 0 && (uint32_t)t < core_->param_count() && core_->param_desc((uint32_t)t, &d);
        const uint32_t sig = signature(bound ? t : -1, bound ? &d : nullptr);
        if (b.sigValid && sig == b.sig)
            continue;
        b.sig = sig;
        b.sigValid = true;
        b.settling = true;
        b.settleUntil = ms + kSettleMs;
        b.holdoff = 0;
        b.valid = false;
        rfme_hp_param_t &p = p_[i];
        if (bound) {
            p.mode = RFME_HP_ABS;
            b.own = t;
            bindView(i, t);
            readValue(i, b);
            p.value = toNorm(p.plain, p.min, p.max);
        } else {
            p.mode = RFME_HP_REL;
            b.own = -1;
            bindView(i, -1);
            p.value = 0.5f;
            p.plain = 0;
            b.relBase = 0.5;
        }
        text(i);
        dirty_ = true;
    }
    uint32_t n = 0;
    for (int k = 0; k < 7; k++)
        n += p_[RFME_HP_KNOB + k].mode == RFME_HP_ABS;
    info_.knobs_bound = n;
}

void HostParams::readBack(uint32_t ms)
{
    if (!core_ || !dev_)
        return;
    started_ = true;
    last_ = ms;
    if (grace_ && (int32_t)(ms - graceUntil_) >= 0)
        grace_ = false;
    rfme_hp_param_t &m = p_[RFME_HP_MASTER];         // MASTER as the core has it (the FM-1's pot, the screen, a map)
    const int32_t master = dev_->panel()->master;
    if (master != (int32_t)std::lround(m.value) || master != m.plain) {
        m.value = (float)master;
        m.plain = master;
        text(RFME_HP_MASTER);
        dirty_ = true;
    }
    const uint32_t e = core_->param_epoch();        // (first: knob_target is valid as of the last param_epoch)
    if (!epochValid_ || e != epoch_) {
        epoch_ = e;
        epochValid_ = true;
        retargetMeta();
        retargetKnobs(ms);
    }
    for (int s = 0; s < RFME_HP_T2_SLOTS; s++)
        if (t_[s].own >= 0)
            readValue(RFME_HP_T2 + (uint32_t)s, t_[s]);
    for (int k = 0; k < 7; k++) {
        Bind &b = k_[k];
        const uint32_t i = RFME_HP_KNOB + (uint32_t)k;
        rfme_hp_param_t &p = p_[i];
        if (p.mode == RFME_HP_ABS) {
            readValue(i, b);
        } else if (p.value != 0.5f && ms - b.lastHost >= kRecentreMs) {
            p.value = 0.5f;                         // (springs back; no detents: the base moves with it)
            b.relBase = 0.5;
            text(i);
            dirty_ = true;
        }
    }
}

void HostParams::fill(HostParamState &out) const
{
    out.info = info_;
    std::memcpy(out.p, p_, sizeof p_);
}

void HostParams::formatText(const rfme_hp_param_t &p, uint32_t i, float x, CoreBackend *core, char *buf, uint32_t n)
{
    if (!buf || !n)
        return;
    buf[0] = 0;
    if (i == RFME_HP_MASTER) {
        std::snprintf(buf, n, "%d", (int)std::lround(x < 0 ? 0 : x > 1023 ? 1023 : x));
    } else if (isButton(i)) {
        std::snprintf(buf, n, "%s: %s", p.name, x >= 0.5f ? "down" : "up");
    } else if (isKey(i)) {
        std::snprintf(buf, n, "%s", x >= 0.5f ? "down" : "up");
    } else if (p.mode == RFME_HP_REL) {
        const int d = (int)std::lround(((double)x - 0.5) * kDetents);   // (the detents from the centre)
        if (d)
            std::snprintf(buf, n, "%+d", d);
        else
            std::snprintf(buf, n, "turn");
    } else if (p.mode == RFME_HP_UNBOUND || p.entry < 0) {
        std::snprintf(buf, n, "\xE2\x80\x93");      // (an en dash)
    } else {
        const int32_t v = toPlain(x, p.min, p.max);
        char t[48] = {};
        if (!core || !core->param_text((uint32_t)p.entry, v, t, sizeof t))
            std::snprintf(t, sizeof t, "%d", (int)v);
        std::snprintf(buf, n, "%s: %s", p.name, t);
    }
}

bool HostParams::parseText(const rfme_hp_param_t &p, uint32_t i, const char *text, CoreBackend *core, float *out)
{
    if (!text || !out)
        return false;
    char w[64];
    const char *s = afterName(text, w, sizeof w);
    char *end = nullptr;
    const long num = std::strtol(s, &end, 10);
    const bool isNum = end && end != s && *end == 0;
    if (i == RFME_HP_MASTER) {
        if (!isNum)
            return false;
        *out = (float)(num < 0 ? 0 : num > 1023 ? 1023 : num);
        return true;
    }
    if (isButton(i) || isKey(i)) {
        if (!strcasecmp(s, "down") || !strcasecmp(s, "on") || (isNum && num != 0))
            *out = 1.0f;
        else if (!strcasecmp(s, "up") || !strcasecmp(s, "off") || (isNum && num == 0))
            *out = 0.0f;
        else
            return false;
        return true;
    }
    if (p.mode == RFME_HP_REL) {
        if (!strcasecmp(s, "turn")) {
            *out = 0.5f;
            return true;
        }
        if (!isNum)
            return false;
        const double v = 0.5 + (double)num / kDetents;
        *out = (float)(v < 0 ? 0 : v > 1 ? 1 : v);
        return true;
    }
    if (p.mode == RFME_HP_UNBOUND || p.entry < 0)
        return false;
    if (core && p.max - p.min <= 2048)              // the firmware's own texts first ("Up", "1/8", "120 ms")
        for (int32_t v = p.min; v <= p.max; v++) {
            char t[48] = {};
            if (core->param_text((uint32_t)p.entry, v, t, sizeof t) && !strcasecmp(t, s)) {
                *out = toNorm(v, p.min, p.max);
                return true;
            }
        }
    if (!end || end == s)
        return false;
    *out = toNorm((int32_t)num, p.min, p.max);      // ("120", "120 ms", "-3")
    return true;
}

} // namespace rfm

extern "C" int rfme_hp_knob_role(int k) { return k >= 0 && k < 7 ? rfm::kKnobRole[k] : -1; }
