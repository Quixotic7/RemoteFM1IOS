/* SPDX-License-Identifier: GPL-3.0-only */
/* The store variant's stand-in for Saadet's generated melodee_j106.h (tools/gen_j106_factory.py: Roland's 128
 * Juno-106 factory patches, for which no licence is granted): no patches. JUNO-106's presets are INIT TONE only
 * (eng_j106.c: k > J106_FACTORY_N returns, the name "INIT TONE"). Included ahead of build/gen. */
#define SAADET_STORE_NO_J106 1
#define J106_FACTORY_N 0u
static const struct { char name[J106_NAME_LEN + 1u]; uint8_t raw[J106_RAW]; } J106_FACTORY[1] = {{"INIT TONE", {0}}};
