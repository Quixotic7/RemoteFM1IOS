// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The Ableton Move as the emulated FM-1's controller, on rfm1cs-abletonmove (vendor/rfm1cs-abletonmove: the core, and
// the session that speaks Move Remote's protocol, shared with the web player and the Android app). This file only
// carries bytes and time to the session and its actions to the engine:
//   network thread  the socket (rfm1cs_tcp): opens and closes it when the session says, its bytes into the session
//                   (_opened, _rx, _closed, _tick), what the session sends written out
//   core thread     the engine's (RFMEngine's between hook, once a device millisecond): the sequencer advanced by the
//                   device clock (_advance, its notes into the firmware then), the firmware's MIDI clock in
//                   (_midi_in), the FM-1's LEDs (_panel) and screen (_frame)
// One mutex keeps the session to one thread at a time; the core thread only tries it (busy: the next millisecond,
// with the time kept). A key or a pad from the network thread reaches the engine through a queue, at its next
// millisecond. The app's side (projects, settings) goes through requests out (takeRequest) and plain calls in.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "rfm1cs/session.h"
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
    struct Status {
        int state = RFM1CS_OFF;     // RFM1CS_* (OFF, CONNECTING, CONNECTED, RETRYING, FAILED)
        std::string text, name;     // what to show; the Move's name (its HELLO)
        int via = -1;               // MR_VIA_*
        int battery = -1;           // 0..100, -1 unknown
        int mode = 0;               // 0..3: FM-1, MIDI, Control, Sequencer
        int project = -1;           // the open project's slot
        bool playing = false;       // the sequencer
        bool ticking = false;       // the engine runs the core (a firmware playing)
        uint32_t inputs = 0, leds = 0, screens = 0, connects = 0, seqMidi = 0;
    };
    // a request for the app (projects, settings): kind is an RFM_MOVE_ACT_PROJECT_* or RFM_MOVE_ACT_SETTINGS
    struct Request {
        int kind = 0, slot = -1, value = 0;
        std::vector<uint8_t> data;  // PROJECT_SAVE's blob; SETTINGS: the settings image
    };

    MoveLink(const uint8_t *settings, uint32_t n, std::string hostName);
    ~MoveLink();

    // ---- any thread (the app)
    void start(const std::string &host);     // "" : move.local; "address:port" for another port
    void stop();
    Status status() const;
    bool takeRequest(Request &r);
    // at start (once the store is read): which slots hold a project, and the one to open (blob empty: a new one)
    void projectsInit(uint32_t dirBits, int openSlot, const std::vector<uint8_t> &openBlob);
    void projectDir(uint32_t bits);
    void projectInfo(int slot, const std::vector<uint8_t> &blob);
    void projectAnswer(int slot, const std::vector<uint8_t> &blob);    // PROJECT_LOAD's answer (empty: none there)
    void flushProject();                                               // the autosave now (the app leaves)

    // ---- the core thread (RFMEngine)
    void coreTick(uint32_t ms, MoveTarget &t, const uint8_t levels[RFM_MOVE_NLEVELS], uint8_t playGreen,
                  int master, const uint16_t *lcdBE, uint32_t lcdWrites);
    void coreMidiOut(const uint8_t *msg, int n);                       // the firmware's MIDI out (realtime, F2)

private:
    struct Out {                            // session -> network thread, in order
        enum Kind { kSend, kOpen, kClose } kind;
        std::vector<uint8_t> bytes;
        uint32_t attempt = 0;               // kOpen: the session's try (its _opened / _rx / _closed carry it)
    };
    static void onEvent(void *ctx, const rfm1cs_event_t *ev);
    void event(const rfm1cs_event_t &ev);
    void act(const rfm_move_act_t &a, const uint8_t *data, uint32_t len);
    void engineAct(const rfm_move_act_t &a);
    void snap();                            // (sm_ held) the session's status into st_
    void netMain();
    bool engineLive() const;

    rfm1cs_session_t *s_ = nullptr;
    mutable std::mutex sm_;                 // the session: one thread at a time
    mutable std::mutex qmu_;                // everything below up to the core thread's
    std::condition_variable cv_;
    bool quit_ = false;
    std::string host_, hostName_;
    std::deque<Out> out_;
    std::deque<Request> requests_;
    std::deque<rfm_move_act_t> engineQ_;    // keys and pads for the engine from outside its thread
    rfm1cs_status_t st_{};
    std::thread net_;

    // ---- the core thread's
    bool inCore_ = false;                   // (sm_ held) the session's call came from coreTick
    MoveTarget *target_ = nullptr;
    std::atomic<uint64_t> lastTickMs_{0};
    std::atomic<uint32_t> seqMidi_{0};      // MIDI messages into the firmware
    uint32_t lastMs_ = 0, lastFrameMs_ = 0, lastLcdWrites_ = ~0u, lastConnects_ = 0;
    uint64_t pendingUs_ = 0;                // device time not yet given to _advance (the lock was busy)
    int master_ = -1;
    bool started_ = false;
    std::vector<uint8_t> midiIn_;           // the firmware's MIDI out, waiting for the lock (len, bytes..)
    std::vector<uint16_t> lcd_;             // the FM-1's screen in this CPU's byte order
};

} // namespace rfm
