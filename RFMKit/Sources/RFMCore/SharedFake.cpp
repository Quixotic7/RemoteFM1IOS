// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The process-wide fake unit (SharedFake.h).
#include "SharedFake.h"

#include <chrono>
#include <cstring>

#include "RFMInternal.h"
#include "rfm/codec.h"
#include "rfm/fake.h"
#include "rfm1.h"

namespace rfm {

SharedFake &SharedFake::get()
{
    static SharedFake *s = new SharedFake;   // (never freed: links may outlive static destruction)
    return *s;
}

SharedFake::SharedFake()
{
    rfm_fake_cfg_t fc;
    rfm_fake_cfg_default(&fc);
    fc.sx_rate_bps = 300000;                // (RemoteLink's own fake: the M0 numbers, SysEx only as on iOS)
    fc.has_bulk = 0;
    f_ = rfm_fake_new(&fc);
    buf_.resize(1u << 18);
    t0_ = (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now().time_since_epoch())
              .count();
}

uint32_t SharedFake::now() const
{
    const uint64_t t = (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now().time_since_epoch())
                           .count();
    return (uint32_t)(t - t0_);
}

SharedFake::Sender &SharedFake::sender(const std::string &label)
{
    for (size_t i = 0; i < senders_.size(); i++)
        if (senders_[i].label == label)
            return senders_[i];
    Sender n;
    n.label = label;
    n.sinceOther = starts_ > 0;
    senders_.push_back(n);
    return senders_.back();
}

int SharedFake::open(const std::string &label)
{
    std::lock_guard<std::mutex> g(mu_);
    for (int i = 0; i < 16; i++) {
        Port &p = ports_[i];
        if (p.used)
            continue;
        p.used = true;
        p.label = label;
        p.inbox.clear();
        p.self = this;
        if (!p.rx)
            p.rx = rfm_rx_new(RFM_LINK_SX, 4096, onMsg, nullptr, &p);
        else
            rfm_rx_reset(p.rx);
        sender(label);
        return i;
    }
    return -1;
}

void SharedFake::close(int port)
{
    if (port < 0 || port >= 16)
        return;
    std::lock_guard<std::mutex> g(mu_);
    ports_[port].used = false;
    ports_[port].inbox.clear();
}

void SharedFake::onMsg(void *ctx, uint8_t cmd, const uint8_t *body, uint32_t n)
{
    Port *p = static_cast<Port *>(ctx);
    SharedFake *s = p->self;
    Sender &me = s->sender(p->label);
    const size_t mi = (size_t)(&me - s->senders_.data());
    me.msgs++;
    if (cmd == RFM_TILES)
        me.tiles++;
    if (cmd == RFM_SESSION) {
        int start = 0;
        uint32_t ka = 0;
        if (rfm_parse_session(body, n, &start, &ka) == 0) {
            if (start) {
                me.starts++;
                s->starts_++;
                s->lastStarter_ = p->label;
                for (size_t i = 0; i < s->senders_.size(); i++)
                    s->senders_[i].sinceOther = i != mi;
                return;
            }
            me.stops++;
        }
    }
    if (me.sinceOther && cmd != RFM_HELLO) {
        me.afterOther++;
        if (cmd == RFM_TILES)
            me.afterOtherTiles++;
    }
}

void SharedFake::write(int port, const uint8_t *p, uint32_t n)
{
    if (port < 0 || port >= 16)
        return;
    std::lock_guard<std::mutex> g(mu_);
    if (!ports_[port].used)
        return;
    rfm_rx_feed(ports_[port].rx, p, n);
    rfm_fake_rx_sx(f_, p, n, now());
}

uint32_t SharedFake::take(int port, uint8_t *out, uint32_t cap)
{
    if (port < 0 || port >= 16)
        return 0;
    std::lock_guard<std::mutex> g(mu_);
    rfm_fake_poll(f_, now());
    const uint32_t n = rfm_fake_take_sx(f_, buf_.data(), (uint32_t)buf_.size());
    if (n)
        for (Port &p : ports_)
            if (p.used)
                p.inbox.insert(p.inbox.end(), buf_.data(), buf_.data() + n);
    Port &me = ports_[port];
    const uint32_t k = (uint32_t)std::min<size_t>(me.inbox.size(), cap);
    if (k) {
        std::memcpy(out, me.inbox.data(), k);
        me.inbox.erase(me.inbox.begin(), me.inbox.begin() + k);
    }
    return k;
}

void SharedFake::with(const std::function<void(rfm_fake *)> &fn)
{
    std::lock_guard<std::mutex> g(mu_);
    fn(f_);
}

SharedFake::Record SharedFake::record()
{
    std::lock_guard<std::mutex> g(mu_);
    Record r;
    rfm_fake_stats_t st;
    rfm_fake_stats(f_, &st);
    r.session = rfm_fake_session(f_);
    r.lastStarter = lastStarter_;
    r.starts = starts_;
    r.frames = st.frames;
    r.acks = st.acks;
    for (const Port &p : ports_)
        r.openPorts += p.used ? 1u : 0u;
    r.senders = senders_;
    return r;
}

void SharedFake::panelRGBA(uint8_t *rgba)
{
    std::lock_guard<std::mutex> g(mu_);
    rfm::lcdToRGBA(reinterpret_cast<const uint16_t *>(rfm_fake_panel(f_)), rgba, RFM_W * RFM_H);
}

} // namespace rfm
