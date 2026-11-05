// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The battery (BackgroundPolicy): when the app stops the firmware in the background, how quiet time is measured, and
// that a slower screen (rfme_set_frame_ms) really draws less.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class BatteryTests: XCTestCase {
    func testPolicyDecides() {
        var p = BackgroundPolicy(mode: .always, idleStop: true)
        XCTAssertNil(p.stop(fm1Linked: false, idleFor: 60))
        XCTAssertNotNil(p.stop(fm1Linked: true, idleFor: 601), "10 quiet minutes stop it in any mode")
        p.idleStop = false
        XCTAssertNil(p.stop(fm1Linked: false, idleFor: 9999), "keep playing, no idle stop: never")
        p.mode = .withFM1
        XCTAssertEqual(p.stop(fm1Linked: false, idleFor: 0), "no FM-1 connected")
        XCTAssertNil(p.stop(fm1Linked: true, idleFor: 0))
        p.mode = .never
        XCTAssertNotNil(p.stop(fm1Linked: true, idleFor: 0))
    }

    func testPolicyIsSaved() throws {
        let suite = "battery-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(BackgroundPolicy(defaults: d), BackgroundPolicy(mode: .always, idleStop: true), "the defaults")
        BackgroundPolicy(mode: .withFM1, idleStop: false).save(d)
        XCTAssertEqual(BackgroundPolicy(defaults: d), BackgroundPolicy(mode: .withFM1, idleStop: false))
    }

    func testIdleWatch() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var w = IdleWatch(now: t0)
        var a = CorePlayer.Activity(devMs: 0, lastSoundMs: 0, inputs: 5)
        w.feed(a, now: t0)
        w.feed(a, now: t0.addingTimeInterval(300))
        XCTAssertEqual(w.idleFor(now: t0.addingTimeInterval(300)), 300, "nothing new: quiet goes on")
        a.inputs = 6                                       // (a key)
        w.feed(a, now: t0.addingTimeInterval(400))
        XCTAssertEqual(w.idleFor(now: t0.addingTimeInterval(450)), 50)
        a.lastSoundMs = 9000                               // (it played a sound)
        w.feed(a, now: t0.addingTimeInterval(500))
        XCTAssertEqual(w.idleFor(now: t0.addingTimeInterval(500)), 0)
    }

    /// a real firmware draws its screen far less often at 250 ms than at 15 ms (the device clock the same)
    func testSlowerScreenDrawsLess() throws {
        let dir = CoreTests.coresDir
        guard FileManager.default.fileExists(atPath: dir) else { throw XCTSkip("no macOS core builds in \(dir)") }
        rfms_scan(dir)
        func writes(_ ms: UInt32) throws -> UInt32 {
            let c = try TestCore("fizz")
            rfme_set_frame_ms(c.e, ms)
            c.boot()
            c.run(500)
            let before = c.status.lcd_writes
            c.run(3000)
            return c.status.lcd_writes - before
        }
        let fast = try writes(15), slow = try writes(250)
        print("fizz LCD writes in 3 s: \(fast) at 15 ms, \(slow) at 250 ms")
        XCTAssertGreaterThan(fast, 0)
        XCTAssertLessThan(slow * 3, fast, "a slower screen should draw much less (FIZZ writes only what changed)")
    }

    // MARK: stopped in the background, then back (Battery.swift)

    @MainActor private func player() throws -> (CorePlayer, () -> Void) {
        guard FileManager.default.fileExists(atPath: CoreTests.coresDir) else { throw XCTSkip("no built cores") }
        let suite = "rfm-battery-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        let flash = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let p = CorePlayer(link: nil, slotsDir: CoreTests.coresDir, flashDir: flash, selected: "fizz", midiDefaults: d)
        p.setAudio(false)
        p.setMode(.core)
        return (p, { p.stop(); d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: flash) })
    }

    @MainActor private func devMsAdvances(_ p: CorePlayer) async -> Bool {
        let a = p.activity.devMs
        try? await Task.sleep(for: .milliseconds(300))
        return p.activity.devMs > a
    }

    @MainActor func testStoppedThenBackItRunsAgain() async throws {
        let (p, done) = try player()
        defer { done() }
        XCTAssertTrue(p.status.booted, p.message)
        let running = await devMsAdvances(p)
        XCTAssertTrue(running, "playing before")
        for round in 1...3 {                    // (more than once: each return must bring it back)
            await p.suspendForBattery("test")
            XCTAssertTrue(p.suspended)
            let still = await devMsAdvances(p)
            XCTAssertFalse(still, "round \(round): stopped: its clock doesn't move")
            p.resumeFromBattery()
            XCTAssertFalse(p.suspended)
            let again = await devMsAdvances(p)
            XCTAssertTrue(again, "round \(round): back: the firmware runs again")
            XCTAssertTrue(p.status.booted, p.message)
        }
    }

    @MainActor func testAStopThatEndsAfterTheReturnIsDropped() async throws {
        let (p, done) = try player()
        defer { done() }
        await p.suspendForBattery("test") { false }   // (the app came back while it saved)
        XCTAssertFalse(p.suspended)
        let running = await devMsAdvances(p)
        XCTAssertTrue(running, "still playing")
    }
}
