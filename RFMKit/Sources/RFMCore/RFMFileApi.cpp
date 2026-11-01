// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// A Fantasy CFW's file API (RFMFileApi.h). The rules follow the web player's FileApi (RemoteFM1 web/engines/rfm1/
// engine.js, branch fantasy-cfw) and FM1VST docs/VIRTUAL-CARTS.md section 4. Platform-neutral but for
// fsPosixFolder (POSIX calls, no Apple types): the Android app ports this file as it is.
#include "RFMFileApi.h"

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>

namespace rfm {

// ------------------------------------------------------------------------------------------------ the folder ----
namespace {

std::mutex g_folderMu;
std::shared_ptr<FsFolder> g_folder;
std::atomic<uint32_t> g_changed{0};
std::atomic<uint64_t> g_reads{0};

int32_t fromErrno(int e)
{
    switch (e) {
    case ENOENT:
    case ENOTDIR: return FS_ENOENT;
    case EACCES:
    case EPERM:
    case EROFS: return FS_EACCES;
    case ENOSPC:
#ifdef EDQUOT
    case EDQUOT:
#endif
        return FS_ENOSPC;
    default: return FS_EIO;
    }
}

class PosixFolder final : public FsFolder {
public:
    explicit PosixFolder(std::string root) : given_(std::move(root)) {}

    int32_t stat(const std::string &rel, FsStat &out) override
    {
        std::string p;
        if (int32_t e = path(rel, p, false))
            return e;
        struct stat st;
        if (::stat(p.c_str(), &st))
            return fromErrno(errno);
        out.dir = S_ISDIR(st.st_mode);
        out.size = out.dir ? 0 : (uint64_t)st.st_size;
        out.mtime = (uint32_t)st.st_mtime;
        return 0;
    }
    int32_t list(const std::string &rel, std::vector<FsEntry> &out) override
    {
        std::string p;
        if (int32_t e = path(rel, p, false))
            return e;
        DIR *d = ::opendir(p.c_str());
        if (!d)
            return fromErrno(errno);
        while (struct dirent *de = ::readdir(d)) {
            FsEntry e;
            e.name = de->d_name;
            if (e.name == "." || e.name == "..")
                continue;
            if (de->d_type == DT_DIR) {
                e.dir = true;
            } else if (de->d_type == DT_LNK || de->d_type == DT_UNKNOWN) {
                struct stat st;
                e.dir = ::stat((p + "/" + e.name).c_str(), &st) == 0 && S_ISDIR(st.st_mode);
            }
            out.push_back(std::move(e));
        }
        ::closedir(d);
        return 0;
    }
    int32_t read(const std::string &rel, uint64_t offset, uint8_t *buf, uint32_t len) override
    {
        std::string p;
        if (int32_t e = path(rel, p, false))
            return e;
        const int fd = ::open(p.c_str(), O_RDONLY);
        if (fd < 0)
            return fromErrno(errno);
        struct stat st;
        if (::fstat(fd, &st) == 0 && S_ISDIR(st.st_mode)) {
            ::close(fd);
            return FS_EIO;
        }
        uint32_t got = 0;
        while (got < len) {
            if (offset + got > (uint64_t)INT64_MAX)
                break;
            const ssize_t n = ::pread(fd, buf + got, len - got, (off_t)(offset + got));
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                const int e = errno;
                ::close(fd);
                return fromErrno(e);
            }
            if (n == 0)
                break;
            got += (uint32_t)n;
        }
        ::close(fd);
        return (int32_t)got;
    }
    int32_t write(const std::string &rel, int64_t offset, const uint8_t *buf, uint32_t len) override
    {
        std::string p;
        if (int32_t e = path(rel, p, true))
            return e;
        struct stat st;
        if (::stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode))
            return FS_EIO;
        const int fd = ::open(p.c_str(), O_WRONLY | O_CREAT | (offset < 0 ? O_TRUNC : 0), 0644);
        if (fd < 0)
            return fromErrno(errno);
        const uint64_t at = offset < 0 ? 0 : (uint64_t)offset;
        uint32_t put = 0;
        while (put < len) {
            const ssize_t n = ::pwrite(fd, buf + put, len - put, (off_t)(at + put));
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                const int e = errno;
                ::close(fd);
                return fromErrno(e);
            }
            put += (uint32_t)n;
        }
        ::close(fd);
        return (int32_t)put;
    }
    int32_t remove(const std::string &rel) override
    {
        std::string p;
        if (int32_t e = path(rel, p, false))
            return e;
        struct stat st;
        if (::lstat(p.c_str(), &st))
            return fromErrno(errno);
        if (S_ISDIR(st.st_mode))
            return ::rmdir(p.c_str()) ? (errno == ENOTEMPTY || errno == EEXIST ? FS_EIO : fromErrno(errno)) : 0;
        return ::unlink(p.c_str()) ? fromErrno(errno) : 0;
    }
    int32_t mkdir(const std::string &rel) override
    {
        std::string p;
        if (int32_t e = path(rel, p, true))
            return e;
        if (::mkdir(p.c_str(), 0755) == 0)
            return 0;
        const int e = errno;
        struct stat st;
        if (e == EEXIST && ::stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode))
            return 0;
        return fromErrno(e);
    }

private:
    // the folder's real path ("" when it isn't there)
    std::string root()
    {
        char r[PATH_MAX];
        return ::realpath(given_.c_str(), r) ? std::string(r) : std::string();
    }
    // the full path of rel, once it (or, for one being made, its folder) resolves inside the folder: no symlink out
    int32_t path(const std::string &rel, std::string &out, bool making)
    {
        const std::string r = root();
        if (r.empty())
            return FS_ENOFOLDER;
        out = r + "/" + rel;
        std::string probe = out;
        char rp[PATH_MAX];
        if (!::realpath(probe.c_str(), rp)) {
            if (errno != ENOENT)
                return fromErrno(errno);
            const size_t sl = probe.find_last_of('/');
            if (sl == std::string::npos || sl < r.size())
                return FS_ENOENT;
            probe.resize(sl);
            if (!::realpath(probe.c_str(), rp))
                return FS_ENOENT;
            if (!making) {
                // (the file isn't there: its folder must still be inside, else it's an escape, not a miss)
                const std::string got(rp);
                if (got.compare(0, r.size(), r) || (got.size() > r.size() && got[r.size()] != '/'))
                    return FS_EACCES;
                return FS_ENOENT;
            }
        }
        const std::string got(rp);
        if (got.compare(0, r.size(), r) || (got.size() > r.size() && got[r.size()] != '/'))
            return FS_EACCES;
        return 0;
    }

    const std::string given_;
};

// strict UTF-8 (no overlongs, no surrogates, nothing over U+10FFFF), and no U+FFFD
bool goodUtf8(const uint8_t *s, uint32_t n)
{
    for (uint32_t i = 0; i < n;) {
        const uint8_t c = s[i];
        uint32_t k = 0, u = 0;
        if (c < 0x80) { i++; continue; }
        else if (c >= 0xC2 && c < 0xE0) { k = 1; u = c & 0x1F; }
        else if (c >= 0xE0 && c < 0xF0) { k = 2; u = c & 0x0F; }
        else if (c >= 0xF0 && c < 0xF5) { k = 3; u = c & 0x07; }
        else return false;
        for (uint32_t j = 1; j <= k; j++) {
            if (i + j >= n || (s[i + j] & 0xC0) != 0x80)
                return false;
            u = (u << 6) | (s[i + j] & 0x3F);
        }
        if ((k == 2 && u < 0x800) || (k == 3 && (u < 0x10000 || u > 0x10FFFF)) || (u >= 0xD800 && u < 0xE000) ||
            u == 0xFFFD)
            return false;
        i += k + 1;
    }
    return true;
}

} // namespace

std::shared_ptr<FsFolder> fsPosixFolder(const std::string &root) { return std::make_shared<PosixFolder>(root); }

void fsSetFolder(std::shared_ptr<FsFolder> folder)
{
    {
        std::lock_guard<std::mutex> g(g_folderMu);
        g_folder = std::move(folder);
    }
    fsBumpChanged();
}

std::shared_ptr<FsFolder> fsFolder()
{
    std::lock_guard<std::mutex> g(g_folderMu);
    return g_folder;
}

void fsBumpChanged() { g_changed.fetch_add(1, std::memory_order_relaxed); }
uint32_t fsChangedCount() { return g_changed.load(std::memory_order_relaxed); }
uint64_t fsReadCount() { return g_reads.load(std::memory_order_relaxed); }

// ------------------------------------------------------------------------------------------------ FileApi -------
FileApi::FileApi(std::string id, FsModes modes, std::shared_ptr<FsFolder> fixed)
    : id_(std::move(id)), modes_(modes), fixed_(std::move(fixed))
{
}

FileApi::~FileApi()
{
    {
        std::lock_guard<std::mutex> g(mu_);
        stop_ = true;
    }
    cv_.notify_all();
    if (io_.joinable())
        io_.join();
}

// the cart's path (bytes in its memory) -> its area ('a', 'c', 'd'), whether it is the area itself, and the folder's
// path ("code/<id>/droplets"); false when section 3 refuses it
bool FileApi::folderPath(const uint8_t *mem, uint32_t memSize, uint32_t at, uint32_t n, char &root, bool &top,
                         std::string &rel) const
{
    if (n < 2 || n > FS_MAX_PATH || (uint64_t)at + n > memSize)
        return false;
    const uint8_t *b = mem + at;
    if (b[0] != '/')
        return false;
    for (uint32_t i = 0; i < n; i++)
        if (b[i] == 0 || b[i] == '\\')
            return false;
    if (!goodUtf8(b, n))
        return false;
    std::vector<std::string> seg;
    std::string cur;
    for (uint32_t i = 1; i < n; i++) {
        if (b[i] == '/') {
            seg.push_back(cur);
            cur.clear();
        } else {
            cur += (char)b[i];
        }
    }
    seg.push_back(cur);
    for (const std::string &x : seg)
        if (x.empty() || x == "." || x == ".." || x.size() > 255)
            return false;
    if (seg[0] == "audio")
        root = 'a';
    else if (seg[0] == "code")
        root = 'c';
    else if (seg[0] == "data")
        root = 'd';
    else
        return false;
    top = seg.size() == 1;
    rel = root == 'a' ? std::string("audio") : seg[0] + "/" + id_;
    for (size_t i = 1; i < seg.size(); i++)
        rel += "/" + seg[i];
    return true;
}

int32_t FileApi::request(int32_t op, const uint8_t *mem, uint32_t memSize, uint32_t pathAt, uint32_t pathLen,
                         int64_t offset, uint32_t buf, int32_t len)
{
    if (op < FS_STAT || op > FS_MKDIR)
        return FS_EIO;
    int inflight = 0;
    for (const auto &kv : reqs_)
        if (!kv.second.canceled)
            inflight++;
    if (inflight >= FS_MAX_INFLIGHT)
        return FS_EBUSY;
    char root = 0;
    bool top = false;
    std::string rel;
    if (!folderPath(mem, memSize, pathAt, pathLen, root, top, rel))
        return FS_EACCES;
    const bool writes = op == FS_WRITE || op == FS_DELETE || op == FS_MKDIR;
    const uint8_t mode = root == 'a' ? modes_.audio : root == 'c' ? modes_.code : modes_.data;
    if (writes ? (root != 'd' || mode != FsModes::ReadWrite || top) : !(mode & FsModes::Read))
        return FS_EACCES;
    if (len < 0)
        return FS_EIO;
    uint32_t n = 0;
    if (op == FS_STAT) {
        if (len < 16 || (uint64_t)buf + 16 > memSize)
            return FS_EIO;
        n = 16;
    } else if (op == FS_LIST || op == FS_READ || op == FS_WRITE) {
        n = (uint32_t)len < FS_MAX_LEN ? (uint32_t)len : FS_MAX_LEN;
        if ((uint64_t)buf + n > memSize)
            return FS_EIO;
        if (offset < (op == FS_WRITE ? -1 : 0) || offset > (int64_t)1 << 53)
            return FS_EIO;
        if (op == FS_LIST && offset > 0x7FFFFFFF)
            return FS_EIO;
    }
    const int32_t id = next_;
    next_ = next_ >= 0x7FFFFFF0 ? 1 : next_ + 1;
    Req r;
    r.op = op;
    r.buf = buf;
    r.len = n;
    r.offset = offset < 0 ? 0 : (uint64_t)offset;
    r.rel = rel;
    reqs_[id] = r;

    std::shared_ptr<FsFolder> folder = fixed_ ? fixed_ : fsFolder();
    if (!folder) {
        Answer a;
        a.id = id;
        a.result = FS_ENOFOLDER;
        ready_.push_back(std::move(a));
        return id;
    }
    if (op == FS_LIST && offset > 0 && listCache_ && listPath_ == rel && listChanged_ == changed()) {
        Answer a;                           // (the next page of a listing just read)
        a.id = id;
        a.entries = listCache_;
        a.cached = true;
        ready_.push_back(std::move(a));
        return id;
    }
    Job j;
    j.id = id;
    j.op = op;
    j.rel = rel;
    j.offset = offset;
    j.len = n;
    j.data = root == 'd';
    j.folder = std::move(folder);
    if (op == FS_WRITE)
        j.bytes.assign(mem + buf, mem + buf + n);
    {
        std::lock_guard<std::mutex> g(mu_);
        jobs_.push_back(std::move(j));
        queued_++;
        if (!io_.joinable())
            io_ = std::thread([this] { worker(); });
    }
    cv_.notify_one();
    return id;
}

int32_t FileApi::poll(int32_t id)
{
    auto it = reqs_.find(id);
    if (it == reqs_.end())
        return FS_ENOENT;
    if (it->second.canceled) {
        reqs_.erase(it);
        return FS_ECANCELED;
    }
    if (!it->second.done)
        return FS_PENDING;
    const int32_t r = it->second.result;
    reqs_.erase(it);
    return r;
}

void FileApi::cancel(int32_t id)
{
    auto it = reqs_.find(id);
    if (it != reqs_.end()) {
        it->second.canceled = true;
        it->second.done = true;
    }
}

void FileApi::apply(uint8_t *mem, uint32_t memSize)
{
    (void)memSize;                          // (every buffer was checked against it when its request was made)
    std::vector<Answer> box;
    if (answered_.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> g(mu_);
        box.swap(done_);
        answered_.store(0, std::memory_order_release);
    }
    if (!ready_.empty()) {
        box.insert(box.end(), std::make_move_iterator(ready_.begin()), std::make_move_iterator(ready_.end()));
        ready_.clear();
    }
    for (const Answer &a : box) {
        auto it = reqs_.find(a.id);
        if (it == reqs_.end() || it->second.done)
            continue;                       // (polled, cancelled)
        it->second.done = true;
        it->second.result = copy(it->second, a, mem);
    }
}

int32_t FileApi::copy(Req &r, const Answer &a, uint8_t *mem)
{
    if (a.result < 0)
        return a.result >= FS_ENOFOLDER && a.result != FS_PENDING ? a.result : FS_EIO;
    switch (r.op) {
    case FS_READ: {
        const uint32_t n = std::min<uint32_t>((uint32_t)a.bytes.size(), r.len);
        if (n)
            std::memcpy(mem + r.buf, a.bytes.data(), n);
        return (int32_t)n;
    }
    case FS_STAT: {
        const uint64_t size = a.st.size;
        const uint32_t mt = a.st.mtime, dir = a.st.dir ? 1u : 0u;
        for (int i = 0; i < 8; i++)
            mem[r.buf + i] = (uint8_t)(size >> (8 * i));
        for (int i = 0; i < 4; i++) {
            mem[r.buf + 8 + i] = (uint8_t)(mt >> (8 * i));
            mem[r.buf + 12 + i] = (uint8_t)(dir >> (8 * i));
        }
        return 16;
    }
    case FS_LIST: {
        if (!a.entries)
            return FS_EIO;
        if (!a.cached) {
            listPath_ = r.rel;
            listCache_ = a.entries;
            listChanged_ = changed();
        }
        const std::vector<FsEntry> &es = *a.entries;
        uint32_t at = r.buf;
        const uint32_t end = r.buf + r.len;
        int32_t k = 0;
        for (size_t i = (size_t)r.offset; i < es.size(); i++) {
            const FsEntry &e = es[i];
            if ((uint64_t)at + 2 + e.name.size() > end)
                break;
            mem[at] = e.dir ? 1 : 0;
            mem[at + 1] = (uint8_t)e.name.size();
            std::memcpy(mem + at + 2, e.name.data(), e.name.size());
            at += 2 + (uint32_t)e.name.size();
            k++;
        }
        if (!k && r.offset < es.size())
            return FS_EIO;                  // (a buffer too small for the next name)
        return k;
    }
    case FS_WRITE: return std::min<int32_t>(a.result, (int32_t)r.len);
    default: return 0;
    }
}

bool FileApi::waitIdle(int ms)
{
    std::unique_lock<std::mutex> g(mu_);
    return idle_.wait_for(g, std::chrono::milliseconds(ms), [this] { return queued_ == 0; });
}

void FileApi::worker()
{
    for (;;) {
        Job j;
        {
            std::unique_lock<std::mutex> g(mu_);
            cv_.wait(g, [this] { return stop_ || !jobs_.empty(); });
            if (stop_)
                return;
            j = std::move(jobs_.front());
            jobs_.pop_front();
        }
        Answer a = run(j);
        {
            std::lock_guard<std::mutex> g(mu_);
            done_.push_back(std::move(a));
            answered_.store(1, std::memory_order_release);
            queued_--;
        }
        idle_.notify_all();
    }
}

FileApi::Answer FileApi::run(Job &j)
{
    Answer a;
    a.id = j.id;
    FsFolder &f = *j.folder;
    if (j.data) {                           // (the cart's own data folder, made on demand)
        f.mkdir("data");
        f.mkdir("data/" + id_);
    }
    switch (j.op) {
    case FS_STAT:
        a.result = f.stat(j.rel, a.st);
        break;
    case FS_LIST: {
        std::vector<FsEntry> raw;
        a.result = f.list(j.rel, raw);
        if (a.result >= 0) {
            auto es = std::make_shared<std::vector<FsEntry>>();
            for (FsEntry &e : raw)
                if (!e.name.empty() && e.name[0] != '.' && e.name.size() <= 255 &&
                    e.name.find('/') == std::string::npos)
                    es->push_back(std::move(e));
            std::sort(es->begin(), es->end(), [](const FsEntry &x, const FsEntry &y) { return x.name < y.name; });
            a.entries = std::move(es);
            a.result = 0;
        }
        break;
    }
    case FS_READ:
        a.bytes.resize(j.len);
        a.result = j.len ? f.read(j.rel, (uint64_t)j.offset, a.bytes.data(), j.len) : 0;
        a.bytes.resize(a.result > 0 ? (size_t)a.result : 0);
        if (a.result > 0)
            g_reads.fetch_add(1, std::memory_order_relaxed);
        break;
    case FS_WRITE: a.result = f.write(j.rel, j.offset, j.bytes.data(), j.len); break;
    case FS_DELETE: a.result = f.remove(j.rel); break;
    case FS_MKDIR: a.result = f.mkdir(j.rel); break;
    default: a.result = FS_EIO; break;
    }
    return a;
}

} // namespace rfm
