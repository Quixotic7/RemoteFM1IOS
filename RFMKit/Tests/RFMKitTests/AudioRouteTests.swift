// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// AudioRoute: what a route change asks of the app's engine, the row's name and the USB hint.

@testable import RFMKit
import XCTest

final class AudioRouteTests: XCTestCase {
    func testActions() {
        for c: AudioRoute.Cause in [.newDevice, .oldDeviceGone, .categoryChange, .override, .other] {
            XCTAssertEqual(AudioRoute.action(c, audioOn: false, engineRunning: false), .none, "sound off: nothing")
            XCTAssertEqual(AudioRoute.action(c, audioOn: true, engineRunning: true), .rename, "still running: the name")
            XCTAssertEqual(AudioRoute.action(c, audioOn: true, engineRunning: false), .restart, "stopped: a new engine")
        }
    }

    func testNameAndHint() {
        let fm1 = AudioRoute.Output(name: "FM-1", usb: true), pods = AudioRoute.Output(name: "AirPods Pro", usb: false)
        XCTAssertEqual(AudioRoute.name([pods]), "AirPods Pro")
        XCTAssertEqual(AudioRoute.name([]), "None")
        XCTAssertNil(AudioRoute.hint([pods]))
        XCTAssertNotNil(AudioRoute.hint([fm1]))
    }
}
