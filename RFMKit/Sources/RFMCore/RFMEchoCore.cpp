// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// (tests) A core that echoes its MIDI in to its MIDI out, packet for packet, and plays silence: the AU's MIDI path
// end to end without a firmware (rfme_test_load_echo). A note-on of note 0 also sends a SysEx (F0 7D 01 02 03 04 05
// F7, three USB-MIDI packets).
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
        for (int i = 0; i < FM1P_NB; i++)
            p_.btn_id[i] = (uint8_t)i;
        for (int i = 0; i < FM1P_NE - 1; i++) {
            p_.enc_id[i] = (uint8_t)i;
            p_.enc_dir[i] = 1;
        }
    }
    void tick(uint32_t) override {}
    void frame() override {}
    void idle() override {}
    void audio(int16_t *s, uint32_t n) override { std::memset(s, 0, n * 2 * sizeof *s); }
    int midi_in(uint32_t pkt) override
    {
        if (w_ - r_ > kRing - 4)
            return 0;
        put(pkt);
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

private:
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
