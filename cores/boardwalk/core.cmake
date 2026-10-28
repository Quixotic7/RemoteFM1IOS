# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# Boardwalk (https://github.com/charlesvestal/fm1-boardwalk, the vendor/boardwalk submodule at v0.9, by Charles
# Vestal; MPL-2.0, its base/ = fm1-base at 4587fda without bsp/), with FM1VST's fm1-base glue (core-glue/fm1base,
# core-glue/plat) and this folder's unit. Not gated. BOARDWALK_DIR: the synced copy (scripts/build_cores.sh:
# build/cores/src/cores/boardwalk without mockups/, tests/ and base/bsp/).
#
# The sources are Boardwalk's host build's (./build.sh --host -> base/tools/build.py build_host): base/host/plat_host.c,
# which includes the app (app/app.c, the games, the scene, the art), and the o2 unit app/dsp/bw.c, with -I base/device
# base/include base/lib app app/build/gen app/dsp app/games (fm1.toml include). plat_host.c is replaced by fm1-base's
# device files as for AMB-1 (core_boardwalk.c). The generate step is the host build's: base's build.py generate() for
# app/ (app/build/gen: felucca_font.h, ann_words.h), as core_amb.cmake runs it.
set(BOARDWALK_DIR ${CMAKE_SOURCE_DIR}/cores/boardwalk)
if(NOT EXISTS ${BOARDWALK_DIR}/app/dsp/bw.c OR NOT EXISTS ${BOARDWALK_DIR}/base/host/plat_host.c)
    message(FATAL_ERROR "boardwalk core: no ${BOARDWALK_DIR}/app or base/ (run scripts/build_cores.sh)")
endif()
set(_bw ${BOARDWALK_DIR})
set(_bw_gen "(lambda b: (setattr(b, 'APP', b.Path('.').resolve()), setattr(b, 'CONF', b.read_conf(b.APP / 'fm1.toml')), setattr(b, 'GEN', b.APP / 'build' / 'gen'), b.generate()))(__import__('sys').path.insert(0, '../base/tools') or __import__('build'))")
set(_bw_inc ${_bw}/base/device ${_bw}/base/include ${_bw}/base/lib ${_bw}/app ${_bw}/app/build/gen ${_bw}/app/dsp
            ${_bw}/app/games ${_glue}/fm1base ${_glue}/plat)
fm1_add_core(boardwalk ${CMAKE_CURRENT_LIST_DIR} SOURCE ${_bw}
             UNIT core_boardwalk.c DESC boardwalk_desc.c EXTRA_SOURCES boardwalk_bw.c
             FAMILY fm1base LICENSE MPL-2.0
             GEN felucca_font.h ann_words.h GEN_ROOT app GEN_PYTHON "${_bw_gen}" PYTHON_NEEDS raqm
             VERSION 0.9
             FLAGS -ffp-contract=off
             INCLUDES ${_bw_inc}
             CREDITS "Boardwalk, a seaside arcade of music games for the FM-1, by Charles Vestal. MPL-2.0, the source: https://github.com/charlesvestal/fm1-boardwalk (LICENSING.md says where everything comes from).\nThe sound engine's reverb is Dattorro's plate, from FoMni-1. The songs in Tiles and the cabinets' tunes are traditional or by composers long out of copyright, arranged by Charles Vestal. Change ringing's place notations are facts from the Central Council of Church Bell Ringers' collection.\nBuilt on fm1-base (Charles Vestal) and felucca-bsp, from Felucca by Leo Kuroshita (@kurogedelic), Hügelton Instruments, under MPL-2.0 with his permission (felucca-bsp issue 4). fm1-base's announce.c is MIT.\nThe idea of a browser emulator for FM-1 firmware: Groove OS by Peter Gombos (no code from it).\nType: Barlow Semi Condensed (The Barlow Project Authors) and Terminus (Dimitar Toshkov Zhekov), SIL Open Font License 1.1."
             CREDITS_FILES ./LICENSE base/assets/fonts/Barlow-OFL.txt base/assets/fonts/Terminus-LICENSE.txt)
# the host build's include order (fm1_add_core puts app/build/gen first)
target_include_directories(core_boardwalk_obj BEFORE PRIVATE ${_bw_inc})
set_source_files_properties(${CMAKE_CURRENT_LIST_DIR}/boardwalk_bw.c TARGET_DIRECTORY core_boardwalk_obj
                            PROPERTIES COMPILE_OPTIONS "-w;-ffp-contract=off")
