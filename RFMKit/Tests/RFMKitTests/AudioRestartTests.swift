// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Changing the audio device: a burst of configuration changes (a switch sends several) and back-to-back restarts keep
// the firmware playing (crashes on Mac: the output's workgroup asked mid-change, an old engine freed too soon).

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class AudioRestartTests: XCTestCase {
    @MainActor func testDeviceChangesKeepItPlaying() async throws {
        guard FileManager.default.fileExists(atPath: CoreTests.coresDir) else { throw XCTSkip("no built cores") }
        let suite = "rfm-restart-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        let flash = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let p = CorePlayer(link: nil, slotsDir: CoreTests.coresDir, flashDir: flash, selected: "fizz", midiDefaults: d)
        defer { p.stop(); d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: flash) }
        p.setAudio(true)
        p.setMode(.core)
        guard p.audioRunning else { throw XCTSkip("no audio output here") }
        for round in 1...3 {
            for _ in 0..<6 { p.configurationChangeSoon() }      // (one switch: several notifications)
            p.audioConfigurationChanged()                       // (and restarts straight after each other)
            p.audioConfigurationChanged()
            try await Task.sleep(for: .milliseconds(900))       // (the settled restart, the workgroup asked)
            XCTAssertTrue(p.audioRunning, "round \(round): the sound back")
            XCTAssertTrue(p.status.booted, p.message)
            let a = p.activity.devMs
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertGreaterThan(p.activity.devMs, a, "round \(round): the firmware runs")
        }
        try await Task.sleep(for: .milliseconds(2500))          // (the stopped engines freed)
    }

    /// another app takes the audio (the Camera, 2026-11-07): the firmware goes on with its timer, the sound comes back
    /// when it lets go, and an output tap (recording) is put back on the new engine
    @MainActor func testInterruptionKeepsItRunningAndComesBack() async throws {
        guard FileManager.default.fileExists(atPath: CoreTests.coresDir) else { throw XCTSkip("no built cores") }
        let suite = "rfm-interrupt-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        let flash = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let p = CorePlayer(link: nil, slotsDir: CoreTests.coresDir, flashDir: flash, selected: "fizz", midiDefaults: d)
        defer { p.setOutputTap(nil); p.stop(); d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: flash) }
        p.setAudio(true)
        p.setMode(.core)
        guard p.audioRunning else { throw XCTSkip("no audio output here") }
        let count = TapCount()
        p.setOutputTap { b, _ in count.add(Int(b.frameLength)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(count.frames, 0, "the tap hears the app")

        p.audioInterrupted()
        XCTAssertTrue(p.interrupted)
        XCTAssertFalse(p.audioRunning)
        let a = p.activity.devMs
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(p.activity.devMs, a, "the firmware runs on its timer meanwhile")

        p.resumeAudioIfNeeded()
        XCTAssertFalse(p.interrupted)
        XCTAssertTrue(p.audioRunning, "the sound back")
        let before = count.frames
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(count.frames, before, "the tap is on the new engine")

        XCTAssertFalse(p.mixWithOthers)
        p.mixWithOthers = true
        XCTAssertTrue(d.bool(forKey: CorePlayer.mixKey), "the setting is kept")
        try await Task.sleep(for: .milliseconds(2500))          // (the stopped engines freed)
    }
}

final class TapLevelTests: XCTestCase {
    /// (recording) the tap hears the firmware: a note played into ChoralRoot shows up in it
    @MainActor func testTapHearsANote() async throws {
        guard FileManager.default.fileExists(atPath: CoreTests.coresDir) else { throw XCTSkip("no built cores") }
        let suite = "rfm-tap-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        let flash = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let p = CorePlayer(link: nil, slotsDir: CoreTests.coresDir, flashDir: flash, selected: "choralroot", midiDefaults: d)
        defer { p.setOutputTap(nil); p.stop(); d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: flash) }
        p.setAudio(true)
        p.setMode(.core)
        guard p.audioRunning else { throw XCTSkip("no audio output here") }
        try await Task.sleep(for: .milliseconds(800))           // (booted)
        let level = TapCount()
        p.setOutputTap { b, _ in
            guard let ch = b.floatChannelData else { return }
            var m: Float = 0
            for i in 0..<Int(b.frameLength) { m = max(m, abs(ch[0][i])) }
            level.peak(m)
        }
        let on: [UInt8] = [0x90, 62, 110]
        _ = on.withUnsafeBufferPointer { rfme_midi_in(p.e, $0.baseAddress, 3, 1) }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(level.maxLevel, 0.001, "a note is heard in the tap")
        let off: [UInt8] = [0x80, 62, 0]
        _ = off.withUnsafeBufferPointer { rfme_midi_in(p.e, $0.baseAddress, 3, 1) }
        try await Task.sleep(for: .milliseconds(2500))
    }
}

final class TapCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var m: Float = 0
    func add(_ f: Int) { lock.withLock { n += f } }
    var frames: Int { lock.withLock { n } }
    func peak(_ v: Float) { lock.withLock { m = max(m, v) } }
    var maxLevel: Float { lock.withLock { m } }
}
