# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# FIZZ (https://github.com/Quixotic7/FIZZ, the vendor/FIZZ submodule; MPL-2.0, the owner's), the FM TONE step
# sequencer. From FM1VST's branch core-quadrille (core-glue/fizz/core.cmake), not gated. The glue is FIZZ's own
# (core/glue); the descriptor goes through fizz_desc.c here (its source_url). FIZZ_DIR: the synced copy
# (scripts/build_cores.sh: build/cores/src/cores/FIZZ, without site/ and core/tests/, which are GPL).
#
# The units are FIZZ's tools/Makefile CORE_SRC with GFX=plutovg (the host's drawing): every other .c in core/ is
# included by one of them (app.c: store, persist, undo, fizz_sx, midi_map; ctl_latch.c: ctl_snd, ctl_mix, ctl_presets,
# ctl_lib, ctl_type, ctl_shift, ctl_mfx, ctl_tools; view.c: view_labels; ui_layer.c and ui_turn.c: the other ui_*;
# pattern.c: tools; sounds.c: names; player.c: mfx; quad_voice.c: eng_quad, quad_ext; qd_fx.c: fz_out, cr_fx;
# qd_gfx_plutovg.c: qd_arena, qd_gfx_rec), and plutovg's source/*.c.
set(FIZZ_DIR ${CMAKE_SOURCE_DIR}/cores/FIZZ)
if(NOT EXISTS ${FIZZ_DIR}/core/glue/core_quadrille.c)
    message(FATAL_ERROR "fizz core: no ${FIZZ_DIR}/core/glue/core_quadrille.c (run scripts/build_cores.sh)")
endif()
set(_qd ${FIZZ_DIR})
set(_qd_glue ${_qd}/core/glue)
set(_qd_pvg ${_qd}/third_party/plutovg/source)
set(_qd_pvg_sources plutovg-blend.c plutovg-canvas.c plutovg-font.c plutovg-ft-math.c plutovg-ft-raster.c
                    plutovg-ft-stroker.c plutovg-matrix.c plutovg-paint.c plutovg-path.c plutovg-rasterize.c
                    plutovg-surface.c)
file(GLOB _qd_pvg_found RELATIVE ${_qd_pvg} ${_qd_pvg}/*.c)
list(SORT _qd_pvg_found)
if(NOT _qd_pvg_found STREQUAL _qd_pvg_sources)
    message(FATAL_ERROR "fizz core: plutovg's sources changed (${_qd_pvg_found}): update cores/fizz/core.cmake")
endif()
list(TRANSFORM _qd_pvg_sources PREPEND ../../third_party/plutovg/source/)   # (EXTRA_SOURCES: glue dir relative)
set(_qd_sources ../app/app.c ../app/ctl.c ../app/ctl_step.c ../app/ctl_rec.c ../app/ctl_leds.c ../app/ctl_latch.c
                ../app/ctl_preview.c ../app/view.c
                ../ui/ui_kit.c ../ui/ui_idle.c ../ui/ui_keys.c ../ui/ui_picker.c ../ui/ui_tracks.c ../ui/ui_lane.c
                ../ui/ui_held.c ../ui/ui_turn.c ../ui/ui_layer.c ../ui/ui_octave.c
                ../gfx/qd_gfx_plutovg.c
                ../seq/model.c ../seq/pattern.c ../seq/seq.c ../seq/player.c ../seq/demo.c ../seq/chord.c
                ../seq/scale.c ../seq/sounds.c ../seq/clip.c
                ../voice/quad/quad_voice.c ../voice/pool.c ../voice/mix.c ../voice/fx/qd_fx.c)
file(RELATIVE_PATH _qd_desc ${_qd_glue} ${CMAKE_CURRENT_LIST_DIR}/fizz_desc.c)
fm1_add_core(fizz ${_qd_glue} SOURCE ${_qd}
             UNIT core_quadrille.c DESC ${_qd_desc}
             EXTRA_SOURCES ${_qd_sources} ${_qd_pvg_sources}
             INCLUDES ${_qd_glue} ${_qd}/core ${_qd}/core/app ${_qd}/core/ui ${_qd}/core/gfx ${_qd}/core/seq
                      ${_qd}/core/voice ${_qd}/core/voice/quad ${_qd}/core/voice/fx ${_qd}/third_party/plutovg/include
                      ${_qd_pvg}
             DEFINES PLUTOVG_BUILD PLUTOVG_BUILD_STATIC PLUTOVG_DISABLE_FONT_FACE_CACHE_LOAD
             FAMILY fizz LICENSE MPL-2.0
             CREDITS "FIZZ, an FM TONE step sequencer for the FM-1, by Michael P Jones (Quixotic7). MPL-2.0, the source: https://github.com/Quixotic7/FIZZ (LICENSING.md says what is under which licence).\nFM TONE, the effects and the output chain: from ChoralRoot FM-1 v0.25.1, the owner's, relicensed MPL-2.0, and the parts that came from Felucca were rewritten (L1).\nDrawn with plutovg v1.3.3 (Samuel Ugochukwu, MIT), which carries stb_truetype, stb_image and stb_image_write (Sean Barrett, MIT or Unlicense). Portions of this software are copyright (c) 2006 The FreeType Project (www.freetype.org). All rights reserved.\nType: Inter Tight (The Inter Project Authors, SIL Open Font License 1.1)."
             CREDITS_FILES ./LICENSE third_party/plutovg/LICENSE third_party/plutovg/source/FTL.TXT assets/fonts/OFL.txt
             NO_GEN
             VERSION 0.12.0-beta.12)
# plutovg is vendored and patched by FIZZ (third_party/README.md): its warnings are not FIZZ's
set(_qd_pvg_abs ${_qd_pvg_sources})
list(TRANSFORM _qd_pvg_abs PREPEND ${_qd_glue}/)
set_source_files_properties(${_qd_pvg_abs} TARGET_DIRECTORY core_fizz_obj PROPERTIES COMPILE_OPTIONS "-w")
