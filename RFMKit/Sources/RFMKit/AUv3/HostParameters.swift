// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AU's parameter tree (PLAN.md section 12): FM1VST's parameters, so a host can map its MIDI controllers to the
// panel (AUM's MIDI control) and automate it (Logic, Cubasis). The engine does the work on its core thread
// (RFMHostParams.h); this is the tree and the way back:
//
//   the tree     fixed: 129 parameters, addresses 0..128 (RFME_HP_*), FM1VST's identifiers (knob_master, knob_select
//                .. knob_4, btn_fx .., key_00 .., t2_00 ..), in four groups. Names never change: what a knob or a
//                Tier 2 slot does now is its value text ("Strum Rate: 120 ms"), so a host's mappings and automation
//                stay valid when the firmware, its screen or its map changes (no tree rebuild, no KVO).
//   host -> core implementorValueObserver -> rfme_hp_set (the render block's parameter events go to the engine
//                directly, sample-accurate: RFMKernelBlock.mm)
//   core -> host sync() on the main queue, 30 times a second: each value the engine says the host should show
//                (the firmware's own change, a relative knob springing back, a dropped write) is set with setValue,
//                unless the host has a write to it still in flight. Our own setValue reaches the implementor
//                observer too: it is not sent back (`reflecting`).

import AudioToolbox
import Foundation
import RFMCore

final class HostParameters: @unchecked Sendable {
    static let count = Int(RFME_HP_COUNT)
    static let buttonBase = AUParameterAddress(RFME_HP_BUTTON)
    static let knobIDs = ["knob_select", "knob_presets", "knob_algo", "knob_1", "knob_2", "knob_3", "knob_4"]
    static let knobNames = ["Knob Select", "Knob Presets", "Knob Algo", "Knob 1", "Knob 2", "Knob 3", "Knob 4"]
    static let buttonIDs = ["btn_fx", "btn_sel", "btn_env", "btn_lfo", "btn_edit", "btn_glo", "btn_home", "btn_save",
                            "btn_arp", "btn_seq", "btn_play", "btn_rec", "btn_octdn", "btn_octup"]
    static let buttonLabels = ["FX", "SEL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE", "ARP", "SEQ", "PLAY", "REC",
                               "OCT-", "OCT+"]

    let tree: AUParameterTree
    private let params: [AUParameter]           // by address
    private let lock = NSLock()                 // `engine` against detach (the tree may outlive the AU)
    private var engine: OpaquePointer?
    private var reflecting = false              // (main thread) our own setValue: not a host change
    private var timer: DispatchSourceTimer?
    private(set) var told = 0                   // (main thread) values told to the host

    init(engine e: OpaquePointer) {
        engine = e
        var all: [AUParameter] = []
        func make(_ id: String, _ name: String, _ min: AUValue, _ max: AUValue, _ unit: AudioUnitParameterUnit,
                  _ value: AUValue) -> AUParameter {
            let p = AUParameterTree.createParameter(
                withIdentifier: id, name: name, address: AUParameterAddress(all.count), min: min, max: max, unit: unit,
                unitName: nil, flags: [.flag_IsReadable, .flag_IsWritable, .flag_ValuesHaveStrings], valueStrings: nil,
                dependentParameters: nil)
            p.value = value
            all.append(p)
            return p
        }
        var knobs = [make("knob_master", "Knob Master", 0, 1023, .generic, 724)]
        for k in 0..<7 { knobs.append(make(Self.knobIDs[k], Self.knobNames[k], 0, 1, .generic, 0.5)) }
        let buttons = (0..<14).map { make(Self.buttonIDs[$0], "Button " + Self.buttonLabels[$0], 0, 1, .boolean, 0) }
        let keys = (0..<27).map { make(String(format: "key_%02d", $0), "Key " + Self.noteName(53 + $0), 0, 1, .boolean, 0) }
        let slots = (0..<Int(RFME_HP_T2_SLOTS)).map {
            make(String(format: "t2_%02d", $0), String(format: "P%02d", $0 + 1), 0, 1, .generic, 0)
        }
        precondition(all.count == Self.count, "the tree's addresses are the engine's indices")
        params = all
        tree = AUParameterTree.createTree(withChildren: [
            AUParameterTree.createGroup(withIdentifier: "knobs", name: "Knobs", children: knobs),
            AUParameterTree.createGroup(withIdentifier: "buttons", name: "Buttons", children: buttons),
            AUParameterTree.createGroup(withIdentifier: "keys", name: "Keys", children: keys),
            AUParameterTree.createGroup(withIdentifier: "firmware", name: "Firmware", children: slots),
        ])
        tree.implementorValueObserver = { [weak self] p, v in self?.hostSet(p.address, v) }
        tree.implementorStringFromValueCallback = { [weak self] p, v in
            self?.text(p.address, v?.pointee ?? p.value) ?? ""
        }
        tree.implementorValueFromStringCallback = { [weak self] p, s in self?.value(p.address, s) ?? p.value }
    }

    /// F3 for 53 (middle C = C4)
    static func noteName(_ n: Int) -> String {
        ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][n % 12] + String(n / 12 - 1)
    }

    /// the AU is going: no callback reaches the engine after this
    func detach() {
        timer?.cancel()
        timer = nil
        lock.withLock { engine = nil }
    }

    private func withEngine<T>(_ fallback: T, _ f: (OpaquePointer) -> T) -> T {
        lock.withLock { engine.map(f) ?? fallback }
    }

    private func hostSet(_ a: AUParameterAddress, _ v: AUValue) {
        if Thread.isMainThread && reflecting { return }
        withEngine(()) { _ = rfme_hp_set($0, UInt32(a), v) }
    }

    private func text(_ a: AUParameterAddress, _ v: AUValue) -> String {
        withEngine("") { e in
            // a button's value: the firmware's name for it now ("PERF: down"); the parameter's name stays printed
            if a >= Self.buttonBase, a < Self.buttonBase + 14 {
                let i = Int(a - Self.buttonBase), n = ButtonNames.read(e).names
                return (n.renamed[i] ? n.labels[i] : Self.buttonLabels[i]) + (v >= 0.5 ? ": down" : ": up")
            }
            var b = [CChar](repeating: 0, count: 64)
            _ = rfme_hp_text(e, UInt32(a), v, &b, 64)
            return CorePlayer.string(b)
        }
    }

    private func value(_ a: AUParameterAddress, _ s: String) -> AUValue? {
        withEngine(nil) { e in
            var v: AUValue = 0
            return rfme_hp_value(e, UInt32(a), s, &v) != 0 ? v : nil
        }
    }

    func parameter(_ address: Int) -> AUParameter? { address >= 0 && address < params.count ? params[address] : nil }

    /// (main thread) the engine's newest state to the host
    func sync() {
        dispatchPrecondition(condition: .onQueue(.main))
        let changes: [(AUParameter, AUValue)] = withEngine([]) { e in
            rfme_hp_poll(e)
            var p = rfme_hp_param_t()
            return params.enumerated().compactMap { i, param in
                guard rfme_hp_param(e, UInt32(i), &p) != 0, p.seq == rfme_hp_writes(e, UInt32(i)),
                      param.value != p.value else { return nil }
                return (param, p.value)
            }
        }
        for (param, v) in changes {                 // (outside the lock: a host's observer may ask for a text)
            reflecting = true
            param.setValue(v, originator: nil)
            reflecting = false
            told += 1
        }
    }

    /// sync() 30 times a second on the main queue
    func start() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.05, repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in self?.sync() }
        t.resume()
        timer = t
    }

    /// the engine's totals and one line for Diagnostics
    var info: rfme_hp_info_t { withEngine(rfme_hp_info_t()) { e in var i = rfme_hp_info_t(); rfme_hp_info(e, &i); return i } }

    static func line(_ i: rfme_hp_info_t) -> String {
        let slots = Int(RFME_HP_T2_SLOTS)
        let more = Int(i.t2_visible) > slots ? ", \(Int(i.t2_visible) - slots) without a slot" : ""
        return "\(count): Knob Master, 7 knobs (\(i.knobs_bound) on a value now), 14 buttons, 27 keys, \(slots) "
            + "firmware slots (\(i.t2_bound) in use\(more)); \(i.applied) host changes, \(i.dropped) dropped"
    }
}
