// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The on-screen panel's link to a core (the app's CorePlayer or an AU instance's engine):
//   in    touches go in through rfme_event, the same queue and between hook as the FM-1's events: note keys 0..26,
//         buttons by label through the panel's btn_id map, encoder detents by knob role, MASTER absolute
//   out   the core's LCD (as one CGImage), its LEDs, the knobs' turns and MASTER, read from the engine's lock-free
//         snapshot (rfme_panel, rfme_preview) by poll(), which the faceplate calls 30-60 times a second
// What changes is split into small observable objects, so an LED changing redraws the keybed or the buttons, not the
// whole faceplate.

import CoreGraphics
import Foundation
import Observation
import RFMCore
#if os(iOS)
import QuartzCore
import UIKit
#endif

/// Something that owns an engine (rfme_t) the faceplate can play and read
public protocol PanelEngineHost: AnyObject {
    /// runs body with the engine while the host is alive
    func withPanelEngine<R>(_ body: (OpaquePointer) -> R) -> R
}

extension CorePlayer: PanelEngineHost {
    public nonisolated func withPanelEngine<R>(_ body: (OpaquePointer) -> R) -> R { body(e) }
}

extension RFMAudioUnit: PanelEngineHost {
    /// (under the preview's lock: the message channel's previewRGBA reads the preview from another thread)
    public func withPanelEngine<R>(_ body: (OpaquePointer) -> R) -> R { pvLock.withLock { body(e) } }
}

/// LED brightness (fm1core.h FM1P_LED_*) as the faceplate draws it
public enum LEDLevel {
    public static let litMin: UInt8 = 176
    /// the share of the lit colour over the off colour: FM1VST's ledAlpha (FAINT .2, DIM .38, MID .62, LIT 1)
    public static func alpha(_ v: UInt8) -> Double {
        let X: [Double] = [0, 12, 40, 96, 255], Y: [Double] = [0, 0.2, 0.38, 0.62, 1]
        let x = Double(v)
        for i in 1..<5 where x <= X[i] { return Y[i - 1] + (Y[i] - Y[i - 1]) * (x - X[i - 1]) / (X[i] - X[i - 1]) }
        return 1
    }
    public static func lit(_ v: UInt8) -> Bool { v >= litMin }
}

/// the core's screen
@MainActor @Observable public final class ScreenFeed {
    public internal(set) var image: CGImage?
    public internal(set) var frames = 0
}

/// the LEDs and what is held
@MainActor @Observable public final class PanelLights {
    public internal(set) var keys = [UInt8](repeating: 0, count: 27)
    public internal(set) var buttons = [UInt8](repeating: 0, count: 14)   // by label (PanelFeed.Label)
    public internal(set) var playGreen: UInt8 = 0
    public internal(set) var heldKeys: UInt32 = 0          // the core's (the unit's, the screen's, host notes)
    public internal(set) var heldLabels: UInt32 = 0
    public internal(set) var booted = false
    public internal(set) var touchedKeys: UInt32 = 0       // held on this screen now (drawn at once)
    public internal(set) var touchedLabels: UInt32 = 0

    public func keyDown(_ k: Int) -> Bool { (heldKeys | touchedKeys) & (1 << UInt32(k)) != 0 }
    public func labelDown(_ l: Int) -> Bool { (heldLabels | touchedLabels) & (1 << UInt32(l)) != 0 }
}

/// the knobs: clockwise detents per role since power-on (pointer angles), MASTER
@MainActor @Observable public final class KnobFeed {
    public internal(set) var turns = [Int32](repeating: 0, count: 7)
    public internal(set) var master: Int32 = 724            // (a core's power-on value when the host gives none)
    public internal(set) var masterKnown = false
}

@MainActor
public final class PanelFeed {
    /// button labels (fm1core.h FM1P_B_*), the faceplate's order is `grid`
    public enum Label: Int, CaseIterable, Sendable {
        case fx, sel, env, lfo, edit, glo, home, save, arp, seq, play, rec, octDown, octUp
        public var legend: String {
            ["FX", "SEL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE", "ARP", "SEQ", "PLAY", "REC", "OCT−", "OCT+"][rawValue]
        }
        public var spoken: String {
            switch self {
            case .play: "Play / Stop"
            case .rec: "Record"
            case .octDown: "Octave down"
            case .octUp: "Octave up"
            default: legend
            }
        }
        public static let grid: [Label] = [.fx, .sel, .env, .lfo, .edit, .glo, .home, .save, .arp, .seq, .play, .rec]
    }

    /// knob roles (fm1core.h FM1P_E_*); MASTER is the pot
    public enum Knob: Int, CaseIterable, Sendable {
        case select, algorithm, presets, k1, k2, k3, k4, master
        public var label: String {
            ["Select", "Algorithm", "Presets", "KN1", "KN2", "KN3", "KN4", "Master"][rawValue]
        }
        public static let main: [Knob] = [.master, .select, .presets, .algorithm]
        public static let kn: [Knob] = [.k1, .k2, .k3, .k4]
    }

    public let screen = ScreenFeed()
    public let lights = PanelLights()
    public let knobs = KnobFeed()
    public private(set) weak var host: (any PanelEngineHost)?
    private var panelSeq: UInt32 = 0
    private var previewSeq: UInt32 = 0
    private var rgba = [UInt8](repeating: 0, count: Int(RFMC_W * RFMC_H * 4))
    private var keyTouches = [Int](repeating: 0, count: 27)
    private var localUntil = [TimeInterval](repeating: 0, count: 8)   // per knob: this screen's value wins until then
    static let localHold: TimeInterval = 0.25
    #if os(iOS)
    private var ticker: Ticker?
    private var users = 0
    #endif

    public init(host: (any PanelEngineHost)?) { self.host = host }

    public func attach(_ host: (any PanelEngineHost)?) {
        self.host = host
        panelSeq = 0
        previewSeq = 0
    }

    // MARK: in (the same path as the FM-1's events)

    private func event(_ type: Int32, _ index: Int32, _ value: Int16) {
        guard index >= 0 else { return }
        host?.withPanelEngine { _ = rfme_event($0, UInt8(type), UInt8(index), value) }
    }

    /// a finger down on note key k (several fingers on one key: one press)
    public func keyDown(_ k: Int) {
        guard (0..<27).contains(k) else { return }
        keyTouches[k] += 1
        guard keyTouches[k] == 1 else { return }
        lights.touchedKeys |= 1 << UInt32(k)
        event(Int32(RFMC_EV_KEY), Int32(k), 1)
    }

    public func keyUp(_ k: Int) {
        guard (0..<27).contains(k), keyTouches[k] > 0 else { return }
        keyTouches[k] -= 1
        guard keyTouches[k] == 0 else { return }
        lights.touchedKeys &= ~(1 << UInt32(k))
        event(Int32(RFMC_EV_KEY), Int32(k), 0)
    }

    /// a button by its label, through the panel's btn_id (the firmware's own map)
    public func button(_ l: Label, down: Bool) {
        let bit = UInt32(1) << UInt32(l.rawValue)
        guard (lights.touchedLabels & bit != 0) != down else { return }
        lights.touchedLabels = down ? lights.touchedLabels | bit : lights.touchedLabels & ~bit
        let id = host?.withPanelEngine { rfme_matrix_button($0, Int32(l.rawValue)) } ?? -1
        event(Int32(RFMC_EV_BUTTON), id, down ? 1 : 0)
    }

    /// detents of an encoder (+ clockwise), by its knob role
    public func turn(_ k: Knob, _ detents: Int) {
        guard k != .master, detents != 0 else { return }
        let id = host?.withPanelEngine { rfme_matrix_encoder($0, Int32(k.rawValue)) } ?? -1
        var left = detents
        while left != 0 {                                       // (int16 per event)
            let d = max(-1000, min(1000, left))
            event(Int32(RFMC_EV_ENC), id, Int16(d))
            left -= d
        }
        knobs.turns[k.rawValue] &+= Int32(detents)             // (drawn at once; the snapshots confirm it)
        localUntil[k.rawValue] = ProcessInfo.processInfo.systemUptime + Self.localHold
    }

    /// the MASTER pot, absolute 0...1023
    public func master(_ v: Int) {
        let c = Int16(max(0, min(1023, v)))
        knobs.master = Int32(c)
        knobs.masterKnown = true
        localUntil[Knob.master.rawValue] = ProcessInfo.processInfo.systemUptime + Self.localHold
        event(Int32(RFMC_EV_MASTER), 0, c)
    }

    /// everything this screen holds let go (the view went away)
    public func releaseAll() {
        for k in 0..<27 where keyTouches[k] > 0 {
            keyTouches[k] = 1
            keyUp(k)
        }
        for l in Label.allCases where lights.touchedLabels & (1 << UInt32(l.rawValue)) != 0 { button(l, down: false) }
    }

    // MARK: out

    /// reads the engine's newest panel state and screen (cheap when nothing changed)
    public func poll() {
        guard let host else { return }
        var p = rfme_panel_t()
        let seq = host.withPanelEngine { rfme_panel($0, &p) }
        if seq != panelSeq {
            panelSeq = seq
            apply(p)
        } else if lights.booted && p.booted == 0 {
            apply(p)
        }
        let s = rgba.withUnsafeMutableBufferPointer { b in host.withPanelEngine { rfme_preview($0, previewSeq, b.baseAddress) } }
        if s != previewSeq, s != 0 {
            previewSeq = s
            screen.image = RemoteController.image(rgba)
            screen.frames += 1
        }
    }

    func apply(_ p: rfme_panel_t) {
        let booted = p.booted != 0
        if booted != lights.booted { lights.booted = booted }
        let keys = withUnsafeBytes(of: p.key_led) { Array($0) }
        let btns = withUnsafeBytes(of: p.btn_led) { Array($0) }
        if keys != lights.keys { lights.keys = booted ? keys : [UInt8](repeating: 0, count: 27) }
        if btns != lights.buttons { lights.buttons = booted ? btns : [UInt8](repeating: 0, count: 14) }
        if p.play_green != lights.playGreen { lights.playGreen = p.play_green }
        if p.keys != lights.heldKeys { lights.heldKeys = p.keys }
        if p.labels != lights.heldLabels { lights.heldLabels = p.labels }
        guard booted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var turns = withUnsafeBytes(of: p.enc) { Array($0.bindMemory(to: Int32.self)) }
        for r in 0..<7 where localUntil[r] > now { turns[r] = knobs.turns[r] }   // (a turn here not applied yet)
        if turns != knobs.turns { knobs.turns = turns }
        if localUntil[Knob.master.rawValue] <= now, p.master != knobs.master || !knobs.masterKnown {
            knobs.master = p.master
            knobs.masterKnown = true
        }
    }

    // MARK: the clock that polls (a display link at 30-60 Hz while a faceplate is on screen)

    #if os(iOS)
    public func start() {
        users += 1
        guard ticker == nil else { return }
        ticker = Ticker { [weak self] in self?.poll() }
    }

    public func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        releaseAll()                                    // (no faceplate on screen holds anything now)
        ticker?.invalidate()
        ticker = nil
    }

    @MainActor private final class Ticker: NSObject {
        private var link: CADisplayLink?
        private let fire: @MainActor () -> Void

        init(_ fire: @escaping @MainActor () -> Void) {
            self.fire = fire
            super.init()
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
        }

        @objc func tick() { fire() }               // (the main run loop)
        func invalidate() { link?.invalidate(); link = nil }
    }
    #endif
}
