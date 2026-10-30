// SPDX-License-Identifier: MPL-2.0
// Copyright (C) 2026 RemoteFM1 contributors
// MIDI learn (M8): js/midi-map.js Learn. A control picked on the panel, then the next CC or note binds to it; while
// the control keeps moving, the mode is guessed again from its values. The engine diverts the messages (rfme_learn,
// armed only while learn is on and a control is picked: CCs and note-ons from the host or a controller then play
// nothing), and poll() takes them from its learn queue. Works with any PanelEngineHost (the app's player or an AU).

import Foundation
import RFMCore

@MainActor
public final class MidiLearn {
    public enum Result: Equatable, Sendable {
        case bound(MidiMapping, fresh: Bool)    // fresh: just bound (else the mode guess changed as it kept moving)
        case rejected(String)                   // a note on a knob: why
        case none                               // consumed, nothing new
    }

    public let store: MidiMapStore
    public private(set) weak var host: (any PanelEngineHost)?
    public private(set) var active = false
    public private(set) var selected: String?
    private var cur: (src: String, target: String, values: [Int])?
    private var armed = false

    public init(store: MidiMapStore = .shared, host: (any PanelEngineHost)?) {
        self.store = store
        self.host = host
    }

    public func attach(_ host: (any PanelEngineHost)?) {
        disarm()
        self.host = host
        arm()
    }

    public func start() {
        active = true
        selected = nil
        cur = nil
        arm()
    }

    public func stop() {
        active = false
        selected = nil
        cur = nil
        arm()
    }

    /// a target id (MidiTarget.id) to bind to, or nil
    public func select(_ target: String?) {
        selected = target.flatMap { MidiTarget.named($0) != nil ? $0 : nil }
        cur = nil
        arm()
    }

    /// the picked control's bindings removed; how many
    @discardableResult public func forgetSelected() -> Int { selected.map { store.forget($0) } ?? 0 }

    /// what learn makes of one message; nil: it leaves it alone (nothing picked, or a note-off of a source not bound)
    public func take(_ d: [UInt8]) -> Result? {
        guard active, let sel = selected, let m = MidiMessage(d) else { return nil }
        let key = m.source
        if m.kind == .note && !m.on { return store.map.has(key) ? Result.none : nil }
        let why = MidiMap.canBind(sel, m)
        if !why.isEmpty { return .rejected(why) }
        if var c = cur, c.src == key, c.target == sel {
            if c.values.count < 24 { c.values.append(m.value) }
            cur = c
            guard let mp = store.map.get(key), let mode = mp.mode else { return Result.none }
            let g = MidiMode.guess(c.values)
            if g == mode { return Result.none }
            store.setMode(key, g)
            return store.map.get(key).map { .bound($0, fresh: false) } ?? Result.none
        }
        let isEnc = MidiTarget.named(sel)?.isEncoder == true
        let mode: MidiMode? = isEnc && m.kind == .cc ? MidiMode.guess([m.value]) : nil
        guard let mp = store.bind(key, to: sel, mode: mode) else { return Result.none }
        cur = (key, sel, [m.value])
        return .bound(mp, fresh: true)
    }

    /// the engine's learn queue taken: what came of each message (consumed ones that changed nothing left out)
    public func poll() -> [Result] {
        guard let host else { return [] }
        var out: [Result] = []
        var msg: [UInt8] = [0, 0, 0]
        while host.withPanelEngine({ e in msg.withUnsafeMutableBufferPointer { rfme_learn_take(e, $0.baseAddress) } }) != 0 {
            if let r = take(msg), r != .none { out.append(r) }
        }
        return out
    }

    // the engine diverts messages only while a control is picked
    private func arm() {
        let want = active && selected != nil && host != nil
        guard want != armed else { return }
        armed = want
        host?.withPanelEngine { rfme_learn($0, want ? 1 : 0) }
    }

    private func disarm() {
        if armed { host?.withPanelEngine { rfme_learn($0, 0) } }
        armed = false
    }
}
