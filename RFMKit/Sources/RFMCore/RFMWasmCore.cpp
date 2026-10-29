// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// WasmCore (M7): the core backend (RFMCoreBackend.h) over an .rfm1 module (docs/RFM1-FORMAT.md, version 1) in wasm3
// v0.5.0 (Sources/CWasm3), and its loader (include/RFMWasm.h).
//
//   the file      read once (WasmFile, cached by path, size and modification time; shared by every instance of it and
//                 kept alive by them): its SHA-256; the binary walked section by section with every bound checked; the
//                 manifest (the rfm1 custom section, JSON: section 4's required fields and forms); rfm1.credits and
//                 rfm1.license.<n>; the imports (section 3's list only, each with its exact signature); the exports
//                 (section 2's, each a function of its i32 signature, and the memory); one memory, defined here and
//                 exported, fixed (initial = maximum), at most 32 MiB, not shared or 64-bit; active data segments
//   an instance   (WasmCore) its own wasm3 environment and runtime, the module parsed from the file's bytes (wasm3 keeps
//                 pointers into them, hence the shared WasmFile) and compiled whole up front (no compile on the core
//                 thread later), the WASI stubs linked with the instance as their context; _initialize,
//                 rfm1_version() == 1, rfm1_get(6), every rfm1_layout value against this host's, the descriptor's
//                 data copied out (CoreDesc), its id / name / version against the manifest's. wasm3 parses a module
//                 into one runtime, so each instance parses again (cheap: the cost is the compile; measured, load_us)
//   calls         through the rfm1_* exports (a host can't call the descriptor's wasm32 function pointers); which
//                 optional entry points the firmware has is read from the descriptor's (non-zero) fields. Pointers the
//                 host hands in point at one scratch block made once with rfm1_alloc (strings, the audio, MIDI and
//                 stats words); audio() renders there and copies out. panel() and flash() point into linear memory,
//                 which never moves (fixed size). A trap ends the instance: halted() is then 0x100 | code after
//                 proc_exit(code), 0x200 after any other trap, and every later call does nothing
//   WASI          fd_write: stdout and stderr to the log (os_log, rate-limited per instance); fd_read, fd_close, fd_seek:
//                 EBADF; clock_time_get: the host's monotonic clock; proc_exit: the instance halts
//
// Threading: as CoreBackend's. No thread-local state: wasm3's runtime is all in the instance, so the core thread and
// the control thread may take turns.
#include <CommonCrypto/CommonDigest.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <sys/stat.h>

#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "RFMCoreBackend.h"
#include "RFMWasm.h"
#include "wasm3.h"

namespace rfm {
namespace {

// ------------------------------------------------------------------------------------------------ small JSON ----
// enough for the manifest: objects, arrays, strings (with escapes), numbers, true / false / null
struct Json {
    enum Type { Null, Bool, Num, Str, Arr, Obj } t = Null;
    bool b = false;
    double n = 0;
    std::string s;
    std::vector<Json> a;
    std::vector<std::pair<std::string, Json>> o;

    const Json *get(const char *k) const
    {
        for (const auto &kv : o)
            if (kv.first == k)
                return &kv.second;
        return nullptr;
    }
};

class JsonParser {
public:
    JsonParser(const char *p, size_t n) : p_(p), e_(p + n) {}
    bool parse(Json &out)
    {
        if (!value(out, 0))
            return false;
        ws();
        return p_ == e_;
    }

private:
    void ws()
    {
        while (p_ < e_ && (*p_ == ' ' || *p_ == '\t' || *p_ == '\n' || *p_ == '\r'))
            p_++;
    }
    static void utf8(std::string &s, uint32_t u)
    {
        if (u < 0x80) {
            s += (char)u;
        } else if (u < 0x800) {
            s += (char)(0xC0 | (u >> 6));
            s += (char)(0x80 | (u & 0x3F));
        } else if (u < 0x10000) {
            s += (char)(0xE0 | (u >> 12));
            s += (char)(0x80 | ((u >> 6) & 0x3F));
            s += (char)(0x80 | (u & 0x3F));
        } else {
            s += (char)(0xF0 | (u >> 18));
            s += (char)(0x80 | ((u >> 12) & 0x3F));
            s += (char)(0x80 | ((u >> 6) & 0x3F));
            s += (char)(0x80 | (u & 0x3F));
        }
    }
    bool hex4(uint32_t &u)
    {
        if (e_ - p_ < 4)
            return false;
        u = 0;
        for (int i = 0; i < 4; i++) {
            const char c = *p_++;
            u <<= 4;
            if (c >= '0' && c <= '9') u |= (uint32_t)(c - '0');
            else if (c >= 'a' && c <= 'f') u |= (uint32_t)(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') u |= (uint32_t)(c - 'A' + 10);
            else return false;
        }
        return true;
    }
    bool string(std::string &s)
    {
        if (p_ >= e_ || *p_ != '"')
            return false;
        p_++;
        while (p_ < e_ && *p_ != '"') {
            const unsigned char c = (unsigned char)*p_++;
            if (c < 0x20)
                return false;
            if (c != '\\') {
                s += (char)c;
                continue;
            }
            if (p_ >= e_)
                return false;
            const char x = *p_++;
            switch (x) {
            case '"': s += '"'; break;
            case '\\': s += '\\'; break;
            case '/': s += '/'; break;
            case 'b': s += '\b'; break;
            case 'f': s += '\f'; break;
            case 'n': s += '\n'; break;
            case 'r': s += '\r'; break;
            case 't': s += '\t'; break;
            case 'u': {
                uint32_t u;
                if (!hex4(u))
                    return false;
                if (u >= 0xD800 && u < 0xDC00 && e_ - p_ >= 6 && p_[0] == '\\' && p_[1] == 'u') {
                    p_ += 2;
                    uint32_t lo;
                    if (!hex4(lo) || lo < 0xDC00 || lo >= 0xE000)
                        return false;
                    u = 0x10000u + ((u - 0xD800u) << 10) + (lo - 0xDC00u);
                }
                utf8(s, u);
                break;
            }
            default: return false;
            }
        }
        if (p_ >= e_)
            return false;
        p_++;
        return true;
    }
    bool value(Json &v, int depth)
    {
        if (depth > 16)
            return false;
        ws();
        if (p_ >= e_)
            return false;
        const char c = *p_;
        if (c == '{') {
            p_++;
            v.t = Json::Obj;
            ws();
            if (p_ < e_ && *p_ == '}') {
                p_++;
                return true;
            }
            for (;;) {
                ws();
                std::string k;
                if (!string(k))
                    return false;
                ws();
                if (p_ >= e_ || *p_++ != ':')
                    return false;
                Json x;
                if (!value(x, depth + 1))
                    return false;
                v.o.emplace_back(std::move(k), std::move(x));
                ws();
                if (p_ < e_ && *p_ == ',') { p_++; continue; }
                if (p_ < e_ && *p_ == '}') { p_++; return true; }
                return false;
            }
        }
        if (c == '[') {
            p_++;
            v.t = Json::Arr;
            ws();
            if (p_ < e_ && *p_ == ']') {
                p_++;
                return true;
            }
            for (;;) {
                Json x;
                if (!value(x, depth + 1))
                    return false;
                v.a.push_back(std::move(x));
                ws();
                if (p_ < e_ && *p_ == ',') { p_++; continue; }
                if (p_ < e_ && *p_ == ']') { p_++; return true; }
                return false;
            }
        }
        if (c == '"') {
            v.t = Json::Str;
            return string(v.s);
        }
        auto word = [&](const char *w) {
            const size_t n = std::strlen(w);
            if ((size_t)(e_ - p_) < n || std::memcmp(p_, w, n))
                return false;
            p_ += n;
            return true;
        };
        if (word("true")) { v.t = Json::Bool; v.b = true; return true; }
        if (word("false")) { v.t = Json::Bool; v.b = false; return true; }
        if (word("null")) { v.t = Json::Null; return true; }
        if (c == '-' || (c >= '0' && c <= '9')) {
            std::string num;
            while (p_ < e_ && (std::strchr("+-.eE", *p_) || (*p_ >= '0' && *p_ <= '9')))
                num += *p_++;
            char *end = nullptr;
            v.t = Json::Num;
            v.n = std::strtod(num.c_str(), &end);
            return end && *end == 0;
        }
        return false;
    }
    const char *p_, *e_;
};

// ------------------------------------------------------------------------------------------------ the file ------
constexpr uint8_t I32 = 0x7F, I64 = 0x7E;
constexpr uint32_t MAX_MEMORY = 32u * 1048576u;
constexpr uint32_t PAGE = 65536;

struct FuncType {
    std::vector<uint8_t> params, results;
};

// section 3's imports, with their signatures
struct ImportSig {
    const char *name;
    std::vector<uint8_t> params, results;
    const char *m3sig;
};
const ImportSig IMPORTS[] = {
    {"fd_write", {I32, I32, I32, I32}, {I32}, "i(iiii)"},
    {"fd_read", {I32, I32, I32, I32}, {I32}, "i(iiii)"},
    {"fd_close", {I32}, {I32}, "i(i)"},
    {"fd_seek", {I32, I64, I32, I32}, {I32}, "i(iIii)"},
    {"clock_time_get", {I32, I64, I32}, {I32}, "i(iIi)"},
    {"proc_exit", {I32}, {}, "v(i)"},
};
const char *const WASI = "wasi_snapshot_preview1";

// section 2's exports: name, i32 arguments, i32 results
enum {
    F_INITIALIZE, F_VERSION, F_GET, F_LAYOUT, F_ALLOC, F_FREE, F_OPTIONS, F_BOOT_OPTIONS, F_INIT, F_TICK, F_FRAME,
    F_IDLE, F_AUDIO, F_MIDI_IN, F_MIDI_OUT_TAKE, F_HALTED, F_SHUTDOWN, F_FLASH_STAGE, F_FLASH, F_FLASH_DIRTY,
    F_FLASH_SYNC, F_STATS, F_UI_INFO, F_N
};
const struct {
    const char *name;
    unsigned nargs, nret;
} FN[F_N] = {
    {"_initialize", 0, 0},     {"rfm1_version", 0, 1},       {"rfm1_get", 1, 1},          {"rfm1_layout", 1, 1},
    {"rfm1_alloc", 1, 1},      {"rfm1_free", 1, 0},          {"rfm1_options", 4, 0},      {"rfm1_boot_options", 3, 1},
    {"rfm1_init", 1, 0},       {"rfm1_tick", 1, 0},          {"rfm1_frame", 0, 0},        {"rfm1_idle", 0, 0},
    {"rfm1_audio", 2, 0},      {"rfm1_midi_in", 1, 1},       {"rfm1_midi_out_take", 1, 1}, {"rfm1_halted", 0, 1},
    {"rfm1_shutdown", 0, 0},   {"rfm1_flash_stage", 2, 1},   {"rfm1_flash", 0, 1},        {"rfm1_flash_dirty", 0, 1},
    {"rfm1_flash_sync", 0, 1}, {"rfm1_stats", 2, 0},         {"rfm1_ui_info", 2, 0},
};

std::string base(const std::string &path)
{
    const size_t s = path.find_last_of('/');
    return s == std::string::npos ? path : path.substr(s + 1);
}

struct Reader {
    const uint8_t *p;
    size_t at, end;
    bool ok = true;

    uint8_t byte()
    {
        if (at >= end) {
            ok = false;
            return 0;
        }
        return p[at++];
    }
    uint32_t u32()
    {
        uint32_t r = 0;
        for (int sh = 0; sh < 35; sh += 7) {
            const uint8_t b = byte();
            if (!ok)
                return 0;
            r |= (uint32_t)(b & 0x7Fu) << sh;
            if (!(b & 0x80u))
                return r;
        }
        ok = false;
        return 0;
    }
    void sleb()                         // (skipped: a signed LEB128 of up to 64 bits)
    {
        for (int i = 0; i < 10; i++) {
            const uint8_t b = byte();
            if (!ok || !(b & 0x80u))
                return;
        }
        ok = false;
    }
    std::string name()
    {
        const uint32_t n = u32();
        if (!ok || at + n > end) {
            ok = false;
            return {};
        }
        std::string s((const char *)p + at, n);
        at += n;
        return s;
    }
    void skip(size_t n)
    {
        if (at + n > end)
            ok = false;
        else
            at += n;
    }
};

} // namespace

// a checked .rfm1 file (immutable once made)
struct WasmFile {
    std::string path, sha256;
    std::vector<uint8_t> bytes;
    std::string manifest_json, credits;
    std::vector<std::string> licenses;
    // the manifest
    std::string id, name, version, license, source_url;
    uint32_t memory_pages = 0;
};

namespace {

std::string hex(const uint8_t *d, size_t n)
{
    static const char *h = "0123456789abcdef";
    std::string s;
    for (size_t i = 0; i < n; i++) {
        s += h[d[i] >> 4];
        s += h[d[i] & 15];
    }
    return s;
}

bool readFile(const std::string &path, std::vector<uint8_t> &out, std::string *err)
{
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) {
        *err = base(path) + ": can't read it (" + std::strerror(errno) + ")";
        return false;
    }
    std::fseek(f, 0, SEEK_END);
    const long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > 64L * 1048576L) {
        std::fclose(f);
        *err = base(path) + (sz <= 0 ? ": an empty file" : ": larger than 64 MiB");
        return false;
    }
    out.resize((size_t)sz);
    const bool ok = std::fread(out.data(), 1, out.size(), f) == out.size();
    std::fclose(f);
    if (!ok)
        *err = base(path) + ": can't read it";
    return ok;
}

bool idForm(const std::string &id)
{
    if (id.empty() || id.size() > 31)
        return false;
    for (char c : id)
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'))
            return false;
    return true;
}

std::string sigText(const std::vector<uint8_t> &p, const std::vector<uint8_t> &r)
{
    auto one = [](uint8_t t) {
        switch (t) {
        case 0x7F: return "i32";
        case 0x7E: return "i64";
        case 0x7D: return "f32";
        case 0x7C: return "f64";
        default: return "?";
        }
    };
    std::string s = "(";
    for (size_t i = 0; i < p.size(); i++)
        s += std::string(i ? ", " : "") + one(p[i]);
    s += ") -> (";
    for (size_t i = 0; i < r.size(); i++)
        s += std::string(i ? ", " : "") + one(r[i]);
    return s + ")";
}

// section 7 step 1 on the bytes: false with the reason
bool checkFile(WasmFile &f, std::string *err)
{
    const std::string who = base(f.path) + ": ";
    auto bad = [&](const std::string &m) {
        *err = who + m;
        return false;
    };
    const std::vector<uint8_t> &b = f.bytes;
    static const uint8_t magic[8] = {0, 'a', 's', 'm', 1, 0, 0, 0};
    if (b.size() < 8 || std::memcmp(b.data(), magic, 4))
        return bad("not a WebAssembly module (no \\0asm magic): not an .rfm1 file");
    if (std::memcmp(b.data() + 4, magic + 4, 4))
        return bad("a WebAssembly module of another binary version (not 1)");

    std::vector<FuncType> types;
    std::vector<uint32_t> funcs;            // each defined function's type index
    uint32_t importedFuncs = 0;
    int memories = 0;
    bool haveManifest = false, memExported = false;
    struct Export { std::string name; uint8_t kind; uint32_t index; };
    std::vector<Export> exports;
    std::map<uint32_t, std::string> licenseByN;

    Reader r{b.data(), 8, b.size()};
    while (r.at < r.end) {
        const uint8_t sid = r.byte();
        const uint32_t size = r.u32();
        if (!r.ok || r.at + size > r.end)
            return bad("a section runs past the end of the file (a truncated or damaged file)");
        Reader s{b.data(), r.at, r.at + size};
        r.at += size;
        switch (sid) {
        case 0: {                           // custom
            const std::string nm = s.name();
            if (!s.ok)
                return bad("a custom section's name runs past its end");
            std::string payload((const char *)b.data() + s.at, s.end - s.at);
            if (nm == "rfm1") {
                if (haveManifest)
                    return bad("two rfm1 sections");
                haveManifest = true;
                f.manifest_json = std::move(payload);
            } else if (nm == "rfm1.credits") {
                f.credits = std::move(payload);
            } else if (nm.rfind("rfm1.license.", 0) == 0) {
                const std::string k = nm.substr(13);
                char *end = nullptr;
                const unsigned long n = std::strtoul(k.c_str(), &end, 10);
                if (!k.empty() && end && *end == 0 && n < 64)
                    licenseByN[(uint32_t)n] = std::move(payload);
            }
            break;
        }
        case 1: {                           // types
            const uint32_t n = s.u32();
            for (uint32_t i = 0; i < n && s.ok; i++) {
                if (s.byte() != 0x60)
                    return bad("a type that is not a function type");
                FuncType t;
                for (uint32_t k = 0, np = s.u32(); k < np && s.ok; k++)
                    t.params.push_back(s.byte());
                for (uint32_t k = 0, nr = s.u32(); k < nr && s.ok; k++)
                    t.results.push_back(s.byte());
                types.push_back(std::move(t));
            }
            break;
        }
        case 2: {                           // imports: section 3's list only
            const uint32_t n = s.u32();
            for (uint32_t i = 0; i < n && s.ok; i++) {
                const std::string mod = s.name(), fld = s.name();
                const uint8_t kind = s.byte();
                if (!s.ok)
                    break;
                const std::string what = mod + "." + fld;
                if (kind != 0)
                    return bad("it imports " + what + " (a " +
                               (kind == 1 ? "table" : kind == 2 ? "memory" : kind == 3 ? "global" : "non-function") +
                               "): the .rfm1 format allows only WASI functions (section 3)");
                const uint32_t ti = s.u32();
                const ImportSig *sig = nullptr;
                if (mod == WASI)
                    for (const ImportSig &x : IMPORTS)
                        if (fld == x.name)
                            sig = &x;
                if (!sig)
                    return bad("it imports " + what + ", which the .rfm1 format doesn't allow (only " + WASI +
                               "'s fd_write, fd_read, fd_close, fd_seek, clock_time_get and proc_exit)");
                if (ti >= types.size())
                    return bad("the import " + what + " has no type");
                if (types[ti].params != sig->params || types[ti].results != sig->results)
                    return bad("the import " + what + " has the signature " +
                               sigText(types[ti].params, types[ti].results) + ", not " +
                               sigText(sig->params, sig->results));
                importedFuncs++;
            }
            break;
        }
        case 3: {                           // functions
            const uint32_t n = s.u32();
            for (uint32_t i = 0; i < n && s.ok; i++)
                funcs.push_back(s.u32());
            break;
        }
        case 5: {                           // memory: one, fixed, at most 32 MiB
            const uint32_t n = s.u32();
            for (uint32_t i = 0; i < n && s.ok; i++) {
                const uint8_t flags = s.byte();
                const uint32_t init = s.u32();
                const uint32_t max = flags & 1 ? s.u32() : 0;
                if (!s.ok)
                    break;
                memories++;
                if (flags & 4)
                    return bad("a 64-bit memory (memory64): the format's memory is wasm32");
                if (flags & 2)
                    return bad("a shared memory (threads): not in the .rfm1 format");
                if (!(flags & 1) || max != init)
                    return bad("its memory can grow (initial " + std::to_string(init) + " pages, maximum " +
                               (flags & 1 ? std::to_string(max) : std::string("none")) +
                               "): the format wants a fixed memory, initial = maximum (section 6)");
                if ((uint64_t)init * PAGE > MAX_MEMORY)
                    return bad("its memory is " + std::to_string(init / 16) + " MiB: at most 32 MiB (section 6)");
                f.memory_pages = init;
            }
            break;
        }
        case 7: {                           // exports
            const uint32_t n = s.u32();
            for (uint32_t i = 0; i < n && s.ok; i++) {
                Export e;
                e.name = s.name();
                e.kind = s.byte();
                e.index = s.u32();
                exports.push_back(std::move(e));
            }
            break;
        }
        case 11: {                          // data: active segments in memory 0
            const uint32_t n = s.u32();
            for (uint32_t i = 0; i < n && s.ok; i++) {
                const uint32_t flags = s.u32();
                if (flags != 0)
                    return bad(flags == 1 ? "a passive data segment (memory.init): not in the .rfm1 format (section 6)"
                                          : "a data segment for another memory: not in the .rfm1 format (section 6)");
                const uint8_t op = s.byte();
                if (op == 0x41)
                    s.sleb();
                else if (op == 0x23)
                    s.u32();
                else
                    return bad("a data segment whose offset is not a constant");
                if (s.byte() != 0x0B)
                    return bad("a data segment whose offset is not a constant");
                s.skip(s.u32());
            }
            break;
        }
        default:
            break;
        }
        if (!s.ok)
            return bad("a damaged section (id " + std::to_string(sid) + ")");
    }
    if (!haveManifest)
        return bad("no rfm1 section (the manifest): a WebAssembly module, but not an .rfm1 file");
    for (uint32_t n = 0; licenseByN.count(n); n++)
        f.licenses.push_back(licenseByN[n]);

    // the manifest (section 4)
    Json m;
    if (!JsonParser(f.manifest_json.data(), f.manifest_json.size()).parse(m) || m.t != Json::Obj)
        return bad("its manifest (the rfm1 section) is not a JSON object");
    const Json *ver = m.get("rfm1");
    if (!ver || ver->t != Json::Num)
        return bad("its manifest has no \"rfm1\" (the format's version)");
    if (ver->n != 1)
        return bad("an .rfm1 of format version " + std::to_string((int)ver->n) + ": this app reads version 1");
    const Json *abi = m.get("abi");
    if (!abi || abi->t != Json::Num || abi->n != (double)FM1CORE_ABI)
        return bad("its manifest's \"abi\" is not " + std::to_string(FM1CORE_ABI));
    auto str = [&](const char *k, std::string &out) {
        const Json *v = m.get(k);
        if (!v || v->t != Json::Str || v->s.empty())
            return false;
        out = v->s;
        return true;
    };
    for (const char *k : {"id", "name", "version", "license", "source_url"}) {
        std::string tmp;
        if (!str(k, tmp))
            return bad(std::string("its manifest has no \"") + k + "\" (a required field, section 4)");
    }
    str("id", f.id);
    str("name", f.name);
    str("version", f.version);
    str("license", f.license);
    str("source_url", f.source_url);
    if (!idForm(f.id))
        return bad("its manifest's id \"" + f.id + "\" is not [a-z0-9_]{1,31}");
    if (const Json *au = m.get("authors"); au && au->t != Json::Arr)
        return bad("its manifest's \"authors\" is not a list");

    // the memory and the exports (section 2)
    if (memories != 1)
        return bad(memories ? "more than one memory" : "no memory of its own (the format wants one, exported)");
    auto findExport = [&](const char *name) -> const Export * {
        for (const Export &e : exports)
            if (e.name == name)
                return &e;
        return nullptr;
    };
    if (const Export *e = findExport("memory"); e && e->kind == 2 && e->index == 0)
        memExported = true;
    if (!memExported)
        return bad("its memory is not exported as \"memory\"");
    for (int i = 0; i < F_N; i++) {
        const Export *e = findExport(FN[i].name);
        if (!e) {
            if (i == F_INITIALIZE)
                continue;
            return bad(std::string("it has no export ") + FN[i].name + " (section 2)");
        }
        if (e->kind != 0 || e->index < importedFuncs || e->index - importedFuncs >= funcs.size())
            return bad(std::string("its export ") + FN[i].name + " is not a function of its own");
        const uint32_t ti = funcs[e->index - importedFuncs];
        if (ti >= types.size())
            return bad(std::string("its export ") + FN[i].name + " has no type");
        const FuncType want{std::vector<uint8_t>(FN[i].nargs, I32), std::vector<uint8_t>(FN[i].nret, I32)};
        if (types[ti].params != want.params || types[ti].results != want.results)
            return bad(std::string("its export ") + FN[i].name + " has the signature " +
                       sigText(types[ti].params, types[ti].results) + ", not " + sigText(want.params, want.results));
    }
    return true;
}

struct CacheEntry {
    off_t size = 0;
    struct timespec mtime{};
    std::shared_ptr<const WasmFile> file;
    std::string err;
};
std::mutex g_mu;
std::map<std::string, CacheEntry> g_cache;

} // namespace

// a checked file (cached by path, size and modification time); nullptr with the reason
std::shared_ptr<const WasmFile> wasmOpen(const std::string &path, std::string *err)
{
    struct stat st;
    if (::stat(path.c_str(), &st) != 0) {
        *err = base(path) + ": not found";
        return nullptr;
    }
    std::lock_guard<std::mutex> g(g_mu);
    auto it = g_cache.find(path);
    if (it != g_cache.end() && it->second.size == st.st_size && it->second.mtime.tv_sec == st.st_mtimespec.tv_sec &&
        it->second.mtime.tv_nsec == st.st_mtimespec.tv_nsec) {
        if (!it->second.file)
            *err = it->second.err;
        return it->second.file;
    }
    auto f = std::make_shared<WasmFile>();
    f->path = path;
    CacheEntry ce;
    ce.size = st.st_size;
    ce.mtime = st.st_mtimespec;
    if (readFile(path, f->bytes, &ce.err)) {
        uint8_t md[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(f->bytes.data(), (CC_LONG)f->bytes.size(), md);
        f->sha256 = hex(md, sizeof md);
        if (checkFile(*f, &ce.err))
            ce.file = f;
    }
    if (g_cache.size() > 32)
        g_cache.clear();
    *err = ce.err;
    auto file = ce.file;
    g_cache[path] = std::move(ce);
    return file;
}

namespace {

// ------------------------------------------------------------------------------------------------ the layout ----
// fm1core_t as wasm32 lays it out: every pointer and function pointer 32 bits
struct core_w32 {
    uint32_t abi_version, id, name, version, source_url, family, license, gated, flash_size;
    uint32_t button_names[FM1P_NB];
    uint32_t params, nparams, panel, keymap;
    uint32_t options, boot_options, init, tick, frame, idle, audio, midi_in, midi_out_take, dump, stats, ui_info,
        shutdown, halted, flash_stage, flash, flash_dirty, flash_sync, param_epoch, knob_target, credits;
};

const int32_t LAYOUT[] = {
    sizeof(fm1panel_t),
    offsetof(fm1panel_t, keys), offsetof(fm1panel_t, buttons), offsetof(fm1panel_t, keys_tap),
    offsetof(fm1panel_t, buttons_tap), offsetof(fm1panel_t, enc), offsetof(fm1panel_t, master),
    offsetof(fm1panel_t, key_vel), offsetof(fm1panel_t, key_lean), offsetof(fm1panel_t, led),
    offsetof(fm1panel_t, led_play_green), offsetof(fm1panel_t, lcd), offsetof(fm1panel_t, lcd_writes),
    offsetof(fm1panel_t, btn_id), offsetof(fm1panel_t, enc_id), offsetof(fm1panel_t, enc_dir),
    offsetof(fm1panel_t, ready),
    sizeof(core_w32),
    offsetof(core_w32, abi_version), offsetof(core_w32, id), offsetof(core_w32, name), offsetof(core_w32, version),
    offsetof(core_w32, source_url), offsetof(core_w32, family), offsetof(core_w32, license), offsetof(core_w32, gated),
    offsetof(core_w32, flash_size), offsetof(core_w32, button_names), offsetof(core_w32, params),
    offsetof(core_w32, nparams), offsetof(core_w32, panel), offsetof(core_w32, keymap), offsetof(core_w32, options),
    offsetof(core_w32, credits),
};
constexpr int NLAYOUT = (int)(sizeof LAYOUT / sizeof LAYOUT[0]);

constexpr uint32_t STR_CAP = 1024;          // the scratch block: a string, MIDI / stats words, the audio
constexpr uint32_t WORDS = 16;
constexpr uint32_t AUDIO_FRAMES = 2048;
constexpr uint32_t SCRATCH = STR_CAP + WORDS + AUDIO_FRAMES * 4 + 16;
constexpr uint32_t HALT_TRAP = 0x200;

double usNow()
{
    static const double us = [] {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        return (double)tb.numer / (double)tb.denom / 1000.0;
    }();
    return (double)mach_absolute_time() * us;
}

os_log_t wasmLog()
{
    static os_log_t l = os_log_create("com.quixotic7.remotefm1", "wasm");
    return l;
}

class WasmCore final : public CoreBackend {
public:
    explicit WasmCore(std::shared_ptr<const WasmFile> f) : f_(std::move(f)) {}

    ~WasmCore() override
    {
        shutdown();
        if (rt_)
            m3_FreeRuntime(rt_);            // (the module with it)
        if (mod_ && !loaded_)
            m3_FreeModule(mod_);
        if (env_)
            m3_FreeEnvironment(env_);
    }

    // the instance made and checked (section 7 steps 2 and 3); false with the reason
    bool open(std::string *err)
    {
        const std::string who = base(f_->path) + ": ";
        auto bad = [&](const std::string &m) {
            *err = who + m;
            return false;
        };
        const double t0 = usNow();
        env_ = m3_NewEnvironment();
        rt_ = env_ ? m3_NewRuntime(env_, 1024 * 1024, this) : nullptr;
        if (!env_ || !rt_)
            return bad("not enough memory for the interpreter");
        M3Result r = m3_ParseModule(env_, &mod_, f_->bytes.data(), (uint32_t)f_->bytes.size());
        if (r)
            return bad(std::string("wasm3 can't parse it: ") + r);
        r = m3_LoadModule(rt_, mod_);
        if (r)
            return bad(std::string("wasm3 can't load it: ") + r);
        loaded_ = true;
        static const M3RawCall impl[] = {w_fd_write, w_fd_read, w_fd_close, w_fd_seek, w_clock_time_get, w_proc_exit};
        for (size_t i = 0; i < sizeof impl / sizeof impl[0]; i++) {
            r = m3_LinkRawFunctionEx(mod_, WASI, IMPORTS[i].name, IMPORTS[i].m3sig, impl[i], this);
            if (r && r != m3Err_functionLookupFailed)
                return bad(std::string("import ") + IMPORTS[i].name + ": " + r);
        }
        r = m3_CompileModule(mod_);
        if (r) {
            M3ErrorInfo info{};
            m3_GetErrorInfo(rt_, &info);
            return bad(std::string("wasm3 can't compile it: ") + r + (info.message ? std::string(" ") + info.message : "") +
                       " (WebAssembly outside the format's feature set, section 6?)");
        }
        for (int i = 0; i < F_N; i++) {
            if (m3_FindFunction(&fn_[i], rt_, FN[i].name)) {
                fn_[i] = nullptr;
                if (i == F_INITIALIZE)
                    continue;
                return bad(std::string("no export ") + FN[i].name);
            }
            if (m3_GetArgCount(fn_[i]) != FN[i].nargs || m3_GetRetCount(fn_[i]) != FN[i].nret)
                return bad(std::string("export ") + FN[i].name + ": the wrong number of arguments or results");
        }
        mem_ = m3_GetMemory(rt_, &memSize_, 0);
        if (!mem_ || memSize_ != f_->memory_pages * PAGE)
            return bad("its memory is not the size its module declares");

        call(F_INITIALIZE);
        if (dead_)
            return bad("_initialize trapped: " + trap_);
        const uint32_t v = call(F_VERSION);
        if (dead_ || v != 1)
            return bad(dead_ ? "rfm1_version trapped: " + trap_
                             : "rfm1_version() is " + std::to_string(v) + ": this app reads version 1");
        desc_ = call(F_GET, FM1CORE_ABI);
        if (dead_ || !desc_)
            return bad(dead_ ? "rfm1_get trapped: " + trap_
                             : "rfm1_get(" + std::to_string(FM1CORE_ABI) + ") is 0: the module doesn't speak ABI " +
                                   std::to_string(FM1CORE_ABI));
        for (int i = 0; i <= NLAYOUT; i++) {
            const int32_t got = (int32_t)call(F_LAYOUT, (uint32_t)i);
            const int32_t want = i < NLAYOUT ? LAYOUT[i] : -1;
            if (dead_)
                return bad("rfm1_layout trapped: " + trap_);
            if (got != want)
                return bad("rfm1_layout(" + std::to_string(i) + ") is " + std::to_string(got) + ", this host expects " +
                           std::to_string(want) + " (built against another fm1core.h?)");
        }
        if (!inMem(desc_, sizeof(core_w32)))
            return bad("its descriptor is outside its memory");
        std::memcpy(&w_, mem_ + desc_, sizeof w_);
        if (w_.abi_version != FM1CORE_ABI)
            return bad("its descriptor's abi_version is " + std::to_string(w_.abi_version));
        const char *id = cstr(w_.id), *name = cstr(w_.name), *version = cstr(w_.version);
        if (!id || !name || !version)
            return bad("its descriptor's id, name or version is not a string in its memory");
        if (f_->id != id || f_->name != name || f_->version != version)
            return bad("the manifest (" + f_->id + ", " + f_->name + ", " + f_->version + ") and the descriptor (" + id +
                       ", " + name + ", " + version + ") disagree");
        if (!inMem(w_.panel, sizeof(fm1panel_t)))
            return bad("its descriptor's panel is outside its memory");
        if (w_.keymap && !inMem(w_.keymap, 6 * FM1P_NCOL))
            return bad("its descriptor's keymap is outside its memory");

        d_.id = id;
        d_.name = name;
        d_.version = version;
        d_.source_url = f_->source_url;
        d_.family = s(w_.family);
        d_.license = f_->license;
        d_.gated = s(w_.gated);
        d_.credits = !f_->credits.empty() ? f_->credits : s(w_.credits);
        d_.abi = w_.abi_version;
        d_.flash_size = w_.flash ? w_.flash_size : 0;
        for (int i = 0; i < FM1P_NB; i++)
            d_.button_names[(size_t)i] = s(w_.button_names[i]);
        if (w_.keymap) {
            d_.has_keymap = true;
            std::memcpy(d_.keymap.data(), mem_ + w_.keymap, d_.keymap.size());
        } else {
            d_.keymap.fill(-1);
        }
        panel_ = reinterpret_cast<fm1panel_t *>(mem_ + w_.panel);

        scratch_ = call(F_ALLOC, SCRATCH);
        if (dead_ || !inMem(scratch_, SCRATCH))
            return bad("rfm1_alloc(" + std::to_string(SCRATCH) + ") failed" + (dead_ ? ": " + trap_ : std::string()));
        sStr_ = scratch_;
        sWords_ = scratch_ + STR_CAP;
        sAudio_ = (sWords_ + WORDS + 3u) & ~3u;
        loadUs_ = (uint32_t)(usNow() - t0);
        return true;
    }

    uint32_t loadUs() const { return loadUs_; }
    uint32_t memoryBytes() const { return memSize_; }

    const CoreDesc &info() const override { return d_; }
    const char *kind() const override { return "wasm"; }

    fm1panel_t *panel() override { return panel_; }
    uint8_t *flash() override
    {
        if (!d_.flash_size)
            return nullptr;
        if (!flash_ && !dead_) {
            const uint32_t p = call(F_FLASH);
            if (inMem(p, d_.flash_size))
                flash_ = mem_ + p;
        }
        return flash_;
    }

    void options(const char *path, int no_flash, int save, int headless) override
    {
        call(F_OPTIONS, putStr(path), (uint32_t)no_flash, (uint32_t)save, (uint32_t)headless);
    }
    bool has_boot_options() const override { return w_.boot_options != 0; }
    int boot_options(int fail, const char *reason, int stage) override
    {
        if (!w_.boot_options)
            return 1;
        return (int)call(F_BOOT_OPTIONS, (uint32_t)fail, putStr(reason), (uint32_t)stage);
    }
    void init(int demo) override { call(F_INIT, (uint32_t)demo); }
    void tick(uint32_t ms) override { call(F_TICK, ms); }
    void frame() override { call(F_FRAME); }
    void idle() override { call(F_IDLE); }
    void audio(int16_t *stereo, uint32_t frames) override
    {
        while (frames) {
            const uint32_t n = frames < AUDIO_FRAMES ? frames : AUDIO_FRAMES;
            if (dead_) {
                std::memset(stereo, 0, (size_t)n * 4);
            } else {
                call(F_AUDIO, sAudio_, n);
                std::memcpy(stereo, mem_ + sAudio_, (size_t)n * 4);
            }
            stereo += 2 * n;
            frames -= n;
        }
    }
    int midi_in(uint32_t pkt) override { return w_.midi_in ? (int)call(F_MIDI_IN, pkt) : 1; }
    int midi_out_take(uint32_t *pkt) override
    {
        if (!w_.midi_out_take || dead_)
            return 0;
        const int r = (int)call(F_MIDI_OUT_TAKE, sWords_);
        if (r && pkt)
            std::memcpy(pkt, mem_ + sWords_, 4);
        return dead_ ? 0 : r;
    }
    bool stats(uint32_t *shed, uint32_t *cpu) override
    {
        if (!w_.stats || dead_)
            return false;
        std::memset(mem_ + sWords_, 0, 8);
        call(F_STATS, sWords_, sWords_ + 4);
        if (shed)
            std::memcpy(shed, mem_ + sWords_, 4);
        if (cpu)
            std::memcpy(cpu, mem_ + sWords_ + 4, 4);
        return true;
    }
    void ui_info(char *buf, uint32_t n) override
    {
        if (!buf || !n)
            return;
        buf[0] = 0;
        if (!w_.ui_info || dead_)
            return;
        const uint32_t cap = n < STR_CAP ? n : STR_CAP;
        mem_[sStr_] = 0;
        call(F_UI_INFO, sStr_, cap);
        if (dead_)
            return;
        mem_[sStr_ + cap - 1] = 0;
        std::memcpy(buf, mem_ + sStr_, std::strlen((const char *)mem_ + sStr_) + 1);
    }
    void shutdown() override
    {
        if (shut_ || !rt_ || !fn_[F_SHUTDOWN])
            return;
        shut_ = true;
        if (w_.shutdown)
            call(F_SHUTDOWN);
    }
    int halted() override
    {
        if (dead_)
            return (int)haltCode_;
        return w_.halted ? (int)call(F_HALTED) : 0;
    }
    int flash_stage(const uint8_t *bytes, uint32_t n) override
    {
        if (!w_.flash_stage)
            return 0;
        if (!bytes || !n)
            return (int)call(F_FLASH_STAGE, 0, 0);
        const uint32_t p = call(F_ALLOC, n);
        if (dead_ || !inMem(p, n))
            return 0;
        std::memcpy(mem_ + p, bytes, n);
        const int r = (int)call(F_FLASH_STAGE, p, n);
        call(F_FREE, p);
        return r;
    }
    uint32_t flash_dirty() override { return w_.flash_dirty ? call(F_FLASH_DIRTY) : 0; }
    int flash_sync() override { return w_.flash_sync ? (int)call(F_FLASH_SYNC) : 1; }

private:
    bool inMem(uint32_t off, uint32_t n) const { return off && (uint64_t)off + n <= memSize_; }
    const char *cstr(uint32_t off) const
    {
        if (!off || off >= memSize_)
            return nullptr;
        return std::memchr(mem_ + off, 0, memSize_ - off) ? (const char *)mem_ + off : nullptr;
    }
    std::string s(uint32_t off) const
    {
        const char *c = cstr(off);
        return c ? c : "";
    }
    // a C string into the scratch block (cut at STR_CAP - 1); 0 for nullptr
    uint32_t putStr(const char *str)
    {
        if (!str)
            return 0;
        size_t n = std::strlen(str);
        if (n > STR_CAP - 1)
            n = STR_CAP - 1;
        std::memcpy(mem_ + sStr_, str, n);
        mem_[sStr_ + n] = 0;
        return sStr_;
    }

    uint32_t call(int f, uint32_t a0 = 0, uint32_t a1 = 0, uint32_t a2 = 0, uint32_t a3 = 0)
    {
        if (dead_ || !fn_[f])
            return 0;
        const uint32_t a[4] = {a0, a1, a2, a3};
        const void *ap[4] = {&a[0], &a[1], &a[2], &a[3]};
        const M3Result r = m3_Call(fn_[f], FN[f].nargs, ap);
        if (r) {
            die(f, r);
            return 0;
        }
        uint32_t ret = 0;
        if (FN[f].nret) {
            const void *rp[1] = {&ret};
            if (m3_GetResults(fn_[f], 1, rp))
                return 0;
        }
        return ret;
    }

    void die(int f, M3Result r)
    {
        dead_ = true;
        if (exitCode_ >= 0) {
            haltCode_ = 0x100u | ((uint32_t)exitCode_ & 0xFFu);
            trap_ = "exit(" + std::to_string(exitCode_) + ")";
        } else {
            haltCode_ = HALT_TRAP;
            M3ErrorInfo info{};
            m3_GetErrorInfo(rt_, &info);
            trap_ = std::string(FN[f].name) + ": " + r + (info.message ? std::string(" ") + info.message : "");
        }
        os_log_error(wasmLog(), "%{public}s %{public}s: halted (%{public}s)", d_.id.c_str(), d_.version.c_str(),
                     trap_.c_str());
    }

    // ---- WASI (section 3)
    static WasmCore *self(IM3ImportContext ctx) { return (WasmCore *)ctx->userdata; }

    void logWrite(uint32_t fd, const uint8_t *p, uint32_t n)
    {
        // at most 40 lines a second, bursts of 80, each up to 400 bytes; what's dropped is counted
        const double now = usNow();
        tokens_ += (now - lastLog_) * 40e-6;
        lastLog_ = now;
        if (tokens_ > 80)
            tokens_ = 80;
        if (tokens_ < 1) {
            dropped_++;
            return;
        }
        tokens_ -= 1;
        int len = (int)(n > 400 ? 400 : n);
        while (len > 0 && (p[len - 1] == '\n' || p[len - 1] == '\r'))
            len--;
        if (len <= 0)
            return;
        if (dropped_) {
            os_log(wasmLog(), "%{public}s: %u log lines dropped", d_.id.c_str(), dropped_);
            dropped_ = 0;
        }
        os_log(wasmLog(), "%{public}s %{public}s: %{public}.*s", d_.id.c_str(), fd == 2 ? "stderr" : "stdout", len,
               (const char *)p);
    }

    static m3ApiRawFunction(w_fd_write)
    {
        m3ApiReturnType(int32_t);
        m3ApiGetArg(uint32_t, fd);
        m3ApiGetArg(uint32_t, iovs);
        m3ApiGetArg(uint32_t, niov);
        m3ApiGetArg(uint32_t, nwritten);
        const uint32_t size = m3_GetMemorySize(runtime);
        uint8_t *m = (uint8_t *)_mem;
        if (fd != 1 && fd != 2)
            m3ApiReturn(8);                 // EBADF
        uint32_t total = 0;
        for (uint32_t i = 0; i < niov; i++) {
            uint32_t p, n;
            if ((uint64_t)iovs + 8u * i + 8u > size)
                m3ApiReturn(28);            // EINVAL
            std::memcpy(&p, m + iovs + 8u * i, 4);
            std::memcpy(&n, m + iovs + 8u * i + 4u, 4);
            if ((uint64_t)p + n > size)
                m3ApiReturn(28);
            if (n)
                self(_ctx)->logWrite(fd, m + p, n);
            total += n;
        }
        if ((uint64_t)nwritten + 4u <= size)
            std::memcpy(m + nwritten, &total, 4);
        m3ApiReturn(0);
    }
    static m3ApiRawFunction(w_fd_read)
    {
        m3ApiReturnType(int32_t);
        (void)runtime; (void)_ctx; (void)_mem;
        m3ApiReturn(8);
    }
    static m3ApiRawFunction(w_fd_close)
    {
        m3ApiReturnType(int32_t);
        (void)runtime; (void)_ctx; (void)_mem;
        m3ApiReturn(8);
    }
    static m3ApiRawFunction(w_fd_seek)
    {
        m3ApiReturnType(int32_t);
        (void)runtime; (void)_ctx; (void)_mem;
        m3ApiReturn(8);
    }
    static m3ApiRawFunction(w_clock_time_get)
    {
        m3ApiReturnType(int32_t);
        m3ApiGetArg(uint32_t, id);
        m3ApiGetArg(uint64_t, precision);
        m3ApiGetArg(uint32_t, out);
        (void)id; (void)precision; (void)_ctx;
        if ((uint64_t)out + 8u > m3_GetMemorySize(runtime))
            m3ApiReturn(28);
        const uint64_t ns = (uint64_t)(usNow() * 1000.0);
        std::memcpy((uint8_t *)_mem + out, &ns, 8);
        m3ApiReturn(0);
    }
    static m3ApiRawFunction(w_proc_exit)
    {
        m3ApiGetArg(uint32_t, code);
        (void)runtime; (void)_mem;
        self(_ctx)->exitCode_ = (int)(code & 0xFFu);
        m3ApiTrap(m3Err_trapExit);
    }

    std::shared_ptr<const WasmFile> f_;
    IM3Environment env_ = nullptr;
    IM3Runtime rt_ = nullptr;
    IM3Module mod_ = nullptr;
    bool loaded_ = false;
    IM3Function fn_[F_N] = {};
    uint8_t *mem_ = nullptr;
    uint32_t memSize_ = 0;
    uint32_t desc_ = 0, scratch_ = 0, sStr_ = 0, sWords_ = 0, sAudio_ = 0;
    core_w32 w_{};
    CoreDesc d_;
    fm1panel_t *panel_ = nullptr;
    uint8_t *flash_ = nullptr;
    bool dead_ = false, shut_ = false;
    int exitCode_ = -1;
    uint32_t haltCode_ = 0;
    std::string trap_;
    uint32_t loadUs_ = 0;
    double tokens_ = 80, lastLog_ = 0;
    uint32_t dropped_ = 0;
};

void put(char *dst, size_t cap, const std::string &s)
{
    if (!dst || !cap)
        return;
    const size_t n = s.size() < cap - 1 ? s.size() : cap - 1;
    std::memcpy(dst, s.data(), n);
    dst[n] = 0;
}

} // namespace

CoreFactory wasmCoreFactory(std::shared_ptr<const WasmFile> file)
{
    return [file](std::string *err) -> std::unique_ptr<CoreBackend> {
        auto c = std::make_unique<WasmCore>(file);
        std::string msg;
        if (!c->open(&msg)) {
            if (err)
                *err = msg;
            return nullptr;
        }
        return c;
    };
}

} // namespace rfm

extern "C" {

int rfmw_check(const char *path, rfmw_info_t *out, char *err, uint32_t n)
{
    std::string msg;
    auto f = rfm::wasmOpen(path ? path : "", &msg);
    if (!f) {
        rfm::put(err, n, msg);
        return 0;
    }
    rfm::WasmCore c(f);
    if (!c.open(&msg)) {
        rfm::put(err, n, msg);
        return 0;
    }
    if (out) {
        std::memset(out, 0, sizeof *out);
        const rfm::CoreDesc &d = c.info();
        rfm::put(out->id, sizeof out->id, d.id);
        rfm::put(out->name, sizeof out->name, d.name);
        rfm::put(out->version, sizeof out->version, d.version);
        rfm::put(out->family, sizeof out->family, d.family);
        rfm::put(out->license, sizeof out->license, d.license);
        rfm::put(out->sha256, sizeof out->sha256, f->sha256);
        out->abi = d.abi;
        out->flash_size = d.flash_size;
        out->memory_bytes = c.memoryBytes();
        out->file_size = (uint32_t)f->bytes.size();
        out->load_us = c.loadUs();
    }
    return 1;
}

uint32_t rfmw_text(const char *path, const char *what, char *buf, uint32_t n)
{
    std::string msg;
    auto f = rfm::wasmOpen(path ? path : "", &msg);
    if (!f || !what)
        return 0;
    const std::string w = what;
    const std::string *s = nullptr;
    if (w == "manifest")
        s = &f->manifest_json;
    else if (w == "credits")
        s = &f->credits;
    else if (w.rfind("license.", 0) == 0) {
        const unsigned long i = std::strtoul(w.c_str() + 8, nullptr, 10);
        if (i < f->licenses.size())
            s = &f->licenses[i];
    }
    if (!s || s->empty())
        return 0;
    rfm::put(buf, n, *s);
    return (uint32_t)s->size();
}

int rfmw_sha256(const char *path, char out[65])
{
    std::vector<uint8_t> b;
    std::string err;
    if (!path || !rfm::readFile(path, b, &err))
        return 0;
    uint8_t md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(b.data(), (CC_LONG)b.size(), md);
    rfm::put(out, 65, rfm::hex(md, sizeof md));
    return 1;
}

int rfme_load_wasm(rfme_t *e, const char *path, char *err, uint32_t n)
{
    std::string msg;
    auto f = rfm::wasmOpen(path ? path : "", &msg);
    if (!f) {
        rfm::put(err, n, msg);
        return 0;
    }
    if (rfm::engineLoad(e, rfm::wasmCoreFactory(f), &msg))
        return 1;
    rfm::put(err, n, msg);
    return 0;
}

} // extern "C"
