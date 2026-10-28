// SPDX-License-Identifier: GPL-3.0-only
// The bench (bench.h). Load the core (native: the one linked in; Wasm: a fresh instance), boot it from a
// fresh flash through FM1VST's Device (engine/device.cpp, as RFMEngine does), render `settle` s of device time
// untimed, then `idle` s with nothing held and `chord` s with D4 F#4 A4 held (velocity 100: core_bench's chord), in
// 128-frame host buffers at 48 kHz (Device::render: the device clock, the core, the Lagrange resampler), timing each
// buffer. x real = device seconds / wall seconds; "% buf" = a buffer's time against its own length (2.667 ms).
// With N instances (Wasm only: a native core's globals exist once per image), each buffer renders every instance in
// turn and the time is their sum: what one audio thread hosting N cores would spend.
#include "bench.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "device.h"
#include "wcore.h"

#if defined(__APPLE__)
#include <sys/sysctl.h>
#include <sys/utsname.h>
#endif

extern "C" {
#ifdef BENCH_NATIVE_FELUCCA
const fm1core_t *fm1core_get_felucca(uint32_t abi);
#endif
#ifdef BENCH_NATIVE_CHORALROOT
const fm1core_t *fm1core_get_choralroot(uint32_t abi);
#endif
}

namespace {

const double RATE = 48000.0;
uint32_t BUF = 128;                     // host buffer frames (spec buf=)
double BUF_US = 1e6 * 128 / RATE;

struct Opts {
    std::vector<std::string> cores{"felucca", "choralroot"};
    std::vector<std::string> engines{"native", "wasm3", "wamr"};
    std::vector<int> multi{2, 4, 8};
    int runs = 3;                           // passes after the power-on (one instance)
    int mruns = 1;                          // the same with n > 1 instances
    double settle = 3, idle = 10, chord = 10;
};

std::vector<std::string> split(const std::string &s, char c)
{
    std::vector<std::string> v;
    std::string t;
    std::istringstream in(s);
    while (std::getline(in, t, c))
        if (!t.empty())
            v.push_back(t);
    return v;
}

struct Out {
    std::string text;
    void (*progress)(const char *) = nullptr;
    void line(const char *fmt, ...)
    {
        char b[1024];
        va_list ap;
        va_start(ap, fmt);
        std::vsnprintf(b, sizeof b, fmt, ap);
        va_end(ap);
        text += b;
        text += "\n";
        if (progress)
            progress(b);
    }
};

const fm1core_t *native_core(const std::string &id)
{
#ifdef BENCH_NATIVE_FELUCCA
    if (id == "felucca")
        return fm1core_get_felucca(FM1CORE_ABI);
#endif
#ifdef BENCH_NATIVE_CHORALROOT
    if (id == "choralroot")
        return fm1core_get_choralroot(FM1CORE_ABI);
#endif
    (void)id;
    return nullptr;
}

bool read_file(const std::string &path, std::vector<uint8_t> &v)
{
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f)
        return false;
    std::fseek(f, 0, SEEK_END);
    const long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    v.resize(n > 0 ? (size_t)n : 0);
    const size_t got = v.empty() ? 0 : std::fread(v.data(), 1, v.size(), f);
    std::fclose(f);
    return got == v.size() && !v.empty();
}

struct Stats {
    double xreal = 0, mean_pct = 0, p99_pct = 0, max_pct = 0;
};
Stats stats_of(std::vector<double> us)   // per-buffer wall times
{
    Stats s;
    if (us.empty())
        return s;
    double sum = 0;
    for (double u : us)
        sum += u;
    std::sort(us.begin(), us.end());
    s.xreal = (double)us.size() * BUF_US / sum;
    s.mean_pct = 100.0 * sum / us.size() / BUF_US;
    s.p99_pct = 100.0 * us[std::min(us.size() - 1, (size_t)std::ceil(0.99 * us.size()) - 1)] / BUF_US;
    s.max_pct = 100.0 * us.back() / BUF_US;
    return s;
}

struct Run {
    std::string err;
    double load_ms = 0, boot_ms = 0;
    Stats idle, chord;
    double rms = 0;                         // the chord phase, instance 0, full scale = 1
    uint64_t hash = 0;                      // FNV-1a of every rendered float, instance 0 (idle + chord)
    uint32_t lcd_writes = 0;                // lcd_writes moved over the run (instance 0)
    uint32_t lcd_colours = 0;               // distinct pixel values on the screen at the end
    uint32_t mem_kb = 0;                    // linear memory per instance (Wasm)
};

uint64_t fnv(uint64_t h, const float *p, uint32_t n)
{
    const uint8_t *b = reinterpret_cast<const uint8_t *>(p);
    for (uint32_t i = 0; i < n * 4u; i++)
        h = (h ^ b[i]) * 1099511628211ull;
    return h;
}

using clk = std::chrono::steady_clock;
double us_since(clk::time_point t0) { return std::chrono::duration<double, std::micro>(clk::now() - t0).count(); }

// One power-on, then o.runs passes of [settle (untimed), idle (timed), chord (timed), release]. A native core's
// globals exist once per process and are never reset (FM1VST loads a fresh dylib copy per power-on), so each core is
// powered on once: the passes are measured after the same single boot, for native and Wasm alike (a Wasm instance
// could be fresh each time; it is not, so both follow the same script and render the same stream: the hash).
std::vector<Run> run_passes(const std::string &id, const std::string &engine, const std::vector<uint8_t> *wasm, int n,
                            const Opts &o)
{
    static std::vector<std::string> native_used;
    std::vector<Run> out;
    Run r;
    std::vector<WCore *> w;
    std::vector<std::unique_ptr<Device>> dev;
    const bool native = engine == "native";
    const WEngine we = engine == "wamr" ? W_WAMR : W_WASM3;
    struct Free { std::vector<WCore *> &w; ~Free() { for (WCore *x : w) wcore_free(x); } } freer{w};
    auto fail = [&](const std::string &e) {
        r.err = e;
        out.push_back(r);
        return out;
    };
    auto t0 = clk::now();
    for (int i = 0; i < n; i++) {
        const fm1core_t *c = nullptr;
        if (native) {
            c = native_core(id);
            if (!c)
                return fail("no native " + id + " in this build");
            if (n != 1 || std::find(native_used.begin(), native_used.end(), id) != native_used.end())
                return fail("a native core powers on once per process");
            native_used.push_back(id);
        } else {
            std::string err;
            WCore *x = wcore_load(we, wasm->data(), wasm->size(), &err);
            if (!x)
                return fail(err);
            w.push_back(x);
            c = wcore_desc(x);
            r.mem_kb = wcore_mem_bytes(x) / 1024;
        }
        dev.emplace_back(new Device(c));
    }
    r.load_ms = us_since(t0) / 1000.0 / n;
    auto sel = [&](int i) {
        if (!native)
            wcore_select(w[i]);
    };
    t0 = clk::now();
    for (int i = 0; i < n; i++) {
        sel(i);
        dev[i]->boot_from(nullptr, 0);
    }
    r.boot_ms = us_since(t0) / 1000.0 / n;
    std::vector<float> L(BUF), R(BUF);
    uint64_t hash = 1469598103934665603ull;
    double sq = 0;
    auto render_all = [&]() {
        for (int i = 0; i < n; i++) {
            sel(i);
            dev[i]->render(L.data(), R.data(), BUF, RATE);
            if (i == 0) {
                hash = fnv(fnv(hash, L.data(), BUF), R.data(), BUF);
                for (uint32_t k = 0; k < BUF; k++)
                    sq += (double)L[k] * L[k] + (double)R[k] * R[k];
            }
        }
    };
    const uint32_t settle = (uint32_t)(o.settle * RATE / BUF), idle = (uint32_t)(o.idle * RATE / BUF),
                   chord = (uint32_t)(o.chord * RATE / BUF);
    std::vector<double> us;
    us.reserve(std::max(idle, chord));
    for (int pass = 0; pass < o.runs; pass++) {
        for (uint32_t b = 0; b < settle; b++)
            render_all();
        const uint32_t lw0 = dev[0]->lcd_writes();
        us.clear();
        for (uint32_t b = 0; b < idle; b++) {
            const auto b0 = clk::now();
            render_all();
            us.push_back(us_since(b0));
        }
        r.idle = stats_of(us);
        us.clear();
        for (int i = 0; i < n; i++) {
            const int keys[3] = {9, 13, 16};    // D4 F#4 A4 (core_bench)
            uint32_t m = 0;
            for (int k : keys) {
                dev[i]->key_vel(k, 100);
                m |= 1u << k;
            }
            dev[i]->keys(m);
        }
        sq = 0;
        for (uint32_t b = 0; b < chord; b++) {
            const auto b0 = clk::now();
            render_all();
            us.push_back(us_since(b0));
        }
        r.chord = stats_of(us);
        r.rms = std::sqrt(sq / (2.0 * chord * BUF));
        for (int i = 0; i < n; i++)
            dev[i]->keys(0);
        r.lcd_writes = dev[0]->lcd_writes() - lw0;
        std::vector<uint16_t> px(dev[0]->lcd(), dev[0]->lcd() + FM1P_LCD_W * FM1P_LCD_H);
        std::sort(px.begin(), px.end());
        r.lcd_colours = (uint32_t)(std::unique(px.begin(), px.end()) - px.begin());
        r.hash = hash;
        for (int i = 0; i < (int)w.size(); i++)
            if (*wcore_error(w[i]))
                r.err = wcore_error(w[i]);
        out.push_back(r);
        if (!r.err.empty())
            break;
    }
    return out;
}


double median(std::vector<double> v)
{
    std::sort(v.begin(), v.end());
    return v.empty() ? 0 : v[v.size() / 2];
}

std::string machine()
{
    std::string m = "?";
#if defined(__APPLE__)
    char b[256];
    size_t n = sizeof b;
    if (sysctlbyname("hw.machine", b, &n, nullptr, 0) == 0)
        m = std::string(b, strnlen(b, n));
    n = sizeof b;
    if (sysctlbyname("machdep.cpu.brand_string", b, &n, nullptr, 0) == 0)
        m += std::string(" / ") + std::string(b, strnlen(b, n));
    n = sizeof b;
    if (sysctlbyname("hw.model", b, &n, nullptr, 0) == 0)
        m += std::string(" / ") + std::string(b, strnlen(b, n));
#endif
    return m;
}

void bench(const Opts &o, const std::string &dir, Out &out)
{
    out.line("rfmbench: %s, %s %s; host buffers %u frames at %.0f Hz (%.3f ms); settle %.0f s, idle %.0f s, chord %.0f s"
             " (D4 F#4 A4); %d passes after one power-on, median",
             machine().c_str(), __DATE__, __TIME__, BUF, RATE, BUF_US / 1000.0, o.settle, o.idle, o.chord, o.runs);
    out.line("%-10s %-10s %3s | %7s %7s %7s %7s | %7s %7s %7s %7s | %7s %6s %6s %9s %s", "core", "engine", "n",
             "idle x", "mean%", "p99%", "max%", "chord x", "mean%", "p99%", "max%", "rms", "lcdw", "colors", "load ms",
             "hash");
    for (const std::string &id : o.cores) {
        std::vector<uint8_t> wasm;
        const bool have_wasm = read_file(dir + "/" + id + ".wasm", wasm);
        if (have_wasm)
            out.line("# %s.wasm: %zu bytes", id.c_str(), wasm.size());
        std::vector<std::pair<std::string, int>> plan;
        for (const std::string &e : o.engines)
            plan.push_back({e, 1});
        for (int m : o.multi)
            for (const std::string &e : o.engines)
                if (e != "native")
                    plan.push_back({e, m});
        for (auto &p : plan) {
            const std::string &e = p.first;
            const int n = p.second;
            if (e != "native" && (!have_wasm || !wcore_has(e == "wamr" ? W_WAMR : W_WASM3)))
                continue;
            if (e == "native" && !native_core(id))
                continue;
            std::vector<double> v[10];
            Run last;
            int ok = 0;
            Opts po = o;
            if (n > 1)
                po.runs = o.mruns;
            const std::vector<Run> runs = run_passes(id, e, &wasm, n, po);
            for (int k = 0; k < (int)runs.size(); k++) {
                const Run &r = runs[k];
                if (!r.err.empty()) {
                    out.line("%-10s %-10s %3d | error: %s", id.c_str(), e.c_str(), n, r.err.c_str());
                    break;
                }
                out.line("  pass %d: idle %.1fx (mean %.2f%% p99 %.2f%% max %.2f%%), chord %.1fx (mean %.2f%% p99 %.2f%% "
                         "max %.2f%%), rms %.4f, load %.1f ms, boot %.1f ms", k + 1, r.idle.xreal, r.idle.mean_pct,
                         r.idle.p99_pct, r.idle.max_pct, r.chord.xreal, r.chord.mean_pct, r.chord.p99_pct,
                         r.chord.max_pct, r.rms, r.load_ms, r.boot_ms);
                const double f[10] = {r.idle.xreal, r.idle.mean_pct, r.idle.p99_pct, r.idle.max_pct, r.chord.xreal,
                                      r.chord.mean_pct, r.chord.p99_pct, r.chord.max_pct, r.load_ms, r.boot_ms};
                for (int i = 0; i < 10; i++)
                    v[i].push_back(f[i]);
                last = r;
                ok++;
            }
            if (!ok)
                continue;
            out.line("%-10s %-10s %3d | %7.1f %7.2f %7.2f %7.2f | %7.1f %7.2f %7.2f %7.2f | %7.4f %6u %6u %9.1f %016llx",
                     id.c_str(), e.c_str(), n, median(v[0]), median(v[1]), median(v[2]), median(v[3]), median(v[4]),
                     median(v[5]), median(v[6]), median(v[7]), last.rms, last.lcd_writes, last.lcd_colours,
                     median(v[8]), (unsigned long long)last.hash);
            out.line("%-10s %-10s %3s | %7s %7s %7.2f %7.2f | %7s %7s %7.2f %7.2f | (the worst pass: p99, max)", "",
                     "", "", "", "", *std::max_element(v[2].begin(), v[2].end()),
                     *std::max_element(v[3].begin(), v[3].end()), "", "", *std::max_element(v[6].begin(), v[6].end()),
                     *std::max_element(v[7].begin(), v[7].end()));
            if (last.mem_kb)
                out.line("# %s %s: linear memory %u KiB per instance, boot %.1f ms", id.c_str(), e.c_str(),
                         last.mem_kb, median(v[9]));
        }
    }
    out.line("# x = device s per wall s; %% = a host buffer's render time / its length; n = instances per buffer;"
             " rms (instance 0, chord), lcdw = lcd_writes over idle + chord, colors = distinct pixels at the end");
}

} // namespace

extern "C" char *rfmbench_run(const char *wasm_dir, const char *spec, void (*progress)(const char *line))
{
    Opts o;
    if (spec)
        for (const std::string &w : split(spec, ' ')) {
            const size_t eq = w.find('=');
            if (eq == std::string::npos)
                continue;
            const std::string k = w.substr(0, eq), v = w.substr(eq + 1);
            if (k == "cores")
                o.cores = split(v, ',');
            else if (k == "engines")
                o.engines = split(v, ',');
            else if (k == "multi") {
                o.multi.clear();
                for (auto &x : split(v, ','))
                    if (std::atoi(x.c_str()) > 1)
                        o.multi.push_back(std::atoi(x.c_str()));
            } else if (k == "runs")
                o.runs = std::max(1, std::atoi(v.c_str()));
            else if (k == "buf") {
                BUF = (uint32_t)std::max(16, std::atoi(v.c_str()));
                BUF_US = 1e6 * BUF / RATE;
            } else if (k == "mruns")
                o.mruns = std::max(1, std::atoi(v.c_str()));
            else if (k == "settle")
                o.settle = std::atof(v.c_str());
            else if (k == "idle")
                o.idle = std::atof(v.c_str());
            else if (k == "chord")
                o.chord = std::atof(v.c_str());
        }
    Out out;
    out.progress = progress;
    bench(o, wasm_dir ? wasm_dir : ".", out);
    char *s = (char *)std::malloc(out.text.size() + 1);
    std::memcpy(s, out.text.c_str(), out.text.size() + 1);
    return s;
}
