# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# LOOM-8 (https://github.com/charlesvestal/fm1-loom, the vendor/loom submodule at v0.9.3, by Charles Vestal; MPL-2.0
# since 0.8, its base/ = fm1-base at d0133c2 without bsp/), with FM1VST's fm1-base glue (core-glue/fm1base,
# core-glue/plat) and this folder's unit, after FM1VST's LOOM-8 0.6.1 core (core-glue/fm1base/core_loom.*). Not gated.
# LOOM_DIR: the synced copy (scripts/build_cores.sh: build/cores/src/cores/loom without docs/, tests/, base/bsp/ and
# app/samples/909_hat.wav).
#
# The sources are LOOM-8's host build's (./build.sh --host -> base/tools/build.py build_host): base/host/plat_host.c,
# which includes the app (app/app.c), and fm1.toml's o2 units (dsp/synth.c, drumline.c, digisophie.c, sample.c, fx.c,
# bench.c, seq/pattern.c, seq/seq.c), with -I base/device base/include base/lib app app/build/gen (and each o2 unit's
# own folder). plat_host.c is replaced by fm1-base's device files, and app/plat_loom.c by loom_plat.c, as in FM1VST's
# LOOM-8 core (core_loom.c says why).
#
# The 909 closed hat (app/samples/909_hat.wav, GPL-3.0: ER-99's sample through 9W9) is not in this build, as it is not
# in LOOM-8's firmware image: build_cores.sh does not copy it, and the generate step makes samples.h with
# gen_samples_rfm.py (LOOM-8's gen_samples.py, its hat row empty) in place of fm1.toml's gen line for gen_samples.py.
# The rest of the generate step is LOOM-8's host build's: base's build.py generate() for app/ (its fonts, the
# wavetables, the build's number, the presets, the kits; felucca_font.h, ann_words.h).
set(LOOM_DIR ${CMAKE_SOURCE_DIR}/cores/loom)
if(NOT EXISTS ${LOOM_DIR}/app/app.c OR NOT EXISTS ${LOOM_DIR}/base/host/plat_host.c)
    message(FATAL_ERROR "loom core: no ${LOOM_DIR}/app or base/ (run scripts/build_cores.sh)")
endif()
if(EXISTS ${LOOM_DIR}/app/samples/909_hat.wav)
    message(FATAL_ERROR "loom core: ${LOOM_DIR}/app/samples/909_hat.wav is there (GPL-3.0; never in this build)")
endif()
set(_lm ${LOOM_DIR})
set(_lm_gen "(lambda b: (setattr(b, 'APP', b.Path('.').resolve()), setattr(b, 'CONF', b.read_conf(b.APP / 'fm1.toml')), b.CONF.__setitem__('gen', [g for g in b.CONF['gen'] if 'gen_samples.py' not in g]), setattr(b, 'GEN', b.APP / 'build' / 'gen'), b.generate()))(__import__('sys').path.insert(0, '../base/tools') or __import__('build'))")
set(_lm_inc ${_lm}/base/device ${_lm}/base/include ${_lm}/base/lib ${_lm}/app ${_lm}/app/build/gen ${_lm}/app/dsp
            ${_lm}/app/seq ${_glue}/fm1base ${_glue}/plat)
set(_lm_vfs ${CMAKE_BINARY_DIR}/core_vfs/loom.yaml)
file(WRITE ${_lm_vfs}.in "{ \"version\": 0, \"case-sensitive\": \"false\", \"roots\": [ { \"type\": \"file\", \"name\": \"${_lm}/app/plat_loom.c\", \"external-contents\": \"${CMAKE_CURRENT_LIST_DIR}/loom_plat.c\" } ] }\n")
configure_file(${_lm_vfs}.in ${_lm_vfs} COPYONLY)
fm1_add_core(loom ${CMAKE_CURRENT_LIST_DIR} SOURCE ${_lm}
             UNIT core_loom.c DESC loom_desc.c
             EXTRA_SOURCES loom_synth.c loom_drumline.c loom_digisophie.c loom_sample.c loom_fx.c loom_bench.c
                           loom_seq_pattern.c loom_seq_seq.c
             FAMILY fm1base LICENSE MPL-2.0
             GEN ann_words.h felucca_font.h loom_font.h wavetables.h samples.h loom_build.h presets.h kits.h
             GEN_ROOT app GEN_PYTHON "${_lm_gen}"
             EXTRA_GEN "${CMAKE_CURRENT_LIST_DIR}/gen_samples_rfm.py ../tools build/gen/samples.h"
             PYTHON_NEEDS raqm numpy
             VERSION 0.9.3
             FLAGS -ffp-contract=off "-ivfsoverlay${_lm_vfs}"
             INCLUDES ${_lm_inc}
             CREDITS "LOOM-8, a pocket groovebox for the FM-1 inspired by the OP-XY, by Charles Vestal. MPL-2.0, the source: https://github.com/charlesvestal/fm1-loom (LICENSING.md, below, says where everything comes from). Not affiliated with teenage engineering.\nBuilt on fm1-base and felucca-bsp (MPL-2.0), from Felucca by Leo Kuroshita (@kurogedelic), Hügelton Instruments, under MPL-2.0 with his permission (felucca-bsp issue 4), with keremimo's dual-core audio (felucca-bsp pull request 5). fm1-base's announce.c is MIT.\nThe plate reverb, after 9W9's reverb, and the factory 909 kick, snare and clap, renders of 9W9: by athousanddetails, used under MPL-2.0 with his permission. This build has no 909 closed hat (its sample is GPL-3.0 and not part of LOOM-8's firmware).\nFactory breaks: free loops by u/FCTRYBEATS, used with their permission (in the user sample bank, not built in). Recorded instruments: Versilian Studios Chamber Orchestra 2 Community Edition (VSCO 2 CE, CC0 1.0). Samples kept as IMA ADPCM (the IMA's 1992 recommended practice).\nMIT: Mutable Instruments Braids (Emilie Gillet), NuSaw and schwung-psxverb (Charles Vestal), MACHINEDRUM (Branislav Đalić), Sophie and digisophie (Matt Estela and the digisophie contributors), their notices in LICENSING.md below.\nThe idea of a browser emulator for FM-1 firmware: Groove OS by Peter Gombos (no code from it).\nType: Barlow Semi Condensed (The Barlow Project Authors) and Terminus (Dimitar Toshkov Zhekov), SIL Open Font License 1.1."
             CREDITS_FILES ./LICENSE LICENSING.md base/assets/fonts/Barlow-OFL.txt base/assets/fonts/Terminus-LICENSE.txt)
# the host build's include order (fm1_add_core puts app/build/gen first)
target_include_directories(core_loom_obj BEFORE PRIVATE ${_lm_inc})
# (the overlay's file: the unit's dependency, which the compiler's depfile also names)
set_property(SOURCE ${CMAKE_CURRENT_LIST_DIR}/core_loom.c APPEND PROPERTY OBJECT_DEPENDS
             ${CMAKE_CURRENT_LIST_DIR}/loom_plat.c ${_lm_vfs})
# the o2 units are LOOM-8's code: warnings off and the host build's float contract, as for the unit
foreach(_u loom_synth.c loom_drumline.c loom_digisophie.c loom_sample.c loom_fx.c loom_bench.c loom_seq_pattern.c
           loom_seq_seq.c)
    set_source_files_properties(${CMAKE_CURRENT_LIST_DIR}/${_u} TARGET_DIRECTORY core_loom_obj
                                PROPERTIES COMPILE_OPTIONS "-w;-ffp-contract=off")
endforeach()
