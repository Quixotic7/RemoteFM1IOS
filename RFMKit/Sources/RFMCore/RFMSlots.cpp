// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The slot loader (RFMSlots.h) and its C face (rfms_*, include/RFMEngine.h). open_core is FM1VST v0.6.2's
// engine/cores.cpp open_core (the descriptor probe and the ABI check), with its messages shortened.
#include "RFMSlots.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <dlfcn.h>
#include <sys/stat.h>

#include <algorithm>
#include <cstring>
#include <map>

#include "RFMEngine.h"

namespace rfm {

static bool isFile(const std::string &p)
{
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

static std::string cfPath(CFURLRef u)
{
    if (!u)
        return "";
    char buf[4096];
    const bool ok = CFURLGetFileSystemRepresentation(u, true, reinterpret_cast<UInt8 *>(buf), sizeof buf);
    CFRelease(u);
    return ok ? buf : "";
}

// the main bundle's Frameworks; inside an app extension (<app>/PlugIns/<x>.appex) also the containing app's
static std::vector<std::string> bundleDirs()
{
    std::vector<std::string> d;
    CFBundleRef b = CFBundleGetMainBundle();
    if (!b)
        return d;
    const std::string own = cfPath(CFBundleCopyPrivateFrameworksURL(b));
    if (!own.empty())
        d.push_back(own);
    const std::string path = cfPath(CFBundleCopyBundleURL(b));
    if (path.size() > 6 && path.compare(path.size() - 6, 6, ".appex") == 0)
        d.push_back(path + "/../../Frameworks");
    return d;
}

// FM1Core_<id>_<n>.framework -> id, n
static bool slotName(const std::string &entry, std::string &id, int &n)
{
    static const std::string pre = "FM1Core_", suf = ".framework";
    if (entry.size() <= pre.size() + suf.size() || entry.compare(0, pre.size(), pre) != 0 ||
        entry.compare(entry.size() - suf.size(), suf.size(), suf) != 0)
        return false;
    const std::string mid = entry.substr(pre.size(), entry.size() - pre.size() - suf.size());
    const size_t us = mid.rfind('_');
    if (us == std::string::npos || us == 0 || us + 1 >= mid.size())
        return false;
    n = 0;
    for (size_t i = us + 1; i < mid.size(); i++) {
        if (mid[i] < '0' || mid[i] > '9')
            return false;
        n = n * 10 + (mid[i] - '0');
    }
    id = mid.substr(0, us);
    return n >= 1 && n <= 64;
}

static const fm1core_t *open_core(const std::string &path, void **handle, std::string *error)
{
    void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        if (error) {
            const char *e = dlerror();
            *error = path + ": " + (e ? e : "dlopen failed");
        }
        return nullptr;
    }
    auto get = reinterpret_cast<fm1core_get_fn>(dlsym(h, FM1CORE_SYMBOL));
    if (!get) {
        if (error)
            *error = path + ": no " FM1CORE_SYMBOL " (not a core)";
        dlclose(h);
        return nullptr;
    }
    const fm1core_t *c = nullptr;   // this host's ABI, else an older one it still loads (ABI 5: no credits)
    for (uint32_t v = FM1CORE_ABI; v >= FM1CORE_ABI_MIN && !c; v--) {
        c = get(v);
        if (c && c->abi_version != v)
            c = nullptr;
    }
    if (!c) {
        uint32_t built = 0;
        for (uint32_t v = 1; v < 64 && !built; v++)
            if ((v < FM1CORE_ABI_MIN || v > FM1CORE_ABI) && get(v))
                built = v;
        if (error)
            *error = path + ": " + (built ? "a core for ABI " + std::to_string(built) : std::string("another ABI")) +
                     "; this host loads ABI " + std::to_string(FM1CORE_ABI_MIN) + ".." + std::to_string(FM1CORE_ABI);
        dlclose(h);
        return nullptr;
    }
    *handle = h;
    return c;
}

static std::string str(const char *s) { return s ? s : ""; }

// dlclose, and whether the image really left (a later dlopen then maps fresh globals)
static bool unload(void *h, const std::string &path)
{
    dlclose(h);
    void *again = dlopen(path.c_str(), RTLD_NOW | RTLD_NOLOAD);
    if (!again)
        return true;
    dlclose(again);
    return false;
}

void *SlotLoader::Slot::symbol(const char *name) const { return handle && name ? dlsym(handle, name) : nullptr; }

SlotLoader &SlotLoader::shared()
{
    static SlotLoader l;
    return l;
}

int SlotLoader::scan(const std::string &dir)
{
    std::lock_guard<std::mutex> g(mu_);
    dirs_ = dir.empty() ? bundleDirs() : std::vector<std::string>{dir};
    errors_.clear();
    std::map<std::string, std::vector<std::string>> found;   // id -> paths by slot
    for (const std::string &d : dirs_) {
        DIR *dp = opendir(d.c_str());
        if (!dp)
            continue;
        while (struct dirent *de = readdir(dp)) {
            std::string id;
            int n = 0;
            const std::string entry = de->d_name;
            if (!slotName(entry, id, n))
                continue;
            const std::string bin = entry.substr(0, entry.size() - 10);   // (".framework")
            std::string p = d + "/" + entry + "/" + bin;
            if (!isFile(p))
                p = d + "/" + entry + "/Versions/Current/" + bin;
            if (!isFile(p))
                continue;
            auto &v = found[id];
            if ((int)v.size() < n)
                v.resize((size_t)n);
            if (v[(size_t)n - 1].empty())            // (the first directory wins)
                v[(size_t)n - 1] = p;
        }
        closedir(dp);
    }
    std::vector<CoreSlotInfo> next;
    for (auto &kv : found) {
        CoreSlotInfo info;
        info.id = kv.first;
        info.paths = kv.second;
        // the descriptor from a slot nobody holds (a held one gives the same descriptor; nothing is initialised)
        std::string probe;
        for (const std::string &p : info.paths)
            if (!p.empty() && (probe.empty() || std::find(held_.begin(), held_.end(), probe) != held_.end()))
                probe = p;
        void *h = nullptr;
        std::string err;
        const fm1core_t *c = open_core(probe, &h, &err);
        if (!c) {
            errors_ += (errors_.empty() ? "" : "; ") + err;
            continue;
        }
        info.name = str(c->name);
        info.version = str(c->version);
        info.source_url = str(c->source_url);
        info.family = str(c->family);
        info.license = str(c->license);
        info.gated = str(c->gated);
        info.credits = str(fm1core_credits(c));
        info.abi = c->abi_version;
        info.flash_size = c->flash_size;
        if (str(c->id) != info.id)
            errors_ += (errors_.empty() ? "" : "; ") + probe + ": its descriptor says id " + str(c->id);
        dlclose(h);                                  // (a probe: nothing to shut down)
        next.push_back(info);
    }
    cores_ = next;
    return (int)cores_.size();
}

std::vector<CoreSlotInfo> SlotLoader::cores() const
{
    std::lock_guard<std::mutex> g(mu_);
    return cores_;
}

bool SlotLoader::find(const std::string &id, CoreSlotInfo &out) const
{
    std::lock_guard<std::mutex> g(mu_);
    for (const CoreSlotInfo &c : cores_)
        if (c.id == id) {
            out = c;
            return true;
        }
    return false;
}

static int countIn(const std::vector<std::string> &v, const CoreSlotInfo &c)
{
    int n = 0;
    for (const std::string &p : c.paths)
        if (!p.empty() && std::find(v.begin(), v.end(), p) != v.end())
            n++;
    return n;
}

int SlotLoader::inUse(const std::string &id) const
{
    CoreSlotInfo c;
    if (!find(id, c))
        return 0;
    std::lock_guard<std::mutex> g(mu_);
    return countIn(held_, c);
}

int SlotLoader::retired(const std::string &id) const
{
    CoreSlotInfo c;
    if (!find(id, c))
        return 0;
    std::lock_guard<std::mutex> g(mu_);
    return countIn(retired_, c);
}

std::string SlotLoader::dirs() const
{
    std::lock_guard<std::mutex> g(mu_);
    std::string s;
    for (const std::string &d : dirs_)
        s += (s.empty() ? "" : "; ") + d;
    return s;
}

std::string SlotLoader::errors() const
{
    std::lock_guard<std::mutex> g(mu_);
    return errors_;
}

SlotLoader::Slot *SlotLoader::acquire(const std::string &id, std::string *err)
{
    std::lock_guard<std::mutex> g(mu_);
    const CoreSlotInfo *info = nullptr;
    for (const CoreSlotInfo &c : cores_)
        if (c.id == id)
            info = &c;
    if (!info) {
        if (err)
            *err = "no core \"" + id + "\" in " + (dirs_.empty() ? std::string("the bundle") : dirs_[0]);
        return nullptr;
    }
    int present = 0;
    for (size_t i = 0; i < info->paths.size(); i++) {
        const std::string &p = info->paths[i];
        if (p.empty())
            continue;
        present++;
        if (std::find(held_.begin(), held_.end(), p) != held_.end() ||
            std::find(retired_.begin(), retired_.end(), p) != retired_.end())
            continue;
        void *h = nullptr;
        std::string e;
        const fm1core_t *c = open_core(p, &h, &e);
        if (!c) {
            if (err)
                *err = e;
            return nullptr;
        }
        auto *s = new Slot;
        s->id = id;
        s->path = p;
        s->n = (int)i + 1;
        s->handle = h;
        s->core = c;
        held_.push_back(p);
        return s;
    }
    if (err) {
        const int r = countIn(retired_, *info);
        *err = "at most " + std::to_string(present - r) + " " + info->name + " per host: all its slots are in use" +
               (r ? " (" + std::to_string(r) + " retired)" : "");
    }
    return nullptr;
}

void SlotLoader::release(Slot *s)
{
    if (!s)
        return;
    if (s->core && s->core->shutdown)
        s->core->shutdown();
    const bool gone = s->handle ? unload(s->handle, s->path) : true;
    {
        std::lock_guard<std::mutex> g(mu_);
        held_.erase(std::remove(held_.begin(), held_.end(), s->path), held_.end());
        if (!gone)
            retired_.push_back(s->path);
    }
    delete s;
}

} // namespace rfm

// ---- the C face
using rfm::CoreSlotInfo;
using rfm::SlotLoader;

static void put(char *dst, size_t n, const std::string &s)
{
    std::strncpy(dst, s.c_str(), n - 1);
    dst[n - 1] = 0;
}

static uint32_t putAll(char *buf, uint32_t n, const std::string &s)
{
    if (buf && n) {
        const size_t k = std::min<size_t>(n - 1, s.size());
        std::memcpy(buf, s.data(), k);
        buf[k] = 0;
    }
    return (uint32_t)s.size();
}

static void fill(const CoreSlotInfo &c, rfms_info_t *o)
{
    std::memset(o, 0, sizeof *o);
    put(o->id, sizeof o->id, c.id);
    put(o->name, sizeof o->name, c.name);
    put(o->version, sizeof o->version, c.version);
    put(o->family, sizeof o->family, c.family);
    put(o->license, sizeof o->license, c.license);
    put(o->gated, sizeof o->gated, c.gated);
    put(o->source_url, sizeof o->source_url, c.source_url);
    o->abi = c.abi;
    o->flash_size = c.flash_size;
    for (const std::string &p : c.paths)
        o->slots += p.empty() ? 0 : 1;
    o->in_use = SlotLoader::shared().inUse(c.id);
    o->retired = SlotLoader::shared().retired(c.id);
}

extern "C" {

int rfms_scan(const char *dir) { return SlotLoader::shared().scan(dir ? dir : ""); }

int rfms_count(void) { return (int)SlotLoader::shared().cores().size(); }

int rfms_info(int i, rfms_info_t *out)
{
    const std::vector<CoreSlotInfo> c = SlotLoader::shared().cores();
    if (i < 0 || i >= (int)c.size())
        return 0;
    fill(c[(size_t)i], out);
    return 1;
}

int rfms_find(const char *id, rfms_info_t *out)
{
    CoreSlotInfo c;
    if (!id || !SlotLoader::shared().find(id, c))
        return 0;
    fill(c, out);
    return 1;
}

uint32_t rfms_credits(const char *id, char *buf, uint32_t n)
{
    CoreSlotInfo c;
    if (!id || !SlotLoader::shared().find(id, c))
        return putAll(buf, n, "");
    return putAll(buf, n, c.credits);
}

uint32_t rfms_dirs(char *buf, uint32_t n) { return putAll(buf, n, SlotLoader::shared().dirs()); }

uint32_t rfms_errors(char *buf, uint32_t n) { return putAll(buf, n, SlotLoader::shared().errors()); }

} // extern "C"
