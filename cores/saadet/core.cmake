# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# Saadet (https://github.com/keremimo/saadet, the vendor/saadet submodule at v0.1.1, by Kerem Kilic; MPL-2.0 in its
# fm1-base build) on fm1-base (vendor/fm1-base at Saadet's pin, tools/build_base.py REV 6c0b47e4bfc5; its bsp/ is
# not needed), with FM1VST's fm1-base glue (core-glue/fm1base, core-glue/plat) and this folder's unit. Not gated.
# SAADET_DIR: the synced copy (scripts/build_cores.sh: build/cores/src/cores/saadet without tests/ and docs/, and
# fm1-base as its base/).
#
# The sources are Saadet's host build's (./build.sh --host -> tools/build_base.py -> fm1-base's tools/build.py
# build_host): base/host/plat_host.c, which includes the app (platform/app.c and what it includes), and the o2 unit
# platform/instrument.c (-DPLAT_HOST -DMELODEE_RAM_AUDIO=1, fm1.toml's o2_cflags), with -I base/device base/include
# base/lib platform platform/build/gen firmware/src build/gen. plat_host.c is replaced by fm1-base's device files as
# for AMB-1 (core_saadet.c says which and why). The generate step is the host build's: Saadet's
# tools/generate_assets.py (build/gen: fonts, palettes, tables, the FM6, CZ-1, JUNO-106 and Prophet banks) and
# fm1-base's build.py generate() for platform/ (platform/build/gen: felucca_font.h, ann_words.h), one expression.
#
# Two cores from the one tree and generate step: saadet (the full build) and saadet_store (the App Store build:
# SAADET_STORE, the same core id "saadet", version 0.1.1-store, store/'s empty factory banks ahead of build/gen;
# build_cores.sh puts it in frameworks-store/ as FM1Core_saadet_<n>).
set(SAADET_DIR ${CMAKE_SOURCE_DIR}/cores/saadet)
if(NOT EXISTS ${SAADET_DIR}/platform/instrument.c OR NOT EXISTS ${SAADET_DIR}/base/host/plat_host.c)
    message(FATAL_ERROR "saadet core: no ${SAADET_DIR}/platform/instrument.c or base/ (run scripts/build_cores.sh)")
endif()
set(_sd ${SAADET_DIR})
set(_sd_gen "(__import__('generate_assets').generate(), (lambda b: (setattr(b, 'APP', b.Path('platform').resolve()), setattr(b, 'CONF', b.read_conf(b.APP / 'fm1.toml')), setattr(b, 'GEN', b.APP / 'build' / 'gen'), b.generate()))(__import__('sys').path.insert(0, 'base/tools') or __import__('build')))")
set(_sd_inc ${_sd}/base/device ${_sd}/base/include ${_sd}/base/lib ${_sd}/platform ${_sd}/platform/build/gen
            ${_sd}/build/gen ${_sd}/firmware/src ${_glue}/fm1base ${_glue}/plat)
set(_sd_credits_common "Saadet, a single-part synthesizer firmware for the M-VAVE FM-1, by Kerem Kilic (Ellic Studio): a Melodee fork rebuilt on fm1-base. MPL-2.0 file by file (the FM6 files MPL-2.0 AND Apache-2.0), the source: https://github.com/keremimo/saadet (LICENSING.md says what is under which licence).\nIt keeps Felucca code by Leo Kuroshita (@kurogedelic), Hügelton Instruments, used under MPL-2.0 by his permission (felucca-bsp issue 4), and keremimo's Felucca MIDI clock and TRS commits, granted under MPL-2.0 (felucca-bsp pull request 3).\nfm1-base by Charles Vestal (MPL-2.0, announce.c MIT).\nThird parties: DX7 synthesis from MSFA (Google Inc., Pascal Gauthier, Jean Pierre Cimalando, Apache-2.0), DaisySP (Electrosmith, Corp and Emilie Gillet, MIT) and Rings (Emilie Gillet, MIT) in the PHYS engine, MAME's uPD933 model (Devin Acker, BSD-3-Clause) in CZ-1, klattsch (Tony Gies, MIT) as the VOICE engine's design reference, no code copied.\nType: Archivo (The Archivo Project Authors), Barlow Semi Condensed (The Barlow Project Authors) and Terminus (Dimitar Toshkov Zhekov), SIL Open Font License 1.1.")
set(_sd_credit_files ./LICENSE LICENSES/Apache-2.0-msfa.txt LICENSES/MIT-DaisySP.txt LICENSES/MIT-Rings.txt
                     LICENSES/BSD-3-Clause-uPD933.txt LICENSES/OFL-Archivo.txt base/assets/fonts/Barlow-OFL.txt
                     base/assets/fonts/Terminus-LICENSE.txt)
set(_sd_gen_h ui_fonts.h ui_palettes.h melodee_tables.h melodee_fm6.h melodee_cz1.h melodee_j106.h
              melodee_prophet_factory.h)

fm1_add_core(saadet ${CMAKE_CURRENT_LIST_DIR} SOURCE ${_sd}
             UNIT core_saadet.c DESC saadet_desc.c EXTRA_SOURCES saadet_instrument.c
             FAMILY fm1base LICENSE MPL-2.0
             GEN ${_sd_gen_h} GEN_OUTPUTS platform/build/gen/felucca_font.h platform/build/gen/ann_words.h
             GEN_PYTHON "${_sd_gen}" PYTHON_NEEDS raqm fontTools
             VERSION 0.1.1
             FLAGS -ffp-contract=off
             DEFINES SAADET_APP_VERSION="0.1.1"
             INCLUDES ${_sd_inc}
             CREDITS "${_sd_credits_common}\nFactory sound data: Roland's Juno-106 factory patches (Roland Corporation, 1984), Sequential's Prophet-5/10 factory programs v1.03 (Sequential, 2025) and Casio's CZ-1 preset tones (Casio Computer Co., Ltd., 1986) are included as sound data for compatibility. They remain those companies' property, no licence is granted for them."
             CREDITS_FILES ${_sd_credit_files})
fm1_add_core(saadet_store ${CMAKE_CURRENT_LIST_DIR} SOURCE ${_sd}
             UNIT core_saadet.c DESC saadet_store_desc.c EXTRA_SOURCES saadet_instrument.c
             FAMILY fm1base LICENSE MPL-2.0
             GEN ${_sd_gen_h} GEN_OUTPUTS platform/build/gen/felucca_font.h platform/build/gen/ann_words.h
             GEN_PYTHON "${_sd_gen}" PYTHON_NEEDS raqm fontTools
             VERSION 0.1.1-store
             FLAGS -ffp-contract=off
             DEFINES SAADET_APP_VERSION="0.1.1" SAADET_STORE=1
             INCLUDES ${_sd_inc}
             CREDITS "${_sd_credits_common}\nThis build's JUNO-106, PROPHET and CZ-1 engines start from their init sounds, it has no factory banks for them."
             CREDITS_FILES ${_sd_credit_files})
# the host build's include order (fm1_add_core puts build/gen and firmware/src first, whose gfx.c, panel.c and
# storage.c are the retired platform's, not fm1-base's device/ files); the store variant's empty factory banks ahead
# of all
target_include_directories(core_saadet_obj BEFORE PRIVATE ${_sd_inc})
target_include_directories(core_saadet_store_obj BEFORE PRIVATE ${_sd_inc})
target_include_directories(core_saadet_store_obj BEFORE PRIVATE ${CMAKE_CURRENT_LIST_DIR}/store)
# instrument.c is Saadet's code: warnings off and the host build's float contract, as for the unit
set_source_files_properties(${CMAKE_CURRENT_LIST_DIR}/saadet_instrument.c TARGET_DIRECTORY core_saadet_obj
                            PROPERTIES COMPILE_OPTIONS "-w;-ffp-contract=off")
