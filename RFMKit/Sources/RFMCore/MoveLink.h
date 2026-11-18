// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The Ableton Move as the emulated FM-1's controller (RemoteFM1's rfm_move core, host/src/move/README.md; the web's
// js/move-link.js is the model). Two halves on two threads:
//   network thread  libmoveremote's mr_client: the Move's INPUT, STATUS and BYE in; LEDs and the screen out; a PING a
//                   second; lost after 3 s silent; connects again (1, 2, 4 s) while wanted
//   core thread     the engine's (RFMEngine's between hook, once a device millisecond): owns rfm_move_t. The input is
//                   applied there, the sequencer advances there (rfm_move_seq_advance by the device clock), and its
//                   notes go into the firmware at that millisecond; the firmware's MIDI clock comes back (coreMidiOut)
// Between them only queues, so nothing touches rfm_move_t from two threads. The app's side (projects, settings)
// goes through two more: requests out (takeRequest), answers in (projectsInit, projectAnswer, projectInfo).
// The Android app ports this file (agreed 2026-11-18).
#pragma once

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "rfm/move.h"
#include "rfm/panel.h"              // rfm_event_t

namespace rfm {

// what the core thread does with the Move's actions (the engine)
struct MoveTarget {
    virtual void moveEvent(const rfm_event_t &e) = 0;                 // a key, button, encoder or MASTER, matrix ids
    virtual void moveMidi(const uint8_t *d, uint32_t n) = 0;          // one message into the firmware's MIDI in
    virtual ~MoveTarget() = default;
};

class MoveLink {
public:
    enum State { kOff = 0, kConnecting, kConnected, kRetrying, kError };
    struct Status {
        State state = kOff;
        std::string text, name;     // what to show; the Move's name (its HELLO)
        int via = -1;               // MR_VIA_*
        int battery = -1;           // 0..100, -1 unknown
        int mode = 0;               // 0..3: FM-1, MIDI, Control, Sequencer
        int project = -1;           // the open project's slot
        bool playing = false;       // the sequencer
        bool ticking = false;       // the engine runs the core (a firmware playing)
        uint32_t inputs = 0, leds = 0, screens = 0, actions = 0, connects = 0, seqMidi = 0;
    };
    // a request for the app (projects, settings): kind is an RFM_MOVE_ACT_PROJECT_* or RFM_MOVE_ACT_SETTINGS
    struct Request {
        int kind = 0, slot = -1, value = 0;
        std::vector<uint8_t> data;  // PROJECT_SAVE's blob; SETTINGS: the settings image
    };

    MoveLink(const uint8_t *settings, uint32_t n, std::string hostName);
    ~MoveLink();

    // ---- any thread (the app)
    void start(const std::string &host);     // "" : move.local (libmoveremote: USB first, then move.local)
    void stop();
    Status status() const;
    bool takeRequest(Request &r);
    // at start (once the store is read) and after the store changed: which slots hold a project, each one's blob for
    // the grid; then the project to open (blob empty: a new one there)
    void projectsInit(uint32_t dirBits, int openSlot, const std::vector<uint8_t> &openBlob);
    void projectDir(uint32_t bits);
    void projectInfo(int slot, const std::vector<uint8_t> &blob);
    void projectAnswer(int slot, const std::vector<uint8_t> &blob);    // PROJECT_LOAD's answer (empty: none there)
    void flushProject();                                               // the autosave now (the app leaves)
    static bool projectValid(const uint8_t *b, uint32_t n) { return rfm_move_project_check(b, n) == 0; }

    // ---- the core thread (RFMEngine)
    void coreTick(uint32_t ms, MoveTarget &t, const uint8_t levels[RFM_MOVE_NLEVELS], uint8_t playGreen,
                  int master, const uint16_t *lcdBE, uint32_t lcdWrites);
    void coreMidiOut(const uint8_t *msg, int n);                       // the firmware's MIDI out (realtime, F2)

private:
    struct CoreMsg {
        enum Kind { kInput, kConnected, kLost, kBattery, kInit, kDir, kInfo, kLoad, kFlush } kind;
        mr_event_t ev{};
        int slot = -1, a = 0, b = 0;
        uint32_t bits = 0;
        std::vector<uint8_t> blob;
    };
    void post(CoreMsg &&m);
    void netMain();
    void session(mr_client_t *c);
    void setStatus(State s, const std::string &text);
    static void onAct(void *ctx, const rfm_move_act_t *a);
    void act(const rfm_move_act_t &a);
    void coreMsg(CoreMsg &m, uint32_t ms);
    void request(Request &&r);

    // ---- shared
    mutable std::mutex mu_;                 // status, the queues below, want/host
    std::condition_variable cv_;
    Status st_;
    bool want_ = false, quit_ = false;
    std::string host_, hostName_;
    std::deque<CoreMsg> toCore_;            // network / app -> core
    std::vector<rfm_move_led_t> ledsOut_;   // core -> network
    std::array<uint8_t, MR_SCREEN_BYTES> screenOut_{};
    bool screenDue_ = false;
    std::deque<Request> requests_;          // core -> app
    std::thread net_;

    // ---- the core thread's
    rfm_move_t *m_ = nullptr;
    MoveTarget *target_ = nullptr;          // the engine (set by its first coreTick)
    std::atomic<uint64_t> lastTickUs_{0};   // (status: the engine runs the core)
    std::atomic<uint64_t> lastRxUs_{0};     // (the network thread's: anything from the Move)
    std::atomic<int> bye_{0};
    std::atomic<uint32_t> seqMidi_{0};    // MIDI messages into the firmware
    bool live_ = false;                     // a Move connected (the core advances, LEDs and screen go out)
    uint32_t lastMs_ = 0, lastScreenMs_ = 0, lastLcdWrites_ = ~0u, lastLedMs_ = 0;
    bool started_ = false, screenDirty_ = true;
    std::vector<CoreMsg> work_;             // toCore_ taken in one go
    std::vector<rfm_move_led_t> ledsPending_;
    std::array<uint8_t, MR_SCREEN_BYTES> screen_{}, screenSent_{};
    bool screenPending_ = false;
    std::vector<uint16_t> lcd_;             // the FM-1's screen in this CPU's byte order
    std::deque<Request> reqPending_;        // core-local until the lock is free
};

} // namespace rfm
