// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// PLAN.md section 18 step 3: the .rfm1state format (round trip, bad files refused in plain words), importing into the
// library (duplicates by hash skipped), the Documents mirror, Back up everything and Restore from backup.

import Foundation
import XCTest
@testable import RFMKit

final class StateFileTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rfm-sf-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func flash(_ v: UInt8, _ n: Int = 4096) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7) ^ v })
    }

    private func save(_ lib: StateLibrary, _ name: String, _ v: UInt8, id: String = "fizz", fw: String = "Fizz") throws -> SavedState {
        try lib.save(name: name, firmwareID: id, firmwareName: fw, kind: "native", version: "1.0", flash: flash(v),
                     master: 512, settings: { var a = AUSettings(); a.transpose = -1; a.keyTouch = true; return a }(), origin: "app")
    }

    // MARK: the format

    func testRoundTrip() throws {
        let lib = StateLibrary(root: tempDir())
        let s = try save(lib, "Pads", 1)
        let d = StateFile.encode(s, flash: flash(1))
        XCTAssertEqual(d.prefix(8), Data("RFM1STAT".utf8))
        XCTAssertLessThan(d.count, 4096)                    // (compressed)
        let back = try StateFile.decode(d)
        XCTAssertEqual(back.state, lib.entry(s))       // (as the library has it: dates through JSON)
        XCTAssertEqual(back.flash, flash(1))
        XCTAssertEqual(back.state.transpose, -1)
        XCTAssertEqual(back.state.master, 512)
    }

    func testBadFilesRefused() throws {
        let s = try save(StateLibrary(root: tempDir()), "Pads", 1)
        let d = StateFile.encode(s, flash: flash(1))
        XCTAssertThrowsError(try StateFile.decode(Data("hello world, not a state".utf8))) {
            XCTAssertEqual($0 as? StateFile.FileError, .notState)
            XCTAssertEqual($0.localizedDescription, "This isn't a RemoteFM1 state file.")
        }
        XCTAssertThrowsError(try StateFile.decode(d.prefix(d.count - 10))) {
            guard case .truncated(let h, let n)? = $0 as? StateFile.FileError else { return XCTFail("\($0)") }
            XCTAssertEqual(h, d.count - 10); XCTAssertEqual(n, d.count)
            XCTAssertTrue($0.localizedDescription.contains("cut short"))
        }
        XCTAssertThrowsError(try StateFile.decode(d.prefix(20))) {
            guard case .truncated? = $0 as? StateFile.FileError else { return XCTFail("\($0)") }
        }
        var bad = d
        bad[bad.count - 3] ^= 0xFF
        XCTAssertThrowsError(try StateFile.decode(bad)) { XCTAssertEqual($0 as? StateFile.FileError, .damaged) }
        var m = d
        m[14] = UInt8(ascii: "#")                           // (inside the manifest's JSON)
        XCTAssertThrowsError(try StateFile.decode(m)) { XCTAssertEqual($0 as? StateFile.FileError, .badManifest) }
    }

    // MARK: import

    func testImportSkipsDuplicates() throws {
        let a = StateLibrary(root: tempDir()), b = StateLibrary(root: tempDir())
        let s = try save(a, "Pads", 1)
        let file = StateFile.encode(s, flash: flash(1))
        let i = try b.importState(StateFile.decode(file))
        XCTAssertFalse(i.duplicate)
        XCTAssertEqual(i.state.id, s.id)                    // (its id kept)
        XCTAssertEqual(try b.flash(i.state), flash(1))
        let again = try b.importState(StateFile.decode(file))
        XCTAssertTrue(again.duplicate)
        XCTAssertEqual(b.list("fizz").count, 1)
        // the same bytes under another name: still a duplicate; another firmware: not
        var other = s; other.id = UUID().uuidString; other.name = "Copy"
        XCTAssertTrue(try b.importState(.init(state: other, flash: flash(1))).duplicate)
        other.firmwareID = "buzz"
        XCTAssertFalse(try b.importState(.init(state: other, flash: flash(1))).duplicate)
        // a taken id gets a new one
        let t = try save(b, "Taken", 9)
        var clash = s; clash.id = t.id
        let c = try b.importState(.init(state: clash, flash: flash(2)))
        XCTAssertNotEqual(c.state.id, t.id)
        XCTAssertEqual(b.allStates().count, 4)
    }

    // MARK: the mirror

    func testMirrorSync() throws {
        let lib = StateLibrary(root: tempDir()), docs = tempDir().appendingPathComponent("States")
        let mirror = StateMirror(root: docs, library: lib)
        let a = try save(lib, "Pads", 1), b = try save(lib, "Pads", 2), c = try save(lib, "Lead/1", 3, id: "amb", fw: "Ambient")
        var r = mirror.sync()
        XCTAssertEqual(r.written, 3)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: docs.appendingPathComponent("README.txt").path))
        let pads = docs.appendingPathComponent("Fizz/Pads.rfm1state"), pads2 = docs.appendingPathComponent("Fizz/Pads 2.rfm1state")
        XCTAssertEqual(try StateFile.read(pads).state.id, a.id)
        XCTAssertEqual(try StateFile.read(pads2).state.id, b.id)
        XCTAssertEqual(try StateFile.read(docs.appendingPathComponent("Ambient/Lead-1.rfm1state")).flash, flash(3))
        r = mirror.sync()
        XCTAssertEqual(r, StateMirror.Report())             // (nothing to do)

        // a rename moves the file; a delete removes it; the folder left empty goes
        try lib.rename(b, to: "Strings")
        lib.delete(c)
        r = mirror.sync()
        XCTAssertEqual(r.moved, 1); XCTAssertEqual(r.removed, 1)
        XCTAssertEqual(try StateFile.read(docs.appendingPathComponent("Fizz/Strings.rfm1state")).state.name, "Strings")
        XCTAssertFalse(fm.fileExists(atPath: pads2.path))
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("Ambient").path))

        // a file removed in Files comes back (the library wins)
        try fm.removeItem(at: pads)
        XCTAssertEqual(mirror.sync().written, 1)
        XCTAssertTrue(fm.fileExists(atPath: pads.path))

        // a file the user drops in: imported; a duplicate dropped: left, skipped
        let other = StateLibrary(root: tempDir())
        let n = try save(other, "From a friend", 7, id: "amb", fw: "Ambient")
        try fm.createDirectory(at: docs.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        try StateFile.encode(n, flash: flash(7)).write(to: docs.appendingPathComponent("Inbox/friend.rfm1state"))
        try StateFile.encode(a, flash: flash(1)).write(to: docs.appendingPathComponent("dup.rfm1state"))
        try Data("junk".utf8).write(to: docs.appendingPathComponent("junk.rfm1state"))
        r = mirror.sync()
        XCTAssertEqual(r.imported, 1)
        XCTAssertEqual(r.duplicates, 0)                     // (dup.rfm1state has a's id: a's own file, at another path)
        XCTAssertEqual(r.failed.count, 1)
        XCTAssertTrue(r.failed[0].contains("isn't a RemoteFM1 state"))
        XCTAssertEqual(lib.list("amb").map(\.name), ["From a friend"])
        XCTAssertTrue(fm.fileExists(atPath: docs.appendingPathComponent("Ambient/From a friend.rfm1state").path))
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("Inbox/friend.rfm1state").path))   // (moved in place)
    }

    // MARK: backups

    func testBackupAndRestore() throws {
        let lib = StateLibrary(root: tempDir()), hist = FlashHistory(root: tempDir())
        hist.rollingInterval = 0
        _ = try save(lib, "Pads", 1)
        _ = try save(lib, "Bass", 2)
        _ = try save(lib, "Lead", 3, id: "amb", fw: "Ambient")
        for v in UInt8(10)...14 { hist.record(flash(v), firmwareID: "fizz", version: "1.0", reason: .other("copy \(v)")) }
        let cur = [Backup.Current(firmwareID: "fizz", firmwareName: "Fizz", kind: "native", version: "1.0", flash: flash(20)),
                   Backup.Current(firmwareID: "fizz", firmwareName: "Fizz", kind: "wasm", version: "1.0", flash: flash(20)),
                   Backup.Current(firmwareID: "amb", firmwareName: "Ambient", kind: "native", version: "2.0", flash: flash(21))]
        let root = tempDir()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let (dir, m) = try Backup.write(into: root, library: lib, history: hist, current: cur, app: "test", date: date)
        XCTAssertTrue(dir.lastPathComponent.hasPrefix("RemoteFM1 backup "))
        XCTAssertEqual(m.states.count, 3)
        XCTAssertEqual(m.current.map(\.name), ["Fizz current", "Ambient current"])   // (the same flash once)
        XCTAssertEqual(m.safetyCopies.count, 3)                                       // (the newest 3)
        let fm = FileManager.default
        for i in m.states + m.current + m.safetyCopies {
            XCTAssertEqual(FlashFile.sha256(try StateFile.read(dir.appendingPathComponent(i.file)).flash), i.flashSHA256)
        }
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("States/Fizz/Pads.rfm1state").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Current/Fizz current.rfm1state").path))
        let mj = try FlashFile.decoder.decode(Backup.Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(mj, m)
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("README.txt").path))
        let (dir2, _) = try Backup.write(into: root, library: lib, history: hist, current: [], date: date)
        XCTAssertEqual(dir2.lastPathComponent, dir.lastPathComponent + " 2")

        // into an empty library: states and current, not the safety copies; again: all skipped
        let fresh = StateLibrary(root: tempDir())
        var r = Backup.restore(from: dir, into: fresh)
        XCTAssertEqual(r.imported.count, 5)
        XCTAssertEqual(r.failed, [])
        XCTAssertEqual(Set(fresh.list("fizz").map(\.name)), ["Pads", "Bass", "Fizz current"])
        r = Backup.restore(from: dir, into: fresh)
        XCTAssertEqual(r.imported.count, 0); XCTAssertEqual(r.duplicates, 5)
        XCTAssertEqual(r.text, "No new states (5 already in the library).")
        // into the library it came from: only the current flashes are new
        XCTAssertEqual(Backup.restore(from: dir, into: lib).imported.count, 2)
        // a broken file in it: said, the others still imported
        try Data("RFM1STAT".utf8).write(to: dir.appendingPathComponent("States/Fizz/broken.rfm1state"))
        r = Backup.restore(from: dir, into: StateLibrary(root: tempDir()))
        XCTAssertEqual(r.imported.count, 5)
        XCTAssertEqual(r.failed.count, 1)
        XCTAssertTrue(r.failed[0].hasPrefix("broken.rfm1state: "))
    }
}
