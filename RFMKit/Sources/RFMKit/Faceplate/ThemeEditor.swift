// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The theme editor (design/README.md section 6, canvas/Theme.dc.html): a live preview (the iPad-landscape faceplate
// scaled down, so it always shows the real arrangement), the preset tiles, and five colours: Faceplate, Keys and
// buttons, Knobs, LEDs and the display's bezel (the design's "Display" row: the LCD colour is only the mock's, so here
// it is the bezel, as section 6 suggests). Changing a colour derives the rest (Theme.derived). Done keeps the result
// (an edited theme is stored as "My theme"); Save as my theme stores it; Cancel leaves the theme as it was.

#if os(iOS)
import SwiftUI
import UIKit

public struct ThemeEditor: View {
    let store: ThemeStore
    let feed: PanelFeed
    let close: () -> Void
    @State private var draft: Theme
    @State private var edited = false
    @State private var previewUI = FaceplateUI()

    public init(store: ThemeStore, feed: PanelFeed, close: @escaping () -> Void) {
        self.store = store
        self.feed = feed
        self.close = close
        _draft = State(initialValue: store.current)
    }

    enum Part: CaseIterable {
        case body, key, knob, led, bezel
        var label: String {
            switch self {
            case .body: "Faceplate"
            case .key: "Keys and buttons"
            case .knob: "Knobs"
            case .led: "LEDs"
            case .bezel: "Display bezel"
            }
        }
    }

    func color(_ p: Part) -> RGB {
        switch p {
        case .body: draft.body
        case .key: draft.key
        case .knob: draft.knob
        case .led: draft.led
        case .bezel: draft.bezel
        }
    }

    func set(_ p: Part, _ c: RGB) {
        var ch = draft.choice
        switch p {
        case .body: ch.body = c
        case .key: ch.key = c
        case .knob: ch.knob = c
        case .led: ch.led = c
        case .bezel: ch.bezel = c
        }
        guard ch != draft.choice else { return }
        draft = Theme.derived(ch, base: draft)
        edited = true
    }

    public var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    preview(width: min(geo.size.width - 32, 560))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                    SheetSectionTitle("Presets", top: 28)
                    presets
                    SheetSectionTitle("Customize", top: 24)
                    SheetList {
                        ForEach(Array(Part.allCases.enumerated()), id: \.offset) { i, p in
                            colorRow(p, divider: i < Part.allCases.count - 1)
                        }
                    }
                    Button {
                        store.saveCustom(draft)
                        close()
                    } label: {
                        Text("Save as my theme").font(RFMFonts.ui(15, 700)).foregroundStyle(Palette.sheetText)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .overlay(Capsule().strokeBorder(Palette.sheetBorder, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Palette.sheetBackground.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        ZStack {
            Text("Theme").font(RFMFonts.title(17)).tracking(-0.17).foregroundStyle(Palette.sheetText)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: close) {
                    Text("Cancel").font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetMuted2)
                        .padding(.horizontal, 4).frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    if edited { store.saveCustom(draft) } else { store.select(draft.name) }
                    close()
                } label: {
                    Text("Done").font(RFMFonts.ui(14, 700)).foregroundStyle(Palette.sheetBackground)
                        .padding(.horizontal, 16).frame(height: 44)
                        .background(Capsule().fill(Palette.sheetAccent))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 44)
        .padding(.top, 6)
    }

    /// the iPad-landscape faceplate, no chrome, scaled into the card (Theme.dc.html: 358 x 258, 12 padding)
    private func preview(width: CGFloat) -> some View {
        let inner = width - 24
        let k = inner / 1194
        return FaceplateView(feed: feed, ui: previewUI, theme: draft, chip: .emulator, kind: .padLandscape, chrome: false)
            .frame(width: 1194, height: 834)
            .scaleEffect(k, anchor: .topLeading)
            .frame(width: inner, height: 834 * k, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .allowsHitTesting(false)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(draft.body.color))
            .accessibilityElement()
            .accessibilityLabel("Preview of the full FM-1 layout")
    }

    private var presets: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
        return LazyVGrid(columns: cols, spacing: 6) {
            ForEach(store.all) { t in
                let on = !edited && draft.name == t.name
                Button {
                    draft = t
                    edited = false
                } label: {
                    VStack(spacing: 7) {
                        ThemeSwatch(theme: t, selected: false, ringed: false)
                            .overlay(Circle().strokeBorder(on ? Palette.sheetAccent : .clear, lineWidth: 2).padding(2))
                            .frame(width: 44, height: 44)
                        Text(t.name).font(RFMFonts.ui(11, 600)).foregroundStyle(Palette.sheetText).lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).frame(height: 76)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(on ? Palette.sheetRaised : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(t.name) theme")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }

    private func colorRow(_ p: Part, divider: Bool) -> some View {
        let c = color(p)
        return HStack(spacing: 12) {
            Circle().fill(c.color).frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            Text(p.label).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText)
            Spacer()
            Text(c.hex).font(RFMFonts.mono(13)).foregroundStyle(Palette.sheetMuted2)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.sheetMuted2)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture { ColorPicking.shared.present(c, title: p.label) { set(p, $0) } }
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(p.label), \(c.hex)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { ColorPicking.shared.present(c, title: p.label) { set(p, $0) } }
    }
}

/// the system colour picker (UIKit), presented over the top view controller; each change goes to `changed`
@MainActor
final class ColorPicking: NSObject, UIColorPickerViewControllerDelegate {
    static let shared = ColorPicking()
    private var changed: ((RGB) -> Void)?

    func present(_ c: RGB, title: String, changed: @escaping (RGB) -> Void) {
        let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?
            .rootViewController
        guard var top = root else { return }
        while let p = top.presentedViewController { top = p }
        self.changed = changed
        let vc = UIColorPickerViewController()
        vc.title = title
        vc.supportsAlpha = false
        vc.selectedColor = UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        vc.delegate = self
        vc.overrideUserInterfaceStyle = .dark
        top.present(vc, animated: true)
    }

    nonisolated func colorPickerViewController(_ vc: UIColorPickerViewController, didSelect color: UIColor,
                                               continuously: Bool) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        let c = RGB(Double(r), Double(g), Double(b))
        MainActor.assumeIsolated { changed?(c) }
    }
}
#endif
