// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The host's clock and transport as MIDI (RFMHostClock.h, PLAN.md section 11): the generator alone, buffer by buffer,
// as a host would call it (its beat from its own sample position and tempo).

import Foundation
import RFMCore
import XCTest

/// a host's transport over buffers: the beat at each buffer's start from its own position and tempo (not the
/// generator's), wrapped into the cycle when there is one
struct FakeHost {
    var rate = 48000.0
    var tempo = 120.0 {
        willSet { base = beat; anchorMoved = moved }
    }
    var moving = true
    var cycle: ClosedRange<Double>?
    var context = true, transport = true
    var c = rfmhc_t()
    var frame = 0                                   // the next buffer's first frame (absolute)
    private var base = 0.0, moved = 0, anchorMoved = 0
    private(set) var out: [(frame: Int, bytes: [UInt8])] = []

    init() { rfmhc_reset(&c) }

    /// the host's beat now (setting it: a relocate)
    var beat: Double {
        get {
            let b = base + Double(moved - anchorMoved) * tempo / 60 / rate
            guard let cycle, b >= cycle.upperBound else { return b }
            let len = cycle.upperBound - cycle.lowerBound
            return cycle.lowerBound + (b - cycle.lowerBound).truncatingRemainder(dividingBy: len)
        }
        set {
            base = newValue
            anchorMoved = moved
        }
    }

    var ticks: [Int] { out.filter { $0.bytes == [0xF8] }.map(\.frame) }
    var others: [(frame: Int, bytes: [UInt8])] { out.filter { $0.bytes != [0xF8] } }
    mutating func clear() { out = [] }

    /// one buffer of n frames; `beat` (the host's position) moves on by n frames at the tempo while moving
    mutating func run(_ n: Int, jitter: Double = 0) {
        var i = rfmhc_input_t()
        i.has_context = context ? 1 : 0
        i.has_transport = transport ? 1 : 0
        i.tempo = tempo
        i.beat = beat + jitter
        i.moving = moving ? 1 : 0
        if let cycle {
            i.cycling = 1
            i.cycle_start = cycle.lowerBound
            i.cycle_end = cycle.upperBound
        }
        i.sample_rate = rate
        i.frames = UInt32(n)
        var buf = [rfme_midi_t](repeating: rfme_midi_t(), count: 256)
        let k = Int(rfmhc_run(&c, &i, &buf, 256))
        var last = 0
        for m in buf.prefix(k) {
            XCTAssertLessThan(Int(m.offset), n, "an offset outside the buffer")
            XCTAssertGreaterThanOrEqual(Int(m.offset), last, "messages out of frame order")
            last = Int(m.offset)
            out.append((frame + Int(m.offset), Array([m.data.0, m.data.1, m.data.2].prefix(Int(m.len)))))
        }
        frame += n
        if moving { moved += n }
    }

    mutating func run(buffers: Int, of n: Int) { for _ in 0..<buffers { run(n) } }

    /// frames per tick at the tempo
    var tickFrames: Double { rate * 60 / tempo / 24 }
}

final class HostClockTests: XCTestCase {
    /// the frame of beat b when the transport started at frame 0 on beat b0
    private func frameOf(_ b: Double, from b0: Double = 0, _ h: FakeHost) -> Int {
        Int(((b - b0) * 24 * h.tickFrames - 1e-6).rounded(.up))
    }

    func testStartAtZero() {
        var h = FakeHost()
        h.run(512)
        XCTAssertEqual(h.out.first?.bytes, [0xFA])
        XCTAssertEqual(h.out.first?.frame, 0)
        XCTAssertEqual(h.ticks.first, 0, "the first clock at beat 0, with Start")
        XCTAssertEqual(h.others.count, 1, "only Start besides the clock")
    }

    /// 120 BPM at 48 kHz and 44.1 kHz in 64-, 512- and 4096-frame buffers: 24 ticks per beat exactly, each at its
    /// frame, none twice
    func testSteadyTempoGives24TicksPerBeat() {
        for rate in [48000.0, 44100.0] {
            for n in [64, 512, 4096] {
                var h = FakeHost()
                h.rate = rate
                let beats = 32
                let end = Int(Double(beats) * 24 * h.tickFrames)
                h.run(buffers: (end + n - 1) / n + 1, of: n)
                let t = h.ticks.filter { $0 < end }
                XCTAssertEqual(t.count, beats * 24, "\(rate) Hz, \(n)-frame buffers")
                for (k, f) in t.enumerated() where f != frameOf(Double(k) / 24, h) {
                    XCTFail("\(rate) Hz, \(n): tick \(k) at \(f), not \(frameOf(Double(k) / 24, h))")
                    break
                }
                XCTAssertEqual(Set(h.ticks).count, h.ticks.count, "a tick twice")
                XCTAssertEqual(h.others.map(\.bytes), [[0xFA]])
            }
        }
    }

    /// starting at beat 4.3: Song Position 18 (beat 4.5, the next sixteenth), Continue, then the clock from beat 4.5;
    /// on a sixteenth exactly (beat 8): Song Position 32
    func testStartMidSong() {
        var h = FakeHost()
        h.beat = 4.3
        h.run(buffers: 12, of: 512)
        XCTAssertEqual(h.others.map(\.bytes), [[0xF2, 18, 0], [0xFB]])
        XCTAssertEqual(h.others.map(\.frame), [0, 0])
        XCTAssertEqual(h.ticks.first, frameOf(4.5, from: 4.3, h))
        var g = FakeHost()
        g.beat = 8
        g.run(512)
        XCTAssertEqual(g.others.map(\.bytes), [[0xF2, 32, 0], [0xFB]])
        XCTAssertEqual(g.ticks.first, 0)
        var far = FakeHost()                            // (beat 300: 1200 sixteenths, both bytes)
        far.beat = 300
        far.run(64)
        XCTAssertEqual(far.others.first?.bytes, [0xF2, 0x30, 0x09])   // (1200 = 9 x 128 + 48)
    }

    /// stop: 0xFC at the stop buffer's first frame, nothing while stopped; playing again from there: Song Position
    /// and Continue
    func testStopAndContinue() {
        var h = FakeHost()
        h.run(buffers: 20, of: 512)
        h.clear()
        h.moving = false
        h.run(buffers: 10, of: 512)
        XCTAssertEqual(h.out.map(\.bytes), [[0xFC]])
        XCTAssertEqual(h.out.first?.frame, 20 * 512)
        h.clear()
        h.moving = true
        h.run(buffers: 2, of: 512)
        let stopped: Double = 20 * 512 * 2 / 48000.0
        let spp = Int(((stopped - 1.0 / 48) * 4).rounded(.up))     // (the next sixteenth)
        XCTAssertEqual(h.others.map(\.bytes), [[0xF2, UInt8(spp & 0x7F), UInt8(spp >> 7)], [0xFB]])
    }

    /// a relocate while playing: 0xFC, Song Position, Continue at the buffer's start, then the clock from there
    func testRelocate() {
        var h = FakeHost()
        h.run(buffers: 10, of: 512)
        h.clear()
        h.beat = 16
        h.run(buffers: 3, of: 512)
        XCTAssertEqual(h.others.map(\.bytes), [[0xFC], [0xF2, 64, 0], [0xFB]])
        XCTAssertEqual(h.others.map(\.frame), [10 * 512, 10 * 512, 10 * 512])
        XCTAssertEqual(h.ticks.first, 10 * 512)
        XCTAssertEqual(h.ticks.count, Int((Double(3 * 512) / h.tickFrames).rounded(.up)))
    }

    /// a 4-beat loop the host wraps at a buffer's start (its buffers end on the loop's end): each pass 96 ticks, then
    /// 0xFC, Song Position 0, Continue
    func testLoopWrapAtABufferEdge() {
        var h = FakeHost()
        h.cycle = 0...4
        let perLoop = Int(4 * 24 * h.tickFrames)        // 96000 frames: 187.5 buffers of 512; 1500 of 64
        h.run(buffers: 3 * perLoop / 64, of: 64)
        XCTAssertEqual(h.others.map(\.bytes), [[0xFA], [0xFC], [0xF2, 0, 0], [0xFB], [0xFC], [0xF2, 0, 0], [0xFB]])
        XCTAssertEqual(h.others.map(\.frame), [0, perLoop, perLoop, perLoop, 2 * perLoop, 2 * perLoop, 2 * perLoop])
        XCTAssertEqual(h.ticks.count, 3 * 96)
        XCTAssertEqual(h.ticks.filter { $0 >= perLoop && $0 < 2 * perLoop }.first, perLoop)
    }

    /// a 4-beat loop whose end falls inside a buffer (512-frame buffers): the wrap at its frame, 96 ticks per pass
    func testLoopWrapInsideABuffer() {
        var h = FakeHost()
        h.cycle = 0...4
        let perLoop = Int(4 * 24 * h.tickFrames)
        h.run(buffers: 3 * perLoop / 512, of: 512)
        let wraps = h.others.filter { $0.bytes == [0xFC] }.map(\.frame)
        XCTAssertEqual(wraps, [perLoop, 2 * perLoop])
        XCTAssertEqual(h.others.map(\.bytes), [[0xFA], [0xFC], [0xF2, 0, 0], [0xFB], [0xFC], [0xF2, 0, 0], [0xFB]])
        XCTAssertEqual(h.ticks.filter { $0 < 3 * perLoop }.count, 3 * 96)
        XCTAssertTrue(h.ticks.contains(perLoop) && h.ticks.contains(2 * perLoop), "beat 0 again at the wrap")
    }

    /// 120 BPM, then 90: 24 ticks per beat on both sides, the spacing following the tempo, none doubled or dropped
    func testTempoChange() {
        var h = FakeHost()
        h.run(buffers: 100, of: 480)                    // 48000 frames: 2 beats at 120
        let before = h.ticks.count
        XCTAssertEqual(before, 48)
        h.tempo = 90
        h.run(buffers: 200, of: 480)                    // 96000 frames: 3 beats at 90
        let all = h.ticks
        XCTAssertEqual(all.count, 48 + 72)
        let gaps = zip(all.dropFirst(), all).map { $0 - $1 }
        XCTAssertTrue(gaps.prefix(47).allSatisfy { $0 == 1000 }, "\(gaps.prefix(47))")
        XCTAssertTrue(gaps.suffix(71).allSatisfy { abs(Double($0) - 4000.0 / 3) < 1 }, "\(gaps.suffix(71))")
        XCTAssertEqual(h.others.map(\.bytes), [[0xFA]])
    }

    /// moving from beat -2 (a count-in): nothing until beat 0, then Start and the clock at beat 0's frame
    func testCountIn() {
        var h = FakeHost()
        h.beat = -2
        h.run(buffers: 200, of: 512)
        let zero = frameOf(2, h)
        XCTAssertEqual(h.others.map(\.bytes), [[0xFA]])
        XCTAssertEqual(h.others.first?.frame, zero)
        XCTAssertEqual(h.ticks.first, zero)
        XCTAssertFalse(h.out.contains { $0.frame < zero }, "a message during the count-in")
    }

    /// the host's beat a little off every buffer (± 0.2 of a tick): every tick once, in order
    func testJitteredPositionsNeitherDoubleNorDrop() {
        var h = FakeHost()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1000 { h.run(256, jitter: Double.random(in: -0.008...0.008, using: &rng)) }
        let beats = Double(1000 * 256) / (24 * h.tickFrames)
        XCTAssertEqual(Double(h.ticks.count), (beats * 24).rounded(.down), accuracy: 1)
        XCTAssertEqual(h.others.map(\.bytes), [[0xFA]], "a jitter taken for a jump")
        XCTAssertEqual(Set(h.ticks).count, h.ticks.count)
    }

    /// no tempo, no context or no transport: nothing at all; a host that has them again starts fresh
    func testNothingWithoutTheHostsContext() {
        for (ctx, tr, tempo) in [(false, true, 120.0), (true, false, 120.0), (true, true, 0.0)] {
            var h = FakeHost()
            h.context = ctx
            h.transport = tr
            h.tempo = tempo
            h.run(buffers: 50, of: 512)
            XCTAssertTrue(h.out.isEmpty, "context \(ctx), transport \(tr), tempo \(tempo)")
        }
        var h = FakeHost()
        h.run(buffers: 10, of: 512)
        h.context = false
        h.clear()
        h.run(buffers: 10, of: 512)
        XCTAssertTrue(h.out.isEmpty)
        h.context = true
        h.run(512)
        XCTAssertEqual(h.others.first?.bytes.first, 0xF2, "a running clock forgotten: Song Position and Continue")
    }
}
