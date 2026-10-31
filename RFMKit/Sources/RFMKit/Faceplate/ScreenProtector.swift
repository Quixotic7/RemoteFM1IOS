// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The display up close and its film:
//   ScreenProtector  the clear protective film the FM-1 ships with: a faint sheen over the display, with its solid
//                    red tab (about a knob cap's size) sticking out beside the screen's corner nearest KN1 (landscape:
//                    right of the screen, level with its top; phone portrait: below its bottom-leading corner).
//                    Dragging the tab across the screen folds the film back (the fold line halfway between the tab's
//                    place and the finger); let go early and it springs back, past a third of the way it peels off and
//                    is gone, the red square with it. Remembered (UserDefaults: the app's; in the AU the extension's, so
//                    one setting for every instance). Settings › View puts it back. Only the tab takes touches.
//   FilmGeometry     the film's outline (the display's rounded square and the strip to the tab) and its fold
//   ScreenFilm       the film drawn on the Full view, over the faceplate
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

    /// let go at this fold: peeled off (true) or back on
    public nonisolated static func peels(_ fold: CGFloat) -> Bool { fold > 0.33 }
}

/// the film's outline in the faceplate's coordinates: the display's rounded square and a strip out to the tab, and
/// the film folded back from the tab by a travel t (points along the peel's direction)
public struct FilmGeometry: Equatable, Sendable {
    public let display: CGRect
    public let radius: CGFloat
    public let tab: CGRect
    /// the peel's direction: from the tab toward the display's centre
    public let direction: CGVector
    /// the tab's travel that folds the whole film over (twice the film's reach from the tab along the direction)
    public let length: CGFloat
    /// the film's pieces (each a convex polygon, counter-clockwise in a y-down space... any one orientation)
    public let pieces: [[CGPoint]]
    /// the film's back edge along the peel (from the tab's centre, <= 0): the fold line starts there, so nothing folds at rest
    let back: CGFloat

    /// the tab's square beside a display: right of it, level with its top, or (below) under its leading corner;
    /// overlapping the bezel a little
    public static func tab(display d: CGRect, below: Bool) -> CGRect {
        let t = (d.width * 0.13).rounded(), o = (t * 0.15).rounded()
        return below ? CGRect(x: d.minX + o, y: d.maxY - o, width: t, height: t)
                     : CGRect(x: d.maxX - o, y: d.minY + o, width: t, height: t)
    }

    public init(display: CGRect, radius: CGFloat, tab: CGRect) {
        self.display = display
        self.radius = radius
        self.tab = tab
        let c = CGPoint(x: tab.midX, y: tab.midY)
        var dx = display.midX - c.x, dy = display.midY - c.y
        let n = max(hypot(dx, dy), 1e-9)
        dx /= n; dy /= n
        direction = CGVector(dx: dx, dy: dy)
        // the display's rounded square
        var sq: [CGPoint] = []
        let r = min(radius, display.width / 2, display.height / 2)
        let corners = [(display.maxX - r, display.maxY - r, 0.0), (display.minX + r, display.maxY - r, 90.0),
                       (display.minX + r, display.minY + r, 180.0), (display.maxX - r, display.minY + r, 270.0)]
        for (x, y, a0) in corners {
            for i in 0...6 {
                let a = (a0 + Double(i) * 15) * .pi / 180
                sq.append(CGPoint(x: x + r * CGFloat(cos(a)), y: y + r * CGFloat(sin(a))))
            }
        }
        // the strip: the tab and a stretch of the display's edge nearest it, as wide as the tab, in its hull
        let hw = max(tab.width, tab.height) * 0.7
        let q = CGPoint(x: min(max(c.x, display.minX), display.maxX), y: min(max(c.y, display.minY), display.maxY))
        let qi = CGPoint(x: q.x + dx * hw * 2, y: q.y + dy * hw * 2)
        let ex = -dy * hw, ey = dx * hw
        let tw = hw * 0.7
        let strip = Self.hull([CGPoint(x: qi.x + ex, y: qi.y + ey), CGPoint(x: qi.x - ex, y: qi.y - ey),
                               CGPoint(x: c.x - dx * tw + ex * 0.7, y: c.y - dy * tw + ey * 0.7),
                               CGPoint(x: c.x - dx * tw - ex * 0.7, y: c.y - dy * tw - ey * 0.7)])
        pieces = [Self.oriented(sq), Self.oriented(strip)]
        let proj = pieces.flatMap { $0 }.map { ($0.x - c.x) * dx + ($0.y - c.y) * dy }
        let reach = proj.max() ?? 0
        back = min(0, proj.min() ?? 0)
        length = 2 * max(reach - back, 1)
    }

    /// the fold (0...1) from the finger's movement: its travel along the peel's direction over the film's length
    public func fold(dx: CGFloat, dy: CGFloat) -> CGFloat {
        min(1, max(0, (dx * direction.dx + dy * direction.dy) / length))
    }

    /// the film folded by travel t (points): what's left on, the folded-back flap (mirrored across the fold line,
    /// halfway between the tab's place and the finger) and the tab's centre (carried with the finger)
    public func folded(_ t: CGFloat) -> (left: [[CGPoint]], flap: [[CGPoint]], tab: CGPoint) {
        let c = CGPoint(x: tab.midX, y: tab.midY), u = direction
        let h = max(0, t) / 2
        let along = { (p: CGPoint) in (p.x - c.x) * u.dx + (p.y - c.y) * u.dy - back - h }
        let left = pieces.map { Self.clip($0, keep: { along($0) }) }.filter { $0.count > 2 }
        let flap = h <= 0 ? [] : pieces.map { Self.clip($0, keep: { -along($0) }) }.filter { $0.count > 2 && abs(Self.area($0)) > 0.5 }
            .map { $0.map { p in let d = along(p); return CGPoint(x: p.x - 2 * d * u.dx, y: p.y - 2 * d * u.dy) } }
        return (left, flap, CGPoint(x: c.x + u.dx * 2 * h, y: c.y + u.dy * 2 * h))
    }

    /// a polygon's part where f >= 0 (f linear: one half-plane)
    static func clip(_ poly: [CGPoint], keep f: (CGPoint) -> CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let fa = f(a), fb = f(b)
            if fa >= 0 { out.append(a) }
            if (fa >= 0) != (fb >= 0) {
                let k = fa / (fa - fb)
                out.append(CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k))
            }
        }
        return out
    }

    static func area(_ p: [CGPoint]) -> CGFloat {
        p.indices.reduce(0) { $0 + p[$1].x * p[($1 + 1) % p.count].y - p[($1 + 1) % p.count].x * p[$1].y } / 2
    }

    /// one orientation for every piece, so a nonzero fill unions them
    static func oriented(_ p: [CGPoint]) -> [CGPoint] { area(p) < 0 ? p.reversed() : p }

    static func hull(_ pts: [CGPoint]) -> [CGPoint] {
        let p = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lo: [CGPoint] = [], up: [CGPoint] = []
        for q in p { while lo.count >= 2 && cross(lo[lo.count - 2], lo[lo.count - 1], q) <= 0 { lo.removeLast() }; lo.append(q) }
        for q in p.reversed() { while up.count >= 2 && cross(up[up.count - 2], up[up.count - 1], q) <= 0 { up.removeLast() }; up.append(q) }
        return Array(lo.dropLast() + up.dropLast())
    }
}

#if os(iOS)
/// polygons as one path (the same orientation each, so a nonzero fill is their union); t animatable
struct FilmShape: Shape {
    let geo: FilmGeometry
    var t: CGFloat
    let flap: Bool
    var animatableData: CGFloat { get { t } set { t = newValue } }

    func path(in _: CGRect) -> Path {
        let f = geo.folded(t)
        var p = Path()
        for poly in flap ? f.flap : f.left { p.addLines(poly); p.closeSubpath() }
        return p
    }
}

/// the film over the Full view (in the faceplate's coordinates): the display and the strip to the tab, the tab the
/// solid red square beside the screen. Drawn only while the film is on.
struct ScreenFilm: View {
    let geo: FilmGeometry
    private let protector = ScreenProtector.shared

    var body: some View {
        if protector.on { FilmLayer(geo: geo, protector: protector) }
    }
}

struct FilmLayer: View {
    let geo: FilmGeometry
    let protector: ScreenProtector
    @State private var t: CGFloat
    @State private var leaving = false

    init(geo: FilmGeometry, protector: ScreenProtector) {
        self.geo = geo
        self.protector = protector
        _t = State(initialValue: protector.startFold * geo.length)
    }

    var body: some View {
        let size = geo.tab.width
        let u = geo.direction
        ZStack(alignment: .topLeading) {
            // the sheet: clear, a faint gloss, without the folded part
            FilmShape(geo: geo, t: t, flap: false)
                .fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.01), .white.opacity(0.07)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(FilmShape(geo: geo, t: t, flap: false)
                    .fill(LinearGradient(colors: [.clear, .white.opacity(0.10), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(FilmShape(geo: geo, t: t, flap: false).stroke(.white.opacity(0.16), lineWidth: 1))
                .allowsHitTesting(false)
            // the flap: the film's back, lit, with a soft shadow on the screen
            FilmShape(geo: geo, t: t, flap: true)
                .fill(Color(white: 0.96).opacity(0.28))
                .shadow(color: .black.opacity(t > 0 ? 0.35 : 0), radius: 6, x: u.dx * 3, y: u.dy * 3)
                .allowsHitTesting(false)
            // the tab: the solid red square, carried with the finger (a 44 pt hit area)
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Palette.indicatorLed)
                .frame(width: size, height: size)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .position(x: geo.tab.midX, y: geo.tab.midY)
                .offset(x: geo.folded(t).tab.x - geo.tab.midX, y: geo.folded(t).tab.y - geo.tab.midY)
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in t = geo.fold(dx: v.translation.width, dy: v.translation.height) * geo.length }
                    .onEnded { v in
                        let f = geo.fold(dx: v.predictedEndTranslation.width, dy: v.predictedEndTranslation.height)
                        if ScreenProtector.peels(max(f, t / geo.length)) { peel() }
                        else { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { t = 0 } }
                    })
                .accessibilityElement()
                .accessibilityLabel("Screen protector")
                .accessibilityHint("Drag across the screen to peel it off")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { peel() }
        }
        .allowsHitTesting(!leaving)
        .offset(x: leaving ? u.dx * geo.length * 0.3 : 0, y: leaving ? u.dy * geo.length * 0.3 - geo.length * 0.2 : 0)
        .opacity(leaving ? 0 : 1)
    }

    private func peel() {
        withAnimation(.easeIn(duration: 0.3)) { t = geo.length; leaving = true } completion: {
            protector.on = false
        }
    }
}

/// the faceplate's display: a double tap shows the display alone
struct ProtectedDisplay: View {
    let feed: PanelFeed
    let theme: Theme
    let size: CGFloat
    let ui: FaceplateUI

    var body: some View {
        DisplayView(screen: feed.screen, theme: theme, size: size)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { ui.showDisplay(true) }
            .accessibilityAction(named: "Show the display alone") { ui.showDisplay(true) }
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
