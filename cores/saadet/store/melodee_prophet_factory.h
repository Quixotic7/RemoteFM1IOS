/* SPDX-License-Identifier: GPL-3.0-only */
/* The store variant's stand-in for Saadet's generated melodee_prophet_factory.h (tools/gen_prophet_factory.py:
 * Sequential's 200 Prophet-5/10 v1.03 factory programs, for which no licence is granted): no programs. PROPHET's
 * presets are its init program only (eng_prophet_test.c: pi <= P5_FACTORY_N false -> p5_patch_init); its native
 * user slots start empty as they do anyway. Included ahead of build/gen. */
#pragma once
#define SAADET_STORE_NO_P5 1
#define P5_FACTORY_N 0u
#define P5_FACTORY_BYTES 55u
static const uint8_t P5_FBASE[P5_RAW_MAX] = {0};
static const uint8_t P5_FWIDTH[P5_RAW_MAX] = {0};
static const uint8_t P5_FPACK[P5_FACTORY_BYTES] = {0};
