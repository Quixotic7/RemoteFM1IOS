// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// (M8) what MIDI learn and MASTER's pickup draw on the faceplate (js/panel.js drawLearn, drawPotAt; css/site.css
// .learn-bar): each learnable control outlined (dashed; solid when it has a binding, with a dot on a knob), the picked
// one pulsing; the bar over the keybed (its line, Forget when the picked control has bindings, Done); the pot's
// position on MASTER while it waits. FaceplateOverlay is the bar and the toast, which the host lays over its sheet.

#if os(iOS)
import SwiftUI

/// a knob's outline while learning (the label's colour, on the faceplate)
struct LearnRing: View {
    let target: String
    let size: CGFloat
    let theme: Theme
    let learn: LearnFeed

    var body: some View {
        if learn.active {
            let sel = learn.selected == target, bound = learn.bound.contains(target)
            let r = size / 2 + 6
            let col = theme.label.color
            ZStack {
                Pulse(on: sel) { p in
                    Circle()
                        .stroke(col.opacity(sel ? 0.55 + 0.45 * p : bound ? 0.95 : 0.6),
                                style: StrokeStyle(lineWidth: sel ? 2.5 + 1.5 * p : bound ? 2 : 1.5,
                                                   dash: sel || bound ? [] : [4, 4]))
                        .shadow(color: sel ? col : .clear, radius: sel ? 3 + 3 * p : 0)
                }
                if bound {
                    Circle().fill(theme.body.color).frame(width: 9, height: 9)
                        .overlay(Circle().fill(col).frame(width: 6, height: 6))
                        .offset(x: r * 0.71, y: -r * 0.71)
                }
            }
            .frame(width: 2 * r, height: 2 * r)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// a button's outline while learning (the LED's colour, in its well)
struct LearnOutline: View {
    let target: String
    let radius: CGFloat
    let theme: Theme
    let learn: LearnFeed

    var body: some View {
        if learn.active {
            let sel = learn.selected == target, bound = learn.bound.contains(target)
            let col = theme.led.color
            Pulse(on: sel) { p in
                RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
                    .stroke(col.opacity(sel ? 0.55 + 0.45 * p : bound ? 0.95 : 0.5),
                            style: StrokeStyle(lineWidth: sel ? 2.5 + 1.5 * p : bound ? 2 : 1.2,
                                               dash: sel || bound ? [] : [3, 4]))
                    .shadow(color: sel ? col : .clear, radius: sel ? 3 + 3 * p : 0)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// the waiting pot's position on MASTER: a small hollow dot outside the knob
struct PotMark: View {
    let size: CGFloat
    let theme: Theme
    let pickup: PickupFeed

    var body: some View {
        if let v = pickup.pot {
            let a = (-135 + Double(v) / 1023 * 270) * .pi / 180
            let r = size / 2 + 5
            Circle().stroke(theme.label.color.opacity(0.75), lineWidth: 1.5)
                .frame(width: 5.2, height: 5.2)
                .offset(x: r * sin(a), y: -r * cos(a))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }
}

/// MIDI learn's bar: the dot, MIDI LEARN, the line, Forget, Done
public struct LearnBar: View {
    let learn: LearnFeed

    public init(learn: LearnFeed) { self.learn = learn }

    public var body: some View {
        HStack(spacing: 12) {
            Pulse(on: true) { p in
                Circle().fill(Palette.sheetAccent).frame(width: 9, height: 9)
                    .opacity(0.35 + 0.65 * p)
                    .shadow(color: Palette.sheetAccent, radius: 5)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("MIDI LEARN").font(RFMFonts.hardware(11)).tracking(11 * 0.14).foregroundStyle(Palette.sheetAccent)
                Text(learn.text).font(RFMFonts.ui(13.5, 500)).foregroundStyle(Palette.sheetText)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if learn.canForget {
                    pill("Forget", accent: false) { learn.forget() }
                        .accessibilityHint("Forgets this control's bindings")
                }
                pill("Done", accent: true) { learn.done() }
                    .accessibilityHint("Ends MIDI learn")
            }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.sheetBackground))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.sheetAccent, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.18)).offset(y: 6))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 14)
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MIDI learn")
    }

    private func pill(_ t: String, accent: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(RFMFonts.ui(13, 700))
                .foregroundStyle(accent ? Palette.sheetBackground : Palette.sheetText)
                .padding(.horizontal, 14).frame(height: 36)
                .background(Capsule().fill(accent ? Palette.sheetAccent : Palette.sheetRaised))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// the faceplate's bottom: the toast, above MIDI learn's bar while it is on. The host lays it over everything (its
/// sheet too); only the bar takes touches. barAtTop: the bar over the top of the faceplate instead (the Controls
/// view's buttons reach the bottom: the bar would cover them)
public struct FaceplateOverlay: View {
    let feed: PanelFeed
    var bottom: CGFloat
    var barAtTop: Bool

    public init(feed: PanelFeed, bottom: CGFloat = 14, barAtTop: Bool = false) {
        self.feed = feed
        self.bottom = bottom
        self.barAtTop = barAtTop
    }

    public var body: some View {
        VStack(spacing: 10) {
            if feed.learn.active && barAtTop {
                LearnBar(learn: feed.learn).padding(.top, 6).transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer(minLength: 0)
            ToastView(center: feed.toast)
            if feed.learn.active && !barAtTop {
                LearnBar(learn: feed.learn).transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.bottom, bottom)
        .animation(.easeInOut(duration: 0.2), value: feed.learn.active)
    }
}
#endif
