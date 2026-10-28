// SPDX-License-Identifier: GPL-3.0-only
// wcore.h: the fm1core ABI over a Wasm interpreter (wasm3; WAMR when built with WCORE_WAMR).
#include "wcore.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

// ---------------------------------------------------------------------------------------------------------------
// the module's exports (wasm/shim.c): every argument and result an i32
enum {
    F_GET, F_ALLOC, F_FREE, F_LAYOUT, F_OPTIONS, F_BOOT_OPTIONS, F_INIT, F_TICK, F_FRAME, F_IDLE, F_AUDIO, F_MIDI_IN,
    F_MIDI_OUT_TAKE, F_HALTED, F_SHUTDOWN, F_FLASH_STAGE, F_FLASH, F_FLASH_DIRTY, F_FLASH_SYNC, F_STATS, F_UI_INFO,
    F_INITIALIZE, F_N
};
static const char *const FNAME[F_N] = {
    "fm1w_get", "fm1w_alloc", "fm1w_free", "fm1w_layout", "fm1w_options", "fm1w_boot_options", "fm1w_init",
    "fm1w_tick", "fm1w_frame", "fm1w_idle", "fm1w_audio", "fm1w_midi_in", "fm1w_midi_out_take", "fm1w_halted",
    "fm1w_shutdown", "fm1w_flash_stage", "fm1w_flash", "fm1w_flash_dirty", "fm1w_flash_sync", "fm1w_stats",
    "fm1w_ui_info", "_initialize",
};

// the descriptor as wasm32 lays it out (fm1core_t with every pointer, function pointer and size 32 bits): what a
// ".rfm1" host reads out of linear memory. Checked against the module's own offsetof (fm1w_layout).
struct fm1core_w32 {
    uint32_t abi_version, id, name, version, source_url, family, license, gated, flash_size;
    uint32_t button_names[FM1P_NB];
    uint32_t params, nparams, panel, keymap;
    uint32_t options, boot_options, init, tick, frame, idle, audio, midi_in, midi_out_take, dump, stats, ui_info,
        shutdown, halted, flash_stage, flash, flash_dirty, flash_sync, param_epoch, knob_target, credits;
};

// one interpreter instance
struct Eng {
    virtual ~Eng() {}
    virtual bool call(int f, const uint32_t *a, int na, uint32_t *ret) = 0;
    virtual uint8_t *mem(uint32_t *size) = 0;
    virtual bool has(int f) = 0;
    std::string err;
};

static bool g_verbose = std::getenv("FM1W_VERBOSE") != nullptr;

// WASI fd_write for the firmware's printf: counted, shown with FM1W_VERBOSE
static uint32_t wasi_fd_write(uint8_t *mem, uint32_t memsize, uint32_t fd, uint32_t iovs, uint32_t niov, uint32_t nw)
{
    uint32_t total = 0;
    for (uint32_t i = 0; i < niov; i++) {
        if ((uint64_t)iovs + 8u * i + 8u > memsize)
            return 28;                      // EINVAL
        uint32_t p, n;
        std::memcpy(&p, mem + iovs + 8u * i, 4);
        std::memcpy(&n, mem + iovs + 8u * i + 4, 4);
        if ((uint64_t)p + n > memsize)
            return 28;
        if (g_verbose)
            std::fwrite(mem + p, 1, n, fd == 2 ? stderr : stdout);
        total += n;
    }
    if ((uint64_t)nw + 4 <= memsize)
        std::memcpy(mem + nw, &total, 4);
    return 0;
}

// WASI clock_time_get: the host's monotonic clock, in ns
static uint32_t wasi_clock(uint8_t *mem, uint32_t memsize, uint32_t out)
{
    if ((uint64_t)out + 8 > memsize)
        return 28;
    const uint64_t ns = (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
                            std::chrono::steady_clock::now().time_since_epoch()).count();
    std::memcpy(mem + out, &ns, 8);
    return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// wasm3
#include "wasm3.h"

struct Eng3 : Eng {
    IM3Environment env = nullptr;
    IM3Runtime rt = nullptr;
    IM3Function fn[F_N] = {};
    ~Eng3() override
    {
        if (rt)
            m3_FreeRuntime(rt);
        if (env)
            m3_FreeEnvironment(env);
    }
    bool fail(M3Result r, const char *what)
    {
        M3ErrorInfo info;
        std::memset(&info, 0, sizeof info);
        if (rt)
            m3_GetErrorInfo(rt, &info);
        err = std::string(what) + ": " + r + (info.message ? std::string(" (") + info.message + ")" : "");
        return false;
    }
    bool call(int f, const uint32_t *a, int na, uint32_t *ret) override
    {
        const void *ap[4];
        for (int i = 0; i < na; i++)
            ap[i] = &a[i];
        M3Result r = m3_Call(fn[f], (uint32_t)na, ap);
        if (r)
            return fail(r, FNAME[f]);
        if (ret) {
            const void *rp[1] = {ret};
            r = m3_GetResults(fn[f], 1, rp);
            if (r)
                return fail(r, FNAME[f]);
        }
        return true;
    }
    uint8_t *mem(uint32_t *size) override { return m3_GetMemory(rt, size, 0); }
    bool has(int f) override { return fn[f] != nullptr; }
};

static m3ApiRawFunction(m3_fd_write)
{
    m3ApiReturnType(int32_t);
    m3ApiGetArg(uint32_t, fd);
    m3ApiGetArg(uint32_t, iovs);
    m3ApiGetArg(uint32_t, niov);
    m3ApiGetArg(uint32_t, nw);
    m3ApiReturn((int32_t)wasi_fd_write((uint8_t *)_mem, m3_GetMemorySize(runtime), fd, iovs, niov, nw));
}
static m3ApiRawFunction(m3_clock_time_get)   // (ChoralRoot: its t0 and profiler; the device clock is simulated)
{
    m3ApiReturnType(int32_t);
    m3ApiGetArg(uint32_t, id);
    m3ApiGetArg(uint64_t, precision);
    m3ApiGetArg(uint32_t, out);
    (void)id;
    (void)precision;
    m3ApiReturn((int32_t)wasi_clock((uint8_t *)_mem, m3_GetMemorySize(runtime), out));
}
static m3ApiRawFunction(m3_fd_badf)   // fd_read / fd_close / fd_seek: no files in a core
{
    m3ApiReturnType(int32_t);
    m3ApiReturn(8);                         // EBADF
}

static Eng *load3(const uint8_t *bytes, size_t n, std::string *err)
{
    std::unique_ptr<Eng3> e(new Eng3);
    e->env = m3_NewEnvironment();
    // the interpreter's own value stack (the firmware's C stack is in linear memory)
    e->rt = m3_NewRuntime(e->env, 1024 * 1024, nullptr);
    IM3Module mod = nullptr;
    M3Result r = m3_ParseModule(e->env, &mod, bytes, (uint32_t)n);
    if (r) {
        e->fail(r, "parse");
        *err = e->err;
        return nullptr;
    }
    r = m3_LoadModule(e->rt, mod);
    if (r) {
        m3_FreeModule(mod);
        e->fail(r, "load");
        *err = e->err;
        return nullptr;
    }
    struct { const char *name, *sig; M3RawCall f; } imp[] = {
        {"fd_write", "i(iiii)", m3_fd_write}, {"fd_read", "i(iiii)", m3_fd_badf},
        {"fd_close", "i(i)", m3_fd_badf},     {"fd_seek", "i(iIii)", m3_fd_badf},
        {"clock_time_get", "i(iIi)", m3_clock_time_get},
    };
    for (auto &i : imp) {
        r = m3_LinkRawFunction(mod, "wasi_snapshot_preview1", i.name, i.sig, i.f);
        if (r && r != m3Err_functionLookupFailed) {
            e->fail(r, i.name);
            *err = e->err;
            return nullptr;
        }
    }
    r = m3_CompileModule(mod);
    if (r) {
        e->fail(r, "compile");
        *err = e->err;
        return nullptr;
    }
    for (int f = 0; f < F_N; f++) {
        r = m3_FindFunction(&e->fn[f], e->rt, FNAME[f]);
        if (r && f == F_INITIALIZE) {       // (optional)
            e->fn[f] = nullptr;
            continue;
        }
        if (r) {
            e->fail(r, FNAME[f]);
            *err = e->err;
            return nullptr;
        }
    }
    return e.release();
}

// ---------------------------------------------------------------------------------------------------------------
// WAMR (fast interpreter), optional
#ifdef WCORE_WAMR
#include "wasm_export.h"

struct EngW : Eng {
    wasm_module_t mod = nullptr;
    wasm_module_inst_t inst = nullptr;
    wasm_exec_env_t ex = nullptr;
    wasm_function_inst_t fn[F_N] = {};
    std::vector<uint8_t> copy;              // (WAMR may patch the buffer it loads from)
    ~EngW() override
    {
        if (ex)
            wasm_runtime_destroy_exec_env(ex);
        if (inst)
            wasm_runtime_deinstantiate(inst);
        if (mod)
            wasm_runtime_unload(mod);
    }
    bool call(int f, const uint32_t *a, int na, uint32_t *ret) override
    {
        uint32_t argv[4] = {0, 0, 0, 0};
        for (int i = 0; i < na; i++)
            argv[i] = a[i];
        if (!wasm_runtime_call_wasm(ex, fn[f], (uint32_t)na, argv)) {
            const char *x = wasm_runtime_get_exception(inst);
            err = std::string(FNAME[f]) + ": " + (x ? x : "trap");
            return false;
        }
        if (ret)
            *ret = argv[0];
        return true;
    }
    uint8_t *mem(uint32_t *size) override
    {
        wasm_memory_inst_t m = wasm_runtime_get_default_memory(inst);
        if (size)
            *size = (uint32_t)(wasm_memory_get_cur_page_count(m) * wasm_memory_get_bytes_per_page(m));
        return (uint8_t *)wasm_memory_get_base_address(m);
    }
    bool has(int f) override { return fn[f] != nullptr; }
};

static int32_t wamr_fd_write(wasm_exec_env_t ex, int32_t fd, int32_t iovs, int32_t niov, int32_t nw)
{
    wasm_module_inst_t inst = wasm_runtime_get_module_inst(ex);
    wasm_memory_inst_t m = wasm_runtime_get_default_memory(inst);
    const uint32_t size = (uint32_t)(wasm_memory_get_cur_page_count(m) * wasm_memory_get_bytes_per_page(m));
    return (int32_t)wasi_fd_write((uint8_t *)wasm_memory_get_base_address(m), size, (uint32_t)fd, (uint32_t)iovs,
                                  (uint32_t)niov, (uint32_t)nw);
}
static int32_t wamr_fd_read(wasm_exec_env_t, int32_t, int32_t, int32_t, int32_t) { return 8; }
static int32_t wamr_fd_close(wasm_exec_env_t, int32_t) { return 8; }
static int32_t wamr_fd_seek(wasm_exec_env_t, int32_t, int64_t, int32_t, int32_t) { return 8; }
static int32_t wamr_clock_time_get(wasm_exec_env_t ex, int32_t, int64_t, int32_t out)
{
    wasm_module_inst_t inst = wasm_runtime_get_module_inst(ex);
    wasm_memory_inst_t m = wasm_runtime_get_default_memory(inst);
    const uint32_t size = (uint32_t)(wasm_memory_get_cur_page_count(m) * wasm_memory_get_bytes_per_page(m));
    return (int32_t)wasi_clock((uint8_t *)wasm_memory_get_base_address(m), size, (uint32_t)out);
}
static NativeSymbol wamr_syms[] = {
    {"clock_time_get", (void *)wamr_clock_time_get, "(iIi)i", nullptr},
    {"fd_write", (void *)wamr_fd_write, "(iiii)i", nullptr},
    {"fd_read", (void *)wamr_fd_read, "(iiii)i", nullptr},
    {"fd_close", (void *)wamr_fd_close, "(i)i", nullptr},
    {"fd_seek", (void *)wamr_fd_seek, "(iIii)i", nullptr},
};

static Eng *loadW(const uint8_t *bytes, size_t n, std::string *err)
{
    static bool up = false;
    if (!up) {
        RuntimeInitArgs init;
        std::memset(&init, 0, sizeof init);
        init.mem_alloc_type = Alloc_With_System_Allocator;
        if (!wasm_runtime_full_init(&init)) {
            *err = "wamr: init failed";
            return nullptr;
        }
        wasm_runtime_register_natives("wasi_snapshot_preview1", wamr_syms, sizeof wamr_syms / sizeof wamr_syms[0]);
        up = true;
    }
    std::unique_ptr<EngW> e(new EngW);
    e->copy.assign(bytes, bytes + n);
    char eb[256] = {0};
    e->mod = wasm_runtime_load(e->copy.data(), (uint32_t)e->copy.size(), eb, sizeof eb);
    if (!e->mod) {
        *err = std::string("wamr load: ") + eb;
        return nullptr;
    }
    e->inst = wasm_runtime_instantiate(e->mod, 1024 * 1024, 0, eb, sizeof eb);
    if (!e->inst) {
        *err = std::string("wamr instantiate: ") + eb;
        return nullptr;
    }
    e->ex = wasm_runtime_create_exec_env(e->inst, 1024 * 1024);
    for (int f = 0; f < F_N; f++) {
        e->fn[f] = wasm_runtime_lookup_function(e->inst, FNAME[f]);
        if (!e->fn[f] && f != F_INITIALIZE) {
            *err = std::string("wamr: no export ") + FNAME[f];
            return nullptr;
        }
    }
    return e.release();
}
#endif

// ---------------------------------------------------------------------------------------------------------------
// the host-side descriptor
struct WCore {
    std::unique_ptr<Eng> e;
    fm1core_t d;
    std::string id, name, version, family, license;
    std::string bnames[FM1P_NB];
    uint32_t scratch = 0;                   // linear memory: [0, 2048) strings, [2048, 2048 + 128 * 4) audio, then words
    uint32_t audio_cap = 0;
    std::string lasterr;
    uint8_t *base(uint32_t *size = nullptr) { return e->mem(size); }
};
static WCore *g_cur = nullptr;
enum { SCR_STR = 0, SCR_W = 1024, SCR_AUDIO = 2048, SCR_BYTES = 2048 + 1024 * 4 };

static uint32_t call(int f, uint32_t a0 = 0, uint32_t a1 = 0, uint32_t a2 = 0, uint32_t a3 = 0, int na = 0,
                     bool hasret = false)
{
    const uint32_t a[4] = {a0, a1, a2, a3};
    uint32_t r = 0;
    if (!g_cur->e->call(f, a, na, hasret ? &r : nullptr)) {
        if (g_cur->lasterr.empty()) {
            g_cur->lasterr = g_cur->e->err;
            std::fprintf(stderr, "wcore: trap: %s\n", g_cur->lasterr.c_str());
        }
    }
    return r;
}
static uint32_t put_str(const char *s, uint32_t at)   // into the scratch, 0 for NULL
{
    if (!s)
        return 0;
    const size_t n = std::strlen(s) + 1;
    if (n > 1024)
        return 0;
    std::memcpy(g_cur->base() + g_cur->scratch + at, s, n);
    return g_cur->scratch + at;
}

static void t_options(const char *path, int no_flash, int save, int headless)
{
    call(F_OPTIONS, put_str(path, SCR_STR), (uint32_t)no_flash, (uint32_t)save, (uint32_t)headless, 4);
}
static int t_boot_options(int fail, const char *reason, int stage)
{
    return (int)call(F_BOOT_OPTIONS, (uint32_t)fail, put_str(reason, SCR_STR), (uint32_t)stage, 0, 3, true);
}
static void t_init(int demo) { call(F_INIT, (uint32_t)demo, 0, 0, 0, 1); }
static void t_tick(uint32_t ms) { call(F_TICK, ms, 0, 0, 0, 1); }
static void t_frame(void) { call(F_FRAME); }
static void t_idle(void) { call(F_IDLE); }
static void t_audio(int16_t *out, uint32_t frames)
{
    uint32_t done = 0;
    while (done < frames) {
        const uint32_t n = frames - done > g_cur->audio_cap ? g_cur->audio_cap : frames - done;
        call(F_AUDIO, g_cur->scratch + SCR_AUDIO, n, 0, 0, 2);
        std::memcpy(out + 2 * done, g_cur->base() + g_cur->scratch + SCR_AUDIO, n * 4u);
        done += n;
    }
}
static int t_midi_in(uint32_t pkt) { return (int)call(F_MIDI_IN, pkt, 0, 0, 0, 1, true); }
static int t_midi_out_take(uint32_t *pkt)
{
    const int r = (int)call(F_MIDI_OUT_TAKE, g_cur->scratch + SCR_W, 0, 0, 0, 1, true);
    if (r)
        std::memcpy(pkt, g_cur->base() + g_cur->scratch + SCR_W, 4);
    return r;
}
static void t_dump(void) {}
static void t_stats(uint32_t *shed, uint32_t *cpu)
{
    call(F_STATS, g_cur->scratch + SCR_W, g_cur->scratch + SCR_W + 4, 0, 0, 2);
    std::memcpy(shed, g_cur->base() + g_cur->scratch + SCR_W, 4);
    std::memcpy(cpu, g_cur->base() + g_cur->scratch + SCR_W + 4, 4);
}
static void t_ui_info(char *buf, uint32_t n)
{
    if (!n)
        return;
    if (n > 1024)
        n = 1024;
    call(F_UI_INFO, g_cur->scratch + SCR_STR, n, 0, 0, 2);
    std::memcpy(buf, g_cur->base() + g_cur->scratch + SCR_STR, n);
    buf[n - 1] = 0;
}
static void t_shutdown(void) { call(F_SHUTDOWN); }
static int t_halted(void) { return (int)call(F_HALTED, 0, 0, 0, 0, 0, true); }
static int t_flash_stage(const uint8_t *bytes, uint32_t n)
{
    if (!bytes || !n)
        return (int)call(F_FLASH_STAGE, 0, 0, 0, 0, 2, true);
    const uint32_t p = call(F_ALLOC, n, 0, 0, 0, 1, true);
    if (!p)
        return 0;
    std::memcpy(g_cur->base() + p, bytes, n);
    const int r = (int)call(F_FLASH_STAGE, p, n, 0, 0, 2, true);
    call(F_FREE, p, 0, 0, 0, 1);
    return r;
}
static uint8_t *t_flash(void) { return g_cur->base() + call(F_FLASH, 0, 0, 0, 0, 0, true); }
static uint32_t t_flash_dirty(void) { return call(F_FLASH_DIRTY, 0, 0, 0, 0, 0, true); }
static int t_flash_sync(void) { return (int)call(F_FLASH_SYNC, 0, 0, 0, 0, 0, true); }

static std::string read_str(WCore *w, uint32_t p)
{
    uint32_t size;
    const uint8_t *m = w->base(&size);
    std::string s;
    while (p && p < size && m[p])
        s += (char)m[p++];
    return s;
}

bool wcore_has(WEngine e)
{
#ifdef WCORE_WAMR
    return e == W_WASM3 || e == W_WAMR;
#else
    return e == W_WASM3;
#endif
}
const char *wcore_engine_name(WEngine e) { return e == W_WAMR ? "wamr-fast" : "wasm3"; }

WCore *wcore_load(WEngine eng, const uint8_t *bytes, size_t n, std::string *err)
{
    std::unique_ptr<WCore> w(new WCore);
    if (eng == W_WASM3)
        w->e.reset(load3(bytes, n, err));
#ifdef WCORE_WAMR
    else if (eng == W_WAMR)
        w->e.reset(loadW(bytes, n, err));
#endif
    else
        *err = "engine not built";
    if (!w->e)
        return nullptr;
    WCore *const prev = g_cur;
    g_cur = w.get();
    struct Restore { WCore *p; ~Restore() { g_cur = p; } } restore{prev};
    if (w->e->has(F_INITIALIZE))
        call(F_INITIALIZE);                 // (a reactor module's constructors)
    const uint32_t dp = call(F_GET, FM1CORE_ABI, 0, 0, 0, 1, true);
    if (!w->lasterr.empty() || !dp) {
        *err = w->lasterr.empty() ? "fm1w_get: NULL (another ABI)" : w->lasterr;
        return nullptr;
    }
    // the layout: the panel as the host has it, the descriptor as fm1core_w32
    const int32_t want[] = {
        (int32_t)sizeof(fm1panel_t),
        (int32_t)offsetof(fm1panel_t, keys), (int32_t)offsetof(fm1panel_t, buttons),
        (int32_t)offsetof(fm1panel_t, keys_tap), (int32_t)offsetof(fm1panel_t, buttons_tap),
        (int32_t)offsetof(fm1panel_t, enc), (int32_t)offsetof(fm1panel_t, master),
        (int32_t)offsetof(fm1panel_t, key_vel), (int32_t)offsetof(fm1panel_t, key_lean),
        (int32_t)offsetof(fm1panel_t, led), (int32_t)offsetof(fm1panel_t, led_play_green),
        (int32_t)offsetof(fm1panel_t, lcd), (int32_t)offsetof(fm1panel_t, lcd_writes),
        (int32_t)offsetof(fm1panel_t, btn_id), (int32_t)offsetof(fm1panel_t, enc_id),
        (int32_t)offsetof(fm1panel_t, enc_dir), (int32_t)offsetof(fm1panel_t, ready),
        (int32_t)sizeof(fm1core_w32),
        (int32_t)offsetof(fm1core_w32, abi_version), (int32_t)offsetof(fm1core_w32, id),
        (int32_t)offsetof(fm1core_w32, name), (int32_t)offsetof(fm1core_w32, version),
        (int32_t)offsetof(fm1core_w32, source_url), (int32_t)offsetof(fm1core_w32, family),
        (int32_t)offsetof(fm1core_w32, license), (int32_t)offsetof(fm1core_w32, gated),
        (int32_t)offsetof(fm1core_w32, flash_size), (int32_t)offsetof(fm1core_w32, button_names),
        (int32_t)offsetof(fm1core_w32, params), (int32_t)offsetof(fm1core_w32, nparams),
        (int32_t)offsetof(fm1core_w32, panel), (int32_t)offsetof(fm1core_w32, keymap),
        (int32_t)offsetof(fm1core_w32, options), (int32_t)offsetof(fm1core_w32, credits),
    };
    for (int i = 0; i < (int)(sizeof want / sizeof want[0]); i++) {
        const int32_t got = (int32_t)call(F_LAYOUT, (uint32_t)i, 0, 0, 0, 1, true);
        if (got != want[i]) {
            char b[128];
            std::snprintf(b, sizeof b, "layout: entry %d is %d in the module, %d here", i, got, want[i]);
            *err = b;
            return nullptr;
        }
    }
    uint32_t size;
    uint8_t *m = w->base(&size);
    if ((uint64_t)dp + sizeof(fm1core_w32) > size) {
        *err = "descriptor outside memory";
        return nullptr;
    }
    fm1core_w32 c;
    std::memcpy(&c, m + dp, sizeof c);
    if (c.abi_version != FM1CORE_ABI || !c.panel || (uint64_t)c.panel + sizeof(fm1panel_t) > size ||
        (c.keymap && (uint64_t)c.keymap + 6 * FM1P_NCOL > size)) {
        *err = "descriptor: bad abi, panel or keymap";
        return nullptr;
    }
    w->id = read_str(w.get(), c.id);
    w->name = read_str(w.get(), c.name);
    w->version = read_str(w.get(), c.version);
    w->family = read_str(w.get(), c.family);
    w->license = read_str(w.get(), c.license);
    for (int i = 0; i < FM1P_NB; i++)
        w->bnames[i] = read_str(w.get(), c.button_names[i]);
    w->scratch = call(F_ALLOC, SCR_BYTES, 0, 0, 0, 1, true);
    if (!w->scratch) {
        *err = "fm1w_alloc failed";
        return nullptr;
    }
    w->audio_cap = 1024;

    fm1core_t &d = w->d;
    std::memset(&d, 0, sizeof d);
    d.abi_version = c.abi_version;
    d.id = w->id.c_str();
    d.name = w->name.c_str();
    d.version = w->version.c_str();
    d.source_url = "";
    d.family = w->family.c_str();
    d.license = w->license.c_str();
    d.gated = nullptr;
    d.flash_size = c.flash_size;
    for (int i = 0; i < FM1P_NB; i++)
        d.button_names[i] = w->bnames[i].c_str();
    d.params = nullptr;                     // (the Tier 2 map's get / set are function pointers too: not in the spike)
    d.nparams = 0;
    d.panel = reinterpret_cast<fm1panel_t *>(m + c.panel);
    d.keymap = c.keymap ? reinterpret_cast<const int8_t *>(m + c.keymap) : nullptr;
    d.options = t_options;
    d.boot_options = c.boot_options ? t_boot_options : nullptr;
    d.init = t_init;
    d.tick = t_tick;
    d.frame = t_frame;
    d.idle = t_idle;
    d.audio = t_audio;
    d.midi_in = t_midi_in;
    d.midi_out_take = t_midi_out_take;
    d.dump = t_dump;
    d.stats = t_stats;
    d.ui_info = t_ui_info;
    d.shutdown = t_shutdown;
    d.halted = t_halted;
    d.flash_stage = t_flash_stage;
    d.flash = t_flash;
    d.flash_dirty = t_flash_dirty;
    d.flash_sync = t_flash_sync;
    d.credits = nullptr;
    return w.release();
}

void wcore_free(WCore *w)
{
    if (g_cur == w)
        g_cur = nullptr;
    delete w;
}
void wcore_select(WCore *w) { g_cur = w; }
const fm1core_t *wcore_desc(WCore *w) { return &w->d; }
const char *wcore_error(WCore *w) { return w->lasterr.c_str(); }
uint32_t wcore_mem_bytes(WCore *w)
{
    uint32_t s = 0;
    w->base(&s);
    return s;
}
