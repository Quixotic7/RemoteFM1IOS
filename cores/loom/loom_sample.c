/* SPDX-License-Identifier: GPL-3.0-only */
/* LOOM-8's app/dsp/sample.c (MPL-2.0) as its own unit, unmodified. PLAT_HOST, as its host simulator builds it: the
 * factory set built in (SMP_FACT_BUILTIN; the FM-1's image leaves it out since 0.8 and plays the copies its installer
 * puts in the user bank, which a core's flash does not have). samples.h is gen_samples_rfm.py's: the 909 closed hat's
 * row empty, as in the FM-1's image (its sample is GPL-3.0 and not in this build). sample.c uses PLAT_HOST only for
 * that. */
#define PLAT_HOST 1
#include "dsp/sample.c"
