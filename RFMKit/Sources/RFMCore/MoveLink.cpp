// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// MoveLink (MoveLink.h): rfm1cs-abletonmove's session over a POSIX socket, its core on the engine's core thread.

#include "MoveLink.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>

#include "rfm1cs/posix_tcp.h"

namespace rfm {

namespace {
constexpr uint32_t kFrameMs = 33;           // a new FM-1 screen into the session at most this often (its thumbnail)
constexpr uint32_t kEngineMs = 200;         // the engine ticked this recently: a firmware runs the core
constexpr size_t kMaxEngineQ = 4096;        // (keys from the network thread waiting for the engine)
constexpr size_t kMaxMidiIn = 4096;

uint32_t nowMs()
{
    using namespace std::chrono;
    return (uint32_t)duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}
} // namespace

MoveLink::MoveLink(const uint8_t *settings, uint32_t n, std::string hostName) : hostName_(std::move(hostName))
{
    s_ = static_cast<rfm1cs_session_t *>(std::calloc(1, sizeof(rfm1cs_session_t)));   // (~180 KB: not the stack)
    rfm1cs_session_init(s_, settings, n, hostName_.c_str(), onEvent, this);
    st_ = *rfm1cs_session_status(s_);
    lcd_.resize(240 * 240);
    net_ = std::thread([this] { netMain(); });
}

MoveLink::~MoveLink()
{
    {
        std::lock_guard<std::mutex> g(sm_);
        rfm1cs_session_stop(s_);
    }
    {
        std::lock_guard<std::mutex> g(qmu_);
        quit_ = true;
    }
    cv_.notify_all();
    if (net_.joinable())
        net_.join();
    std::free(s_);
}

// ------------------------------------------------------------------ the app ---

void MoveLink::start(const std::string &host)
{
    {
        std::lock_guard<std::mutex> g(qmu_);
        host_ = host.empty() ? "move.local" : host;
        lostWhy_ = byeWhy_ = 0;
    }
    std::lock_guard<std::mutex> g(sm_);
    if (rfm1cs_session_status(s_)->state != RFM1CS_OFF)
        rfm1cs_session_stop(s_);                // (another address: from the start)
    rfm1cs_session_start(s_, nowMs());
    snap();
}

void MoveLink::stop()
{
    std::lock_guard<std::mutex> g(sm_);
    rfm1cs_session_stop(s_);
    snap();
}

bool MoveLink::engineLive() const { return nowMs() - (uint32_t)lastTickMs_.load(std::memory_order_relaxed) < kEngineMs; }

MoveLink::Status MoveLink::status() const
{
    std::lock_guard<std::mutex> g(qmu_);
    Status s;
    s.state = st_.state;
    s.name = st_.name;
    s.via = st_.via;
    s.battery = st_.battery;
    s.mode = st_.mode;
    s.project = st_.project;
    s.playing = st_.playing != 0;
    s.ticking = engineLive();
    s.inputs = st_.inputs;
    s.leds = st_.led_writes;
    s.screens = st_.screens;
    s.connects = st_.connects;
    s.seqMidi = seqMidi_.load(std::memory_order_relaxed);
    const std::string &host = host_;
    const std::string name = s.name.empty() ? "the Move" : s.name;
    const std::string again = " Trying again in " + std::to_string((st_.retry_ms + 999) / 1000) + " s.";
    switch (st_.state) {
    case RFM1CS_OFF:
        s.text = byeWhy_ == MR_BYE_REPLACED ? "Another app took the Move."
               : byeWhy_ ? "The Move left Move Remote." : "Off";
        break;
    case RFM1CS_CONNECTING:
        s.text = "Connecting to " + host + "...";
        break;
    case RFM1CS_CONNECTED:
        s.text = "Connected to " + name + (st_.via == MR_VIA_USB ? " over USB" : st_.via == MR_VIA_WIFI ? " over Wi-Fi" : "");
        break;
    case RFM1CS_RETRYING:
        switch (lostWhy_) {
        case RFM1CS_WHY_SILENT: s.text = "The Move stopped answering." + again; break;
        case RFM1CS_WHY_GARBLED: s.text = "The Move's messages didn't make sense." + again; break;
        case RFM1CS_WHY_NOT_MOVE: s.text = host + " isn't a Move running Move Remote." + again; break;
        case RFM1CS_WHY_SHUTDOWN: s.text = "The Move shut down: connecting again when it's back."; break;
        default:
            s.text = st_.ever_live ? "Link lost." + again
                                   : "No answer. Is Move Remote running on the Move, and is " + host + " its address?" + again;
        }
        break;
    default:
        s.text = lostWhy_ == RFM1CS_WHY_PROTO
                     ? "This Move Remote speaks another protocol version (" + std::to_string(st_.proto) +
                           "): update the app or Move Remote."
                     : "Couldn't connect to the Move.";
    }
    return s;
}

bool MoveLink::takeRequest(Request &r)
{
    std::lock_guard<std::mutex> g(qmu_);
    if (requests_.empty())
        return false;
    r = std::move(requests_.front());
    requests_.pop_front();
    return true;
}

static const uint8_t *ptr(const std::vector<uint8_t> &b) { return b.empty() ? nullptr : b.data(); }

void MoveLink::projectsInit(uint32_t dirBits, int openSlot, const std::vector<uint8_t> &openBlob)
{
    std::lock_guard<std::mutex> g(sm_);
    rfm1cs_session_projects_init(s_, nowMs(), dirBits, openSlot, ptr(openBlob), (uint32_t)openBlob.size());
    snap();
}

void MoveLink::projectDir(uint32_t bits)
{
    std::lock_guard<std::mutex> g(sm_);
    rfm_move_project_dir(&s_->core, bits);
    rfm1cs_session_redraw(s_, nowMs());
}

void MoveLink::projectInfo(int slot, const std::vector<uint8_t> &blob)
{
    std::lock_guard<std::mutex> g(sm_);
    rfm_move_project_info(&s_->core, slot, ptr(blob), (uint32_t)blob.size());
    rfm1cs_session_redraw(s_, nowMs());
}

void MoveLink::projectAnswer(int slot, const std::vector<uint8_t> &blob)
{
    std::lock_guard<std::mutex> g(sm_);
    const uint32_t now = nowMs();
    if (rfm1cs_session_project_answer(s_, now, slot, ptr(blob), (uint32_t)blob.size()) < 0)
        rfm1cs_session_project_answer(s_, now, slot, nullptr, 0);   // (unreadable: an empty project there)
    snap();
}

void MoveLink::flushProject()
{
    std::lock_guard<std::mutex> g(sm_);
    rfm1cs_session_flush(s_);
}

void MoveLink::snap()
{
    std::lock_guard<std::mutex> g(qmu_);
    st_ = *rfm1cs_session_status(s_);
}

// ------------------------------------------------------------------ the session's events (sm_ held) ---

void MoveLink::onEvent(void *ctx, const rfm1cs_event_t *ev) { static_cast<MoveLink *>(ctx)->event(*ev); }

void MoveLink::event(const rfm1cs_event_t &ev)
{
    switch (ev.type) {
    case RFM1CS_EV_SEND:
    case RFM1CS_EV_OPEN:
    case RFM1CS_EV_CLOSE: {
        Out o{ev.type == RFM1CS_EV_SEND ? Out::kSend : ev.type == RFM1CS_EV_OPEN ? Out::kOpen : Out::kClose, {}};
        if (ev.type == RFM1CS_EV_SEND)
            o.bytes.assign(ev.data, ev.data + ev.len);
        {
            std::lock_guard<std::mutex> g(qmu_);
            out_.push_back(std::move(o));
        }
        if (ev.type != RFM1CS_EV_SEND)
            cv_.notify_all();
        break;
    }
    case RFM1CS_EV_ACTION:
        if (ev.act)
            act(*ev.act, ev.data, ev.len);
        break;
    case RFM1CS_EV_LOST: {
        std::lock_guard<std::mutex> g(qmu_);
        lostWhy_ = ev.reason;
        byeWhy_ = 0;
        break;
    }
    case RFM1CS_EV_BYE: {
        std::lock_guard<std::mutex> g(qmu_);
        byeWhy_ = ev.reason ? ev.reason : -1;
        break;
    }
    default:                                    // (RELEASED: no timed MIDI is queued here; STATUS: snap())
        break;
    }
}

void MoveLink::act(const rfm_move_act_t &a, const uint8_t *data, uint32_t len)
{
    switch (a.kind) {
    case RFM_MOVE_ACT_KEY:
    case RFM_MOVE_ACT_PRESS:
    case RFM_MOVE_ACT_BTN:
    case RFM_MOVE_ACT_TURN:
    case RFM_MOVE_ACT_MASTER:
    case RFM_MOVE_ACT_MIDI:
        if (inCore_) {
            engineAct(a);
        } else if (engineLive()) {              // (from the network thread: the engine takes it next millisecond)
            rfm_move_act_t e = a;                // (its MIDI bytes are inline)
            e.data = nullptr;
            e.len = 0;
            std::lock_guard<std::mutex> g(qmu_);
            if (engineQ_.size() < kMaxEngineQ)
                engineQ_.push_back(e);
        }                                       // (no firmware running: nothing to play it into)
        return;
    case RFM_MOVE_ACT_SETTINGS:
    case RFM_MOVE_ACT_PROJECT_SAVE:
    case RFM_MOVE_ACT_PROJECT_LOAD:
    case RFM_MOVE_ACT_PROJECT_DELETE:
    case RFM_MOVE_ACT_PROJECT_CUT:
    case RFM_MOVE_ACT_PROJECT_COPY:
    case RFM_MOVE_ACT_PROJECT_PASTE:
    case RFM_MOVE_ACT_PROJECT_COLOR: {
        Request r;
        r.kind = a.kind;
        r.slot = a.kind == RFM_MOVE_ACT_SETTINGS ? -1 : a.index;
        r.value = a.value;
        if (a.kind == RFM_MOVE_ACT_SETTINGS) {
            if (data && len) {
                r.data.assign(data, data + len);
            } else {
                r.data.resize(RFM_MOVE_SETTINGS_BYTES);
                rfm_move_save(&s_->core.s, r.data.data());
            }
        } else if (a.kind == RFM_MOVE_ACT_PROJECT_SAVE && a.data) {
            r.data.assign(a.data, a.data + a.len);
        }
        std::lock_guard<std::mutex> g(qmu_);
        requests_.push_back(std::move(r));
        return;
    }
    default:                                    // (Sample's audio loop, the metronome click: not yet)
        return;
    }
}

void MoveLink::engineAct(const rfm_move_act_t &a)
{
    if (!target_)
        return;
    rfm_event_t e{};
    switch (a.kind) {
    case RFM_MOVE_ACT_KEY:
        e.type = RFM_EV_KEY, e.index = a.index, e.value = a.down, e.vel = a.down ? a.vel : 0;
        break;
    case RFM_MOVE_ACT_PRESS:
        e.type = RFM_EV_PRESS, e.index = a.index, e.value = a.value;
        break;
    case RFM_MOVE_ACT_BTN:
        e.type = RFM_EV_BUTTON, e.index = a.index, e.value = a.down;
        break;
    case RFM_MOVE_ACT_TURN:
        e.type = RFM_EV_ENC, e.index = a.index, e.value = a.value;
        break;
    case RFM_MOVE_ACT_MASTER:
        e.type = RFM_EV_MASTER, e.value = a.value;
        break;
    case RFM_MOVE_ACT_MIDI:
        if (a.n) {
            target_->moveMidi(a.bytes, a.n);
            seqMidi_.fetch_add(1, std::memory_order_relaxed);
        }
        return;
    default:
        return;
    }
    target_->moveEvent(e);
}

// ------------------------------------------------------------------ the network thread ---

void MoveLink::netMain()
{
    std::vector<uint8_t> buf(16384);
    int fd = -1;
    bool connecting = false;
    std::unique_lock<std::mutex> q(qmu_);
    while (!quit_) {
        std::deque<Out> outs;
        outs.swap(out_);
        const std::string host = host_;
        q.unlock();
        bool failed = false, opened = false;
        for (Out &o : outs) {
            switch (o.kind) {
            case Out::kSend:
                if (fd >= 0 && !connecting && rfm1cs_tcp_write(fd, o.bytes.data(), (int)o.bytes.size()) != 0) {
                    rfm1cs_tcp_close(fd);
                    fd = -1;
                    failed = true;
                }
                break;
            case Out::kOpen: {
                if (fd >= 0)
                    rfm1cs_tcp_close(fd);
                std::string addr = host;        // "address" or "address:port" (port 0: Move Remote's 7720)
                int port = 0;
                if (const size_t colon = addr.rfind(':'); colon != std::string::npos && addr.find(':') == colon &&
                    colon + 1 < addr.size() && addr.find_first_not_of("0123456789", colon + 1) == std::string::npos) {
                    port = std::atoi(addr.c_str() + colon + 1);
                    addr.resize(colon);
                }
                fd = rfm1cs_tcp_connect(addr.c_str(), port);
                connecting = fd >= 0;
                failed = fd < 0;
                break;
            }
            case Out::kClose:
                if (fd >= 0)
                    rfm1cs_tcp_close(fd);
                fd = -1;
                connecting = false;
                failed = false;
                break;
            }
        }
        int n = 0;
        if (fd >= 0 && connecting) {
            const int r = rfm1cs_tcp_wait(fd, 2);
            if (r == 1) {
                connecting = false;
                opened = true;
            } else if (r < 0) {
                rfm1cs_tcp_close(fd);
                fd = -1;
                connecting = false;
                failed = true;
            }
        } else if (fd >= 0) {
            n = rfm1cs_tcp_read(fd, buf.data(), (int)buf.size(), 2);
            if (n < 0) {
                rfm1cs_tcp_close(fd);
                fd = -1;
                failed = true;
                n = 0;
            }
        }
        int32_t next;
        {
            std::lock_guard<std::mutex> g(sm_);
            const uint32_t now = nowMs();
            if (failed)
                rfm1cs_session_closed(s_, now, 0);
            if (opened)
                rfm1cs_session_opened(s_, now);
            if (n > 0)
                rfm1cs_session_rx(s_, now, buf.data(), (uint32_t)n);
            rfm1cs_session_tick(s_, now);
            next = rfm1cs_session_next_ms(s_, now);
            snap();
        }
        q.lock();
        if (fd < 0 && out_.empty() && !quit_) {
            const int32_t w = next < 0 ? 100 : std::min<int32_t>(next, 100);
            if (w > 0)
                cv_.wait_for(q, std::chrono::milliseconds(w), [this] { return quit_ || !out_.empty(); });
        }
    }
    q.unlock();
    if (fd >= 0)
        rfm1cs_tcp_close(fd);
}

// ------------------------------------------------------------------ the core thread ---

void MoveLink::coreTick(uint32_t ms, MoveTarget &t, const uint8_t levels[RFM_MOVE_NLEVELS], uint8_t playGreen,
                        int master, const uint16_t *lcdBE, uint32_t lcdWrites)
{
    target_ = &t;
    lastTickMs_.store(nowMs(), std::memory_order_relaxed);
    const uint32_t dt = started_ ? ms - lastMs_ : 0;
    started_ = true;
    lastMs_ = ms;
    if (dt > 0 && dt < 1000)
        pendingUs_ += dt * 1000u;
    // the keys and pads that came in on the network thread
    std::deque<rfm_move_act_t> acts;
    {
        std::lock_guard<std::mutex> g(qmu_);
        acts.swap(engineQ_);
    }
    for (const rfm_move_act_t &a : acts)
        engineAct(a);
    if (!sm_.try_lock())                        // (never waiting: the next millisecond, with the time kept)
        return;
    inCore_ = true;
    const uint32_t now = nowMs();
    const bool live = rfm1cs_session_status(s_)->state == RFM1CS_CONNECTED;
    if (master != master_) {
        master_ = master;
        rfm_move_set_master(&s_->core, master);
        if (live)
            rfm1cs_session_redraw(s_, now);
    }
    if (live) {
        for (size_t i = 0; i < midiIn_.size(); i += 1 + midiIn_[i])
            rfm1cs_session_midi_in(s_, now, &midiIn_[i + 1], midiIn_[i]);
        if (pendingUs_)
            rfm1cs_session_advance(s_, now, (uint32_t)pendingUs_, 1000000u);
        rfm1cs_session_panel(s_, levels, playGreen);
        // a new FM-1 screen (the session draws it onto the Move's when due); every new connection gets one
        if (rfm1cs_session_status(s_)->connects != lastConnects_) {
            lastConnects_ = rfm1cs_session_status(s_)->connects;
            lastLcdWrites_ = ~0u;
        }
        if (lcdBE && lcdWrites != lastLcdWrites_ && now - lastFrameMs_ >= kFrameMs) {
            lastFrameMs_ = now;
            lastLcdWrites_ = lcdWrites;
            for (size_t i = 0; i < lcd_.size(); i++)
                lcd_[i] = (uint16_t)(lcdBE[i] >> 8 | lcdBE[i] << 8);   // (the FM-1's are big-endian, as sent)
            rfm1cs_session_frame(s_, now, lcd_.data());
        }
    }
    midiIn_.clear();
    pendingUs_ = 0;
    snap();
    inCore_ = false;
    sm_.unlock();
}

void MoveLink::coreMidiOut(const uint8_t *msg, int n)
{
    if (n > 0 && n < 256 && midiIn_.size() + 1 + n <= kMaxMidiIn) {   // (into the session at the next tick)
        midiIn_.push_back((uint8_t)n);
        midiIn_.insert(midiIn_.end(), msg, msg + n);
    }
}

} // namespace rfm
