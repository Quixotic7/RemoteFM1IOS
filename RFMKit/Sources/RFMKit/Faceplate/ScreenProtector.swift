// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The display up close and its film:
//   ScreenProtector  the red protective film the FM-1 ships with, drawn faintly over the display with its red tab at a
//                    corner. Dragging the tab folds the film back (the fold line follows the finger); let go early and
//                    it springs back, past a third of the way it peels off and is gone. Remembered (UserDefaults:
//                    the app's; in the AU the extension's, so one setting for every instance). Settings › View puts it
//                    back. Only the tab takes touches; the film itself never does.
//   ProtectedDisplay the faceplate's display with the film, and a double tap that shows the display alone
//   FullDisplay      the display alone: black, aspect-correct (240 x 240), as large as fits; a double tap or a swipe
//                    down closes it

import Foundation
import Observation
import SwiftUI

/// whether the film is still on (default: on, as the FM-1 comes)
@MainActor @Observable public final class ScreenProtector {
    public static let key = "rfm1.screenProtector"
    public static let shared = ScreenProtector()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public var startFold: CGFloat = 0     // (screenshots) the film drawn this far folded at first
    public var on: Bool { didSet { defaults.set(on, forKey: Self.key) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        on = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    /// the fold's travel (0...1) from the finger's movement, the tab at the bottom-leading corner (flipped: top-trailing)
    public nonisolated static func fold(dx: CGFloat, dy: CGFloat, side: CGFloat, flipped: Bool) -> CGFloat {
        guard side > 0 else { return 0 }
        let c = (flipped ? dy - dx : dx - dy) / 2
        return min(1, max(0, c / side))
    }

    /// let go at this fold: peeled off (true) or back on
    public nonisolated static func peels(_ fold: CGFloat) -> Bool { fold > 0.33 }
}

#if os(iOS)
/// the film left on: the square minus the folded corner (c: the fold's travel in points, the tab's corner bottom-leading)
struct FilmLeft: Shape {
    var c: CGFloat
    var animatableData: CGFloat { get { c } set { c = newValue } }

    func path(in r: CGRect) -> Path {
        let s = r.width, c = min(max(c, 0), s)
        var p = Path()
        p.move(to: CGPoint(x: c, y: s))
        p.addLine(to: CGPoint(x: s, y: s))
        p.addLine(to: CGPoint(x: s, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: s - c))
        p.closeSubpath()
        return p
    }
}

/// the folded-back flap: the corner reflected across the fold line
struct FilmFlap: Shape {
    var c: CGFloat
    var animatableData: CGFloat { get { c } set { c = newValue } }

    func path(in r: CGRect) -> Path {
        let s = r.width, c = min(max(c, 0), s)
        var p = Path()
        guard c > 0 else { return p }
        p.move(to: CGPoint(x: c, y: s))
        p.addLine(to: CGPoint(x: 0, y: s - c))
        p.addLine(to: CGPoint(x: c, y: s - c))
        p.closeSubpath()
        return p
    }
}

/// the film over a display of this size (its tab at the bottom-leading corner, or top-trailing when flipped)
struct FilmView: View {
    let size: CGFloat
    let flipped: Bool
    let protector: ScreenProtector
    @State private var c: CGFloat = 0           // the fold's travel, points
    @State private var leaving = false

    init(size: CGFloat, flipped: Bool, protector: ScreenProtector) {
        self.size = size
        self.flipped = flipped
        self.protector = protector
        _c = State(initialValue: protector.startFold * size)
    }

    static let red = Color(.sRGB, red: 0.93, green: 0.16, blue: 0.12, opacity: 1)

    var body: some View {
        let radius = max(10, (size * 0.09).rounded())
        let tab = max(14, size * 0.085)
        ZStack(alignment: .topLeading) {
            // the sheet: a faint red tint and a gloss, without the folded corner
            ZStack {
                Self.red.opacity(0.10)
                LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.02), .white.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .mask(FilmLeft(c: c).frame(width: size, height: size))
            .allowsHitTesting(false)
            // the flap: the film's back, lit, with a soft shadow on the screen
            FilmFlap(c: c)
                .fill(LinearGradient(colors: [Color(white: 0.96).opacity(0.85), Self.red.opacity(0.35)],
                                     startPoint: .topTrailing, endPoint: .bottomLeading))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(c > 0 ? 0.35 : 0), radius: 6, x: 2, y: -2)
                .allowsHitTesting(false)
            // the tab: at the corner, or at the flap's tip while folding (a 44 pt hit area)
            RoundedRectangle(cornerRadius: tab * 0.2, style: .continuous)
                .fill(Self.red)
                .frame(width: tab, height: tab * 0.62)
                .rotationEffect(.degrees(45))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .position(x: c - tab * 0.18, y: size - c + tab * 0.18)
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in
                        c = ScreenProtector.fold(dx: v.translation.width, dy: v.translation.height, side: size,
                                                 flipped: flipped) * size
                    }
                    .onEnded { v in
                        let f = ScreenProtector.fold(dx: v.predictedEndTranslation.width,
                                                     dy: v.predictedEndTranslation.height, side: size, flipped: flipped)
                        if ScreenProtector.peels(max(f, c / size)) { peel() }
                        else { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { c = 0 } }
                    })
                .accessibilityElement()
                .accessibilityLabel("Screen protector")
                .accessibilityHint("Drag across the screen to peel it off")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { peel() }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(flipped ? 180 : 0))
        .offset(x: leaving ? (flipped ? -1 : 1) * size * 0.9 : 0, y: leaving ? (flipped ? 1 : -1) * size * 0.9 : 0)
        .opacity(leaving ? 0 : 1)
    }

    private func peel() {
        withAnimation(.easeIn(duration: 0.3)) { c = size; leaving = true } completion: {
            protector.on = false
        }
    }
}

/// the faceplate's display: the film over it while it's on, a double tap shows the display alone
struct ProtectedDisplay: View {
    let feed: PanelFeed
    let theme: Theme
    let size: CGFloat
    let ui: FaceplateUI
    var flipped = false
    private let protector = ScreenProtector.shared

    var body: some View {
        DisplayView(screen: feed.screen, theme: theme, size: size)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { ui.showDisplay(true) }
            .accessibilityAction(named: "Show the display alone") { ui.showDisplay(true) }
            .overlay { if protector.on { FilmView(size: size, flipped: flipped, protector: protector) } }
    }
}

/// the display alone, filling the view: black, square, as large as fits
struct FullDisplay: View {
    let feed: PanelFeed
    let ui: FaceplateUI
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Color.black
                FrameImage(screen: feed.screen)
                    .frame(width: side, height: side)
                    .accessibilityLabel("FM-1 display")
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .offset(y: max(0, drag))
            .onTapGesture(count: 2) { ui.showDisplay(false) }
            .gesture(DragGesture(minimumDistance: 16)
                .onChanged { v in drag = v.translation.height }
                .onEnded { v in
                    if v.translation.height > 80 || abs(v.translation.width) > 120 { ui.showDisplay(false) }
                    withAnimation(.easeOut(duration: 0.2)) { drag = 0 }
                })
            .accessibilityAction(.escape) { ui.showDisplay(false) }
            .accessibilityAction(named: "Close") { ui.showDisplay(false) }
        }
        .ignoresSafeArea()
    }
}
#endif
