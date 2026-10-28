// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The faceplate's parts (design/README.md section 5, canvas/Screen, Knob, Buttons, Keys): the display, a knob, the
// 6 x 2 button grid, the OCT well, the indicator LED. Each draws from the theme and reads only the part of the
// PanelFeed it shows, so an LED or a knob changing redraws that part alone. Touches go to the feed (the core).

#if os(iOS)
import SwiftUI
import UIKit

// MARK: - shared drawing

extension View {
    /// a frame at a rect of the parent's coordinate space (the faceplate's absolute layout)
    func place(_ r: CGRect) -> some View {
        frame(width: max(0, r.width), height: max(0, r.height)).position(x: r.midX, y: r.midY)
    }

    /// the design's hard drop shadow ("0 4px 0 lo"): the same shape, offset, behind
    func hardShadow<S: Shape>(_ shape: S, _ color: Color, _ dy: CGFloat) -> some View {
        background(shape.fill(color).offset(y: dy))
    }
}

/// a key or button face: `key` with a 2 pt `hi` top edge (the design's inset highlight), `lo` 4 pt under it
struct CapFace: View {
    var face: Color, hi: Color, lo: Color, radius: CGFloat
    var drop: CGFloat = 4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(hi)
            shape.fill(face).offset(y: 2)
        }
        .clipShape(shape)
        .hardShadow(shape, lo, drop)
    }
}

/// a recessed well (keybed, button well, OCT well): `bed` with a dark inset top edge
struct Well: View {
    var bed: Color, radius: CGFloat
    var inset: CGFloat = 2, darkness: Double = 0.18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(bed)
            shape.fill(Color.black.opacity(darkness))
            shape.fill(bed).offset(y: inset)
        }
        .clipShape(shape)
    }
}

// MARK: - 5.1 Display

/// the bezel and the core's 240 x 240 framebuffer, nearest-neighbour, snapped to whole device pixels when that keeps
/// at least 92 % of the room
public struct DisplayView: View {
    let screen: ScreenFeed
    let theme: Theme
    let size: CGFloat
    @Environment(\.displayScale) private var scale

    public init(screen: ScreenFeed, theme: Theme, size: CGFloat) {
        self.screen = screen
        self.theme = theme
        self.size = size
    }

    public var body: some View {
        let pad = max(6, (size * 0.045).rounded()), br = max(10, (size * 0.09).rounded())
        let lr = max(4, (size * 0.035).rounded())
        let inner = size - 2 * pad
        let k = (inner * scale / 240).rounded(.down)
        let snapped = k >= 1 && k * 240 / scale >= inner * 0.92 ? k * 240 / scale : inner
        let bezel = RoundedRectangle(cornerRadius: br, style: .continuous)
        ZStack {
            bezel.fill(theme.bezel.color).hardShadow(bezel, .black.opacity(0.25), 4)
            FrameImage(screen: screen)
                .frame(width: snapped, height: snapped)
                .clipShape(RoundedRectangle(cornerRadius: lr * snapped / inner, style: .continuous))
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("FM-1 display")
        .accessibilityAddTraits(.isImage)
    }
}

/// (only this redraws when a frame comes)
struct FrameImage: View {
    let screen: ScreenFeed

    var body: some View {
        if let img = screen.image {
            Image(decorative: img, scale: 1).interpolation(.none).resizable()
        } else {
            Color.black
        }
    }
}

// MARK: - 5.2 Knob

public struct KnobView: View {
    let knob: PanelFeed.Knob
    let size: CGFloat
    let theme: Theme
    let feed: PanelFeed
    var onSwipe: ((Int) -> Void)?                   // a sideways swipe on the knob: +1 next set, -1 previous
    var labelWidth: CGFloat?                        // the room for the label (small sizes: it shrinks to fit)
    @State private var track = KnobDrag.Track()     // (kept across redraws during a drag)

    public static let degreesPerDetent: Double = 18   // (20 detents a turn)
    static let pointsPerDetent: CGFloat = 9
    static let masterSweepPoints: CGFloat = 220

    public init(knob: PanelFeed.Knob, size: CGFloat, theme: Theme, feed: PanelFeed, labelWidth: CGFloat? = nil,
                onSwipe: ((Int) -> Void)? = nil) {
        self.knob = knob
        self.size = size
        self.theme = theme
        self.feed = feed
        self.labelWidth = labelWidth
        self.onSwipe = onSwipe
    }

    /// the knob's cell: label above, the knob, room for its shadow (Knob.dc.html: size + 28 wide)
    public static func cell(_ size: CGFloat) -> CGSize {
        let lf = max(9, (size * 0.17).rounded())
        return CGSize(width: size + 28, height: lf + 6 + size + 6)
    }

    public var body: some View {
        let lf = max(9, (size * 0.17).rounded())
        VStack(spacing: 6) {
            Text(knob.label.uppercased())
                .font(RFMFonts.hardware(lf))
                .tracking(lf * 0.08)
                .foregroundStyle(theme.label.color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)       // (shrinks for width only)
                .frame(width: max(size, min(size + 28, labelWidth ?? size + 28) - 2))
                .frame(height: lf)
            KnobBody(knob: knob, size: size, theme: theme, knobs: feed.knobs)
                .frame(width: size, height: size)
        }
        .frame(width: size + 28, height: lf + 6 + size + 6, alignment: .top)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .gesture(KnobDrag(knob: knob, feed: feed, onSwipe: onSwipe, t: track).gesture)
        .accessibilityElement()
        .accessibilityLabel("\(knob.label) knob")
        .accessibilityValue(KnobBody.spokenValue(knob, feed.knobs))
        .accessibilityAdjustableAction { dir in
            let d = dir == .increment ? 1 : -1
            if knob == .master { feed.master(Int(feed.knobs.master) + 32 * d) } else { feed.turn(knob, d) }
        }
    }
}

struct KnobBody: View {
    let knob: PanelFeed.Knob
    let size: CGFloat
    let theme: Theme
    let knobs: KnobFeed

    static func angle(_ knob: PanelFeed.Knob, _ k: KnobFeed) -> Double {
        if knob == .master { return -135 + Double(k.master) / 1023 * 270 }
        return Double(k.turns[knob.rawValue]) * KnobView.degreesPerDetent
    }

    static func spokenValue(_ knob: PanelFeed.Knob, _ k: KnobFeed) -> String {
        knob == .master ? "\(Int((Double(k.master) / 1023 * 100).rounded())) percent" : "turned \(k.turns[knob.rawValue])"
    }

    var body: some View {
        let u = size / 100
        ZStack {
            Circle().fill(theme.knob.color)
            Circle().inset(by: 5 * u)
                .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 8 * u, dash: [3.2 * u, 3.9 * u]))
            Circle().inset(by: 14 * u).fill(theme.knob.color)
            Circle().inset(by: 14 * u).fill(Color.white.opacity(0.07))
            Pointer(knob: knob, size: size, theme: theme, knobs: knobs)
        }
        .background(Circle().fill(Color.black.opacity(0.28)).offset(y: max(3, (size * 0.06).rounded())))
    }
}

/// (only the pointer redraws when the knob turns)
struct Pointer: View {
    let knob: PanelFeed.Knob
    let size: CGFloat
    let theme: Theme
    let knobs: KnobFeed

    var body: some View {
        let u = size / 100
        Capsule()
            .fill(theme.mark.color)
            .frame(width: 7 * u, height: 27 * u)          // 10..30 of 100, round caps (7 wide)
            .offset(y: -30 * u)
            .rotationEffect(.degrees(KnobBody.angle(knob, knobs)))
    }
}

/// vertical drag turns the knob (up = clockwise); a sideways swipe goes to onSwipe when there is one
@MainActor
struct KnobDrag {
    let knob: PanelFeed.Knob
    let feed: PanelFeed
    let onSwipe: ((Int) -> Void)?
    let t: Track

    @MainActor final class Track {
        var began = false
        var axis = 0                            // 0 undecided, 1 vertical (turning), 2 sideways (swipe)
        var sent = 0
        var start: Int32 = 0
        let haptic = UISelectionFeedbackGenerator()
    }

    var gesture: some Gesture {
        let t = self.t
        return DragGesture(minimumDistance: 0)
            .onChanged { v in
                let dx = v.translation.width, dy = v.translation.height
                if t.axis == 0 {
                    if !t.began { t.began = true; t.start = feed.knobs.master; t.haptic.prepare() }
                    guard max(abs(dx), abs(dy)) > 6 else { return }
                    t.axis = onSwipe != nil && abs(dx) > abs(dy) * 1.2 ? 2 : 1
                }
                guard t.axis == 1 else { return }
                if knob == .master {
                    let v = Int(t.start) + Int(-dy / KnobView.masterSweepPoints * 1023)
                    feed.master(v)
                } else {
                    let target = Int((-dy / KnobView.pointsPerDetent).rounded(.towardZero))
                    if target != t.sent {
                        feed.turn(knob, target - t.sent)
                        t.sent = target
                        t.haptic.selectionChanged()
                    }
                }
            }
            .onEnded { v in
                if t.axis == 2, abs(v.translation.width) > 40 { onSwipe?(v.translation.width < 0 ? 1 : -1) }
                t.axis = 0
                t.sent = 0
                t.began = false
            }
    }
}

// MARK: - 5.4 Buttons

/// one button of the grid or the OCT well; lit by the firmware's LED for it, pressed while touched
struct PanelButton: View {
    let label: PanelFeed.Label
    let theme: Theme
    let lights: PanelLights
    let feed: PanelFeed
    let height: CGFloat
    var radius: CGFloat
    var font: CGFloat
    var drop: CGFloat = 4

    var body: some View {
        let level = lights.buttons[label.rawValue]
        let lit = LEDLevel.lit(level)
        let down = lights.labelDown(label.rawValue)
        let tint = lit ? 1 : LEDLevel.alpha(level) * 0.5
        let legend = tint > 0 ? mix(theme.keyText, theme.led, tint) : theme.keyText.color
        let ic = max(7, (height * 0.17).rounded())
        ZStack {
            CapFace(face: (lit || down) ? theme.hi.color : theme.key.color, hi: theme.hi.color, lo: theme.lo.color,
                    radius: radius, drop: drop)
                .offset(y: down ? 1 : 0)
            VStack(spacing: 3) {
                if label == .play {
                    PlayGlyph(level: lights.playGreen).frame(width: ic, height: ic)
                } else if label == .rec {
                    Circle().fill(Palette.recGlyph).frame(width: ic * 0.8, height: ic * 0.8).frame(width: ic, height: ic)
                }
                Text(label.legend)
                    .font(RFMFonts.hardware(font))
                    .tracking(font * 0.06)
                    .foregroundStyle(legend)
                    .shadow(color: lit ? theme.led.color : .clear, radius: lit ? 4 : 0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .offset(y: down ? 1 : 0)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if lights.touchedLabels & (1 << UInt32(label.rawValue)) == 0 { feed.button(label, down: true) } }
            .onEnded { _ in feed.button(label, down: false) })
        .accessibilityElement()
        .accessibilityLabel(label.spoken)
        .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { tap() }
    }

    private func tap() {
        feed.button(label, down: true)
        let f = feed, l = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { MainActor.assumeIsolated { f.button(l, down: false) } }
    }

    private func mix(_ a: RGB, _ b: RGB, _ t: Double) -> Color {
        RGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t).color
    }
}

/// PLAY's green triangle; it glows while PLAY's green LED is lit
struct PlayGlyph: View {
    let level: UInt8

    var body: some View {
        Canvas { ctx, s in
            var p = Path()
            p.move(to: CGPoint(x: s.width * 0.2, y: s.height * 0.1))
            p.addLine(to: CGPoint(x: s.width * 0.9, y: s.height * 0.5))
            p.addLine(to: CGPoint(x: s.width * 0.2, y: s.height * 0.9))
            p.closeSubpath()
            ctx.fill(p, with: .color(Palette.playGlyph))
        }
        .shadow(color: LEDLevel.lit(level) ? Palette.playGlyph : .clear, radius: LEDLevel.lit(level) ? 4 : 0)
    }
}

/// the 6 x 2 grid in its well (Buttons.dc.html)
public struct ButtonGrid: View {
    let theme: Theme
    let feed: PanelFeed
    let bw: CGFloat, bh: CGFloat, gap: CGFloat

    public init(theme: Theme, feed: PanelFeed, bw: CGFloat, bh: CGFloat, gap: CGFloat) {
        self.theme = theme
        self.feed = feed
        self.bw = bw
        self.bh = bh
        self.gap = gap
    }

    public var body: some View {
        let rows = [Array(PanelFeed.Label.grid[0..<6]), Array(PanelFeed.Label.grid[6..<12])]
        VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(rows[r], id: \.self) { l in
                        PanelButton(label: l, theme: theme, lights: feed.lights, feed: feed, height: bh,
                                    radius: (bh * 0.24).rounded(), font: max(10, (bh * 0.26).rounded()))
                            .frame(width: bw, height: bh)
                    }
                }
            }
        }
        .padding(10)
        .background(Well(bed: theme.bed.color, radius: (bh * 0.34).rounded() + 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Function buttons")
    }
}

// MARK: - 5.5 OCT- / OCT+

public struct OctWell: View {
    let theme: Theme
    let feed: PanelFeed
    let pad: CGFloat, gap: CGFloat, radius: CGFloat, buttonRadius: CGFloat, font: CGFloat
    let height: CGFloat

    public init(theme: Theme, feed: PanelFeed, pad: CGFloat, gap: CGFloat, radius: CGFloat, buttonRadius: CGFloat,
                font: CGFloat, height: CGFloat) {
        self.theme = theme
        self.feed = feed
        self.pad = pad
        self.gap = gap
        self.radius = radius
        self.buttonRadius = buttonRadius
        self.font = font
        self.height = height
    }

    public var body: some View {
        HStack(spacing: gap) {
            ForEach([PanelFeed.Label.octDown, .octUp], id: \.self) { l in
                PanelButton(label: l, theme: theme, lights: feed.lights, feed: feed, height: height - 2 * pad,
                            radius: buttonRadius, font: font, drop: 3)
            }
        }
        .padding(pad)
        .padding(.bottom, 0)
        .background(Well(bed: theme.bed.color, radius: radius))
        // (the iPhone landscape well is ~42 pt high: a larger invisible hit area, section 8)
        .padding(.vertical, max(0, (44 - height) / 2))
        .contentShape(Rectangle())
        .padding(.vertical, -max(0, (44 - height) / 2))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 5.6 Indicator LED

/// the red LED left of KN1. No firmware LED drives it (RemoteFM1's keymap gives every matrix LED to a key or a
/// button; the FM-1's red LED is outside the panel's LED matrix), so it shows that a core is running: lit while one
/// is booted, dark otherwise.
public struct IndicatorLED: View {
    let lights: PanelLights
    let size: CGFloat

    public init(lights: PanelLights, size: CGFloat) {
        self.lights = lights
        self.size = size
    }

    public var body: some View {
        let on = lights.booted
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Palette.indicatorLed.opacity(on ? 1 : 0.3))
            .shadow(color: on ? Palette.indicatorLed : .clear, radius: on ? size * 0.4 : 0)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
#endif
