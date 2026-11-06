// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// A hardware keyboard (a Mac, an iPad's Magic Keyboard): FM1VST's keymap (plugin/PanelComponent.cpp, keymap.c), the
// same as the web player's (web/site/js/panel.js KEYMAP), by physical key:
//   notes      Ableton Live's layout: A S D F G H J K L ; ' ] white from C4 (key 7) up, W E T Y U O P black; the chord
//              block below: 1 2 3 4 5 = F3 G3 A3 B3 C4 (Tab B3 too), F1 F2 F3 F4 = F#3 G#3 A#3 C#4
//   buttons    F5..F10 = FX SEL ENV LFO EDIT GLO (C V B N M , too: a host or macOS often takes the F keys),
//              7 8 9 0 - = = HOME SAVE ARP SEQ PLAY REC
//   octave     Z / X (Esc / Return too; End = both, the panic); Escape lets latches go first
//   knobs      Page Down / Up pick SELECT, KN1..KN4; Up / Down turn it
//   `          the display alone
// Cmd shortcuts stay the system's. Shift or Ctrl held makes a click latch (PanelFeed.latchPress).

#if os(iOS)
import SwiftUI
import UIKit

public enum KeyboardMap {
    public enum Action: Hashable, Sendable {
        case key(Int), button(PanelFeed.Label), octBoth, cycle(Int), turn(Int), displayAlone
    }

    public static let actions: [UIKeyboardHIDUsage: Action] = {
        typealias K = UIKeyboardHIDUsage
        var m: [K: Action] = [
            .keyboardF1: .key(1), .keyboardF2: .key(3), .keyboardF3: .key(5), .keyboardF4: .key(8),
            // (the owner's order: 1 2 3 4 5 = F G A B C, the lowest five whites; FM1VST has 2 3 4 5 = F G A C)
            .keyboard1: .key(0), .keyboard2: .key(2), .keyboard3: .key(4), .keyboard4: .key(6), .keyboard5: .key(7),
            .keyboardTab: .key(6),
            .keyboardA: .key(7), .keyboardS: .key(9), .keyboardD: .key(11), .keyboardF: .key(12),
            .keyboardG: .key(14), .keyboardH: .key(16), .keyboardJ: .key(18), .keyboardK: .key(19),
            .keyboardL: .key(21), .keyboardSemicolon: .key(23), .keyboardQuote: .key(24), .keyboardCloseBracket: .key(26),
            .keyboardW: .key(8), .keyboardE: .key(10), .keyboardT: .key(13), .keyboardY: .key(15),
            .keyboardU: .key(17), .keyboardO: .key(20), .keyboardP: .key(22),
            .keyboardZ: .button(.octDown), .keyboardX: .button(.octUp),
            .keyboardEscape: .button(.octDown), .keyboardReturnOrEnter: .button(.octUp), .keyboardEnd: .octBoth,
            .keyboardF5: .button(.fx), .keyboardF6: .button(.sel), .keyboardF7: .button(.env),
            .keyboardF8: .button(.lfo), .keyboardF9: .button(.edit), .keyboardF10: .button(.glo),
            .keyboard7: .button(.home), .keyboard8: .button(.save), .keyboard9: .button(.arp),
            .keyboard0: .button(.seq), .keyboardHyphen: .button(.play), .keyboardEqualSign: .button(.rec),
            .keyboardC: .button(.fx), .keyboardV: .button(.sel), .keyboardB: .button(.env),
            .keyboardN: .button(.lfo), .keyboardM: .button(.edit), .keyboardComma: .button(.glo),
            .keyboardPageDown: .cycle(1), .keyboardPageUp: .cycle(-1),
            .keyboardUpArrow: .turn(1), .keyboardDownArrow: .turn(-1),
            .keyboardGraveAccentAndTilde: .displayAlone,
        ]
        m[.keypadEnter] = .button(.octUp)
        return m
    }()

    static let modifiers: Set<UIKeyboardHIDUsage> = [.keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl,
                                                     .keyboardRightControl]

    /// PgDn / PgUp's order
    static let cycle: [PanelFeed.Knob] = [.select, .k1, .k2, .k3, .k4]

    static func next(_ k: PanelFeed.Knob, _ d: Int) -> PanelFeed.Knob {
        let at = cycle.firstIndex(of: k) ?? (d > 0 ? -1 : 0)
        return cycle[((at + d) % cycle.count + cycle.count) % cycle.count]
    }
}

/// the faceplate's keyboard: an invisible view that is the first responder while nothing else (a text field) is
struct KeyboardCatcher: UIViewRepresentable {
    let feed: PanelFeed
    let ui: FaceplateUI
    var refocus: Bool                                   // (changes when the sheet closes: take the keys back)

    func makeUIView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.feed = feed
        v.ui = ui
        return v
    }

    func updateUIView(_ v: CatcherView, context: Context) {
        v.feed = feed
        v.ui = ui
        DispatchQueue.main.async { v.claim() }
    }

    final class CatcherView: UIView {
        weak var feed: PanelFeed?
        weak var ui: FaceplateUI?
        private var held: [UIKeyboardHIDUsage: KeyboardMap.Action] = [:]
        private var mods: Set<UIKeyboardHIDUsage> = []

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { DispatchQueue.main.async { [weak self] in self?.claim() } } else { releaseAll() }
        }

        /// first responder, unless a text field (or anything else that types) has it
        func claim() {
            guard window != nil, !isFirstResponder else { return }
            if let r = window?.firstResponder, r !== self, r is UITextInput { return }
            becomeFirstResponder()
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var rest = Set<UIPress>()
            for p in presses {
                guard let key = p.key, let feed, !key.modifierFlags.contains(.command) else { rest.insert(p); continue }
                if KeyboardMap.modifiers.contains(key.keyCode) {
                    mods.insert(key.keyCode)
                    feed.latchModifier = true
                    rest.insert(p)
                    continue
                }
                guard let a = KeyboardMap.actions[key.keyCode] else { rest.insert(p); continue }
                if key.keyCode == .keyboardEscape, feed.anyLatched { feed.releaseLatches(); continue }
                if held[key.keyCode] != nil { continue }
                held[key.keyCode] = a
                act(a, down: true)
            }
            if !rest.isEmpty { super.pressesBegan(rest, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { end(presses, event) }
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { end(presses, event) }

        private func end(_ presses: Set<UIPress>, _ event: UIPressesEvent?) {
            var rest = Set<UIPress>()
            for p in presses {
                guard let key = p.key else { rest.insert(p); continue }
                if mods.remove(key.keyCode) != nil {
                    feed?.latchModifier = !mods.isEmpty
                    rest.insert(p)
                } else if let a = held.removeValue(forKey: key.keyCode) {
                    // (Z and Esc both hold OCT-: up only when neither does)
                    if !held.values.contains(a) { act(a, down: false) }
                } else {
                    rest.insert(p)
                }
            }
            if !rest.isEmpty { super.pressesEnded(rest, with: event) }
        }

        override func resignFirstResponder() -> Bool {
            releaseAll()
            return super.resignFirstResponder()
        }

        private func releaseAll() {
            for a in Set(held.values) { act(a, down: false) }
            held.removeAll()
            mods.removeAll()
            feed?.latchModifier = false
        }

        private func act(_ a: KeyboardMap.Action, down: Bool) {
            guard let feed else { return }
            switch a {
            case .key(let k): down ? feed.keyDown(k, source: .keyboard) : feed.keyUp(k, source: .keyboard)
            case .button(let l): feed.button(l, down: down, source: .keyboard)
            case .octBoth:
                feed.button(.octDown, down: down, source: .keyboard)
                feed.button(.octUp, down: down, source: .keyboard)
            case .cycle(let d):
                guard down else { return }
                feed.selectedKnob = KeyboardMap.next(feed.selectedKnob, d)
                feed.toast.show("↑ ↓ turn \(feed.selectedKnob.label)", seconds: 1.5)
            case .turn(let d):
                if down { feed.turn(feed.selectedKnob, d) }
            case .displayAlone:
                if down, let ui { ui.showDisplay(!ui.displayAlone) }
            }
        }
    }
}

private extension UIWindow {
    /// the window's first responder (UIKit has no public getter: the views that are)
    var firstResponder: UIResponder? { Self.find(in: self) }

    static func find(in v: UIView) -> UIResponder? {
        if v.isFirstResponder { return v }
        for s in v.subviews { if let r = find(in: s) { return r } }
        return nil
    }
}
#endif
