/* SPDX-License-Identifier: GPL-3.0-only */
/* Saadet's instrument (platform/instrument.c, MPL-2.0: the engines, the UI, storage, the editor), its own unit as
 * fm1-base's build compiles an fm1.toml "o2" unit, with the host build's flags: PLAT_HOST and fm1.toml's o2_cflags
 * (MELODEE_RAM_AUDIO=1). Its host build already renders the second core's half inline (MELODEE_DUAL_CORE 0). */
#define PLAT_HOST 1
#define MELODEE_RAM_AUDIO 1
#define APP_VERSION SAADET_APP_VERSION
#include "instrument.c"

/* flash_sync (core_saadet.c): what the device saves by itself once at rest (sound.c autosave_poll ->
 * state_autosave; not while playing) and a queued settings save (settings_poll), now. 1: the flash is current */
int saadet_core_sync(void)
{
    int ok = state_autosave();
    settings_poll();
    return ok && !persist_pending;
}
