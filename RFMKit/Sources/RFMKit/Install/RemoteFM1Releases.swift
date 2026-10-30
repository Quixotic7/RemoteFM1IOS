// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The RemoteFM1 firmware releases the website's installer offers (https://remotefm1.com/installer/releases.json,
// newest first): each release's version, identity (what the FM-1 reports once it is installed, FM-1_52XXYYZZ), licence,
// notes and its packages: the default one (firmware/remote-<version>.fwsc) and, for most, a USB-only one without
// Bluetooth. The last list that was fetched and read is kept in Caches, so the page works offline with what it saw.
// RemoteFM1Version reads a version from text ("0.2.3", HELLO_R's firmware version) or from an identity.

import Foundation
import Observation

/// a RemoteFM1 version: major.minor.patch
public struct RemoteFM1Version: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "0.2.3", "v0.2.3", "0.2.3-dev" (the leading numbers); nil when there are none
    public init?(string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let head = s.prefix { $0.isNumber || $0 == "." }
        let parts = head.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count >= 2, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.init(parts[0]!, parts[1]!, parts.count > 2 ? parts[2]! : 0)
    }

    /// RemoteFM1's release identities: FM-1_52XXYYZZ is XX.YY.ZZ (firmware/fm1.toml's id_prefix "FM-1_52"; a dev
    /// build reports FM-1_5200, which has no version). nil for anything else, including 0.1.x's FM-1_015 (V15's)
    public init?(identity: String) {
        guard identity.hasPrefix(Self.identityPrefix) else { return nil }
        let digits = identity.dropFirst(Self.identityPrefix.count)
        guard digits.count == 6, let n = Int(digits) else { return nil }
        self.init(n / 10000, (n / 100) % 100, n % 100)
    }

    public static let identityPrefix = "FM-1_52"

    /// the identity a release with this version installs as
    public var identity: String { String(format: "\(Self.identityPrefix)%02d%02d%02d", major, minor, patch) }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: Self, b: Self) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }

    /// the oldest RemoteFM1 this app's link speaks (libremotefm1 0.2.2's protocol; 0.2.1 lacks its Bluetooth pacing)
    public static let appMinimum = RemoteFM1Version(0, 2, 2)
}

/// one release in releases.json
public struct RemoteFM1Release: Codable, Hashable, Sendable, Identifiable {
    public struct Variant: Codable, Hashable, Sendable {
        public var file: String
        public var sha256: String
    }

    public var version: String
    public var date: String
    public var tag: String
    public var identity: String
    public var license: String
    public var sha256: String
    public var usbOnly: Variant?
    public var notes: [String]

    public var id: String { version }
    public var parsedVersion: RemoteFM1Version? { RemoteFM1Version(string: version) }

    /// the release's package of this kind (nil: it has none)
    public func package(_ kind: FirmwarePackageRef.Kind) -> FirmwarePackageRef? {
        switch kind {
        case .standard:
            return FirmwarePackageRef(version: version, kind: .standard, file: "remote-\(version).fwsc", sha256: sha256,
                                      identity: identity)
        case .usbOnly:
            guard let u = usbOnly else { return nil }
            return FirmwarePackageRef(version: version, kind: .usbOnly, file: u.file, sha256: u.sha256, identity: identity)
        }
    }

    /// what this app can install: a RemoteFM1 identity FM1Kit can check afterwards (0.1.x answers as M-VAVE's V15,
    /// FM-1_015, so neither FM1Kit nor this app could tell it from V15)
    public var installable: Bool { RemoteFM1Version(identity: identity) != nil && parsedVersion != nil }

    /// the date as "28 Oct 2026" (releases.json: 2026-10-28)
    public var displayDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: date) else { return date }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// one package to download: a release's default or USB-only file, its SHA-256 and the identity it must carry
public struct FirmwarePackageRef: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case standard, usbOnly }
    public var version: String
    public var kind: Kind
    public var file: String
    public var sha256: String
    public var identity: String

    public init(version: String, kind: Kind, file: String, sha256: String, identity: String) {
        self.version = version
        self.kind = kind
        self.file = file
        self.sha256 = sha256.lowercased()
        self.identity = identity
    }

    public var title: String { "RemoteFM1 \(version)" + (kind == .usbOnly ? " (USB only)" : "") }
}

/// releases.json
public struct RemoteFM1ReleaseList: Codable, Hashable, Sendable {
    public var releases: [RemoteFM1Release]

    public init(releases: [RemoteFM1Release]) { self.releases = releases }

    public static func parse(_ data: Data) throws -> Self {
        let list = try JSONDecoder().decode(Self.self, from: data)
        guard !list.releases.isEmpty else { throw InstallerFetchError.badList("it lists no releases") }
        for r in list.releases {
            guard r.sha256.count == 64, r.sha256.allSatisfy(\.isHexDigit) else {
                throw InstallerFetchError.badList("\(r.version)'s SHA-256 isn't one")
            }
        }
        return list
    }
}

public enum InstallerFetchError: Error, LocalizedError, Equatable {
    case http(Int, String)
    case badList(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let what): "The website answered \(code) for \(what)."
        case .badList(let why): "The list of releases can't be read: \(why)."
        }
    }
}

/// where the installer's files come from (the website; tests give their own)
public protocol InstallerFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

/// HTTPS through URLSession: anything but 200 is an error
public struct URLSessionFetcher: InstallerFetching {
    public init() {}

    public func data(from url: URL) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("RemoteFM1-iOS", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw InstallerFetchError.http(h.statusCode, url.lastPathComponent)
        }
        return data
    }
}

/// The releases, fetched from the website (or the last good copy): newest first, as releases.json has them.
@MainActor
@Observable
public final class RemoteFM1Releases {
    public static let site = URL(string: "https://remotefm1.com/installer/")!
    public static var listURL: URL { site.appendingPathComponent("releases.json") }
    public static func packageURL(_ file: String) -> URL { site.appendingPathComponent("firmware").appendingPathComponent(file) }

    public private(set) var releases: [RemoteFM1Release] = []
    public private(set) var fetchedAt: Date?            // the list's time (the cache's, when it came from there)
    public private(set) var fromCache = false
    public private(set) var error: String?              // the last fetch's, in words (nil: it worked)
    public private(set) var fetching = false

    @ObservationIgnored public let cacheDirectory: URL
    @ObservationIgnored private let fetcher: any InstallerFetching
    @ObservationIgnored private var lastAttempt: Date?

    /// cacheDirectory: where the last good list is kept (and the packages, FirmwarePackages)
    public init(cacheDirectory: URL = RemoteFM1Releases.defaultCache, fetcher: any InstallerFetching = URLSessionFetcher()) {
        self.cacheDirectory = cacheDirectory
        self.fetcher = fetcher
        loadCache()
    }

    public nonisolated static var defaultCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RemoteFM1Installer")
    }

    private var cacheFile: URL { cacheDirectory.appendingPathComponent("releases.json") }

    /// the newest release this app can install
    public var newest: RemoteFM1Release? { releases.first(where: \.installable) }

    /// the release with this identity (what an FM-1 reports)
    public func release(identity: String) -> RemoteFM1Release? { releases.first { $0.identity == identity } }

    /// a newer release than `version` (the unit's), nil: none, or the version is unknown
    public func update(over version: RemoteFM1Version?) -> RemoteFM1Release? {
        guard let version, let n = newest, let nv = n.parsedVersion, nv > version else { return nil }
        return n
    }

    /// fetches the list; on success it is kept as the last good copy; on failure the cached copy stays (error says why)
    public func refresh() async {
        guard !fetching else { return }
        fetching = true
        lastAttempt = Date()
        defer { fetching = false }
        do {
            let data = try await fetcher.data(from: Self.listURL)
            let list = try RemoteFM1ReleaseList.parse(data)
            releases = list.releases
            fetchedAt = Date()
            fromCache = false
            error = nil
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        } catch {
            self.error = Self.words(error)
            if releases.isEmpty { loadCache() }
        }
    }

    /// refresh() unless one was tried in the last `age` seconds
    public func refreshIfStale(_ age: TimeInterval = 600) async {
        if let t = lastAttempt, Date().timeIntervalSince(t) < age { return }
        await refresh()
    }

    /// the last good copy, if any
    public func loadCache() {
        guard let data = try? Data(contentsOf: cacheFile), let list = try? RemoteFM1ReleaseList.parse(data) else { return }
        releases = list.releases
        fetchedAt = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        fromCache = true
    }

    nonisolated static func words(_ e: any Error) -> String {
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "No internet connection."
            case .timedOut: return "The website didn't answer in time."
            default: return u.localizedDescription
            }
        }
        if e is DecodingError { return "The list of releases can't be read." }
        return e.localizedDescription
    }
}
