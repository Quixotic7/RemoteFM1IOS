// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// PLAN.md section 18 step 1 in the sheet (the app's Firmware page, the AU's): Reset firmware… asked again inline,
// and the Safety copies list (date, reason) with Restore, asked again inline.

#if os(iOS)
import SwiftUI

/// a question on its own lines, then Cancel and the red button (longer than SheetConfirm's one line)
struct SheetAsk: View {
    let question: String
    let action: String
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question).font(RFMFonts.ui(13, 600)).foregroundStyle(Palette.sheetText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                SheetButton("Cancel", action: cancel)
                Button(action: confirm) {
                    Text(action).font(RFMFonts.ui(14, 700)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 44)
                        .background(Capsule().fill(SheetConfirm.red))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// "Reset firmware…": a row; tapped, the question in its place
public struct ResetFirmwareRow: View {
    let name: String
    var divider = true
    let reset: () -> Void
    @Binding var asking: Bool

    public init(name: String, asking: Binding<Bool>, divider: Bool = true, reset: @escaping () -> Void) {
        self.name = name
        _asking = asking
        self.divider = divider
        self.reset = reset
    }

    public var body: some View {
        Group {
            if asking {
                SheetAsk(question: "Start \(name) with a clean memory? A copy of the current one is kept.",
                         action: "Reset", cancel: { withAnimation { asking = false } },
                         confirm: { withAnimation { asking = false }; reset() })
            } else {
                SheetRow("Reset firmware…", divider: false, chevron: false) { withAnimation { asking = true } }
            }
        }
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
    }
}

/// the safety copies of a firmware, newest first: date, reason, Restore (asked again)
public struct SafetyCopiesList: View {
    let copies: [FlashHistory.Snapshot]
    let restore: (FlashHistory.Snapshot) -> Void
    @Binding var asking: String?

    public init(copies: [FlashHistory.Snapshot], asking: Binding<String?>,
                restore: @escaping (FlashHistory.Snapshot) -> Void) {
        self.copies = copies
        _asking = asking
        self.restore = restore
    }

    public var body: some View {
        if copies.isEmpty {
            SheetNote("No safety copies yet: one is kept before an update, a delete, a reset or a restore, and every "
                      + "few minutes while the memory changes.")
        } else {
            SheetList {
                ForEach(Array(copies.enumerated()), id: \.element.id) { i, s in
                    let divider = i < copies.count - 1
                    if asking == s.id {
                        SheetAsk(question: "Restore the copy of \(Self.date(s.date))? A copy of the current memory is kept first.",
                                 action: "Restore", cancel: { withAnimation { asking = nil } },
                                 confirm: { withAnimation { asking = nil }; restore(s) })
                            .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
                    } else {
                        row(s, divider: divider)
                    }
                }
            }
        }
    }

    private func row(_ s: FlashHistory.Snapshot, divider: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.date(s.date)).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText).lineLimit(1)
                Text(s.reason + (s.version.isEmpty ? "" : " · \(s.version)"))
                    .font(RFMFonts.ui(12, 500)).foregroundStyle(Palette.sheetMuted2).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { withAnimation { asking = s.id } } label: {
                Text("Restore").font(RFMFonts.ui(14, 700)).foregroundStyle(Palette.sheetAccent)
                    .padding(.horizontal, 6).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore the copy of \(Self.date(s.date))")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
    }

    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}
#endif
