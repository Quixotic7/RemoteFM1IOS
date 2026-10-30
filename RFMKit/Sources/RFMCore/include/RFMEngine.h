// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMEngine (M3): FM-1 firmware cores on iOS.
//
// SLOTS (rfms_*): each core is in the bundle as FM1Core_<id>_1 .. _4.framework, the same code with its own install
// name (PLAN.md section 3). A core's state is its image's globals, so each instance takes a slot nobody in this
// process holds, and gives it back by unloading it. The registry is process-wide and thread-safe (not for the audio
// thread). A slot whose image did not leave memory on unload is retired for the rest of the process (its globals are
// the old instance's).
//
// THE ENGINE (rfme_*): one loaded core (a backend: RFMCoreBackend.h) run by FM1VST's device clock on ONE thread at a
// time (core-api/fm1core.h's threading contract): the engine's core thread, which renders ahead of the audio callback
// (RFME_CLOCK_AUDIO) or runs by the wall clock when there is no audio (RFME_CLOCK_TIMER, the sound dropped), or the
// caller (RFME_CLOCK_CALLER, tests). fm1remote's design
// (RemoteFM1 host/tools/fm1remote/engine.h) with FM1VST's panel mapping (plugin/Processor.cpp):
//   panel -> core   the FM-1's events (RemoteLink's queue) and rfme_event's, applied in Device's between hook, in order
//   core -> FM-1    the LCD, the LEDs (as RemoteFM1's planes) and PLAY green, into RemoteLink's triple buffer and the
//                   engine's preview at most every 50 device ms and only when they changed
//   core -> files   the flash image copied by the clock every 30 device s when flash_dirty moved, or when asked; the
//                   caller writes it (never on the audio thread)
//   host -> core    (M4, the AUv3) host MIDI at its frame in the render (rfme_render_midi): FM1VST's mapping (notes
//                   53.. play the keys, with the host's velocity, transposed by octaves; everything else, and the key
//                   notes too if asked, to the core's midi_in as USB-MIDI packets)
//   core -> host    (M4) the core's midi_out_take packets, to the AU's MIDI output (rfme_midi_out_take)
//   controller      (M8) a MIDI controller's messages (rfme_midi_in) take host MIDI's path on the core thread; learn
//                   and the learned map (rfme_set_midi_map) come first there, for host MIDI too
// Load, boot, unload and power cycle run on one control thread (the main thread) with the clock stopped
// (rfme_set_clock(NONE) waits until the clock is out). Nothing in rfme_render allocates or locks.
//
// RENDER AHEAD (M7): with RFME_CLOCK_AUDIO the audio callback never runs the core. The core thread renders into a
// lock-free ring, kept `target` frames ahead (the largest host buffer seen + a headroom, 6 ms by default: a slow
// screen redraw in frame() is absorbed there); rfme_render copies from the ring, queues the host's MIDI stamped with
// its frame, and wakes the core thread. So the sound is `latency` frames later than the callback's own time
// (rfme_latency, rfme_status.latency_frames), host MIDI too, exactly (at its frame + latency), and the core's MIDI out
// keeps its place in the stream (rfme_midi_out_take_at). What the core hasn't made in time is silence, counted
// (underruns). The core thread is a Mach real-time thread and joins the host's audio workgroup when it is given one
// (rfme_set_workgroup, rfme_use_output_workgroup).
#ifndef RFMENGINE_H
#define RFMENGINE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- slots
typedef struct {
    char id[32], name[64], version[48], family[32], license[48], gated[96];
    char source_url[256];
    uint32_t abi, flash_size;
    int slots;                  // FM1Core_<id>_<n>.framework found
    int in_use, retired;        // slots held now; slots retired (their image stayed loaded)
} rfms_info_t;
// finds the slots in dir, or (NULL / "") in the main bundle's Frameworks, and from inside an app extension also the
// containing app's (<appex>/../../Frameworks); probes each core's descriptor (ABI 5..6). Returns how many cores.
// A core with a slot in use keeps its registry entry. An appex that finds no slots that way (on a Mac the sandbox
// denies listing the containing app's folder) takes the slots its FM1CoreSlots.txt names, by path in the app's
// Frameworks (scripts/embed_cores.sh --list).
int rfms_scan(const char *dir);
// the same with the slots `list` names (FM1CoreSlots.txt's text: one FM1Core_<id>_<n>.framework a line, # comments)
// looked for in dir by path, without listing it
int rfms_scan_list(const char *dir, const char *list);
int rfms_count(void);
int rfms_info(int i, rfms_info_t *out);             // 1: filled
int rfms_find(const char *id, rfms_info_t *out);    // 1: found
// the core's credits (fm1core_credits: NULL for ABI 5): copied into buf (n bytes, NUL-terminated); returns the full
// length (0: none)
uint32_t rfms_credits(const char *id, char *buf, uint32_t n);
// where the slots were found (the last scan's directories, "; "-separated) and the scan's problems ("" none)
uint32_t rfms_dirs(char *buf, uint32_t n);
uint32_t rfms_errors(char *buf, uint32_t n);
// how the last scan found its slots: "dir listing", "list file" (with why the folder couldn't be listed), "" none
uint32_t rfms_source(char *buf, uint32_t n);

// ---- the engine
typedef struct rfmc rfmc_t;
typedef struct rfme rfme_t;
enum { RFME_CLOCK_NONE = 0, RFME_CLOCK_AUDIO, RFME_CLOCK_TIMER, RFME_CLOCK_CALLER };
// button labels and knob roles, as fm1core.h's FM1P_B_* / FM1P_E_* (for rfme_matrix_button / _encoder)
enum { RFME_B_FX, RFME_B_SEL, RFME_B_ENV, RFME_B_LFO, RFME_B_EDIT, RFME_B_GLO, RFME_B_HOME, RFME_B_SAVE, RFME_B_ARP,
       RFME_B_SEQ, RFME_B_PLAY, RFME_B_REC, RFME_B_OCTDN, RFME_B_OCTUP };
enum { RFME_E_SELECT, RFME_E_ALGO, RFME_E_PRESETS, RFME_E_K1, RFME_E_K2, RFME_E_K3, RFME_E_K4 };

// link: the FM-1 (RFMCore's rfmc_t) whose panel this engine plays and shows on while attached, or NULL (headless)
rfme_t *rfme_new(rfmc_t *link);
void rfme_free(rfme_t *e);      // the clock stopped, detached, the core shut down and its slot released

// control thread, any clock (each stops the clock while it works, then gives it back)
int rfme_load(rfme_t *e, const char *core_id, char *err, uint32_t n);   // a free slot of the core; 0: failed (err)
int rfme_boot(rfme_t *e, const uint8_t *flash, uint32_t n);             // power-on from the image (NULL / 0: fresh)
void rfme_unload(rfme_t *e);                                             // shutdown(), the slot released
// a firmware reboot (halted()): the image kept (flash_sync, copied), the slot reloaded, booted from the image, which is
// also offered to rfme_take_flash for saving. 0: failed (err)
int rfme_power_cycle(rfme_t *e, char *err, uint32_t n);
// attached: the engine takes the link's panel events and publishes to it; the link's own producer (the test pattern)
// stands aside (rfmc_set_external)
void rfme_attach(rfme_t *e, int on);

// who runs the clock; waits until the previous owner has left it
void rfme_set_clock(rfme_t *e, int owner);
int rfme_clock(rfme_t *e);

// RFME_CLOCK_AUDIO: n frames at `rate` into L and R (silence while not booted or not the owner). Real-time safe.
void rfme_render(rfme_t *e, float *L, float *R, uint32_t n, double rate);
// ---- host MIDI (M4)
typedef struct {
    uint32_t offset;            // the frame in this render it applies at (events in order)
    uint8_t len;                // 1..3 (a channel or system message; SysEx is not passed here)
    uint8_t data[3];
} rfme_midi_t;
// RFME_CLOCK_AUDIO: rfme_render with host MIDI applied at each event's frame (+ the latency). Returns 1 when the
// core's audio played (some frames of it), 0 silence (not booted, not the clock's owner, the ring still filling).
// Real-time safe: no locks, no allocation, no waits (offline: bounded waits for the core thread).
int rfme_render_midi(rfme_t *e, float *L, float *R, uint32_t n, double rate, const rfme_midi_t *ev, uint32_t nev);
// (any thread) the ring's target: the largest host buffer seen (at least min_buffer_frames) + headroom_us (default
// 6000, 0 frames); applies from the next render on
void rfme_set_latency(rfme_t *e, uint32_t headroom_us, uint32_t min_buffer_frames);
// the latency now, in frames at the render's rate (a host event to its sound; the core's audio behind the callback's
// time); before the first render, what it will be at `rate` with `buffer`-frame renders
uint32_t rfme_latency(rfme_t *e, double rate, uint32_t buffer);
// (any thread) offline rendering (a host's bounce): a render waits (bounded) for the core thread instead of playing
// silence where frames are missing. Default off
void rfme_set_offline(rfme_t *e, int on);
// (any thread, real-time safe) the audio workgroup the render callback runs in (an os_workgroup_t; NULL: none): the
// core thread leaves the one it is in and joins it. The AU's render context observer calls this
void rfme_set_workgroup(rfme_t *e, void *os_workgroup);
// (control thread) the output unit's workgroup (kAudioOutputUnitProperty_OSWorkgroup of an AudioUnit, e.g.
// AVAudioEngine's outputNode.audioUnit) to rfme_set_workgroup; 1: it had one
int rfme_use_output_workgroup(rfme_t *e, void *audio_unit);
// (any thread) FM1VST's settings: MIDI notes play the keys (default 1), transpose -2..2 octaves (0), key notes also
// to the firmware (0)
void rfme_set_midi(rfme_t *e, int notes_play_keys, int transpose, int key_notes_to_firmware);
// the core's MIDI out kept for rfme_midi_out_take (on: the AU has a MIDI output; off: counted and dropped)
void rfme_midi_out_enable(rfme_t *e, int on);
// the render thread, after rfme_render_midi: one USB-MIDI packet of the core's that falls in the frames that render
// played; 0: none. _at also gives its frame in that render (the same latency as the audio)
int rfme_midi_out_take(rfme_t *e, uint32_t *pkt);
int rfme_midi_out_take_at(rfme_t *e, uint32_t *pkt, uint32_t *offset);

// ---- (M8) MIDI from a controller, and the learned map (the website's js/midi-map.js)
// (any thread but the audio thread; serialised inside) one channel message (1..3 bytes) from a controller, for the
// core thread: as host MIDI (learn, the learned map, then notes play keys, the rest to the core's midi_in), or with
// to_firmware straight to the core's midi_in (not learnt, not mapped, no keys: the OMX-27's Keyboard view). Applied
// before the next chunk the core thread renders (TIMER: its next tick; CALLER: the next rfme_run_ms). 0: dropped
// (the queue is full, or not a channel message)
int rfme_midi_in(rfme_t *e, const uint8_t *data, uint32_t len, int to_firmware);

enum { RFME_SRC_CC = 0, RFME_SRC_NOTE = 1 };
// targets: 0..6 the knob roles (RFME_E_* order), RFME_T_MASTER, RFME_T_BUTTON + label (RFME_B_*: 8..21)
enum { RFME_T_MASTER = 7, RFME_T_BUTTON = 8 };
// a CC on an encoder: abs a pot (the change since its last value), rel64 binary offset (65 = +1), rel2c two's
// complement (127 = -1), relsign sign bit (65 = -1)
enum { RFME_MAP_ABS = 0, RFME_MAP_REL64 = 1, RFME_MAP_REL2C = 2, RFME_MAP_RELSIGN = 3 };
typedef struct {
    uint8_t src;                // RFME_SRC_*
    uint8_t channel;            // 0..15
    uint8_t number;             // the CC or note number, 0..127
    uint8_t target;             // RFME_T_* or a knob role
    uint8_t mode;               // RFME_MAP_* (an encoder's CC; otherwise ignored)
} rfme_map_entry_t;
// (control thread, one writer) the learned map, whole (n <= 512; a note on a knob or MASTER is ignored), and the
// knob speed (0.5, 1 or 2; else 1). A source whose target is new starts again; whatever the old map held is let go.
// Kept across loads and power cycles (an engine setting). As midi-map.js: a mapped message is consumed (it plays no
// key, never reaches midi_in); encoders turn by whole detents (fractions carry), buttons press on note-on / CC >= 64
// and are down while any of their sources is; a MASTER pot waits until it reaches MASTER (rfme_panel_t.master_pot)
void rfme_set_midi_map(rfme_t *e, const rfme_map_entry_t *map, uint32_t n, float speed);
// (any thread) learn armed: every CC and note-on from the host or rfme_midi_in (and the note-off of a note it took)
// goes to the learn queue instead of anywhere else
void rfme_learn(rfme_t *e, int armed);
// (one reader, not the audio thread) the next message in the learn queue: 1 and its 3 bytes; 0 none
int rfme_learn_take(rfme_t *e, uint8_t msg[3]);
// RemoteMidi.c's rule (fm1_remote_midi_candidate): 1 when a MIDI endpoint may be an FM-1 (USB 1209:0001; without the
// USB property, "FM-1" in the device's or the endpoint's name; never an updater port). has_usb 0 for Bluetooth MIDI
int rfme_fm1_candidate(int has_usb, int32_t usb_id, const char *device_name, const char *endpoint_name);

// RFME_CLOCK_CALLER (tests): `ms` device milliseconds on this thread; the sound measured, then dropped
typedef struct {
    uint64_t frames;
    double rms;                 // over both channels, full scale 1.0
    int32_t peak;               // the largest |sample| (int16)
    uint32_t hash;              // FNV-1a over the samples (each int16 as 16 bits), for bit-exact comparisons
} rfme_audio_t;
void rfme_run_ms(rfme_t *e, uint32_t ms, rfme_audio_t *out);

// a panel event as the FM-1 sends it (RFMC_EV_KEY / BUTTON / ENC / MASTER, matrix ids; any thread but the clock's,
// one producer), applied in the clock's between hook like the unit's. 0: the queue is full
int rfme_event(rfme_t *e, uint8_t type, uint8_t index, int16_t value);
int rfme_matrix_button(rfme_t *e, int label);   // the matrix id of a label (after boot), -1
int rfme_matrix_encoder(rfme_t *e, int role);   // the matrix encoder of a knob role (after boot), -1

// ---- the on-screen panel (the app's faceplate): the core's panel state besides the LCD, for a UI to poll (30-60 Hz).
// The clock publishes it every 8 device ms when it changed, through a triple buffer: lock-free, never blocking the
// audio thread. The on-screen controls go in through rfme_event, as the FM-1's do.
typedef struct {
    uint32_t seq;               // moves when anything below changed (0: nothing published yet)
    uint32_t keys;              // note keys held now (the unit's, the screen's and host notes): bit k = key k
    uint32_t labels;            // buttons held now, by label (bit RFME_B_*)
    int32_t enc[7];             // per knob role (RFME_E_*): detents turned clockwise since power-on, anyone's turns
    int32_t master;             // the MASTER pot as the core has it, 0..1023
    uint8_t key_led[27];        // each note key's LED level 0..255 (fm1core.h FM1P_LED_*: 176+ lit, 96 mid, 40 dim, 12 faint)
    uint8_t btn_led[14];        // each button's LED level, by label (RFME_B_*)
    uint8_t play_green;         // PLAY's green LED level
    uint8_t booted;             // 1: a core is running (the values above are its)
    // (M8) a learned MASTER pot waiting to pick MASTER up: where the pot is, 0..1023; -1 none (MASTER set by a pot)
    int16_t master_pot;
    uint16_t pickup_seq;        // moves each time a pot starts waiting (the UI: "turn the pot to <master>%")
} rfme_panel_t;
// the newest panel state (one reader thread, any but the clock's); returns its seq (0: none yet; out zeroed)
uint32_t rfme_panel(rfme_t *e, rfme_panel_t *out);

typedef struct {
    int loaded, booted, halted, clock, attached;
    uint32_t halt_code;         // halted(): 0x100 | exit code
    int slot;                   // 1..4, 0 none (or a Wasm core: no slots)
    char core_id[32];
    uint32_t dev_ms, lcd_writes, snapshots, events_applied, events_dropped, keys_pressed, midi_out;
    uint32_t midi_in, midi_notes, midi_in_dropped;  // (M4) host MIDI messages; of them notes that played a key; lost
    uint32_t shed, cpu_pct, have_stats;   // the core's stats(), read every 500 device ms
    uint64_t renders, render_frames;
    uint32_t render_last_us, render_avg_us, render_max_us, render_last_frames;   // rfme_render's own time
    double rate;                // the last render's rate
    uint32_t flash_size, flash_dirty, flash_copies;
    // (M7) render ahead
    uint32_t latency_frames;    // the latency now (rfme_latency; 0: no render yet)
    uint32_t ring_target;       // frames the core thread keeps in the ring
    uint32_t ring_fill_min;     // the fewest frames the ring held at a render since the reset (~0: none yet)
    uint32_t underruns, underrun_frames;   // renders the ring ran short in; frames played as silence for it
    uint64_t core_wakes, core_frames;      // the core thread's renders (about one per host buffer) and frames made
    uint32_t core_avg_us, core_max_us;     // the core thread's time per render
    uint32_t core_load_pct;     // the core thread's time over the audio's duration
    uint32_t frame_max_us;      // the longest frame() (the firmware's screen redraw)
    int32_t realtime;           // the core thread got the time-constraint policy
    int32_t workgroup;          // the core thread is in the host's audio workgroup
    uint32_t workgroup_joins;
    char kind[8];               // (M7) the backend: "native" (a slot), "wasm" (an .rfm1 in wasm3), "" none
    // (M8) MIDI messages the learned map took; learn took; passed on to the core's midi_in (host and controller)
    uint32_t midi_mapped, midi_learned, midi_to_core;
} rfme_status_t;
void rfme_status(rfme_t *e, rfme_status_t *st);
void rfme_reset_render_stats(rfme_t *e);
// the LCD last published (any thread but the clock's): if its number differs from `have`, copied as RGBA8888
// (240 x 240 x 4) into rgba; returns its number (0: none yet)
uint32_t rfme_preview(rfme_t *e, uint32_t have, uint8_t *rgba);
// (RFME_CLOCK_CALLER or NONE) FNV-1a of the core's LCD as it is now
uint32_t rfme_lcd_hash(rfme_t *e);

// ---- the flash image
uint32_t rfme_flash_size(rfme_t *e);
// a copy the clock made (every 30 device s when dirty, after rfme_request_flash, or a power cycle's); 1: one was
// ready and is now in out (n >= flash size)
int rfme_take_flash(rfme_t *e, uint8_t *out, uint32_t n);
// asks the clock for flash_sync and a copy at its next between hook (then rfme_take_flash)
void rfme_request_flash(rfme_t *e);
// stops the clock, flash_sync, the image now into out, the clock given back; 1: ok
int rfme_final_flash(rfme_t *e, uint8_t *out, uint32_t n);

// ---- the parameter map (RFME_CLOCK_CALLER or NONE: tests)
int rfme_param_get(rfme_t *e, const char *name, int32_t *value);    // 1: found
int rfme_param_set(rfme_t *e, const char *name, int32_t value);
// the first FM1P_PERSIST entry: its name, range and value; 0: none
int rfme_param_persist(rfme_t *e, char *name, uint32_t n, int32_t *min, int32_t *max, int32_t *value);
// (control thread, any clock: the clock stopped for the read; diagnostics and tests) 1: found
int rfme_param_read(rfme_t *e, const char *name, int32_t *value);

// ---- tests
// from the next rfme_load / rfme_power_cycle on, every frame() of the core takes `us` microseconds longer (a busy
// wait on the clock's thread: a stand-in for an interpreted firmware's screen redraw); 0: off
void rfme_test_frame_stall(rfme_t *e, uint32_t us);
// core threads alive in this process (each engine with a clock run has one until rfme_free)
int rfme_test_core_threads(void);
// the calling thread as a real-time thread with this period (a test's stand-in for an audio callback); 1: done
int rfme_test_realtime(double period_s);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <AVFoundation/AVFoundation.h>
#ifdef __cplusplus
extern "C" {
#endif
// an AVAudioSourceNode whose render block calls rfme_render (format: deinterleaved float, 1 or 2 channels); e must
// outlive the node's use
AVAudioSourceNode *rfme_source_node(rfme_t *e, AVAudioFormat *format);
#ifdef __cplusplus
}
#endif
#endif
#endif
