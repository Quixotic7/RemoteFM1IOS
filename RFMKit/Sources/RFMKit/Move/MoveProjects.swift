// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The Ableton Move sequencer's 32 projects (RemoteFM1's host/src/move/README.md, "Projects"), one file a slot in
// Documents/move (On My iPhone › RemoteFM1 › move): move-project-01.rfmmove .. -32, each in the web player's file
// format, written and read by rfm1cs-abletonmove (store.h, "The project file") as the website and Android do, so a
// file goes between them as it is.

import Foundation
import RFMCore

public struct MoveProject: Equatable, Sendable {
    public var slot: Int
    public var bytes: [UInt8]
    public var saved: Date
}

public enum MoveProjectFile {
    public static let slots = 32
    public static let extOne = "rfmmove", extSet = "rfmmoveset"
    public static var blobMax: Int { Int(rfmm_project_max()) }
    public static var maxFile: Int { Int(rfmm_file_max()) }

    public static func name(_ slot: Int) -> String { String(format: "move-project-%02d.%@", slot + 1, extOne) }
    public static func displayName(_ slot: Int) -> String { "Project \(slot + 1)" }

    /// the file (rfm1cs-abletonmove writes it: one project, or a set)
    public static func pack(_ projects: [MoveProject]) -> [UInt8] {
        guard projects.count <= slots else { return [] }
        let size = 8 + projects.reduce(0) { $0 + 10 + $1.bytes.count }
        var out = [UInt8](repeating: 0, count: size)
        func entries(_ i: Int, _ e: [rfmm_file_entry_t]) -> UInt32 {
            guard i < projects.count else {
                return out.withUnsafeMutableBufferPointer { o in rfmm_file_pack(e, Int32(e.count), o.baseAddress, UInt32(size)) }
            }
            let p = projects[i]
            return p.bytes.withUnsafeBufferPointer { b in
                entries(i + 1, e + [rfmm_file_entry_t(slot: Int32(p.slot), saved: UInt32(clamping: max(0, Int(p.saved.timeIntervalSince1970))),
                                                      bytes: b.baseAddress, len: UInt32(b.count))])
            }
        }
        let n = Int(entries(0, []))             // (first: out is read after it's written)
        return Array(out.prefix(n))
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notAFile(String)               // the whole sentence, as the web says it
        public var description: String { if case .notAFile(let text) = self { text } else { "" } }
    }

    /// the file's projects, each checked by the core; throws what's wrong
    public static func unpack(_ b: [UInt8]) throws -> [MoveProject] {
        var e = [rfmm_file_entry_t](repeating: rfmm_file_entry_t(), count: slots)
        var err = [CChar](repeating: 0, count: 256)
        return try b.withUnsafeBufferPointer { f in
            let n = Int(rfmm_file_unpack(f.baseAddress, UInt32(f.count), &e, &err, UInt32(err.count)))
            guard n > 0 else { throw Problem.notAFile(String(cString: err)) }
            return e.prefix(n).map { x in
                MoveProject(slot: Int(x.slot), bytes: Array(UnsafeBufferPointer(start: x.bytes, count: Int(x.len))),
                            saved: x.saved > 0 ? Date(timeIntervalSince1970: TimeInterval(x.saved)) : Date())
            }
        }
    }

    public static func check(_ blob: [UInt8]) -> Bool { blob.withUnsafeBufferPointer { rfmm_project_check($0.baseAddress, UInt32($0.count)) == 0 } }

    /// the blob with its colour (byte 18) set and its check made again
    public static func withColor(_ blob: [UInt8], _ color: Int) -> [UInt8] {
        var b = blob
        b.withUnsafeMutableBufferPointer { rfmm_project_with_color($0.baseAddress, UInt32($0.count), Int32(color)) }
        return b
    }
}

/// the folder of slots (any thread: the controller uses it from the main actor)
public struct MoveProjectStore: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    /// Documents/move
    public static var app: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("move")
    }

    func url(_ slot: Int) -> URL { folder.appendingPathComponent(MoveProjectFile.name(slot)) }

    public func read(_ slot: Int) -> MoveProject? {
        guard (0..<MoveProjectFile.slots).contains(slot), let d = try? Data(contentsOf: url(slot)),
              let p = try? MoveProjectFile.unpack([UInt8](d)).first else { return nil }
        return MoveProject(slot: slot, bytes: p.bytes, saved: p.saved)
    }

    public func write(_ slot: Int, _ blob: [UInt8]) throws {
        guard (0..<MoveProjectFile.slots).contains(slot) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = MoveProjectFile.pack([MoveProject(slot: slot, bytes: blob, saved: Date())])
        try Data(file).write(to: url(slot), options: .atomic)
    }

    public func delete(_ slot: Int) { try? FileManager.default.removeItem(at: url(slot)) }

    public func all() -> [MoveProject] { (0..<MoveProjectFile.slots).compactMap(read) }

    public static func dirBits(_ projects: [MoveProject]) -> UInt32 {
        projects.reduce(0) { $0 | (1 << UInt32($1.slot)) }
    }
}
