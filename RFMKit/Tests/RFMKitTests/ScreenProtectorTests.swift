// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The screen protector's setting and its fold, and the status row's word (the firmware's name).

import Foundation
import XCTest
@testable import RFMKit

@MainActor
final class ScreenProtectorTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "rfm1.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testOnByDefaultAndPeeledIsRemembered() {
        let d = defaults()
        XCTAssertTrue(ScreenProtector(defaults: d).on)
        ScreenProtector(defaults: d).on = false
        XCTAssertFalse(ScreenProtector(defaults: d).on)
        ScreenProtector(defaults: d).on = true
        XCTAssertTrue(ScreenProtector(defaults: d).on)
    }

    func testFoldFollowsTheFingerAcrossTheScreen() {
        // the tab at the bottom-leading corner: up and to the right folds it
        XCTAssertEqual(ScreenProtector.fold(dx: 100, dy: -100, side: 200, flipped: false), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ScreenProtector.fold(dx: -50, dy: 50, side: 200, flipped: false), 0)
        XCTAssertEqual(ScreenProtector.fold(dx: 900, dy: -900, side: 200, flipped: false), 1)
        // top-trailing: down and to the left
        XCTAssertEqual(ScreenProtector.fold(dx: -100, dy: 100, side: 200, flipped: true), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ScreenProtector.fold(dx: 10, dy: 10, side: 0, flipped: false), 0)
        XCTAssertFalse(ScreenProtector.peels(0.2))
        XCTAssertTrue(ScreenProtector.peels(0.5))
    }

    func testWordIsTheFirmwareNameOrRemoteFM1() {
        XCTAssertEqual(FaceplateUI.word("Fizz"), "FIZZ")
        XCTAssertEqual(FaceplateUI.word("ChoralRoot"), "CHORALROOT")
        XCTAssertEqual(FaceplateUI.word(nil), "REMOTE FM1")
        XCTAssertEqual(FaceplateUI.word("  "), "REMOTE FM1")
        let ui = FaceplateUI()
        XCTAssertEqual(ui.word, "REMOTE FM1")
        ui.firmwareName = "fizz"
        XCTAssertEqual(ui.word, "FIZZ")
    }
}
