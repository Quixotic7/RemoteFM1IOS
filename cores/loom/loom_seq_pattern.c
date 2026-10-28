/* SPDX-License-Identifier: GPL-3.0-only */
/* LOOM-8's app/seq/pattern.c (MPL-2.0) as its own unit, unmodified, as fm1-base's build.py builds an fm1.toml "o2"
 * unit for the host simulator: PLAT_HOST (the simulator's voice order, buffers in plain memory, not the .pool section) */
#define PLAT_HOST 1
#include "seq/pattern.c"
