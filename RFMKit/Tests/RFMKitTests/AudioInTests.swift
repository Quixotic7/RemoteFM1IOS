// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// ain1, live audio input for an .rfm1 (RemoteFM1 web/engine/API.md section 6), through the engine: the manifest's
// "wants", the input ring, rfm1_audio_in_info / rfm1_audio_in before rfm1_audio. Fixtures/ain_cart.rfm1 (RemoteFM1's
// web/engines/rfm1/fixtures, source ain_cart.c beside it) plays its input back: its output is the input.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class AudioInTests: XCTestCase {
    private var path: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ain_cart.rfm1").path }

    private func tone(_ frames: Int, amp: Double = 0.5) -> [Int16] {
        var s: [Int16] = []
        s.reserveCapacity(frames * 2)
        for i in 0..<frames {
            let v = Int16(amp * 32767 * sin(Double(i) * 2 * .pi * 441 / 44100))
            s += [v, v]
        }
        return s
    }

    func testTheManifestSaysItWantsInput() {
        var info = rfmw_info_t()
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(rfmw_check(path, &info, &err, 512), 1, String(cString: err))
        XCTAssertEqual(info.audio_in, 1, "wants")
    }

    func testInputComesThroughOnlyWhileLive() throws {
        let c = try WasmTestCore(path)
        c.boot()
        XCTAssertEqual(rfme_ain_mode(c.e), 1)
        c.run(200)
        XCTAssertEqual(c.run(200).peak, 0, "off: silence")
        let lcdOff = c.lcd

        rfme_ain_set(c.e, 1, 1234, 256)
        let t = tone(44100)
        var sound = rfme_audio_t()
        for k in 0..<20 {                                   // 20 x 50 ms of input, the core taking it as it runs
            t[(k * 2205 * 2)..<((k + 1) * 2205 * 2)].withUnsafeBufferPointer { rfme_ain_push(c.e, $0.baseAddress, 2205) }
            sound = c.run(50)
        }
        XCTAssertGreaterThan(sound.rms, 0.2, "live: the cart plays its input back")
        XCTAssertNotEqual(c.lcd, lcdOff, "its screen: green while live")
        var short: UInt32 = 0, dropped: UInt32 = 0
        rfme_ain_stats(c.e, &short, &dropped)
        XCTAssertEqual(dropped, 0)

        rfme_ain_set(c.e, 0, 0, 0)
        c.run(100)
        XCTAssertEqual(c.run(100).peak, 0, "off again: silence")
    }

    func testNeedsAin1IsKnown() throws {
        // (a manifest needing ain1 isn't refused as "needs a newer RemoteFM1": KNOWN_NEEDS has it)
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/RFMKitTests/AudioInTests.swift",
                                                                           with: "Sources/RFMCore/RFMWasmCore.cpp"), encoding: .utf8)
        XCTAssertTrue(src.contains(#"KNOWN_NEEDS[] = {"fs1", "ain1"}"#))
    }
}
