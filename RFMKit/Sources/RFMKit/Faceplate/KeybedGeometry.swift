// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The keybed's geometry (design/canvas/Keys.dc.html, README section 5.3): 27 keys F3..G5, 16 naturals in the lower
// row, 11 sharps in the upper row each centred on the gap between its two naturals, an LED slot in every key. Two
// layouts: `row` (all keys across the width) and `scroll` (naturals at a fixed width, a range strip of 16 mini cells
// above them). Shared by the drawing and the touch tracking, so a touch lands on the key that is drawn.

import CoreGraphics
import Foundation

public struct KeybedGeometry: Equatable, Sendable {
    public enum Layout: Equatable, Sendable {
        case row
        case scroll(keyWidth: CGFloat)          // a natural's width (the pitch is this plus the gap)
    }

    public struct Key: Equatable, Sendable {
        public var index: Int                   // note key 0 (F3) ... 26 (G5): the panel's key number
        public var natural: Bool
        public var step: Int                    // naturals: 0...15 (the sequencer's step); sharps -1
        public var rect: CGRect                 // in the stage's content coordinates (scroll offset 0)
        public var radius: CGFloat
        public var led: CGSize                  // the LED slot, centred in the key
    }

    /// semitones above F3 of the 16 naturals
    public static let naturals = [0, 2, 4, 6, 7, 9, 11, 12, 14, 16, 18, 19, 21, 23, 24, 26]
    /// the naturals a sharp follows (its gap is between natural i and i + 1)
    public static let sharpAfter = [0, 1, 2, 4, 5, 7, 8, 9, 11, 12, 14]

    public let size: CGSize
    public let layout: Layout
    public let pad, gap: CGFloat
    public let stripHeight, stripGap: CGFloat   // the range strip (scroll only; 0 in a row)
    public let stage: CGRect                    // where the keys are, in the keybed's coordinates
    public let pitch: CGFloat                   // a natural plus a gap
    public let visible: CGFloat                 // naturals in view (scroll)
    public let maxOffset: CGFloat               // the largest scroll offset, in naturals
    public let radius: CGFloat                  // the keybed's own corner
    public let keys: [Key]                      // the 16 naturals then the 11 sharps

    static func clamp(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { max(a, min(b, v)) }

    public init(size: CGSize, layout: Layout, stepMode: Bool = false) {
        self.size = size
        self.layout = layout
        let W = size.width, H = size.height
        pad = Self.clamp((min(W, H) * 0.05).rounded(), 8, 18)
        gap = Self.clamp((W * 0.008).rounded(), 3, 10)
        radius = (min(W, H) * 0.08).rounded()
        var ox: CGFloat = 0, oy: CGFloat = 0
        switch layout {
        case .scroll(let kw):
            stripHeight = Self.clamp((H * 0.11).rounded(), 22, 34)
            stripGap = max(8, gap + 4)
            pitch = kw + gap
            let sy = pad + stripHeight + stripGap
            stage = CGRect(x: pad, y: sy, width: W - 2 * pad, height: H - sy - pad)
            visible = (stage.width + gap) / pitch
            maxOffset = max(0, 16 - visible)
        case .row:
            stripHeight = 0
            stripGap = 0
            pitch = (W - 2 * pad + gap) / 16
            stage = CGRect(origin: .zero, size: size)
            visible = 16
            maxOffset = 0
            ox = pad
            oy = pad
        }
        let kw = pitch - gap
        let rowH = layout == .row ? H - 2 * pad : stage.height
        let vg = gap + 2
        let bh = (rowH * 0.4).rounded()
        let wh = (rowH - bh - vg - 4).rounded()
        let bw = kw * 0.86
        let lw = max(3, (kw * 0.08).rounded())
        var keys: [Key] = []
        for (i, semi) in Self.naturals.enumerated() {
            keys.append(Key(index: semi, natural: true, step: i,
                            rect: CGRect(x: ox + CGFloat(i) * pitch, y: oy + bh + vg, width: kw, height: wh),
                            radius: min(kw * 0.42, 18).rounded(),
                            led: CGSize(width: lw, height: (wh * (stepMode ? 0.34 : 0.42)).rounded())))
        }
        for after in Self.sharpAfter {
            let cx = ox + CGFloat(after + 1) * pitch - gap / 2      // the centre of the gap after natural `after`
            keys.append(Key(index: Self.naturals[after] + 1, natural: false, step: -1,
                            rect: CGRect(x: cx - bw / 2, y: oy, width: bw, height: bh),
                            radius: min(bw * 0.42, 18).rounded(),
                            led: CGSize(width: lw, height: (bh * 0.42).rounded())))
        }
        self.keys = keys
    }

    /// the content's x shift for a scroll offset (in naturals)
    public func shift(_ offset: CGFloat) -> CGFloat { -Self.clamp(offset, 0, maxOffset) * pitch }

    /// the default scroll offset (the canvas: F3 in view for steps, else four naturals in, around C4)
    public var defaultOffset: CGFloat { min(maxOffset, 4) }

    /// the offset that centres natural i
    public func offset(centering i: Int) -> CGFloat { Self.clamp(CGFloat(i) - visible / 2 + 0.5, 0, maxOffset) }

    /// the key under a point in the keybed's coordinates (scroll offset applied), nil: none (a gap, the strip)
    public func key(at p: CGPoint, offset: CGFloat = 0) -> Key? {
        guard stage.contains(p) || layout == .row else { return nil }
        let local: CGPoint
        if case .scroll = layout {
            local = CGPoint(x: p.x - stage.minX - shift(offset), y: p.y - stage.minY)
        } else {
            local = p
        }
        return keys.first { $0.rect.contains(local) }
    }

    /// the key nearest a point within `slop` (gaps between keys count for the key beside them), for a sliding finger
    public func key(near p: CGPoint, offset: CGFloat = 0, slop: CGFloat) -> Key? {
        if let k = key(at: p, offset: offset) { return k }
        let local: CGPoint
        if case .scroll = layout {
            local = CGPoint(x: p.x - stage.minX - shift(offset), y: p.y - stage.minY)
        } else {
            local = p
        }
        return keys.first { $0.rect.insetBy(dx: -slop, dy: 0).contains(local) && local.y >= $0.rect.minY
            && local.y <= $0.rect.maxY }
    }

    /// the range strip's cells (scroll), in the keybed's coordinates
    public func stripCell(_ i: Int) -> CGRect {
        let w = (size.width - 2 * pad - 15 * 2) / 16
        return CGRect(x: pad + CGFloat(i) * (w + 2), y: pad, width: w, height: stripHeight)
    }

    /// the strip's frame around the naturals in view (scroll)
    public func stripWindow(_ offset: CGFloat) -> CGRect {
        let mw = size.width - 2 * pad
        let o = Self.clamp(offset, 0, maxOffset)
        return CGRect(x: pad + o / 16 * mw, y: pad - 3, width: min(visible, 16) / 16 * mw, height: stripHeight + 6)
    }

    /// the natural (strip cell) under an x in the keybed's coordinates
    public func stripIndex(atX x: CGFloat) -> Int {
        let mw = size.width - 2 * pad
        return Int(Self.clamp((x - pad) / mw * 16, 0, 15.999))
    }

    /// "F3", "C sharp 4": a key's name for VoiceOver
    public static func spokenName(_ k: Int) -> String {
        PanelEvent.keyName(k).replacingOccurrences(of: "#", with: " sharp ")
    }
}
