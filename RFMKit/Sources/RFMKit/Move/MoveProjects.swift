// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The Ableton Move sequencer's 32 projects (RemoteFM1's host/src/move/README.md, "Projects"), one file a slot in
// Documents/move (On My iPhone › RemoteFM1 › move): move-project-01.rfmmove .. -32, each in the web player's file
// format (js/move-projects.js, "THE FILE"), so a file goes between the app and the website as it is:
//   "RMVP" | u8 version 1 | u8 kind (1 one project, 2 a set) | u16 count | per entry: u8 slot, u8 flags 0,
//   u32 saved (Unix s), u32 len, len bytes (the core's blob, checked with rfmm_project_check)   (little-endian)

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
    static let magic: [UInt8] = [0x52, 0x4D, 0x56, 0x50], version: UInt8 = 1, head = 8, entry = 10
    public static var blobMax: Int { Int(rfmm_project_max()) }
    public static var maxFile: Int { head + slots * (entry + blobMax) }

    public static func name(_ slot: Int) -> String { String(format: "move-project-%02d.%@", slot + 1, extOne) }
    public static func displayName(_ slot: Int) -> String { "Project \(slot + 1)" }

    public static func pack(_ projects: [MoveProject]) -> [UInt8] {
        var out = magic + [version, projects.count == 1 ? 1 : 2]
        out += le16(projects.count)
        for p in projects {
            out += [UInt8(p.slot), 0] + le32(max(0, Int(p.saved.timeIntervalSince1970))) + le32(p.bytes.count) + p.bytes
        }
        return out
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notAFile(String)
        public var description: String { if case .notAFile(let why) = self { "Not a Move project file: \(why)." } else { "" } }
    }

    /// the file's projects, each checked by the core; throws what's wrong
    public static func unpack(_ b: [UInt8]) throws -> [MoveProject] {
        func bad(_ why: String) -> Problem { .notAFile(why) }
        guard b.count <= maxFile else { throw bad("it is \(b.count) bytes, more than a full set") }
        guard b.count >= head, Array(b[0..<4]) == magic else { throw bad("it does not start with RMVP") }
        guard b[4] == version else { throw bad("version \(b[4]); this app reads version \(version)") }
        let kind = b[5], count = Int(b[6]) | Int(b[7]) << 8
        guard kind == 1 || kind == 2 else { throw bad("kind \(kind)") }
        guard count >= 1, count <= slots, kind == 2 || count == 1 else { throw bad("\(count) projects") }
        var out: [MoveProject] = [], seen = Set<Int>(), o = head
        for i in 0..<count {
            guard o + entry <= b.count else { throw bad("project \(i + 1) is cut off") }
            let slot = Int(b[o]), t = u32(b, o + 2), len = u32(b, o + 6)
            guard slot < slots, !seen.contains(slot) else { throw bad("slot \(slot + 1) \(seen.contains(slot) ? "twice" : "out of range")") }
            guard len >= 1, len <= blobMax else { throw bad("project \(i + 1) is \(len) bytes") }
            guard o + entry + len <= b.count else { throw bad("project \(i + 1) is cut off") }
            let blob = Array(b[(o + entry)..<(o + entry + len)])
            guard check(blob) else { throw bad("project \(i + 1) (slot \(slot + 1)) is damaged") }
            seen.insert(slot)
            out.append(MoveProject(slot: slot, bytes: blob, saved: t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : Date()))
            o += entry + len
        }
        guard o == b.count else { throw bad("\(b.count - o) bytes after the last project") }
        return out
    }

    public static func check(_ blob: [UInt8]) -> Bool { blob.withUnsafeBufferPointer { rfmm_project_check($0.baseAddress, UInt32($0.count)) == 0 } }

    /// the blob with its colour (byte 18) set and its check made again
    public static func withColor(_ blob: [UInt8], _ color: Int) -> [UInt8] {
        var b = blob
        b.withUnsafeMutableBufferPointer { rfmm_project_with_color($0.baseAddress, UInt32($0.count), Int32(color)) }
        return b
    }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255)] }
    static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> ($0 * 8) & 255) } }
    static func u32(_ b: [UInt8], _ o: Int) -> Int { (0..<4).reduce(0) { $0 | Int(b[o + $1]) << ($1 * 8) } }
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
