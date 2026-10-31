// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Makes the firmware list's shipped thumbnails (RFMKit/Sources/RFMKit/Resources/Thumbs/<id>.png): each firmware booted
// fresh, a chord of three white keys played, PLAY pressed, and its LCD taken a while later. Runs only when asked:
//   RFM_MAKE_THUMBS=1 RFM1_DIR=<folder of .rfm1 files> swift test --filter ThumbnailMaker
// The macOS builds of the native cores (CoreTests.coresDir) and every .rfm1 in RFM1_DIR (the id: the file name before
// its version). A frame that's blank is retried later, then skipped.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class ThumbnailMaker: XCTestCase {
    static var out: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/RFMKit/Resources/Thumbs").standardized
    }

    @MainActor func testMakeThumbnails() throws {
        guard ProcessInfo.processInfo.environment["RFM_MAKE_THUMBS"] == "1" else { throw XCTSkip("RFM_MAKE_THUMBS=1 makes them") }
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var made: [String] = []
        if FileManager.default.fileExists(atPath: CoreTests.coresDir) {
            rfms_scan(CoreTests.coresDir)
            for id in CoreTests.ids {
                let e = rfme_new(nil)!
                defer { rfme_free(e) }
                var err = [CChar](repeating: 0, count: 256)
                guard rfme_load(e, id, &err, 256) != 0 else { print("thumb \(id): not loaded: \(cstr(err))"); continue }
                if shoot(e, id: id) { made.append(id) }
            }
        }
        let dir = RFM1Files.dir
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() where name.hasSuffix(".rfm1") {
            guard let id = name.split(separator: "-").first.map(String.init), !made.contains(id) else { continue }
            let e = rfme_new(nil)!
            defer { rfme_free(e) }
            var err = [CChar](repeating: 0, count: 256)
            guard rfme_load_wasm(e, (dir as NSString).appendingPathComponent(name), &err, 256) == 1 else {
                print("thumb \(name): not loaded: \(cstr(err))")
                continue
            }
            if shoot(e, id: id) { made.append(id) }
        }
        print("thumbs made: \(made.sorted()) in \(Self.out.path)")
    }

    /// boot, wait, a chord of white keys (F3 A3 C4: keys 0, 4, 7), PLAY, then the LCD; true when a frame was kept
    @MainActor private func shoot(_ e: OpaquePointer, id: String) -> Bool {
        _ = rfme_boot(e, nil, 0)
        rfme_set_clock(e, Int32(RFME_CLOCK_CALLER))
        var a = rfme_audio_t()
        rfme_run_ms(e, 2500, &a)
        let chord = [0, 4, 7]
        for k in chord { _ = rfme_event(e, UInt8(RFMC_EV_KEY), UInt8(k), 1) }
        rfme_run_ms(e, 600, &a)
        for k in chord { _ = rfme_event(e, UInt8(RFMC_EV_KEY), UInt8(k), 0) }
        rfme_run_ms(e, 200, &a)
        let play = rfme_matrix_button(e, Int32(RFME_B_PLAY))
        if play >= 0 {
            _ = rfme_event(e, UInt8(RFMC_EV_BUTTON), UInt8(play), 1)
            rfme_run_ms(e, 120, &a)
            _ = rfme_event(e, UInt8(RFMC_EV_BUTTON), UInt8(play), 0)
        }
        let thumbs = FirmwareThumbs(directory: Self.out)
        var rgba = [UInt8](repeating: 0, count: 240 * 240 * 4)
        for _ in 0..<6 {
            rfme_run_ms(e, 1500, &a)
            _ = rgba.withUnsafeMutableBufferPointer { rfme_preview(e, 0, $0.baseAddress) }
            if thumbs.save(rgba: rgba, id: id) { print("thumb \(id): kept"); return true }
        }
        print("thumb \(id): blank, skipped")
        return false
    }

    /// every built-in core and every released .rfm1 ships a picture
    @MainActor func testShippedThumbnails() {
        for id in CoreTests.ids + ["amb", "coralflower", "duell", "fimba", "fmini", "fomni", "ghoulbox", "jiant", "minitone",
                                   "pigeon", "purplemonkey", "s1vave", "skiff", "speak37"] {
            XCTAssertNotNil(FirmwareThumbs.shipped(id), "\(id) has no shipped thumbnail")
        }
        let t = FirmwareThumbs(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertTrue(t.exists("fizz"), "a shipped one counts: no capture over it")
        XCTAssertNotNil(t.image("fizz"))
        XCTAssertFalse(t.exists("nonesuch"))
    }
}
