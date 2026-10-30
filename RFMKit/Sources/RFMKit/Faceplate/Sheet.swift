// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The pull-down sheet (design/README.md section 3, canvas/PhoneSheet.dc.html) and its building blocks: the panel
// that comes down from the top over a dimmed faceplate, its header, section titles, the Sound source cards, the
// View tiles, the theme swatches, the list rows and a sub-page with a back button. The app and the AUv3 put their
// own items in it. It is drawn in the view itself (no SwiftUI .sheet: that crashed inside the extension, M2).
// M8: a segmented row (Knob speed), a stepper row (Transpose, MIDI octave), a status line with a dot (the OMX-27), a
// back title for pages under pages (MIDI input), and a first scroll position (screenshots). Get firmware: a row's badge.

#if os(iOS)
import SwiftUI

/// the sheet: dims the faceplate, comes down from the top; Done, a tap on the dimmed part or a swipe up closes it
public struct PullDownSheet<Content: View>: View {
    @Binding var open: Bool
    let content: Content
    @State private var drag: CGFloat = 0

    public init(open: Binding<Bool>, @ViewBuilder content: () -> Content) {
        _open = open
        self.content = content()
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let top = geo.safeAreaInsets.top
            let w = min(size.width, 560)
            // (below the safe area's top; the panel's background reaches up behind the status bar)
            let full = size.height + top
            let h = (full < 500 ? full - 6 : min(full * 0.83, 760)) - top      // (the canvas: 79 %; a bit more fits the list)
            ZStack(alignment: .top) {
                if open {
                    Color(.sRGB, red: 10 / 255, green: 8 / 255, blue: 6 / 255, opacity: 0.45)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .accessibilityLabel("Close controls")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)
                    VStack(spacing: 0) {
                        content
                            .padding(.top, top > 0 ? 9 : 14)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        // the bottom grabber: swipe up (or tap) to close
                        Capsule().fill(Palette.sheetDim).frame(width: 40, height: 5)
                            .frame(width: 88, height: 32)
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                            .accessibilityElement()
                            .accessibilityLabel("Close controls, or swipe up")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { close() }
                    }
                    .frame(width: w, height: h)
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: 32, bottomTrailingRadius: 32, style: .continuous)
                        .fill(Palette.sheetBackground)
                        .shadow(color: .black.opacity(0.35), radius: 20, y: 18)
                        .padding(.top, -top))
                    .offset(y: min(0, drag))
                    .gesture(DragGesture(minimumDistance: 12)
                        .onChanged { v in if v.translation.height < 0, abs(v.translation.height) > abs(v.translation.width) { drag = v.translation.height } }
                        .onEnded { v in
                            if v.translation.height < -60 { close() }
                            withAnimation(.easeOut(duration: 0.2)) { drag = 0 }
                        })
                    .transition(.move(edge: .top))
                    .environment(\.colorScheme, .dark)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.28), value: open)
    }

    private func close() { withAnimation(.easeInOut(duration: 0.28)) { open = false } }
}

public struct SheetHeader: View {
    let title: String
    let done: () -> Void

    public init(_ title: String, done: @escaping () -> Void) {
        self.title = title
        self.done = done
    }

    public var body: some View {
        HStack {
            Text(title).font(RFMFonts.title(22)).tracking(-0.44).foregroundStyle(Palette.sheetText)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: done) {
                Text("Done").font(RFMFonts.ui(14, 700)).foregroundStyle(Palette.sheetText)
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(Capsule().fill(Palette.sheetRaised))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 44)
    }
}

public struct SheetSectionTitle: View {
    let text: String
    var top: CGFloat = 20

    public init(_ text: String, top: CGFloat = 20) {
        self.text = text
        self.top = top
    }

    public var body: some View {
        Text(text.uppercased())
            .font(RFMFonts.ui(11, 600)).tracking(11 * 0.16)
            .foregroundStyle(Palette.sheetMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, top).padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }
}

/// a Sound source card: a dot, a title, a line under it
public struct SourceCard: View {
    let title: String, sub: String
    let selected: Bool
    let dot: Color
    let action: () -> Void

    public init(title: String, sub: String, selected: Bool, dot: Color, action: @escaping () -> Void) {
        self.title = title
        self.sub = sub
        self.selected = selected
        self.dot = dot
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle().fill(selected ? dot : Palette.sheetDim).frame(width: 8, height: 8)
                    Text(title).font(RFMFonts.ui(15, 700)).foregroundStyle(Palette.sheetText)
                }
                Text(sub).font(RFMFonts.ui(12)).foregroundStyle(Palette.sheetMuted2).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(selected ? Palette.sheetRaised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(selected ? Palette.sheetAccent : Palette.sheetBorder, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// the View tiles: Full, Panel (Controls with the buttons), Keys (Controls with the keys), Screen
public struct ViewTiles: View {
    @Bindable var ui: FaceplateUI
    let pick: () -> Void

    public init(ui: FaceplateUI, pick: @escaping () -> Void = {}) {
        self.ui = ui
        self.pick = pick
    }

    enum Tile: CaseIterable { case full, panel, keys, screen }

    func selected(_ t: Tile) -> Bool {
        switch t {
        case .full: ui.page == .full
        case .panel: ui.page == .controls && ui.deck == .buttons
        case .keys: ui.page == .controls && ui.deck == .keys
        case .screen: ui.page == .screen
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(Tile.allCases, id: \.self) { t in
                let on = selected(t)
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        switch t {
                        case .full: ui.page = .full
                        case .panel: ui.page = .controls; ui.deck = .buttons
                        case .keys: ui.page = .controls; ui.deck = .keys
                        case .screen: ui.page = .screen
                        }
                    }
                    pick()
                } label: {
                    VStack(spacing: 9) {
                        wire(t).frame(width: 48, height: 40)
                        Text(name(t)).font(RFMFonts.ui(12, on ? 700 : 600)).foregroundStyle(Palette.sheetText)
                    }
                    .frame(maxWidth: .infinity).frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(on ? Palette.sheetRaised : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(on ? Palette.sheetAccent : Palette.sheetBorder, lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name(t)) view")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    func name(_ t: Tile) -> String {
        switch t {
        case .full: "Full"
        case .panel: "Panel"
        case .keys: "Keys"
        case .screen: "Screen"
        }
    }

    /// the tiles' mini wireframes
    @ViewBuilder func wire(_ t: Tile) -> some View {
        let fg = Palette.sheetText, dim = Palette.sheetDim, acc = Palette.sheetAccent
        switch t {
        case .full:
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3).fill(dim).frame(width: 12)
                    RoundedRectangle(cornerRadius: 3).fill(fg).frame(width: 20)
                    RoundedRectangle(cornerRadius: 3).fill(dim)
                }
                .frame(height: 20)
                RoundedRectangle(cornerRadius: 3).fill(acc)
            }
        case .panel, .keys:
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(fg).frame(width: t == .panel ? 22 : 20, height: t == .panel ? 22 : 20)
                RoundedRectangle(cornerRadius: 3).fill(t == .panel ? dim : acc).frame(width: 48)
            }
        case .screen:
            RoundedRectangle(cornerRadius: 4).fill(fg).frame(width: 38, height: 38)
        }
    }
}

/// a theme's swatch: body, bed, LED, ringed when chosen
struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool
    var ringed = true

    var body: some View {
        Circle().fill(theme.body.color).frame(width: 40, height: 40)
            .overlay(Circle().fill(theme.bed.color).frame(width: 22, height: 22))
            .overlay(Circle().fill(theme.led.color).frame(width: 8, height: 8))
            .padding(4)
            .background(Circle().fill(selected && ringed ? Palette.sheetAccent : .clear))
    }
}

/// the preset swatches (and the user's theme) and Edit
public struct ThemeSwatches: View {
    let store: ThemeStore
    let edit: (() -> Void)?

    public init(store: ThemeStore, edit: (() -> Void)?) {
        self.store = store
        self.edit = edit
    }

    public var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.all) { t in
                        Button { store.select(t.name) } label: {
                            ThemeSwatch(theme: t, selected: store.current.name == t.name)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(t.name) theme")
                        .accessibilityAddTraits(store.current.name == t.name ? .isSelected : [])
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            if let edit {
                Button(action: edit) {
                    Text("Edit").font(RFMFonts.ui(13, 600)).foregroundStyle(Palette.sheetText)
                        .padding(.horizontal, 16).frame(height: 44)
                        .overlay(Capsule().strokeBorder(Palette.sheetBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// the list at the sheet's bottom (Firmware, MIDI & audio, Settings) and the sub-pages' lists
public struct SheetList<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.sheetSurface))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

public struct SheetRow: View {
    let title: String
    var value: String?
    var divider = true
    var chevron = true
    var check = false
    var badge = 0
    let action: () -> Void

    /// badge: a count in an accent dot (updates), 0 none
    public init(_ title: String, value: String? = nil, divider: Bool = true, chevron: Bool = true, check: Bool = false,
                badge: Int = 0, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.divider = divider
        self.chevron = chevron
        self.check = check
        self.badge = badge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText).lineLimit(1)
                Spacer(minLength: 8)
                if badge > 0 {
                    Text("\(badge)").font(RFMFonts.ui(12, 700)).foregroundStyle(Palette.sheetBackground)
                        .monospacedDigit()
                        .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                        .background(Capsule().fill(Palette.sheetAccent))
                        .accessibilityLabel(badge == 1 ? "1 update" : "\(badge) updates")
                }
                if let value {
                    Text(value).font(RFMFonts.ui(15, 500)).foregroundStyle(Palette.sheetMuted2).lineLimit(1)
                }
                if check {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.sheetAccent)
                }
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.sheetMuted2)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
        .accessibilityAddTraits(check ? .isSelected : [])
    }
}

/// a toggle row in a SheetList
public struct SheetToggle: View {
    let title: String
    @Binding var on: Bool
    var divider = true

    public init(_ title: String, on: Binding<Bool>, divider: Bool = true) {
        self.title = title
        _on = on
        self.divider = divider
    }

    public var body: some View {
        Toggle(isOn: $on) {
            Text(title).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText)
        }
        .tint(Palette.sheetAccent)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
    }
}

/// (M8) 0..1, 1.2 times a second (panel.js's pulse: MIDI learn, a busy status); 1 with Reduce Motion
struct Pulse<Content: View>: View {
    let on: Bool
    @ViewBuilder let content: (Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        if on && !still {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                content(0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 2 * .pi * 1.2))
            }
        } else {
            content(1)
        }
    }
}

/// (M8) a row with a segmented choice on its right (Knob speed: ½× 1× 2×)
public struct SheetSegmented: View {
    let title: String
    let options: [String]
    let selected: Int
    var divider = true
    let pick: (Int) -> Void

    public init(_ title: String, options: [String], selected: Int, divider: Bool = true, pick: @escaping (Int) -> Void) {
        self.title = title
        self.options = options
        self.selected = selected
        self.divider = divider
        self.pick = pick
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                    let on = i == selected
                    Button { pick(i) } label: {
                        Text(o).font(RFMFonts.ui(13, on ? 700 : 600)).lineLimit(1)
                            .foregroundStyle(on ? Palette.sheetBackground : Palette.sheetText)
                            .padding(.horizontal, 8)
                            .frame(minWidth: 44).frame(height: 30)
                            .background(Capsule().fill(on ? Palette.sheetAccent : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(o)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Capsule().fill(Palette.sheetRaised))
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
    }
}

/// (M8) a row with a − value + stepper (Transpose, MIDI octave)
public struct SheetStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let text: (Int) -> String
    var divider = true

    public init(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, divider: Bool = true,
                text: @escaping (Int) -> String = { "\($0 > 0 ? "+" : "")\($0)" }) {
        self.title = title
        _value = value
        self.range = range
        self.text = text
        self.divider = divider
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText).lineLimit(1)
            Spacer(minLength: 8)
            Text(text(value)).font(RFMFonts.ui(15, 500)).foregroundStyle(Palette.sheetMuted2).lineLimit(1)
                .monospacedDigit()
            HStack(spacing: 0) {
                step("minus", -1)
                Palette.sheetLine.frame(width: 1, height: 18)
                step("plus", 1)
            }
            .background(Capsule().fill(Palette.sheetRaised))
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text(value))
        .accessibilityAdjustableAction { d in move(d == .increment ? 1 : -1) }
    }

    private func move(_ d: Int) { value = max(range.lowerBound, min(range.upperBound, value + d)) }

    private func step(_ icon: String, _ d: Int) -> some View {
        let can = range.contains(value + d)
        return Button { move(d) } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
                .foregroundStyle(can ? Palette.sheetText : Palette.sheetDim)
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!can)
    }
}

/// (M8) a status line: a coloured dot and its text (the OMX-27's)
public struct SheetStatus: View {
    let text: String
    let dot: Color
    var pulsing = false
    var color = Palette.sheetMuted

    public init(_ text: String, dot: Color, pulsing: Bool = false, color: Color = Palette.sheetMuted) {
        self.text = text
        self.dot = dot
        self.pulsing = pulsing
        self.color = color
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Pulse(on: pulsing) { p in
                Circle().fill(dot).frame(width: 8, height: 8).opacity(pulsing ? 0.35 + 0.65 * p : 1)
            }
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            Text(text).font(RFMFonts.ui(12, 500)).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }
}

/// a sub-page of the sheet: "‹ back" and a title, then its content (scrolls)
public struct SheetPage<Content: View>: View {
    let title: String
    let backTitle: String
    let back: () -> Void
    let scrollTo: String?
    let content: Content

    /// scrollTo: an id in the content shown at the top at first (screenshots)
    public init(_ title: String, backTitle: String = "Controls", scrollTo: String? = nil, back: @escaping () -> Void,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.backTitle = backTitle
        self.scrollTo = scrollTo
        self.back = back
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                        Text(backTitle).font(RFMFonts.ui(15, 600))
                    }
                    .foregroundStyle(Palette.sheetMuted2)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Text(title).font(RFMFonts.title(20)).tracking(-0.4).foregroundStyle(Palette.sheetText)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.bottom, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onAppear {
                    guard let scrollTo else { return }
                    DispatchQueue.main.async { proxy.scrollTo(scrollTo, anchor: .top) }
                }
            }
        }
    }
}

/// small print in the sheet
public struct SheetNote: View {
    let text: String
    var color = Palette.sheetMuted

    public init(_ text: String, color: Color = Palette.sheetMuted) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text).font(RFMFonts.ui(12)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }
}

/// (M7) a short note over the faceplate (a Wasm core that can't keep up): a tap hides it until the problem has gone
/// and come back
public struct PerfBanner: View {
    let text: String
    @State private var hidden = false

    public init(_ text: String) { self.text = text }

    public var body: some View {
        content.onChange(of: text.isEmpty) { _, empty in if empty { hidden = false } }
    }

    @ViewBuilder private var content: some View {
        if !text.isEmpty && !hidden {
            Text(text).font(RFMFonts.ui(12, 600)).foregroundStyle(.black)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.92)))
                .frame(maxWidth: 520)
                .padding(.horizontal, 16)
                .onTapGesture { hidden = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Hides the note")
                .transition(.opacity)
        }
    }
}

/// a pill button in the sheet (accent: the prominent one)
public struct SheetButton: View {
    let title: String
    var accent = false
    let action: () -> Void

    public init(_ title: String, accent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.accent = accent
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title).font(RFMFonts.ui(14, 700))
                .foregroundStyle(accent ? Palette.sheetBackground : Palette.sheetText)
                .padding(.horizontal, 16).frame(height: 44)
                .background(Capsule().fill(accent ? Palette.sheetAccent : Palette.sheetRaised))
        }
        .buttonStyle(.plain)
    }
}
#endif
