/* SPDX-License-Identifier: GPL-3.0-only */
/* Copyright (C) 2026 RemoteFM1 contributors */
/* FM1VST's coroutine (core-glue/common/coro.h) for iOS, without ucontext. FM1VST's coro.c switches stacks with
 * getcontext / makecontext / swapcontext, which work on macOS but not on an iPhone: Melodee (the one built-in core
 * whose main loop runs on a coroutine) booted to its splash and never drew again there (2026-10-31). This does the
 * same with a small arm64 switch: the callee-saved registers (x19-x30, d8-d15) pushed on the old stack, sp swapped,
 * popped from the new one. x18 (the platform register on Apple) is left alone; no signal mask is saved.
 * Same API and behaviour as coro.c: an mmap'ed stack with a PROT_NONE guard page below it, one level only, park. */
#define _DARWIN_C_SOURCE 1                      /* (MAP_ANON) */
#include "coro.h"

#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if !defined(__aarch64__)
#error "coro_arm64.c is for arm64 (iOS device and Apple-silicon simulator)"
#endif

#define FILL 0xA5u
#define FRAME 160u                              /* x19-x30 (12 x 8) + d8-d15 (8 x 8) */

struct fm1coro {
    void *sp;                                   /* the coroutine's saved stack pointer */
    void *back;                                 /* the resumer's */
    void (*fn)(void *);
    void *arg;
    uint8_t *map;                               /* the mapping: guard page + stack */
    size_t map_len, page, stack_len;
    int done;
    uint32_t resumes;
};

static fm1coro_t *cur;                          /* the coroutine running now, or NULL */

/* saves the callee-saved registers on this stack, stores sp in *from, switches to `to` and restores its registers;
 * returns (ret) on the other stack, where that one last called it (or into fm1coro_entry the first time) */
__attribute__((naked, noinline)) static void coro_switch(void **from, void *to)
{
    __asm__ volatile(
        "sub sp, sp, #160\n"
        "stp x19, x20, [sp, #0]\n"
        "stp x21, x22, [sp, #16]\n"
        "stp x23, x24, [sp, #32]\n"
        "stp x25, x26, [sp, #48]\n"
        "stp x27, x28, [sp, #64]\n"
        "stp x29, x30, [sp, #80]\n"
        "stp d8, d9, [sp, #96]\n"
        "stp d10, d11, [sp, #112]\n"
        "stp d12, d13, [sp, #128]\n"
        "stp d14, d15, [sp, #144]\n"
        "mov x9, sp\n"
        "str x9, [x0]\n"
        "mov sp, x1\n"
        "ldp x19, x20, [sp, #0]\n"
        "ldp x21, x22, [sp, #16]\n"
        "ldp x23, x24, [sp, #32]\n"
        "ldp x25, x26, [sp, #48]\n"
        "ldp x27, x28, [sp, #64]\n"
        "ldp x29, x30, [sp, #80]\n"
        "ldp d8, d9, [sp, #96]\n"
        "ldp d10, d11, [sp, #112]\n"
        "ldp d12, d13, [sp, #128]\n"
        "ldp d14, d15, [sp, #144]\n"
        "add sp, sp, #160\n"
        "ret\n");
}

/* the coroutine's first frame returns here (x30), on its own stack */
static void fm1coro_entry(void)
{
    fm1coro_t *c = cur;
    c->fn(c->arg);
    c->done = 1;
    cur = NULL;
    coro_switch(&c->sp, c->back);               /* (never resumed again) */
    abort();
}

fm1coro_t *fm1coro_new(void (*fn)(void *), void *arg, size_t stack_bytes)
{
    const size_t page = (size_t)getpagesize();
    if (!stack_bytes)
        stack_bytes = FM1CORO_STACK;
    stack_bytes = (stack_bytes + page - 1) & ~(page - 1);
    fm1coro_t *c = calloc(1, sizeof *c);
    if (!c)
        return NULL;
    c->map_len = stack_bytes + page;
    c->map = mmap(NULL, c->map_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (c->map == MAP_FAILED) {
        free(c);
        return NULL;
    }
    mprotect(c->map, page, PROT_NONE);          /* the guard page: the stack grows down into it */
    c->page = page;
    c->stack_len = stack_bytes;
    c->fn = fn;
    c->arg = arg;
    memset(c->map + page, FILL, stack_bytes - 256u);    /* (the high-water mark's fill, below the first frame) */
    /* the first frame, as coro_switch leaves one: registers zero, x30 (at +88) the entry */
    uint8_t *top = (uint8_t *)((uintptr_t)(c->map + page + stack_bytes) & ~(uintptr_t)15);
    uint8_t *sp = top - FRAME;
    memset(sp, 0, FRAME);
    void (*entry)(void) = fm1coro_entry;
    memcpy(sp + 88, &entry, sizeof entry);
    c->sp = sp;
    return c;
}

int fm1coro_resume(fm1coro_t *c)
{
    if (cur)
        return -1;
    if (!c || c->done)
        return 0;
    c->resumes++;
    cur = c;
    coro_switch(&c->back, c->sp);
    cur = NULL;
    return c->done ? 0 : 1;
}

void fm1coro_yield(void)
{
    fm1coro_t *c = cur;
    if (!c)
        return;
    cur = NULL;
    coro_switch(&c->sp, c->back);
    cur = c;                                    /* (resumed: fm1coro_resume set it too) */
}

void fm1coro_park(void)
{
    fm1coro_t *c = cur;
    if (!c)
        return;
    c->done = 1;
    cur = NULL;
    coro_switch(&c->sp, c->back);               /* (never resumed again) */
    abort();
}

int fm1coro_inside(void) { return cur != NULL; }

int fm1coro_done(const fm1coro_t *c) { return c ? c->done : 1; }

uint32_t fm1coro_resumes(const fm1coro_t *c) { return c ? c->resumes : 0; }

size_t fm1coro_stack_peak(const fm1coro_t *c)
{
    if (!c)
        return 0;
    const uint8_t *p = c->map + c->page, *end = p + c->stack_len;
    while (p < end && *p == FILL)
        p++;
    return (size_t)(end - p);
}

void fm1coro_free(fm1coro_t *c)
{
    if (!c)
        return;
    munmap(c->map, c->map_len);
    free(c);
}
