// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The extension's view: the same on-screen FM-1 as the app (RFMKit's FaceplateView) playing this instance's core.
// The host decides the size, so the view picks from it (design/README.md section 4's suggestion): wide and short ->
// the landscape layout, tall -> the Controls view, very small -> the Screen view (until the user picks a view). The
// grabber sits inside the view's top edge; its sheet holds the AU's own items: the FM-1 (Use this FM-1, Bluetooth),
// the view, the theme (shared with the app through the App Group), the firmware (About, Restart), the MIDI octave,
// and Diagnostics (the instance's numbers and M2's probes).

import RFMKit
import SwiftUI

struct AUView: View {
    @Bindable var model: AUViewModel
    private let store = ThemeStore.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FaceplateView(feed: model.feed, ui: model.ui, theme: store.current, chip: model.chip)
                    .equatable()
                PullDownSheet(open: Binding(get: { model.ui.sheetOpen }, set: { model.ui.sheetOpen = $0 })) {
                    AUSheet(model: model)
                }
            }
            .onAppear { model.fit(geo.size) }
            .onChange(of: geo.size) { _, s in model.fit(s) }
        }
        .ignoresSafeArea()
        .onAppear { store.observe() }
    }
}

/// the sheet's items (its own view: the instance's numbers it reads redraw only it)
struct AUSheet: View {
    @Bindable var model: AUViewModel
    private let store = ThemeStore.shared

    var body: some View { sheet.onChange(of: model.ui.sheetOpen) { _, open in if !open { model.page = nil } } }

    private var chip: PanelChip { model.chip }

    private func close() { withAnimation(.easeInOut(duration: 0.28)) { model.ui.sheetOpen = false } }

    @ViewBuilder private var sheet: some View {
        switch model.page {
        case .firmware: firmwarePage
        case .diagnostics: diagnosticsPage
        case nil: mainSheet
        }
    }

    private var mainSheet: some View {
        VStack(spacing: 0) {
            SheetHeader("Controls", done: close)
            ScrollView {
                VStack(spacing: 0) {
                    SheetSectionTitle("FM-1", top: 18)
                    fm1Card
                    SheetSectionTitle("View · or swipe sideways")
                    ViewTiles(ui: model.ui) { model.userPicked = true }
                    SheetSectionTitle("Theme")
                    ThemeSwatches(store: store, edit: nil)
                    SheetList {
                        SheetRow("Firmware", value: model.status.coreName.isEmpty ? "–" : model.status.coreName) {
                            model.page = .firmware
                        }
                        Stepper(value: Binding(get: { model.status.settings.transpose }, set: { model.setTranspose($0) }),
                                in: -2...2) {
                            Text("MIDI octave \(model.status.settings.transpose > 0 ? "+" : "")\(model.status.settings.transpose)")
                                .font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText)
                        }
                        .padding(.horizontal, 16).frame(height: 52)
                        .overlay(alignment: .bottom) { Palette.sheetLine.frame(height: 1) }
                        SheetRow("Diagnostics", divider: false) {
                            model.page = .diagnostics
                            model.diagnosticsOpen = true
                        }
                    }
                    .padding(.top, 20)
                    if !model.status.coreError.isEmpty { SheetNote(model.status.coreError, color: .orange) }
                }
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// the panel's state, "Use this FM-1" (design section 10: when another instance holds it) and the Bluetooth pairing
    private var fm1Card: some View {
        let p = model.status.panel
        let reason: String? = p == nil ? "No panel link" : p?.hasUnit == false ? "No FM-1 found: pair it over Bluetooth." : nil
        return VStack(alignment: .leading, spacing: 0) {
            SourceCard(title: p?.owner == true && p?.link.isConnected == true ? "FM-1 linked" : chip.text,
                       sub: p?.line ?? "No panel link", selected: p?.owner == true,
                       dot: chip == .inUse ? Palette.sheetAccent : Palette.linkedDot) {}
                .allowsHitTesting(false)
            HStack(spacing: 8) {
                if p?.owner != true {
                    SheetButton("Use this FM-1", accent: p?.heldElsewhere == true) { model.claim() }
                        .disabled(reason != nil)
                        .opacity(reason != nil ? 0.5 : 1)
                }
                SheetButton("Bluetooth…") { model.onBluetooth?() }
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            if let reason, p?.owner != true { SheetNote(reason) }
            if p?.foreignSession == true { SheetNote("The FM-1 had a session from elsewhere.", color: .orange) }
            if let w = p?.leaseWarning { SheetNote(w, color: .orange) }
        }
    }

    private var firmwarePage: some View {
        SheetPage("Firmware", back: { model.page = nil }) {
            SheetSectionTitle("Core", top: 12)
            SheetList {
                ForEach(Array(model.cores.enumerated()), id: \.element.id) { i, c in
                    SheetRow(c.name, value: c.version, divider: i < model.cores.count - 1, chevron: false,
                             check: c.id == model.status.coreID) { model.select(c.id) }
                }
            }
            SheetList {
                SheetRow("About this firmware") { model.onAbout?(model.current) }
                SheetRow("Restart the firmware", divider: false, chevron: false) { model.restart() }
            }
            .padding(.top, 16)
            let s = model.status.core
            if s.halted { SheetNote(String(format: "Firmware halted (exit %u)", s.haltCode & 0xFF), color: .orange) }
            SheetNote(s.booted ? "\(model.status.coreName), slot \(s.slot) · instance \(model.instance)"
                      : "No firmware running · instance \(model.instance)")
        }
    }

    private var diagnosticsPage: some View {
        SheetPage("Diagnostics", back: { model.page = nil; model.diagnosticsOpen = false }) {
            Rows(rows: rows).foregroundStyle(Palette.sheetText).padding(.top, 8)
            DiagnosticsView(report: model.report).padding(.top, 12)
        }
    }

    private var rows: [(String, String)] {
        let s = model.status, c = s.core, p = s.panel
        var r: [(String, String)] = [
            ("instance", model.instance),
            ("render", c.renders == 0 ? "–" : String(format: "avg %u us, max %u us per %u frames (%.0f%%)",
                                                    c.renderAvgUs, c.renderMaxUs, c.renderLastFrames, c.renderLoad * 100)),
            ("clock", ["stopped", "audio", "timer (no sound)", "caller"][min(max(c.clock, 0), 3)]),
            ("MIDI", "in \(s.midiIn) (\(s.midiNotes) notes), out \(s.midiOutMsgs)"),
            ("flash", "\(c.flashSize / 1024) KiB, from \(s.bootedFrom.isEmpty ? "–" : s.bootedFrom)"),
        ]
        if let p {
            r.append(("panel", p.line))
            r.append(("lease", "epoch \(p.epoch), \(p.owner ? "owner" : p.leaseEmpty ? "empty" : p.ownerStale ? "stale" : "held")"
                      + (p.ownerName.isEmpty ? "" : ": \(p.ownerName)")))
            r.append(("link", p.linkText))
            if p.duplicate { r.append(("identity", "a duplicated state: a new UUID")) }
        }
        return r
    }
}
