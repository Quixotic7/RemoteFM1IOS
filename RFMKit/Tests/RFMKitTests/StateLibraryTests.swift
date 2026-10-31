// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// PLAN.md section 18 step 2: the shared state library (CRUD, two writers on one folder), the history's one file per
// copy (concurrent writers, step 1's index and root moved in), and the app↔AU round trip with the macOS core
// builds (skipped without them): a state saved by an RFMAudioUnit loads in a CorePlayer and the reverse, a load
// keeping a safety copy first.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class StateLibraryTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rfm-states-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func bytes(_ v: UInt8, _ n: Int = 4096) -> Data { Data(repeating: v, count: n) }

    // MARK: the library

    func testSaveListLoadRenameDelete() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let lib = StateLibrary(root: tempDir(), now: { clock.t })
        var s = MainSettings.with(transpose: 1, keyTouch: false)
        let a = try lib.save(name: "  Pads  ", firmwareID: "fizz", firmwareName: "Fizz", kind: "native", version: "1.0",
                             flash: bytes(1), master: 700, settings: s, origin: "app")
        XCTAssertEqual(a.name, "Pads", "trimmed")
        clock.t += 60
        let b = try lib.save(name: "", firmwareID: "fizz", firmwareName: "Fizz", kind: "native", version: "1.1",
                             flash: bytes(2), origin: "au")
        XCTAssertTrue(b.name.hasPrefix("Fizz "), "the default name: \(b.name)")
        XCTAssertEqual(lib.list("fizz").map(\.id), [b.id, a.id], "newest first")
        XCTAssertTrue(lib.list("other").isEmpty)
        XCTAssertEqual(try lib.flash(a), bytes(1))
        let z = try Data(contentsOf: lib.dir("fizz").appendingPathComponent("\(a.id).flash"))
        XCTAssertLessThan(z.count, 4096, "LZFSE")
        XCTAssertEqual(a.master, 700)
        s = AUSettings()
        a.apply(to: &s)
        XCTAssertEqual(s.transpose, 1)
        XCTAssertFalse(s.keyTouch)
        XCTAssertEqual(a.versionNote(running: "1.1"), "made with 1.0")
        XCTAssertEqual(a.versionNote(running: "1.0"), "")

        let r = try lib.rename(a, to: "Pads, bridge", note: "for Friday")
        XCTAssertEqual(lib.list("fizz").first { $0.id == a.id }?.name, "Pads, bridge")
        XCTAssertEqual(r.note, "for Friday")
        lib.delete(b)
        XCTAssertEqual(lib.list("fizz").map(\.id), [a.id])
        XCTAssertThrowsError(try lib.flash(b))
        XCTAssertThrowsError(try lib.rename(b, to: "x"))
        XCTAssertThrowsError(try lib.save(name: "e", firmwareID: "fizz", firmwareName: "", kind: "native", version: "",
                                          flash: Data(), origin: "app"))
        // a damaged flash file: refused, said so
        try Data([1, 2, 3]).write(to: lib.dir("fizz").appendingPathComponent("\(a.id).flash"))
        XCTAssertThrowsError(try lib.flash(a))
    }

    func testTwoLibrariesOnOneFolderNeverLoseAChange() throws {
        let root = tempDir()
        let l1 = StateLibrary(root: root), l2 = StateLibrary(root: root)
        let n = 40
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let l = i % 2 == 0 ? l1 : l2
            _ = try? l.save(name: "s\(i)", firmwareID: "loom", firmwareName: "Loom", kind: "native", version: "1",
                            flash: bytes(UInt8(i), 2048), origin: "app")
        }
        let all = l1.list("loom")
        XCTAssertEqual(all.count, n)
        XCTAssertEqual(Set(l2.list("loom").map(\.id)), Set(all.map(\.id)))
        // renames by one, deletes by the other, at once: each lands
        DispatchQueue.concurrentPerform(iterations: n) { i in
            if i % 2 == 0 { _ = try? l1.rename(all[i], to: "renamed \(i)") } else { l2.delete(all[i]) }
        }
        let left = l2.list("loom")
        XCTAssertEqual(left.count, n / 2)
        XCTAssertTrue(left.allSatisfy { $0.name.hasPrefix("renamed") })
        for s in left { XCTAssertNoThrow(try l2.flash(s)) }
        let files = try FileManager.default.contentsOfDirectory(atPath: l1.dir("loom").path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".tmp") }, "\(files)")
    }

    func testChangesAreNotified() {
        let lib = StateLibrary(root: tempDir())
        let e = expectation(forNotification: StateLibrary.didChange, object: nil)
        e.assertForOverFulfill = false
        _ = try? lib.save(name: "x", firmwareID: "fizz", firmwareName: "Fizz", kind: "native", version: "1",
                          flash: bytes(3), origin: "app")
        wait(for: [e], timeout: 2)
    }

    // MARK: the history, shared

    func testHistoryConcurrentWritersKeepEveryCopy() {
        let root = tempDir()
        let h1 = FlashHistory(root: root), h2 = FlashHistory(root: root)
        h1.keepEvents = 100
        h2.keepEvents = 100
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            (i % 2 == 0 ? h1 : h2).record(bytes(UInt8(i), 256), firmwareID: "fizz", version: "1", reason: .beforeReset)
        }
        let l = h1.list("fizz")
        XCTAssertEqual(l.count, 40)
        XCTAssertEqual(Set(h2.list("fizz").map(\.id)), Set(l.map(\.id)))
        for s in l { XCTAssertNotNil(h2.data(s)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: h1.dir("fizz").appendingPathComponent("index.json").path))
    }

    func testStepOneHistoryMovesIntoTheGroup() throws {
        let old = tempDir().appendingPathComponent("FlashHistory"), group = tempDir().appendingPathComponent("FlashHistory")
        // step 1's layout: <id>/index.json + <uuid>.bin
        let dir = old.appendingPathComponent("felucca")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = bytes(9, 128)
        let s = FlashHistory.Snapshot(id: UUID().uuidString, kind: .event, reason: "before reset", firmwareID: "felucca",
                                      version: "1.6.1", date: Date(timeIntervalSince1970: 1_800_000_000), size: d.count,
                                      sha256: FlashFile.sha256(d))
        try d.write(to: dir.appendingPathComponent("\(s.id).bin"))
        try FlashFile.encoder.encode([s]).write(to: dir.appendingPathComponent("index.json"))
        // the group already has a copy of its own (an AU's)
        let g = FlashHistory(root: group)
        g.record(bytes(7, 128), firmwareID: "felucca", version: "1.6.2", reason: .beforeReset)

        FlashHistory.migrate(from: old, to: group)
        FlashHistory.migrate(from: old, to: group)                  // (twice: nothing more)
        let l = g.list("felucca")
        XCTAssertEqual(l.count, 2)
        XCTAssertEqual(l.first { $0.id == s.id }, s)
        XCTAssertEqual(g.data(s), d)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "the old root removed")
        // an index left in place (an old build wrote it into the group): split when read
        let dir2 = group.appendingPathComponent("loom")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        var s2 = s
        s2.firmwareID = "loom"
        try d.write(to: dir2.appendingPathComponent("\(s2.id).bin"))
        try FlashFile.encoder.encode([s2]).write(to: dir2.appendingPathComponent("index.json"))
        XCTAssertEqual(g.list("loom"), [s2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir2.appendingPathComponent("index.json").path))
    }

    // MARK: the app and the AU

    private func needCores() throws {
        guard FileManager.default.fileExists(atPath: CoreTests.coresDir) else {
            throw XCTSkip("no macOS core builds in \(CoreTests.coresDir): run scripts/build_cores.sh macos")
        }
        _ = rfms_scan(CoreTests.coresDir)
    }

    private func makeAU(_ root: URL) throws -> RFMAudioUnit {
        var c = RFMAudioUnit.Config()
        c.runProbes = false
        c.link = .none
        c.defaultCore = "choralroot"
        c.slotsDir = CoreTests.coresDir
        let au = try RFMAudioUnit(componentDescription: RFMShared.component, options: [], config: c)
        au.maximumFramesToRender = 512
        au.isRenderingOffline = true
        au.history = FlashHistory(root: root.appendingPathComponent("FlashHistory"))
        au.library = StateLibrary(root: root.appendingPathComponent("States"))
        try au.allocateRenderResources()
        for _ in 0..<60 { _ = au.renderForTest(frames: 441, midi: []) }
        return au
    }

    /// the core's flash as the AU's fullState has it now
    private func auFlash(_ au: RFMAudioUnit) -> Data? { CoreState(au.fullState)?.flash }

    @MainActor func testStateRoundTripsBetweenTheAUAndTheApp() async throws {
        try needCores()
        let root = tempDir()
        let au = try makeAU(root)
        defer { au.deallocateRenderResources() }
        XCTAssertTrue(au.status().core.booted)
        var st = au.settings
        st.transpose = -1
        au.settings = st
        let fromAU = try au.saveState(name: "From the AU")
        XCTAssertEqual(fromAU.origin, "au")
        XCTAssertEqual(fromAU.firmwareID, "choralroot")
        XCTAssertEqual(fromAU.transpose, -1)
        let auBytes = try au.library.flash(fromAU)

        let suite = "rfm-states-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let p = CorePlayer(link: nil, slotsDir: CoreTests.coresDir, flashDir: root.appendingPathComponent("cores"),
                           selected: "choralroot", midiDefaults: d, history: au.history, library: au.library)
        defer { p.stop() }
        p.setAudio(false)
        p.setMode(.core)
        XCTAssertTrue(p.status.booted, p.message)
        XCTAssertEqual(p.states.map(\.id), [fromAU.id], "the same library")
        await p.saveNow()
        let before = try Data(contentsOf: p.flashURL("choralroot"))

        // the AU's state loads in the app: a safety copy of the app's memory first
        let ok = await p.loadState(fromAU)
        XCTAssertTrue(ok, p.message)
        XCTAssertTrue(p.status.booted)
        XCTAssertEqual(FlashFile.read(p.flashURL("choralroot"), expectedSize: auBytes.count).data, auBytes)
        XCTAssertEqual(p.midiSettings.transpose, -1, "the kept settings")
        let copy = try XCTUnwrap(p.safetyCopies.first)
        XCTAssertEqual(copy.reason, "before load state")
        XCTAssertEqual(copy.sha256, FlashFile.sha256(before))

        // the reverse: a state saved in the app loads in the AU, which keeps a copy of its memory first
        let fromApp = await p.saveState(name: "From the app")
        let a = try XCTUnwrap(fromApp, p.message)
        XCTAssertEqual(a.origin, "app")
        XCTAssertEqual(try au.library.flash(a).count, auBytes.count)
        let auBefore = try XCTUnwrap(auFlash(au))
        try au.loadState(a)
        for _ in 0..<30 { _ = au.renderForTest(frames: 441, midi: []) }
        XCTAssertTrue(au.status().core.booted)
        XCTAssertEqual(au.status().bootedFrom, "the state \"From the app\"")
        let auCopy = try XCTUnwrap(au.history.list("choralroot").first)
        XCTAssertEqual(auCopy.reason, "before load state")
        XCTAssertEqual(auCopy.sha256, FlashFile.sha256(auBefore))
        // the AU's restore of that copy
        try au.restore(auCopy)
        XCTAssertEqual(au.status().bootedFrom, "a safety copy")

        // another firmware's state isn't loaded
        var other = a
        other.firmwareID = "felucca"
        let refused = await p.loadState(other)
        XCTAssertFalse(refused)
        XCTAssertThrowsError(try au.loadState(other))
    }
}

private enum MainSettings {
    static func with(transpose: Int, keyTouch: Bool) -> AUSettings {
        var s = AUSettings()
        s.transpose = transpose
        s.keyTouch = keyTouch
        return s
    }
}
