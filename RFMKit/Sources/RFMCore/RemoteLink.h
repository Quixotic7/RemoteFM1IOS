// SPDX-License-Identifier: GPL-3.0-only
// Copied from FM1VST v0.6.2 plugin/RemoteLink.h. Changed for RemoteFM1 iOS: Status also carries the unit's HELLO_R,
// the session state and more of rfm_session_stats_t (budget, bytes, ACK times); requestRescan() (CoreMIDI's setup
// changed). M4: the unit lock is optional (an empty lockPath: none; the lease of PLAN.md section 4 decides instead,
// through a gate: below); drop(); a process-wide fake unit shared by several links (tests); the unit's TRS MIDI in (MIDI_IN, popMidi).
// Everything else as there.
// Remote FM-1 (RemoteFM1 M3): a real M-VAVE FM-1 running the RemoteFM1 firmware as the panel of the core inside the
// plugin. The protocol and the host library are RemoteFM1's (remote/RemoteFM1: docs/PROTOCOL.md, host/include/rfm);
// this is fm1remote's design (host/tools/fm1remote/engine.h, main.cpp) inside a plugin instance.
//
// THREADS
//   session thread   one per RemoteLink, started by the first start() and joined by the destructor. While the link
//                    is wanted it takes the unit lock, runs libremotefm1 (rfm_session over the CoreMIDI and libusb
//                    back ends, or over the in-process fake unit), and polls it every 1-2 ms; when not wanted it sleeps
//                    on a condition variable. start() / stop() only set a flag and return at once.
//   audio thread     (the processor, devLock_ held) pops panel events (popEvent) and publishes the LCD + LEDs
//                    (back() .. publish()). Both are lock-free, allocation-free and bounded.
//   message thread   start / stop / status / options (the editor, the state).
// Session -> audio: a single-producer single-consumer queue of rfm_event_t (matrix ids, as the unit sends them).
// Audio -> session: a triple buffer of RemoteSnapshot (the newest wins; the session thread gives it to
// rfm_session_set_frame / set_leds, which diff it against the unit's shadow and send what differs).
//
// ONE OWNER PER UNIT, ACROSS EVERYTHING ON THIS MAC: an exclusive flock on <fm1emu home>/remote.lock (FM1EMU_HOME
// relocates it, as every other fm1emu file). flock locks belong to an open file, so a second instance in the same host
// is locked out exactly as the Standalone next to Live is. A link that cannot take the lock reports "in use", touches
// nothing, and tries again every second (it takes over when the owner lets go). The kernel drops the lock when a host
// process dies; the unit then ends the session by itself after its keepalive (3 s).
//
// STOPPING (stop(), the destructor): SESSION start=0 (the unit goes back to its waiting screen), up to kStopMs for its
// ACK, then the back ends closed and the lock released. The destructor joins the thread (bounded by kStopMs).
//
// THE GATE (M4, RemoteFM1 iOS): setGate(gate, onDrop, ctx). The session thread calls gate() before it starts a run
// and before every pump, frame and poll (anything that may write to the unit), and the shared fake's write checks it
// too. When it says no (another instance took the unit: the lease's epoch moved), the run DROPS: nothing more is sent,
// the back ends are closed, no SESSION 0 (it could end the new owner's session), the link stays off, and onDrop() runs
// on the session thread once its links are closed (the lease's ack). drop() asks for the same from any thread.
//
// THE FAKE UNIT (tests): Backend::Fake runs libremotefm1's fake (host/src/fake.c) in this process behind a loopback at
// the measured M0 rates; nothing on USB or CoreMIDI is touched. FM1EMU_REMOTE_FAKE=1 in the environment forces it for
// every link (defaultBackend()). The fake belongs to the link (it outlives each run, as a unit stays plugged in);
// withFake() reaches it under the session thread's lock. sharedFake (M4): every such link in the process talks to ONE
// fake unit (SharedFake.h) while its run lasts, as several CoreMIDI clients connected to one FM-1 would.
#pragma once
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "rfm/codec.h"
#include "rfm/panel.h"
#include "rfm1.h"

struct rfm_session;
struct rfm_mac;
struct rfm_fake;

// what the unit shows: the LCD exactly as emu_hal_t.lcd holds it (RGB565, each slot big-endian in memory) and the LEDs
struct RemoteSnapshot {
    uint16_t lcd[RFM_W * RFM_H];
    rfm_leds_t leds;
    uint32_t seq = 0;
};

class RemoteLink {
public:
    enum class Backend { Device, Fake };
    // Fake when FM1EMU_REMOTE_FAKE is set (and not "0"), else Device
    static Backend defaultBackend();
    struct Options {
        Backend backend = Backend::Device;
        std::string lockPath;                       // the unit lock (FM1Processor: home()/remote.lock)
        uint32_t fps = 20;                          // frames per second to the unit (the session's cap)
        std::string hostName = "FM1VST";            // HELLO's body
        // (tests) the fake unit as a RemoteFM1 0.2.2 unit over Bluetooth MIDI: SysEx only, its HELLO_R says
        // Bluetooth, HOLD in its caps, the wire at Bluetooth's rate (the session paces and reduces tiles for it)
        bool fakeBluetooth = false;
        // (RemoteFM1 iOS, tests) Backend::Fake: the process-wide shared fake unit instead of this link's own; the
        // label names this link in the shared fake's record of who sent what
        bool sharedFake = false;
        std::string fakeLabel;
    };
    explicit RemoteLink(const Options &o);
    ~RemoteLink();                                  // stop(), then the thread joined (<= kStopMs + a poll)
    RemoteLink(const RemoteLink &) = delete;
    RemoteLink &operator=(const RemoteLink &) = delete;

    // ---- control (any thread; they return at once)
    void start();
    void stop();
    bool wanted() const { return want_.load(); }
    // (RemoteFM1 iOS) the gate (above); set before the first start(). gate(ctx) runs on the session thread
    using Gate = bool (*)(void *ctx);
    using DropFn = void (*)(void *ctx);
    void setGate(Gate g, DropFn onDrop, void *ctx)
    {
        gateCtx_.store(ctx);
        onDrop_.store(onDrop);
        gate_.store(g);
    }
    void drop();                                    // the run ends without SESSION 0 (any thread; returns at once)
    Backend backend() const { return opt_.backend; }
    static bool hasBulk();                          // built with libusb (else SysEx only)

    enum State { kOff = 0, kInUse, kSearching, kConnected, kLost, kError, kStopping };
    struct Status {
        State state = kOff;
        bool bulk = false;                          // kConnected: frames on the vendor bulk pipe (else SysEx)
        bool ble = false;                           // kConnected: frames over Bluetooth MIDI (paced for it)
        float fps = 0.0f;                           // frames sent in the last second
        uint32_t sessions = 0, frames = 0, acks = 0, pending = 0, inFlight = 0, fullResends = 0, eventsIn = 0;
        uint32_t eventsDropped = 0, snapshotsTaken = 0, runs = 0;
        // Bluetooth (libremotefm1's rfm_session_stats_t): tiles sent reduced to `colors` colours, reduced tiles
        // sent again exactly once the screen was still, frames sent with HOLD (a screen change shown whole)
        uint32_t colors = 0, reduced = 0, refined = 0, held = 0;
        std::string text;                           // for the editor: "connected (bulk, 20 fps)" ..
        std::string lastLog;                        // the session's last log line
        // (RemoteFM1 iOS) the session's own view: RFM_S_*, -1 none; the unit's HELLO_R once found (kept after)
        int sessionState = -1;
        bool haveHello = false;
        rfm_hello_t hello{};
        uint32_t budget = 0, wireBytes = 0, bodyBytes = 0, ackMsLast = 0, ackMsAvg = 0, ackMsMax = 0;
        uint32_t ackTimeouts = 0, discoveries = 0, hold = 0, wireCap = 0, frameMs = 0;
        uint32_t drops = 0, gateBlocked = 0;        // (M4) runs dropped; shared-fake writes the gate refused
        // (RemoteFM1 0.3, RFM_CAP_MIDI_IN) the unit's TRS MIDI in: messages queued for the core, lost (queue full)
        uint32_t trsMidiIn = 0, trsMidiDropped = 0;
    };
    Status status() const;
    static const char *stateName(State s);

    // ---- the audio thread
    // this link holds the unit (the lock taken, the back ends running): panel events may come, frames are wanted
    bool engaged() const { return engaged_.load(std::memory_order_acquire); }
    // one panel event (rfm_event_t: RFM_EV_KEY / BUTTON / ENC / MASTER, matrix ids), or kEvRelease: everything the
    // unit held is up (the session ended or the unit was lost)
    static constexpr uint8_t kEvRelease = 0x80;
    bool popEvent(rfm_event_t &e) { return q_.pop(e); }
    // (RemoteFM1 iOS, RFM_CAP_MIDI_IN) one MIDI message from the unit's TRS jack (MIDI_IN, split by status: a channel
    // message or real time F8 FA FB FC), in order, for the core's MIDI in. Popped where the panel events are
    struct MidiMsg {
        uint8_t len = 0;
        uint8_t data[3] = {0, 0, 0};
    };
    bool popMidi(MidiMsg &m) { return midiQ_.pop(m); }
    // true once after a run started or invalidateScreen(): publish now, whatever changed
    bool takeFullRequest() { return fullReq_.exchange(false, std::memory_order_acq_rel); }
    void requestFull() { fullReq_.store(true, std::memory_order_release); }   // (any thread: the next block publishes)
    RemoteSnapshot &back() { return tb_.back(); }
    void publish() { tb_.publish(); }
    static constexpr uint32_t kPeriodMs = 50;       // the audio thread publishes at most every kPeriodMs device ms

    // ---- any thread: CoreMIDI's setup changed (a Bluetooth device came or went): the session thread rescans
    void requestRescan() { rescan_.store(true, std::memory_order_release); }

    // ---- any thread: the device's screen is unknown (a power cycle, a core switch): the next frame resends it all
    void invalidateScreen();

    // ---- tests: the fake unit, under the session thread's lock (Backend::Fake only; f is nullptr otherwise)
    template <typename F> void withFake(F &&fn)
    {
        if (opt_.sharedFake && opt_.backend == Backend::Fake) {
            withSharedFake([&](rfm_fake *f) { fn(f); });
            return;
        }
        std::lock_guard<std::mutex> g(fakeMu_);
        fn(fake_);
    }

    static constexpr uint32_t kStopMs = 600;        // the longest a stop waits for the unit's ACK
    static constexpr uint32_t kLockRetryMs = 1000;
    static constexpr int kNoLock = -2;              // (takeLock: no lock path, none taken)

private:
    // single producer (the session thread), single consumer (the audio thread)
    template <uint32_t N, typename T = rfm_event_t> class EventQueue {
    public:
        bool push(const T &e)
        {
            const uint32_t w = w_.load(std::memory_order_relaxed);
            if (w - r_.load(std::memory_order_acquire) >= N)
                return false;
            buf_[w % N] = e;
            w_.store(w + 1, std::memory_order_release);
            return true;
        }
        bool pop(T &e)
        {
            const uint32_t r = r_.load(std::memory_order_relaxed);
            if (r == w_.load(std::memory_order_acquire))
                return false;
            e = buf_[r % N];
            r_.store(r + 1, std::memory_order_release);
            return true;
        }

    private:
        std::array<T, N> buf_{};
        std::atomic<uint32_t> w_{0}, r_{0};
    };
    // one writer (the audio thread), one reader (the session thread); the reader gets the newest published buffer
    class TripleBuffer {
    public:
        TripleBuffer()
        {
            for (auto &p : s_)
                p = std::make_unique<RemoteSnapshot>();
        }
        RemoteSnapshot &back() { return *s_[back_]; }
        void publish() { back_ = mid_.exchange(back_ | FRESH, std::memory_order_acq_rel) & 3; }
        const RemoteSnapshot *take()
        {
            if (!(mid_.load(std::memory_order_acquire) & FRESH))
                return nullptr;
            front_ = mid_.exchange(front_, std::memory_order_acq_rel) & 3;
            return s_[front_].get();
        }

    private:
        static constexpr int FRESH = 4;
        std::unique_ptr<RemoteSnapshot> s_[3];
        int back_ = 0, front_ = 2;
        std::atomic<int> mid_{1};
    };

    struct Loop {                                   // a loopback link to the fake unit
        RemoteLink *self;
        int kind, id;
    };

    void threadMain();
    void runOnce();                                 // one run: the lock, the back ends, the session, the stop
    int takeLock();                                 // the fd, or -1 (in use, or an error: lockError_)
    uint32_t now() const;
    void setStatus(State s, const std::string &text);
    void updateStatus(uint32_t now);
    void pumpFake(uint32_t now);
    void releasePanel();                            // kEvRelease, and the decoder forgets what it held
    bool gateOpen();                                // the gate says this link may send (no gate: yes)
    static void withSharedFake(const std::function<void(rfm_fake *)> &fn);

    static void cbEvent(void *ctx, const rfm_event_t *e);
    static void cbState(void *ctx, int st, const char *why);
    static void cbRescan(void *ctx);
    static void cbLog(void *ctx, const char *m);
    static void cbMidiIn(void *ctx, const uint8_t *msgs, uint32_t n);
    static int loopWrite(void *ctx, const uint8_t *p, uint32_t n);

    Options opt_;
    std::thread th_;
    std::mutex mu_;                                 // want_ / quit_ changes, the condition variable
    std::condition_variable cv_;
    std::atomic<bool> want_{false}, quit_{false}, engaged_{false}, fullReq_{false}, invalidate_{false}, rescan_{false};
    EventQueue<4096> q_;
    EventQueue<1024, MidiMsg> midiQ_;                // (TRS MIDI in) the session thread -> the panel's consumer
    TripleBuffer tb_;
    // the session thread's own
    rfm_session *s_ = nullptr;
    rfm_mac *mac_ = nullptr;
    rfm_fake *fake_ = nullptr;                      // Backend::Fake: for the link's lifetime
    std::mutex fakeMu_;
    Loop loops_[2] = {};
    int sharedPort_ = -1;                           // the shared fake's port while a run lasts
    std::atomic<Gate> gate_{nullptr};
    std::atomic<DropFn> onDrop_{nullptr};
    std::atomic<void *> gateCtx_{nullptr};
    std::atomic<bool> dropReq_{false};
    std::atomic<uint32_t> drops_{0}, gateBlocked_{0};
    std::vector<uint8_t> loopBuf_;
    int lastState_ = -1;
    bool wasConnected_ = false;
    uint32_t statFrames_ = 0, statT_ = 0;
    std::chrono::steady_clock::time_point t0_;
    std::string lockError_;
    // the status (the session thread writes, anyone reads)
    mutable std::mutex stMu_;
    Status st_;
    std::atomic<uint32_t> trsMidiIn_{0}, trsMidiDropped_{0};
    std::atomic<uint32_t> eventsIn_{0}, eventsDropped_{0}, snapshotsTaken_{0}, fullResends_{0}, runs_{0};
};
