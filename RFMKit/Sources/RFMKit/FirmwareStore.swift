// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Get firmware (PLAN.md section 9): FirmwareStore reads the feeds (FirmwareFeeds.swift), keeps the last good list of
// each in the app's Caches (shown offline, with its date), and downloads and installs one firmware at a time.
//
//   a check      every feed fetched at once (20 s timeout); a feed that fails keeps its cached list, and the page
//                says so. The app checks at launch when the list is a day old, and when the page opens
//   an install   the download (https only) to a temporary file, with progress and Cancel; its size and SHA-256
//                checked against the feed's (a mismatch refuses it, then the next feed's copy is tried); then
//                FirmwareLibrary.importFile, the same path as a file added by hand (the .rfm1 loader checks it, it is
//                mirrored into the App Group). A file the loader refuses is removed again
//   an update    the same, then the other files of the same firmware id and an older or equal version are removed
//                (willReplace first: the app moves its selection to the new file). Saved choices of the old file
//                fall back to the same id (CoreRef.resolve), so projects keep working
//
// Nothing here selects or runs a firmware: the user picks it in the Firmware page.

import CryptoKit
import Foundation
import Observation

/// how the store reaches the network (tests use their own)
public protocol FirmwareTransport: Sendable {
    func data(from url: URL) async throws -> Data
    /// the file at url written to `to`; at most `limit` bytes; progress(received, expected; 0 unknown)
    func download(from url: URL, to: URL, limit: Int, progress: @escaping @Sendable (Int, Int) -> Void) async throws
}

/// URLSession: no cache, a timeout, no waiting for a connection
public final class URLSessionTransport: FirmwareTransport {
    let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = 300
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "RemoteFM1-iOS"]
        session = URLSession(configuration: c)
    }

    public func data(from url: URL) async throws -> Data {
        var r = URLRequest(url: url)
        if url.host == "api.github.com" { r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let (d, resp) = try await session.data(for: r)
        try Self.check(resp)
        return d
    }

    public func download(from url: URL, to: URL, limit: Int, progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        let (bytes, resp) = try await session.bytes(from: url)
        try Self.check(resp)
        let expected = Int(max(0, resp.expectedContentLength))
        if expected > limit { throw FirmwareStoreError.tooLarge }
        guard FileManager.default.createFile(atPath: to.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let h = try FileHandle(forWritingTo: to)
        defer { try? h.close() }
        var buf = Data()
        buf.reserveCapacity(1 << 16)
        var n = 0
        for try await b in bytes {
            buf.append(b)
            if buf.count == 1 << 16 {
                try Task.checkCancellation()
                n += buf.count
                if n > limit { throw FirmwareStoreError.tooLarge }
                try h.write(contentsOf: buf)
                buf.removeAll(keepingCapacity: true)
                progress(n, expected)
            }
        }
        n += buf.count
        if n > limit { throw FirmwareStoreError.tooLarge }
        try h.write(contentsOf: buf)
        progress(n, expected)
    }

    static func check(_ r: URLResponse) throws {
        if let h = r as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw FirmwareStoreError.server(h.statusCode) }
    }
}

/// what went wrong, in plain words (message)
public enum FirmwareStoreError: Error, Equatable, Sendable {
    case offline
    case server(Int)
    case unreadable(String)                 // a feed's answer isn't what it should be (the feed's name)
    case notHTTPS
    case tooLarge
    case size(expected: Int, got: Int)
    case checksum
    case invalid(String)                    // the .rfm1 loader's reason
    case other(String)

    public var message: String {
        switch self {
        case .offline: "Can't reach the server. You may be offline: try again when you're connected."
        case .server(let c): "The server answered \(c) (\(HTTPURLResponse.localizedString(forStatusCode: c))). Try again later."
        case .unreadable(let f): "The list from \(f) couldn't be read."
        case .notHTTPS: "The list gave an address that isn't secure (https), so nothing was downloaded."
        case .tooLarge: "The download was bigger than the list says, so it wasn't installed."
        case .size(let e, let g): "The download was the wrong size (\(g) bytes, not \(e)), so it wasn't installed."
        case .checksum: "The download didn't match its checksum, so it wasn't installed. Try again later."
        case .invalid(let why): "The file isn't a valid .rfm1 firmware (\(why)), so it wasn't installed."
        case .other(let s): s
        }
    }

    static func from(_ e: Error) -> FirmwareStoreError {
        if let e = e as? FirmwareStoreError { return e }
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed:
                return .offline
            default: return .other(u.localizedDescription)
            }
        }
        return .other(e.localizedDescription)
    }
}

/// the list of available firmware and the one download (main actor)
@MainActor
@Observable
public final class FirmwareStore {
    public struct Progress: Equatable, Sendable {
        public var id: String                   // the firmware's
        public var received = 0, expected = 0
        public var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    }

    public let feeds: [FirmwareFeed]
    /// each feed's last good list (feed order)
    public private(set) var snapshots: [FeedSnapshot] = []
    /// the merged list (every id, built-in ones too: list(builtIn:) leaves those out)
    public private(set) var available: [AvailableFirmware] = []
    public private(set) var checking = false
    /// the last check's trouble ("" when every feed answered)
    public private(set) var problem = ""
    /// the last check, one line a feed: what came back (a byte count, firmware found, or how an unreadable answer
    /// starts), so a screenshot shows what a phone received
    public private(set) var report: [String] = []
    /// the download running
    public private(set) var progress: Progress?
    /// the last install's result, and its error
    public private(set) var message = ""
    public private(set) var failure = ""

    /// before an update removes older files (old, new): the app moves its selection
    @ObservationIgnored public var willReplace: (@MainActor ([ImportedFirmware], ImportedFirmware) -> Void)?
    /// after an install changed the firmware folder
    @ObservationIgnored public var didChange: (@MainActor () -> Void)?

    @ObservationIgnored public let library: FirmwareLibrary
    @ObservationIgnored private let transport: FirmwareTransport
    @ObservationIgnored public let cacheURL: URL
    @ObservationIgnored private var task: Task<ImportedFirmware?, Never>?
    @ObservationIgnored private var attempted: Date?
    @ObservationIgnored private let log = RFMShared.log("catalog")

    /// the most an .rfm1 may be when a feed gives no size (the format's memory cap is 32 MiB)
    public static let maxSize = 64 << 20

    /// cache: the cached lists' file (nil: Caches/Firmware catalog/feeds.json)
    public init(library: FirmwareLibrary, feeds: [FirmwareFeed] = FirmwareFeed.defaults,
                transport: FirmwareTransport = URLSessionTransport(), cache: URL? = nil) {
        self.library = library
        self.feeds = feeds
        self.transport = transport
        cacheURL = cache ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Firmware catalog/feeds.json")
        loadCache()
    }

    /// when the list was read: the oldest feed's last good answer (nil: never)
    public var checked: Date? { snapshots.map(\.fetched).min() }

    /// the list a page shows: without firmware this build has built in (of that version or newer)
    public func list(builtIn: [CoreInfo]) -> [AvailableFirmware] { available.filter { !$0.builtIn(builtIn) } }

    public func state(_ e: AvailableFirmware) -> InstallState { e.state(library.files) }

    /// the entries with a newer version than the one here
    public func updates(builtIn: [CoreInfo]) -> [AvailableFirmware] {
        list(builtIn: builtIn).filter { if case .update = state($0) { true } else { false } }
    }

    // MARK: the check

    /// every feed read again (a feed that fails keeps its cached list)
    public func refresh() async {
        guard !checking else { return }
        checking = true
        attempted = Date()
        defer { checking = false }
        let transport = transport
        // one task a feed, started together, awaited in feed order. (Not a task group of (index, result) tuples: a
        // Release build, Swift 6.4, gave every child the first index, so GitHub's answer was read as the catalog's.)
        let tasks = feeds.map { f in
            Task<Result<Data, FirmwareStoreError>, Never> {
                do { return .success(try await transport.data(from: f.url)) }
                catch { return .failure(.from(error)) }
            }
        }
        var results: [(Int, Result<Data, FirmwareStoreError>)] = []
        for (i, t) in tasks.enumerated() { results.append((i, await t.value)) }
        var snaps: [FeedSnapshot] = [], problems: [String] = [], lines: [String] = []
        let now = Date()
        for (i, r) in results {
            let f = feeds[i]
            switch r {
            case .success(let d):
                if let s = try? FeedSnapshot.parse(d, feed: f, fetched: now) {
                    snaps.append(s)
                    lines.append("\(f.name): \(d.count) bytes, \(s.firmware.count) to download")
                    continue
                }
                let head = String(decoding: d.prefix(80), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                lines.append("\(f.name): \(d.count) bytes, not a list: \"\(head)\"")
                log.error("\(f.url.absoluteString, privacy: .public): unreadable, \(d.count) bytes: \(head, privacy: .public)")
                problems.append(FirmwareStoreError.unreadable(f.name).message)
            case .failure(let e):
                log.error("\(f.url.absoluteString, privacy: .public): \(e.message, privacy: .public)")
                lines.append("\(f.name): \(e.message)")
                problems.append(e == .offline ? e.message : "\(f.name): \(e.message)")
            }
            if let old = snapshots.first(where: { $0.feed == f }) { snaps.append(old) }
        }
        snapshots = snaps
        available = FeedSnapshot.merge(snaps)
        report = lines
        problem = Array(Set(problems)).sorted().joined(separator: " ")
        saveCache()
        log.info("checked \(self.feeds.count) feed(s): \(self.available.count) firmware, \(problems.count) problem(s)")
    }

    /// a check when the list is older than maxAge (or there is none), and no check was tried in the last minLapse
    public func refreshIfOlder(than maxAge: TimeInterval, minLapse: TimeInterval = 60) async {
        if let a = attempted, Date().timeIntervalSince(a) < minLapse { return }
        if snapshots.count == feeds.count, let c = checked, Date().timeIntervalSince(c) < maxAge { return }
        await refresh()
    }

    private func loadCache() {
        guard let d = try? Data(contentsOf: cacheURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let s = try? dec.decode([FeedSnapshot].self, from: d) else { return }
        snapshots = feeds.compactMap { f in s.first { $0.feed == f } }
        available = FeedSnapshot.merge(snapshots)
    }

    private func saveCache() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(snapshots) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: cacheURL, options: .atomic)
    }

    // MARK: install

    /// e downloaded, checked and added (an update: older files of its id removed). Returns when it is done, failed
    /// or was cancelled (message / failure say which). One at a time: nil when another one runs
    @discardableResult
    public func install(_ e: AvailableFirmware) async -> ImportedFirmware? {
        guard progress == nil else { return nil }
        message = ""
        failure = ""
        progress = Progress(id: e.id, received: 0, expected: e.size)
        let t = Task { @MainActor in await run(e) }
        task = t
        let got = await t.value
        task = nil
        progress = nil
        return got
    }

    /// the running download stopped (nothing is added)
    public func cancel() { task?.cancel() }

    private func run(_ e: AvailableFirmware) async -> ImportedFirmware? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("rfm1-download-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: dir) }
        var last = FirmwareStoreError.other("Nothing to download.")
        for d in e.downloads {
            guard d.url.scheme?.lowercased() == "https" else {
                last = .notHTTPS
                continue
            }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(Self.safeName(d.fileName, e))
                try? fm.removeItem(at: file)
                log.info("download \(d.url.absoluteString, privacy: .public)")
                progress = Progress(id: e.id, received: 0, expected: d.size)
                try await transport.download(from: d.url, to: file, limit: d.size > 0 ? d.size : Self.maxSize) { n, x in
                    Task { @MainActor [weak self] in
                        guard let self, self.progress?.id == e.id else { return }
                        self.progress?.received = n
                        if d.size == 0 { self.progress?.expected = x }
                    }
                }
                try Task.checkCancellation()
                try Self.verify(file, d)
                return try add(file, e)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    message = "Cancelled."
                    log.info("download of \(e.id, privacy: .public) cancelled")
                    return nil
                }
                last = .from(error)
                log.error("\(d.url.absoluteString, privacy: .public): \(last.message, privacy: .public)")
                if case .invalid = last { break }           // (another feed's copy is the same file)
            }
        }
        failure = last.message
        return nil
    }

    /// the size and SHA-256 the feed gave (either may be missing; the loader checks the file next)
    static func verify(_ file: URL, _ d: AvailableFirmware.Download) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        if d.size > 0, data.count != d.size { throw FirmwareStoreError.size(expected: d.size, got: data.count) }
        if !d.sha256.isEmpty, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != d.sha256 {
            throw FirmwareStoreError.checksum
        }
    }

    /// the feed's file name, if it is a plain .rfm1 name; else <id>-<version>.rfm1
    static func safeName(_ n: String, _ e: AvailableFirmware) -> String {
        let ok = !n.isEmpty && !n.hasPrefix(".") && n.lowercased().hasSuffix(".rfm1")
            && n.allSatisfy { $0.isLetter || $0.isNumber || "-_.+ ".contains($0) }
        return ok ? n : "\(e.id)-\(e.version).rfm1".replacingOccurrences(of: "/", with: "_")
    }

    /// the checked file through the import path, then the older files of its id removed
    private func add(_ file: URL, _ e: AvailableFirmware) throws -> ImportedFirmware {
        let f = try library.importFile(file)
        if let why = f.error {
            library.delete(f)
            didChange?()
            throw FirmwareStoreError.invalid(why)
        }
        let old = library.files.filter {
            $0.error == nil && $0.coreID == f.coreID && $0.sha256 != f.sha256 && !FirmwareVersion.less(f.version, $0.version)
        }
        didChange?()
        if !old.isEmpty {
            willReplace?(old, f)
            for o in old { library.delete(o) }
            didChange?()
        }
        message = old.isEmpty ? "Installed \(f.name) \(f.version)." : "Updated \(f.name) to \(f.version)."
        log.info("\(self.message, privacy: .public) (\(f.file, privacy: .public); removed \(old.map(\.file), privacy: .public))")
        return f
    }
}
