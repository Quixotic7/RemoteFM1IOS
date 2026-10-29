// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// (M8) the faceplate's toast: one short line at the bottom for a few seconds (js/main.js toast): MIDI learn's results,
// MASTER's pickup, the OMX-27. Tinted ok (green), bad (red) or neutral; a newer one replaces it. Shared by the app and
// the AUv3 (PanelFeed.toast; the host draws it with FaceplateOverlay, over its sheet).

import Foundation
import Observation
#if os(iOS)
import SwiftUI
import UIKit
#endif

@MainActor @Observable public final class ToastCenter {
    public enum Tone: Sendable { case neutral, ok, bad }
    public struct Toast: Equatable, Sendable {
        public let id: Int
        public let text: String
        public let tone: Tone
    }

    public private(set) var current: Toast?
    @ObservationIgnored private var next = 0

    public init() {}

    /// shown for `seconds` (default: 4, bad 7, as the website)
    public func show(_ text: String, _ tone: Tone = .neutral, seconds: Double? = nil) {
        next += 1
        let t = Toast(id: next, text: text, tone: tone)
        current = t
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
        let s = seconds ?? (tone == .bad ? 7 : 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            MainActor.assumeIsolated { self?.hide(t.id) }
        }
    }

    /// hides it (id: only if it is still that one)
    public func hide(_ id: Int? = nil) {
        guard let c = current, id == nil || c.id == id else { return }
        current = nil
    }
}

#if os(iOS)
/// the toast, in the sheet's dark style with a tinted edge (site.css .toast)
public struct ToastView: View {
    let center: ToastCenter

    public init(center: ToastCenter) { self.center = center }

    public var body: some View {
        ZStack {
            if let t = center.current {
                Text(t.text)
                    .font(RFMFonts.ui(13, 500)).foregroundStyle(Palette.sheetText)
                    .lineLimit(2).minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.sheetBackground.opacity(0.97)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Self.edge(t.tone), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    .id(t.id)
                    .transition(.opacity.combined(with: .offset(y: 12)))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeOut(duration: 0.2), value: center.current?.id)
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
    }

    static func edge(_ t: ToastCenter.Tone) -> Color {
        switch t {
        case .ok: Palette.linkedDot.opacity(0.55)
        case .bad: Color(.sRGB, red: 1, green: 100 / 255, blue: 100 / 255, opacity: 0.6)
        case .neutral: Palette.sheetBorder
        }
    }
}
#endif
