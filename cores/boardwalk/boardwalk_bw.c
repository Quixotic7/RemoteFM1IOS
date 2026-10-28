/* SPDX-License-Identifier: GPL-3.0-only */
/* Boardwalk's sound engine (app/dsp/bw.c, MPL-2.0), its own unit as fm1-base's build compiles an fm1.toml "o2" unit,
 * with the host build's PLAT_HOST (its buffers in plain memory, not the device's .pool section). */
#define PLAT_HOST 1
#include "bw.c"
