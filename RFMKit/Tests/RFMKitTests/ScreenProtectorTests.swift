// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The screen protector's setting, its tab's place and its fold, and the status row's word (the firmware's name).

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

    func testTabSitsBesideTheScreenNearestKN1() {
        let d = CGRect(x: 198, y: 20, width: 172, height: 172)
        let right = FilmGeometry.tab(display: d, below: false)       // landscape: right of the screen, level with its top
        XCTAssertGreaterThan(right.maxX, d.maxX)
        XCTAssertLessThan(right.minX, d.maxX, "overlapping the bezel a little")
        XCTAssertLessThan(right.minY - d.minY, right.height)
        let below = FilmGeometry.tab(display: d, below: true)        // phone portrait: under the leading corner
        XCTAssertGreaterThan(below.maxY, d.maxY)
        XCTAssertLessThan(below.minX - d.minX, below.width)
    }

    func testFoldFollowsTheFingerFromTheTabAcrossTheScreen() {
        let d = CGRect(x: 0, y: 0, width: 200, height: 200)
        let g = FilmGeometry(display: d, radius: 18, tab: FilmGeometry.tab(display: d, below: false))
        // the tab right of the screen: dragging left (into the screen) folds, right does nothing
        XCTAssertLessThan(g.direction.dx, 0)
        XCTAssertGreaterThan(g.fold(dx: -100, dy: 0), 0.2)
        XCTAssertEqual(g.fold(dx: 100, dy: 0), 0)
        XCTAssertEqual(g.fold(dx: -9000, dy: 0), 1)
        // unfolded: the whole film on (the display and the strip to the tab), no flap, the tab in its place
        let f0 = g.folded(0)
        XCTAssertEqual(f0.left.count, 2)
        XCTAssertTrue(f0.flap.isEmpty)
        XCTAssertEqual(f0.tab.x, g.tab.midX, accuracy: 1e-9)
        // half folded: some film still on, a flap, the tab carried by the finger
        let f = g.folded(g.length / 2)
        XCTAssertFalse(f.left.isEmpty)
        XCTAssertFalse(f.flap.isEmpty)
        XCTAssertLessThan(f.tab.x, g.tab.midX)
        // fully folded: nothing left on
        XCTAssertTrue(g.folded(g.length * 1.01).left.isEmpty)
        // below the screen: up folds
        let b = FilmGeometry(display: d, radius: 18, tab: FilmGeometry.tab(display: d, below: true))
        XCTAssertGreaterThan(b.fold(dx: 0, dy: -100), 0.2)
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
