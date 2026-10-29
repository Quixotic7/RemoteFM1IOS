// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The LED keybed (design/README.md 5.3, canvas/Keys.dc.html): the keys drawn from KeybedGeometry, each with its LED
// slot mirroring the firmware's LED, in a `row` or a `scroll` layout. Touch is a UIKit view over the keys: true
// multitouch, one note per finger, a finger sliding onto another key plays it (glissando); the keys never scroll on
// touch. In the scroll layout the range strip above scrolls them (tap a cell to centre it, or drag the strip).

#if os(iOS)
import SwiftUI
import UIKit

public struct KeybedView: View {
    let theme: Theme
    let feed: PanelFeed
    let size: CGSize
    let layout: KeybedGeometry.Layout
    let stepNumbers: Bool
    @Binding var offset: CGFloat                    // scroll: naturals scrolled past (nil default: the geometry's)

    public init(theme: Theme, feed: PanelFeed, size: CGSize, layout: KeybedGeometry.Layout, stepNumbers: Bool = false,
                offset: Binding<CGFloat>) {
        self.theme = theme
        self.feed = feed
        self.size = size
        self.layout = layout
        self.stepNumbers = stepNumbers
        _offset = offset
    }

    public var body: some View {
        let g = KeybedGeometry(size: size, layout: layout, stepMode: stepNumbers)
        let off = offset < 0 ? g.defaultOffset : min(offset, g.maxOffset)
        ZStack(alignment: .topLeading) {
            Well(bed: theme.bed.color, radius: g.radius, inset: 3, darkness: 0.2)
            if case .scroll = layout {
                RangeStrip(theme: theme, lights: feed.lights, g: g, offset: off) { o in
                    withAnimation(.easeOut(duration: 0.2)) { offset = o }
                } drag: { o in
                    offset = o
                }
            }
            ZStack(alignment: .topLeading) {
                ForEach(g.keys, id: \.index) { k in
                    KeyCap(key: k, theme: theme, lights: feed.lights, stepNumbers: stepNumbers && k.natural)
                        .frame(width: k.rect.width, height: k.rect.height)
                        .offset(x: k.rect.minX, y: k.rect.minY)
                }
            }
            .offset(x: g.shift(off))
            .frame(width: g.stage.width, height: g.stage.height, alignment: .topLeading)
            .clipped()
            .offset(x: g.stage.minX, y: g.stage.minY)
            KeyTouchArea(geometry: g, offset: off, feed: feed)
                .frame(width: g.stage.width, height: g.stage.height)
                .offset(x: g.stage.minX, y: g.stage.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stepNumbers ? "Keyboard as 16-step sequencer" : "Keyboard, F3 to G5")
    }
}

/// one key: its face (`hi` while held) and its LED slot
struct KeyCap: View {
    let key: KeybedGeometry.Key
    let theme: Theme
    let lights: PanelLights
    let stepNumbers: Bool

    var body: some View {
        let level = lights.keys[key.index]
        let down = lights.keyDown(key.index)
        let lit = LEDLevel.lit(level)
        let a = LEDLevel.alpha(level)
        let nf = min(14, max(8, (key.rect.width * 0.22).rounded()))
        ZStack {
            CapFace(face: down ? theme.hi.color : theme.key.color, hi: theme.hi.color, lo: theme.lo.color,
                    radius: key.radius)
                .offset(y: down ? 1.5 : 0)
            VStack(spacing: (key.rect.height * 0.08).rounded()) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(theme.ledOff.color)
                    if a > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(theme.led.color.opacity(a))
                    }
                }
                .frame(width: key.led.width, height: key.led.height)
                .shadow(color: lit ? theme.led.color : .clear, radius: lit ? 5 : 0)
                .shadow(color: lit ? theme.led.color : .clear, radius: lit ? 1.5 : 0)
                if stepNumbers {
                    Text("\(key.step + 1)").font(RFMFonts.hardware(nf)).foregroundStyle(theme.keyText.color)
                }
            }
            .offset(y: down ? 1.5 : 0)
        }
    }
}

/// the scroll layout's strip: 16 mini cells with each natural's LED, and a frame around the naturals in view
struct RangeStrip: View {
    let theme: Theme
    let lights: PanelLights
    let g: KeybedGeometry
    let offset: CGFloat
    let jump: (CGFloat) -> Void
    let drag: (CGFloat) -> Void

    var body: some View {
        let first = Int(offset.rounded(.down))
        ZStack(alignment: .topLeading) {
            ForEach(0..<16, id: \.self) { i in
                let c = g.stripCell(i)
                let k = KeybedGeometry.naturals[i]
                let level = lights.keys[k]
                let inView = i >= first && CGFloat(i) < offset + g.visible
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4).fill(inView ? theme.hi.color : theme.key.color)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LEDLevel.alpha(level) > 0 ? theme.led.color.opacity(LEDLevel.alpha(level)) : theme.ledOff.color)
                        .frame(width: c.width * 0.55, height: 3)
                        .shadow(color: LEDLevel.lit(level) ? theme.led.color : .clear, radius: 3)
                        .padding(.bottom, 4)
                }
                .frame(width: c.width, height: c.height)
                .offset(x: c.minX, y: c.minY)
                .accessibilityElement()
                .accessibilityLabel("Scroll keyboard to \(KeybedGeometry.spokenName(k))")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { jump(g.offset(centering: i)) }
            }
            let w = g.stripWindow(offset)
            RoundedRectangle(cornerRadius: 7)
                .stroke(theme.keyText.color, lineWidth: 2)
                .frame(width: w.width, height: w.height)
                .offset(x: w.minX, y: w.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // tap a cell: centre it (animated); drag along the strip: the frame follows the finger
        .frame(width: g.size.width, height: g.pad + g.stripHeight + g.stripGap / 2, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if abs(v.translation.width) > 4 {
                    let mw = g.size.width - 2 * g.pad
                    drag(KeybedGeometry.clamp((v.location.x - g.pad) / mw * 16 - g.visible / 2, 0, g.maxOffset))
                }
            }
            .onEnded { v in
                if abs(v.translation.width) <= 4 { jump(g.offset(centering: g.stripIndex(atX: v.location.x))) }
            })
    }
}

/// the keys' touch surface: each finger plays the key under it
struct KeyTouchArea: UIViewRepresentable {
    let geometry: KeybedGeometry
    let offset: CGFloat
    let feed: PanelFeed

    func makeUIView(context: Context) -> KeyTouchView {
        let v = KeyTouchView()
        v.feed = feed
        return v
    }

    func updateUIView(_ v: KeyTouchView, context: Context) {
        v.feed = feed
        if v.geometry != geometry || v.offset != offset {
            v.geometry = geometry
            v.offset = offset
            v.accessibilityElements = nil           // (rebuilt on demand)
        }
    }

    static func dismantleUIView(_ v: KeyTouchView, coordinator: ()) { v.releaseAll() }
}

final class KeyTouchView: UIView {
    var geometry: KeybedGeometry?
    var offset: CGFloat = 0
    weak var feed: PanelFeed?
    private var held: [ObjectIdentifier: Int] = [:]         // touch -> the key it plays

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// a point in this view (the stage) -> the keybed's coordinates
    private func key(for t: UITouch, sliding: Bool) -> Int? {
        guard let g = geometry else { return nil }
        let p = t.location(in: self)
        let q: CGPoint
        if case .scroll = g.layout { q = CGPoint(x: p.x + g.stage.minX, y: p.y + g.stage.minY) } else { q = p }
        return g.key(near: q, offset: offset, slop: sliding ? g.gap : g.gap / 2)?.index
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard feed?.learn.active != true else { return }             // (MIDI learn: the keys play nothing)
        for t in touches {
            guard let k = key(for: t, sliding: false) else { continue }
            held[ObjectIdentifier(t)] = k
            feed?.keyDown(k)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let k = key(for: t, sliding: true) else { continue }    // (off the keys: the last one stays down)
            if let old = held[id] {
                if old == k { continue }
                held[id] = k
                feed?.keyDown(k)                                          // (the new one first: a legato glissando)
                feed?.keyUp(old)
            } else if feed?.learn.active != true {
                held[id] = k
                feed?.keyDown(k)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }

    private func end(_ touches: Set<UITouch>) {
        for t in touches {
            if let k = held.removeValue(forKey: ObjectIdentifier(t)) { feed?.keyUp(k) }
        }
    }

    func releaseAll() {
        for k in held.values { feed?.keyUp(k) }
        held.removeAll()
    }

    // VoiceOver: one element per key in view ("F3", "C sharp 4"); activating it plays the key briefly
    override var accessibilityElements: [Any]? {
        get {
            if let cached = super.accessibilityElements { return cached }
            guard let g = geometry else { return nil }
            var list: [Any] = []
            for k in g.keys.sorted(by: { $0.index < $1.index }) {
                var r = k.rect
                if case .scroll = g.layout { r.origin.x += g.shift(offset) }
                guard r.maxX > 0, r.minX < bounds.width else { continue }
                let e = KeyElement(accessibilityContainer: self)
                e.key = k.index
                e.view = self
                e.accessibilityLabel = KeybedGeometry.spokenName(k.index)
                e.accessibilityTraits = [.button, .playsSound]
                e.accessibilityFrameInContainerSpace = r
                list.append(e)
            }
            super.accessibilityElements = list
            return list
        }
        set { super.accessibilityElements = newValue }
    }

    final class KeyElement: UIAccessibilityElement {
        var key = 0
        weak var view: KeyTouchView?

        override func accessibilityActivate() -> Bool {
            guard let f = view?.feed, !f.learn.active else { return false }
            let k = key
            f.keyDown(k)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { f.keyUp(k) } }
            return true
        }
    }
}
#endif
