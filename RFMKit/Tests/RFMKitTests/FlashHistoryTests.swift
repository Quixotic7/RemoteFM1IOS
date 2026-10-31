// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// PLAN.md section 18 step 1: FlashFile's safe writes and .prev fallback, FlashHistory's rolling, daily and dedupe
// rules (an injected clock), and CorePlayer's safety copies before a version change, a delete, a reset and a restore
// (the macOS core builds; skipped without them), and the AU's reset.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

/// a clock the test moves
final class TestClock: @unchecked Sendable {
    var t: Date
    init(_ t: Date) { self.t = t }
}

final class FlashHistoryTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rfm-flash-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func bytes(_ v: UInt8, _ n: Int = 64) -> Data { Data(repeating: v, count: n) }

    // MARK: FlashFile

    func testSafeWriteKeepsThePreviousFile() throws {
        let url = tempDir().appendingPathComponent("felucca.bin")
        try FlashFile.write(bytes(1), to: url, firmwareID: "felucca", version: "1.6.1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FlashFile.prevURL(url).path))
        try FlashFile.write(bytes(2), to: url, firmwareID: "felucca", version: "1.6.1")
        XCTAssertEqual(try Data(contentsOf: url), bytes(2))
        XCTAssertEqual(try Data(contentsOf: FlashFile.prevURL(url)), bytes(1))
        XCTAssertEqual(FlashFile.meta(url)?.version, "1.6.1")
        XCTAssertEqual(FlashFile.meta(url)?.sha256, FlashFile.sha256(bytes(2)))
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") }, "the temp file is left: \(names)")
        let r = FlashFile.read(url, expectedSize: 64)
        XCTAssertEqual(r.data, bytes(2))
        XCTAssertFalse(r.fromPrev)
        XCTAssertEqual(r.note, "")
    }

    func testDamagedOrMissingFileFallsBackToPrev() throws {
        let url = tempDir().appendingPathComponent("choralroot.bin")
        XCTAssertNil(FlashFile.read(url, expectedSize: 64).data, "never saved: a fresh flash")
        XCTAssertEqual(FlashFile.read(url, expectedSize: 64).note, "")
        try FlashFile.write(bytes(1), to: url)
        try FlashFile.write(bytes(2), to: url)
        try Data([9, 9, 9]).write(to: url)                     // (a torn write: the wrong size)
        var r = FlashFile.read(url, expectedSize: 64)
        XCTAssertEqual(r.data, bytes(1))
        XCTAssertTrue(r.fromPrev)
        XCTAssertTrue(r.note.contains("damaged"), r.note)
        try FileManager.default.removeItem(at: url)             // (missing)
        r = FlashFile.read(url, expectedSize: 64)
        XCTAssertEqual(r.data, bytes(1))
        XCTAssertTrue(r.note.contains("missing"), r.note)
        try Data([1]).write(to: FlashFile.prevURL(url))          // (both bad: fresh, said so)
        r = FlashFile.read(url, expectedSize: 64)
        XCTAssertNil(r.data)
        XCTAssertFalse(r.note.isEmpty)
        FlashFile.remove(url)
        XCTAssertNil(FlashFile.read(url, expectedSize: 64).data)
        XCTAssertEqual(FlashFile.read(url, expectedSize: 64).note, "")
    }

    // MARK: FlashHistory

    func testRollingCopiesAreDedupedAndLimited() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let h = FlashHistory(root: tempDir(), now: { clock.t })
        XCTAssertNotNil(h.record(bytes(1), firmwareID: "fizz", version: "1", reason: .rolling))
        clock.t += 600
        XCTAssertNil(h.record(bytes(1), firmwareID: "fizz", version: "1", reason: .rolling), "the same as the newest")
        clock.t = Date(timeIntervalSince1970: 1_800_000_060)
        XCTAssertNil(h.record(bytes(2), firmwareID: "fizz", version: "1", reason: .rolling), "too soon after the last")
        clock.t += 300
        XCTAssertNotNil(h.record(bytes(2), firmwareID: "fizz", version: "1", reason: .rolling))
        XCTAssertEqual(h.list("fizz").count, 2)
        // a risky step's copy equal to the newest: that copy relabelled, not kept twice
        let e = h.record(bytes(2), firmwareID: "fizz", version: "1", reason: .beforeReset)
        XCTAssertEqual(e?.reason, "before reset")
        XCTAssertEqual(h.list("fizz").count, 2)
        XCTAssertEqual(h.list("fizz").first?.kind, .event)
        // 15 more distinct saves 5 min apart, the same day: the last 10 rolling, the event kept
        h.rollingInterval = 0
        for i in 0..<15 {
            clock.t += 300
            h.record(bytes(UInt8(10 + i)), firmwareID: "fizz", version: "1", reason: .rolling)
        }
        let l = h.list("fizz")
        XCTAssertEqual(l.filter { $0.kind == .rolling }.count, 10)
        XCTAssertEqual(l.filter { $0.kind == .event }.count, 1)
        XCTAssertEqual(l.first?.sha256, FlashFile.sha256(bytes(24)), "newest first")
        XCTAssertNotNil(h.data(l[0]))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: h.dir("fizz").path)) ?? []
        XCTAssertEqual(files.filter { $0.hasSuffix(".bin") }.count, 11, "pruned copies' files removed")
        XCTAssertTrue(h.list("other").isEmpty)
    }

    func testOneADayForAWeek() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9))!
        let clock = TestClock(start)
        let h = FlashHistory(root: tempDir(), now: { clock.t })
        h.calendar = cal
        h.rollingInterval = 0
        var n: UInt8 = 0
        for _ in 0..<12 {                                       // 12 days, 3 saves a day (9:00, 12:00, 15:00)
            for _ in 0..<3 {
                n += 1
                h.record(bytes(n), firmwareID: "loom", version: "1", reason: .rolling)
                clock.t += 3 * 3600
            }
            clock.t += 15 * 3600
        }
        let l = h.list("loom")
        let rolling = l.filter { $0.kind == .rolling }, daily = l.filter { $0.kind == .daily }
        XCTAssertEqual(rolling.count, 10)
        // the last 10 cover the last 4 days (10 = 3 + 3 + 3 + 1); days 7, 6, 5 back keep their newest as daily
        XCTAssertEqual(daily.count, 3, "\(l.map { ($0.date, $0.kind) })")
        let days = Set(l.map { cal.startOfDay(for: $0.date) })
        XCTAssertEqual(days.count, 7, "one a day for the last 7 days")
        for d in daily {
            XCTAssertEqual(cal.component(.hour, from: d.date), 15, "the day's newest")
            XCTAssertEqual(d.reason, "daily")
        }
    }

    func testEventCopiesArePrunedAfterTheLimit() {
        let clock = TestClock(Date())
        let h = FlashHistory(root: tempDir(), now: { clock.t })
        h.keepEvents = 3
        for i in 0..<5 {
            clock.t += 1
            h.record(bytes(UInt8(i)), firmwareID: "x", version: "1", reason: .beforeDelete("X \(i)"))
        }
        XCTAssertEqual(h.list("x").map(\.reason), ["before deleting X 4", "before deleting X 3", "before deleting X 2"])
        XCTAssertNil(h.record(Data(), firmwareID: "x", version: "1", reason: .beforeReset), "nothing to copy")
    }

    // MARK: the player and the AU

    private func needCores() throws {
        guard FileManager.default.fileExists(atPath: CoreTests.coresDir) else {
            throw XCTSkip("no macOS core builds in \(CoreTests.coresDir): run scripts/build_cores.sh macos")
        }
        _ = rfms_scan(CoreTests.coresDir)
    }

    /// a ChoralRoot image (the fresh one's, a byte changed: another distinct flash)
    private func image(_ mark: UInt8) throws -> Data {
        let c = try TestCore("choralroot")
        c.boot()
        c.run(300)
        var f = c.flash()
        XCTAssertFalse(f.isEmpty)
        f[f.count - 1] = mark
        return Data(f)
    }

    @MainActor func testPlayerCopiesBeforeVersionChangeResetAndRestore() async throws {
        try needCores()
        let dir = tempDir()
        let cores = dir.appendingPathComponent("cores")
        let a = try image(0xA1)
        // a flash written by an older ChoralRoot, its main file then torn: the boot uses .prev and says so
        let url = cores.appendingPathComponent("choralroot.bin")
        try FlashFile.write(a, to: url, firmwareID: "choralroot", version: "0.0.1")
        try FlashFile.write(a, to: url, firmwareID: "choralroot", version: "0.0.1")
        try Data([1, 2, 3]).write(to: url)
        let suite = "rfm-flash-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let p = CorePlayer(link: nil, slotsDir: CoreTests.coresDir, flashDir: cores, selected: "choralroot", midiDefaults: d)
        defer { p.stop() }
        let v = try XCTUnwrap(p.current?.version)
        p.setAudio(false)
        p.setMode(.core)
        XCTAssertTrue(p.status.booted, p.message)
        XCTAssertTrue(p.message.contains("copy saved before it"), p.message)
        var l = p.safetyCopies
        XCTAssertEqual(l.first?.reason, "before update 0.0.1→\(v)")
        XCTAssertEqual(l.first?.sha256, FlashFile.sha256(a))
        XCTAssertEqual(l.first?.version, "0.0.1")
        XCTAssertEqual(FlashFile.meta(url)?.version, v, "the sidecar names this version now")

        // before a delete (the hook FirmwareLibrary's delete and Get firmware's update use)
        let del = p.safetyCopy(of: "choralroot", .beforeDelete("ChoralRoot"))
        XCTAssertEqual(del?.kind, .event)

        // reset: a copy of the current memory, then a fresh flash (its file gone), booted
        await p.saveNow()
        let current = try Data(contentsOf: url)
        let snap = await p.resetFlash()
        XCTAssertEqual(snap?.sha256, FlashFile.sha256(current))
        XCTAssertEqual(p.safetyCopies.first?.reason, "before reset")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FlashFile.prevURL(url).path))
        XCTAssertTrue(p.status.booted)
        XCTAssertTrue(p.message.contains("clean memory"), p.message)

        // restore the copy from before the update: the file is it again, a copy of the fresh memory kept first
        l = p.safetyCopies
        let old = try XCTUnwrap(l.first { $0.reason.hasPrefix("before update") })
        let ok = await p.restore(old)
        XCTAssertTrue(ok, p.message)
        XCTAssertEqual(FlashFile.read(url, expectedSize: a.count).data, a)
        XCTAssertTrue(p.status.booted)
        XCTAssertEqual(p.safetyCopies.first?.reason, "before restore")
        // a copy of another firmware isn't restored here
        var other = old
        other.firmwareID = "felucca"
        let refused = await p.restore(other)
        XCTAssertFalse(refused)
    }

    func testAUResetKeepsACopyAndBootsFresh() throws {
        try needCores()
        var c = RFMAudioUnit.Config()
        c.runProbes = false
        c.link = .none
        c.defaultCore = "choralroot"
        c.slotsDir = CoreTests.coresDir
        let au = try RFMAudioUnit(componentDescription: RFMShared.component, options: [], config: c)
        au.maximumFramesToRender = 512
        au.isRenderingOffline = true
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }
        for _ in 0..<60 { _ = au.renderForTest(frames: 441, midi: []) }
        XCTAssertTrue(au.status().core.booted)
        au.history = FlashHistory(root: tempDir())
        let snap = au.resetFlash()
        XCTAssertNotNil(snap)
        XCTAssertEqual(au.history.list("choralroot").count, 1)
        XCTAssertEqual(au.history.list("choralroot").first?.reason, "before reset")
        XCTAssertEqual(au.status().bootedFrom, "a fresh flash (reset)")
        XCTAssertTrue(au.status().core.booted)
    }
}
