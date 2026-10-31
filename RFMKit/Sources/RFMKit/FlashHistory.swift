// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// PLAN.md section 18 step 1: a firmware's flash never lost.
//
//   FlashFile     safe writes of one flash file: a temp file beside it, fsync, read back and compared (length and
//                 SHA-256), the old file kept as <name>.prev, the temp file renamed in. A sidecar <name>.json says
//                 which firmware version wrote it (a version change is seen at the next boot). A read that finds the
//                 file missing or damaged (unreadable, not the firmware's flash size) uses <name>.prev and says so.
//   FlashHistory  the safety copies, per firmware id: <root>/<id>/index.json and <uuid>.bin. Copies taken before
//                 something risky (an update, a delete, a reset, a restore; later steps: loading a state, a web
//                 manager's write) are kept (the newest 30); rolling copies of the saves: the last 10 distinct ones
//                 and the newest of each day for 7 days. A copy identical to the newest one is not kept twice. The
//                 root is Application Support/FlashHistory for now; step 2 points it at the App Group (`root`).

import CryptoKit
import Foundation

public enum FlashFile {
    /// which firmware wrote a flash file (the sidecar <name>.json)
    public struct Meta: Codable, Sendable, Equatable {
        public var firmwareID: String
        public var version: String
        public var size: Int
        public var sha256: String
        public var date: Date

        public init(firmwareID: String, version: String, size: Int, sha256: String, date: Date) {
            self.firmwareID = firmwareID
            self.version = version
            self.size = size
            self.sha256 = sha256
            self.date = date
        }
    }

    public struct Read: Sendable {
        public var data: Data?              // nil: none (a fresh flash)
        public var fromPrev = false
        public var note = ""                // what went wrong with the main file ("" when nothing did)
    }

    public enum WriteError: Error { case verify(String) }

    public static func prevURL(_ url: URL) -> URL { url.appendingPathExtension("prev") }
    public static func metaURL(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("json") }

    public static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// data written safely to url (see the top); meta: the sidecar's firmware id and version (nil: left as it is)
    public static func write(_ data: Data, to url: URL, firmwareID: String? = nil, version: String? = nil,
                             now: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let h = try FileHandle(forWritingTo: tmp)
        do {
            try h.write(contentsOf: data)
            try h.synchronize()                                     // (fsync)
            try h.close()
        } catch {
            try? h.close()
            try? fm.removeItem(at: tmp)
            throw error
        }
        let back = try Data(contentsOf: tmp)
        let hash = sha256(data)
        guard back.count == data.count, sha256(back) == hash else {
            try? fm.removeItem(at: tmp)
            throw WriteError.verify("\(url.lastPathComponent): read back \(back.count) of \(data.count) bytes, not the same")
        }
        let prev = prevURL(url)
        if fm.fileExists(atPath: url.path) {                        // (the previous good file kept)
            try? fm.removeItem(at: prev)
            try fm.moveItem(at: url, to: prev)
        }
        try fm.moveItem(at: tmp, to: url)
        if let firmwareID, let version {
            let m = Meta(firmwareID: firmwareID, version: version, size: data.count, sha256: hash, date: now)
            try? writeMeta(m, for: url)
        }
    }

    public static func meta(_ url: URL) -> Meta? {
        (try? Data(contentsOf: metaURL(url))).flatMap { try? decoder.decode(Meta.self, from: $0) }
    }

    public static func writeMeta(_ m: Meta, for url: URL) throws {
        try encoder.encode(m).write(to: metaURL(url), options: .atomic)
    }

    /// the flash at url; expectedSize: the firmware's flash size (0: any non-empty file is taken). Missing or damaged:
    /// <name>.prev, with a note
    public static func read(_ url: URL, expectedSize: Int) -> Read {
        let fm = FileManager.default
        func good(_ d: Data?) -> Bool { guard let d, !d.isEmpty else { return false }; return expectedSize <= 0 || d.count == expectedSize }
        let main = try? Data(contentsOf: url)
        if good(main) { return Read(data: main) }
        let exists = fm.fileExists(atPath: url.path)
        let what = !exists ? "missing" : main == nil ? "unreadable"
            : "damaged (\(main!.count) bytes, not \(expectedSize))"
        let prev = try? Data(contentsOf: prevURL(url))
        if good(prev) {
            return Read(data: prev, fromPrev: true,
                        note: "The saved memory was \(what): started from the copy saved before it.")
        }
        if !exists && prev == nil { return Read(data: nil) }        // (never saved: a fresh flash)
        return Read(data: nil, note: "The saved memory was \(what) and no earlier copy was usable: a fresh memory.")
    }

    /// the file, its .prev and its sidecar removed (a reset: the history holds the copy)
    public static func remove(_ url: URL) {
        for u in [url, prevURL(url), metaURL(url)] { try? FileManager.default.removeItem(at: u) }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// the safety copies of each firmware's flash (see the top). Thread-safe; any thread
public final class FlashHistory: @unchecked Sendable {
    public enum Kind: String, Codable, Sendable { case event, rolling, daily }

    /// why a copy was taken
    public enum Reason: Sendable, Equatable {
        case rolling
        case beforeUpdate(from: String, to: String)
        case beforeDelete(String)
        case beforeReset
        case beforeRestore
        case beforeLoadState            // (step 2)
        case beforeManagerWrite         // (step 5)
        case firstCopy                  // a flash saved before this build (no version known)
        case other(String)

        public var text: String {
            switch self {
            case .rolling: return "rolling"
            case .beforeUpdate(let a, let b): return "before update \(a.isEmpty ? "?" : a)→\(b.isEmpty ? "?" : b)"
            case .beforeDelete(let n): return n.isEmpty ? "before delete" : "before deleting \(n)"
            case .beforeReset: return "before reset"
            case .beforeRestore: return "before restore"
            case .beforeLoadState: return "before load state"
            case .beforeManagerWrite: return "before manager write"
            case .firstCopy: return "first safety copy"
            case .other(let s): return s
            }
        }

        var kind: Kind { self == .rolling ? .rolling : .event }
    }

    public struct Snapshot: Codable, Sendable, Equatable, Identifiable {
        public var id: String           // its file: <id>.bin
        public var kind: Kind
        public var reason: String       // "rolling", "daily", "before update 1.6.1→1.6.2", ...
        public var firmwareID: String
        public var version: String
        public var date: Date
        public var size: Int
        public var sha256: String
    }

    public let root: URL
    public let now: @Sendable () -> Date
    public var keepRolling = 10, keepDays = 7, keepEvents = 30
    /// rolling copies at most this often (the clock saves every 30 device s while the flash changes)
    public var rollingInterval: TimeInterval = 5 * 60
    public var calendar = Calendar.current
    private let lock = NSLock()

    public init(root: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root ?? Self.defaultRoot()
        self.now = now
    }

    /// Application Support/FlashHistory (step 2: the App Group's)
    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlashHistory")
    }

    /// the copies of a firmware, newest first
    public func list(_ firmwareID: String) -> [Snapshot] {
        lock.withLock { Array(ordered(load(firmwareID)).reversed()) }
    }

    /// a copy's bytes (nil: missing, or not what was saved)
    public func data(_ s: Snapshot) -> Data? {
        guard let d = try? Data(contentsOf: dir(s.firmwareID).appendingPathComponent("\(s.id).bin")),
              FlashFile.sha256(d) == s.sha256 else { return nil }
        return d
    }

    /// a copy of data kept; nil when none was needed (empty data, a rolling copy too soon or the same as the newest).
    /// A risky step's copy that equals the newest copy relabels that copy rather than keeping the bytes twice
    @discardableResult
    public func record(_ data: Data, firmwareID: String, version: String, reason: Reason) -> Snapshot? {
        guard !data.isEmpty, !firmwareID.isEmpty else { return nil }
        return lock.withLock {
            var list = ordered(load(firmwareID))
            let hash = FlashFile.sha256(data)
            let t = now()
            if let i = list.indices.last, list[i].sha256 == hash {
                if reason.kind == .event && list[i].kind != .event {
                    list[i].kind = .event
                    list[i].reason = reason.text
                    save(list, firmwareID)
                }
                return reason.kind == .event ? list[i] : nil
            }
            if reason == .rolling, let r = list.last(where: { $0.kind != .event }),
               t.timeIntervalSince(r.date) < rollingInterval, t >= r.date {
                return nil
            }
            let s = Snapshot(id: UUID().uuidString, kind: reason.kind, reason: reason.text, firmwareID: firmwareID,
                             version: version, date: t, size: data.count, sha256: hash)
            do {
                try FileManager.default.createDirectory(at: dir(firmwareID), withIntermediateDirectories: true)
                try data.write(to: dir(firmwareID).appendingPathComponent("\(s.id).bin"), options: .atomic)
            } catch {
                RFMShared.log("flash").error("history \(firmwareID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
            list.append(s)
            save(prune(list), firmwareID)
            return s
        }
    }

    /// the rules: every event copy up to keepEvents; the last keepRolling rolling copies; the newest of each of the
    /// last keepDays days (as "daily"); the rest removed
    func prune(_ list: [Snapshot]) -> [Snapshot] {
        let t = now()
        let events = list.filter { $0.kind == .event }.sorted { $0.date > $1.date }
        let rolling = list.filter { $0.kind != .event }.sorted { $0.date > $1.date }
        var keep = Set(events.prefix(keepEvents).map(\.id))
        let recent = Set(rolling.prefix(keepRolling).map(\.id))
        keep.formUnion(recent)
        let today = calendar.startOfDay(for: t)
        let first = calendar.date(byAdding: .day, value: -(keepDays - 1), to: today) ?? today
        var days = Set<Date>(), daily = Set<String>()
        for r in rolling where r.date >= first {
            if days.insert(calendar.startOfDay(for: r.date)).inserted { daily.insert(r.id) }
        }
        keep.formUnion(daily)
        var out: [Snapshot] = []
        for var s in list {
            if keep.contains(s.id) {
                if s.kind != .event { s.kind = recent.contains(s.id) ? .rolling : .daily; s.reason = s.kind.rawValue }
                out.append(s)
            } else {
                try? FileManager.default.removeItem(at: dir(s.firmwareID).appendingPathComponent("\(s.id).bin"))
            }
        }
        return out
    }

    /// oldest first (the order kept for copies of the same moment)
    private func ordered(_ l: [Snapshot]) -> [Snapshot] {
        l.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
    }

    func dir(_ firmwareID: String) -> URL {
        root.appendingPathComponent(firmwareID.replacingOccurrences(of: "/", with: "_"))
    }

    private func load(_ firmwareID: String) -> [Snapshot] {
        (try? Data(contentsOf: dir(firmwareID).appendingPathComponent("index.json")))
            .flatMap { try? FlashFile.decoder.decode([Snapshot].self, from: $0) } ?? []
    }

    private func save(_ list: [Snapshot], _ firmwareID: String) {
        try? FileManager.default.createDirectory(at: dir(firmwareID), withIntermediateDirectories: true)
        try? FlashFile.encoder.encode(list).write(to: dir(firmwareID).appendingPathComponent("index.json"), options: .atomic)
    }
}
