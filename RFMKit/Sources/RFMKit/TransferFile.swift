// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Send to another device (the owner, 2026-11-01: users copied files from an iPhone to an iPad and couldn't get the
// same state back). One .rfm1transfer file holds what another device needs:
//   every state in the library, as .rfm1state bytes
//   each firmware's current memory, as a state "Current memory from <device>" (the memory itself isn't in Files)
//   the .rfm1 file of each firmware those states were made with, when it is on this device (not the built-in ones)
// Layout: "RFM1XFER", the manifest's length (UInt32, little-endian), the manifest (JSON: format, app, device, date,
// the entries: kind, name, size, SHA-256, current), then each entry's bytes in order. Read back: every length and
// checksum checked. Opened on the other device: the firmware files first (one already there is skipped), then the
// states (a state already in the library is skipped); the current memories are offered to load.

import Foundation

public enum TransferFile {
    public static let fileExtension = "rfm1transfer"
    public static let typeIdentifier = "com.quixotic7.remotefm1.transfer"
    static let magic = Data("RFM1XFER".utf8)
    static let format = 1

    public enum FileError: LocalizedError, Equatable {
        case notTransfer, newer(Int), damaged
        public var errorDescription: String? {
            switch self {
            case .notTransfer: "This isn't a RemoteFM1 transfer file."
            case .newer(let f): "This file was made by a newer RemoteFM1 (format \(f)): update the app to open it."
            case .damaged: "This transfer file is damaged or cut short: send it again."
            }
        }
    }

    struct Manifest: Codable {
        var format: Int
        var app: String
        var device: String
        var date: Date
        var entries: [Entry]
    }

    struct Entry: Codable {
        var kind: String                    // "state" | "firmware"
        var name: String                    // a firmware's file name; a state's name
        var size: Int
        var sha256: String
        var current: Bool?                  // a state: a firmware's current memory
    }

    public struct Decoded: Sendable {
        public var device = "", app = ""
        public var date = Date()
        public var states: [(state: StateFile.Decoded, current: Bool)] = []
        public var firmware: [(name: String, data: Data)] = []
    }

    /// the file's bytes. states: each with its flash and whether it is a current memory; firmware: (file name, bytes)
    public static func encode(states: [(SavedState, Data, Bool)], firmware: [(String, Data)], device: String,
                              app: String, date: Date = Date()) -> Data {
        var entries: [Entry] = [], blobs: [Data] = []
        for (s, flash, cur) in states {
            let b = StateFile.encode(s, flash: flash)
            entries.append(Entry(kind: "state", name: s.name, size: b.count, sha256: FlashFile.sha256(b), current: cur))
            blobs.append(b)
        }
        for (n, d) in firmware {
            entries.append(Entry(kind: "firmware", name: n, size: d.count, sha256: FlashFile.sha256(d), current: nil))
            blobs.append(d)
        }
        let m = Manifest(format: format, app: app, device: device, date: date, entries: entries)
        let json = (try? FlashFile.encoder.encode(m)) ?? Data()
        var out = magic
        var n = UInt32(json.count).littleEndian
        out.append(Data(bytes: &n, count: 4))
        out.append(json)
        for b in blobs { out.append(b) }
        return out
    }

    public static func decode(_ d: Data) throws -> Decoded {
        guard d.count >= magic.count, d.prefix(magic.count) == magic else { throw FileError.notTransfer }
        guard d.count >= 12 else { throw FileError.damaged }
        let n = Int(d.subdata(in: d.startIndex + 8 ..< d.startIndex + 12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard n > 0, n <= 16 << 20, d.count >= 12 + n else { throw FileError.damaged }
        let json = d.subdata(in: d.startIndex + 12 ..< d.startIndex + 12 + n)
        guard let m = try? FlashFile.decoder.decode(Manifest.self, from: json) else {
            if let any = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let f = any["format"] as? Int,
               f > format { throw FileError.newer(f) }
            throw FileError.damaged
        }
        if m.format > format { throw FileError.newer(m.format) }
        var out = Decoded(device: m.device, app: m.app, date: m.date)
        var at = d.startIndex + 12 + n
        for e in m.entries {
            guard e.size >= 0, d.endIndex - at >= e.size else { throw FileError.damaged }
            let b = d.subdata(in: at ..< at + e.size)
            at += e.size
            guard FlashFile.sha256(b) == e.sha256 else { throw FileError.damaged }
            switch e.kind {
            case "state": out.states.append((try StateFile.decode(b), e.current ?? false))
            case "firmware": out.firmware.append((e.name, b))
            default: continue                       // (a kind from a newer app: left out)
            }
        }
        guard at == d.endIndex else { throw FileError.damaged }
        return out
    }

    /// the file for this device: every state, each current memory (a firmware's flash once; empty ones left out), and
    /// the .rfm1 files of the versions they were made with
    public static func make(library: StateLibrary, current: [Backup.Current], files: [(ImportedFirmware, URL)],
                            device: String, app: String, date: Date = Date()) -> Data {
        var states: [(SavedState, Data, Bool)] = []
        for s in library.allStates().sorted(by: { ($0.firmwareID, $0.date) < ($1.firmwareID, $1.date) }) {
            if let f = try? library.flash(s) { states.append((s, f, false)) }
        }
        var seen = Set<String>()
        for c in current where !c.flash.isEmpty && !FlashFile.looksErased(c.flash) && seen.insert(FlashFile.sha256(c.flash)).inserted {
            let s = SavedState(id: UUID().uuidString, name: "Current memory from \(device)", note: "Sent \(date.formatted())",
                               firmwareID: c.firmwareID, firmwareName: c.firmwareName, kind: c.kind, version: c.version,
                               sha256: c.sha256, date: date, flashSize: c.flash.count, flashSHA256: FlashFile.sha256(c.flash),
                               master: nil, transpose: nil, keyTouch: nil, origin: "transfer")
            states.append((s, c.flash, true))
        }
        let wanted = Set(states.map { "\($0.0.firmwareID) \($0.0.version)" })
        var firmware: [(String, Data)] = [], sent = Set<String>()
        for (f, u) in files where f.error == nil && wanted.contains("\(f.coreID) \(f.version)") && sent.insert(f.sha256).inserted {
            if let d = try? Data(contentsOf: u) { firmware.append((u.lastPathComponent, d)) }
        }
        return encode(states: states, firmware: firmware, device: device, app: app, date: date)
    }

    /// what opening a file did
    public struct Report: Sendable {
        public var device = ""
        public var statesAdded = 0, statesHere = 0
        public var firmwareAdded: [String] = [], firmwareHere = 0
        public var failed: [String] = []
        /// the current memories (the library's entries), to offer a load
        public var current: [SavedState] = []
        /// the states of firmware not on this device: "<name> <version>"
        public var missing: [String] = []

        public var text: String {
            var t = "From \(device.isEmpty ? "another device" : device): \(statesAdded) state\(statesAdded == 1 ? "" : "s") added"
            if statesHere > 0 { t += ", \(statesHere) already here" }
            t += "."
            if !firmwareAdded.isEmpty { t += " Added \(firmwareAdded.joined(separator: ", "))." }
            if !failed.isEmpty { t += " Not read: \(failed.joined(separator: "; "))." }
            return t
        }
    }

    /// a decoded file into this device: the firmware files, then the states. coreIDs: what is on this device then
    /// (firmware id and version), for the missing list
    @MainActor
    public static func importInto(_ d: Decoded, states lib: StateLibrary, firmware: FirmwareLibrary,
                                  installed: () -> [(String, String)]) -> Report {
        var r = Report(device: d.device)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("rfm1-transfer-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (n, data) in d.firmware {
            let sha = FlashFile.sha256(data)
            if firmware.files.contains(where: { $0.sha256 == sha && $0.error == nil }) { r.firmwareHere += 1; continue }
            var name = (n as NSString).lastPathComponent
            if name.isEmpty || name.hasPrefix(".") || !name.lowercased().hasSuffix(".rfm1") { name = "firmware-\(sha.prefix(8)).rfm1" }
            let u = tmp.appendingPathComponent(name)
            do {
                try data.write(to: u)
                let f = try firmware.importFile(u)
                if let e = f.error { firmware.delete(f); r.failed.append("\(name): \(e)") }
                else { r.firmwareAdded.append("\(f.name) \(f.version)") }
            } catch { r.failed.append("\(name): \(error.localizedDescription)") }
        }
        for (s, cur) in d.states {
            do {
                let i = try lib.importState(s)
                if i.duplicate { r.statesHere += 1 } else { r.statesAdded += 1 }
                if cur { r.current.append(i.state) }
            } catch { r.failed.append("\(s.state.name): \(error.localizedDescription)") }
        }
        let ids = Set(installed().map(\.0))
        var miss = Set<String>()
        for (s, _) in d.states where !ids.contains(s.state.firmwareID) {
            miss.insert("\(s.state.firmwareName.isEmpty ? s.state.firmwareID : s.state.firmwareName) \(s.state.version)")
        }
        r.missing = miss.sorted()
        return r
    }
}
