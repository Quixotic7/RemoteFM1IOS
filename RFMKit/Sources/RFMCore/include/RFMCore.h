// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMCore: the C face of RemoteLink for Swift. One rfmc_t is one RemoteLink plus a producer thread that does what
// FM1VST's audio thread does there: it takes the panel's events and publishes the LCD and LEDs. In M1 there is no
// core: the producer draws fm1remote's test pattern (--pattern), or a still screen, and shows the panel's held keys
// and buttons on the unit (their LEDs lit, a strip at the bottom of the screen).
// Plain C (Swift imports it). Every call returns at once and may come from any thread.
#ifndef RFMCORE_H
#define RFMCORE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { RFMC_DEVICE = 0, RFMC_FAKE = 1 };
// RemoteLink::State
enum { RFMC_OFF = 0, RFMC_IN_USE, RFMC_SEARCHING, RFMC_CONNECTED, RFMC_LOST, RFMC_ERROR, RFMC_STOPPING };
// rfm_session_state (RFM_S_*), -1 no session
enum { RFMC_S_DISCOVER = 0, RFMC_S_STARTING, RFMC_S_ACTIVE, RFMC_S_STOPPING, RFMC_S_STOPPED };
// rfm_event_t types, and RemoteLink::kEvRelease (everything the unit held is up)
enum { RFMC_EV_KEY = 1, RFMC_EV_BUTTON = 2, RFMC_EV_ENC = 3, RFMC_EV_MASTER = 4, RFMC_EV_RELEASE = 0x80 };
#define RFMC_W 240
#define RFMC_H 240

typedef struct {
    int backend;                // RFMC_DEVICE (CoreMIDI, FM-1 candidates only) or RFMC_FAKE (in-process fake unit)
    int fake_ble;               // the fake as a 0.2.2 unit over Bluetooth MIDI
    uint32_t fps;               // the session's cap (20)
    const char *lock_path;      // RemoteLink's unit lock (flock), in the app's own temporary directory
    const char *host_name;      // HELLO's body, at most 16 bytes
} rfmc_cfg_t;

typedef struct rfmc rfmc_t;
rfmc_t *rfmc_new(const rfmc_cfg_t *cfg);
void rfmc_free(rfmc_t *c);      // stops (SESSION 0, at most ~600 ms) and joins the threads

void rfmc_start(rfmc_t *c);
void rfmc_stop(rfmc_t *c);
void rfmc_set_pattern(rfmc_t *c, int on);
void rfmc_rescan(rfmc_t *c);    // CoreMIDI's setup changed

typedef struct {
    int state;                  // RFMC_*
    int session_state;          // RFMC_S_*, -1
    int wanted, bulk, ble;
    float fps;
    uint32_t runs, sessions, frames, acks, pending, in_flight, events_in, events_dropped, snapshots;
    uint32_t colors, reduced, refined, held, hold, budget, wire_bytes, body_bytes, wire_cap, frame_ms;
    uint32_t ack_ms_last, ack_ms_avg, ack_ms_max, ack_timeouts, discoveries;
    char text[160];
    char log[200];
    // the unit's HELLO_R (have_hello: one was seen; kept after the session ends)
    int have_hello, hello_ble;
    char name[17], ver[9], fw_ver[9], identity[9];
    uint8_t proto, transports, usb_mode, session, max_in_flight;
    uint16_t caps, sxq, sx_body_max, bk_body_max, screen_w, screen_h;
} rfmc_status_t;
void rfmc_status(rfmc_t *c, rfmc_status_t *st);

typedef struct {
    uint32_t seq;               // 1, 2, .. in arrival order
    uint8_t type, index, source; // RFMC_EV_*; key 0..26 / button 0..13 / encoder 0..6; 0 MIDI, 1 PANEL_R correction
    int16_t value;              // key / button 1 down 0 up; encoder detents; MASTER 0..1023
} rfmc_event_t;
// the events after seq `after` (the newest `max` of them, oldest first); returns how many were copied
uint32_t rfmc_events(rfmc_t *c, uint32_t after, rfmc_event_t *out, uint32_t max);
// the panel as the producer sees it: held keys and buttons (bits), MASTER (-1 unknown)
void rfmc_panel(rfmc_t *c, uint32_t *keys, uint32_t *buttons, int32_t *master);

// the frame being sent: if its number differs from `have`, copies it as RGBA8888 (240 x 240 x 4) into rgba;
// returns its number (0: none yet)
uint32_t rfmc_preview(rfmc_t *c, uint32_t have, uint8_t *rgba);

// ---- the fake unit (RFMC_FAKE; no-ops otherwise)
void rfmc_fake_key(rfmc_t *c, uint32_t k, int down);
void rfmc_fake_button(rfmc_t *c, uint32_t b, int down);
void rfmc_fake_enc(rfmc_t *c, uint32_t e, int32_t detents);
void rfmc_fake_master(rfmc_t *c, uint32_t adc);
typedef struct {
    int session;                // 0 none, 1 SysEx, 2 bulk
    uint32_t frames, acks, held_frames, hellos;
    uint8_t lit[11];            // the LEDs it shows lit (LEDS' lit plane, packed row bits per column)
} rfmc_fake_t;
int rfmc_fake_state(rfmc_t *c, rfmc_fake_t *out);   // 0: not the fake backend
// the fake's LED (lit plane) for note key k / matrix button b: 1 lit
int rfmc_fake_key_lit(rfmc_t *c, uint32_t k);
int rfmc_fake_button_lit(rfmc_t *c, uint32_t b);

#ifdef __cplusplus
}
#endif
#endif
