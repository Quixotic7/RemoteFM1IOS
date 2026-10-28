# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 RemoteFM1 contributors
# The FM-1 cores for RemoteFM1 iOS: ChoralRoot, Felucca, Melodee, FIZZ and Saadet through FM1VST's fm1_add_core() (cmake/FM1Cores.cmake)
# and their glue (core-glue/), without FM1VST's top CMakeLists (it fetches JUCE). One SHARED library per core,
# FM1Core_<id>, from the core's objects, exporting only _fm1core_get; scripts/build_cores.sh turns it into the four slot
# frameworks (PLAN.md section 3).
#
# Not configured from here directly: scripts/build_cores.sh copies this file, the parts of vendor/FM1VST it needs and
# the firmware trees into build/cores/src, laid out as in FM1VST, and configures that: the generate steps write
# into <tree>/build/gen, which must not land in vendor/, and the glue reaches the firmware by relative paths and as
# ${CMAKE_SOURCE_DIR}/cores/<name>. RFM_FM1VST is that copy (the source dir).
cmake_minimum_required(VERSION 3.22)
project(RemoteFM1Cores LANGUAGES C CXX)

set(RFM_FM1VST ${CMAKE_SOURCE_DIR} CACHE PATH "a copy of vendor/FM1VST's cmake, core-api, core-glue, engine, tests")
if(NOT EXISTS ${RFM_FM1VST}/cmake/FM1Cores.cmake)
    message(FATAL_ERROR "RFM_FM1VST (${RFM_FM1VST}) is not FM1VST: run scripts/build_cores.sh")
endif()
set(CR_PYTHON "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3" CACHE FILEPATH
    "python3 with Pillow and fontTools, for the cores' generate steps")
set(RFM_CORES "choralroot;felucca;melodee;fizz;saadet" CACHE STRING "the cores to build")
# iOS: ChoralRoot's host build includes <libproc.h> (its profiler's instruction counter), which the iOS SDKs lack:
# cores/ios/libproc.h stands in for it. FIZZ's build file is cores/fizz/core.cmake, Saadet's
# cores/saadet/core.cmake (two cores: saadet and its store variant saadet_store, the same core id). (RFM_OWN: this repo's cores/ folder)
set(RFM_OWN "" CACHE PATH "the repo's cores/ folder (cores/ios: the iOS stand-in headers; cores/fizz)")

include(${RFM_FM1VST}/cmake/FM1Cores.cmake)
set(_glue ${RFM_FM1VST}/core-glue)
# (crf.cmake's golden tests are deferred to the end of this directory; they need FM1VST's reference emulator target,
# which is not here, so they skip themselves)
if(choralroot IN_LIST RFM_CORES)
    include(${_glue}/choralroot/core_choralroot.cmake)
endif()
if(felucca IN_LIST RFM_CORES)
    include(${_glue}/felucca_web/core_felucca.cmake)
endif()
if(melodee IN_LIST RFM_CORES)
    include(${_glue}/melodee/core.cmake)
endif()
if(fizz IN_LIST RFM_CORES)
    include(${RFM_OWN}/fizz/core.cmake)
endif()
if(saadet IN_LIST RFM_CORES)
    include(${RFM_OWN}/saadet/core.cmake)
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND TARGET core_choralroot_obj)
    target_include_directories(core_choralroot_obj BEFORE PRIVATE ${RFM_OWN}/ios)
endif()
message(STATUS "cores: ${FM1_CORE_IDS} (${CMAKE_SYSTEM_NAME} ${CMAKE_OSX_SYSROOT} ${CMAKE_OSX_ARCHITECTURES})")

# per core: FM1Core_<id> (lib/libFM1Core_<id>.dylib), the same objects as FM1VST's <id>.fm1core. The header pad lets
# install_name_tool give each slot its own install name.
foreach(_id IN LISTS FM1_CORE_IDS)
    add_library(FM1Core_${_id} SHARED $<TARGET_OBJECTS:core_${_id}_obj>)
    set_target_properties(FM1Core_${_id} PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib
        INSTALL_NAME_DIR "@rpath")
    target_link_options(FM1Core_${_id} PRIVATE -Wl,-exported_symbol,_fm1core_get -Wl,-headerpad_max_install_names
                        -Wl,-dead_strip)
    get_property(_ver GLOBAL PROPERTY FM1_CORE_VERSION_${_id})
    get_property(_commit GLOBAL PROPERTY FM1_CORE_COMMIT_${_id})
    string(APPEND _manifest "${_id} ${_ver} ${_commit}\n")
endforeach()
file(WRITE ${CMAKE_BINARY_DIR}/cores.txt "${_manifest}")

# macOS only: FM1VST's conformance test (tests/core_conformance.cpp) over our libraries: ctest -R core_conformance
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    enable_testing()
    add_library(fm1engine STATIC ${RFM_FM1VST}/engine/cores.cpp ${RFM_FM1VST}/engine/device.cpp)
    target_include_directories(fm1engine PUBLIC ${RFM_FM1VST}/engine ${RFM_FM1VST}/core-api)
    target_compile_features(fm1engine PUBLIC cxx_std_17)
    add_library(fm1testlib STATIC ${RFM_FM1VST}/tests/script_runner.cpp)
    target_link_libraries(fm1testlib PUBLIC fm1engine)
    target_include_directories(fm1testlib PUBLIC ${RFM_FM1VST}/tests ${FM1_COMMON_DIR})
    target_compile_definitions(fm1testlib PUBLIC FM1_CR_DIR="" FM1_CORE_MODULE="" FM1_REF_EMU="" FM1_CORES_BUILD_DIR=""
        FM1_BUILT_CORES="" FM1_REF_OUT="" FM1_SOURCE_DIR="${RFM_FM1VST}")
    add_executable(core_conformance EXCLUDE_FROM_ALL ${RFM_FM1VST}/tests/core_conformance.cpp)
    target_link_libraries(core_conformance PRIVATE fm1testlib)
    file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/conformance)
    foreach(_id IN LISTS FM1_CORE_IDS)
        get_property(_g GLOBAL PROPERTY FM1_CORE_GLUE_${_id})
        get_property(_fam GLOBAL PROPERTY FM1_CORE_FAMILY_${_id})
        get_property(_lic GLOBAL PROPERTY FM1_CORE_LICENSE_${_id})
        set(_conf ${_g}/conformance_${_id}.txt)
        if(NOT EXISTS ${_conf})
            set(_conf ${_g}/conformance.txt)
        endif()
        string(REGEX REPLACE "_store$" "" _cid ${_id})     # (a store variant has its core's id)
        add_test(NAME core_conformance_${_id}
                 COMMAND core_conformance $<TARGET_FILE:FM1Core_${_id}> ${_cid} ${_fam} ${_lic} ${_conf}
                         ${CMAKE_BINARY_DIR}/conformance)
        set_tests_properties(core_conformance_${_id} PROPERTIES TIMEOUT 300
                             ENVIRONMENT "FM1EMU_HOME=${CMAKE_BINARY_DIR}/conformance/home")
    endforeach()
endif()
