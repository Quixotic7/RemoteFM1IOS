// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// A pointer's latches and a hardware keyboard (PanelFeed's latch and keyboard sources, as the web player and FM1VST):
// Shift / Ctrl-click latches, any click on a latched one lets it go, Escape lets them all go, and a key held by
// several sources is one press.

import XCTest
@testable import RFMKit

@MainActor
final class LatchTests: XCTestCase {
    func testShiftClickLatchesAndAClickLetsGo() {
        let f = PanelFeed(host: nil)
        XCTAssertFalse(f.latchPress(key: 7, modifier: false), "a plain click: an ordinary press")
        XCTAssertTrue(f.latchPress(key: 7, modifier: true))
        XCTAssertTrue(f.lights.keyDown(7), "held after the click")
        XCTAssertTrue(f.anyLatched)
        XCTAssertTrue(f.latchPress(key: 7, modifier: false), "a click on it")
        XCTAssertFalse(f.lights.keyDown(7))
        XCTAssertFalse(f.anyLatched)
    }

    func testButtonsLatchToo() {
        let f = PanelFeed(host: nil)
        XCTAssertTrue(f.latchPress(.play, modifier: true))
        XCTAssertTrue(f.latchPress(.fx, modifier: true))
        XCTAssertTrue(f.lights.labelDown(PanelFeed.Label.play.rawValue))
        XCTAssertTrue(f.lights.labelDown(PanelFeed.Label.fx.rawValue))
        f.releaseLatches()                                     // (Escape)
        XCTAssertFalse(f.lights.labelDown(PanelFeed.Label.play.rawValue))
        XCTAssertFalse(f.anyLatched)
    }

    func testAKeyHeldBySeveralSourcesIsOnePress() {
        let f = PanelFeed(host: nil)
        f.keyDown(9, source: .keyboard)
        f.keyDown(9)                                           // (a finger as well)
        f.keyUp(9, source: .keyboard)
        XCTAssertTrue(f.lights.keyDown(9), "the finger still holds it")
        f.keyUp(9)
        XCTAssertFalse(f.lights.keyDown(9))
        f.button(.octDown, down: true, source: .keyboard)
        _ = f.latchPress(.octDown, modifier: true)
        f.button(.octDown, down: false, source: .keyboard)
        XCTAssertTrue(f.lights.labelDown(PanelFeed.Label.octDown.rawValue), "the latch still holds it")
    }

    func testLettingTheScreenGoKeepsLatches() {
        let f = PanelFeed(host: nil)
        _ = f.latchPress(key: 3, modifier: true)
        f.keyDown(5)
        f.releaseAll()                                         // (the view went away)
        XCTAssertTrue(f.lights.keyDown(3))
        XCTAssertFalse(f.lights.keyDown(5))
    }
}
