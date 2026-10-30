// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The unit's TRS MIDI in (RemoteFM1 0.3: caps RFM_CAP_MIDI_IN, MIDI_IN 0x54 in a session; docs/TRS-MIDI-HOSTS.md):
// MIDI into libremotefm1's fake unit's jack (rfmc_fake_trs) comes over the session to RemoteLink, is split by status
// and reaches the attached engine's core MIDI in (the echo core, rfme_test_load_echo, sends it back out), in order,
// not through learn, the map or the keys. Offline renders (RFME_CLOCK_AUDIO), 44.1 kHz. Needs no core builds.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class TrsMidiTests: XCTestCase {
    private var link: OpaquePointer!
    private var e: OpaquePointer!

    override func setUpWithError() throws {
        var cfg = rfmc_cfg_t()
        cfg.backend = Int32(RFMC_FAKE)
        cfg.fps = 20
        link = "RFMKit trs".withCString { hn in
            cfg.host_name = hn
            return rfmc_new(&cfg)
        }
        e = rfme_new(link)
        XCTAssertEqual(rfme_test_load_echo(e), 1)
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))
        rfme_set_offline(e, 1)
        rfme_midi_out_enable(e, 1)
        rfme_set_midi(e, Int32(RFME_KEYS_ANY), 0, 0, 1)     // (the keys on: TRS notes still go to the firmware)
        rfme_attach(e, 1)
        rfmc_start(link)
        var st = rfmc_status_t()
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            _ = render(1)
            rfmc_status(link, &st)
            if Int(st.state) == RFMC_CONNECTED { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(Int(st.state), RFMC_CONNECTED)
        XCTAssertNotEqual(Int(st.caps) & 0x200, 0, "the fake's HELLO_R has no RFM_CAP_MIDI_IN")
        _ = render(4)                                        // (anything from the start out of the way)
    }

    override func tearDown() {
        if let e {
            rfme_attach(e, 0)
            rfme_free(e)
        }
        if let link { rfmc_free(link) }
    }

    /// `count` renders of 512 frames; the core's MIDI out (USB-MIDI packets)
    private func render(_ count: Int) -> [UInt32] {
        var L = [Float](repeating: 0, count: 512), R = L
        var out: [UInt32] = []
        for _ in 0..<count {
            _ = L.withUnsafeMutableBufferPointer { l in
                R.withUnsafeMutableBufferPointer { r in rfme_render_midi(e, l.baseAddress, r.baseAddress, 512, 44100, nil, 0) }
            }
            var pkt: UInt32 = 0
            while rfme_midi_out_take(e, &pkt) != 0 { out.append(pkt) }
        }
        return out
    }

    /// MIDI into the jack, then renders until `want` packets came back out (or ~3 s)
    private func trs(_ msgs: [UInt8], want: Int) -> [UInt32] {
        msgs.withUnsafeBufferPointer { rfmc_fake_trs(link, $0.baseAddress, UInt32($0.count)) }
        var out: [UInt32] = []
        let end = Date().addingTimeInterval(3)
        while out.count < want && Date() < end {
            out += render(1)
            Thread.sleep(forTimeInterval: 0.005)
        }
        return out
    }

    private func pkt(_ m: [UInt8]) -> UInt32 {
        let cin = m[0] >= 0xF8 ? 0xF : UInt32(m[0] >> 4)
        return cin | UInt32(m[0]) << 8 | UInt32(m.count > 1 ? m[1] : 0) << 16 | UInt32(m.count > 2 ? m[2] : 0) << 24
    }

    /// one MIDI_IN body with several messages, real time among them: each its own packet, in order
    func testMessagesReachTheCoreSplitAndInOrder() {
        let msgs: [[UInt8]] = [[0x90, 60, 100], [0xF8], [0xB3, 7, 64], [0xC0, 5], [0xFA], [0xE1, 0, 64], [0xD2, 9],
                               [0x80, 60, 0], [0xFC]]
        let out = trs(msgs.flatMap { $0 }, want: msgs.count)
        XCTAssertEqual(out, msgs.map(pkt), "the core's MIDI in did not get the jack's messages as they came")
        var st = rfmc_status_t()
        rfmc_status(link, &st)
        XCTAssertEqual(st.trs_midi_in, UInt32(msgs.count))
        XCTAssertEqual(st.trs_midi_dropped, 0)
        var s = rfme_status_t()
        rfme_status(e, &s)
        XCTAssertEqual(s.keys_pressed, 0, "a TRS note played a key: it went through host MIDI's path")
    }

    /// more than a body holds (64 bytes): the fake sends several MIDI_IN, all arrive, in order (no note 0: the echo
    /// core answers it with a SysEx)
    func testLongBurstSpansSeveralBodies() {
        var msgs: [[UInt8]] = []
        for n in 1...40 { msgs.append([0x90, UInt8(n), UInt8(n)]); if n % 5 == 0 { msgs.append([0xF8]) } }
        let out = trs(msgs.flatMap { $0 }, want: msgs.count)
        XCTAssertEqual(out, msgs.map(pkt))
        var st = rfmc_status_t()
        rfmc_status(link, &st)
        XCTAssertEqual(st.trs_midi_in, UInt32(msgs.count))
    }
}
