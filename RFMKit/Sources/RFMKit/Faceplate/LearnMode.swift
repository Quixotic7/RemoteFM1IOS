// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// (M8) MIDI learn on the faceplate (js/main.js learnStart, learnView, learnPick, learnTook, learnForget) and MASTER's
// pickup mark (main.js potAt), for the app and the AUv3:
//   LearnFeed      what the faceplate draws while learning: the learnable controls outlined, the bound ones marked,
//                  the picked one pulsing; the bar's text. A tap on a control picks it instead of playing it; the keys
//                  play nothing.
//   MidiLearnMode  runs it: MidiLearn (the engine's learn queue, polled on the faceplate's tick), the results as
//                  toasts, Forget, Done. The host starts it (the sheet's Learn) and stops it when its sheet opens.
//   PickupFeed     a pot waiting to pick MASTER up: where it is, shown on MASTER for 4 s after it last moved.

import Foundation
import Observation

/// MIDI learn's state on the faceplate (PanelFeed.learn)
@MainActor @Observable public final class LearnFeed {
    public internal(set) var active = false
    /// the picked control (a MidiTarget id), nil: none
    public internal(set) var selected: String?
    /// the targets with a binding
    public internal(set) var bound: Set<String> = []
    /// the bar's line
    public internal(set) var text = ""
    /// Forget shown: the picked control has bindings
    public internal(set) var canForget = false
    @ObservationIgnored weak var mode: MidiLearnMode?

    /// a control tapped while learning
    public func pick(_ target: MidiTarget) { mode?.pick(target.id) }
    public func forget() { mode?.forget() }
    public func done() { mode?.stop() }
}

/// a learned MASTER pot (or the OMX-27's K5) away from MASTER: its position, 0..1023 (PanelFeed.pickup)
@MainActor @Observable public final class PickupFeed {
    public static let showFor: TimeInterval = 4
    public internal(set) var pot: Int?
    @ObservationIgnored private var until: TimeInterval = 0

    /// main.js mapAct's pickup toast: MASTER now (0..1023) as a percentage
    public nonisolated static func text(_ master: Int) -> String {
        "MASTER: turn the pot to \(Int((Double(max(0, min(1023, master))) / 1023 * 100).rounded()))% to pick it up"
    }

    func show(_ v: Int, now: TimeInterval) {
        let c = max(0, min(1023, v))
        if pot != c { pot = c }
        until = now + Self.showFor
    }

    func hide() { if pot != nil { pot = nil } }

    /// hidden 4 s after the last change
    func expire(now: TimeInterval) { if pot != nil, now >= until { pot = nil } }
}

@MainActor
public final class MidiLearnMode {
    public let feed: PanelFeed
    public let learn: MidiLearn
    public let store: MidiMapStore
    private var seen: MidiMap?

    public init(feed: PanelFeed, host: (any PanelEngineHost)?, store: MidiMapStore = .shared) {
        self.feed = feed
        self.store = store
        learn = MidiLearn(store: store, host: host)
        feed.learn.mode = self
    }

    public var active: Bool { learn.active }

    public func attach(_ host: (any PanelEngineHost)?) { learn.attach(host) }

    /// learn mode on: the sheet closes and the Screen view gives way to the panel (ui: the faceplate's, if any)
    public func start(_ ui: FaceplateUI? = nil) {
        if let ui {
            ui.sheetOpen = false
            ui.editorOpen = false
            if ui.page == .screen { ui.page = .full }
        }
        feed.releaseAll()
        learn.start()
        feed.onTick = { [weak self] in self?.tick() }
        refresh()
    }

    public func stop() {
        guard learn.active else { return }
        learn.stop()
        feed.onTick = nil
        refresh()
    }

    /// a control tapped (picked again: it stays picked)
    public func pick(_ target: String) {
        guard learn.active, learn.selected != target else { return }
        learn.select(target)
        refresh()
    }

    /// the picked control's bindings dropped (main.js learnForget)
    public func forget() {
        guard let id = learn.selected else { return }
        let n = learn.forgetSelected()
        let t = feed.names.value.title(id)
        feed.toast.show(n == 0 ? "\(t) has no binding" : "\(t): \(n == 1 ? "its binding" : "its \(n) bindings") forgotten",
                        seconds: 2.5)
        refresh()
    }

    /// the faceplate's tick: the engine's learn queue taken, the results said
    public func tick() {
        guard learn.active else { return }
        for r in learn.poll() { took(r) }
        if store.map != seen { refresh() }               // (another process, or the sheet, changed the map)
    }

    func took(_ r: MidiLearn.Result) {
        switch r {
        case .rejected(let why): feed.toast.show(why, .bad, seconds: 2.5)
        case .bound(let b, _):
            feed.toast.show(Self.boundText(b, names: feed.names.value), .ok, seconds: 3)
        case .none: break
        }
    }

    /// main.js learnTook: "KN1 ← CC 21, channel 1 (absolute)"
    public nonisolated static func boundText(_ b: MidiMapping, names: ButtonNames = .standard) -> String {
        "\(names.title(b.target)) ← \(MidiSource.label(b.src, long: true))\(b.mode.map { " (\($0.label))" } ?? "")"
    }

    /// main.js learnView's line
    public nonisolated static func barText(selected: String?, sources: [MidiMapping],
                                           names: ButtonNames = .standard) -> String {
        guard let id = selected else { return "Tap a knob or button, then move a control on your MIDI device" }
        let sel = names.title(id)
        if !sources.isEmpty { return "\(sel) ← \(sources.map { MidiSource.label($0.src) }.joined(separator: ", "))" }
        let button = MidiTarget.named(id)?.isButton == true
        return "\(sel): now \(button ? "press a button or a key" : "turn a knob or a pot") on your MIDI device"
    }

    func refresh() {
        let l = feed.learn
        seen = store.map
        let on = learn.active
        if l.active != on { l.active = on }
        let sel = on ? learn.selected : nil
        if l.selected != sel { l.selected = sel }
        let bound = on ? store.boundTargets : []
        if l.bound != bound { l.bound = bound }
        let srcs = sel.map { store.sourcesOf($0) } ?? []
        let text = on ? Self.barText(selected: sel, sources: srcs, names: feed.names.value) : ""
        if l.text != text { l.text = text }
        if l.canForget != !srcs.isEmpty { l.canForget = !srcs.isEmpty }
    }
}
