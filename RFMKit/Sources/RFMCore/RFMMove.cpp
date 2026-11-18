// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// rfmm_* (RFMMove.h) over MoveLink.

#include "RFMMove.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>

#include "MoveLink.h"

using rfm::MoveLink;

static MoveLink *L(rfmm_t *m) { return reinterpret_cast<MoveLink *>(m); }

static std::vector<uint8_t> bytes(const uint8_t *b, uint32_t n) { return b && n ? std::vector<uint8_t>(b, b + n) : std::vector<uint8_t>{}; }

rfmm_t *rfmm_new(const uint8_t *settings, uint32_t n, const char *host_name)
{
    return reinterpret_cast<rfmm_t *>(new MoveLink(settings, n, host_name ? host_name : "RemoteFM1"));
}

void rfmm_free(rfmm_t *m) { delete L(m); }
void rfmm_start(rfmm_t *m, const char *host) { L(m)->start(host ? host : ""); }
void rfmm_stop(rfmm_t *m) { L(m)->stop(); }

void rfmm_status(rfmm_t *m, rfmm_status_t *st)
{
    const MoveLink::Status s = L(m)->status();
    std::memset(st, 0, sizeof *st);
    st->state = s.state;
    std::snprintf(st->text, sizeof st->text, "%s", s.text.c_str());
    std::snprintf(st->name, sizeof st->name, "%s", s.name.c_str());
    st->via = s.via;
    st->battery = s.battery;
    st->mode = s.mode;
    st->project = s.project;
    st->playing = s.playing;
    st->ticking = s.ticking;
    st->inputs = s.inputs;
    st->leds = s.leds;
    st->screens = s.screens;
    st->connects = s.connects;
    st->seq_midi = s.seqMidi;
}

int rfmm_take_request(rfmm_t *m, rfmm_request_t *r, uint8_t *data, uint32_t cap)
{
    MoveLink::Request q;
    if (!L(m)->takeRequest(q))
        return 0;
    r->kind = q.kind;
    r->slot = q.slot;
    r->value = q.value;
    r->len = (uint32_t)std::min<size_t>(q.data.size(), data ? cap : 0);
    if (r->len)
        std::memcpy(data, q.data.data(), r->len);
    return 1;
}

void rfmm_projects_init(rfmm_t *m, uint32_t dir, int slot, const uint8_t *b, uint32_t n) { L(m)->projectsInit(dir, slot, bytes(b, n)); }
void rfmm_project_dir(rfmm_t *m, uint32_t bits) { L(m)->projectDir(bits); }
void rfmm_project_info(rfmm_t *m, int slot, const uint8_t *b, uint32_t n) { L(m)->projectInfo(slot, bytes(b, n)); }
void rfmm_project_answer(rfmm_t *m, int slot, const uint8_t *b, uint32_t n) { L(m)->projectAnswer(slot, bytes(b, n)); }
void rfmm_project_flush(rfmm_t *m) { L(m)->flushProject(); }
int rfmm_project_check(const uint8_t *b, uint32_t n) { return rfm_move_project_check(b, n); }

// the web's withColor (js/move-projects.js): byte 18, then the FNV-1a check over all but the last 4 bytes
void rfmm_project_with_color(uint8_t *b, uint32_t n, int color)
{
    if (!b || n < 23)
        return;
    b[18] = (uint8_t)color;
    uint32_t h = 2166136261u;
    for (uint32_t i = 0; i < n - 4; i++)
        h = (h ^ b[i]) * 16777619u;
    b[n - 4] = (uint8_t)h, b[n - 3] = (uint8_t)(h >> 8), b[n - 2] = (uint8_t)(h >> 16), b[n - 1] = (uint8_t)(h >> 24);
}

uint32_t rfmm_project_max(void) { return RFM_MOVE_PROJECT_MAX; }
uint32_t rfmm_settings_bytes(void) { return RFM_MOVE_SETTINGS_BYTES; }

int rfmm_test_empty_project(uint8_t *out, uint32_t cap)
{
    rfm_move_t *m = static_cast<rfm_move_t *>(std::calloc(1, sizeof(rfm_move_t)));
    rfm_move_settings_t st;
    rfm_move_settings_default(&st);
    rfm_move_init(m, &st, [](void *, const rfm_move_act_t *) {}, nullptr);
    rfm_move_project_load(m, 0, nullptr, 0);
    const int n = rfm_move_project_save(m, out, cap);
    std::free(m);
    return n;
}
