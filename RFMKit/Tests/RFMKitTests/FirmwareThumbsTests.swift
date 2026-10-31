// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The firmware list's thumbnails (save, load, an all-black frame refused, the capture's timing) and the Firmware
// panel's info (the catalog's details by id, the source link's order, the core's own fallback).

import Foundation
import XCTest
@testable import RFMKit

@MainActor
final class FirmwareThumbsTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rfm-th-\(UUID().uuidString.prefix(8))")
    }

    private func frame(lit: Bool) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 240 * 240 * 4)
        if lit { for i in stride(from: 0, to: b.count / 2, by: 4) { b[i] = 200; b[i + 1] = 120 } }
        return b
    }

    func testSaveLoadAndBlank() throws {
        let t = FirmwareThumbs(directory: tempDir())
        XCTAssertNil(t.image("felucca"))
        XCTAssertFalse(t.save(rgba: frame(lit: false), id: "felucca"))
        XCTAssertFalse(t.exists("felucca"))
        XCTAssertTrue(t.save(rgba: frame(lit: true), id: "felucca"))
        XCTAssertTrue(t.exists("felucca"))
        let again = FirmwareThumbs(directory: t.directory)
        let img = try XCTUnwrap(again.image("felucca"))
        XCTAssertEqual(img.width, 240)
        XCTAssertEqual(img.height, 240)
        XCTAssertTrue(t.url("rfm1:ab/c").lastPathComponent == "rfm1_ab_c.png")
        XCTAssertTrue(FirmwareThumbs.isBlank(frame(lit: false)))
        XCTAssertFalse(FirmwareThumbs.isBlank(frame(lit: true)))
    }

    func testCaptureTiming() {
        let t = FirmwareThumbs(directory: tempDir())
        let c = ThumbCapture(thumbs: t)
        XCTAssertFalse(c.frame(frame(lit: true), id: "fizz", booted: true, now: 100))
        XCTAssertFalse(c.frame(frame(lit: true), id: "fizz", booted: true, now: 102))
        XCTAssertFalse(c.frame(frame(lit: false), id: "fizz", booted: true, now: 103.5))   // black: retried
        XCTAssertTrue(c.frame(frame(lit: true), id: "fizz", booted: true, now: 104))
        XCTAssertFalse(c.frame(frame(lit: true), id: "fizz", booted: true, now: 105))        // once
        // another firmware, all black past the window: given up
        XCTAssertFalse(c.frame(frame(lit: false), id: "buzz", booted: true, now: 200))
        XCTAssertFalse(c.frame(frame(lit: false), id: "buzz", booted: true, now: 205))
        XCTAssertFalse(c.frame(frame(lit: true), id: "buzz", booted: true, now: 214))
        XCTAssertFalse(t.exists("buzz"))
        // existing: not taken again after a reboot
        XCTAssertFalse(c.frame(frame(lit: true), id: "fizz", booted: false, now: 300))
        XCTAssertFalse(c.frame(frame(lit: true), id: "fizz", booted: true, now: 301))
        XCTAssertFalse(c.frame(frame(lit: true), id: "fizz", booted: true, now: 305))
    }

    func testInfoLookup() {
        var core = CoreInfo(id: "felucca")
        core.name = "Felucca"
        core.version = "1.6.1"
        core.sourceURL = "https://example.org/felucca"
        core.credits = "Felucca by someone."
        var d = AvailableFirmware(id: "felucca")
        d.version = "1.6.1"
        d.author = "A. Author"
        d.summary = "An FM synth"
        d.about = "A long description."
        d.repo = "owner/felucca"
        d.sourceURL = "https://github.com/owner/felucca/tree/v1.6.1"
        var i = FirmwareInfo.lookup(core, details: ["felucca": d])
        XCTAssertEqual(i.tag, "An FM synth")
        XCTAssertEqual(i.about, "A long description.")
        XCTAssertEqual(i.author, "A. Author")
        XCTAssertEqual(i.source?.absoluteString, "https://github.com/owner/felucca/tree/v1.6.1")
        d.version = "1.7.0"   // another version: the repo
        i = FirmwareInfo.lookup(core, details: ["felucca": d])
        XCTAssertEqual(i.source?.absoluteString, "https://github.com/owner/felucca")
        // not in the catalog: the core's own (an imported file's by its firmware id)
        var imp = CoreInfo(id: "rfm1:abc")
        imp.coreID = "felucca"
        imp.name = "Felucca"
        XCTAssertEqual(FirmwareInfo.lookup(imp, details: ["felucca": d]).tag, "An FM synth")
        i = FirmwareInfo.lookup(core, details: [:])
        XCTAssertEqual(i.about, "Felucca by someone.")
        XCTAssertEqual(i.source?.absoluteString, "https://example.org/felucca")
        core.sourceURL = "javascript:alert(1)"
        XCTAssertNil(FirmwareInfo.lookup(core, details: [:]).source)
    }

    func testDetailsShare() {
        let dir = tempDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var d = AvailableFirmware(id: "x")
        d.about = "about"
        FirmwareDetailsShare.save(["x": d], dir: dir)
        XCTAssertEqual(FirmwareDetailsShare.load(dir: dir)["x"]?.about, "about")
    }
}
