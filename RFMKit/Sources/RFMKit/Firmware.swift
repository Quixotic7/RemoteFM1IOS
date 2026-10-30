// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Imported firmware (M7, PLAN.md section 9): .rfm1 files (docs/RFM1-FORMAT.md) the user puts into the app.
//
//   the folder    the app's Documents/Firmware, visible in the Files app (UIFileSharingEnabled,
//                 LSSupportsOpeningDocumentsInPlace), with a README.txt. Files land there from Files, from "Add
//                 firmware…" (a document picker), or by opening an .rfm1 (com.quixotic7.rfm1) from Files, Safari's
//                 downloads or AirDrop, which copies it in
//   the mirror    the AU extension can't read the app's Documents, so the app (FirmwareLibrary.sync: at launch, on
//                 returning to the foreground, after an import or a delete) copies each valid file into the App Group
//                 container as Firmware/<sha256>.rfm1 and writes Firmware/index.json (sha256, id, name, version,
//                 license, file size, added date). Mirrors of files no longer in Documents are removed. Invalid files
//                 stay in Documents and are listed with their error, not mirrored. Without an App Group (the Mac
//                 tests, an unsigned build) the mirror is Application Support/Firmware: the app alone sees it
//   the catalog   FirmwareCatalog (process-wide): the mirror's index as playable cores, read again when index.json
//                 changes; both the app and the extension list it next to the built-in cores (CorePlayer.catalog)
//
// Keys: an imported core's catalog key is "rfm1:<sha256>" (CoreInfo.id), so the same firmware imported twice (two
// versions) and a built-in core of the same id are separate entries. Saved selections and AU states keep the kind,
// id, version and SHA-256 (CoreRef): restoring finds the same file, else the same firmware id of the same kind (with a
// note), else as before.

import CryptoKit
import Foundation
import Observation
import RFMCore
import UniformTypeIdentifiers

/// one .rfm1 file the app knows: in the index (valid) or only in Documents (error set)
public struct ImportedFirmware: Codable, Sendable, Equatable, Identifiable {
    public var sha256: String
    public var coreID: String                   // the firmware's id ("felucca")
    public var name: String, version: String, license: String
    public var fileSize: Int
    public var added: Date
    public var file: String                     // its name in Documents/Firmware ("" unknown)
    public var error: String?                   // why it can't be played (then it is not mirrored)

    public var id: String { key }
    /// the catalog key (CoreInfo.id)
    public var key: String { FirmwareCatalog.keyPrefix + sha256 }

    enum CodingKeys: String, CodingKey {
        case sha256, coreID = "id", name, version, license, fileSize = "file_size", added, file, error
    }

    public init(sha256: String, coreID: String, name: String, version: String, license: String, fileSize: Int,
                added: Date = Date(), file: String = "", error: String? = nil) {
        self.sha256 = sha256
        self.coreID = coreID
        self.name = name
        self.version = version
        self.license = license
        self.fileSize = fileSize
        self.added = added
        self.file = file
        self.error = error
    }
}

/// what an About screen shows of an imported file, from its manifest and sections
public struct FirmwareDetails: Sendable, Equatable {
    public var authors: [String] = []
    public var sourceURL = "", glueURL = "", builtBy = ""
    public var credits = ""
    public var licenses: [String] = []          // rfm1.license.<n>: the first line is the licence's name

    /// read from the file (RFMWasm.h); empty when it isn't a valid .rfm1
    public static func read(_ path: String) -> FirmwareDetails {
        var d = FirmwareDetails()
        let m = text(path, "manifest")
        if let j = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any] {
            d.authors = (j["authors"] as? [Any])?.compactMap { $0 as? String } ?? []
            d.sourceURL = j["source_url"] as? String ?? ""
            d.glueURL = j["glue_url"] as? String ?? ""
            d.builtBy = j["built_by"] as? String ?? ""
        }
        d.credits = text(path, "credits")
        for i in 0..<64 {
            let t = text(path, "license.\(i)")
            if t.isEmpty { break }
            d.licenses.append(t)
        }
        return d
    }

    static func text(_ path: String, _ what: String) -> String {
        let n = Int(rfmw_text(path, what, nil, 0))
        guard n > 0 else { return "" }
        var b = [CChar](repeating: 0, count: n + 1)
        _ = rfmw_text(path, what, &b, UInt32(n + 1))
        return String(decoding: b.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// the playable imported firmware of this process: the mirror's index.json (thread-safe)
public final class FirmwareCatalog: @unchecked Sendable {
    public static let shared = FirmwareCatalog()
    public static let keyPrefix = "rfm1:"
    public static let indexName = "index.json"

    private let lock = NSLock()
    private var dir_: URL?
    private var stamp: Date?
    private var size = -1
    private var entries_: [ImportedFirmware] = []
    private var details_: [String: FirmwareDetails] = [:]

    /// dir: where the mirror is (nil: RFMShared.firmwareMirror())
    public init(dir: URL? = nil) { dir_ = dir ?? RFMShared.firmwareMirror() }

    /// the mirror's folder (tests and the app's fallback set it)
    public var dir: URL? {
        get { lock.withLock { dir_ } }
        set { lock.withLock { dir_ = newValue; stamp = nil; size = -1 } }
    }

    public static func isKey(_ key: String) -> Bool { key.hasPrefix(keyPrefix) }

    /// the index as it is on disk now (read again only when index.json changed)
    public var entries: [ImportedFirmware] {
        lock.withLock {
            reloadLocked()
            return entries_
        }
    }

    /// the mirrored file of an entry
    public func path(_ sha256: String) -> String? {
        lock.withLock { dir_?.appendingPathComponent("\(sha256).rfm1").path }
    }

    /// an entry's manifest, credits and licence texts (read once per file)
    public func details(_ sha256: String) -> FirmwareDetails {
        if let d = lock.withLock({ details_[sha256] }) { return d }
        guard let p = path(sha256) else { return FirmwareDetails() }
        let d = FirmwareDetails.read(p)
        lock.withLock { details_[sha256] = d }
        return d
    }

    /// forget what was read (after the app rewrote the index)
    public func invalidate() { lock.withLock { stamp = nil; size = -1 } }

    private func reloadLocked() {
        guard let dir = dir_ else {
            entries_ = []
            return
        }
        let url = dir.appendingPathComponent(Self.indexName)
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        let m = a?[.modificationDate] as? Date
        let n = (a?[.size] as? NSNumber)?.intValue ?? -1
        if m == stamp && n == size { return }
        stamp = m
        size = n
        guard let data = try? Data(contentsOf: url), let idx = try? FirmwareIndex.decode(data) else {
            entries_ = []
            return
        }
        entries_ = idx.firmware.filter { $0.error == nil }
    }

    /// the entries as catalog cores
    public func cores() -> [CoreInfo] {
        entries.compactMap { f in
            guard let p = path(f.sha256) else { return nil }
            var c = CoreInfo(id: f.key)
            c.kind = "wasm"
            c.coreID = f.coreID
            c.name = f.name
            c.version = f.version
            c.license = f.license
            c.sha256 = f.sha256
            c.path = p
            c.fileSize = f.fileSize
            c.fileName = f.file
            return c
        }
        .sorted { ($0.name.lowercased(), $0.version, $0.sha256) < ($1.name.lowercased(), $1.version, $1.sha256) }
    }
}

/// index.json
struct FirmwareIndex: Codable {
    var format = 1
    var firmware: [ImportedFirmware] = []

    static func decode(_ d: Data) throws -> FirmwareIndex {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(FirmwareIndex.self, from: d)
    }

    func encode() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
}

/// The app's firmware folder: Documents/Firmware, its mirror and index (see the top of this file). Main actor.
@MainActor
@Observable
public final class FirmwareLibrary {
    public static let fileType = UTType(exportedAs: "com.quixotic7.rfm1", conformingTo: .data)
    public static let readme = """
        Put .rfm1 firmware files here.

        An .rfm1 file is an FM-1 firmware built to run in RemoteFM1 (WebAssembly): its author's release, or one you \
        built with FM1VST's fm1_add_rfm1. RemoteFM1 lists every valid file here in its Firmware page, next to the \
        firmware built into the app, and in the AU instrument. Delete a file here (or in the app) to remove it.
        """

    /// every .rfm1 in the folder, valid or not (name order)
    public private(set) var files: [ImportedFirmware] = []
    public private(set) var lastSync: Date?
    public private(set) var message = ""

    public let folder: URL
    public let mirror: URL
    @ObservationIgnored private let catalog: FirmwareCatalog
    @ObservationIgnored private let log = RFMShared.log("firmware")

    /// folder: nil = Documents/Firmware; mirror: nil = the App Group's Firmware (else Application Support/Firmware)
    public init(folder: URL? = nil, mirror: URL? = nil, catalog: FirmwareCatalog = .shared) {
        let fm = FileManager.default
        self.folder = folder ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Firmware")
        self.mirror = mirror ?? RFMShared.firmwareMirror() ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Firmware")
        self.catalog = catalog
        if catalog.dir != self.mirror { catalog.dir = self.mirror }
    }

    /// the valid files (the catalog's), by key
    public func entry(_ key: String) -> ImportedFirmware? { files.first { $0.key == key && $0.error == nil } }

    /// the folder scanned: each file checked (RFMWasm.h), valid ones mirrored, the index rewritten when it changed
    @discardableResult
    public func sync() -> [ImportedFirmware] {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: mirror, withIntermediateDirectories: true)
        let readmeURL = folder.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readmeURL.path) { try? Data(Self.readme.utf8).write(to: readmeURL, options: .atomic) }

        let old = (try? Data(contentsOf: mirror.appendingPathComponent(FirmwareCatalog.indexName)))
            .flatMap { try? FirmwareIndex.decode($0) }?.firmware ?? []
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".rfm1") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var list: [ImportedFirmware] = [], seen = Set<String>()
        for n in names {
            let path = folder.appendingPathComponent(n).path
            var info = rfmw_info_t()
            var err = [CChar](repeating: 0, count: 512)
            let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
            if rfmw_check(path, &info, &err, 512) != 0 {
                let sha = RemoteController.string(info.sha256)
                guard seen.insert(sha).inserted else { continue }     // (the same file twice: listed once)
                let added = old.first { $0.sha256 == sha }?.added
                    ?? ((try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date) ?? Date()
                list.append(ImportedFirmware(sha256: sha, coreID: RemoteController.string(info.id),
                                             name: RemoteController.string(info.name),
                                             version: RemoteController.string(info.version),
                                             license: RemoteController.string(info.license), fileSize: size,
                                             added: added, file: n))
            } else {
                var sha = [CChar](repeating: 0, count: 65)
                _ = rfmw_sha256(path, &sha)
                let e = String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                list.append(ImportedFirmware(sha256: CorePlayer.string(sha), coreID: "", name: n, version: "",
                                             license: "", fileSize: size, file: n,
                                             error: e.hasPrefix(n + ": ") ? String(e.dropFirst(n.count + 2)) : e))
            }
        }
        // the mirror: each valid file as <sha256>.rfm1, nothing else
        let valid = list.filter { $0.error == nil }
        for f in valid {
            let dst = mirror.appendingPathComponent("\(f.sha256).rfm1")
            if fm.fileExists(atPath: dst.path) { continue }
            let tmp = mirror.appendingPathComponent(".\(f.sha256).tmp")
            try? fm.removeItem(at: tmp)
            do {
                try fm.copyItem(at: folder.appendingPathComponent(f.file), to: tmp)
                try fm.moveItem(at: tmp, to: dst)
            } catch {
                log.error("mirror \(f.file, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        let keep = Set(valid.map { "\($0.sha256).rfm1" })
        for n in (try? fm.contentsOfDirectory(atPath: mirror.path)) ?? [] where n.hasSuffix(".rfm1") && !keep.contains(n) {
            try? fm.removeItem(at: mirror.appendingPathComponent(n))
        }
        if valid != old, let data = try? FirmwareIndex(firmware: valid).encode() {
            try? data.write(to: mirror.appendingPathComponent(FirmwareCatalog.indexName), options: .atomic)
        }
        catalog.invalidate()
        if list != files { files = list }
        lastSync = Date()
        log.info("synced \(list.count) file(s), \(valid.count) valid, into \(self.mirror.path, privacy: .public)")
        return list
    }

    /// a file from elsewhere (Files, the picker, an opened document) copied into the folder, then synced. Returns its
    /// entry (error set when it isn't a valid .rfm1; the file stays in the folder then, as one put there by hand)
    @discardableResult
    public func importFile(_ url: URL) throws -> ImportedFirmware {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let have = files.first(where: { $0.sha256 == sha }), !have.file.isEmpty,
           FileManager.default.fileExists(atPath: folder.appendingPathComponent(have.file).path) {
            message = "\(have.file) is already here"
            return have
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = url.lastPathComponent
        if !name.lowercased().hasSuffix(".rfm1") { name += ".rfm1" }
        let stem = String(name.dropLast(5))
        var dst = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = folder.appendingPathComponent("\(stem) \(n).rfm1")
            n += 1
        }
        if url.standardizedFileURL.deletingLastPathComponent() != folder.standardizedFileURL {
            try data.write(to: dst, options: .atomic)
        }
        sync()
        let got = files.first { $0.sha256 == sha } ?? ImportedFirmware(sha256: sha, coreID: "", name: name, version: "",
                                                                      license: "", fileSize: data.count, file: name,
                                                                      error: "not found after the copy")
        message = got.error.map { "\(got.file): \($0)" } ?? "Added \(got.name) \(got.version)"
        log.info("imported \(url.lastPathComponent, privacy: .public): \(self.message, privacy: .public)")
        return got
    }

    /// the file removed from the folder (and so from the mirror and the index)
    public func delete(_ f: ImportedFirmware) {
        guard !f.file.isEmpty else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(f.file))
        message = "Removed \(f.error == nil ? "\(f.name) \(f.version)" : f.file)"
        sync()
    }
}

extension RFMShared {
    /// the App Group's Firmware folder (the mirror the extension reads), nil without an App Group
    public static func firmwareMirror() -> URL? { groupContainer()?.appendingPathComponent("Firmware") }
}

extension RFMShared {
    /// the App Group's CoreSlots folder (CoreSlotMirror: Mac only), nil without an App Group
    public static func coreSlotsMirror() -> URL? { groupContainer()?.appendingPathComponent("CoreSlots") }
}

/// (Mac only, build 7) the app's core slots copied into the App Group's CoreSlots, beside the firmware mirror: on a Mac
/// ("Designed for iPad") the AU extension's sandbox denies it the app's Frameworks folder, and when its FM1CoreSlots.txt
/// doesn't get it the slots either (rfms_scan), it scans this copy. Never on iOS: loading code from a writable
/// container is forbidden there. The AU sees the copy only once the app has been opened after an install or update.
public enum CoreSlotMirror {
    public static let manifestName = "manifest.txt"

    /// (the app, off the main thread) on a Mac only: the copy brought up to date
    public static func syncOnMac() {
        guard ProcessInfo.processInfo.isiOSAppOnMac, let from = Bundle.main.privateFrameworksURL,
              let to = RFMShared.coreSlotsMirror() else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        sync(from: from, to: to, build: build)
    }

    /// the slots in `from` copied into `to` when the manifest (the build, each slot's name and binary size) changed;
    /// slots no longer in `from` removed. Returns how many were copied
    @discardableResult
    static func sync(from: URL, to: URL, build: String) -> Int {
        let fm = FileManager.default, log = RFMShared.log("slots")
        let names = ((try? fm.contentsOfDirectory(atPath: from.path)) ?? [])
            .filter { $0.hasPrefix("FM1Core_") && $0.hasSuffix(".framework") }.sorted()
        func size(_ name: String) -> Int {
            let bin = from.appendingPathComponent(name).appendingPathComponent(String(name.dropLast(10))).path
            return (try? fm.attributesOfItem(atPath: bin)[.size] as? Int) ?? -1
        }
        let manifest = (["build \(build)"] + names.map { "\($0) \(size($0))" }).joined(separator: "\n") + "\n"
        let mURL = to.appendingPathComponent(manifestName)
        if (try? String(contentsOf: mURL, encoding: .utf8)) == manifest { return 0 }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        try? fm.removeItem(at: mURL)                    // (written last: an interrupted copy is redone)
        for n in (try? fm.contentsOfDirectory(atPath: to.path)) ?? [] where n.hasPrefix("FM1Core_") && !names.contains(n) {
            try? fm.removeItem(at: to.appendingPathComponent(n))
        }
        var copied = 0
        for n in names {
            let tmp = to.appendingPathComponent(".\(n).tmp"), dst = to.appendingPathComponent(n)
            do {
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: from.appendingPathComponent(n), to: tmp)
                try? fm.removeItem(at: dst)
                try fm.moveItem(at: tmp, to: dst)
                copied += 1
            } catch {
                log.error("copy \(n, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return copied
            }
        }
        try? Data(manifest.utf8).write(to: mURL, options: .atomic)
        log.info("copied \(copied) core slot(s) into \(to.path, privacy: .public)")
        return copied
    }
}
