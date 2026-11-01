// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Older versions (the owner, 2026-11-01: a state that only works with an older version needs a way back). Every
// RemoteFM1FW release is read (api.github.com .../releases, newest first; the releases are cumulative), each
// firmware's versions kept once (the newest release's file), cached beside the feeds' cache so the list shows
// offline. Read when a page needs it (a firmware's Get firmware page, the States page), at most once an hour.
// Installing one is the same install as the latest (checked, then the loader); a newer file of the id stays.

import Foundation

extension FirmwareStore {
    private struct VersionsCache: Codable {
        var fetched: Date
        var versions: [String: [AvailableFirmware]]
    }

    var versionsCacheURL: URL { cacheURL.deletingLastPathComponent().appendingPathComponent("versions.json") }

    func loadVersionsCache() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: versionsCacheURL), let c = try? dec.decode(VersionsCache.self, from: d) else { return }
        allVersions = c.versions
        versionsChecked = c.fetched
    }

    /// the releases read again when the list is older than maxAge (a failure keeps the cached list)
    public func loadVersions(maxAge: TimeInterval = 3600) async {
        if let c = versionsChecked, Date().timeIntervalSince(c) < maxAge { return }
        guard !versionsLoading else { return }
        versionsLoading = true
        defer { versionsLoading = false }
        let t = transport
        let url = FirmwareFeed.allReleases
        let r: Result<Data, Error> = await Task.detached { do { return .success(try await t.data(from: url)) } catch { return .failure(error) } }.value
        guard case .success(let d) = r, let v = try? FeedSnapshot.versions(d, feed: "the RemoteFM1FW releases on GitHub")
        else { return }
        allVersions = v
        versionsChecked = Date()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(VersionsCache(fetched: versionsChecked!, versions: v)) {
            try? FileManager.default.createDirectory(at: versionsCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: versionsCacheURL, options: .atomic)
        }
    }

    /// a firmware's versions, newest first, each with the catalog's details
    public func versions(of id: String) -> [AvailableFirmware] {
        let d = details[id]
        return (allVersions[id] ?? []).map { e in
            var e = e
            if let d { e.fill(from: d, sameVersion: FirmwareVersion.compare(d.version, e.version) == .orderedSame) }
            if e.name.isEmpty { e.name = AvailableFirmware.name(fromID: id) }
            return e
        }
    }

    /// one version of a firmware (the latest list's entry when it is that version)
    public func version(_ id: String, _ v: String) -> AvailableFirmware? {
        if let e = available.first(where: { $0.id == id && $0.version == v }) { return e }
        return versions(of: id).first { $0.version == v }
    }
}
