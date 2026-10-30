// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// M7 on the Mac: the core off the audio thread (RFMEngine.h, render ahead). A test thread stands in for the audio
// callback: a Mach real-time thread calling rfme_render_midi every buffer's duration by the wall clock, as CoreAudio
// would. The core's frame() is made slower on purpose (rfme_test_frame_stall: a busy wait, as an interpreted
// firmware's screen redraw), below and above the ring's headroom; host MIDI lands at its frame + the latency; core
// switches and power cycles under the running callback neither deadlock nor leak the core thread. The macOS core
// builds as in CoreTests (skipped without them).

import Darwin
import Foundation
import RFMCore
import XCTest
@testable import RFMKit

/// a real-time stand-in for an audio callback: `count` renders of `frames` at `rate`, paced by the wall clock
final class CallbackDriver: @unchecked Sendable {
    let e: OpaquePointer
    let frames: Int, rate: Double
    private(set) var out: [Float]             // the left channel of every render, back to back (`record`)
    private var events: [Int: (offset: UInt32, bytes: [UInt8])] = [:]
    private let lock = NSLock()
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)
    private var stopFlag = false
    private(set) var lateCallbacks = 0         // renders the driver itself started a buffer late (the Mac was busy)
    private(set) var midiOut: [(frame: Int, pkt: UInt32)] = []   // the core's MIDI out (rfme_midi_out_take_at)
    let record: Bool

    init(_ e: OpaquePointer, frames: Int = 128, rate: Double = 48000, record: Bool = false) {
        self.e = e
        self.frames = frames
        self.rate = rate
        self.record = record
        out = []
    }

    /// a host MIDI message at frame `offset` of render number `at`
    func event(at: Int, offset: UInt32, _ bytes: [UInt8]) { lock.withLock { events[at] = (offset, bytes) } }

    var stopped: Bool { lock.withLock { stopFlag } }

    /// starts the renders; `count` nil: until stop()
    func start(count: Int?) {
        if record, let count { out = [Float](repeating: 0, count: count * frames) }
        let t = Thread { [self] in run(count) }
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.withLock { stopFlag = true }
        done.wait()
    }

    func wait() { done.wait() }

    private func run(_ count: Int?) {
        let period = Double(frames) / rate
        _ = rfme_test_realtime(period)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = UInt64(period * 1e9 * Double(tb.denom) / Double(tb.numer))
        var L = [Float](repeating: 0, count: frames), R = [Float](repeating: 0, count: frames)
        var ev = [rfme_midi_t](repeating: rfme_midi_t(), count: 1)
        let evs = lock.withLock { events }
        let t0 = mach_absolute_time()
        midiOut.reserveCapacity(4096)
        var i = 0
        while count.map({ i < $0 }) ?? true {
            if i & 63 == 0 && stopped { break }
            let due = t0 + UInt64(i) * ticks
            let now = mach_absolute_time()
            if now < due { mach_wait_until(due) } else if now > due + ticks { lateCallbacks += 1 }
            var nev: UInt32 = 0
            if let m = evs[i] {
                ev[0].offset = m.offset
                ev[0].len = UInt8(m.bytes.count)
                ev[0].data = (m.bytes[0], m.bytes.count > 1 ? m.bytes[1] : 0, m.bytes.count > 2 ? m.bytes[2] : 0)
                nev = 1
            }
            L.withUnsafeMutableBufferPointer { l in
                R.withUnsafeMutableBufferPointer { r in
                    ev.withUnsafeBufferPointer { p in
                        _ = rfme_render_midi(e, l.baseAddress, r.baseAddress, UInt32(frames), rate, p.baseAddress, nev)
                    }
                }
            }
            var pkt: UInt32 = 0, off: UInt32 = 0
            while rfme_midi_out_take_at(e, &pkt, &off) != 0 {
                if midiOut.count < 4096 { midiOut.append((i * frames + Int(off), pkt)) }
            }
            if record && i * frames + frames <= out.count {
                out.withUnsafeMutableBufferPointer { o in
                    for k in 0..<frames { o[i * frames + k] = L[k] }
                }
            }
            i += 1
        }
        done.signal()
    }
}

final class RenderAheadTests: XCTestCase {
    override func setUpWithError() throws {
        let dir = CoreTests.coresDir
        guard FileManager.default.fileExists(atPath: dir) else {
            throw XCTSkip("no macOS core builds in \(dir): run scripts/build_cores.sh macos")
        }
        _ = rfms_scan(dir)
    }

    /// an engine with `core` booted (fresh flash) on the audio clock, frame() slowed by `stallUs`
    private func engine(_ core: String = "felucca", stallUs: UInt32 = 0, headroomUs: UInt32? = nil) throws -> OpaquePointer {
        let e = rfme_new(nil)!
        rfme_test_frame_stall(e, stallUs)
        if let headroomUs { rfme_set_latency(e, headroomUs, 0) }
        var err = [CChar](repeating: 0, count: 256)
        guard rfme_load(e, core, &err, 256) != 0 else {
            rfme_free(e)
            throw NSError(domain: "core", code: 1, userInfo: [NSLocalizedDescriptionKey: cstr(err)])
        }
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))
        return e
    }

    private func status(_ e: OpaquePointer) -> CoreStatus { CorePlayer.status(e) }

    private func describe(_ s: CoreStatus) -> String {
        String(format: "latency %u frames, target %u, ring min %u; callback avg %u us, max %u us; core thread %u us avg, "
               + "%u max per render (%u%%), frame() max %u us; %u underruns (%u frames); rt %d, workgroup %d",
               s.latencyFrames, s.ringTarget, s.ringFillMin, s.renderAvgUs, s.renderMaxUs, s.coreAvgUs, s.coreMaxUs,
               s.coreLoadPct, s.frameMaxUs, s.underruns, s.underrunFrames, s.realtime ? 1 : 0, s.workgroup ? 1 : 0)
    }

    /// frame() 3 ms slower every 15 ms (the ring's headroom is 6 ms beyond the 128-frame buffer): 10 s of 128-frame
    /// callbacks at 48 kHz without a single underrun; the callback itself stays tiny
    func testStallBelowTheHeadroomNeverUnderruns() throws {
        let e = try engine(stallUs: 3000)
        defer { rfme_free(e) }
        let warm = CallbackDriver(e)
        warm.start(count: 375)                          // (1 s: the boot, the ring primed)
        warm.wait()
        rfme_reset_render_stats(e)
        let d = CallbackDriver(e)
        d.start(count: 3750)                            // 10 s
        d.wait()
        let s = status(e)
        print("stall 3 ms, 10 s: \(describe(s)); the driver late \(d.lateCallbacks) times")
        XCTAssertGreaterThan(s.latencyFrames, 0)
        XCTAssertGreaterThanOrEqual(s.frameMaxUs, 3000, "the stall did not happen")
        XCTAssertEqual(s.renders, 3750)
        XCTAssertEqual(s.underruns, 0, "underruns with a stall below the headroom")
        XCTAssertGreaterThan(s.ringFillMin, 0)
        XCTAssertLessThan(s.renderAvgUs, 100, "the callback should only copy")
        XCTAssertTrue(s.realtime)
    }

    /// frame() 12 ms slower (more than the ring holds): underruns are counted, nothing hangs, the engine goes away
    func testStallAboveTheHeadroomCountsUnderruns() throws {
        let e = try engine(stallUs: 12000)
        let d = CallbackDriver(e)
        d.start(count: 750)                             // 2 s
        d.wait()
        let s = status(e)
        print("stall 12 ms, 2 s: \(describe(s))")
        XCTAssertGreaterThan(s.underruns, 0)
        XCTAssertGreaterThan(s.underrunFrames, 0)
        XCTAssertEqual(s.renders, 750)
        XCTAssertGreaterThanOrEqual(s.frameMaxUs, 12000)
        let t0 = Date()
        rfme_free(e)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "rfme_free waited too long for the core thread")
    }

    /// host MIDI at frame `offset` of a render sounds `latency` frames after that frame (plus the device's own block
    /// and the firmware's response, the same in every run); a longer headroom delays it by exactly the difference.
    /// At 44.1 kHz, so device frames are host frames.
    func testHostMIDISoundsAtItsFramePlusTheLatency() throws {
        let rate = 44100.0, at = 400, offset: UInt32 = 37
        let due = at * 128 + Int(offset)
        var delays: [(latency: Int, delay: Int)] = []
        for head: UInt32 in [6000, 20500] {
            let e = try engine("felucca", headroomUs: head)
            let d = CallbackDriver(e, frames: 128, rate: rate, record: true)
            d.event(at: at, offset: offset, [0x90, 62, 110])
            d.start(count: at + 200)
            d.wait()
            let s = status(e)
            rfme_free(e)
            let onset = d.out.indices.first { $0 >= at * 128 && abs(d.out[$0]) > 1e-4 }
            let silentBefore = d.out[(at - 100) * 128..<(at * 128)].allSatisfy { abs($0) <= 1e-4 }
            XCTAssertTrue(silentBefore, "Felucca not silent before the note")
            let o = try XCTUnwrap(onset, "no sound after the note")
            print("headroom \(head) us: latency \(s.latencyFrames) frames; note due at \(due), sound from \(o): "
                  + "\(o - due) frames later; \(s.underruns) underruns")
            XCTAssertEqual(s.underruns, 0)
            delays.append((Int(s.latencyFrames), o - due))
        }
        for (l, dl) in delays {
            XCTAssertGreaterThanOrEqual(dl, l, "a note sounded before its latency")
            XCTAssertLessThan(dl - l, 128 + 2 * 44, "more than a device block and 2 ms after its latency")
        }
        let extra = (delays[1].delay - delays[0].delay) - (delays[1].latency - delays[0].latency)
        XCTAssertLessThanOrEqual(abs(extra), 128, "the delay did not follow the latency (off by \(extra) frames)")
    }

    /// the core's MIDI out keeps its place in the stream: a key played by host MIDI comes out of the firmware as a
    /// note at the same frame as its sound starts (both a latency after the host's note), give or take a device block
    func testMIDIOutKeepsItsFrame() throws {
        let rate = 44100.0, at = 400, offset: UInt32 = 50
        var found = false
        for core in ["felucca", "choralroot", "melodee", "saadet"] {
            let e = try engine(core)
            rfme_midi_out_enable(e, 1)
            rfme_set_midi(e, 0, 0, 0, 1)
            let d = CallbackDriver(e, frames: 128, rate: rate, record: true)
            d.event(at: at, offset: offset, [0x90, 62, 110])
            d.start(count: at + 200)
            d.wait()
            let lat = Int(status(e).latencyFrames)
            rfme_free(e)
            let due = at * 128 + Int(offset)
            // a note on (USB-MIDI CIN 9, velocity > 0) after the host's note
            guard let note = d.midiOut.first(where: { $0.frame >= at * 128 && $0.pkt & 0xF == 9 && ($0.pkt >> 24) & 0x7F > 0 }),
                  let onset = d.out.indices.first(where: { $0 >= at * 128 && abs(d.out[$0]) > 1e-4 }) else {
                print("\(core): no MIDI note out (\(d.midiOut.count) packets) or no sound")
                continue
            }
            print("\(core): host note due \(due); MIDI out note at +\(note.frame - due), sound at +\(onset - due); latency \(lat)")
            XCTAssertGreaterThanOrEqual(note.frame - due, lat - 128, core)
            XCTAssertLessThanOrEqual(abs(note.frame - onset), 2 * 128, "\(core): the MIDI out and the sound apart")
            found = true
        }
        if !found { throw XCTSkip("no core sends its played notes to MIDI out") }
    }

    /// under a running callback: other cores, power cycles, the timer clock and back, a flash save; no deadlock
    /// (each step under a watchdog), sound at the end, and the core thread gone after rfme_free
    func testSwitchingCoresAndPowerCyclesUnderTheCallback() throws {
        let threads0 = rfme_test_core_threads()
        let e = try engine("felucca")
        let d = CallbackDriver(e)
        d.start(count: nil)
        let steps = ["choralroot", "power", "fizz", "timer", "audio", "flash", "power", "felucca", "loom", "felucca"]
        let ok = expectation(description: "steps")
        let log = Locked<[String]>([])
        DispatchQueue.global().async {
            var err = [CChar](repeating: 0, count: 256)
            for st in steps {
                let t0 = Date()
                switch st {
                case "power":
                    _ = rfme_power_cycle(e, &err, 256)
                case "timer":
                    rfme_set_clock(e, Int32(RFME_CLOCK_TIMER))
                case "audio":
                    rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))
                case "flash":
                    var buf = [UInt8](repeating: 0, count: Int(rfme_flash_size(e)))
                    _ = rfme_final_flash(e, &buf, UInt32(buf.count))
                default:
                    _ = rfme_load(e, st, &err, 256)
                    _ = rfme_boot(e, nil, 0)
                }
                log.value.append("\(st) \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                Thread.sleep(forTimeInterval: 0.25)
            }
            ok.fulfill()
        }
        wait(for: [ok], timeout: 30)
        print("switches under the callback: \(log.value.joined(separator: ", "))")
        let mid = status(e)
        XCTAssertEqual(mid.coreID, "felucca")
        XCTAssertTrue(mid.booted)
        XCTAssertEqual(mid.clock, Int(RFME_CLOCK_AUDIO))
        d.stop()
        XCTAssertEqual(rfme_test_core_threads(), threads0 + 1)

        // still playing: a note after the switches
        let p = CallbackDriver(e, record: true)
        p.event(at: 200, offset: 0, [0x90, 62, 110])
        p.start(count: 500)
        p.wait()
        let peak = p.out[(200 * 128)...].map { abs($0) }.max() ?? 0
        print("after the switches: peak \(peak); \(describe(status(e)))")
        XCTAssertGreaterThan(peak, 0.002, "no sound after the switches")
        let t0 = Date()
        rfme_free(e)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        XCTAssertEqual(rfme_test_core_threads(), threads0, "the core thread outlived its engine")
    }

    /// the latency the AU reports before its first render, and what the engine settles on
    func testLatencyBeforeAndAfterTheFirstRender() throws {
        let e = try engine("felucca")
        defer { rfme_free(e) }
        let before = rfme_latency(e, 48000, 128)
        XCTAssertEqual(before, 448 + 64)                // 128 + 6 ms (288) in whole 64-frame chunks, + a chunk
        let d = CallbackDriver(e)
        d.start(count: 100)
        d.wait()
        XCTAssertEqual(rfme_latency(e, 48000, 4096), 512, "after renders: the one it has")
        XCTAssertEqual(status(e).ringTarget, 448)
    }
}
