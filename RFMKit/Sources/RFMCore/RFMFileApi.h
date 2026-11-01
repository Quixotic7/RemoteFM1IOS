// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// A Fantasy CFW's file API (FM1VST docs/VIRTUAL-CARTS.md section 4: rfm1_host_1, capability fs1), platform-neutral:
// no Apple or Android types here, so the Android app ports this file and RFMFileApi.cpp as they are.
//
//   FsFolder   the platform's side: stat / list / read / write / remove / mkdir on a path relative to the RemoteFM1
//              folder ("audio/kick.wav", "data/ripple/save.bin"), already checked. Blocking is fine: it is called on
//              the FileApi's IO thread only. fsPosixFolder() is the POSIX one (iOS, macOS, the tests); Android brings
//              its own (ContentResolver, through JNI)
//   FileApi    one per instance of a cart, owned by the core: a request is checked when the cart makes it (the op,
//              the path, the manifest's folders, the buffer, the limits: 32 in flight, 1 MiB each), given an id and
//              queued; the IO thread does it; apply(), called by the core between two export calls (never during
//              one), copies the answers into the module's memory. poll / cancel / changed as the spec says
//   the folder fsSetFolder(): the folder every request uses from then on (nullptr: FS_ENOFOLDER); fsBumpChanged():
//              the counter fs_changed() returns moves (files added through the app, a new folder)
//
// Threading: request, poll, cancel, changed and apply on the core thread (the one calling the module); the folder on
// the IO thread; fsSetFolder / fsBumpChanged from any thread.
#ifndef RFMFILEAPI_H
#define RFMFILEAPI_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace rfm {

enum : int32_t {
    FS_PENDING = -1, FS_ENOENT = -2, FS_EACCES = -3, FS_EIO = -4, FS_ENOSPC = -5, FS_EBUSY = -6, FS_ECANCELED = -7,
    FS_ENOFOLDER = -8,
};
enum : int32_t { FS_STAT = 1, FS_LIST = 2, FS_READ = 3, FS_WRITE = 4, FS_DELETE = 5, FS_MKDIR = 6 };
constexpr int FS_MAX_INFLIGHT = 32;
constexpr uint32_t FS_MAX_LEN = 1u << 20;
constexpr uint32_t FS_MAX_PATH = 1024;

struct FsStat {
    uint64_t size = 0;
    uint32_t mtime = 0;                     // seconds since 1970
    bool dir = false;
};
struct FsEntry {
    std::string name;
    bool dir = false;
};

// the platform's folder (see the top). Results: 0 or a byte count, or an FS_E* error (< 0)
class FsFolder {
public:
    virtual ~FsFolder() = default;
    virtual int32_t stat(const std::string &rel, FsStat &out) = 0;
    // every entry of a folder, any order, hidden ones too (FileApi filters and sorts)
    virtual int32_t list(const std::string &rel, std::vector<FsEntry> &out) = 0;
    // up to len bytes at offset; 0 at the end
    virtual int32_t read(const std::string &rel, uint64_t offset, uint8_t *buf, uint32_t len) = 0;
    // len bytes at offset (-1: the file truncated first, then written at 0); its folder must exist (FS_ENOENT)
    virtual int32_t write(const std::string &rel, int64_t offset, const uint8_t *buf, uint32_t len) = 0;
    // a file, or an empty folder
    virtual int32_t remove(const std::string &rel) = 0;
    // 0 also when the folder is there already
    virtual int32_t mkdir(const std::string &rel) = 0;
};

// a folder on a POSIX file system; symlinks that lead out of it are refused (FS_EACCES)
std::shared_ptr<FsFolder> fsPosixFolder(const std::string &root);

void fsSetFolder(std::shared_ptr<FsFolder> folder);
std::shared_ptr<FsFolder> fsFolder();
void fsBumpChanged();
uint32_t fsChangedCount();
// READs answered with bytes, every instance (diagnostics, tests)
uint64_t fsReadCount();

// the manifest's "folders": what a cart may do in each area
struct FsModes {
    enum : uint8_t { None = 0, Read = 1, ReadWrite = 3 };
    uint8_t audio = None, code = None, data = None;
};

class FileApi {
public:
    // id: the cart's (code/<id>/, data/<id>/). fixed: this folder instead of fsFolder() (tests)
    FileApi(std::string id, FsModes modes, std::shared_ptr<FsFolder> fixed = nullptr);
    ~FileApi();
    FileApi(const FileApi &) = delete;
    FileApi &operator=(const FileApi &) = delete;

    // rfm1_host_1 (mem: the module's linear memory, fixed while the module lives)
    int32_t request(int32_t op, const uint8_t *mem, uint32_t memSize, uint32_t pathAt, uint32_t pathLen,
                    int64_t offset, uint32_t buf, int32_t len);
    int32_t poll(int32_t id);
    void cancel(int32_t id);
    int32_t changed() const { return (int32_t)(fsChangedCount() + local_); }

    // the answers into memory: between two export calls only
    void apply(uint8_t *mem, uint32_t memSize);
    // fs_changed moves for this instance alone (tests)
    void bump() { local_++; }
    // (tests) every queued request answered (true), or the timeout
    bool waitIdle(int ms);

private:
    struct Req {
        int32_t op = 0;
        uint32_t buf = 0, len = 0;
        uint64_t offset = 0;
        std::string rel;
        bool done = false, canceled = false;
        int32_t result = FS_PENDING;
    };
    struct Job {
        int32_t id = 0, op = 0;
        std::string rel;
        int64_t offset = 0;
        uint32_t len = 0;
        bool data = false;                  // under data/<id>/: that folder made first
        std::vector<uint8_t> bytes;         // a WRITE's
        std::shared_ptr<FsFolder> folder;
    };
    struct Answer {
        int32_t id = 0, result = 0;
        std::vector<uint8_t> bytes;         // a READ's
        FsStat st;
        std::shared_ptr<const std::vector<FsEntry>> entries;    // a LIST's, sorted
        bool cached = false;
    };

    bool folderPath(const uint8_t *mem, uint32_t memSize, uint32_t at, uint32_t n, char &root, bool &top,
                    std::string &rel) const;
    int32_t copy(Req &r, const Answer &a, uint8_t *mem);
    void worker();
    Answer run(Job &j);

    const std::string id_;
    const FsModes modes_;
    const std::shared_ptr<FsFolder> fixed_;
    uint32_t local_ = 0;

    // the core thread's
    std::map<int32_t, Req> reqs_;
    int32_t next_ = 1;
    std::vector<Answer> ready_;             // answered without the IO thread (no folder, a cached LIST page)
    std::string listPath_;
    std::shared_ptr<const std::vector<FsEntry>> listCache_;
    int32_t listChanged_ = 0;

    // shared with the IO thread
    std::mutex mu_;
    std::condition_variable cv_, idle_;
    std::deque<Job> jobs_;
    std::vector<Answer> done_;
    std::atomic<int> answered_{0};
    int queued_ = 0;
    bool stop_ = false;
    std::thread io_;
};

} // namespace rfm

#endif
