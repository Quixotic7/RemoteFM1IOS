// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The web managers' MIDI path (PLAN.md section 18 step 5): a page's SysEx into the firmware (rfme_sysex_in) and the
// firmware's MIDI out back as whole messages (UsbMidiDecoder), through the echo test core; the manager list.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class ManagerTests: XCTestCase {
    func testDecoderPutsMessagesBackTogether() {
        var d = UsbMidiDecoder()
        XCTAssertNil(d.feed(0x4 | 0xF0 << 8 | 0x7D << 16 | 0x01 << 24))
        XCTAssertNil(d.feed(0x4 | 0x02 << 8 | 0x03 << 16 | 0x04 << 24))
        XCTAssertEqual(d.feed(0x6 | 0x05 << 8 | 0xF7 << 16), [0xF0, 0x7D, 0x01, 0x02, 0x03, 0x04, 0x05, 0xF7])
        XCTAssertEqual(d.feed(0x5 | 0xF7 << 8), nil, "an end with nothing begun")
        XCTAssertEqual(d.feed(0x9 | 0x90 << 8 | 0x3C << 16 | 0x64 << 24), [0x90, 0x3C, 0x64])
        XCTAssertEqual(d.feed(0xC | 0xC0 << 8 | 0x05 << 16), [0xC0, 0x05])
        XCTAssertEqual(d.feed(0xF | 0xF8 << 8), [0xF8])
    }

    func testSysExThroughTheFirmwareAndBack() {
        let e = rfme_new(nil)!
        defer { rfme_free(e) }
        XCTAssertEqual(rfme_test_load_echo(e), 1)
        _ = rfme_boot(e, nil, 0)
        rfme_set_clock(e, Int32(RFME_CLOCK_CALLER))
        rfme_midi_out_enable(e, 2)
        // a 3 KB SysEx (a bank dump's size), each length 1..3 of the last packet
        for tail in 0..<3 {
            let body = (0..<(3000 + tail)).map { UInt8(truncatingIfNeeded: $0 * 7) & 0x7F }
            let msg = [0xF0] + body + [0xF7]
            XCTAssertEqual(msg.withUnsafeBufferPointer { rfme_sysex_in(e, $0.baseAddress, UInt32($0.count)) }, 1)
            var d = UsbMidiDecoder(), got: [[UInt8]] = []
            var a = rfme_audio_t()
            for _ in 0..<200 where got.isEmpty {
                rfme_run_ms(e, 5, &a)
                for p in drain(e) { if let m = d.feed(p) { got.append(m) } }
            }
            XCTAssertEqual(got.count, 1)
            XCTAssertEqual(got.first, msg, "the SysEx came back whole (tail \(tail))")
        }
        // not one SysEx message: refused
        XCTAssertEqual([UInt8]([0xF0, 0x01, 0x90, 0xF7]).withUnsafeBufferPointer { rfme_sysex_in(e, $0.baseAddress, 4) }, 0)
        XCTAssertEqual([UInt8]([0x90, 0x3C, 0x64]).withUnsafeBufferPointer { rfme_sysex_in(e, $0.baseAddress, 3) }, 0)
    }

    func testManagerList() {
        XCTAssertEqual(ManagerList.url(for: "choralroot")?.absoluteString, "https://remotefm1.com/managers/choralroot/")
        XCTAssertEqual(ManagerList.url(for: "purplemonkey")?.absoluteString, "https://remotefm1.com/managers/choralroot/")
        XCTAssertNil(ManagerList.url(for: "fizz"))
        XCTAssertEqual(ManagerList.port(for: "melodee", name: "Melodee"), "Melodee FM-1")
        XCTAssertEqual(ManagerList.port(for: "nonesuch", name: "Nonesuch"), "Nonesuch")
    }

    private func drain(_ e: OpaquePointer) -> [UInt32] {
        var out: [UInt32] = []
        for _ in 0..<100_000 {
            var p: UInt32 = 0
            guard rfme_midi_out_take(e, &p) == 1 else { break }
            out.append(p)
        }
        return out
    }
}
