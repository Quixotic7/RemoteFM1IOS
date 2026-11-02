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
        XCTAssertEqual(ManagerList.url(for: "choralroot")?.absoluteString, "https://quixotic7.github.io/ChoralRootFM1/webapp/installer/manager.html")
        XCTAssertEqual(ManagerList.url(for: "purplemonkey")?.absoluteString, "https://quixotic7.github.io/ChoralRootFM1/webapp/installer/manager.html")
        XCTAssertEqual(ManagerList.url(for: "felucca")?.absoluteString, "https://hugelton.github.io/Felucca/webapp/editor/")
        XCTAssertFalse(ManagerList.authors.values.contains { $0.host == "remotefm1.com" }, "never the site's copies")
        XCTAssertEqual(ManagerList.url(for: "fizz")?.absoluteString, "https://quixotic7.github.io/FIZZ/manager/")
        XCTAssertNil(ManagerList.url(for: "nonesuch"))
        XCTAssertNotNil(ManagerList.url(for: "mutabledreams"), "the site lists it as \"mutable\"")
        XCTAssertEqual(ManagerList.port(for: "rainbow", name: "Rainbow Mode"), "Felucca", "Felucca's editor looks for Felucca")
        XCTAssertEqual(ManagerList.port(for: "melodee", name: "Melodee"), "Melodee FM-1")
        // (RemoteFM1FW 31b8751, checked against the firmwares' USB descriptors)
        XCTAssertEqual(ManagerList.port(for: "jiant", name: "JIANT"), "FM-1", "10.26's; JIANT's editor matches FM-1")
        XCTAssertEqual(ManagerList.port(for: "hortator", name: "Hortator"), "Hortator")
        XCTAssertNil(ManagerList.url(for: "hortator"), "its firmware answers no editor (RemoteFM1FW 5bcbb65)")
        XCTAssertTrue(ManagerList.hasReader("ctl1"), "CTL-1's catalog id")
        XCTAssertTrue(ManagerList.hasReader("amb"))
        XCTAssertFalse(ManagerList.hasReader("ripple"), "his, but no screen reader support (0.4)")
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

    /// the page: the catalog's editor link (the author's, https only), else the author's page the app knows
    func testEditorPage() {
        var sloop = AvailableFirmware(id: "sloop")
        sloop.editor = "https://isod89.github.io/sloop-fm1/webapp/editor/"
        var bad = AvailableFirmware(id: "old")
        bad.editor = "http://example.com/editor"
        var felucca = AvailableFirmware(id: "felucca")
        felucca.editor = "https://hugelton.github.io/Felucca/webapp/editor/"
        let d = ["sloop": sloop, "old": bad, "felucca": felucca]
        XCTAssertEqual(ManagerList.editor(for: "sloop", details: d)?.absoluteString, sloop.editor)
        XCTAssertEqual(ManagerList.editor(for: "felucca", details: d)?.absoluteString, "https://hugelton.github.io/Felucca/webapp/editor/")
        XCTAssertNil(ManagerList.editor(for: "old", details: d), "not https")
        XCTAssertEqual(ManagerList.editor(for: "choralroot", details: d), ManagerList.authors["choralroot"], "not in the catalog")
        var moved = AvailableFirmware(id: "melodee")
        moved.editor = "https://keremimo.github.io/melodee-next/editor/"
        XCTAssertEqual(ManagerList.editor(for: "melodee", details: ["melodee": moved])?.absoluteString, moved.editor,
                       "the catalog's link wins: the author may move it")
        XCTAssertNil(ManagerList.editor(for: "nonesuch", details: d))
    }

    /// an older cache without `editor` still reads
    func testOldCacheEntryDecodes() throws {
        let json = #"{"id":"amb","name":"AMB-1","version":"1.3","downloads":[]}"#
        let e = try JSONDecoder().decode(AvailableFirmware.self, from: Data(json.utf8))
        XCTAssertEqual(e.name, "AMB-1")
        XCTAssertEqual(e.editor, "")
    }
}
