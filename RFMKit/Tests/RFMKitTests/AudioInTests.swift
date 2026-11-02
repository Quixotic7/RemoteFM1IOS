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

    func testFloatInputIsResampledTo44k() throws {
        let c = try WasmTestCore(path)
        c.boot()
        rfme_ain_set(c.e, 1, 0, 256)
        // 48 kHz mono, 1 s, in 480-frame buffers: about 44100 frames reach the ring, the tone's level kept
        var phase = 0.0
        var got = rfme_audio_t()
        for k in 0..<100 {
            var buf = [Float](repeating: 0, count: 480)
            for i in 0..<480 { buf[i] = Float(0.5 * sin(phase)); phase += 2 * .pi * 441 / 48000 }
            buf.withUnsafeBufferPointer { rfme_ain_push_f32(c.e, $0.baseAddress, nil, 480, 48000) }
            if k % 2 == 1 { got = c.run(20) }
        }
        XCTAssertGreaterThan(got.rms, 0.3, "a 0.5 sine: RMS about 0.35")
        XCTAssertLessThan(got.rms, 0.4)
        var short: UInt32 = 0, dropped: UInt32 = 0
        rfme_ain_stats(c.e, &short, &dropped)
        XCTAssertEqual(dropped, 0)
    }

    /// Elasticat 0.4.0 (FM1VST's elasticat worktree; skipped when absent): loads, says it takes input, boots, and
    /// sounds with a tone in
    func testElasticat() throws {
        let p = "/Volumes/Q7Media-2025/Projects/Github/ChoralRootFM1/FM1VST/.claude/worktrees/elasticat/build-rfm1/rfm1/elasticat-0.4.0.rfm1"
        guard FileManager.default.fileExists(atPath: p) else { throw XCTSkip("no elasticat-0.4.0.rfm1") }
        var info = rfmw_info_t()
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(rfmw_check(p, &info, &err, 512), 1, String(cString: err))
        XCTAssertGreaterThan(info.audio_in, 0)
        let c = try WasmTestCore(p)
        c.boot()
        XCTAssertGreaterThan(rfme_ain_mode(c.e), 0)
        rfme_ain_set(c.e, 1, 2000, 512)
        let t = tone(44100)
        for k in 0..<20 {
            t[(k * 2205 * 2)..<((k + 1) * 2205 * 2)].withUnsafeBufferPointer { rfme_ain_push(c.e, $0.baseAddress, 2205) }
            c.run(50)
        }
        XCTAssertEqual(c.status.halted, 0, "running")
        print("elasticat: audio_in \(info.audio_in), mode \(rfme_ain_mode(c.e))")
    }

    /// the AU: the music effect variant has one stereo input bus, the instrument none
    func testTheEffectVariantHasAnInput() throws {
        var c = RFMAudioUnit.Config()
        c.runProbes = false
        c.link = .none
        c.defaultCore = nil
        let fx = try RFMAudioUnit(componentDescription: RFMShared.effectComponent, options: [], config: c)
        XCTAssertTrue(fx.isEffect)
        XCTAssertEqual(fx.inputBusses.count, 1)
        XCTAssertEqual(fx.inputBusses[0].format.channelCount, 2)
        let inst = try RFMAudioUnit(componentDescription: RFMShared.component, options: [], config: c)
        XCTAssertFalse(inst.isEffect)
        XCTAssertEqual(inst.inputBusses.count, 0)
    }
}
