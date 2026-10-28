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
// THE ENGINE (rfme_*): one loaded core run by FM1VST's Device on ONE clock thread at a time (core-api/fm1core.h's
// threading contract): the audio callback (RFME_CLOCK_AUDIO), the engine's own timer thread when there is no audio
// (RFME_CLOCK_TIMER, the sound dropped), or the caller (RFME_CLOCK_CALLER, tests). fm1remote's design
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
// Load, boot, unload and power cycle run on one control thread (the main thread) with the clock stopped
// (rfme_set_clock(NONE) waits until the clock is out). Nothing in rfme_render allocates or locks.
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
// A core with a slot in use keeps its registry entry.
int rfms_scan(const char *dir);
int rfms_count(void);
int rfms_info(int i, rfms_info_t *out);             // 1: filled
int rfms_find(const char *id, rfms_info_t *out);    // 1: found
// the core's credits (fm1core_credits: NULL for ABI 5): copied into buf (n bytes, NUL-terminated); returns the full
// length (0: none)
uint32_t rfms_credits(const char *id, char *buf, uint32_t n);
// where the slots were found (the last scan's directories, "; "-separated) and the scan's problems ("" none)
uint32_t rfms_dirs(char *buf, uint32_t n);
uint32_t rfms_errors(char *buf, uint32_t n);

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
// RFME_CLOCK_AUDIO: rfme_render with host MIDI applied at each event's frame. Returns 1 when the core rendered,
// 0 silence (not booted, or not the clock's owner). Real-time safe.
int rfme_render_midi(rfme_t *e, float *L, float *R, uint32_t n, double rate, const rfme_midi_t *ev, uint32_t nev);
// (any thread) FM1VST's settings: MIDI notes play the keys (default 1), transpose -2..2 octaves (0), key notes also
// to the firmware (0)
void rfme_set_midi(rfme_t *e, int notes_play_keys, int transpose, int key_notes_to_firmware);
// the core's MIDI out kept for rfme_midi_out_take (on: the AU has a MIDI output; off: counted and dropped)
void rfme_midi_out_enable(rfme_t *e, int on);
// the render thread, after rfme_render_midi: one USB-MIDI packet of the core's; 0: none
int rfme_midi_out_take(rfme_t *e, uint32_t *pkt);

// RFME_CLOCK_CALLER (tests): `ms` device milliseconds on this thread; the sound measured, then dropped
typedef struct {
    uint64_t frames;
    double rms;                 // over both channels, full scale 1.0
    int32_t peak;               // the largest |sample| (int16)
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
} rfme_panel_t;
// the newest panel state (one reader thread, any but the clock's); returns its seq (0: none yet; out zeroed)
uint32_t rfme_panel(rfme_t *e, rfme_panel_t *out);

typedef struct {
    int loaded, booted, halted, clock, attached;
    uint32_t halt_code;         // halted(): 0x100 | exit code
    int slot;                   // 1..4, 0 none
    char core_id[32];
    uint32_t dev_ms, lcd_writes, snapshots, events_applied, events_dropped, keys_pressed, midi_out;
    uint32_t midi_in, midi_notes, midi_in_dropped;  // (M4) host MIDI messages; of them notes that played a key; lost
    uint32_t shed, cpu_pct, have_stats;   // the core's stats(), read every 500 device ms
    uint64_t renders, render_frames;
    uint32_t render_last_us, render_avg_us, render_max_us, render_last_frames;   // rfme_render's own time
    double rate;                // the last render's rate
    uint32_t flash_size, flash_dirty, flash_copies;
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
