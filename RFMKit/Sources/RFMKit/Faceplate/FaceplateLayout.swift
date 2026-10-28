// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The faceplate's layouts (design/README.md section 4): the canvas's frames, in points at each reference size, and
// the mapping from a reference size to the real one. Positions follow the screen's own width and height; square parts
// (knobs, the display) scale by the smaller of the two, so nothing stretches. When the aspect differs a lot from the
// reference (an iPad in Split View, an AU window), the layout scales uniformly and is centred instead.

import CoreGraphics
import Foundation

public enum FaceplateLayout {
    public enum Kind: String, CaseIterable, Sendable {
        case phonePortrait, phoneLandscape, padLandscape, padPortrait

        public var ref: CGSize {
            switch self {
            case .phonePortrait: CGSize(width: 390, height: 844)
            case .phoneLandscape: CGSize(width: 844, height: 390)
            case .padLandscape: CGSize(width: 1194, height: 834)
            case .padPortrait: CGSize(width: 834, height: 1194)
            }
        }

        /// the layout for a view of this size: portrait under 600 pt wide is the phone's, landscape under 500 pt
        /// high the phone's, else the iPad's
        public static func pick(_ size: CGSize) -> Kind {
            if size.height >= size.width { return size.width < 600 ? .phonePortrait : .padPortrait }
            return size.height < 500 ? .phoneLandscape : .padLandscape
        }

        public var landscape: Bool { self == .phoneLandscape || self == .padLandscape }
    }

    /// reference points -> view points
    public struct Mapper: Sendable {
        public let ref: CGSize, size: CGSize
        public let sx: CGFloat, sy: CGFloat, s: CGFloat, ox: CGFloat, oy: CGFloat

        /// uniform: always scale both axes alike (and centre)
        public init(ref: CGSize, size: CGSize, uniform: Bool = false) {
            self.ref = ref
            self.size = size
            let ax = size.width / ref.width, ay = size.height / ref.height
            let m = min(ax, ay)
            if uniform || max(ax, ay) / max(m, 0.0001) > 1.12 {
                sx = m; sy = m
                ox = (size.width - ref.width * m) / 2
                oy = (size.height - ref.height * m) / 2
            } else {
                sx = ax; sy = ay; ox = 0; oy = 0
            }
            s = min(sx, sy)
        }

        public func x(_ v: CGFloat) -> CGFloat { ox + v * sx }
        public func y(_ v: CGFloat) -> CGFloat { oy + v * sy }
        public func len(_ v: CGFloat) -> CGFloat { v * s }
        public func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: self.x(x), y: self.y(y), width: w * sx, height: h * sy)
        }
    }

    /// the status row: chip left, grabber centre, wordmark right
    public struct Status: Sendable {
        public var y: CGFloat, margin: CGFloat
        public var chipHeight: CGFloat, chipPad: CGFloat, chipFont: CGFloat
        public var grabberWidth: CGFloat, barWidth: CGFloat
        public var wordFont: CGFloat, wordTracking: CGFloat
    }

    /// knobs in a 2 x 2 grid (or a row) of cells `width / columns` wide
    public struct Cluster: Sendable {
        public var x: CGFloat, y: CGFloat, width: CGFloat, knob: CGFloat, rowGap: CGFloat
    }

    /// the OCT- / OCT+ well
    public struct Well: Sendable {
        public var x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
        public var pad: CGFloat, gap: CGFloat, radius: CGFloat, buttonRadius: CGFloat, font: CGFloat
    }

    public struct Buttons: Sendable {
        public var x: CGFloat, y: CGFloat, bw: CGFloat, bh: CGFloat, gap: CGFloat
        public var size: CGSize { CGSize(width: 6 * bw + 5 * gap + 20, height: 2 * bh + gap + 20) }
    }

    public enum KnRow: Sendable {
        case row(x: CGFloat, y: CGFloat, width: CGFloat, knob: CGFloat, led: CGFloat)   // LED then KN1-4
        case grid(Cluster, ledX: CGFloat, ledY: CGFloat, led: CGFloat)                  // 2 x 2, LED below
    }

    /// The Full view (Main, PhoneWide, PadWide, PadTall)
    public struct Full: Sendable {
        public var kind: Kind
        public var status: Status?
        public var grabber: CGRect?                 // without a status row (iPhone landscape)
        public var main: Cluster
        public var oct: Well
        public var display: CGPoint, displaySize: CGFloat
        public var kn: KnRow
        public var buttons: Buttons
        public var keybed: CGRect
        public var keyWidth: CGFloat?               // scroll (iPhone portrait), else a row
        public var pageDots: Bool
    }

    static let phoneStatus = Status(y: 50, margin: 16, chipHeight: 28, chipPad: 11, chipFont: 12, grabberWidth: 88,
                                    barWidth: 40, wordFont: 12, wordTracking: 0.14)
    static let padStatus = Status(y: 26, margin: 48, chipHeight: 30, chipPad: 12, chipFont: 13, grabberWidth: 96,
                                  barWidth: 48, wordFont: 13, wordTracking: 0.16)

    public static func full(_ k: Kind) -> Full {
        switch k {
        case .phonePortrait:
            return Full(kind: k, status: phoneStatus, grabber: nil,
                        main: Cluster(x: 16, y: 96, width: 148, knob: 46, rowGap: 8),
                        oct: Well(x: 16, y: 246, width: 148, height: 52, pad: 5, gap: 6, radius: 14, buttonRadius: 10,
                                  font: 13),
                        display: CGPoint(x: 172, y: 96), displaySize: 202,
                        kn: .row(x: 16, y: 316, width: 358, knob: 46, led: 10),
                        buttons: Buttons(x: 21, y: 400, bw: 48, bh: 42, gap: 8),
                        keybed: CGRect(x: 16, y: 530, width: 358, height: 272), keyWidth: 40, pageDots: true)
        case .phoneLandscape:
            return Full(kind: k, status: nil, grabber: CGRect(x: 378, y: 0, width: 88, height: 20),
                        main: Cluster(x: 54, y: 20, width: 132, knob: 38, rowGap: 2),
                        oct: Well(x: 54, y: 144, width: 132, height: 48, pad: 3, gap: 4, radius: 12, buttonRadius: 9,
                                  font: 12),
                        display: CGPoint(x: 198, y: 20), displaySize: 172,
                        kn: .row(x: 386, y: 20, width: 408, knob: 38, led: 9),
                        buttons: Buttons(x: 386, y: 88, bw: 58, bh: 38, gap: 8),
                        keybed: CGRect(x: 50, y: 206, width: 744, height: 170), keyWidth: nil, pageDots: false)
        case .padLandscape:
            var st = padStatus
            st.margin = 48
            return Full(kind: k, status: st, grabber: nil,
                        main: Cluster(x: 48, y: 88, width: 192, knob: 64, rowGap: 24),
                        oct: Well(x: 48, y: 334, width: 192, height: 54, pad: 5, gap: 6, radius: 15, buttonRadius: 11,
                                  font: 15),
                        display: CGPoint(x: 272, y: 88), displaySize: 300,
                        kn: .row(x: 604, y: 88, width: 542, knob: 64, led: 12),
                        buttons: Buttons(x: 606, y: 234, bw: 78, bh: 60, gap: 10),
                        keybed: CGRect(x: 48, y: 424, width: 1098, height: 362), keyWidth: nil, pageDots: true)
        case .padPortrait:
            var st = padStatus
            st.margin = 40
            return Full(kind: k, status: st, grabber: nil,
                        main: Cluster(x: 40, y: 88, width: 224, knob: 84, rowGap: 8),
                        oct: Well(x: 40, y: 590, width: 220, height: 54, pad: 5, gap: 6, radius: 15, buttonRadius: 11,
                                  font: 15),
                        display: CGPoint(x: 272, y: 88), displaySize: 290,
                        kn: .grid(Cluster(x: 570, y: 88, width: 224, knob: 84, rowGap: 8), ledX: 677, ledY: 344, led: 10),
                        buttons: Buttons(x: 77, y: 404, bw: 100, bh: 64, gap: 12),
                        keybed: CGRect(x: 40, y: 660, width: 754, height: 476), keyWidth: nil, pageDots: true)
        }
    }

    /// The Controls view (PhonePanel, PhoneKeys): a big display, one knob row with its MAIN | KN 1-4 switch, the
    /// BUTTONS | KEYS switch and the deck. Portrait is the canvas's; landscape (not drawn) puts the display left and
    /// the rest in a column on the right.
    public struct Controls: Sendable {
        public var ref: CGSize
        public var status: Status?
        public var grabber: CGRect?
        public var display: CGPoint, displaySize: CGFloat
        public var knobRow: CGRect, knob: CGFloat           // the knobs spread across knobRow (its y is the top)
        public var setSwitch: CGRect
        public var deckSwitch: CGRect
        public var deck: CGRect                             // the area the deck swipes in
        public var buttons: Buttons
        public var oct: Well
        public var keybed: CGRect, keyWidth: CGFloat
    }

    public static func controls(landscape: Bool) -> Controls {
        if !landscape {
            return Controls(ref: Kind.phonePortrait.ref, status: phoneStatus, grabber: nil,
                            display: CGPoint(x: 25, y: 92), displaySize: 340,
                            knobRow: CGRect(x: 12, y: 444, width: 366, height: 71), knob: 50,
                            setSwitch: CGRect(x: 115, y: 523, width: 160, height: 32),
                            deckSwitch: CGRect(x: 95, y: 565, width: 200, height: 36),
                            deck: CGRect(x: 0, y: 605, width: 390, height: 196),
                            buttons: Buttons(x: 15, y: 611, bw: 50, bh: 48, gap: 8),
                            oct: Well(x: 95, y: 747, width: 200, height: 48, pad: 4, gap: 6, radius: 14,
                                      buttonRadius: 10, font: 13),
                            keybed: CGRect(x: 16, y: 611, width: 358, height: 186), keyWidth: 40)
        }
        return Controls(ref: Kind.phoneLandscape.ref, status: nil, grabber: CGRect(x: 378, y: 0, width: 88, height: 20),
                        display: CGPoint(x: 40, y: 32), displaySize: 330,
                        knobRow: CGRect(x: 404, y: 30, width: 410, height: 67), knob: 46,
                        setSwitch: CGRect(x: 529, y: 98, width: 160, height: 30),
                        deckSwitch: CGRect(x: 509, y: 132, width: 200, height: 34),
                        deck: CGRect(x: 396, y: 170, width: 448, height: 210),
                        buttons: Buttons(x: 399, y: 176, bw: 61, bh: 46, gap: 8),
                        oct: Well(x: 509, y: 304, width: 200, height: 46, pad: 4, gap: 6, radius: 14, buttonRadius: 10,
                                  font: 13),
                        keybed: CGRect(x: 404, y: 176, width: 420, height: 186), keyWidth: 40)
    }
}
