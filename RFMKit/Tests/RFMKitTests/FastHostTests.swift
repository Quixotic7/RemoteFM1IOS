// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// A host that renders faster than real time without saying so (isRenderingOffline left off: Koala Sampler's resample,
// a tester's report): the engine notices and waits for the core thread as offline, so the recording has no gaps.

import Foundation
import RFMCore
import XCTest

final class FastHostTests: XCTestCase {
    private var cart: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/aout_cart.rfm1").path }

    func testAHostPullingFasterThanRealTimeGetsNoGaps() throws {
        let e = try XCTUnwrap(rfme_new(nil))
        defer { rfme_free(e) }
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(rfme_load_wasm(e, cart, &err, 512), 1, String(cString: err))
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))
        let n = 256
        var l = [Float](repeating: 0, count: n), r = l
        // real time first (the ring primed, as a host playing): 0.5 s at its pace
        for _ in 0..<(48000 / 2 / n) {
            _ = rfme_render_events(e, &l, &r, UInt32(n), 48000, nil, 0, nil, 0)
            Thread.sleep(forTimeInterval: Double(n) / 48000)
        }
        rfme_reset_render_stats(e)
        // then as fast as it can (a resample): 4 s of audio, no sleeps
        var silent = 0
        for _ in 0..<(48000 * 4 / n) {
            _ = rfme_render_events(e, &l, &r, UInt32(n), 48000, nil, 0, nil, 0)
            if l.contains(0) { silent += 1 }
        }
        var s = rfme_status_t()
        rfme_status(e, &s)
        print("fast host: \(s.underruns) underruns, \(s.underrun_frames) frames of silence, \(silent) buffers with a gap")
        XCTAssertEqual(s.underruns, 0, "a host faster than real time got gaps")
        XCTAssertEqual(silent, 0)
    }

    /// the same with a firmware that is barely faster than real time (Oberwave's preset 53 in Koala, 2026-11-07): the
    /// engine's own waits for the core made the renders look real time, it stopped waiting, and the recording broke up
    /// a few seconds in. The host's pace is measured without the engine's waits now
    func testAHeavyFirmwareInAFastHostGetsNoGaps() throws {
        let e = try XCTUnwrap(rfme_new(nil))
        defer { rfme_free(e) }
        rfme_test_frame_stall(e, 13_000)        // (each 15 ms of firmware time costs ~13 ms more: ~1.15x real time)
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(rfme_load_wasm(e, cart, &err, 512), 1, String(cString: err))
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))
        let n = 256
        var l = [Float](repeating: 0, count: n), r = l
        for _ in 0..<(48000 / 2 / n) {
            _ = rfme_render_events(e, &l, &r, UInt32(n), 48000, nil, 0, nil, 0)
            Thread.sleep(forTimeInterval: Double(n) / 48000)
        }
        rfme_reset_render_stats(e)
        var silent = 0
        for _ in 0..<(48000 * 4 / n) {
            _ = rfme_render_events(e, &l, &r, UInt32(n), 48000, nil, 0, nil, 0)
            if l.contains(0) { silent += 1 }
        }
        var s = rfme_status_t()
        rfme_status(e, &s)
        print("heavy firmware, fast host: \(s.underruns) underruns, \(silent) buffers with a gap")
        XCTAssertEqual(s.underruns, 0, "the engine stopped waiting for a heavy firmware")
        XCTAssertEqual(silent, 0)
    }

    /// a host playing at real time is never taken for a fast one (it would wait on the audio thread), with a heavy
    /// firmware too
    func testARealTimeHostIsNotTakenForAFastOne() throws {
        let e = try XCTUnwrap(rfme_new(nil))
        defer { rfme_free(e) }
        rfme_test_frame_stall(e, 9_000)
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(rfme_load_wasm(e, cart, &err, 512), 1, String(cString: err))
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))
        let n = 256
        var l = [Float](repeating: 0, count: n), r = l
        let period = Double(n) / 48000
        var next = Date()
        for _ in 0..<(48000 * 1 / n) {
            _ = rfme_render_events(e, &l, &r, UInt32(n), 48000, nil, 0, nil, 0)
            next += period
            Thread.sleep(until: next)
        }
        XCTAssertEqual(rfme_test_fast_renders(e), 0, "a real-time host taken for a fast one")
    }
}
