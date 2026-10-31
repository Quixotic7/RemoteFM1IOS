// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// TOUCH (RemoteFM1 0.3.1: caps RFM_CAP_TOUCH, TOUCH 0x14 after the SESSION start's ACK; docs/VELOCITY-HOSTS.md):
// libremotefm1's fake unit (vendor/RemoteFM1-touch) asked by the session for its keys' velocity and pressure, PANEL_R
// confirming it, `9F 53+k v` and `AF 53+k p` parsed into panel events, and the attached engine giving them to the
// core as key_vel / key_lean (the echo core; rfme_status's key_vel_last / key_lean_last). Off, or a unit before 0.3.1:
// no TOUCH, the keys at velocity 100. Offline renders, needs no core builds.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class TouchTests: XCTestCase {
    private var link: OpaquePointer!
    private var e: OpaquePointer!

    private func open(noTouch: Bool = false, flags: UInt32? = nil) {
        var cfg = rfmc_cfg_t()
        cfg.backend = Int32(RFMC_FAKE)
        cfg.fps = 20
        cfg.fake_no_touch = noTouch ? 1 : 0
        link = "RFMKit touch".withCString { hn in
            cfg.host_name = hn
            return rfmc_new(&cfg)
        }
        if let flags { rfmc_set_key_touch(link, flags) }
        e = rfme_new(link)
        XCTAssertEqual(rfme_test_load_echo(e), 1)
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))
        rfme_set_offline(e, 1)
        rfme_attach(e, 1)
        rfmc_start(link)
        XCTAssertTrue(until { Int(self.status().state) == RFMC_CONNECTED }, "no session")
        _ = until { false }                                 // (the start, its TOUCH and PANEL_R out of the way)
    }

    override func tearDown() {
        if let e {
            rfme_attach(e, 0)
            rfme_free(e)
        }
        if let link { rfmc_free(link) }
    }

    private func status() -> rfmc_status_t {
        var st = rfmc_status_t()
        rfmc_status(link, &st)
        return st
    }

    private func fake() -> rfmc_fake_t {
        var f = rfmc_fake_t()
        _ = rfmc_fake_state(link, &f)
        return f
    }

    private func engine() -> rfme_status_t {
        var s = rfme_status_t()
        rfme_status(e, &s)
        return s
    }

    /// renders until `ok` (or `seconds`)
    @discardableResult
    private func until(_ seconds: Double = 0.6, _ ok: () -> Bool) -> Bool {
        var L = [Float](repeating: 0, count: 256), R = L
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            _ = L.withUnsafeMutableBufferPointer { l in
                R.withUnsafeMutableBufferPointer { r in rfme_render_midi(e, l.baseAddress, r.baseAddress, 256, 44100, nil, 0) }
            }
            if ok() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }

    private func pressed(_ k: UInt32, vel: UInt32) -> Bool {
        rfmc_fake_key_vel(link, k, 1, vel)
        let before = engine().keys_pressed
        return until(3) { self.engine().keys_pressed > before }
    }

    func testTouchAskedAfterAckAndConfirmed() {
        open()
        XCTAssertNotEqual(Int(status().caps) & 0x400, 0, "the fake's HELLO_R has no RFM_CAP_TOUCH")
        XCTAssertTrue(until(3) { self.status().touch == 3 }, "PANEL_R does not confirm velocity + pressure")
        XCTAssertEqual(status().touch_wanted, 3)
        XCTAssertGreaterThanOrEqual(status().touch_sent, 1)
        XCTAssertEqual(fake().touch, 3)
        XCTAssertGreaterThanOrEqual(fake().touch_msgs, 1)
        let t = LinkStats.touchText(caps: status().caps, wanted: 3, inForce: 3, sent: 1)
        XCTAssertTrue(t.contains("confirms velocity + pressure"), t)
    }

    func testVelocityAndPressureReachTheCore() {
        open()
        XCTAssertTrue(until(3) { self.status().touch == 3 })
        XCTAssertTrue(pressed(4, vel: 37))
        XCTAssertEqual(engine().key_vel_last, 4 << 8 | 37, "key_vel")
        rfmc_fake_press(link, 4, 90)                        // (90 * 100 + 63) / 127 = 71
        XCTAssertTrue(until(3) { self.engine().key_lean_last == 4 << 8 | 71 }, "key_lean \(engine().key_lean_last)")
        rfmc_fake_press(link, 4, 127)
        XCTAssertTrue(until(3) { self.engine().key_lean_last == 4 << 8 | 100 })
        // the panel's event log carries both (9F 53+k v, AF 53+k p)
        var ev = [rfmc_event_t](repeating: rfmc_event_t(), count: 64)
        let n = Int(rfmc_events(link, 0, &ev, 64))
        let evs = ev.prefix(n).map(RemoteController.event(of:))
        XCTAssertTrue(evs.contains { $0.kind == .key && $0.index == 4 && $0.value == 1 && $0.velocity == 37 })
        XCTAssertTrue(evs.contains { $0.kind == .pressure && $0.index == 4 && $0.value == 90 })
        rfmc_fake_key(link, 4, 0)
        XCTAssertTrue(pressed(5, vel: 120))
        XCTAssertEqual(engine().key_vel_last, 5 << 8 | 120)
    }

    func testOffSendsNoTouch() {
        open(flags: 0)
        XCTAssertNotEqual(Int(status().caps) & 0x400, 0)
        XCTAssertEqual(status().touch_sent, 0)
        XCTAssertEqual(fake().touch_msgs, 0)
        XCTAssertEqual(fake().touch, 0)
        XCTAssertTrue(pressed(2, vel: 37))
        XCTAssertEqual(engine().key_vel_last, 2 << 8 | 100, "off: velocity 100 as before")
        rfmc_fake_press(link, 2, 90)                        // (the fake sends no AF without TOUCH's pressure)
        _ = until { false }
        XCTAssertEqual(engine().key_lean_last, 0)
    }

    func testTurningItOffInASession() {
        open()
        XCTAssertTrue(until(3) { self.fake().touch == 3 })
        rfmc_set_key_touch(link, 0)
        XCTAssertTrue(until(3) { self.fake().touch == 0 && self.status().touch == 0 }, "TOUCH 0 not sent")
        XCTAssertTrue(pressed(7, vel: 20))
        XCTAssertEqual(engine().key_vel_last, 7 << 8 | 100)
        rfmc_set_key_touch(link, 3)
        XCTAssertTrue(until(3) { self.fake().touch == 3 && self.status().touch == 3 })
    }

    func testOlderFirmwareNothingChanges() {
        open(noTouch: true)
        XCTAssertEqual(Int(status().caps) & 0x400, 0)
        XCTAssertEqual(status().touch_sent, 0)
        XCTAssertEqual(fake().touch_msgs, 0)
        XCTAssertTrue(pressed(3, vel: 37))
        XCTAssertEqual(engine().key_vel_last, 3 << 8 | 100)
        let t = LinkStats.touchText(caps: status().caps, wanted: 3, inForce: 0, sent: 0)
        XCTAssertTrue(t.hasPrefix("not in this firmware"), t)
    }

    func testSettingIsKeptAndDefaultsOn() {
        XCTAssertTrue(AUSettings().keyTouch)
        XCTAssertTrue(AUSettings([:]).keyTouch)
        XCTAssertEqual(AUSettings().keyTouchFlags, 3)
        var s = AUSettings()
        s.keyTouch = false
        XCTAssertFalse(AUSettings(s.dict).keyTouch)
        XCTAssertEqual(AUSettings(s.dict).keyTouchFlags, 0)
    }
}
