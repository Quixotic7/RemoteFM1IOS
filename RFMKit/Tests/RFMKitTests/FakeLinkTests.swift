// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RemoteController against libremotefm1's in-process fake unit only. FM1EMU_REMOTE_FAKE=1 makes every RemoteLink
// fake whatever it is asked, so nothing here can reach CoreMIDI or a real FM-1.

import Foundation
import XCTest
@testable import RFMKit

@MainActor
final class FakeLinkTests: XCTestCase {
    override func setUp() {
        setenv("FM1EMU_REMOTE_FAKE", "1", 1)
    }

    private func lockPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("rfmkit-test-\(UUID().uuidString).lock").path
    }

    private func controller(ble: Bool, pattern: Bool = true) -> RemoteController {
        let c = RemoteController(backend: .fake(bluetooth: ble), patternOn: pattern, lockPath: lockPath())
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }

    /// polls `cond` (after a refresh) until it holds or `seconds` pass
    private func wait(_ c: RemoteController, _ seconds: Double, _ what: String,
                      _ cond: (RemoteController) -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            c.refresh()
            if cond(c) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        c.refresh()
        XCTFail("timed out: \(what) (state \(c.state), \(c.statusText), log \(c.lastLog))")
    }

    func testReachesActiveAndFramesAreAcknowledged() async {
        let c = controller(ble: false)
        c.start()
        await wait(c, 5, "connected") { $0.state.isConnected }
        XCTAssertEqual(c.state, .connected(bluetooth: false))
        let h = try? XCTUnwrap(c.hello)
        XCTAssertEqual(h?.name, "RemoteFM1")
        XCTAssertEqual(h?.proto, 2)
        XCTAssertEqual(h?.isBluetooth, false)
        await wait(c, 5, "20 frames acknowledged") { $0.stats.acks >= 20 }
        XCTAssertGreaterThan(c.stats.frames, 0)
        XCTAssertGreaterThan(c.stats.wireBytes, 0)
        XCTAssertGreaterThan(c.stats.budget, 0)
        XCTAssertFalse(c.stats.ble)
        XCTAssertEqual(c.fakeUnit()?.session, 1)
        let img = try? XCTUnwrap(c.preview)
        XCTAssertEqual(img?.width, 240)
        XCTAssertEqual(img?.height, 240)
    }

    func testBluetoothFakeReportsBleAndUsesHold() async {
        let c = controller(ble: true)
        c.start()
        await wait(c, 8, "connected over Bluetooth") { $0.state == .connected(bluetooth: true) }
        XCTAssertTrue(c.stats.ble)
        XCTAssertTrue(c.stats.hold)
        XCTAssertEqual(c.hello?.isBluetooth, true)
        XCTAssertNotEqual((c.hello?.caps ?? 0) & (1 << 7), 0, "HOLD in the caps")
        await wait(c, 15, "frames sent with HOLD, acknowledged") { $0.stats.held > 0 && $0.stats.acks > 0 }
        XCTAssertGreaterThan(c.fakeUnit()?.heldFrames ?? 0, 0)
    }

    func testFakePanelEventReachesSwiftAndLightsTheKey() async {
        let c = controller(ble: false, pattern: false)
        c.start()
        await wait(c, 5, "connected") { $0.state.isConnected }
        c.fakeKey(5, down: true)
        await wait(c, 3, "key 5 down") { c in
            c.events.contains { $0.kind == .key && $0.index == 5 && $0.value == 1 } && c.heldKeys & (1 << 5) != 0
        }
        await wait(c, 3, "key 5's LED lit on the unit") { $0.fakeKeyLit(5) }
        c.fakeButton(12, down: true)                    // PLAY
        await wait(c, 3, "PLAY down, its LED lit") { $0.heldButtons & (1 << 12) != 0 && $0.fakeButtonLit(12) }
        c.fakeKey(5, down: false)
        c.fakeButton(12, down: false)
        await wait(c, 3, "key 5 up, its LED off") { $0.heldKeys == 0 && $0.heldButtons == 0 && !$0.fakeKeyLit(5) }
        c.fakeEncoder(2, detents: 3)
        await wait(c, 3, "encoder 2 +3") { c in
            c.events.contains { $0.kind == .encoder && $0.index == 2 && $0.value == 3 }
        }
        c.fakeMaster(700)
        await wait(c, 3, "MASTER near 700") { abs(($0.master ?? -100) - 700) <= 16 }
        XCTAssertEqual(c.events.first { $0.kind == .key }?.text, "key 5 A#3 up")
    }

    func testStopEndsTheSession() async {
        let c = controller(ble: false)
        c.start()
        await wait(c, 5, "connected") { $0.state.isConnected }
        c.stop()
        await wait(c, 3, "stopped") { $0.state == .stopped("") }
        XCTAssertEqual(c.fakeUnit()?.session, 0)
        c.start()                                       // (and again)
        await wait(c, 5, "connected again") { $0.state.isConnected }
    }

    func testSecondLinkOnTheSameLockIsInUse() async {
        let path = lockPath()
        let a = RemoteController(backend: .fake(bluetooth: false), lockPath: path)
        let b = RemoteController(backend: .fake(bluetooth: false), lockPath: path)
        addTeardownBlock { @MainActor in a.shutdown(); b.shutdown() }
        a.start()
        await wait(a, 5, "a connected") { $0.state.isConnected }
        b.start()
        await wait(b, 3, "b in use") { if case .inUse = $0.state { true } else { false } }
        a.stop()
        await wait(b, 5, "b takes over") { $0.state.isConnected }
    }
}
