// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AU's MIDI end to end on the Mac (PLAN.md section 11), through the real render block, with a test core that
// echoes its MIDI in to its MIDI out (rfme_test_load_echo): the AU's switches reaching the firmware, the host's clock
// and transport (from the AU's musicalContextBlock and transportStateBlock) arriving as MIDI, and the core's MIDI
// out reaching the AU's MIDI output block with its sample time and length. Offline renders (the core thread waited
// for), 44.1 kHz. Needs no core builds.

import AVFoundation
import AudioToolbox
import Foundation
import RFMCore
import XCTest
@testable import RFMKit

/// the host's side: its transport and tempo (read by the AU's blocks on the render thread, here the test's)
final class HostSim: @unchecked Sendable {
    var tempo = 120.0, moving = true, rate = 44100.0
    var startBeat = 0.0, startSample = 0.0
    var sample = 0.0                                // the buffer being rendered
    var beat: Double { moving ? startBeat + (sample - startSample) * tempo / 60 / rate : startBeat }
}

/// what the AU's MIDI output block received
final class OutLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(time: Int, bytes: [UInt8])] = []
    func add(_ t: AUEventSampleTime, _ b: [UInt8]) { lock.withLock { list.append((Int(t), b)) } }
    var items: [(time: Int, bytes: [UInt8])] { lock.withLock { list } }
    func clear() { lock.withLock { list = [] } }
}

final class AUMidiTests: XCTestCase {
    private let frames = 512
    private let block = 128                         // a device block: how far a core's MIDI out may trail its input

    /// an AU playing the echo core, its MIDI output logged; host blocks when `host` is given
    private func makeAU(host: HostSim?, settings: AUSettings = AUSettings()) throws -> (RFMAudioUnit, OutLog) {
        var c = RFMAudioUnit.Config()
        c.runProbes = false
        c.link = .none
        c.defaultCore = nil
        let au = try RFMAudioUnit(componentDescription: RFMShared.component, options: [], config: c)
        au.maximumFramesToRender = 4096
        au.isRenderingOffline = true
        au.settings = settings
        let log = OutLog()
        au.midiOutputEventBlock = { t, _, n, bytes in
            log.add(t, Array(UnsafeBufferPointer(start: bytes, count: n)))
            return noErr
        }
        if let host {
            au.musicalContextBlock = { tempo, _, _, beat, _, _ in
                tempo?.pointee = host.tempo
                beat?.pointee = host.beat
                return true
            }
            au.transportStateBlock = { flags, pos, _, _ in
                flags?.pointee = host.moving ? .moving : []
                pos?.pointee = host.sample
                return true
            }
        }
        try au.allocateRenderResources()
        addTeardownBlock { au.deallocateRenderResources() }
        XCTAssertEqual(rfme_test_load_echo(au.e), 1)
        XCTAssertEqual(rfme_boot(au.e, nil, 0), 1)
        return (au, log)
    }

    /// `count` renders from sample time `start`, with host MIDI at absolute sample times
    private func render(_ au: RFMAudioUnit, host: HostSim? = nil, count: Int, frames n: Int? = nil, from start: Int = 0,
                        events: [(time: Int, bytes: [UInt8])] = []) {
        let n = n ?? frames
        let rb = au.internalRenderBlock
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        let evs = UnsafeMutablePointer<AURenderEvent>.allocate(capacity: 64)
        defer { abl.unsafeMutablePointer.deallocate(); evs.deallocate() }
        for i in 0..<count {
            let t0 = start + i * n
            host?.sample = Double(t0)
            let mine = events.filter { $0.time >= t0 && $0.time < t0 + n }
            for (j, m) in mine.enumerated() {
                let b = m.bytes
                let e = AUMIDIEvent(next: j + 1 < mine.count ? evs + j + 1 : nil, eventSampleTime: AUEventSampleTime(m.time),
                                    eventType: .MIDI, reserved: 0, length: UInt16(b.count), cable: 0,
                                    data: (b[0], b.count > 1 ? b[1] : 0, b.count > 2 ? b[2] : 0))
                evs[j] = AURenderEvent(MIDI: e)
            }
            for c in 0..<2 { abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil) }
            var flags = AudioUnitRenderActionFlags()
            var ts = AudioTimeStamp()
            ts.mFlags = .sampleTimeValid
            ts.mSampleTime = Double(t0)
            XCTAssertEqual(rb(&flags, &ts, AUAudioFrameCount(n), 0, abl.unsafeMutablePointer, mine.isEmpty ? nil : evs, nil), noErr)
        }
    }

    private func latency(_ au: RFMAudioUnit) -> Int { Int(au.status().core.latencyFrames) }

    // MARK: the switches

    func testSettingsDefaultsAndState() {
        let d = AUSettings()
        XCTAssertEqual(d.keyChannel, .any)
        XCTAssertEqual(d.transpose, 0)
        XCTAssertFalse(d.keyNotesToFirmware)
        XCTAssertTrue(d.useLearnedMap)
        XCTAssertTrue(d.hostClock)
        XCTAssertEqual(AUSettings([:]), d, "a state without the keys: the defaults")
        XCTAssertEqual(AUSettings(["notesPlayKeys": true, "transpose": 0, "keyNotesToFirmware": false]), d,
                       "a state from before the host clock: on")
        XCTAssertEqual(AUSettings(["notesPlayKeys": false]).keyChannel, .off, "an old \"notes play keys\" off")
        XCTAssertEqual(AUSettings(["notesPlayKeys": true]).keyChannel, .any)
        XCTAssertEqual(AUSettings(["keyChannel": 10, "notesPlayKeys": true]).keyChannel, .channel(10))
        XCTAssertEqual(AUSettings(["keyChannel": 0, "notesPlayKeys": false]).keyChannel, .any, "keyChannel wins")
        XCTAssertEqual(AUSettings(["keyChannel": 99]).keyChannel, .off)
        XCTAssertEqual(AUSettings.KeyChannel.all.count, 18)
        for k in AUSettings.KeyChannel.all { var x = d; x.keyChannel = k; XCTAssertEqual(AUSettings(x.dict), x) }
        XCTAssertEqual(AUSettings(["useLearnedMap": false]).useLearnedMap, false)
        var s = d
        s.keyChannel = .channel(7)
        s.useLearnedMap = false
        XCTAssertEqual(s.dict["notesPlayKeys"] as? Bool, true, "an older build reads the keys on")
        XCTAssertEqual(AUSettings(s.dict), s)
        s.keyChannel = .off
        s.keyNotesToFirmware = true
        s.hostClock = false
        s.transpose = -1
        XCTAssertEqual(AUSettings(s.dict), s)
        var dict: [String: Any] = [:]
        CoreState(core: "felucca", version: "1", flash: nil, settings: s).encode(into: &dict)
        XCTAssertEqual(CoreState(dict)?.settings, s, "the settings in fullState")
    }

    /// the switches reach the firmware: a key note (60) plays the keys and stays away from the firmware by default;
    /// "...and reach the firmware" sends it too; with the keys off every note goes there, and with the keys on
    /// channel 2 channel 1's notes do. Note 30 (no key) always goes there.
    func testSwitchesReachTheFirmware() throws {
        let (au, log) = try makeAU(host: nil)
        render(au, count: 20)
        var t = 20 * frames
        func play(_ note: UInt8) -> Bool {
            log.clear()
            render(au, count: 20, from: t, events: [(t + 10, [0x90, note, 100]), (t + 300, [0x80, note, 0])])
            t += 20 * frames
            return log.items.contains { $0.bytes == [0x90, note, 100] } && log.items.contains { $0.bytes == [0x80, note, 0] }
        }
        XCTAssertFalse(play(60), "a key note reached the firmware by default")
        XCTAssertTrue(play(30))
        XCTAssertEqual(au.status().midiNotes, 1)
        au.settings.keyNotesToFirmware = true
        XCTAssertTrue(play(60), "...and reach the firmware: the key note too")
        au.settings.keyNotesToFirmware = false
        au.settings.keyChannel = .off
        XCTAssertTrue(play(60), "notes don't play keys: every note to the firmware")
        XCTAssertEqual(au.status().midiNotes, 2, "a note played a key with the keys off")
        au.settings.keyChannel = .channel(2)
        XCTAssertTrue(play(60), "keys on channel 2: a channel 1 note to the firmware")
        XCTAssertEqual(au.status().midiNotes, 2)
    }

    // MARK: the host's clock

    /// 120 BPM from beat 0: Start, then a clock every 918.75 frames, each a latency after its host frame (and within
    /// one device block): 24 per beat
    func testHostClockReachesTheFirmware() throws {
        let host = HostSim()
        let (au, log) = try makeAU(host: host)
        render(au, host: host, count: 400)
        let lat = latency(au)
        let items = log.items
        let ticks = items.filter { $0.bytes == [0xF8] }.map(\.time)
        XCTAssertEqual(items.first?.bytes, [0xFA])
        let start = try XCTUnwrap(items.first?.time)
        XCTAssertTrue((lat...(lat + block)).contains(start), "Start at \(start), latency \(lat)")
        let played = 400 * frames - lat - block                 // (what the core has surely made by now)
        let want = Int((Double(played) / 918.75).rounded(.down))
        XCTAssertEqual(Double(ticks.count), Double(want), accuracy: 1, "\(ticks.count) clocks for \(played) frames")
        for (k, at) in ticks.enumerated() {
            let due = Int((Double(k) * 918.75).rounded(.up)) + lat
            if at < due || at > due + block {
                XCTFail("clock \(k) at \(at), due \(due)")
                break
            }
        }
        let s = au.status()
        XCTAssertEqual(s.hostClock, 3)
        XCTAssertEqual(s.hostTempo, 120)
        print("host clock through the echo core: latency \(lat), Start at +\(start - lat), \(ticks.count) clocks; "
              + s.hostClockText)

        // stop, then play again from beat 8: Stop, Song Position 32, Continue
        log.clear()
        host.moving = false
        host.startBeat = host.beat
        render(au, host: host, count: 20, from: 400 * frames)
        host.startBeat = 8
        host.startSample = Double(420 * frames)
        host.moving = true
        render(au, host: host, count: 40, from: 420 * frames)
        let other = log.items.map(\.bytes).filter { $0 != [0xF8] }
        XCTAssertEqual(other, [[0xFC], [0xF2, 32, 0], [0xFB]])
    }

    /// MIDI in the AU's very first render reaches the core, at its frame + the latency: the render queues it before
    /// the core thread has seen the new stream (it used to drop the queue then: Start and clock 0 lost in a Release
    /// build about 1 run in 3). A fresh AU each time, so the race is run 20 times
    func testMIDIInTheFirstRenderReachesTheCore() throws {
        var s = AUSettings()
        s.keyChannel = .off
        for k in 0..<20 {
            let (au, log) = try makeAU(host: nil, settings: s)
            render(au, count: 8, events: [(5, [0xB0, 7, 99]), (300, [0x90, 30, 100]), (700, [0x80, 30, 0])])
            let lat = latency(au)
            let got = log.items
            XCTAssertEqual(got.map(\.bytes), [[0xB0, 7, 99], [0x90, 30, 100], [0x80, 30, 0]], "AU \(k)")
            for (t, g) in zip([5, 300, 700], got) where !((t + lat)...(t + lat + block)).contains(g.time) {
                XCTFail("AU \(k): \(g.bytes) at \(t): out at \(g.time), latency \(lat)")
            }
            XCTAssertEqual(au.status().midiEvents, 3)
            if got.count != 3 { break }
        }
    }

    /// a new core mid-song (a power cycle): what the old stream had queued goes, and the host clock starts again for
    /// the new one: Song Position and Continue, then the clock
    func testHostClockStartsAgainForANewCore() throws {
        let host = HostSim()
        let (au, log) = try makeAU(host: host)
        render(au, host: host, count: 100)
        XCTAssertEqual(log.items.first?.bytes, [0xFA])
        var err = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(rfme_power_cycle(au.e, &err, 256), 1)
        log.clear()
        render(au, host: host, count: 40, from: 100 * frames)
        let other = log.items.map(\.bytes).filter { $0 != [0xF8] }
        XCTAssertEqual(other.count, 2, "\(other)")
        XCTAssertEqual(other.first?.first, 0xF2)
        XCTAssertEqual(other.last, [0xFB])
        XCTAssertGreaterThan(log.items.filter { $0.bytes == [0xF8] }.count, 15)
    }

    /// the setting off: no clock of ours; the host's own clock bytes pass. On: the host's are dropped
    func testHostClockSettingAndTheHostsOwnClock() throws {
        let host = HostSim()
        var off = AUSettings()
        off.hostClock = false
        let (au, log) = try makeAU(host: host, settings: off)
        let hostTicks = (0..<10).map { (time: 2000 + $0 * 3000, bytes: [UInt8(0xF8)]) }
        render(au, host: host, count: 200, events: hostTicks)
        XCTAssertEqual(log.items.filter { $0.bytes == [0xF8] }.count, 10, "the host's clock with the setting off")
        XCTAssertFalse(log.items.contains { $0.bytes == [0xFA] })
        XCTAssertEqual(au.status().hostClock, 0)
        log.clear()
        au.settings.hostClock = true
        render(au, host: host, count: 200, from: 200 * frames, events: hostTicks.map { ($0.time + 200 * frames, $0.bytes) })
        XCTAssertEqual(au.status().clockDropped, 10, "the host's clock bytes not dropped")
        XCTAssertEqual(log.items.map(\.bytes).filter { $0 != [0xF8] }.map { $0[0] }, [0xF2, 0xFB],
                       "the setting on mid-song: Song Position and Continue")
        XCTAssertGreaterThan(log.items.filter { $0.bytes == [0xF8] }.count, 100)
        // and off again while playing: a Stop, then nothing (before it: the clocks still on their way, the latency)
        log.clear()
        au.settings.hostClock = false
        render(au, host: host, count: 20, from: 400 * frames)
        let rest = log.items.map(\.bytes)
        XCTAssertEqual(rest.last, [0xFC])
        XCTAssertEqual(rest.filter { $0 != [0xF8] }, [[0xFC]])
    }

    /// a host without a musical context or transport (AVAudioEngine, the AU test host): nothing is sent, and the
    /// host's own clock bytes pass
    func testNoHostContextSendsNothing() throws {
        let (au, log) = try makeAU(host: nil)
        render(au, count: 200, events: [(1000, [0xF8]), (5000, [0xFA])])
        XCTAssertEqual(log.items.map(\.bytes), [[0xF8], [0xFA]])
        let s = au.status()
        XCTAssertEqual(s.hostClock, 1)
        XCTAssertEqual(s.clockMsgs, 0)
        XCTAssertEqual(s.clockDropped, 0)
    }

    // MARK: MIDI out

    /// what the core sends reaches the AU's MIDI output whole (1, 2 and 3 bytes, SysEx), a latency after the host
    /// MIDI that caused it, within one device block, inside the render that plays its frame
    func testCoreMIDIOutReachesTheOutputBlock() throws {
        var s = AUSettings()
        s.keyChannel = .off
        let (au, log) = try makeAU(host: nil, settings: s)
        render(au, count: 20)
        let base = 20 * frames
        let sent: [(time: Int, bytes: [UInt8])] = [
            (base + 37, [0x90, 64, 101]), (base + 600, [0x80, 64, 0]), (base + 1500, [0xB0, 7, 99]),
            (base + 2100, [0xC3, 12]), (base + 2101, [0xD3, 80]), (base + 3000, [0xE0, 0x10, 0x50]),
            (base + 4000, [0xF8]), (base + 4500, [0xF2, 5, 1]), (base + 5000, [0x90, 0, 1]),
        ]
        render(au, count: 40, from: base, events: sent)
        let lat = latency(au)
        let got = log.items
        let sysex: [UInt8] = [0xF0, 0x7D, 0x01, 0x02, 0x03, 0x04, 0x05, 0xF7]
        XCTAssertEqual(got.map(\.bytes), sent.map(\.bytes).dropLast() + [[0x90, 0, 1], sysex])
        for (m, g) in zip(sent + [sent.last!], got) {
            XCTAssertTrue(((m.time + lat)...(m.time + lat + block)).contains(g.time),
                          "\(m.bytes) at \(m.time): out at \(g.time), latency \(lat)")
        }
        XCTAssertEqual(got.last?.time, got[got.count - 2].time, "the SysEx apart from the note that made it")
        XCTAssertEqual(au.status().midiOutMsgs, UInt32(got.count))
    }
}
