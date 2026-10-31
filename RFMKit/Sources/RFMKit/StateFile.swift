// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// PLAN.md section 18 step 3: files and backups (docs/RFM1STATE-FORMAT.md).
//
//   StateFile    one .rfm1state file: "RFM1STAT", the manifest's length (UInt32, little-endian), the manifest
//                (JSON: format, the SavedState, the flash's encoding and stored length), the flash (LZFSE). Read back:
//                every length, the manifest, the decompressed size and SHA-256 checked; a bad file refused in plain
//                words.
//   import       StateLibrary.importState: a file's state into the library (its id kept when free); a state whose
//                flash is already in the library for that firmware is skipped (the one there returned).
//   StateMirror  Documents/States/<Firmware>/<state>.rfm1state kept like the library (Files sees it); a .rfm1state
//                the user puts there is imported. The library wins: a file renamed or removed in Files comes back;
//                a state deleted in the app leaves. A ledger (.mirror.json) says which files the mirror wrote.
//   Backup       Documents/Backups/RemoteFM1 backup <date>/: States/, Current/ (each firmware's flash now),
//                Safety copies/ (the newest 3 per firmware), manifest.json, README.txt. Restore: every .rfm1state
//                under States/ and Current/ (or any folder or file picked) imported, duplicates skipped.

import Foundation

public enum StateFile {
    public static let fileExtension = "rfm1state"
    public static let typeIdentifier = "com.quixotic7.remotefm1.state"
    static let magic = Data("RFM1STAT".utf8)
    public static let format = 1
    static let maxManifest = 1 << 20

    public enum FileError: LocalizedError, Equatable {
        case notState, truncated(have: Int, need: Int), newer(Int), badManifest, damaged
        public var errorDescription: String? {
            switch self {
            case .notState: "This isn't a RemoteFM1 state file."
            case .truncated(let h, let n):
                "This state file is cut short (\(h) of \(n) bytes): it may not have finished copying."
            case .newer(let f): "This state file was made by a newer RemoteFM1 (format \(f)): update the app to open it."
            case .badManifest: "This state file's description can't be read: it's damaged."
            case .damaged: "This state file's memory doesn't match its checksum: it's damaged."
            }
        }
    }

    struct Manifest: Codable {
        var format: Int
        var state: SavedState
        var flashEncoding: String           // "lzfse" | "none"
        var flashBytes: Int                 // as stored
    }

    /// a state read from a file
    public struct Decoded: Sendable {
        public var state: SavedState
        public var flash: Data
    }

    /// the file's bytes
    public static func encode(_ s: SavedState, flash: Data) -> Data {
        var st = s
        st.flashSize = flash.count
        st.flashSHA256 = FlashFile.sha256(flash)
        let z = (try? (flash as NSData).compressed(using: .lzfse) as Data)
        let body = z ?? flash
        let m = Manifest(format: format, state: st, flashEncoding: z == nil ? "none" : "lzfse", flashBytes: body.count)
        let json = (try? FlashFile.encoder.encode(m)) ?? Data()
        var out = magic
        var n = UInt32(json.count).littleEndian
        out.append(Data(bytes: &n, count: 4))
        out.append(json)
        out.append(body)
        return out
    }

    /// the manifest and where the flash starts (the flash not read)
    static func manifest(_ d: Data) throws -> (Manifest, Int) {
        guard d.count >= magic.count, d.prefix(magic.count) == magic else { throw FileError.notState }
        guard d.count >= 12 else { throw FileError.truncated(have: d.count, need: 12) }
        let b = d.startIndex
        let n = Int(d[b + 8]) | Int(d[b + 9]) << 8 | Int(d[b + 10]) << 16 | Int(d[b + 11]) << 24
        guard n > 0, n <= maxManifest else { throw FileError.badManifest }
        guard d.count >= 12 + n else { throw FileError.truncated(have: d.count, need: 12 + n) }
        let m: Manifest
        do { m = try FlashFile.decoder.decode(Manifest.self, from: d.subdata(in: b + 12 ..< b + 12 + n)) }
        catch {
            if let f = (try? JSONSerialization.jsonObject(with: d.subdata(in: b + 12 ..< b + 12 + n)) as? [String: Any])?["format"] as? Int,
               f > format { throw FileError.newer(f) }
            throw FileError.badManifest
        }
        if m.format > format { throw FileError.newer(m.format) }
        return (m, 12 + n)
    }

    /// a file's state and flash, everything checked
    public static func decode(_ d: Data) throws -> Decoded {
        let (m, at) = try manifest(d)
        let need = at + m.flashBytes
        guard d.count >= need else { throw FileError.truncated(have: d.count, need: need) }
        guard d.count == need, m.state.flashSize > 0 else { throw FileError.damaged }
        let body = d.subdata(in: d.startIndex + at ..< d.startIndex + need)
        let raw: Data
        switch m.flashEncoding {
        case "none": raw = body
        case "lzfse": guard let r = try? (body as NSData).decompressed(using: .lzfse) as Data else { throw FileError.damaged }
            raw = r
        default: throw FileError.badManifest
        }
        guard raw.count == m.state.flashSize, FlashFile.sha256(raw) == m.state.flashSHA256 else { throw FileError.damaged }
        return Decoded(state: m.state, flash: raw)
    }

    public static func read(_ url: URL) throws -> Decoded {
        guard let d = try? Data(contentsOf: url) else { throw CocoaError(.fileReadUnknown) }
        return try decode(d)
    }

    /// a name usable as a file name ("/" and ":" replaced; empty: "State")
    public static func safeName(_ s: String) -> String {
        var n = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? "State" : String(n.prefix(120))
    }

    /// a temporary <name>.rfm1state of a library state (to share)
    public static func temporaryFile(_ s: SavedState, library: StateLibrary) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("Share-\(s.id)")
        try? FileManager.default.removeItem(at: d)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent("\(safeName(s.name)).\(fileExtension)")
        try encode(s, flash: try library.flash(s)).write(to: u, options: .atomic)
        return u
    }
}

// MARK: the library's side

extension StateLibrary {
    public struct Imported: Sendable {
        public var state: SavedState
        public var duplicate: Bool          // already there (the library's state returned)
    }

    /// every state, every firmware
    public func allStates() -> [SavedState] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var seen = Set<String>(), out: [SavedState] = []
        for d in ids where !d.hasPrefix(".") {
            for s in listDir(d) where seen.insert(s.id).inserted { out.append(s) }
        }
        return out
    }

    private func listDir(_ name: String) -> [SavedState] {
        let d = root.appendingPathComponent(name)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        guard let first = names.first(where: { $0.hasSuffix(".json") && !$0.hasPrefix(".") }),
              let data = try? Data(contentsOf: d.appendingPathComponent(first)),
              let s = try? FlashFile.decoder.decode(SavedState.self, from: data) else { return [] }
        return list(s.firmwareID)
    }

    /// a file's state into the library: its id kept when free; already there (the same flash for that firmware):
    /// nothing written, the library's returned
    @discardableResult
    public func importState(_ f: StateFile.Decoded) throws -> Imported {
        guard !f.flash.isEmpty, !f.state.firmwareID.isEmpty else { throw LibraryError.empty }
        let hash = FlashFile.sha256(f.flash)
        let have = list(f.state.firmwareID)
        if let d = have.first(where: { $0.flashSHA256 == hash }) { return Imported(state: d, duplicate: true) }
        var s = f.state
        if s.id.isEmpty || entry(s) != nil || s.id.contains("/") || s.id.hasPrefix(".") { s.id = UUID().uuidString }
        s.flashSize = f.flash.count
        s.flashSHA256 = hash
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = Self.defaultName(s.firmwareName, date: s.date) }
        try add(s, flash: f.flash)
        return Imported(state: s, duplicate: false)
    }

    /// a .rfm1state file imported (see importState)
    @discardableResult
    public func importFile(_ url: URL) throws -> Imported { try importState(StateFile.read(url)) }
}

// MARK: the Documents mirror

public final class StateMirror: @unchecked Sendable {
    public struct Report: Sendable, Equatable {
        public var written = 0, moved = 0, removed = 0, imported = 0, duplicates = 0
        public var failed: [String] = []            // "<file>: why"
        public var importedStates: [SavedState] = []
    }

    struct Ledger: Codable { var files: [String: Entry] = [:] }   // state id → the file
    struct Entry: Codable { var path: String; var name: String; var note: String }

    public let root: URL
    public let library: StateLibrary
    private let lock = NSLock()

    public init(root: URL? = nil, library: StateLibrary = .shared) {
        self.root = root ?? Self.defaultRoot()
        self.library = library
    }

    /// Documents/States (the app's; Files shows it)
    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("States")
    }

    public static let readme = """
        RemoteFM1 states

        Each folder is a firmware; each .rfm1state file is a state saved in the app or the AU instrument (the \
        firmware's memory with MASTER, the octave and the keys' touch). The app keeps this folder like its library: \
        rename, delete and load states in the app (Firmware › States); a file renamed or removed here comes back.

        To add a state, put its .rfm1state file anywhere in this folder: the app imports it the next time it opens \
        (a state already in the library is skipped). Share a state from its … menu in the app, or open a \
        .rfm1state file from Files, Mail or AirDrop.

        Back up everything (Settings) writes a backup folder in Backups, beside this one.

        """

    private var ledgerURL: URL { root.appendingPathComponent(".mirror.json") }

    /// the folder made like the library (see the top); files found there imported first
    @discardableResult
    public func sync() -> Report {
        lock.withLock { syncLocked() }
    }

    private func syncLocked() -> Report {
        let fm = FileManager.default
        var r = Report()
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let readmeURL = root.appendingPathComponent("README.txt")
        if (try? String(contentsOf: readmeURL, encoding: .utf8)) != Self.readme {
            try? Self.readme.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
        var ledger = (try? Data(contentsOf: ledgerURL)).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()

        // the files there: their ids (manifest only)
        var files: [String: String] = [:]          // relative path → state id
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.pathExtension.lowercased() == StateFile.fileExtension {
                let rel = String(u.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                guard let d = try? Data(contentsOf: u) else { continue }
                do { files[rel] = try StateFile.manifest(d).0.state.id }
                catch { r.failed.append("\(rel): \(error.localizedDescription)") }
            }
        }
        var lib = Dictionary(library.allStates().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // new files (not the mirror's): imported
        for (rel, id) in files.sorted(by: { $0.key < $1.key }) where lib[id] == nil && ledger.files[id] == nil {
            do {
                let i = try library.importFile(root.appendingPathComponent(rel))
                if i.duplicate { r.duplicates += 1; continue }
                r.imported += 1
                r.importedStates.append(i.state)
                lib[i.state.id] = i.state
                if i.state.id == id { ledger.files[id] = Entry(path: rel, name: "", note: "") }   // (renamed below)
            } catch { r.failed.append("\(rel): \(error.localizedDescription)") }
        }
        // the mirror's files of states gone from the library: removed
        for (id, e) in ledger.files where lib[id] == nil {
            if files[e.path] == id { try? fm.removeItem(at: root.appendingPathComponent(e.path)); r.removed += 1 }
            ledger.files[id] = nil
        }
        // every state at its place
        let byPath = files
        var taken = Set<String>()
        for (rel, id) in byPath where lib[id] == nil { taken.insert(rel.lowercased()) }   // (the user's other files)
        for s in lib.values.sorted(by: { ($0.date, $0.id) < ($1.date, $1.id) }) {
            let folder = StateFile.safeName(s.firmwareName.isEmpty ? s.firmwareID : s.firmwareName)
            let base = StateFile.safeName(s.name)
            var rel = "\(folder)/\(base).\(StateFile.fileExtension)", n = 2
            while taken.contains(rel.lowercased()) || (byPath[rel] != nil && byPath[rel] != s.id) {
                rel = "\(folder)/\(base) \(n).\(StateFile.fileExtension)"; n += 1
            }
            taken.insert(rel.lowercased())
            let dst = root.appendingPathComponent(rel)
            let have = ledger.files[s.id].flatMap { byPath[$0.path] == s.id ? $0.path : nil }
                ?? byPath.first(where: { $0.value == s.id })?.key
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let have, have != rel {
                    try fm.moveItem(at: root.appendingPathComponent(have), to: dst)
                    r.moved += 1
                }
                let e = ledger.files[s.id]
                if have == nil || e?.name != s.name || e?.note != s.note {
                    try StateFile.encode(s, flash: try library.flash(s)).write(to: dst, options: .atomic)
                    if have == nil { r.written += 1 }
                }
                ledger.files[s.id] = Entry(path: rel, name: s.name, note: s.note)
            } catch { r.failed.append("\(rel): \(error.localizedDescription)") }
        }
        // empty firmware folders left by a rename or a delete
        for d in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !d.hasPrefix(".") {
            let u = root.appendingPathComponent(d)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
               (try? fm.contentsOfDirectory(atPath: u.path))?.isEmpty ?? false { try? fm.removeItem(at: u) }
        }
        if let d = try? JSONEncoder().encode(ledger) { try? d.write(to: ledgerURL, options: .atomic) }
        return r
    }
}

// MARK: Back up everything

public enum Backup {
    /// a firmware's flash as it is now (the caller reads it: the app's files)
    public struct Current: Sendable {
        public var firmwareID, firmwareName, kind, version, sha256: String
        public var flash: Data
        public init(firmwareID: String, firmwareName: String, kind: String, version: String, sha256: String = "",
                    flash: Data) {
            self.firmwareID = firmwareID; self.firmwareName = firmwareName; self.kind = kind
            self.version = version; self.sha256 = sha256; self.flash = flash
        }
    }

    public struct Manifest: Codable, Sendable, Equatable {
        public struct Item: Codable, Sendable, Equatable {
            public var file: String                 // relative to the backup's folder
            public var name: String
            public var firmwareID: String
            public var version: String
            public var date: Date
            public var flashSHA256: String
        }
        public var format = 1
        public var date: Date
        public var app: String
        public var states: [Item] = []
        public var current: [Item] = []
        public var safetyCopies: [Item] = []
    }

    public struct RestoreReport: Sendable, Equatable {
        public var imported: [SavedState] = []
        public var duplicates = 0
        public var failed: [String] = []
        public init() {}
        /// plain words: "Imported 3 states (2 already there)."
        public var text: String {
            var t = imported.isEmpty ? "No new states" : "Imported \(imported.count) state\(imported.count == 1 ? "" : "s")"
            if duplicates > 0 { t += " (\(duplicates) already in the library)" }
            t += "."
            if !failed.isEmpty { t += " \(failed.count) file\(failed.count == 1 ? "" : "s") couldn't be read: " + failed.prefix(3).joined(separator: "; ") }
            return t
        }
    }

    public static let safetyCopiesKept = 3
    public static let readme = """
        RemoteFM1 backup

        States: every state in the library, one .rfm1state per state, by firmware.
        Current: each firmware's memory as it was at the backup ("<Firmware> current").
        Safety copies: the newest 3 safety copies of each firmware.
        manifest.json lists them.

        To restore, in the app: Settings › Restore from backup…, then pick this folder (a zip: tap it in Files to \
        unzip it first). The states in States and Current are added to the library; one already there is skipped, \
        nothing is overwritten. Any single .rfm1state can also be opened by itself.

        """

    /// Documents/Backups
    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Backups")
    }

    public static func folderName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "RemoteFM1 backup \(f.string(from: date))"
    }

    /// a new backup folder under `root` (a second one in the same minute: " 2"); its URL and manifest
    public static func write(into root: URL = defaultRoot(), library: StateLibrary, history: FlashHistory,
                             current: [Current], app: String = "", date: Date = Date()) throws -> (URL, Manifest) {
        let fm = FileManager.default
        var dir = root.appendingPathComponent(folderName(date)), n = 2
        while fm.fileExists(atPath: dir.path) { dir = root.appendingPathComponent("\(folderName(date)) \(n)"); n += 1 }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var m = Manifest(date: date, app: app)
        var used = Set<String>()
        func place(_ folder: String, _ base: String) -> String {
            var rel = "\(folder)/\(StateFile.safeName(base)).\(StateFile.fileExtension)", i = 2
            while used.contains(rel.lowercased()) { rel = "\(folder)/\(StateFile.safeName(base)) \(i).\(StateFile.fileExtension)"; i += 1 }
            used.insert(rel.lowercased())
            return rel
        }
        func put(_ s: SavedState, _ flash: Data, _ rel: String) throws -> Manifest.Item {
            let u = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FlashFile.write(StateFile.encode(s, flash: flash), to: u, keepPrev: false)
            return .init(file: rel, name: s.name, firmwareID: s.firmwareID, version: s.version, date: s.date,
                         flashSHA256: FlashFile.sha256(flash))
        }
        let states = library.allStates()
        var names: [String: String] = [:]           // firmware id → name
        for s in states { names[s.firmwareID] = s.firmwareName }
        for c in current { names[c.firmwareID] = c.firmwareName }
        func folder(_ id: String) -> String { StateFile.safeName(names[id].flatMap { $0.isEmpty ? nil : $0 } ?? id) }

        for s in states.sorted(by: { ($0.firmwareID, $0.date) < ($1.firmwareID, $1.date) }) {
            guard let f = try? library.flash(s) else { continue }     // (damaged: left out, the rest kept)
            m.states.append(try put(s, f, place("States/\(folder(s.firmwareID))", s.name)))
        }
        var seen = Set<String>()
        for c in current where !c.flash.isEmpty && seen.insert(FlashFile.sha256(c.flash)).inserted {
            let s = SavedState(id: UUID().uuidString, name: "\(c.firmwareName) current", note: "Backed up \(date.formatted())",
                               firmwareID: c.firmwareID, firmwareName: c.firmwareName, kind: c.kind, version: c.version,
                               sha256: c.sha256, date: date, flashSize: 0, flashSHA256: "", master: nil, transpose: nil,
                               keyTouch: nil, origin: "backup")
            m.current.append(try put(s, c.flash, place("Current", s.name)))
        }
        let ids = Set((try? fm.contentsOfDirectory(atPath: history.root.path))?.filter { !$0.hasPrefix(".") } ?? [])
        for id in ids.sorted() {
            for snap in history.list(id).prefix(safetyCopiesKept) {
                guard let d = history.data(snap) else { continue }
                let fname = names[snap.firmwareID] ?? snap.firmwareID
                let label = "\(fname) \(snap.date.formatted(date: .abbreviated, time: .shortened)) \(snap.reason)"
                let s = SavedState(id: snap.id, name: label, note: "A safety copy (\(snap.reason))",
                                   firmwareID: snap.firmwareID, firmwareName: fname, kind: "", version: snap.version,
                                   sha256: "", date: snap.date, flashSize: 0, flashSHA256: "", master: nil,
                                   transpose: nil, keyTouch: nil, origin: "safety copy")
                m.safetyCopies.append(try put(s, d, place("Safety copies/\(folder(snap.firmwareID))", label)))
            }
        }
        try FlashFile.encoder.encode(m).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        try readme.write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        return (dir, m)
    }

    /// a backup folder's States and Current imported (a folder that isn't a backup: every .rfm1state in it; a file:
    /// that one). Nothing overwritten: a state already in the library is skipped
    public static func restore(from url: URL, into library: StateLibrary) -> RestoreReport {
        let fm = FileManager.default
        var r = RestoreReport()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            r.failed.append("\(url.lastPathComponent): not found")
            return r
        }
        var files: [URL] = []
        if !isDir.boolValue { files = [url] } else {
            let isBackup = fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
            let tops = isBackup ? ["States", "Current"].map { url.appendingPathComponent($0) } : [url]
            for t in tops {
                guard let e = fm.enumerator(at: t, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for case let u as URL in e where u.pathExtension.lowercased() == StateFile.fileExtension { files.append(u) }
            }
        }
        for u in files.sorted(by: { $0.path < $1.path }) {
            do {
                let i = try library.importFile(u)
                if i.duplicate { r.duplicates += 1 } else { r.imported.append(i.state) }
            } catch { r.failed.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
        return r
    }

    /// a zip of a folder (the system's, through NSFileCoordinator's forUploading), copied to the temporary folder
    public static func zip(_ dir: URL) throws -> URL {
        var out: URL?, err: Error?
        var cerr: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &cerr) { z in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(dir.lastPathComponent).zip")
            do {
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: z, to: dst)
                out = dst
            } catch { err = error }
        }
        if let e = cerr ?? err { throw e }
        guard let out else { throw CocoaError(.fileWriteUnknown) }
        return out
    }
}
