// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The on-screen FM-1 (design/README.md sections 1-4): the whole view is the faceplate, in one of three views
//   Full      everything in the hardware's arrangement (iPhone portrait with the scrolling keybed, iPhone landscape,
//             iPad landscape, iPad portrait: FaceplateLayout)
//   Controls  a big display, one knob row (MAIN | KN 1-4) and a deck: BUTTONS (6 x 2 + OCT) or KEYS
//   Screen    the display alone
// Sideways swipes on the background move between the views (page dots and the sheet's tiles do the same); in
// Controls a sideways swipe on the knob row switches its set, and one in the deck switches the deck. The grabber
// (a tap, or a swipe down) asks the host for its pull-down sheet. Shared by the app and the AUv3.

import Foundation
import Observation
import SwiftUI

/// the faceplate's own state: the view, the deck, the knob set, the keybeds' scroll
@MainActor @Observable public final class FaceplateUI {
    public enum Page: String, CaseIterable, Sendable { case full, controls, screen }
    public enum Deck: String, Sendable { case buttons, keys }
    public enum KnobSet: String, Sendable { case main, kn }

    public var page: Page = .full
    public var deck: Deck = .buttons
    public var knobSet: KnobSet = .main
    public var fullOffset: CGFloat = -1             // the Full keybed's scroll (-1: its default)
    public var deckOffset: CGFloat = -1
    public var stepNumbers = false                  // step numbers 1-16 on the naturals (Settings)
    public var sheetOpen = false
    public var editorOpen = false
    public var displayAlone = false                 // the display alone, full size (a double tap on it)
    public var firmwareName: String?                // the running firmware: the status row's word
    @ObservationIgnored public var onWord: (() -> Void)?   // a tap on the word (the host's Firmware panel)

    public init() {}

    /// the status row's word: the firmware's name in capitals, REMOTE FM1 without one
    public nonisolated static func word(_ firmware: String?) -> String {
        let n = (firmware ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "REMOTE FM1" : n.uppercased()
    }

    public var word: String { Self.word(firmwareName) }

    public func showDisplay(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { displayAlone = on }
    }

    public func move(_ d: Int) {
        let all = Page.allCases
        let i = all.firstIndex(of: page)! + d
        guard all.indices.contains(i) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { page = all[i] }
    }
}

/// the status chip: which way the FM-1 is played (section 1, and section 10's "FM-1 in use")
public enum PanelChip: Equatable, Sendable {
    case emulator
    case linked
    case inUse
    case searching

    public var text: String {
        switch self {
        case .emulator: "Emulator"
        case .linked: "FM-1 linked"
        case .inUse: "FM-1 in use"
        case .searching: "FM-1 searching"
        }
    }
}

#if os(iOS)
public struct FaceplateView: View, @MainActor Equatable {
    let feed: PanelFeed
    @Bindable var ui: FaceplateUI
    let theme: Theme
    let chip: PanelChip
    var kind: FaceplateLayout.Kind?                 // nil: from the view's size
    var chrome = true                               // the status row / grabber (it sets ui.sheetOpen)

    public init(feed: PanelFeed, ui: FaceplateUI, theme: Theme, chip: PanelChip, kind: FaceplateLayout.Kind? = nil,
                chrome: Bool = true) {
        self.feed = feed
        self.ui = ui
        self.theme = theme
        self.chip = chip
        self.kind = kind
        self.chrome = chrome
    }

    /// (equal inputs: SwiftUI skips the faceplate when its host redraws for something else)
    public static func == (a: FaceplateView, b: FaceplateView) -> Bool {
        a.feed === b.feed && a.ui === b.ui && a.theme == b.theme && a.chip == b.chip && a.kind == b.kind
            && a.chrome == b.chrome
    }

    private func openSheet() { withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true } }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let k = kind ?? FaceplateLayout.Kind.pick(size)
            ZStack(alignment: .topLeading) {
                // the background: sideways swipes change the view (controls on top get their own touches)
                theme.body.color
                    .contentShape(Rectangle())
                    .gesture(swipe { ui.move($0) })
                    .accessibilityHidden(true)
                Group {
                    switch ui.page {
                    case .full: FullView(feed: feed, ui: ui, theme: theme, chip: chip, kind: k, size: size, chrome: chrome,
                                         openSheet: openSheet)
                    case .controls: ControlsView(feed: feed, ui: ui, theme: theme, chip: chip, size: size, chrome: chrome,
                                                 openSheet: openSheet)
                    case .screen: ScreenOnlyView(feed: feed, ui: ui, theme: theme, chip: chip, size: size, chrome: chrome,
                                                 openSheet: openSheet)
                    }
                }
                .transition(.opacity)
                if ui.displayAlone {
                    FullDisplay(feed: feed, ui: ui)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .zIndex(1)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .onAppear { feed.start() }
        .onDisappear { feed.stop() }
    }
}

/// a sideways swipe: -1 (to the right: the previous) or +1
@MainActor func swipe(_ go: @escaping (Int) -> Void) -> some Gesture {
    DragGesture(minimumDistance: 24)
        .onEnded { v in
            let dx = v.translation.width, dy = v.translation.height
            guard abs(dx) > 60, abs(dx) > abs(dy) * 1.3 else { return }
            go(dx < 0 ? 1 : -1)
        }
}

// MARK: - status row, grabber, page dots

struct StatusRow: View {
    let theme: Theme
    let chip: PanelChip
    let spec: FaceplateLayout.Status
    let m: FaceplateLayout.Mapper
    var word = "REMOTE FM1"
    var onWord: (() -> Void)?
    let openSheet: () -> Void

    var body: some View {
        let y = m.y(spec.y), h = m.len(32)
        let s = m.s
        ZStack {
            HStack {
                Chip(theme: theme, chip: chip, height: spec.chipHeight * s, pad: spec.chipPad * s, font: spec.chipFont * s)
                Spacer()
                Text(word)
                    .font(RFMFonts.hardware(spec.wordFont * s))
                    .tracking(spec.wordFont * s * spec.wordTracking)
                    .foregroundStyle(theme.label.color)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { onWord?() }
                    .accessibilityAddTraits(onWord == nil ? .isHeader : [.isHeader, .isButton])
                    .accessibilityHint(onWord == nil ? "" : "Opens the firmware")
            }
            Grabber(theme: theme, width: spec.grabberWidth * s, bar: spec.barWidth * s, open: openSheet)
        }
        .frame(width: (m.ref.width - 2 * spec.margin) * m.sx, height: h)
        .position(x: m.ox + m.ref.width * m.sx / 2, y: y + h / 2)
    }
}

struct Chip: View {
    let theme: Theme
    let chip: PanelChip
    let height: CGFloat, pad: CGFloat, font: CGFloat

    var body: some View {
        let dot: Color = switch chip {
        case .linked: Palette.linkedDot
        case .inUse: Palette.sheetAccent
        case .emulator, .searching: theme.label.color
        }
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 7, height: 7)
                .opacity(chip == .searching ? 0.5 : 1)
            Text(chip.text).font(RFMFonts.ui(font, 600)).foregroundStyle(theme.label.color).lineLimit(1)
        }
        .padding(.horizontal, pad)
        .frame(height: height)
        .background(Capsule().fill(Color.black.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

/// the pull-down handle: a tap or a swipe down opens the sheet (88 x 44 hit area)
struct Grabber: View {
    let theme: Theme
    let width: CGFloat, bar: CGFloat
    var height: CGFloat = 44
    let open: () -> Void

    var body: some View {
        Capsule().fill(theme.label.color.opacity(0.55))
            .frame(width: bar, height: 5)
            .frame(width: max(width, 88), height: max(height, 44))
            .contentShape(Rectangle())
            .onTapGesture { open() }
            .gesture(DragGesture(minimumDistance: 8).onEnded { v in if v.translation.height > 20 { open() } })
            .accessibilityElement()
            .accessibilityLabel("Open controls, or swipe down")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
    }
}

struct PageDots: View {
    let theme: Theme
    @Bindable var ui: FaceplateUI
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FaceplateUI.Page.allCases, id: \.self) { p in
                let on = ui.page == p
                Capsule().fill(theme.label.color.opacity(on ? 1 : 0.35))
                    .frame(width: (on ? 22 : 8) * scale, height: 8 * scale)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { ui.page = p } }
                    .accessibilityElement()
                    .accessibilityLabel(p == .full ? "Full view" : p == .controls ? "Controls view" : "Screen view")
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { ui.page = p }
            }
        }
        .frame(width: 132, height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Views")
    }
}

// MARK: - Full

struct FullView: View {
    let feed: PanelFeed
    @Bindable var ui: FaceplateUI
    let theme: Theme
    let chip: PanelChip
    let kind: FaceplateLayout.Kind
    let size: CGSize
    let chrome: Bool
    let openSheet: () -> Void

    var body: some View {
        let L = FaceplateLayout.full(kind)
        let m = FaceplateLayout.Mapper(ref: kind.ref, size: size)
        let s = m.s
        ZStack(alignment: .topLeading) {
            if chrome, let st = L.status {
                StatusRow(theme: theme, chip: chip, spec: st, m: m, word: ui.word, onWord: ui.onWord, openSheet: openSheet)
            } else if chrome, let gr = L.grabber {
                Grabber(theme: theme, width: gr.width * s, bar: 40 * s, height: gr.height * s, open: openSheet)
                    .position(x: size.width / 2, y: max(22, m.y(gr.midY)))
            }
            // MAIN knobs, 2 x 2
            KnobGrid(knobs: PanelFeed.Knob.main, c: L.main, m: m, theme: theme, feed: feed)
            // OCT well
            let o = L.oct
            OctWell(theme: theme, feed: feed, pad: o.pad * s, gap: o.gap * s, radius: o.radius * s,
                    buttonRadius: o.buttonRadius * s, font: o.font * s, height: o.height * m.sy)
                .place(m.rect(o.x, o.y, o.width, o.height))
            // the display
            let ds = L.displaySize * s
            let dr = CGRect(x: m.x(L.display.x) + L.displaySize * m.sx / 2 - ds / 2, y: m.y(L.display.y),
                            width: ds, height: ds)
            ProtectedDisplay(feed: feed, theme: theme, size: ds, ui: ui)
                .position(x: dr.midX, y: dr.midY)
            // KN1-4
            switch L.kn {
            case .row(let x, let y, let w, let knob, let led):
                KnRow(m: m, x: x, y: y, width: w, knob: knob, led: led, theme: theme, feed: feed)
            case .grid(let c, _, _, _):
                KnobGrid(knobs: PanelFeed.Knob.kn, c: c, m: m, theme: theme, feed: feed)
            }
            // the buttons
            let b = L.buttons
            ButtonGrid(theme: theme, feed: feed, bw: b.bw * m.sx, bh: b.bh * m.sy, gap: b.gap * s)
                .fixedSize()
                .position(x: m.x(b.x) + b.size.width * m.sx / 2, y: m.y(b.y) + (2 * b.bh * m.sy + b.gap * s + 20) / 2)
            // the keybed
            let kr = m.rect(L.keybed.minX, L.keybed.minY, L.keybed.width, L.keybed.height)
            KeybedView(theme: theme, feed: feed, size: kr.size,
                       layout: L.keyWidth.map { .scroll(keyWidth: $0 * m.sx) } ?? .row,
                       stepNumbers: ui.stepNumbers, offset: $ui.fullOffset)
                .place(kr)
                .defersSystemGestures(on: .bottom)
            if chrome, L.pageDots {
                PageDots(theme: theme, ui: ui, scale: s)
                    .position(x: size.width / 2, y: size.height - 18 * m.sy - 12)
            }
            // the screen protector: its film over the display, its red tab beside the screen
            ScreenFilm(geo: FilmGeometry(display: dr, radius: max(10, (ds * 0.09).rounded()),
                                         tab: FilmGeometry.tab(display: dr, below: kind == .phonePortrait)))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// knobs in a 2 x 2 grid of cells width/2 wide (the canvas's grid, items centred)
struct KnobGrid: View {
    let knobs: [PanelFeed.Knob]
    let c: FaceplateLayout.Cluster
    let m: FaceplateLayout.Mapper
    let theme: Theme
    let feed: PanelFeed

    var body: some View {
        let size = c.knob * m.s
        let cell = KnobView.cell(size)
        let colW = c.width * m.sx / 2
        ForEach(Array(knobs.enumerated()), id: \.offset) { i, k in
            let col = CGFloat(i % 2), row = CGFloat(i / 2)
            KnobView(knob: k, size: size, theme: theme, feed: feed, labelWidth: colW)
                .position(x: m.x(c.x) + colW * (col + 0.5),
                          y: m.y(c.y) + row * (cell.height + c.rowGap * m.sy) + cell.height / 2)
        }
    }
}

/// KN1-4 spread across a width (the canvas's space-between row; its first slot, led wide, left empty: the FM-1's
/// red square there is the screen protector's tab, see ScreenFilm)
struct KnRow: View {
    let m: FaceplateLayout.Mapper
    let x: CGFloat, y: CGFloat, width: CGFloat, knob: CGFloat, led: CGFloat
    let theme: Theme
    let feed: PanelFeed

    var body: some View {
        let size = knob * m.s
        let cell = KnobView.cell(size)
        let w = width * m.sx
        let ledW = led * m.s
        let gap = (w - ledW - 4 * cell.width) / 4
        let cy = m.y(y) + cell.height / 2
        ForEach(Array(PanelFeed.Knob.kn.enumerated()), id: \.offset) { i, k in
            KnobView(knob: k, size: size, theme: theme, feed: feed, labelWidth: cell.width + gap)
                .position(x: m.x(x) + ledW + gap * CGFloat(i + 1) + cell.width * (CGFloat(i) + 0.5), y: cy)
        }
    }
}

// MARK: - Controls

struct ControlsView: View {
    let feed: PanelFeed
    @Bindable var ui: FaceplateUI
    let theme: Theme
    let chip: PanelChip
    let size: CGSize
    let chrome: Bool
    let openSheet: () -> Void

    var body: some View {
        let landscape = size.width > size.height
        let L = FaceplateLayout.controls(landscape: landscape)
        let m = FaceplateLayout.Mapper(ref: L.ref, size: size, uniform: size.width > 600)
        let s = m.s
        ZStack(alignment: .topLeading) {
            if chrome, let st = L.status {
                StatusRow(theme: theme, chip: chip, spec: st, m: m, word: ui.word, onWord: ui.onWord, openSheet: openSheet)
            } else if chrome, let gr = L.grabber {
                Grabber(theme: theme, width: gr.width * s, bar: 40 * s, height: gr.height * s, open: openSheet)
                    .position(x: size.width / 2, y: max(22, m.y(gr.midY)))
            }
            let ds = L.displaySize * s
            ProtectedDisplay(feed: feed, theme: theme, size: ds, ui: ui)
                .position(x: m.x(L.display.x) + L.displaySize * m.sx / 2, y: m.y(L.display.y) + ds / 2)
            // the deck's background: a sideways swipe here changes the deck
            Color.clear.contentShape(Rectangle())
                .gesture(swipe { d in withAnimation(.easeInOut(duration: 0.2)) { ui.deck = d > 0 ? .keys : .buttons } })
                .place(m.rect(L.deck.minX, L.deck.minY, L.deck.width, L.deck.height))
                .accessibilityHidden(true)
            // the knob row (its gaps swipe the set too)
            Color.clear.contentShape(Rectangle())
                .gesture(swipe { _ in toggleSet() })
                .place(m.rect(L.knobRow.minX, L.knobRow.minY, L.knobRow.width, L.knobRow.height))
                .accessibilityHidden(true)
            knobRow(L, m)
            SetSwitch(theme: theme, ui: ui, scale: s)
                .place(m.rect(L.setSwitch.minX, L.setSwitch.minY, L.setSwitch.width, L.setSwitch.height))
            DeckSwitch(theme: theme, ui: ui, scale: s)
                .place(m.rect(L.deckSwitch.minX, L.deckSwitch.minY, L.deckSwitch.width, L.deckSwitch.height))
            if ui.deck == .buttons {
                let b = L.buttons
                ButtonGrid(theme: theme, feed: feed, bw: b.bw * m.sx, bh: b.bh * m.sy, gap: b.gap * s)
                    .fixedSize()
                    .position(x: m.x(b.x) + b.size.width * m.sx / 2, y: m.y(b.y) + (2 * b.bh * m.sy + b.gap * s + 20) / 2)
                    .transition(.opacity)
                let o = L.oct
                OctWell(theme: theme, feed: feed, pad: o.pad * s, gap: o.gap * s, radius: o.radius * s,
                        buttonRadius: o.buttonRadius * s, font: o.font * s, height: o.height * m.sy)
                    .place(m.rect(o.x, o.y, o.width, o.height))
                    .transition(.opacity)
            } else {
                let kr = m.rect(L.keybed.minX, L.keybed.minY, L.keybed.width, L.keybed.height)
                KeybedView(theme: theme, feed: feed, size: kr.size, layout: .scroll(keyWidth: L.keyWidth * m.sx),
                           stepNumbers: ui.stepNumbers, offset: $ui.deckOffset)
                    .place(kr)
                    .defersSystemGestures(on: .bottom)
                    .transition(.opacity)
            }
            if chrome {
                PageDots(theme: theme, ui: ui, scale: s)
                    .position(x: size.width / 2, y: size.height - 18 * m.sy - 12)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func toggleSet() {
        withAnimation(.easeInOut(duration: 0.2)) { ui.knobSet = ui.knobSet == .main ? .kn : .main }
    }

    @ViewBuilder private func knobRow(_ L: FaceplateLayout.Controls, _ m: FaceplateLayout.Mapper) -> some View {
        let size = L.knob * m.s
        let cell = KnobView.cell(size)
        let w = L.knobRow.width * m.sx
        let gap = (w - 4 * cell.width) / 3
        let set = ui.knobSet == .main ? PanelFeed.Knob.main : PanelFeed.Knob.kn
        ForEach(Array(set.enumerated()), id: \.element) { i, k in
            KnobView(knob: k, size: size, theme: theme, feed: feed, onSwipe: { _ in toggleSet() })
                .position(x: m.x(L.knobRow.minX) + CGFloat(i) * (cell.width + gap) + cell.width / 2,
                          y: m.y(L.knobRow.minY) + cell.height / 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Knobs, swipe sideways to switch sets")
    }
}

/// MAIN | KN 1-4 (32 pt tall: a 44 pt hit area round it)
struct SetSwitch: View {
    let theme: Theme
    @Bindable var ui: FaceplateUI
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 6 * scale) {
            tab("MAIN", .main)
            tab("KN 1–4", .kn)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Knob set")
    }

    private func tab(_ t: String, _ s: FaceplateUI.KnobSet) -> some View {
        let on = ui.knobSet == s
        let f: CGFloat = 10 * scale, h: CGFloat = 32 * scale
        let extra: CGFloat = max(0, (44 - h) / 2)
        let fill: Color = on ? Color.black.opacity(0.18) : Color.clear
        let text = Text(t).font(RFMFonts.hardware(f)).tracking(f * 0.12).foregroundStyle(theme.label.color)
        return text
            .padding(.horizontal, f)
            .frame(height: h)
            .background(Capsule().fill(fill))
            .padding(.vertical, extra)
            .contentShape(Rectangle())
            .padding(.vertical, -extra)
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { ui.knobSet = s } }
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { ui.knobSet = s }
    }
}

/// BUTTONS | KEYS
struct DeckSwitch: View {
    let theme: Theme
    @Bindable var ui: FaceplateUI
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            seg("BUTTONS", .buttons)
            seg("KEYS", .keys)
        }
        .padding(3 * scale)
        .background(Capsule().fill(Color.black.opacity(0.16)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lower deck, or swipe sideways")
    }

    private func seg(_ t: String, _ d: FaceplateUI.Deck) -> some View {
        let on = ui.deck == d
        return Text(t)
            .font(RFMFonts.hardware(12 * scale))
            .tracking(12 * scale * 0.1)
            .foregroundStyle(on ? theme.keyText.color : theme.label.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(on ? theme.key.color : .clear))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { ui.deck = d } }
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { ui.deck = d }
    }
}

// MARK: - Screen

struct ScreenOnlyView: View {
    let feed: PanelFeed
    let ui: FaceplateUI
    let theme: Theme
    let chip: PanelChip
    let size: CGSize
    let chrome: Bool
    let openSheet: () -> Void

    var body: some View {
        let portrait = size.height >= size.width
        let ref = portrait ? FaceplateLayout.Kind.phonePortrait.ref : FaceplateLayout.Kind.phoneLandscape.ref
        let m = FaceplateLayout.Mapper(ref: ref, size: size, uniform: true)
        let margin = 16 * m.s
        let top: CGFloat = portrait ? 0 : 22
        let side = max(40, min(size.width - 2 * margin, size.height - 2 * margin - 2 * top))
        ZStack(alignment: .topLeading) {
            if chrome {
                if portrait, size.width < 600 {
                    StatusRow(theme: theme, chip: chip, spec: FaceplateLayout.phoneStatus, m: m, word: "SCREEN",
                              openSheet: openSheet)
                } else if portrait {
                    StatusRow(theme: theme, chip: chip, spec: FaceplateLayout.padStatus,
                              m: FaceplateLayout.Mapper(ref: FaceplateLayout.Kind.padPortrait.ref, size: size),
                              word: "SCREEN", openSheet: openSheet)
                } else {
                    Grabber(theme: theme, width: 88, bar: 40, height: 20, open: openSheet)
                        .position(x: size.width / 2, y: 22)
                }
            }
            ProtectedDisplay(feed: feed, theme: theme, size: side, ui: ui)
                .position(x: size.width / 2, y: size.height / 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
#endif
