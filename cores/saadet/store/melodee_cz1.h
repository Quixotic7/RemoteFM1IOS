/* SPDX-License-Identifier: GPL-3.0-only */
/* The store variant's stand-in for Saadet's generated melodee_cz1.h (tools/gen_cz1_factory.py: Casio's 64 CZ-1
 * preset tones, for which no licence is granted): no tones. CZ-1's presets are INIT TONE only and its default banks
 * A..D start empty, as E..H do (cz_bank.c). eng_cz.c's cz_factory, which unpacks tone k, is never reached
 * (k < CZ_FACTORY_N is false). Included ahead of build/gen (cores/saadet/core.cmake). */
#define SAADET_STORE_NO_CZ1 1
#define CZ_FACTORY_N 0u
static const uint8_t CZ_DICT[144] = {0};
static const uint16_t CZ_LZ_AT[1] = {0};
static const uint8_t CZ_LZ[1] = {0};
static const struct { uint8_t k; char name[13]; } CZ_SHORT[1] = {{255u, ""}};
