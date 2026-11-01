// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The RemoteFM1 folder a Fantasy CFW reads (FM1VST docs/VIRTUAL-CARTS.md section 3): audio/ (shared samples), code/<id>/
// (a firmware's scripts: ripple's droplets), data/<id>/ (the only place a firmware writes).
//
// Step 1 (the owner, 2026-11-01; the File Provider is step 2):
//   the app       Documents/RemoteFM1, which the Files app shows (On My iPhone › RemoteFM1 › RemoteFM1); the app's
//                 firmwares read and write it directly
//   the AU        can't read the app's Documents: it uses RemoteFM1/ in the App Group, which the app keeps as a copy of
//                 audio/ and code/ (new and changed files copied, removed ones removed; APFS clones, so the copy takes
//                 no extra space). The AU's data/ stays its own until the File Provider shares one folder
// The app copies at launch and each time it comes back to the front, and tells running firmwares the folder changed
// (fs_changed) then.

import Foundation
import RFMCore

public enum RemoteFM1Folder {
    public static let areas = ["audio", "code", "data"]

    /// the app's: Documents/RemoteFM1
    public static var app: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RemoteFM1")
    }
    /// the AU's: the App Group's RemoteFM1 (nil: no App Group)
    public static var group: URL? { RFMShared.groupContainer()?.appendingPathComponent("RemoteFM1") }

    public static let readme = """
        The RemoteFM1 folder

        Fantasy CFW firmwares (they run only in RemoteFM1, never on an FM-1) read their files here:

          audio/        samples every firmware can read (WAV, AIFF; folders allowed)
          code/<id>/    a firmware's own scripts, for example code/ripple/droplets/*.lua for fm1-ripple
          data/<id>/    what a firmware saves; the only place it writes

        Copy files in with the Files app or AirDrop. A firmware sees new files when you come back to RemoteFM1.
        Nothing here is part of a saved state: a state keeps the firmware's memory only.

        """

    /// the folder made (its areas, the README), and set as the one every Fantasy CFW in this process uses
    public static func use(_ root: URL) {
        let fm = FileManager.default
        for a in areas { try? fm.createDirectory(at: root.appendingPathComponent(a), withIntermediateDirectories: true) }
        let r = root.appendingPathComponent("README.txt")
        if (try? String(contentsOf: r, encoding: .utf8)) != readme { try? readme.write(to: r, atomically: true, encoding: .utf8) }
        rfmw_set_folder(root.path)
    }

    /// a firmware's own folders (code/<id>, data/<id>), so the user sees where its files go
    public static func prepare(_ firmwareID: String, in root: URL = app) {
        guard !firmwareID.isEmpty, !firmwareID.contains("/"), !firmwareID.hasPrefix(".") else { return }
        for a in ["code", "data"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("\(a)/\(firmwareID)"),
                                                     withIntermediateDirectories: true)
        }
    }

    /// the files a firmware has in code/<id> (not counting folders or hidden files)
    public static func codeFiles(_ firmwareID: String, in root: URL = app) -> Int {
        let d = root.appendingPathComponent("code/\(firmwareID)")
        guard let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
        return n
    }

    /// running firmwares told the folder changed (they rescan)
    public static func changed() { rfmw_folder_changed() }

    public struct CopyReport: Equatable, Sendable {
        public var copied = 0, removed = 0
        public var changed: Bool { copied + removed > 0 }
    }

    /// `from`'s audio/ and code/ copied into `to`'s: new and changed files (size or date) copied, files gone from
    /// `from` removed; data/ left alone. Off the main thread
    @discardableResult
    public static func copy(from: URL, to: URL) -> CopyReport {
        let fm = FileManager.default
        var r = CopyReport()
        for a in ["audio", "code"] {
            let src = from.appendingPathComponent(a), dst = to.appendingPathComponent(a)
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let have = files(src), there = files(dst)
            for (rel, s) in have {
                if let d = there[rel], d.size == s.size, abs(d.date.timeIntervalSince(s.date)) < 1 { continue }
                let to = dst.appendingPathComponent(rel)
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: to)
                if (try? fm.copyItem(at: src.appendingPathComponent(rel), to: to)) != nil {
                    try? fm.setAttributes([.modificationDate: s.date], ofItemAtPath: to.path)
                    r.copied += 1
                }
            }
            for rel in there.keys where have[rel] == nil {
                if (try? fm.removeItem(at: dst.appendingPathComponent(rel))) != nil { r.removed += 1 }
            }
            removeEmptyFolders(dst)
        }
        return r
    }

    /// regular files under dir, by path relative to it: size and modification date (hidden files left out)
    static func files(_ dir: URL) -> [String: (size: Int, date: Date)] {
        var out: [String: (Int, Date)] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [:] }
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            guard p.hasPrefix(base + "/") else { continue }
            out[String(p.dropFirst(base.count + 1))] = (v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        return out
    }

    private static func removeEmptyFolders(_ dir: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var dirs: [URL] = []
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { dirs.append(u) }
        for d in dirs.sorted(by: { $0.path.count > $1.path.count }) where (try? fm.contentsOfDirectory(atPath: d.path))?.isEmpty == true {
            try? fm.removeItem(at: d)
        }
    }
}
