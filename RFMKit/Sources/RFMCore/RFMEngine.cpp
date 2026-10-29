// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The core engine (include/RFMEngine.h). Adapted from RemoteFM1 v0.2.2's host/tools/fm1remote/engine.cpp (Engine:
// the between hook, the publish at most every frame period and only on change, the flash copy every 30 device s and
// final_flash, the timer clock). Changed: ABI 6's fm1panel_t instead of emu_hal_t, with FM1VST v0.6.2's
// plugin/Processor.cpp mapping (applyRemote: buttons by label, encoders by role with enc_dir undone, velocity 100 for
// the unit's keys; remoteLeds: each LED in the plane of its fm1p_led_class, PLAY green); slots instead of
// CoreLoader's copies; the clock owned by one of audio / timer / caller at a time (rfme_set_clock); the preview
// for the app; flash on request; the core's stats() and the render's own time. M4: host MIDI in (FM1VST's handleMidi,
// pushKeys, forwardMidi and toUsbPackets) and the core's MIDI out kept for the AU's MIDI output.
#include "RFMEngine.h"

#include <mach/mach_time.h>

#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "RFMCoreBackend.h"
#include "RFMDevice.h"
#include "RFMInternal.h"
#include "RemoteLink.h"

static_assert(RFME_B_OCTUP == FM1P_B_OCTUP && RFME_B_SAVE == FM1P_B_SAVE && RFME_E_K4 == FM1P_E_K4, "labels");
static_assert(RFMC_EV_KEY == RFM_EV_KEY && RFMC_EV_BUTTON == RFM_EV_BUTTON && RFMC_EV_ENC == RFM_EV_ENC &&
                  RFMC_EV_MASTER == RFM_EV_MASTER && RFMC_EV_RELEASE == RemoteLink::kEvRelease,
              "event types");
static_assert(sizeof(RemoteSnapshot::lcd) == sizeof(fm1panel_t::lcd), "the LCD layouts differ");

namespace {

constexpr uint32_t kPeriodMs = RemoteLink::kPeriodMs;   // the LCD and LEDs at most every 50 device ms (20 fps)
constexpr uint32_t kPreviewMs = 33;                      // the app's preview at most every 33 device ms (30 fps)
constexpr uint32_t kPanelMs = 8;                         // the on-screen panel's state at most every 8 device ms
constexpr int kNIds = FM1P_NBTN + FM1P_NKEY;             // keymap ids: 0..13 matrix buttons, 14.. note keys
constexpr uint32_t kFlashEveryMs = 30000;
constexpr uint32_t kStatsEveryMs = 500;
constexpr int kRemoteVel = 100;                          // RemoteFM1 sends no velocity (Processor.cpp kRemoteVel)
constexpr int kNoteBase = 53;                            // the MIDI note of key 0 (F3), Processor.h kNoteBase
constexpr uint32_t kInRing = 512;                        // host MIDI packets waiting for the core's midi_in

// one MIDI message -> USB-MIDI event packets (cable 0): FM1VST's toUsbPackets (plugin/EditorPort.h), channel and system
// messages only (the host's SysEx is not passed in)
template <typename Put> void toUsbPackets(const uint8_t *d, uint32_t n, Put &&put)
{
    auto pkt = [](uint32_t cin, uint32_t a, uint32_t b, uint32_t c) { return (cin & 15u) | a << 8 | b << 16 | c << 24; };
    if (n == 0)
        return;
    const uint8_t st = d[0];
    if (st >= 0xF8) {
        put(pkt(0xF, st, 0, 0));
    } else if (st >= 0xF0) {
        if (st == 0xF1 || st == 0xF3)
            put(pkt(2, st, n > 1 ? d[1] : 0u, 0));
        else if (st == 0xF2)
            put(pkt(3, st, n > 1 ? d[1] : 0u, n > 2 ? d[2] : 0u));
        else if (st == 0xF6)
            put(pkt(5, st, 0, 0));
    } else if (st >= 0x80) {
        put(pkt(st >> 4, st, n > 1 ? d[1] : 0u, n > 2 ? d[2] : 0u));
    }
}

struct Preview {
    uint16_t lcd[FM1P_LCD_W * FM1P_LCD_H];
    rfm_leds_t leds;
    uint32_t seq = 0, devMs = 0;
};

double ticksToUs()
{
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (double)tb.numer / (double)tb.denom / 1000.0;
}

// The panel's LED levels as RemoteFM1's LEDS planes (Processor.cpp remoteLeds)
void remoteLeds(const fm1panel_t *h, rfm_leds_t &l)
{
    std::memset(&l, 0, sizeof l);
    for (int c = 0; c < (int)RFM_NCOL && c < FM1P_NCOL; c++)
        for (int r = 0; r < FM1P_NLINE; r++) {
            const uint8_t bit = (uint8_t)(1u << (r + 1));
            switch (fm1p_led_class(h->led[c][r])) {
            case FM1P_LC_LIT: l.lit[c] |= bit; break;
            case FM1P_LC_MID: l.mid[c] |= bit; break;
            case FM1P_LC_DIM: l.dim[c] |= bit; break;
            case FM1P_LC_FAINT: l.faint[c] |= bit; break;
            default: break;
            }
        }
    l.flags = fm1p_led_class(h->led_play_green) == FM1P_LC_LIT ? RFM_LEDS_F_PLAY_GREEN : 0;
}

void putErr(char *err, uint32_t n, const std::string &s)
{
    if (err && n) {
        std::strncpy(err, s.c_str(), n - 1);
        err[n - 1] = 0;
    }
}

} // namespace

struct rfme {
    rfmc_t *owner = nullptr;            // the link's handle (NULL: headless)
    RemoteLink *link = nullptr;

    // the core (the control thread changes these only with the clock stopped)
    rfm::CoreFactory factory;               // makes the backend (the load's; a power cycle makes a new one with it)
    std::unique_ptr<rfm::CoreBackend> core; // the firmware (a native slot; later a Wasm module)
    std::unique_ptr<rfm::CoreDevice> dev;   // its clock
    uint32_t stallUs = 0;                   // (tests) rfme_test_frame_stall
    uint8_t btnId[FM1P_NB] = {}, encId[FM1P_NE - 1] = {};   // the panel's label / role maps, as init left them
    bool booted = false;
    std::vector<uint8_t> flashCopy;     // the clock's copy, handed over by flashReady

    // the clock: exactly one owner runs it; inClock counts threads inside a clock entry
    std::atomic<int> clock{RFME_CLOCK_NONE};
    std::atomic<int> inClock{0};
    std::atomic<bool> attached{false};

    // the clock thread's own
    uint32_t noteKeys = 0, labels = 0, matrixButtons = 0;
    // host MIDI (the clock's own; FM1VST's midiKeys_, midiVel_, noteKey_, keyCount_, appliedKeys_, inRing_)
    uint32_t midiKeys = 0, appliedKeys = 0;
    uint8_t midiVel[FM1P_NKEY] = {};
    uint8_t keyCount[FM1P_NKEY] = {};
    int8_t noteKey[16][128];
    uint32_t inRing[kInRing] = {};
    uint32_t inR = 0, inW = 0;
    std::atomic<int> notesPlayKeys{1}, transpose{0}, keyNotesToFw{0};
    std::atomic<bool> midiOutOn{false};
    rfm::Spsc<uint32_t, 2048> midiOutQ;                  // the clock -> the render thread (the AU's MIDI output)
    std::atomic<uint32_t> midiInCount{0}, midiNotes{0}, midiInDropped{0};
    int32_t masterV = -1;
    uint32_t lastPub = 0, lastWrites = 0, linkPubs = 0, pubSeq = 0;
    uint32_t lastLinkPub = 0, lastLinkWrites = 0;
    rfm_leds_t lastLeds{}, lastLinkLeds{};
    // the on-screen panel's state (the clock's own, then published): each keymap id's LED (column, line), -1 none
    int8_t ledCol[kNIds], ledLine[kNIds];
    rfme_panel_t panelLast{};
    uint32_t lastPanel = 0;
    rfm::Triple<rfme_panel_t> panelOut;
    uint32_t panelSeen = 0;                 // (the reader's)
    bool pubValid = false, linkValid = false;
    uint32_t lastFlashCheck = 0, savedDirty = 0, lastStats = 0;
    rfm::Spsc<rfm_event_t, 1024> in;    // rfme_event -> the clock
    rfm::Triple<Preview> preview;       // the clock -> rfme_preview

    // read by anyone
    std::atomic<bool> halted{false}, flashReady{false}, flashReq{false};
    std::atomic<uint32_t> haltCode{0}, devMs{0}, lcdWrites{0}, snapshots{0}, applied{0}, dropped{0}, keysPressed{0};
    std::atomic<uint32_t> midiOut{0}, shed{0}, cpuPct{0}, haveStats{0}, flashCopies{0}, flashDirty{0};
    std::atomic<uint64_t> renders{0}, renderFrames{0}, renderTicks{0};
    std::atomic<uint32_t> renderLastUs{0}, renderMaxUs{0}, renderLastFrames{0};
    std::atomic<double> rate{0};
    double usPerTick = ticksToUs();

    // the timer clock
    std::thread timer;
    std::mutex tmu;
    std::condition_variable tcv;
    bool timerQuit = false;
    std::atomic<bool> timerRebase{true};

    // the main thread's view of the preview
    uint32_t viewSeq = 0;

    // ---- the clock's guard
    struct Scope {
        rfme *e;
        bool ok;
        Scope(rfme *x, int who) : e(x)
        {
            e->inClock.fetch_add(1, std::memory_order_seq_cst);
            ok = e->clock.load(std::memory_order_seq_cst) == who && e->dev && e->booted;
        }
        ~Scope() { e->inClock.fetch_sub(1, std::memory_order_seq_cst); }
    };

    // the control thread: the clock stopped (the old owner out of it); returns the old owner
    int stop()
    {
        const int prev = clock.exchange(RFME_CLOCK_NONE, std::memory_order_seq_cst);
        while (inClock.load(std::memory_order_seq_cst) != 0)
            std::this_thread::yield();
        return prev;
    }
    void resume(int who)
    {
        if (who == RFME_CLOCK_TIMER) {
            timerRebase.store(true);
            startTimer();
        }
        clock.store(who, std::memory_order_seq_cst);
        if (who == RFME_CLOCK_TIMER)
            tcv.notify_all();
    }

    rfme()
    {
        std::memset(noteKey, -1, sizeof noteKey);
        std::memset(ledCol, -1, sizeof ledCol);
        std::memset(ledLine, -1, sizeof ledLine);
    }

    // each keymap id's LED: (column, line) where the keymap has it on rows 1..4 (Device::led_level, precomputed)
    void mapLeds(const int8_t *keymap)
    {
        std::memset(ledCol, -1, sizeof ledCol);
        std::memset(ledLine, -1, sizeof ledLine);
        if (!keymap)
            return;
        for (int r = 1; r <= FM1P_NLINE; r++)
            for (int c = 0; c < FM1P_NCOL; c++) {
                const int id = keymap[r * FM1P_NCOL + c];
                if (id >= 0 && id < kNIds && ledCol[id] < 0) {
                    ledCol[id] = (int8_t)c;
                    ledLine[id] = (int8_t)(r - 1);
                }
            }
    }

    // the keys held by the unit and by host notes, to the device; a key newly down gets its velocity first
    // (Processor.cpp pushKeys)
    void pushKeys()
    {
        const uint32_t m = noteKeys | midiKeys;
        if (m == appliedKeys)
            return;
        const uint32_t down = m & ~appliedKeys;
        for (int k = 0; k < FM1P_NKEY; k++)
            if ((down >> k) & 1u)
                dev->key_vel(k, (midiKeys >> k) & 1u ? midiVel[k] : (noteKeys >> k) & 1u ? kRemoteVel : 0);
        dev->keys(m);
        appliedKeys = m;
    }

    void resetMidi()
    {
        midiKeys = appliedKeys = 0;
        std::memset(noteKey, -1, sizeof noteKey);
        std::memset(keyCount, 0, sizeof keyCount);
        inR = inW = 0;
    }

    void flushMidiIn()
    {
        while (inR != inW && dev->midi_in(inRing[inR % kInRing]))
            inR++;                                       // (0: no room in the core: retried after the next render)
    }

    // one host MIDI message (Processor.cpp handleMidi + forwardMidi)
    void hostMidi(const uint8_t *d, uint32_t n)
    {
        if (n == 0 || !(d[0] & 0x80))
            return;
        midiInCount.fetch_add(1, std::memory_order_relaxed);
        bool keyNote = false;
        if (notesPlayKeys.load(std::memory_order_relaxed) && d[0] < 0xF0) {
            const uint8_t st = d[0] & 0xF0, ch = d[0] & 0x0F;
            const uint8_t note = n > 1 ? (d[1] & 0x7F) : 0, vel = n > 2 ? (d[2] & 0x7F) : 0;
            if (st == 0x90 && n >= 3 && vel > 0) {
                const int key = (int)note - kNoteBase + 12 * transpose.load(std::memory_order_relaxed);
                if (noteKey[ch][note] < 0 && key >= 0 && key < FM1P_NKEY) {
                    noteKey[ch][note] = (int8_t)key;
                    midiVel[key] = vel;
                    keyCount[key]++;
                    midiKeys |= 1u << key;
                    keyNote = true;
                    midiNotes.fetch_add(1, std::memory_order_relaxed);
                }
            } else if ((st == 0x80 && n >= 2) || (st == 0x90 && n >= 3)) {
                const int key = noteKey[ch][note];
                if (key >= 0) {
                    noteKey[ch][note] = -1;
                    if (keyCount[key] && --keyCount[key] == 0)
                        midiKeys &= ~(1u << key);
                    keyNote = true;
                }
            } else if (st == 0xB0 && n >= 3 && (d[1] == 123 || d[1] == 120)) {   // all notes off, all sound off
                for (int k = 0; k < 128; k++) {
                    const int key = noteKey[ch][k];
                    if (key >= 0) {
                        noteKey[ch][k] = -1;
                        if (keyCount[key] && --keyCount[key] == 0)
                            midiKeys &= ~(1u << key);
                    }
                }
            }
            pushKeys();
        }
        if (!keyNote || keyNotesToFw.load(std::memory_order_relaxed)) {
            toUsbPackets(d, n, [this](uint32_t p) {
                if (inW - inR < kInRing)
                    inRing[inW++ % kInRing] = p;
                else
                    midiInDropped.fetch_add(1, std::memory_order_relaxed);
            });
            flushMidiIn();
        }
    }

    // ---- the between hook (the clock thread)
    void apply(const rfm_event_t &e)
    {
        fm1panel_t *h = dev->panel();
        switch (e.type) {
        case RFM_EV_KEY:
            if (e.index < FM1P_NKEY) {
                const uint32_t bit = 1u << e.index;
                if (e.value) {
                    if (!(noteKeys & bit))
                        keysPressed.fetch_add(1, std::memory_order_relaxed);
                    noteKeys |= bit;
                } else {
                    noteKeys &= ~bit;
                }
                pushKeys();                                  // (its velocity first; a key newly down also taps)
            }
            break;
        case RFM_EV_BUTTON:
            if (e.index < FM1P_NBTN) {
                matrixButtons = e.value ? matrixButtons | 1u << e.index : matrixButtons & ~(1u << e.index);
                int label = -1;                              // matrix id -> label (panel->btn_id)
                for (int l = 0; l < FM1P_NB && label < 0; l++)
                    if (h->btn_id[l] == e.index)
                        label = l;
                if (label >= 0) {
                    labels = e.value ? labels | 1u << label : labels & ~(1u << label);
                    dev->buttons(labels);
                }
            }
            break;
        case RFM_EV_ENC:
            if (e.index < FM1P_NENC && e.value) {
                int role = -1;                               // matrix encoder -> knob role (panel->enc_id)
                for (int r = 0; r < FM1P_NE - 1 && role < 0; r++)
                    if (h->enc_id[r] == e.index)
                        role = r;
                if (role >= 0)                               // (Device::enc multiplies by enc_dir: undone)
                    dev->enc(role, e.value * (h->enc_dir[role] < 0 ? -1 : 1));
                else
                    h->enc[e.index] += e.value;
            }
            break;
        case RFM_EV_MASTER:
            masterV = e.value < 0 ? 0 : e.value > 1023 ? 1023 : e.value;
            dev->master(masterV);
            break;
        case RemoteLink::kEvRelease:                         // the session ended: nothing is held any more
            noteKeys = labels = matrixButtons = 0;
            pushKeys();                                      // (the host's notes stay down)
            dev->buttons(0);
            break;
        default:
            return;
        }
        applied.fetch_add(1, std::memory_order_relaxed);
        if (owner && attached.load(std::memory_order_relaxed)) {
            rfmc_external_event(owner, e);
            rfmc_external_panel(owner, noteKeys, matrixButtons, masterV);
        }
    }

    // the LCD and LEDs: to the FM-1 (at most every kPeriodMs, whole on request) and to the preview (at most every
    // kPreviewMs), each only when they changed
    void publish(uint32_t ms)
    {
        const fm1panel_t *h = dev->panel();
        const bool engaged = link && attached.load(std::memory_order_relaxed) && link->engaged();
        if (!engaged)
            linkValid = false;
        const bool linkFull = engaged && (link->takeFullRequest() || !linkValid);
        const bool linkDue = engaged && (linkFull || ms - lastLinkPub >= kPeriodMs);
        const bool viewDue = !pubValid || ms - lastPub >= kPreviewMs;
        if (!linkDue && !viewDue)
            return;
        rfm_leds_t l;
        remoteLeds(h, l);
        const uint32_t writes = h->lcd_writes;
        if (linkDue && (linkFull || writes != lastLinkWrites || !rfm_leds_equal(&l, &lastLinkLeds))) {
            RemoteSnapshot &s = link->back();
            std::memcpy(s.lcd, h->lcd, sizeof s.lcd);
            s.leds = l;
            s.seq = ++linkPubs;
            link->publish();
            linkValid = true;
            lastLinkPub = ms;
            lastLinkWrites = writes;
            lastLinkLeds = l;
        }
        if (viewDue && (!pubValid || writes != lastWrites || !rfm_leds_equal(&l, &lastLeds))) {
            Preview &p = preview.back();
            std::memcpy(p.lcd, h->lcd, sizeof p.lcd);
            p.leds = l;
            p.seq = ++pubSeq;
            p.devMs = ms;
            preview.publish();
            lastPub = ms;
            lastWrites = writes;
            lastLeds = l;
            pubValid = true;
            snapshots.fetch_add(1, std::memory_order_relaxed);
            lcdWrites.store(writes, std::memory_order_relaxed);
        }
    }

    // the on-screen panel's state, when it changed (rfme_panel)
    void publishPanel(uint32_t ms)
    {
        if (ms - lastPanel < kPanelMs && panelLast.seq != 0)
            return;
        lastPanel = ms;
        const fm1panel_t *h = dev->panel();
        rfme_panel_t p{};
        p.booted = 1;
        p.keys = appliedKeys;
        p.labels = labels;
        for (int r = 0; r < FM1P_NE - 1; r++)
            p.enc[r] = dev->enc_total(r) * (h->enc_dir[r] < 0 ? -1 : 1);   // (enc_total counts in enc_dir's sense)
        p.master = h->master;
        auto level = [&](int id) -> uint8_t {
            return id >= 0 && id < kNIds && ledCol[id] >= 0 ? h->led[ledCol[id]][ledLine[id]] : 0;
        };
        for (int k = 0; k < FM1P_NKEY; k++)
            p.key_led[k] = level(FM1P_NBTN + k);
        for (int b = 0; b < FM1P_NB; b++)
            p.btn_led[b] = level(h->btn_id[b]);
        p.play_green = h->led_play_green;
        p.seq = panelLast.seq;
        if (panelLast.seq != 0 && std::memcmp(&p, &panelLast, sizeof p) == 0)
            return;
        p.seq = panelLast.seq + 1;
        panelLast = p;
        panelOut.back() = p;
        panelOut.publish();
    }

    void between(uint32_t ms, bool)
    {
        rfm_event_t ev;
        if (link && attached.load(std::memory_order_relaxed))
            while (link->popEvent(ev))
                apply(ev);
        while (in.pop(ev))
            apply(ev);
        devMs.store(ms, std::memory_order_relaxed);
        const bool keep = midiOutOn.load(std::memory_order_relaxed);
        for (uint32_t pkt; dev->midi_out_take(&pkt);) {    // (M4: for the AU's MIDI output; else counted, dropped)
            midiOut.fetch_add(1, std::memory_order_relaxed);
            if (keep)
                (void)midiOutQ.push(pkt);
        }
        if (!halted.load(std::memory_order_relaxed) && dev->halted()) {
            haltCode.store((uint32_t)dev->core().halted(), std::memory_order_relaxed);
            halted.store(true, std::memory_order_release);
        }
        if (ms - lastStats >= kStatsEveryMs) {
            lastStats = ms;
            uint32_t s = 0, c = 0;
            if (dev->core().stats(&s, &c)) {
                shed.store(s, std::memory_order_relaxed);
                cpuPct.store(c, std::memory_order_relaxed);
                haveStats.store(1, std::memory_order_relaxed);
            }
            flashDirty.store(dev->flash_dirty(), std::memory_order_relaxed);
        }
        publish(ms);
        publishPanel(ms);
        // the flash (fm1remote: every 30 device s when flash_dirty moved; here also when asked, flash_sync first)
        if (!flashCopy.empty() && dev->flash() && !flashReady.load(std::memory_order_acquire)) {
            if (flashReq.load(std::memory_order_acquire)) {
                flashReq.store(false, std::memory_order_relaxed);
                dev->flash_sync();
                copyFlash();
            } else if (ms - lastFlashCheck >= kFlashEveryMs) {
                lastFlashCheck = ms;
                if (dev->flash_dirty() != savedDirty)
                    copyFlash();
            }
        }
    }

    void copyFlash()
    {
        std::memcpy(flashCopy.data(), dev->flash(), flashCopy.size());
        savedDirty = dev->flash_dirty();
        flashCopies.fetch_add(1, std::memory_order_relaxed);
        flashReady.store(true, std::memory_order_release);
    }

    // ---- the timer clock (no audio: the device runs by the wall clock, its sound dropped)
    void startTimer()
    {
        if (timer.joinable())
            return;
        timer = std::thread([this] {
            using clk = std::chrono::steady_clock;
            clk::time_point t0 = clk::now();
            uint32_t ms0 = 0;
            for (;;) {
                {
                    std::unique_lock<std::mutex> l(tmu);
                    if (timerQuit)
                        return;
                    if (clock.load() != RFME_CLOCK_TIMER)
                        tcv.wait_for(l, std::chrono::milliseconds(50));
                }
                {
                    Scope cs(this, RFME_CLOCK_TIMER);
                    if (cs.ok) {
                        if (timerRebase.exchange(false)) {
                            t0 = clk::now();
                            ms0 = dev->ms();
                        }
                        const uint32_t target =
                            ms0 + (uint32_t)std::chrono::duration_cast<std::chrono::milliseconds>(clk::now() - t0).count();
                        for (int k = 0; k < 200 && (int32_t)(target - dev->ms()) > 0; k++)
                            dev->run_ms();
                        if ((int32_t)(target - dev->ms()) > 200)    // (far behind: start counting again from here)
                            timerRebase.store(true);
                        dev->discard();
                    }
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
        });
    }

    // ---- the control thread, the clock stopped
    void unloadStopped()
    {
        dev.reset();
        booted = false;
        halted.store(false);
        haltCode.store(0);
        core.reset();                                   // (shutdown(); a native slot: dlclose, given back)
    }

    // a new backend from the factory, and its device; false with a message
    bool makeStopped(std::string *msg)
    {
        core = factory ? factory(msg) : nullptr;
        if (!core)
            return false;
        if (stallUs)
            core = rfm::stallingCore(std::move(core), stallUs);
        dev = std::make_unique<rfm::CoreDevice>(*core);
        return true;
    }

    void bootStopped(const uint8_t *bytes, uint32_t n)
    {
        dev->boot_from(bytes && n ? bytes : nullptr, bytes ? n : 0);
        noteKeys = labels = matrixButtons = 0;
        resetMidi();
        masterV = -1;
        pubValid = linkValid = false;
        lastPub = lastLinkPub = lastFlashCheck = lastStats = 0;
        lastPanel = 0;
        panelLast.booted = 0;                            // (differs from the first state: published again)
        const rfm::CoreDesc &d = core->info();
        mapLeds(d.has_keymap ? d.keymap.data() : nullptr);
        const fm1panel_t *h = dev->panel();
        std::memcpy(btnId, h->btn_id, sizeof btnId);
        std::memcpy(encId, h->enc_id, sizeof encId);
        flashCopy.assign(dev->flash_size(), 0);
        savedDirty = dev->flash_dirty();
        halted.store(false);
        haltCode.store(0);
        dev->set_between([this](uint32_t ms, bool frame) { between(ms, frame); });
        booted = true;
        if (link)
            link->invalidateScreen();                   // (a new device: the unit's screen resent whole)
    }
};

extern "C" {

rfme_t *rfme_new(rfmc_t *link)
{
    auto *e = new rfme;
    e->owner = link;
    e->link = link ? rfmc_link(link) : nullptr;
    return e;
}

void rfme_free(rfme_t *e)
{
    if (!e)
        return;
    e->stop();
    if (e->attached.exchange(false) && e->owner)
        rfmc_set_external(e->owner, 0);
    {
        std::lock_guard<std::mutex> l(e->tmu);
        e->timerQuit = true;
    }
    e->tcv.notify_all();
    if (e->timer.joinable())
        e->timer.join();
    e->unloadStopped();
    delete e;
}

int rfme_load(rfme_t *e, const char *core_id, char *err, uint32_t n)
{
    const int prev = e->stop();
    e->unloadStopped();
    std::string msg;
    e->factory = rfm::nativeCoreFactory(core_id ? core_id : "");
    if (!e->makeStopped(&msg)) {
        e->factory = nullptr;
        putErr(err, n, msg);
        e->resume(prev);
        return 0;
    }
    e->resume(prev);
    return 1;
}

int rfme_boot(rfme_t *e, const uint8_t *flash, uint32_t n)
{
    if (!e->dev || e->booted)
        return 0;
    const int prev = e->stop();
    e->bootStopped(flash, n);
    e->resume(prev);
    return 1;
}

void rfme_unload(rfme_t *e)
{
    const int prev = e->stop();
    e->unloadStopped();
    e->resume(prev);
}

int rfme_power_cycle(rfme_t *e, char *err, uint32_t n)
{
    if (!e->core || !e->factory) {
        putErr(err, n, "no core loaded");
        return 0;
    }
    const int prev = e->stop();
    std::vector<uint8_t> image;
    if (e->booted && e->dev->flash()) {             // (FM1VST powerCycleLocked: the current flash, synced)
        e->dev->flash_sync();
        image.assign(e->dev->flash(), e->dev->flash() + e->dev->flash_size());
    }
    e->unloadStopped();
    std::string msg;
    if (!e->makeStopped(&msg)) {
        putErr(err, n, msg);
        e->resume(prev);
        return 0;
    }
    e->bootStopped(image.empty() ? nullptr : image.data(), (uint32_t)image.size());
    if (!image.empty() && image.size() == e->flashCopy.size()) {   // (offered for saving)
        std::memcpy(e->flashCopy.data(), image.data(), image.size());
        e->flashReady.store(true, std::memory_order_release);
    }
    e->resume(prev);
    return 1;
}

void rfme_attach(rfme_t *e, int on)
{
    const int prev = e->stop();
    if (e->attached.exchange(on != 0) != (on != 0) && e->owner) {
        if (!on && e->booted) {                         // (what the unit held lets go; the host's notes stay)
            e->noteKeys = e->labels = e->matrixButtons = 0;
            e->pushKeys();
            e->dev->buttons(0);
        }
        e->linkValid = false;
        rfmc_set_external(e->owner, on);
    }
    e->resume(prev);
}

void rfme_set_clock(rfme_t *e, int owner)
{
    e->stop();
    e->resume(owner);
}

int rfme_clock(rfme_t *e) { return e->clock.load(); }

void rfme_render(rfme_t *e, float *L, float *R, uint32_t n, double rate) { rfme_render_midi(e, L, R, n, rate, nullptr, 0); }

int rfme_render_midi(rfme_t *e, float *L, float *R, uint32_t n, double rate, const rfme_midi_t *ev, uint32_t nev)
{
    const uint64_t t0 = mach_absolute_time();
    int ok;
    {
        rfme::Scope cs(e, RFME_CLOCK_AUDIO);
        ok = cs.ok;
        if (cs.ok) {
            uint32_t pos = 0;                           // (FM1VST renderBlock: the device runs up to each event)
            for (uint32_t i = 0; i < nev; i++) {
                const uint32_t at = ev[i].offset < n ? ev[i].offset : n;
                if (at > pos) {
                    e->dev->render(L + pos, R ? R + pos : nullptr, at - pos, rate);
                    pos = at;
                }
                e->hostMidi(ev[i].data, ev[i].len > 3 ? 3u : ev[i].len);
            }
            if (pos < n)
                e->dev->render(L + pos, R ? R + pos : nullptr, n - pos, rate);
            e->flushMidiIn();
        } else {
            std::memset(L, 0, n * sizeof *L);
            if (R && R != L)
                std::memset(R, 0, n * sizeof *R);
        }
    }
    const uint64_t dt = mach_absolute_time() - t0;
    const uint32_t us = (uint32_t)((double)dt * e->usPerTick);
    e->renders.fetch_add(1, std::memory_order_relaxed);
    e->renderFrames.fetch_add(n, std::memory_order_relaxed);
    e->renderTicks.fetch_add(dt, std::memory_order_relaxed);
    e->renderLastUs.store(us, std::memory_order_relaxed);
    e->renderLastFrames.store(n, std::memory_order_relaxed);
    if (us > e->renderMaxUs.load(std::memory_order_relaxed))
        e->renderMaxUs.store(us, std::memory_order_relaxed);
    e->rate.store(rate, std::memory_order_relaxed);
    return ok;
}

void rfme_set_midi(rfme_t *e, int notes_play_keys, int transpose, int key_notes_to_firmware)
{
    e->notesPlayKeys.store(notes_play_keys != 0);
    e->transpose.store(transpose < -2 ? -2 : transpose > 2 ? 2 : transpose);
    e->keyNotesToFw.store(key_notes_to_firmware != 0);
}

void rfme_midi_out_enable(rfme_t *e, int on) { e->midiOutOn.store(on != 0); }

int rfme_midi_out_take(rfme_t *e, uint32_t *pkt) { return e->midiOutQ.pop(*pkt) ? 1 : 0; }

void rfme_run_ms(rfme_t *e, uint32_t ms, rfme_audio_t *out)
{
    rfme_audio_t a{};
    double sum = 0;
    rfme::Scope cs(e, RFME_CLOCK_CALLER);
    if (cs.ok) {
        int16_t buf[2 * 256];
        for (uint32_t i = 0; i < ms; i++) {
            e->dev->run_ms();
            for (uint32_t got; (got = e->dev->take_s16(buf, 256)) > 0;) {
                for (uint32_t k = 0; k < 2 * got; k++) {
                    const int32_t v = buf[k];
                    sum += (double)v * v;
                    const int32_t m = v < 0 ? -v : v;
                    if (m > a.peak)
                        a.peak = m;
                }
                a.frames += got;
            }
        }
    }
    a.rms = a.frames ? std::sqrt(sum / (2.0 * (double)a.frames)) / 32768.0 : 0.0;
    if (out)
        *out = a;
}

int rfme_event(rfme_t *e, uint8_t type, uint8_t index, int16_t value)
{
    rfm_event_t ev{};
    ev.type = type;
    ev.index = index;
    ev.value = value;
    if (e->in.push(ev))
        return 1;
    e->dropped.fetch_add(1, std::memory_order_relaxed);
    return 0;
}

int rfme_matrix_button(rfme_t *e, int label)
{
    return e->booted && label >= 0 && label < FM1P_NB ? e->btnId[label] : -1;
}

int rfme_matrix_encoder(rfme_t *e, int role)
{
    return e->booted && role >= 0 && role < FM1P_NE - 1 ? e->encId[role] : -1;
}

void rfme_status(rfme_t *e, rfme_status_t *st)
{
    std::memset(st, 0, sizeof *st);
    st->loaded = e->core != nullptr;
    st->booted = e->booted;
    st->halted = e->halted.load();
    st->halt_code = e->haltCode.load();
    st->clock = e->clock.load();
    st->attached = e->attached.load();
    st->slot = e->core ? e->core->slot() : 0;
    if (e->core)
        putErr(st->core_id, sizeof st->core_id, e->core->info().id);
    st->dev_ms = e->devMs.load();
    st->lcd_writes = e->lcdWrites.load();
    st->snapshots = e->snapshots.load();
    st->events_applied = e->applied.load();
    st->events_dropped = e->dropped.load();
    st->keys_pressed = e->keysPressed.load();
    st->midi_out = e->midiOut.load();
    st->midi_in = e->midiInCount.load();
    st->midi_notes = e->midiNotes.load();
    st->midi_in_dropped = e->midiInDropped.load();
    st->shed = e->shed.load();
    st->cpu_pct = e->cpuPct.load();
    st->have_stats = e->haveStats.load();
    st->renders = e->renders.load();
    st->render_frames = e->renderFrames.load();
    st->render_last_us = e->renderLastUs.load();
    st->render_max_us = e->renderMaxUs.load();
    st->render_last_frames = e->renderLastFrames.load();
    st->render_avg_us = st->renders ? (uint32_t)((double)e->renderTicks.load() * e->usPerTick / (double)st->renders) : 0;
    st->rate = e->rate.load();
    st->flash_size = e->dev ? e->dev->flash_size() : 0;
    st->flash_dirty = e->flashDirty.load();
    st->flash_copies = e->flashCopies.load();
}

void rfme_reset_render_stats(rfme_t *e)
{
    e->renders.store(0);
    e->renderFrames.store(0);
    e->renderTicks.store(0);
    e->renderMaxUs.store(0);
}

uint32_t rfme_preview(rfme_t *e, uint32_t have, uint8_t *rgba)
{
    if (const Preview *p = e->preview.take())
        e->viewSeq = p->seq;
    if (!e->viewSeq || e->viewSeq == have || !rgba)
        return e->viewSeq;
    rfm::lcdToRGBA(e->preview.front()->lcd, rgba, FM1P_LCD_W * FM1P_LCD_H);
    return e->viewSeq;
}

uint32_t rfme_panel(rfme_t *e, rfme_panel_t *out)
{
    if (const rfme_panel_t *p = e->panelOut.take())
        e->panelSeen = p->seq;
    if (out) {
        if (e->panelSeen)
            *out = *e->panelOut.front();
        else
            std::memset(out, 0, sizeof *out);
        if (!e->booted)                                 // (unloaded since: nothing is lit)
            out->booted = 0;
    }
    return e->panelSeen;
}

uint32_t rfme_lcd_hash(rfme_t *e)
{
    if (!e->dev || !e->booted)
        return 0;
    const uint8_t *p = reinterpret_cast<const uint8_t *>(e->dev->lcd());
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < sizeof(fm1panel_t::lcd); i++)
        h = (h ^ p[i]) * 16777619u;
    return h;
}

uint32_t rfme_flash_size(rfme_t *e) { return e->dev ? e->dev->flash_size() : 0; }

int rfme_take_flash(rfme_t *e, uint8_t *out, uint32_t n)
{
    if (!e->flashReady.load(std::memory_order_acquire))
        return 0;
    const int ok = out && n >= e->flashCopy.size();
    if (ok)
        std::memcpy(out, e->flashCopy.data(), e->flashCopy.size());
    e->flashReady.store(false, std::memory_order_release);
    return ok;
}

void rfme_request_flash(rfme_t *e) { e->flashReq.store(true, std::memory_order_release); }

int rfme_final_flash(rfme_t *e, uint8_t *out, uint32_t n)
{
    const int prev = e->stop();
    int ok = 0;
    if (e->booted && e->dev->flash() && out && n >= e->dev->flash_size()) {
        e->dev->flash_sync();
        std::memcpy(out, e->dev->flash(), e->dev->flash_size());
        e->savedDirty = e->dev->flash_dirty();
        ok = 1;
    }
    e->resume(prev);
    return ok;
}

// the parameter named `name` of the booted core, -1 none
static int param(rfme_t *e, const char *name)
{
    return e->booted && name ? e->core->param_find(name) : -1;
}

int rfme_param_get(rfme_t *e, const char *name, int32_t *value)
{
    const int i = param(e, name);
    return i >= 0 && e->core->param_get((uint32_t)i, value) ? 1 : 0;
}

int rfme_param_set(rfme_t *e, const char *name, int32_t value)
{
    const int i = param(e, name);
    return i >= 0 && e->core->param_set((uint32_t)i, value) ? 1 : 0;
}

int rfme_param_read(rfme_t *e, const char *name, int32_t *value)
{
    const int prev = e->stop();
    const int ok = rfme_param_get(e, name, value);
    e->resume(prev);
    return ok;
}

int rfme_param_persist(rfme_t *e, char *name, uint32_t n, int32_t *min, int32_t *max, int32_t *value)
{
    if (!e->booted)
        return 0;
    rfm::CoreBackend &c = *e->core;
    for (uint32_t i = 0; i < c.param_count(); i++) {
        const rfm::CoreParam *p = c.param(i);
        if (p && (p->flags & FM1P_PERSIST) && !(p->flags & FM1P_META) && p->readable && p->writable && !p->name.empty()) {
            putErr(name, n, p->name);
            if (min)
                *min = p->min;
            if (max)
                *max = p->max;
            if (value)
                c.param_get(i, value);
            return 1;
        }
    }
    return 0;
}

void rfme_test_frame_stall(rfme_t *e, uint32_t us) { e->stallUs = us; }

} // extern "C"
