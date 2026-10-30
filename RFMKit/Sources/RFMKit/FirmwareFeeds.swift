// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Get firmware (PLAN.md section 9): the .rfm1 files the app can download, from a list of feeds.
//
//   a feed       a URL the app reads: a site catalog (remotefm1.com/catalog.json: firmwares[], those with an rfm1
//                object can be downloaded, its file relative to the catalog's URL) or a GitHub release (the API's
//                releases/latest: its <id>-<version>.rfm1 assets, with size and sha256 digest). More feeds (a firmware
//                author's own) are more entries in FirmwareFeed.defaults
//   the merge    one entry per firmware id: its newest version (FirmwareVersion), the downloads of that version from
//                every feed kept as alternatives; names, authors and descriptions filled in from a site catalog's
//                entry of the same id
//   the state    an entry against the imported files (ImportedFirmware: the manifest's id and version): Install,
//                Installed, or Update when every file of that id is older
//
// FirmwareStore (FirmwareStore.swift) fetches, caches, downloads and installs.

import Foundation

/// version order: dot parts as numbers ("1.6.1" < "1.6.10", "1.0" == "1.0.0"), a pre-release below its release
/// ("0.12.0-beta.12" < "0.12.0"), pre-release parts as semver compares them; a leading "v" and "+build" ignored
public enum FirmwareVersion {
    public static func less(_ a: String, _ b: String) -> Bool { compare(a, b) == .orderedAscending }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (ac, ap) = split(a), (bc, bp) = split(b)
        let r = parts(ac, bc, pad: true)
        if r != .orderedSame { return r }
        switch (ap.isEmpty, bp.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): return parts(ap, bp, pad: false)
        }
    }

    static func split(_ v: String) -> (String, String) {
        var s = Substring(v.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        guard let dash = s.firstIndex(of: "-") else { return (String(s), "") }
        return (String(s[..<dash]), String(s[s.index(after: dash)...]))
    }

    /// pad: a missing part counts as 0 (the release part); else fewer parts sort first (semver's pre-release)
    static func parts(_ a: String, _ b: String, pad: Bool) -> ComparisonResult {
        let x = a.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let y = b.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for i in 0..<max(x.count, y.count) {
            if i >= x.count || i >= y.count {
                guard pad else { return x.count < y.count ? .orderedAscending : .orderedDescending }
                let r = one(i < x.count ? x[i] : "0", i < y.count ? y[i] : "0")
                if r != .orderedSame { return r }
                continue
            }
            let r = one(x[i], y[i])
            if r != .orderedSame { return r }
        }
        return .orderedSame
    }

    static func one(_ a: String, _ b: String) -> ComparisonResult {
        switch (Int(a), Int(b)) {
        case let (x?, y?): x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        case (.some, nil): .orderedAscending             // (a number below a word, as semver)
        case (nil, .some): .orderedDescending
        case (nil, nil): a.compare(b, options: .numeric)
        }
    }
}

/// a place the app reads the list from
public struct FirmwareFeed: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case site       // a catalog.json like remotefm1.com's
        case github     // a GitHub release (api.github.com/repos/<owner>/<repo>/releases/latest)
    }

    public var kind: Kind
    public var url: URL
    public var name: String                 // what the footer calls it

    public var id: String { url.absoluteString }

    public init(kind: Kind, url: URL, name: String) {
        self.kind = kind
        self.url = url
        self.name = name
    }

    public static let remotefm1 = FirmwareFeed(kind: .site, url: URL(string: "https://remotefm1.com/catalog.json")!,
                                               name: "remotefm1.com")
    public static let releases = FirmwareFeed(
        kind: .github, url: URL(string: "https://api.github.com/repos/Quixotic7/RemoteFM1FW/releases/latest")!,
        name: "the RemoteFM1FW releases on GitHub")
    /// the feeds the app reads, in order (the first one's details win)
    public static let defaults = [remotefm1, releases]
}

/// a firmware the app can download
public struct AvailableFirmware: Codable, Sendable, Hashable, Identifiable {
    public struct Download: Codable, Sendable, Hashable {
        public var url: URL
        public var feed: String             // the feed's name
        public var sha256: String           // lower-case hex; "" when the feed gives none
        public var size: Int                // 0 when the feed gives none
        public var fileName: String
    }

    public var id: String                   // the firmware's id (its manifest's)
    public var name = ""
    public var version = ""
    public var author = ""
    public var category = ""
    public var summary = ""                 // one line
    public var about = ""                   // the description
    public var license = ""
    public var sourceURL = ""
    public var site = ""
    public var repo = ""                    // "owner/name" on GitHub
    public var beta = false
    public var downloads: [Download] = []   // the same version from each feed, the first tried first

    public init(id: String) { self.id = id }

    public var size: Int { downloads.first { $0.size > 0 }?.size ?? 0 }
    public var sha256: String { downloads.first { !$0.sha256.isEmpty }?.sha256 ?? "" }
    public var fileName: String { downloads.first?.fileName ?? "\(id)-\(version).rfm1" }
    public var displayName: String { name.isEmpty ? Self.name(fromID: id) : name }

    /// "coralflower" -> "Coralflower"
    public static func name(fromID id: String) -> String { id.prefix(1).uppercased() + id.dropFirst() }

    /// the empty fields taken from o (a site catalog's entry for this id, or another feed's). otherVersion: o
    /// describes another version (its source link then is the repo's, not that version's tag)
    mutating func fill(from o: AvailableFirmware, sameVersion: Bool) {
        func take(_ k: WritableKeyPath<AvailableFirmware, String>) { if self[keyPath: k].isEmpty { self[keyPath: k] = o[keyPath: k] } }
        take(\.name); take(\.author); take(\.category); take(\.summary); take(\.about); take(\.license)
        take(\.site); take(\.repo)
        if sourceURL.isEmpty {
            sourceURL = sameVersion || o.repo.isEmpty ? o.sourceURL : "https://github.com/\(o.repo)"
        }
        if sameVersion && o.beta { beta = true }
    }
}

/// what an entry is to this device
public enum InstallState: Equatable, Sendable {
    case notInstalled
    case installed(String)                  // the version here
    case update(String)                     // the newest version here, older than the entry's

    public var installedVersion: String? {
        switch self {
        case .notInstalled: nil
        case .installed(let v), .update(let v): v
        }
    }
}

extension AvailableFirmware {
    /// against the imported files: the same file, else the newest valid file of the same id
    public func state(_ files: [ImportedFirmware]) -> InstallState {
        let shas = Set(downloads.map(\.sha256).filter { !$0.isEmpty })
        let here = files.filter { $0.error == nil && ($0.coreID == id || shas.contains($0.sha256)) }
        if let f = here.first(where: { shas.contains($0.sha256) }) { return .installed(f.version) }
        guard let newest = here.max(by: { FirmwareVersion.less($0.version, $1.version) }) else { return .notInstalled }
        return FirmwareVersion.less(newest.version, version) ? .update(newest.version) : .installed(newest.version)
    }

    /// a built-in core of this id, of this version or newer (not offered: the built-in one runs natively)
    public func builtIn(_ cores: [CoreInfo]) -> Bool {
        cores.contains { !$0.imported && $0.firmwareID == id && !FirmwareVersion.less($0.version, version) }
    }
}

/// one feed as last read
public struct FeedSnapshot: Codable, Sendable, Equatable {
    public var feed: FirmwareFeed
    public var fetched: Date
    public var firmware: [AvailableFirmware]            // the downloadable ones
    public var details: [String: AvailableFirmware]     // a site catalog: every firmware's details by id (no downloads)

    public init(feed: FirmwareFeed, fetched: Date, firmware: [AvailableFirmware], details: [String: AvailableFirmware] = [:]) {
        self.feed = feed
        self.fetched = fetched
        self.firmware = firmware
        self.details = details
    }

    public struct ParseError: Error, Equatable {}

    /// a feed's response read (a firmware whose fields don't parse is left out)
    public static func parse(_ data: Data, feed: FirmwareFeed, fetched: Date = Date()) throws -> FeedSnapshot {
        let dec = JSONDecoder()
        switch feed.kind {
        case .site:
            guard let j = try? dec.decode(SiteJSON.self, from: data) else { throw ParseError() }
            var list: [AvailableFirmware] = [], details: [String: AvailableFirmware] = [:]
            for case let f? in j.firmwares.map(\.value) where !f.id.isEmpty {
                var e = AvailableFirmware(id: f.id)
                e.name = f.name ?? ""
                e.version = f.version ?? ""
                e.author = f.authorFull ?? f.author ?? ""
                e.category = f.category ?? ""
                e.summary = f.tag ?? ""
                e.about = f.what ?? f.blurb ?? ""
                e.license = f.license ?? ""
                e.sourceURL = f.source ?? ""
                e.site = f.site ?? ""
                e.repo = f.repo ?? ""
                e.beta = f.beta ?? false
                details[f.id] = e
                guard let r = f.rfm1, let path = r.url ?? r.file, let url = URL(string: path, relativeTo: feed.url)?.absoluteURL
                else { continue }
                if let v = r.version, !v.isEmpty, v != e.version {
                    e.version = v
                    e.beta = v.contains("-")
                    if !e.repo.isEmpty { e.sourceURL = "https://github.com/\(e.repo)" }
                }
                if let a = r.authors, !a.isEmpty, f.authorFull == nil { e.author = a.joined(separator: ", ") }
                e.downloads = [.init(url: url, feed: feed.name, sha256: (r.sha256 ?? "").lowercased(), size: r.size ?? 0,
                                     fileName: r.fileName ?? url.lastPathComponent)]
                list.append(e)
            }
            return FeedSnapshot(feed: feed, fetched: fetched, firmware: list, details: details)
        case .github:
            guard let j = try? dec.decode(ReleaseJSON.self, from: data) else { throw ParseError() }
            var list: [AvailableFirmware] = []
            for a in j.assets {
                guard let (id, version) = Self.idAndVersion(a.name), let url = URL(string: a.browser_download_url) else { continue }
                var e = AvailableFirmware(id: id)
                e.version = version
                let d = a.digest ?? ""
                e.downloads = [.init(url: url, feed: feed.name, sha256: d.hasPrefix("sha256:") ? String(d.dropFirst(7)).lowercased() : "",
                                     size: a.size ?? 0, fileName: a.name)]
                list.append(e)
            }
            return FeedSnapshot(feed: feed, fetched: fetched, firmware: list)
        }
    }

    /// "<id>-<version>.rfm1" (the id may hold dashes: the version starts at the first "-" before a digit)
    static func idAndVersion(_ name: String) -> (String, String)? {
        guard name.lowercased().hasSuffix(".rfm1") else { return nil }
        let stem = name.dropLast(5)
        var i = stem.startIndex
        while let dash = stem[i...].firstIndex(of: "-") {
            let next = stem.index(after: dash)
            if next < stem.endIndex, stem[next].isNumber || (stem[next] == "v" && stem.index(after: next) < stem.endIndex
                                                             && stem[stem.index(after: next)].isNumber) {
                let id = String(stem[..<dash]).lowercased()
                return id.isEmpty ? nil : (id, String(stem[next...]))
            }
            i = next
        }
        return nil
    }

    /// every feed's list as one: one entry per id, its newest version; the same version from several feeds keeps
    /// each download (in feed order); details filled in from the site catalogs. Sorted by name
    public static func merge(_ snaps: [FeedSnapshot]) -> [AvailableFirmware] {
        var details: [String: AvailableFirmware] = [:]
        for s in snaps { for (k, v) in s.details where details[k] == nil { details[k] = v } }
        var out: [String: AvailableFirmware] = [:]
        for s in snaps {
            for var e in s.firmware {
                if let d = details[e.id] {
                    e.fill(from: d, sameVersion: FirmwareVersion.compare(d.version, e.version) == .orderedSame)
                }
                guard var have = out[e.id] else {
                    out[e.id] = e
                    continue
                }
                switch FirmwareVersion.compare(e.version, have.version) {
                case .orderedDescending:
                    e.fill(from: have, sameVersion: false)
                    out[e.id] = e
                case .orderedSame:
                    for d in e.downloads where !have.downloads.contains(where: { $0.url == d.url }) { have.downloads.append(d) }
                    have.fill(from: e, sameVersion: true)
                    out[e.id] = have
                case .orderedAscending:
                    have.fill(from: e, sameVersion: false)
                    out[e.id] = have
                }
            }
        }
        return out.values.map { e in
            var e = e
            if e.name.isEmpty { e.name = AvailableFirmware.name(fromID: e.id) }
            if e.version.contains("-") { e.beta = true }
            return e
        }
        .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }
}

/// a value that may not decode (left out, not the whole list)
private struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from d: Decoder) throws { value = try? T(from: d) }
}

/// remotefm1.com/catalog.json (the fields used)
private struct SiteJSON: Decodable {
    var firmwares: [Lossy<Item>]

    struct Item: Decodable {
        var id: String
        var name, version, author, authorFull, category, tag, what, blurb, license, source, repo, site: String?
        var beta: Bool?
        var rfm1: RFM1?
    }

    struct RFM1: Decodable {
        var file, url, sha256, version, fileName, sourceUrl: String?
        var size: Int?
        var authors: [String]?
    }
}

/// a GitHub release (the fields used)
private struct ReleaseJSON: Decodable {
    var assets: [Asset]

    struct Asset: Decodable {
        var name: String
        var size: Int?
        var digest: String?
        var browser_download_url: String
    }
}
