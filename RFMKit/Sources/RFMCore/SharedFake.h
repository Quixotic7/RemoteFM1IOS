// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The process-wide fake unit (M4, tests): one libremotefm1 fake that every RemoteLink with Options::sharedFake talks
// to, as several CoreMIDI clients connected to one FM-1. A link opens a port for each run (its "CoreMIDI
// connection") and closes it at the run's end; what the unit sends goes to every open port, as CoreMIDI delivers the
// unit's source to every connected client. The fake keeps its own clock.
//
// It also keeps a record of who sent what (by the link's label): SESSION starts and stops, and the messages each
// sender sent after ANOTHER sender's SESSION start (until its own next start) other than HELLO: what the takeover
// test checks (a stale owner sends nothing once the new one has started, and never SESSION 0).
#pragma once
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

struct rfm_fake;
struct rfm_rx;

namespace rfm {

class SharedFake {
public:
    static SharedFake &get();

    int open(const std::string &label);             // a port, -1: none free
    void close(int port);
    void write(int port, const uint8_t *p, uint32_t n);
    // polls the fake, hands what it sent to every open port, and moves this port's into out; returns the bytes
    uint32_t take(int port, uint8_t *out, uint32_t cap);
    void with(const std::function<void(rfm_fake *)> &fn);

    struct Sender {
        std::string label;
        uint32_t msgs = 0, starts = 0, stops = 0, tiles = 0, afterOther = 0, afterOtherTiles = 0;
        bool sinceOther = false;                    // another sender started a session after this one's last start
    };
    struct Record {
        int session = 0;                            // the fake's: 0 none, 1 SysEx
        std::string lastStarter;                    // the label of the last SESSION start
        uint32_t starts = 0, frames = 0, acks = 0, openPorts = 0;
        std::vector<Sender> senders;
    };
    Record record();
    // the fake's panel (what the unit shows) as RGBA8888, 240 x 240 x 4
    void panelRGBA(uint8_t *rgba);

private:
    SharedFake();
    struct Port {
        bool used = false;
        std::string label;
        std::vector<uint8_t> inbox;
        rfm_rx *rx = nullptr;                       // parses what this port's link sends
        SharedFake *self = nullptr;
    };
    static void onMsg(void *ctx, uint8_t cmd, const uint8_t *body, uint32_t n);
    Sender &sender(const std::string &label);
    uint32_t now() const;

    std::mutex mu_;
    rfm_fake *f_ = nullptr;
    Port ports_[16];
    std::vector<uint8_t> buf_;
    std::vector<Sender> senders_;
    std::string lastStarter_;
    uint32_t starts_ = 0;
    uint64_t t0_ = 0;
};

} // namespace rfm
