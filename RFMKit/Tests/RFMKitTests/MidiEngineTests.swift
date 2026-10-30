// SPDX-License-Identifier: MPL-2.0
// Copyright (C) 2026 RemoteFM1 contributors
// M8 in the engine (RFME_CLOCK_CALLER, ChoralRoot): a controller's MIDI (rfme_midi_in), the learned map
// (rfme_set_midi_map: test.mjs's MidiMap.feed checks, run where the app runs them), MASTER's pickup, learn diverting
// messages (rfme_learn), and MidiLearn end to end. Skipped, saying so, when the macOS cores are not built.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class MidiEngineTests: XCTestCase {
    override func setUpWithError() throws {
        let dir = CoreTests.coresDir
        guard FileManager.default.fileExists(atPath: dir) else {
            throw XCTSkip("no macOS core builds in \(dir): run scripts/build_cores.sh macos")
        }
        _ = rfms_scan(dir)
    }

    private func core() throws -> TestCore {
        let c = try TestCore("choralroot")
        c.boot()
        c.run(1500)
        return c
    }

    private func send(_ c: TestCore, _ d: [UInt8], firmware: Bool = false) {
        XCTAssertEqual(d.withUnsafeBufferPointer { rfme_midi_in(c.e, $0.baseAddress, UInt32(d.count), firmware ? 1 : 0) }, 1)
    }

    /// one message, then the panel as the clock publishes it
    @discardableResult private func feed(_ c: TestCore, _ d: [UInt8]) -> rfme_panel_t {
        send(c, d)
        return panel(c)
    }

    private func panel(_ c: TestCore) -> rfme_panel_t {
        c.run(20)
        var p = rfme_panel_t()
        rfme_panel(c.e, &p)
        return p
    }

    private func map(_ c: TestCore, _ list: [MidiMapping], speed: Double = 1) {
        MidiMap(list, speed: speed).apply(to: c.e)
        c.run(2)                                        // (taken at the next millisecond)
    }

    private func enc(_ p: rfme_panel_t, _ role: Int32) -> Int32 { withUnsafeBytes(of: p.enc) { $0.bindMemory(to: Int32.self)[Int(role)] } }

    /// an absolute pot on KN1 at each speed: 40 41 43 42 -> its detents (the first value only sets the start)
    func testAbsolutePotTurnsAnEncoder() throws {
        let c = try core()
        for (n, (sp, want)) in [(1.0, [0, 1, 3, 2]), (2.0, [0, 2, 6, 4]), (0.5, [0, 0, 1, 1])].enumerated() {
            let src = "cc:1:\(21 + n)"
            map(c, [MidiMapping(src: src, target: "KN1", mode: .abs)], speed: sp)
            let base = enc(panel(c), Int32(RFME_E_K1))
            let got = [40, 41, 43, 42].map { enc(feed(c, cc(21 + n, $0)), Int32(RFME_E_K1)) - base }
            XCTAssertEqual(got, want.map(Int32.init), "absolute at \(sp)x")
        }
    }

    /// a pot learn saw at 10, mapped at 1/2x: 11 12 13 -> 0 1 0, back to 10: -1 (the half step carries over)
    func testHalfSpeedCarriesTheFraction() throws {
        let c = try core()
        rfme_learn(c.e, 1)
        send(c, cc(24, 10))
        c.run(2)
        var msg = [UInt8](repeating: 0, count: 3)
        XCTAssertEqual(rfme_learn_take(c.e, &msg), 1)
        XCTAssertEqual(msg, cc(24, 10))
        rfme_learn(c.e, 0)
        map(c, [MidiMapping(src: "cc:1:24", target: "KN2", mode: .abs)], speed: 0.5)
        var last = enc(panel(c), Int32(RFME_E_K2))
        var steps: [Int32] = []
        for v in [11, 12, 13, 10] {
            let now = enc(feed(c, cc(24, v)), Int32(RFME_E_K2))
            steps.append(now - last)
            last = now
        }
        XCTAssertEqual(steps, [0, 1, 0, -1])
    }

    func testRelativeModes() throws {
        let c = try core()
        func rel(_ n: Int, _ mode: MidiMode, _ vals: [Int], speed: Double = 1) -> [Int32] {
            map(c, [MidiMapping(src: "cc:1:\(n)", target: "SELECT", mode: mode)], speed: speed)
            var last = enc(panel(c), Int32(RFME_E_SELECT))
            return vals.map { v in
                let now = enc(feed(c, cc(n, v)), Int32(RFME_E_SELECT))
                defer { last = now }
                return now - last
            }
        }
        XCTAssertEqual(rel(30, .rel64, [65, 66, 63, 60, 64]), [1, 2, -1, -4, 0], "binary offset")
        XCTAssertEqual(rel(31, .rel2c, [1, 3, 127, 125, 64]), [1, 3, -1, -3, -64], "two's complement")
        XCTAssertEqual(rel(32, .relsign, [1, 3, 65, 67]), [1, 3, -1, -3], "sign bit")
        XCTAssertEqual(rel(33, .rel64, [65], speed: 2), [2], "the speed scales a relative encoder too")
    }

    /// a note and a CC on HOME: each presses and releases it; two sources hold it until both let go. A mapped message
    /// is consumed (no key, nothing to midi_in); another number or channel flows on; a note stored on a knob does too
    func testButtonsAndConsumption() throws {
        let c = try core()
        let home = UInt32(1) << UInt32(RFME_B_HOME)
        map(c, [MidiMapping(src: "note:1:60", target: "HOME"), MidiMapping(src: "cc:1:64", target: "HOME"),
                MidiMapping(src: "cc:1:21", target: "KN1")])
        let held = [noteOn(60), cc(64, 127), noteOff(60), cc(64, 0), cc(64, 63)].map { feed(c, $0).labels & home != 0 }
        XCTAssertEqual(held, [true, true, true, false, false])
        XCTAssertEqual(panel(c).keys, 0, "a mapped note plays no key")
        // consumption, by the stats
        let s0 = c.status
        feed(c, cc(21, 3))
        let s1 = c.status
        XCTAssertEqual(s1.midi_mapped - s0.midi_mapped, 1)
        XCTAssertEqual(s1.midi_to_core, s0.midi_to_core, "a mapped CC never reaches midi_in")
        feed(c, cc(21, 3, 2))
        XCTAssertEqual(c.status.midi_to_core - s1.midi_to_core, 1, "the same CC on another channel does")
        // a note stored on a knob is ignored by the engine too: it plays its key
        var bad = MidiMap([MidiMapping(src: "note:1:62", target: "HOME")]).entries
        bad[0].target = UInt8(RFME_E_K1)
        bad.withUnsafeBufferPointer { rfme_set_midi_map(c.e, $0.baseAddress, 1, 1) }
        XCTAssertNotEqual(feed(c, noteOn(62)).keys & (1 << 9), 0)
        feed(c, noteOff(62))
    }

    /// a new map lets go of what the old one held
    func testNewMapReleasesItsButtons() throws {
        let c = try core()
        let fx = UInt32(1) << UInt32(RFME_B_FX)
        map(c, [MidiMapping(src: "cc:1:80", target: "FX")])
        XCTAssertNotEqual(feed(c, cc(80, 127)).labels & fx, 0)
        map(c, [])
        XCTAssertEqual(panel(c).labels & fx, 0)
    }

    /// test.mjs's pickup checks: a pot away from MASTER waits (master_pot, pickup_seq once), crossing or reaching it
    /// picks MASTER up, MASTER moved by anything else: it waits again
    func testMasterPickup() throws {
        let c = try core()
        map(c, [MidiMapping(src: "cc:1:22", target: "MASTER"), MidiMapping(src: "cc:1:23", target: "MASTER")])
        XCTAssertEqual(feed(c, cc(22, 64)).master, 516, "MASTER unknown (just booted): set at once")
        XCTAssertEqual(panel(c).master_pot, -1)
        _ = rfme_event(c.e, UInt8(RFMC_EV_MASTER), 0, 768)  // (96.0 in CC steps)
        let seq0 = panel(c).pickup_seq
        let a1 = feed(c, cc(22, 20)), a2 = feed(c, cc(22, 40)), a3 = feed(c, cc(22, 60))
        XCTAssertEqual([a1.master, a2.master, a3.master], [768, 768, 768], "a pot below MASTER is ignored")
        XCTAssertEqual([a1.master_pot, a2.master_pot, a3.master_pot], [161, 322, 483], "where the pot is")
        XCTAssertEqual(a3.pickup_seq, seq0 &+ 1, "the first ignore says so once")
        let a4 = feed(c, cc(22, 100))
        XCTAssertEqual(a4.master, 806, "crossing MASTER's position (60 -> 100) picks it up")
        XCTAssertEqual(a4.master_pot, -1)
        feed(c, cc(22, 127))
        XCTAssertEqual(panel(c).master, 1023)
        XCTAssertEqual(feed(c, cc(22, 0)).master, 0, "then it follows directly")
        _ = rfme_event(c.e, UInt8(RFMC_EV_MASTER), 0, 512)  // (the screen moved MASTER)
        c.run(2)
        let a5 = feed(c, cc(22, 10))
        XCTAssertEqual(a5.master, 512, "after MASTER moves by anything else, the pot waits again")
        XCTAssertEqual(a5.pickup_seq, seq0 &+ 2)
        XCTAssertEqual(feed(c, cc(22, 63)).master, 507, "within 2 steps of MASTER (63 ~ 512) picks it up")
        _ = rfme_event(c.e, UInt8(RFMC_EV_MASTER), 0, 768)
        c.run(2)
        XCTAssertEqual(feed(c, cc(23, 95)).master, 765, "a pot not seen before picks up at once within 2 steps")
    }

    /// learn armed: CCs, note-ons and the note-offs of the notes it took go to its queue, nowhere else
    func testLearnDivertsMessages() throws {
        let c = try core()
        map(c, [MidiMapping(src: "cc:1:21", target: "KN1")])
        let k1 = enc(panel(c), Int32(RFME_E_K1))
        rfme_learn(c.e, 1)
        let s0 = c.status
        feed(c, noteOn(62))
        XCTAssertEqual(panel(c).keys, 0, "a note-on learn takes plays nothing")
        feed(c, noteOff(62))
        feed(c, cc(21, 5))
        feed(c, cc(21, 90))
        XCTAssertEqual(enc(panel(c), Int32(RFME_E_K1)), k1, "nor does a mapped CC")
        feed(c, [0xE0, 0, 64])                          // (pitch bend: not learn's)
        let s1 = c.status
        XCTAssertEqual(s1.midi_learned - s0.midi_learned, 4)
        XCTAssertEqual(s1.midi_to_core - s0.midi_to_core, 1)
        var got: [[UInt8]] = []
        var msg = [UInt8](repeating: 0, count: 3)
        while rfme_learn_take(c.e, &msg) != 0 { got.append(msg) }
        XCTAssertEqual(got, [noteOn(62), noteOff(62), cc(21, 5), cc(21, 90)])
        rfme_learn(c.e, 0)
        XCTAssertNotEqual(feed(c, noteOn(62)).keys & (1 << 9), 0, "disarmed: notes play again")
        feed(c, noteOff(62))
        XCTAssertEqual(enc(feed(c, cc(21, 91)), Int32(RFME_E_K1)) - k1, 1, "the pot turns from what learn saw (90)")
    }

    /// rfme_midi_in: notes play keys (with the settings), to_firmware goes to midi_in and plays no key
    func testControllerNotes() throws {
        let c = try core()
        XCTAssertNotEqual(feed(c, noteOn(62)).keys & (1 << 9), 0, "D4 holds key 9")
        XCTAssertEqual(feed(c, noteOff(62)).keys, 0)
        XCTAssertEqual(c.status.midi_notes, 1)
        let s0 = c.status
        send(c, noteOn(62), firmware: true)
        XCTAssertEqual(panel(c).keys, 0, "the firmware's MIDI in only")
        send(c, noteOff(62), firmware: true)
        c.run(10)
        XCTAssertEqual(c.status.midi_to_core - s0.midi_to_core, 2)
        rfme_set_midi(c.e, 1, 1, 0)                     // (FM1VST's transpose, +1 octave: D3 plays key 9)
        XCTAssertNotEqual(feed(c, noteOn(50)).keys & (1 << 9), 0)
        feed(c, noteOff(50))
        XCTAssertEqual(rfme_midi_in(c.e, [0xF0, 1, 2], 3, 0), 0, "SysEx: not passed")
        XCTAssertEqual(rfme_midi_in(c.e, [0x40], 1, 0), 0, "no status byte")
    }

    /// render ahead (RFME_CLOCK_AUDIO, offline so the test's renders wait for the core thread): the host's mapped CC
    /// (the AU's render MIDI) turns KN1 on the core thread, and a controller's note plays its key there
    func testUnderTheAudioClock() throws {
        let c = try TestCore("choralroot")
        c.boot()
        rfme_set_offline(c.e, 1)
        rfme_set_clock(c.e, Int32(RFME_CLOCK_AUDIO))
        var l = [Float](repeating: 0, count: 512), r = l
        func render(_ n: Int, _ ev: [UInt8]? = nil) {
            for i in 0..<n {
                var m = rfme_midi_t()
                if let ev, i == 0 { m.len = UInt8(ev.count); m.data = (ev[0], ev[1], ev[2]) }
                let nev: UInt32 = ev != nil && i == 0 ? 1 : 0
                _ = withUnsafePointer(to: &m) { mp in rfme_render_midi(c.e, &l, &r, 512, 44100, mp, nev) }
            }
        }
        render(150)                                     // (booted, the ring primed: ~1.7 s)
        MidiMap([MidiMapping(src: "cc:1:21", target: "KN1", mode: .rel64)]).apply(to: c.e)
        render(5)
        var p = rfme_panel_t()
        rfme_panel(c.e, &p)
        let k1 = enc(p, Int32(RFME_E_K1))
        for _ in 0..<3 { render(5, cc(21, 65)) }
        send(c, noteOn(62))
        render(20)
        rfme_panel(c.e, &p)
        XCTAssertEqual(enc(p, Int32(RFME_E_K1)) - k1, 3)
        XCTAssertNotEqual(p.keys & (1 << 9), 0)
        XCTAssertEqual(c.status.midi_mapped, 3)
        rfme_set_clock(c.e, Int32(RFME_CLOCK_NONE))
    }

    /// the app's MIDI settings are remembered
    @MainActor func testAppMidiSettingsAreKept() throws {
        let suite = "rfm-midi-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let flash = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: flash) }
        var p: CorePlayer? = CorePlayer(link: nil, slotsDir: CoreTests.coresDir, flashDir: flash, midiDefaults: d)
        XCTAssertEqual(p?.midiSettings, AUSettings())
        p?.midiSettings.transpose = -1
        p?.midiSettings.keyNotesToFirmware = true
        p = nil
        let q = CorePlayer(link: nil, slotsDir: CoreTests.coresDir, flashDir: flash, midiDefaults: d)
        XCTAssertEqual(q.midiSettings.transpose, -1)
        XCTAssertTrue(q.midiSettings.keyNotesToFirmware)
        XCTAssertTrue(q.midiSettings.notesPlayKeys)
    }

    /// MidiLearn on an engine: KN1 picked, a pot moved on the controller binds it (absolute); after learn the pot
    /// turns from its last learned value (43 -> 44: 1 detent); a note on a knob is refused
    @MainActor func testLearnSeedsThePot() throws {
        let c = try core()
        let url = MidiMapTests.tempFile()
        let store = MidiMapStore(url: url)
        let follower = MidiMapFollower(engine: c.e, url: url)
        defer { follower.stop() }
        let host = TestEngineHost(c)
        let L = MidiLearn(store: store, host: host)
        L.start()
        send(c, cc(21, 30))
        c.run(5)
        XCTAssertEqual(L.poll(), [], "nothing picked: learn leaves it alone")
        L.select("KN1")
        for v in [40, 41, 42, 43] { send(c, cc(21, v)) }
        c.run(5)
        XCTAssertEqual(L.poll(), [.bound(MidiMapping(src: "cc:1:21", target: "KN1", mode: .abs), fresh: true)])
        XCTAssertEqual(store.map.get("cc:1:21")?.mode, .abs)
        L.select("KN2")
        send(c, noteOn(60))
        c.run(5)
        XCTAssertEqual(L.poll(), [.rejected("KN2 takes a CC: move a knob or a pot")])
        L.stop()
        send(c, noteOff(60))
        let k1 = enc(panel(c), Int32(RFME_E_K1))
        XCTAssertEqual(enc(feed(c, cc(21, 44)), Int32(RFME_E_K1)) - k1, 1)
    }
}
