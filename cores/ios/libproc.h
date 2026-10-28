/* SPDX-License-Identifier: GPL-3.0-only */
/* Copyright (C) 2026 RemoteFM1 contributors */
/* iOS has no <libproc.h> (proc_pid_rusage is private there). ChoralRoot's host build includes it under __APPLE__ for
 * its debug profiler only (firmware/src/cr_cpu1.h cr_prof_now, used while the profiler page is on); this stand-in
 * fails the call, so cr_prof_now gives 0 as on every non-Apple host. Put on the include path of the iOS builds only
 * (cores/CMakeLists.txt). */
#pragma once
#include <sys/resource.h>
static inline int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer)
{
    (void)pid;
    (void)flavor;
    (void)buffer;
    return -1;
}
