// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// aout1, more output channels (docs/RFM1-FORMAT.md section 9), through the engine's audio clock as the AU renders:
// Fixtures/aout_cart.rfm1 (aout_cart.c) gives ten channels, each its own level (the master 1000 / 2000, channel c
// c x 1000), so every channel's place is checked; at 44.1 kHz (as made) and 48 kHz (resampled together). A cart
// without the exports plays the master and silence on 3..10.

import Foundation
import RFMCore
import AVFoundation
import XCTest
@testable import RFMKit

final class AudioOutTests: XCTestCase {
    private var cart: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/aout_cart.rfm1").path }
    private var plain: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ain_cart.rfm1").path }

    /// one engine on the audio clock, offline (each render waits for the core thread)
    private func engine(_ path: String) throws -> OpaquePointer {
        let e = try XCTUnwrap(rfme_new(nil))
        var err = [CChar](repeating: 0, count: 512)
        guard rfme_load_wasm(e, path, &err, 512) != 0 else {
            rfme_free(e)
            throw NSError(domain: "wasm", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: err)])
        }
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))
        rfme_set_offline(e, 1)
        return e
    }

    /// renders `blocks` host buffers of n frames; the last buffer's ten channels
    private func render(_ e: OpaquePointer, rate: Double, n: Int = 256, blocks: Int = 40) -> [[Float]] {
        var ch = [[Float]](repeating: [Float](repeating: 0, count: n), count: 10)
        for _ in 0..<blocks {
            var l = [Float](repeating: 0, count: n), r = l
            var aux = (0..<8).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
            defer { aux.forEach { $0.deallocate() } }
            for p in aux { p.initialize(repeating: -1, count: n) }
            var ptrs: [UnsafeMutablePointer<Float>?] = aux
            _ = ptrs.withUnsafeMutableBufferPointer { b in
                rfme_render_events_aux(e, &l, &r, b.baseAddress, 8, UInt32(n), rate, nil, 0, nil, 0)
            }
            ch[0] = l
            ch[1] = r
            for c in 0..<8 { ch[2 + c] = Array(UnsafeBufferPointer(start: aux[c], count: n)) }
        }
        return ch
    }

    private func level(_ x: [Float]) -> Int { Int((x[x.count / 2] * 32768).rounded()) }

    func testTenChannelsEachInItsPlace() throws {
        for rate in [44100.0, 48000.0] {
            let e = try engine(cart)
            defer { rfme_free(e) }
            XCTAssertEqual(rfme_audio_out_channels(e), 10)
            let ch = render(e, rate: rate)
            XCTAssertEqual(level(ch[0]), 1000, "\(rate): the master's left (-1000: the cart saw a wrong call)")
            XCTAssertEqual(level(ch[1]), 2000, "\(rate): the master's right")
            for c in 0..<8 { XCTAssertEqual(level(ch[2 + c]), (c + 3) * 1000, "\(rate): channel \(c + 3)") }
        }
    }

    func testFewerChannelsAskedOrAPlainCart() throws {
        let e = try engine(cart)
        defer { rfme_free(e) }
        var l = [Float](repeating: 0, count: 256), r = l
        for _ in 0..<40 { _ = rfme_render_events(e, &l, &r, 256, 48000, nil, 0, nil, 0) }   // (stereo only: the AU's bus 1)
        XCTAssertEqual(Int((l[128] * 32768).rounded()), 1000)

        let p = try engine(plain)                              // (ain_cart: no aout1 exports)
        defer { rfme_free(p) }
        XCTAssertEqual(rfme_audio_out_channels(p), 2)
        let ch = render(p, rate: 48000)
        for c in 2..<10 { XCTAssertEqual(ch[c].map(abs).max(), 0, "channel \(c + 1): silent") }
    }
}

/// the AU's five stereo outputs: one cycle made once, each bus its pair (Main 1-2 the master, Out 3-4 .. 9-10)
final class AUOutputBusTests: XCTestCase {
    private var cart: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/aout_cart.rfm1").path }

    func testEachBusGetsItsPair() throws {
        var c = RFMAudioUnit.Config()
        c.runProbes = false
        c.link = .none
        c.defaultCore = nil
        let au = try RFMAudioUnit(componentDescription: RFMShared.component, options: [], config: c)
        XCTAssertEqual(au.outputBusses.count, 5)
        XCTAssertEqual((0..<5).map { au.outputBusses[$0].name }, ["Main 1-2", "Out 3-4", "Out 5-6", "Out 7-8", "Out 9-10"])
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(rfme_load_wasm(au.e, cart, &err, 512), 1, String(cString: err))
        XCTAssertEqual(rfme_boot(au.e, nil, 0), 1)
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }
        rfme_set_offline(au.e, 1)
        let block = au.internalRenderBlock
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer { abl.unsafeMutablePointer.deallocate() }
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mFlags = .sampleTimeValid
        var levels: [[Int]] = []
        for cycle in 0..<40 {                                   // (the ring primed; the last cycle read)
            ts.mSampleTime = Double(cycle * 256)
            levels = []
            for bus in (0..<5).reversed() {                     // (any order: the first call of a cycle makes it)
                for i in 0..<2 { abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil) }
                XCTAssertEqual(block(&flags, &ts, 256, bus, abl.unsafeMutablePointer, nil, nil), noErr)
                let l = abl[0].mData!.assumingMemoryBound(to: Float.self), r = abl[1].mData!.assumingMemoryBound(to: Float.self)
                levels.insert([Int((l[128] * 32768).rounded()), Int((r[128] * 32768).rounded())], at: 0)
            }
        }
        XCTAssertEqual(levels, [[1000, 2000], [3000, 4000], [5000, 6000], [7000, 8000], [9000, 10000]])
        XCTAssertEqual(au.probe.report(write: false).render?.renders, 40, "one render a cycle, not one a bus")
    }
}
