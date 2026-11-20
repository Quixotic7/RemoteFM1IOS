// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// THE ABLETON MOVE (rfmm_*): an Ableton Move running Move Remote (github.com/Quixotic7/abletonmoveremote) as the
// emulated FM-1's controller, through rfm1cs-abletonmove, the Move code shared with the web and Android (MoveLink.h says how). The app keeps the settings and
// the 32 project slots: it answers the link's requests (rfmm_take_request) and gives it the store at start.
//   rfmm_t *m = rfmm_new(settings, n, "RemoteFM1 iOS");   rfme_attach_move(engine, m);   rfmm_start(m, "move.local");
// Free order: rfme_attach_move(engine, NULL), the engine's clock stopped (or the engine freed), then rfmm_free.
#ifndef RFM_MOVE_API_H
#define RFM_MOVE_API_H

#include <stdint.h>

#include "RFMEngine.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rfmm rfmm_t;

enum { RFMM_OFF = 0, RFMM_CONNECTING = 1, RFMM_CONNECTED = 2, RFMM_RETRYING = 3, RFMM_ERROR = 4 };   // (RFM1CS_*; ERROR: FAILED)
enum { RFMM_VIA_WIFI = 0, RFMM_VIA_USB = 1, RFMM_VIA_LOCAL = 2 };   // (MR_VIA_*)
// requests (rfm_move's RFM_MOVE_ACT_* numbers)
enum {
    RFMM_REQ_SETTINGS = 7,          // data: the settings image, to keep
    RFMM_REQ_PROJECT_SAVE = 8,      // slot, data: the project's blob, to store
    RFMM_REQ_PROJECT_LOAD = 9,      // slot: answer with rfmm_project_answer
    RFMM_REQ_PROJECT_DELETE = 10,   // slot: forget it
    RFMM_REQ_PROJECT_CUT = 13,      // slot: into the app's project buffer, then forget it
    RFMM_REQ_PROJECT_COPY = 14,     // slot: into the buffer
    RFMM_REQ_PROJECT_PASTE = 15,    // slot (empty): the buffer stored there
    RFMM_REQ_PROJECT_COLOR = 16,    // slot, value 1..16: the stored blob's byte 18 set (rfmm_project_with_color)
    // (rfm1cs-abletonmove 0.5.10, one firmware and no FX) the Move's firmware browser
    RFMM_REQ_FW_LOAD = 17,          // data: the firmware's id: play it (then rfmm_fw_progress 100 and rfmm_fw_slot)
    RFMM_REQ_FW_UNLOAD = 18,        // the slot emptied on the Move (the app keeps a firmware: rfmm_fw_slot again)
    RFMM_REQ_FW_DOWNLOAD = 20,      // data: the id: download it, or update it (progress, then rfmm_fw_installed)
    RFMM_REQ_FW_LIBRARY = 21,       // data: the library blob (favourites, colours, tags), to keep
    RFMM_REQ_FW_LEVEL = 22,         // value 0..127: the firmware's level (kept in the library)
};
enum { RFMM_FW_FAILED = -1, RFMM_FW_BUSY = -2, RFMM_FW_THUMB_BYTES = 512 };
// one firmware the browser lists: ASCII strings (id < 32 bytes); installed NULL / "": not here; thumb 64 x 64, 1 bit,
// rows top first, MSB left (NULL: initials); cats RFMM_CAT_* bits; cat the main one 0..4 (255 none); virt a Fantasy CFW
enum { RFMM_CAT_SYNTH = 1, RFMM_CAT_GROOVEBOX = 2, RFMM_CAT_CHORDS = 4, RFMM_CAT_DRUMS = 8, RFMM_CAT_OTHER = 16 };
typedef struct {
    const char *id, *name, *version, *installed, *desc;
    const uint8_t *thumb;
    int cats, cat, virt;
} rfmm_fw_t;

typedef struct {
    int state;                      // RFMM_*
    char text[256];                 // what to show
    char name[32];                  // the Move's name (its HELLO)
    int via;                        // RFMM_VIA_*, -1 not connected
    int battery;                    // 0..100, -1 unknown
    int mode;                       // 0 FM-1, 1 MIDI, 2 Control, 3 Sequencer
    int project;                    // the open project's slot
    int playing;                    // the sequencer plays
    int ticking;                    // a firmware runs the core (no firmware: the Move waits)
    uint32_t inputs, leds, screens, connects, seq_midi;
} rfmm_status_t;

typedef struct {
    int kind, slot, value;
    uint32_t len;                   // data's bytes (copied into the caller's buffer)
} rfmm_request_t;

rfmm_t *rfmm_new(const uint8_t *settings, uint32_t n, const char *host_name);   // settings: NULL for the defaults
void rfmm_free(rfmm_t *m);
void rfmm_start(rfmm_t *m, const char *host);      // NULL or "": move.local
void rfmm_stop(rfmm_t *m);
void rfmm_status(rfmm_t *m, rfmm_status_t *st);
// 1: a request (its data in data, at most cap bytes: give rfmm_project_max()), 0: none
int rfmm_take_request(rfmm_t *m, rfmm_request_t *r, uint8_t *data, uint32_t cap);
void rfmm_projects_init(rfmm_t *m, uint32_t dir_bits, int open_slot, const uint8_t *blob, uint32_t n);
void rfmm_project_dir(rfmm_t *m, uint32_t bits);
void rfmm_project_info(rfmm_t *m, int slot, const uint8_t *blob, uint32_t n);
void rfmm_project_answer(rfmm_t *m, int slot, const uint8_t *blob, uint32_t n);   // NULL / 0: none there
void rfmm_project_flush(rfmm_t *m);
int rfmm_project_check(const uint8_t *blob, uint32_t n);     // 0: a valid project blob
// a stored blob with a new colour (byte 18) and its check made again, in place (n: its length)
void rfmm_project_with_color(uint8_t *blob, uint32_t n, int color);
uint32_t rfmm_project_max(void);
// the project file (.rfmmove one project, .rfmmoveset a set: rfm1cs-abletonmove's, byte for byte the web's and
// Android's): pack n entries into out (its length, 0: cap too small); unpack reads and checks one (the count, entries
// pointing into b; or < 0 with what is wrong in err, as the web says it)
typedef struct { int slot; uint32_t saved; const uint8_t *bytes; uint32_t len; } rfmm_file_entry_t;
uint32_t rfmm_file_max(void);
uint32_t rfmm_file_pack(const rfmm_file_entry_t *e, int n, uint8_t *out, uint32_t cap);
int rfmm_file_unpack(const uint8_t *b, uint32_t n, rfmm_file_entry_t e[32], char *err, uint32_t errcap);
uint32_t rfmm_settings_bytes(void);
// the firmware browser (copied: the caller's array may go once this returns). The list A-Z by name
void rfmm_fw_list(rfmm_t *m, const rfmm_fw_t *e, int n);
void rfmm_fw_installed(rfmm_t *m, const char *id, const char *version);   // a download landed (NULL: removed)
void rfmm_fw_progress(rfmm_t *m, const char *id, int pct);                 // 0..100, RFMM_FW_FAILED, RFMM_FW_BUSY
void rfmm_fw_slot(rfmm_t *m, const char *id);                              // the firmware playing (NULL: none)
int rfmm_fw_library(rfmm_t *m, const uint8_t *blob, uint32_t n);           // at start; 0 ok, -1 not a library
uint32_t rfmm_fw_library_max(void);
// another firmware plays (or its names changed): its own button names, 14 in FM1P_B_* order ("" or NULL: none;
// names NULL: none at all); the Move's live labels and readouts start again
void rfmm_firmware_changed(rfmm_t *m, const char *const *names);
// (tests) a new, empty project's blob, as the core saves it: its bytes, or -1 (cap too small)
int rfmm_test_empty_project(uint8_t *out, uint32_t cap);

// (RFMEngine) the Move's core runs on this engine's core thread; NULL detaches it
void rfme_attach_move(rfme_t *e, rfmm_t *m);

#ifdef __cplusplus
}
#endif

#endif
