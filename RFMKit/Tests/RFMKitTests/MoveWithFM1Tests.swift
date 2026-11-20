// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The Ableton Move and an FM-1 at once (the owner, 2026-11-19: "both use the Ableton Move as a controller and also
// still have the FM-1 connected via BLE or USB"). The firmware runs in the app's engine either way; "My FM-1" attaches
// that engine to the FM-1's link (its keys in, its screen and LEDs out) and the Move's core runs on the same engine.
// Here: libremotefm1's fake unit on the link and a fake Move (MoveLinkTests.swift) on loopback, the echo core (one
// still screen: the FM-1 gets it once).

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class MoveWithFM1Tests: XCTestCase {
    private var link: OpaquePointer!
    private var e: OpaquePointer!
    private var m: OpaquePointer!
    private var move: FakeMove!

    override func setUp() async throws {
        var cfg = rfmc_cfg_t()
        cfg.backend = Int32(RFMC_FAKE)
        cfg.fps = 20
        link = "RFMKit move + FM-1".withCString { hn in
            cfg.host_name = hn
            return rfmc_new(&cfg)
        }
        e = try XCTUnwrap(rfme_new(link))
        XCTAssertEqual(rfme_test_load_echo(e), 1)
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        rfme_set_clock(e, Int32(RFME_CLOCK_TIMER))
        rfme_attach(e, 1)
        rfmc_start(link)
        move = try FakeMove()
        m = "RFMKit test".withCString { rfmm_new(nil, 0, $0) }
        rfme_attach_move(e, m)
        rfmm_projects_init(m, 0, 0, nil, 0)
        rfmm_start(m, "127.0.0.1:\(move.port)")
    }

    override func tearDown() async throws {
        if let m { rfmm_stop(m) }
        if let e {
            rfme_set_clock(e, Int32(RFME_CLOCK_NONE))
            rfme_attach_move(e, nil)
            rfme_attach(e, 0)
            rfme_free(e)
        }
        if let m { rfmm_free(m) }
        if let link { rfmc_free(link) }
        move?.stop()
    }

    private func engine() -> rfme_status_t {
        var s = rfme_status_t()
        rfme_status(e, &s)
        return s
    }
    private func fm1() -> rfmc_fake_t {
        var f = rfmc_fake_t()
        _ = rfmc_fake_state(link, &f)
        return f
    }
    private func linked() -> Bool {
        var st = rfmc_status_t()
        rfmc_status(link, &st)
        return Int(st.state) == RFMC_CONNECTED
    }
    private func moveConnected() -> Bool {
        var s = rfmm_status_t()
        rfmm_status(m, &s)
        return Int(s.state) == Int(RFMM_CONNECTED) && s.ticking != 0
    }
    @discardableResult
    private func until(_ seconds: Double = 3, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if ok() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return ok()
    }

    func testTheMoveAndTheFM1PlayTheSameFirmware() {
        XCTAssertTrue(until { self.linked() }, "the FM-1's session")
        XCTAssertTrue(until { self.moveConnected() }, "the Move connected, the engine running its core")
        // a key from each reaches the firmware
        var before = engine().keys_pressed
        move.pad(16, 100)
        XCTAssertTrue(until { self.engine().keys_pressed > before }, "the Move's pad: an FM-1 key")
        move.pad(16, 0)
        before = engine().keys_pressed
        rfmc_fake_key(link, 4, 1)
        XCTAssertTrue(until { self.engine().keys_pressed > before }, "the FM-1's own key")
        rfmc_fake_key(link, 4, 0)
        // both show the firmware: the FM-1 gets its screen, the Move its own
        XCTAssertTrue(until { self.fm1().frames >= 1 }, "the FM-1 shows the firmware's screen")
        XCTAssertTrue(until { self.move.counts.screens > 0 && self.move.counts.rgb > 0 }, "the Move its screen and LEDs")
        XCTAssertTrue(linked(), "the FM-1 still linked")
        XCTAssertTrue(moveConnected(), "the Move still connected")
    }
}
