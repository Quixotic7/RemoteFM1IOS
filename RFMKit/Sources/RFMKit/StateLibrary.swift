// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// PLAN.md section 18 step 2: named states, one library for the app and every AU instance (the App Group container).
//
//   <root>/<firmware id>/<uuid>.flash   the flash, LZFSE-compressed (as the AU's fullState); written by FlashFile
//                                       (temp file, fsync, read back and compared, renamed in)
//   <root>/<firmware id>/<uuid>.json    the entry (SavedState): name, note, the firmware (id, kind, version, file
//                                       hash), the date, the flash's size and hash, MASTER and the settings kept
//
// One pair of files per state and no index, so writers in several processes (the app, AU instances in one or more
// hosts) never overwrite each other's changes: a save writes its own new files (the flash first: an entry always
// names bytes that are there), a rename or note rewrites one entry atomically, a delete removes the entry, then
// the bytes. No locks (a suspended iOS process holding a lock in the shared container is killed: PLAN.md section 4).
// Every change posts a Darwin notification (and this process's StateLibrary.didChange), so open pages list again.
//
// The settings kept besides the flash: MASTER (the pot isn't in the flash) and, of AUSettings, the two that change
// how the firmware plays: transpose and the keys' touch. Routing (keys' MIDI channel, notes to the firmware, the
// learned map, the host's clock) and the view (button names) stay the instance's or the app's own.

import Foundation

/// one named state in the library
public struct SavedState: Codable, Sendable, Equatable, Identifiable {
    public var id: String                   // its files: <id>.json, <id>.flash
    public var name: String
    public var note: String
    public var firmwareID: String           // the firmware's own id (CoreInfo.firmwareID)
    public var firmwareName: String
    public var kind: String                 // "native" | "wasm" (an imported .rfm1)
    public var version: String
    public var sha256: String               // an imported file's ("" for a built-in core)
    public var date: Date
    public var flashSize: Int
    public var flashSHA256: String          // the uncompressed flash's
    public var master: Int?                 // the MASTER pot, 0..1023; nil: not known
    public var transpose: Int?              // AUSettings.transpose
    public var keyTouch: Bool?              // AUSettings.keyTouch
    public var origin: String               // "app" | "au": where it was saved (shown, nothing else)

    /// "made with 1.6.1" when `version` isn't the running one ("" when it is, or unknown)
    public func versionNote(running: String) -> String {
        version.isEmpty || running.isEmpty || version == running ? "" : "made with \(version)"
    }

    /// the kept settings applied to `s`
    public func apply(to s: inout AUSettings) {
        if let transpose { s.transpose = max(-2, min(2, transpose)) }
        if let keyTouch { s.keyTouch = keyTouch }
    }
}

/// the library (see the top). Thread-safe without locks; any thread
public final class StateLibrary: @unchecked Sendable {
    public enum LibraryError: LocalizedError {
        case empty, missing, damaged
        public var errorDescription: String? {
            switch self {
            case .empty: "No memory to save."
            case .missing: "That state is no longer in the library."
            case .damaged: "That state's memory can't be read."
            }
        }
    }

    public let root: URL
    public let now: @Sendable () -> Date

    public init(root: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root ?? Self.defaultRoot()
        self.now = now
        Self.observe()
    }

    /// the App Group's States; no group: this process's Application Support/States
    public static func defaultRoot() -> URL {
        RFMShared.groupContainer()?.appendingPathComponent("States")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("States")
    }

    public static let shared = StateLibrary()

    /// "<Firmware> <date>"
    public static func defaultName(_ firmware: String, date: Date = Date()) -> String {
        "\(firmware.isEmpty ? "State" : firmware) \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: reading

    /// a firmware's states, newest first
    public func list(_ firmwareID: String) -> [SavedState] {
        let d = dir(firmwareID), fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: d.path)) ?? []
        let set = Set(names)
        var out: [SavedState] = []
        for n in names where n.hasSuffix(".json") && !n.hasPrefix(".") {
            guard let data = try? Data(contentsOf: d.appendingPathComponent(n)),
                  let s = try? FlashFile.decoder.decode(SavedState.self, from: data),
                  set.contains("\(s.id).flash") else { continue }       // (a delete half done: not listed)
            out.append(s)
        }
        // bytes without an entry: a save cut short (an hour old; a save in progress has its entry within ms)
        for n in names where n.hasSuffix(".flash") && !set.contains(n.replacingOccurrences(of: ".flash", with: ".json")) {
            let u = d.appendingPathComponent(n)
            if let m = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date, now().timeIntervalSince(m) > 3600 {
                try? fm.removeItem(at: u)
            }
        }
        return out.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// a state's flash, uncompressed and checked
    public func flash(_ s: SavedState) throws -> Data {
        guard let z = try? Data(contentsOf: flashURL(s)) else { throw LibraryError.missing }
        guard let raw = try? (z as NSData).decompressed(using: .lzfse) as Data,
              raw.count == s.flashSize, FlashFile.sha256(raw) == s.flashSHA256 else { throw LibraryError.damaged }
        return raw
    }

    // MARK: writing

    /// a new state; its files written safely (the bytes first, checked), then the others told
    @discardableResult
    public func save(name: String, note: String = "", firmwareID: String, firmwareName: String, kind: String,
                     version: String, sha256: String = "", flash: Data, master: Int? = nil,
                     settings: AUSettings? = nil, origin: String) throws -> SavedState {
        guard !flash.isEmpty, !firmwareID.isEmpty else { throw LibraryError.empty }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = SavedState(id: UUID().uuidString, name: n.isEmpty ? Self.defaultName(firmwareName, date: now()) : n,
                           note: note, firmwareID: firmwareID, firmwareName: firmwareName, kind: kind, version: version,
                           sha256: sha256, date: now(), flashSize: flash.count, flashSHA256: FlashFile.sha256(flash),
                           master: master, transpose: settings?.transpose, keyTouch: settings?.keyTouch, origin: origin)
        let z = (try? (flash as NSData).compressed(using: .lzfse) as Data) ?? flash
        try FlashFile.write(z, to: flashURL(s), keepPrev: false)
        try FlashFile.encoder.encode(s).write(to: entryURL(s), options: .atomic)
        Self.postChange()
        return s
    }

    /// a state renamed (and its note, when given)
    @discardableResult
    public func rename(_ s: SavedState, to name: String, note: String? = nil) throws -> SavedState {
        guard var cur = entry(s) else { throw LibraryError.missing }    // (the newest entry: another writer's note kept)
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { cur.name = n }
        if let note { cur.note = note }
        guard FileManager.default.fileExists(atPath: flashURL(s).path) else { throw LibraryError.missing }
        try FlashFile.encoder.encode(cur).write(to: entryURL(cur), options: .atomic)
        Self.postChange()
        return cur
    }

    /// a state removed (its entry, then its bytes)
    public func delete(_ s: SavedState) {
        try? FileManager.default.removeItem(at: entryURL(s))
        try? FileManager.default.removeItem(at: flashURL(s))
        Self.postChange()
    }

    /// the entry as the library has it now (nil: gone)
    public func entry(_ s: SavedState) -> SavedState? {
        (try? Data(contentsOf: entryURL(s))).flatMap { try? FlashFile.decoder.decode(SavedState.self, from: $0) }
    }

    func dir(_ firmwareID: String) -> URL {
        root.appendingPathComponent(firmwareID.replacingOccurrences(of: "/", with: "_"))
    }
    private func entryURL(_ s: SavedState) -> URL { dir(s.firmwareID).appendingPathComponent("\(s.id).json") }
    private func flashURL(_ s: SavedState) -> URL { dir(s.firmwareID).appendingPathComponent("\(s.id).flash") }

    // MARK: change notification (the library and the safety copies)

    /// the Darwin notification every process posts after a change (states or safety copies)
    public static let changedNotification = "\(RFMShared.appGroup).states"
    /// this process's: posted on the main queue for every change, ours or another process's
    public static let didChange = Notification.Name("RFMStateLibraryDidChange")

    private nonisolated(unsafe) static var observing = false
    private static let observeLock = NSLock()

    /// (once per process) the Darwin notification forwarded as didChange
    static func observe() {
        let start = observeLock.withLock { () -> Bool in defer { observing = true }; return !observing }
        guard start else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: StateLibrary.didChange, object: nil) }
        }, changedNotification as CFString, nil, .deliverImmediately)
    }

    /// every process told (this one too, through the same notification)
    public static func postChange() {
        observe()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(changedNotification as CFString), nil, nil, true)
    }
}
