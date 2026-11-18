// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// MoveLink (MoveLink.h): the Ableton Move on libmoveremote's client, the rfm_move core on the engine's core thread.

#include "MoveLink.h"

#include <chrono>
#include <cstdlib>
#include <cstring>

#include "moveremote/client.h"

namespace rfm {

namespace {
constexpr uint32_t kScreenMs = 33;          // the Move's screen at most ~30 a second (the web's SCREEN_MS)
constexpr uint32_t kLedMs = 5;              // the FM-1's LEDs onto the Move at most every 5 ms (and after input)
constexpr uint64_t kPingUs = 1000000, kSilentUs = 3000000;   // PING a second; nothing for 3 s: lost (STATUS: 500 ms)
constexpr int kConnectMs = 3000;
constexpr int kRetryMs[] = {1000, 2000, 4000};
constexpr size_t kMaxToCore = 4096;         // (inputs while no firmware runs the core: the oldest go)

uint64_t nowUs() { return mr_now_us(); }
} // namespace

MoveLink::MoveLink(const uint8_t *settings, uint32_t n, std::string hostName) : hostName_(std::move(hostName))
{
    m_ = static_cast<rfm_move_t *>(std::calloc(1, sizeof(rfm_move_t)));
    rfm_move_settings_t s;
    if (!settings || rfm_move_load(&s, settings, n) != 0)
        rfm_move_settings_default(&s);
    rfm_move_init(m_, &s, onAct, this);
    lcd_.resize(240 * 240);
    net_ = std::thread([this] { netMain(); });
}

MoveLink::~MoveLink()
{
    {
        std::lock_guard<std::mutex> g(mu_);
        quit_ = true;
        want_ = false;
    }
    cv_.notify_all();
    if (net_.joinable())
        net_.join();
    std::free(m_);
}

// ------------------------------------------------------------------ the app ---

void MoveLink::start(const std::string &host)
{
    {
        std::lock_guard<std::mutex> g(mu_);
        host_ = host;
        want_ = true;
    }
    cv_.notify_all();
}

void MoveLink::stop()
{
    {
        std::lock_guard<std::mutex> g(mu_);
        want_ = false;
    }
    cv_.notify_all();
}

MoveLink::Status MoveLink::status() const
{
    std::lock_guard<std::mutex> g(mu_);
    Status s = st_;
    s.ticking = nowUs() - lastTickUs_.load(std::memory_order_relaxed) < 500000;
    s.seqMidi = seqMidi_.load(std::memory_order_relaxed);
    return s;
}

bool MoveLink::takeRequest(Request &r)
{
    std::lock_guard<std::mutex> g(mu_);
    if (requests_.empty())
        return false;
    r = std::move(requests_.front());
    requests_.pop_front();
    return true;
}

void MoveLink::post(CoreMsg &&m)
{
    std::lock_guard<std::mutex> g(mu_);
    if (toCore_.size() >= kMaxToCore)
        toCore_.pop_front();
    toCore_.push_back(std::move(m));
}

void MoveLink::projectsInit(uint32_t dirBits, int openSlot, const std::vector<uint8_t> &openBlob)
{
    CoreMsg m{CoreMsg::kInit};
    m.bits = dirBits;
    m.slot = openSlot;
    m.blob = openBlob;
    post(std::move(m));
}

void MoveLink::projectDir(uint32_t bits)
{
    CoreMsg m{CoreMsg::kDir};
    m.bits = bits;
    post(std::move(m));
}

void MoveLink::projectInfo(int slot, const std::vector<uint8_t> &blob)
{
    CoreMsg m{CoreMsg::kInfo};
    m.slot = slot;
    m.blob = blob;
    post(std::move(m));
}

void MoveLink::projectAnswer(int slot, const std::vector<uint8_t> &blob)
{
    CoreMsg m{CoreMsg::kLoad};
    m.slot = slot;
    m.blob = blob;
    post(std::move(m));
}

void MoveLink::flushProject() { post(CoreMsg{CoreMsg::kFlush}); }

void MoveLink::setStatus(State s, const std::string &text)
{
    std::lock_guard<std::mutex> g(mu_);
    st_.state = s;
    st_.text = text;
}

// ------------------------------------------------------------------ the network thread ---

void MoveLink::netMain()
{
    std::unique_lock<std::mutex> l(mu_);
    int retries = 0;
    while (!quit_) {
        cv_.wait(l, [this] { return quit_ || want_; });
        if (quit_)
            break;
        const std::string host = host_.empty() ? "move.local" : host_;
        st_.state = kConnecting;
        st_.text = "Connecting to " + host + "...";
        l.unlock();
        mr_callbacks_t cb{};
        cb.user = this;
        cb.on_input = [](void *u, const mr_event_t *ev) {
            auto *self = static_cast<MoveLink *>(u);
            self->lastRxUs_.store(nowUs(), std::memory_order_relaxed);
            CoreMsg m{CoreMsg::kInput};
            m.ev = *ev;
            self->post(std::move(m));
            std::lock_guard<std::mutex> g(self->mu_);
            self->st_.inputs++;
        };
        cb.on_status = [](void *u, const mr_status_t *st) {
            auto *self = static_cast<MoveLink *>(u);
            self->lastRxUs_.store(nowUs(), std::memory_order_relaxed);
            bool changed;
            {
                std::lock_guard<std::mutex> g(self->mu_);
                changed = self->st_.battery != st->battery;
                self->st_.battery = st->battery;
            }
            if (changed) {
                CoreMsg m{CoreMsg::kBattery};
                m.a = st->battery;
                m.b = st->power;
                self->post(std::move(m));
            }
        };
        cb.on_pong = [](void *u, uint32_t, uint64_t, uint32_t) {
            static_cast<MoveLink *>(u)->lastRxUs_.store(nowUs(), std::memory_order_relaxed);
        };
        cb.on_bye = [](void *u, int reason) { static_cast<MoveLink *>(u)->bye_.store(reason ? reason : -1); };
        std::string addr = host;                // "address" or "address:port" (port 0: MR_PORT)
        int port = 0;
        if (const size_t colon = addr.rfind(':'); colon != std::string::npos && addr.find(':') == colon &&
            colon + 1 < addr.size() && addr.find_first_not_of("0123456789", colon + 1) == std::string::npos) {
            port = std::atoi(addr.c_str() + colon + 1);
            addr.resize(colon);
        }
        mr_client_t *c = mr_connect(addr.c_str(), port, hostName_.c_str(), &cb, kConnectMs);
        if (!c) {
            const char *e = mr_last_error();
            const int ms = kRetryMs[retries < 2 ? retries : 2];
            retries++;
            l.lock();
            st_.state = kRetrying;
            st_.text = std::string(e && *e ? e : "no answer") + ". Is Move Remote running on the Move, and is " + host +
                       " its address? Trying again in " + std::to_string(ms / 1000) + " s.";
            cv_.wait_for(l, std::chrono::milliseconds(ms), [this] { return quit_ || !want_; });
            if (!want_ && !quit_) {
                st_.state = kOff;
                st_.text = "Off";
            }
            continue;
        }
        retries = 0;
        session(c);
        mr_close(c);
        post(CoreMsg{CoreMsg::kLost});
        l.lock();
        st_.via = -1;
        if (!want_ && st_.state != kError) {
            st_.state = kOff;
            if (st_.text.empty() || st_.text.rfind("Connected", 0) == 0)
                st_.text = "Off";
        }
    }
}

void MoveLink::session(mr_client_t *c)
{
    bye_.store(0);
    mr_config(c, MR_CFG_AUDIO_CLOCK, 0);        // (no AUDIO messages: the app plays its own sound)
    const mr_hello_t *h = mr_hello(c);
    {
        std::lock_guard<std::mutex> g(mu_);
        st_.state = kConnected;
        st_.name = h && h->name[0] ? h->name : "Move";
        st_.via = h ? h->via : -1;
        st_.text = "Connected to " + st_.name + (st_.via == MR_VIA_USB ? " over USB" : st_.via == MR_VIA_WIFI ? " over Wi-Fi" : "");
        st_.connects++;
        ledsOut_.clear();
        screenDue_ = false;
    }
    post(CoreMsg{CoreMsg::kConnected});
    lastRxUs_.store(nowUs());
    uint64_t lastPing = nowUs();
    uint32_t token = 0;
    std::vector<rfm_move_led_t> leds;
    std::array<uint8_t, MR_SCREEN_BYTES> screen{};
    for (;;) {
        {
            std::lock_guard<std::mutex> g(mu_);
            if (quit_ || !want_)
                return;
        }
        if (mr_poll(c, 2) < 0) {
            setStatus(kRetrying, "Link lost: connecting again...");
            return;
        }
        if (const int bye = bye_.load()) {
            std::lock_guard<std::mutex> g(mu_);
            if (bye == MR_BYE_SHUTDOWN || bye < 0) {
                st_.state = kRetrying;
                st_.text = "The Move shut down: connecting again when it's back...";
            } else {
                want_ = false;
                st_.state = kOff;
                st_.text = bye == MR_BYE_REPLACED ? "Another app took the Move." : "The Move left Move Remote.";
            }
            return;
        }
        bool sendScreen = false;
        {
            std::lock_guard<std::mutex> g(mu_);
            leds.swap(ledsOut_);
            if (screenDue_) {
                screen = screenOut_;
                screenDue_ = false;
                sendScreen = true;
            }
        }
        for (const rfm_move_led_t &d : leds) {
            if (d.rgb)
                mr_led_rgb(c, d.cc, d.number, d.r, d.g, d.b);
            else
                mr_led(c, d.cc, d.number, d.r, 0);
        }
        if (sendScreen)
            mr_display(c, screen.data());
        {
            std::lock_guard<std::mutex> g(mu_);
            st_.leds += (uint32_t)leds.size();
            st_.screens += sendScreen ? 1 : 0;
        }
        leds.clear();
        const uint64_t t = nowUs();
        if (t - lastPing >= kPingUs) {
            lastPing = t;
            mr_ping(c, ++token);
        }
        if (t - lastRxUs_.load(std::memory_order_relaxed) > kSilentUs) {
            setStatus(kRetrying, "The Move stopped answering: connecting again...");
            return;
        }
    }
}

// ------------------------------------------------------------------ the core thread ---

void MoveLink::onAct(void *ctx, const rfm_move_act_t *a) { static_cast<MoveLink *>(ctx)->act(*a); }

void MoveLink::act(const rfm_move_act_t &a)
{
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
        if (target_ && a.n) {
            target_->moveMidi(a.bytes, a.n);
            seqMidi_.fetch_add(1, std::memory_order_relaxed);
        }
        return;
    case RFM_MOVE_ACT_SETTINGS: {
        Request r;
        r.kind = a.kind;
        r.data.resize(RFM_MOVE_SETTINGS_BYTES);
        rfm_move_save(&m_->s, r.data.data());
        request(std::move(r));
        return;
    }
    case RFM_MOVE_ACT_PROJECT_SAVE:
    case RFM_MOVE_ACT_PROJECT_LOAD:
    case RFM_MOVE_ACT_PROJECT_DELETE:
    case RFM_MOVE_ACT_PROJECT_CUT:
    case RFM_MOVE_ACT_PROJECT_COPY:
    case RFM_MOVE_ACT_PROJECT_PASTE:
    case RFM_MOVE_ACT_PROJECT_COLOR: {
        Request r;
        r.kind = a.kind;
        r.slot = a.index;
        r.value = a.value;
        if (a.kind == RFM_MOVE_ACT_PROJECT_SAVE && a.data)
            r.data.assign(a.data, a.data + a.len);
        request(std::move(r));
        return;
    }
    default:                                    // (Sample's audio loop, the metronome: not yet)
        return;
    }
    if (target_)
        target_->moveEvent(e);
}

void MoveLink::request(Request &&r) { reqPending_.push_back(std::move(r)); }

void MoveLink::coreMsg(CoreMsg &m, uint32_t ms)
{
    switch (m.kind) {
    case CoreMsg::kInput:
        if (live_) {
            rfm_move_input(m_, &m.ev, ms);
            screenDirty_ = true;
        }
        break;
    case CoreMsg::kConnected:
        live_ = true;
        lastMs_ = ms;
        rfm_move_leds_invalidate(m_);
        screenSent_.fill(0xA5);                 // (the first screen goes out whatever it is)
        screenDirty_ = true;
        lastLedMs_ = ms - kLedMs;
        break;
    case CoreMsg::kLost:
        if (live_) {
            rfm_move_release_all(m_);           // (every key, button and note let go; the sequencer stops)
            rfm_move_project_flush(m_);
        }
        live_ = false;
        break;
    case CoreMsg::kBattery:
        if (rfm_move_set_battery(m_, m.a, m.b))
            screenDirty_ = true;
        break;
    case CoreMsg::kInit:
        rfm_move_project_dir(m_, m.bits);
        if (rfm_move_project_load(m_, m.slot, m.blob.empty() ? nullptr : m.blob.data(), (uint32_t)m.blob.size()) < 0)
            rfm_move_project_load(m_, m.slot, nullptr, 0);   // (unreadable: it starts empty; the stored copy stays)
        screenDirty_ = true;
        break;
    case CoreMsg::kDir:
        rfm_move_project_dir(m_, m.bits);
        screenDirty_ = true;
        break;
    case CoreMsg::kInfo:
        rfm_move_project_info(m_, m.slot, m.blob.empty() ? nullptr : m.blob.data(), (uint32_t)m.blob.size());
        screenDirty_ = true;
        break;
    case CoreMsg::kLoad:
        if (rfm_move_project_load(m_, m.slot, m.blob.empty() ? nullptr : m.blob.data(), (uint32_t)m.blob.size()) < 0)
            rfm_move_project_load(m_, m.slot, nullptr, 0);
        screenDirty_ = true;
        break;
    case CoreMsg::kFlush:
        rfm_move_project_flush(m_);
        break;
    }
}

void MoveLink::coreTick(uint32_t ms, MoveTarget &t, const uint8_t levels[RFM_MOVE_NLEVELS], uint8_t playGreen,
                        int master, const uint16_t *lcdBE, uint32_t lcdWrites)
{
    target_ = &t;
    lastTickUs_.store(nowUs(), std::memory_order_relaxed);
    // what came in (never waiting: the lock busy, it waits for the next millisecond)
    if (mu_.try_lock()) {
        work_.insert(work_.end(), std::make_move_iterator(toCore_.begin()), std::make_move_iterator(toCore_.end()));
        toCore_.clear();
        if (!ledsPending_.empty()) {
            ledsOut_.insert(ledsOut_.end(), ledsPending_.begin(), ledsPending_.end());
            ledsPending_.clear();
        }
        if (screenPending_) {
            screenOut_ = screen_;
            screenDue_ = true;
            screenPending_ = false;
        }
        while (!reqPending_.empty()) {
            requests_.push_back(std::move(reqPending_.front()));
            reqPending_.pop_front();
        }
        st_.mode = m_->s.mode;
        st_.project = rfm_move_project_slot(m_);
        st_.playing = m_->seq.playing != 0;
        mu_.unlock();
    }
    const bool hadInput = !work_.empty();
    rfm_move_set_master(m_, master);
    for (CoreMsg &m : work_)
        coreMsg(m, ms);
    work_.clear();
    if (!live_)
        return;
    // the sequencer and the popups' timers, by the device clock (us)
    const uint32_t dt = ms - lastMs_;
    lastMs_ = ms;
    if (dt > 0 && dt < 1000)
        rfm_move_seq_advance(m_, dt * 1000u, 1000000u);
    // the FM-1's LEDs onto the Move
    if (hadInput || ms - lastLedMs_ >= kLedMs) {
        lastLedMs_ = ms;
        rfm_move_panel(m_, levels, playGreen);
        rfm_move_led_t buf[RFM_MOVE_NLEDS];
        const int n = rfm_move_leds(m_, buf, RFM_MOVE_NLEDS);
        if (n > 0)
            ledsPending_.insert(ledsPending_.end(), buf, buf + n);
    }
    // the screen: after input, a new FM-1 frame, or while it moves with the clock; only when it changed
    if (ms - lastScreenMs_ >= kScreenMs &&
        (screenDirty_ || hadInput || lcdWrites != lastLcdWrites_ || rfm_move_screen_timed(m_))) {
        lastScreenMs_ = ms;
        screenDirty_ = false;
        const uint16_t *px = nullptr;
        if (lcdBE && lcdWrites != lastLcdWrites_) {
            for (size_t i = 0; i < lcd_.size(); i++)
                lcd_[i] = (uint16_t)(lcdBE[i] >> 8 | lcdBE[i] << 8);   // (the FM-1's are big-endian, as sent)
            px = lcd_.data();
        }
        lastLcdWrites_ = lcdWrites;
        rfm_move_screen(m_, px, screen_.data());
        if (screen_ != screenSent_) {
            screenSent_ = screen_;
            screenPending_ = true;
        }
    }
}

void MoveLink::coreMidiOut(const uint8_t *msg, int n)
{
    if (live_ && n > 0)
        rfm_move_seq_midi_in(m_, msg, n);
}

} // namespace rfm
