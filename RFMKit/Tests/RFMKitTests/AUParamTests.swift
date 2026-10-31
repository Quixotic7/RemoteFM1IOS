// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AU's parameter tree on the Mac (PLAN.md section 12): its shape and FM1VST's identifiers; host values (the
// implementor observer and render events) reaching the core as panel events and map writes; the firmware's own
// changes coming back; Tier 2 binding and relabelling; writes just after a boot dropped. With the echo test core and
// its small map (RFMEchoCore.cpp), through the real render block (offline renders, 44.1 kHz); ChoralRoot and Felucca
// (their real maps) when the macOS core builds are there.

import AVFoundation
import AudioToolbox
import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class AUParamTests: XCTestCase {
    private let frames = 512
    private var t = 0                               // the next render's sample time

    private enum Ev {
        case midi([UInt8])
        case param(Int, Float)
    }

    private func makeAU() throws -> RFMAudioUnit {
        var c = RFMAudioUnit.Config()
        c.runProbes = false
        c.link = .none
        c.defaultCore = nil
        let au = try RFMAudioUnit(componentDescription: RFMShared.component, options: [], config: c)
        au.maximumFramesToRender = 4096
        au.isRenderingOffline = true
        try au.allocateRenderResources()
        addTeardownBlock { au.deallocateRenderResources() }
        XCTAssertEqual(rfme_test_load_echo(au.e), 1)
        XCTAssertEqual(rfme_boot(au.e, nil, 0), 1)
        t = 0
        return au
    }

    /// `count` renders; events at frames from the first render's start
    private func render(_ au: RFMAudioUnit, count: Int, events: [(frame: Int, ev: Ev)] = []) {
        let rb = au.internalRenderBlock
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        let evs = UnsafeMutablePointer<AURenderEvent>.allocate(capacity: 64)
        defer { abl.unsafeMutablePointer.deallocate(); evs.deallocate() }
        let start = t
        for _ in 0..<count {
            let mine = events.filter { start + $0.frame >= t && start + $0.frame < t + frames }.sorted { $0.frame < $1.frame }
            for (j, m) in mine.enumerated() {
                let next = j + 1 < mine.count ? evs + j + 1 : nil
                let at = AUEventSampleTime(start + m.frame)
                switch m.ev {
                case .midi(let b):
                    evs[j] = AURenderEvent(MIDI: AUMIDIEvent(next: next, eventSampleTime: at, eventType: .MIDI, reserved: 0,
                                                            length: UInt16(b.count), cable: 0,
                                                            data: (b[0], b.count > 1 ? b[1] : 0, b.count > 2 ? b[2] : 0)))
                case .param(let a, let v):
                    evs[j] = AURenderEvent(parameter: AUParameterEvent(next: next, eventSampleTime: at, eventType: .parameter,
                                                                       reserved: (0, 0, 0), rampDurationSampleFrames: 0,
                                                                       parameterAddress: AUParameterAddress(a), value: v))
                }
            }
            for c in 0..<2 { abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil) }
            var flags = AudioUnitRenderActionFlags()
            var ts = AudioTimeStamp()
            ts.mFlags = .sampleTimeValid
            ts.mSampleTime = Double(t)
            XCTAssertEqual(rb(&flags, &ts, AUAudioFrameCount(frames), 0, abl.unsafeMutablePointer, mine.isEmpty ? nil : evs, nil), noErr)
            t += frames
        }
    }

    /// renders for about `ms` of device time
    private func run(_ au: RFMAudioUnit, ms: Int, events: [(frame: Int, ev: Ev)] = []) {
        render(au, count: max(1, ms * 44100 / 1000 / frames + 1), events: events)
    }

    /// past the boot's grace (host writes dropped), the state synced to the tree
    private func ready() throws -> RFMAudioUnit {
        let au = try makeAU()
        run(au, ms: 1100)
        au.hostParams.sync()
        return au
    }

    private func p(_ au: RFMAudioUnit, _ a: Int32) -> AUParameter { au.hostParams.parameter(Int(a))! }
    private func fw(_ au: RFMAudioUnit, _ name: String) -> Int32 { au.param(name) ?? -9999 }
    private func state(_ au: RFMAudioUnit, _ a: Int32) -> rfme_hp_param_t {
        rfme_hp_poll(au.e)
        var s = rfme_hp_param_t()
        XCTAssertEqual(rfme_hp_param(au.e, UInt32(a), &s), 1)
        return s
    }
    private func info(_ au: RFMAudioUnit) -> rfme_hp_info_t {
        rfme_hp_poll(au.e)
        return au.hostParams.info
    }
    private func text(_ au: RFMAudioUnit, _ a: Int32, _ v: Float? = nil) -> String {
        var x = v ?? p(au, a).value
        return p(au, a).string(fromValue: &x)
    }
    private func knob(_ k: Int32) -> Int32 { Int32(RFME_HP_KNOB) + k }
    private let knob1: Int32 = Int32(RFME_HP_KNOB) + 3, knob2: Int32 = Int32(RFME_HP_KNOB) + 4
    private let t2: Int32 = Int32(RFME_HP_T2)

    // MARK: the tree

    func testTreeShapeAndIdentifiers() throws {
        var c = RFMAudioUnit.Config()
        c.runProbes = false
        c.link = .none
        c.defaultCore = nil
        let au = try RFMAudioUnit(componentDescription: RFMShared.component, options: [], config: c)
        let all = try XCTUnwrap(au.parameterTree).allParameters
        XCTAssertEqual(all.count, 129)
        XCTAssertEqual(Int(RFME_HP_COUNT), 129)
        XCTAssertEqual(all.map(\.address), (0..<129).map { AUParameterAddress($0) }, "addresses are the engine's indices")
        let ids = all.map(\.identifier)
        XCTAssertEqual(Array(ids[0..<8]), ["knob_master", "knob_select", "knob_presets", "knob_algo", "knob_1", "knob_2",
                                           "knob_3", "knob_4"])
        XCTAssertEqual(Array(ids[8..<22]), ["btn_fx", "btn_sel", "btn_env", "btn_lfo", "btn_edit", "btn_glo", "btn_home",
                                            "btn_save", "btn_arp", "btn_seq", "btn_play", "btn_rec", "btn_octdn", "btn_octup"])
        XCTAssertEqual(ids[22], "key_00")
        XCTAssertEqual(ids[48], "key_26")
        XCTAssertEqual(ids[49], "t2_00")
        XCTAssertEqual(ids[128], "t2_79")
        XCTAssertEqual(all[0].displayName, "Knob Master")
        XCTAssertEqual(all[0].maxValue, 1023)
        XCTAssertEqual(all[4].displayName, "Knob 1")
        XCTAssertEqual(all[8].displayName, "Button FX")
        XCTAssertEqual(all[8].unit, .boolean)
        XCTAssertEqual(all[22].displayName, "Key F3")
        XCTAssertEqual(all[48].displayName, "Key G5")
        XCTAssertEqual(all[49].displayName, "P01")
        XCTAssertEqual(all[128].displayName, "P80")
        XCTAssertEqual(au.parameterTree?.children.map(\.identifier), ["knobs", "buttons", "keys", "firmware"])
        XCTAssertEqual(au.parameterTree?.parameter(withAddress: 49)?.keyPath, "firmware.t2_00")
        XCTAssertEqual(au.parametersForOverview(withCount: 4), [4, 5, 6, 7])
        XCTAssertTrue(all.allSatisfy { $0.flags.contains(.flag_IsWritable) && $0.flags.contains(.flag_ValuesHaveStrings) })
        var v: AUValue = 0
        XCTAssertEqual(all[49].string(fromValue: &v), "–", "no core: an unused slot")
    }

    // MARK: host -> core

    /// buttons and keys press and release (held from 0.5), Knob Master sets MASTER
    func testButtonsKeysAndMaster() throws {
        let au = try ready()
        let fx = Int32(RFME_HP_BUTTON) + Int32(RFME_B_FX), play = Int32(RFME_HP_BUTTON) + Int32(RFME_B_PLAY)
        p(au, fx).setValue(1, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Buttons"), 1 << RFME_B_FX)
        XCTAssertEqual(fw(au, "Presses"), 1)
        p(au, play).setValue(0.7, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Buttons"), 1 << RFME_B_FX | 1 << RFME_B_PLAY)
        p(au, fx).setValue(1, originator: nil)          // (the same value again: no second press)
        p(au, fx).setValue(0, originator: nil)
        p(au, play).setValue(0.2, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Buttons"), 0)
        XCTAssertEqual(fw(au, "Presses"), 2)
        XCTAssertEqual(text(au, fx, 1), "FX: down")
        // a button's value text: the firmware's name (the echo core: SEL "KEY", ARP " perf "), its name stays printed;
        // OCT- is never renamed; the setting off: the printed names
        let sel = Int32(RFME_HP_BUTTON) + Int32(RFME_B_SEL), arp = Int32(RFME_HP_BUTTON) + Int32(RFME_B_ARP)
        let octDn = Int32(RFME_HP_BUTTON) + Int32(RFME_B_OCTDN)
        XCTAssertEqual(text(au, sel, 1), "KEY: down")
        XCTAssertEqual(text(au, arp, 0), "PERF: up")
        XCTAssertEqual(text(au, octDn, 1), "OCT-: down")
        XCTAssertEqual(p(au, sel).displayName, "Button SEL")
        au.settings.buttonNames = false
        XCTAssertEqual(text(au, sel, 1), "SEL: down")
        au.settings.buttonNames = true

        let key5 = Int32(RFME_HP_KEY) + 5
        p(au, key5).setValue(1, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Keys"), 1 << 5)
        XCTAssertEqual(au.status().core.keysPressed, 0, "a host key isn't the unit's")
        p(au, key5).setValue(0, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Keys"), 0)

        XCTAssertEqual(state(au, Int32(RFME_HP_MASTER)).plain, 724, "the core's MASTER")
        p(au, Int32(RFME_HP_MASTER)).setValue(300, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Master"), 300)
        XCTAssertEqual(text(au, Int32(RFME_HP_MASTER)), "300")
    }

    /// Knob 1 is bound to Alpha (0..100): 0..1 is its range; the value text says what it turns; its target changes
    /// with the firmware (CC 20) and the text follows; a write just after a retarget is dropped
    func testAbsoluteKnob() throws {
        let au = try ready()
        XCTAssertEqual(state(au, knob1).mode, UInt8(RFME_HP_ABS))
        XCTAssertEqual(CorePlayer.string(state(au, knob1).name), "Alpha")
        XCTAssertEqual(p(au, knob1).value, 0.5, "told Alpha's value")
        XCTAssertEqual(text(au, knob1), "Alpha: 50 ms")
        p(au, knob1).setValue(0.25, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Alpha"), 25)
        XCTAssertEqual(text(au, knob1), "Alpha: 25 ms")
        XCTAssertEqual(p(au, knob1).value(from: "Alpha: 40 ms"), 0.4, accuracy: 1e-6)
        XCTAssertEqual(p(au, knob1).value(from: "70"), 0.7, accuracy: 1e-6)

        run(au, ms: 200, events: [(0, .midi([0xB0, 20, 2]))])   // Knob 1 -> Beta
        au.hostParams.sync()
        XCTAssertEqual(CorePlayer.string(state(au, knob1).name), "Beta")
        XCTAssertEqual(text(au, knob1), "Beta: Up")
        XCTAssertEqual(text(au, knob1, 1), "Beta: Both")
        XCTAssertEqual(p(au, knob1).value(from: "Down"), 0.5, accuracy: 1e-6)

        run(au, ms: 200, events: [(0, .midi([0xB0, 20, 0]))])   // Knob 1 relative
        au.hostParams.sync()
        XCTAssertEqual(state(au, knob1).mode, UInt8(RFME_HP_REL))
        XCTAssertEqual(text(au, knob1), "turn")

        // back to Alpha, and a host write 60 ms later: inside the 150 ms after the retarget, dropped
        let dropped = info(au).dropped
        run(au, ms: 300, events: [(0, .midi([0xB0, 20, 1])), (2646, .param(Int(knob1), 0.9))])
        XCTAssertEqual(info(au).dropped, dropped + 1)
        XCTAssertEqual(fw(au, "Alpha"), 25, "a write meant for the old target")
        au.hostParams.sync()
        XCTAssertEqual(p(au, knob1).value, 0.25, "told Alpha's value again")
    }

    /// Knob 2 is relative: a host change is detents (24 per travel), then it springs back to 0.5 and the host is
    /// told; the spring back isn't a host write
    func testRelativeKnob() throws {
        let au = try ready()
        XCTAssertEqual(state(au, knob2).mode, UInt8(RFME_HP_REL))
        XCTAssertEqual(p(au, knob2).value, 0.5)
        p(au, knob2).setValue(0.5 + 3.0 / 24, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Turns"), 3)
        XCTAssertEqual(text(au, knob2), "+3")
        p(au, knob2).setValue(0.5 + 3.4 / 24, originator: nil)  // (0.4 of a detent: kept)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Turns"), 3)
        p(au, knob2).setValue(0.5 + 3.6 / 24, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Turns"), 4)
        au.hostParams.sync()
        XCTAssertNotEqual(p(au, knob2).value, 0.5, "not yet")
        let writes = rfme_hp_writes(au.e, UInt32(knob2))
        run(au, ms: 500)
        au.hostParams.sync()
        XCTAssertEqual(p(au, knob2).value, 0.5, "sprang back")
        XCTAssertEqual(rfme_hp_writes(au.e, UInt32(knob2)), writes, "the spring back came back as a host write")
        run(au, ms: 60)
        XCTAssertEqual(fw(au, "Turns"), 4, "the spring back turned it")
        p(au, knob2).setValue(0.5 - 2.0 / 24, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Turns"), 2)
        XCTAssertEqual(p(au, knob2).value(from: "+2"), 0.5 + 2.0 / 24, accuracy: 1e-6)
    }

    /// the render block's parameter events, at their frames: a press and its release in one buffer still press;
    /// a Tier 2 slot and a knob from automation
    func testRenderBlockParameterEvents() throws {
        let au = try ready()
        let fx = Int(RFME_HP_BUTTON) + Int(RFME_B_FX)
        let before = au.status().paramEvents
        run(au, ms: 60, events: [(100, .param(fx, 1)), (400, .param(fx, 0)), (200, .param(Int(t2), 0.8)),
                                 (300, .param(Int(knob2), 0.5 + 2.0 / 24))])
        XCTAssertEqual(fw(au, "Presses"), 1)
        XCTAssertEqual(fw(au, "Buttons"), 0)
        XCTAssertEqual(fw(au, "Alpha"), 80)
        XCTAssertEqual(fw(au, "Turns"), 2)
        XCTAssertEqual(au.status().paramEvents, before + 4)
        XCTAssertEqual(rfme_hp_writes(au.e, UInt32(fx)), 2)
        au.hostParams.sync()
        XCTAssertEqual(p(au, t2).value, 0.8, accuracy: 1e-6, "the host's automation value shown")
        XCTAssertEqual(text(au, t2), "Alpha: 80 ms")
    }

    // MARK: Tier 2

    /// the map's visible entries in map order (Gamma and the read-outs are FM1P_HIDDEN); a meta slot shows its
    /// target and relabels when the epoch moves; unused slots say "–" and are inert
    func testTier2BindingAndRelabel() throws {
        let au = try ready()
        let info = info(au)
        XCTAssertEqual(info.t2_bound, 3)
        XCTAssertEqual(info.t2_visible, 3)
        XCTAssertEqual(info.knobs_bound, 2, "Knob 1 (Alpha), Knob 3 (Gamma)")
        XCTAssertEqual((0..<4).map { CorePlayer.string(state(au, t2 + $0).name) }, ["Alpha", "Beta", "Alpha", ""])
        XCTAssertEqual(text(au, t2 + 1), "Beta: Up")
        XCTAssertEqual(text(au, t2 + 3), "–")
        XCTAssertEqual(text(au, knob(5)), "Gamma: 0", "Knob 3 on a hidden entry")
        p(au, t2 + 1).setValue(1, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Beta"), 2)
        XCTAssertEqual(text(au, t2 + 1), "Beta: Both")
        XCTAssertEqual(p(au, t2 + 1).value(from: "Down"), 0.5, accuracy: 1e-6)
        p(au, t2 + 3).setValue(0.6, originator: nil)    // (unused: nothing happens, nothing is told)
        run(au, ms: 60)
        au.hostParams.sync()
        XCTAssertEqual(p(au, t2 + 3).value, 0.6)

        run(au, ms: 100, events: [(0, .midi([0xB0, 22, 1]))])  // Meta now stands for Beta
        au.hostParams.sync()
        XCTAssertEqual(CorePlayer.string(state(au, t2 + 2).name), "Beta")
        XCTAssertEqual(state(au, t2 + 2).entry, 1)
        XCTAssertEqual(p(au, t2 + 2).value, 1, "Beta's value (2 of 0..2)")
        XCTAssertEqual(text(au, t2 + 2), "Beta: Both")
        p(au, t2 + 2).setValue(0, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Beta"), 0, "the meta slot writes its target")
    }

    // MARK: core -> host

    /// the firmware's own change (CC 21: Alpha = 77) reaches the host's observers, on the slot and on the knob bound
    /// to it, and isn't sent back as a host write
    func testFirmwareChangesReachTheHost() throws {
        let au = try ready()
        final class Seen: @unchecked Sendable { var values: [AUParameterAddress: AUValue] = [:] }
        let seen = Seen()
        let token = au.parameterTree!.token(byAddingParameterObserver: { a, v in seen.values[a] = v })
        defer { au.parameterTree!.removeParameterObserver(token) }
        let writes = (0..<129).map { rfme_hp_writes(au.e, UInt32($0)) }
        run(au, ms: 80, events: [(0, .midi([0xB0, 21, 77]))])
        au.hostParams.sync()
        XCTAssertEqual(p(au, t2).value, 0.77, accuracy: 1e-6)
        XCTAssertEqual(p(au, knob1).value, 0.77, accuracy: 1e-6)
        for _ in 0..<50 where seen.values[AUParameterAddress(t2)] == nil {   // (observers may be called later)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(seen.values[AUParameterAddress(t2)] ?? -1, 0.77, accuracy: 1e-6)
        XCTAssertEqual(text(au, knob1), "Alpha: 77 ms")
        XCTAssertEqual((0..<129).map { rfme_hp_writes(au.e, UInt32($0)) }, writes, "a told value came back as a write")
        let told = au.hostParams.told
        au.hostParams.sync()
        XCTAssertEqual(au.hostParams.told, told, "told twice")
    }

    /// host writes in the second after a boot (a project's restored values) are dropped: no press, no turn, no
    /// MASTER; the host is told the firmware's values again
    func testWritesAfterABootAreDropped() throws {
        let au = try makeAU()
        let fx = Int32(RFME_HP_BUTTON) + Int32(RFME_B_FX)
        p(au, fx).setValue(1, originator: nil)
        p(au, Int32(RFME_HP_MASTER)).setValue(100, originator: nil)
        p(au, knob2).setValue(0.9, originator: nil)
        p(au, t2).setValue(0.1, originator: nil)
        run(au, ms: 200)
        XCTAssertEqual(fw(au, "Presses"), 0)
        XCTAssertEqual(fw(au, "Buttons"), 0)
        XCTAssertEqual(fw(au, "Turns"), 0)
        XCTAssertEqual(fw(au, "Master"), 724)
        XCTAssertEqual(fw(au, "Alpha"), 50)
        XCTAssertEqual(info(au).dropped, 4)
        au.hostParams.sync()
        XCTAssertEqual(p(au, fx).value, 0)
        XCTAssertEqual(p(au, Int32(RFME_HP_MASTER)).value, 724)
        XCTAssertEqual(p(au, knob2).value, 0.5)
        XCTAssertEqual(p(au, t2).value, 0.5)
        run(au, ms: 1000)
        p(au, fx).setValue(1, originator: nil)
        run(au, ms: 30)
        XCTAssertEqual(fw(au, "Presses"), 1, "after the grace")
    }

    func testMasterInFullState() {
        var d: [String: Any] = [:]
        CoreState(core: "felucca", version: "1", flash: nil, master: 512).encode(into: &d)
        XCTAssertEqual(CoreState(d)?.master, 512)
        CoreState(core: "felucca", version: "1", flash: nil).encode(into: &d)
        d[CoreState.masterKey] = nil
        XCTAssertNil(CoreState(d)?.master)
    }

    // MARK: real maps (the macOS core builds)

    /// ChoralRoot's and Felucca's maps on the engine (the caller's clock): every visible entry gets a slot, a slot
    /// write reaches the firmware's value, the knobs are bound where the live page has values
    func testRealMaps() throws {
        guard FileManager.default.fileExists(atPath: CoreTests.coresDir) else {
            throw XCTSkip("no macOS core builds in \(CoreTests.coresDir): run scripts/build_cores.sh macos")
        }
        XCTAssertGreaterThan(rfms_scan(CoreTests.coresDir), 0)
        for (id, visible) in [("choralroot", 77), ("felucca", 73), ("melodee", 78)] {
            let e = rfme_new(nil)!
            defer { rfme_free(e) }
            var err = [CChar](repeating: 0, count: 256)
            XCTAssertEqual(rfme_load(e, id, &err, 256), 1, CorePlayer.string(err))
            XCTAssertEqual(rfme_boot(e, nil, 0), 1)
            rfme_set_clock(e, Int32(RFME_CLOCK_CALLER))
            rfme_run_ms(e, 1100, nil)
            rfme_hp_poll(e)
            var info = rfme_hp_info_t()
            rfme_hp_info(e, &info)
            XCTAssertEqual(Int(info.t2_visible), visible, id)
            XCTAssertEqual(Int(info.t2_bound), min(visible, Int(RFME_HP_T2_SLOTS)), id)
            var s = rfme_hp_param_t()
            rfme_hp_param(e, UInt32(RFME_HP_T2), &s)
            let name = CorePlayer.string(s.name)
            XCTAssertFalse(name.isEmpty, id)
            // the first slot to its minimum, then its maximum: the firmware has them
            for x: Float in [0, 1] {
                XCTAssertEqual(rfme_hp_set(e, UInt32(RFME_HP_T2), x), 1)
                rfme_run_ms(e, 100, nil)
                var v: Int32 = 0
                XCTAssertEqual(rfme_param_get(e, name, &v), 1, "\(id) \(name)")
                XCTAssertEqual(v, x == 0 ? s.min : s.max, "\(id) \(name)")
            }
            rfme_hp_poll(e)
            rfme_hp_param(e, UInt32(RFME_HP_T2), &s)
            var bound: [String] = []
            for k in 0..<7 {
                var q = rfme_hp_param_t()
                rfme_hp_param(e, UInt32(RFME_HP_KNOB) + UInt32(k), &q)
                bound.append(q.mode == UInt8(RFME_HP_ABS) ? CorePlayer.string(q.text) : "turn")
            }
            print("host parameters, \(id): \(info.t2_bound) of \(info.t2_visible) entries in slots, P01 \(CorePlayer.string(s.text)); "
                  + "knobs: \(bound.joined(separator: ", "))")
            XCTAssertGreaterThan(info.knobs_bound, 0, "\(id): no knob bound on the first screen")
        }
    }
}
