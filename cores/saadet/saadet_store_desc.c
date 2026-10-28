/* SPDX-License-Identifier: GPL-3.0-only */
/* The store variant's descriptor: the same core as saadet_desc.c, the same id (saved states and the picker see one
 * Saadet), its own version (0.1.1-store) and credits (core.cmake). */
#include "version.h"
#undef FM1CORE_ID
#define FM1CORE_ID "saadet"
#include "saadet_desc.c"
