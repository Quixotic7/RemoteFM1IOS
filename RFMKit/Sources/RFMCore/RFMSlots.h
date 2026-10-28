// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The slot loader (PLAN.md section 3; the C face is rfms_* in include/RFMEngine.h). Replaces FM1VST's engine/cores.cpp
// on iOS: instead of copying a module per instance (iOS loads code only from the signed bundle), each core is bundled
// as FM1Core_<id>_1 .. _4.framework, and an instance takes a slot of its core that nobody in this process holds.
// The descriptor probe and the ABI check are cores.cpp's (open_core).
#pragma once
#include <mutex>
#include <string>
#include <vector>

#include "fm1core.h"

namespace rfm {

struct CoreSlotInfo {
    std::string id, name, version, source_url, family, license, gated, credits;
    uint32_t abi = 0, flash_size = 0;
    std::vector<std::string> paths;     // slot n's binary is paths[n - 1] ("" where slot n is missing)
};

class SlotLoader {
public:
    static SlotLoader &shared();

    // one held slot: its image loaded (RTLD_NOW | RTLD_LOCAL), its descriptor checked
    struct Slot {
        std::string id, path;
        int n = 0;                      // 1..
        void *handle = nullptr;
        const fm1core_t *core = nullptr;
        void *symbol(const char *name) const;
    };

    int scan(const std::string &dir);   // "" = the bundle's Frameworks (see rfms_scan)
    std::vector<CoreSlotInfo> cores() const;
    bool find(const std::string &id, CoreSlotInfo &out) const;
    int inUse(const std::string &id) const;
    int retired(const std::string &id) const;
    std::string dirs() const;
    std::string errors() const;

    // the first slot of the core that is neither held nor retired; nullptr with a message otherwise
    Slot *acquire(const std::string &id, std::string *err);
    // shutdown(), dlclose; the slot is free again if its image left memory, else retired
    void release(Slot *s);

private:
    mutable std::mutex mu_;
    std::vector<CoreSlotInfo> cores_;
    std::vector<std::string> held_, retired_;   // slot paths
    std::vector<std::string> dirs_;
    std::string errors_;
};

} // namespace rfm
