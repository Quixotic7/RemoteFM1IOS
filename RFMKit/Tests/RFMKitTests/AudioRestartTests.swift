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
}
