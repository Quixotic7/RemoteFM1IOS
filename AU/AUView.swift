// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The extension's view: the same on-screen FM-1 as the app (RFMKit's FaceplateView) playing this instance's core.
// The host decides the size, so the view picks from it (design/README.md section 4's suggestion): wide and short ->
// the landscape layout, tall -> the Controls view, very small -> the Screen view (until the user picks a view). The
// grabber sits inside the view's top edge; its sheet holds the AU's own items: the FM-1 (Use this FM-1, Bluetooth),
// the view, the theme (shared with the app through the App Group), the firmware (About, Restart), the MIDI octave,
// and Diagnostics (the instance's numbers and M2's probes). M7: the firmware page lists the imported .rfm1 files too
// (the app's mirror in the App Group); a Wasm core that can't keep up shows a note over the faceplate. M8: Knobs from
// MIDI (MIDI learn on the host's MIDI, the knob speed, the mappings: global, shared with the app); learn mode on the
// faceplate, its bar and the toasts over the sheet (FaceplateOverlay). The MIDI section: notes play keys, ...and reach
// the firmware, the octave, the host's clock (PLAN.md section 11). On a Mac: the window's size (Window).
// Keys from MIDI and a learned knob's mode are pages of the sheet: a SwiftUI Menu is clipped in a host (AUM).

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
                if !model.ui.sheetOpen {
                    VStack { Spacer(); PerfBanner(model.perfNote).padding(.bottom, 8) }
                }
                PullDownSheet(open: Binding(get: { model.ui.sheetOpen }, set: { model.ui.sheetOpen = $0 })) {
                    AUSheet(model: model)
                }
                FaceplateOverlay(feed: model.feed, bottom: !model.ui.sheetOpen && !model.perfNote.isEmpty ? 56 : 10,
                                 barAtTop: model.ui.page == .controls && model.ui.deck == .buttons)
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

    var body: some View {
        sheet.onChange(of: model.ui.sheetOpen) { _, open in
            if open { model.learn.stop() } else { model.page = nil }
        }
    }

    private var chip: PanelChip { model.chip }

    private func close() { withAnimation(.easeInOut(duration: 0.28)) { model.ui.sheetOpen = false } }

    @ViewBuilder private var sheet: some View {
        switch model.page {
        case .firmware: firmwarePage
        case .midi: midiPage
        case .keyChannel: keyChannelPage
        case .midiMode: modePage
        case .diagnostics: diagnosticsPage
        case nil: mainSheet
        }
    }

    private var mainSheet: some View {
        VStack(spacing: 0) {
            SheetHeader("Controls", done: close)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        SheetSectionTitle("FM-1", top: 18)
                        fm1Card
                        SheetSectionTitle("View · or swipe sideways")
                        ViewTiles(ui: model.ui) { model.userPicked = true }
                        if model.macWindow { windowSection.id("window") }
                        SheetSectionTitle("Theme")
                        ThemeSwatches(store: store, edit: nil)
                        SheetList {
                            SheetRow("Firmware", value: model.status.coreName.isEmpty ? "–" : model.status.coreName) {
                                model.page = .firmware
                            }
                            SheetRow("Diagnostics", divider: false) {
                                model.page = .diagnostics
                                model.diagnosticsOpen = true
                            }
                        }
                        .padding(.top, 20)
                        if !model.status.coreError.isEmpty { SheetNote(model.status.coreError, color: .orange) }
                        else if !model.status.coreNote.isEmpty { SheetNote(model.status.coreNote, color: .orange) }
                        midiSection
                    }
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onAppear {
                    guard let id = model.sheetScroll else { return }
                    model.sheetScroll = nil
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    /// (a Mac) the window's size: hosts that follow preferredContentSize resize at once, Ableton when reopened
    private var windowSection: some View {
        let s = model.windowSize, sizes = AUViewModel.windowSizes
        let i = sizes.firstIndex { $0.1 == s }
        return VStack(spacing: 0) {
            SheetSectionTitle("Window · \(Int(s.width))×\(Int(s.height))")
            SheetList {
                SheetSegmented("Size", options: sizes.map(\.0) + (i == nil ? ["Custom"] : []),
                               selected: i ?? sizes.count, divider: false) { k in
                    if k < sizes.count { model.onPickSize?(sizes[k].1) }
                }
            }
            SheetNote("Ableton: close and reopen the plugin window to apply.")
        }
    }

    /// the host's MIDI to the firmware (PLAN.md section 11): the keys, the octave, the host's clock, learn
    private var midiSection: some View {
        let s = model.status.settings
        let set = { (change: @escaping (inout AUSettings) -> Void) in model.changeSettings(change) }
        return VStack(spacing: 0) {
            SheetSectionTitle("MIDI").id("midi")
            SheetList {
                KeyChannelRows(channel: s.keyChannel,
                               toFirmware: Binding(get: { s.keyNotesToFirmware },
                                                   set: { v in set { $0.keyNotesToFirmware = v } })) {
                    model.page = .keyChannel
                }
                SheetStepper("MIDI octave", value: Binding(get: { s.transpose }, set: { v in set { $0.transpose = v } }),
                             in: -2...2)
                SheetToggle("Send the host's clock and transport", on: Binding(get: { s.hostClock },
                                                                              set: { v in set { $0.hostClock = v } }))
                SheetToggle("Use learned knobs", on: useMap)
                SheetRow("Knobs from MIDI", value: MidiMapStore.shared.mappings.isEmpty ? nil
                         : "\(MidiMapStore.shared.mappings.count) learned", divider: false) { model.page = .midi }
            }
            SheetNote("Keys from MIDI: notes on that channel (or any) play the keys. Notes on other channels, every "
                      + "note when Off (FIZZ's tracks), and whatever the learned knobs don't take go to the firmware's "
                      + "MIDI in. Use learned knobs off: the mappings are kept but do nothing; Learn still works. The host's clock: its tempo, start, stop and position as MIDI clock (clock "
                      + "in the host's MIDI is then dropped). The firmware's MIDI out is this instrument's MIDI output.")
        }
    }

    /// AUSettings.useLearnedMap
    private var useMap: Binding<Bool> {
        Binding(get: { model.status.settings.useLearnedMap }, set: { v in model.changeSettings { $0.useLearnedMap = v } })
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
        let builtIn = model.cores.filter { !$0.imported }, imported = model.cores.filter(\.imported)
        return SheetPage("Firmware", back: { model.page = nil }) {
            SheetSectionTitle("Built in", top: 12)
            SheetList {
                ForEach(Array(builtIn.enumerated()), id: \.element.id) { i, c in
                    SheetRow(c.name, value: c.version, divider: i < builtIn.count - 1, chevron: false,
                             check: c.id == model.status.coreKey) { model.select(c.id) }
                }
            }
            SheetSectionTitle("Imported")
            if !imported.isEmpty {
                SheetList {
                    ForEach(Array(imported.enumerated()), id: \.element.id) { i, c in
                        SheetRow(c.name, value: c.version, divider: i < imported.count - 1, chevron: false,
                                 check: c.id == model.status.coreKey) { model.select(c.id) }
                    }
                }
            }
            SheetNote("Add .rfm1 firmware in the RemoteFM1 app (Firmware › Add firmware…, or Files › RemoteFM1 › Firmware); "
                      + "open the app once after adding files so the instrument sees them.")
            SheetList {
                SheetRow("About this firmware") { model.onAbout?(model.current) }
                SheetRow("Restart the firmware", divider: false, chevron: false) { model.restart() }
            }
            .padding(.top, 16)
            let s = model.status.core
            if s.halted {
                SheetNote(s.haltCode == 0x200 ? "Firmware stopped: the WebAssembly module trapped"
                          : String(format: "Firmware halted (exit %u)", s.haltCode & 0xFF), color: .orange)
            }
            if s.booted && s.kind == "wasm" {
                SheetNote(String(format: "WebAssembly: %u%% of the audio time on the core thread, %u underruns.",
                                 s.coreLoadPct, s.underruns))
            }
            if !model.perfNote.isEmpty { SheetNote(model.perfNote, color: .orange) }
            SheetNote(s.booted ? "\(model.status.coreName)\(s.slot > 0 ? ", slot \(s.slot)" : " (imported)") · instance \(model.instance)"
                      : "No firmware running · instance \(model.instance)")
        }
    }

    /// Keys from MIDI's choices (a page: a SwiftUI Menu can't open inside the host's view)
    private var keyChannelPage: some View {
        SheetPage("Keys from MIDI", back: { back(to: nil) }) {
            KeyChannelList(channel: Binding(get: { model.status.settings.keyChannel },
                                            set: { v in model.changeSettings { $0.keyChannel = v } }))
        }
    }

    /// a learned encoder's mode
    private var modePage: some View {
        SheetPage("Knob mode", backTitle: "Knobs from MIDI", back: { back(to: .midi) }) {
            MidiModeList(src: model.modeSource ?? "")
        }
    }

    /// back to the main sheet (at its MIDI section) or to a page
    private func back(to p: AUViewModel.Page?) {
        if p == nil { model.sheetScroll = "midi" }
        model.page = p
    }

    /// Knobs from MIDI: learned from the host's MIDI (route a controller to this instrument in the host)
    private var midiPage: some View {
        SheetPage("Knobs from MIDI", back: { model.page = nil }) {
            MidiMapSection(top: 12, titled: false, useMap: useMap, pickMode: { src in
                model.modeSource = src
                model.page = .midiMode
            }) { model.startLearn() }
            SheetNote("Learn listens to the MIDI the host sends this instrument: route your controller to it. The "
                      + "mappings are shared by the RemoteFM1 app and every instance.")
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
            ("ahead", c.aheadText),
            ("clock", ["stopped", "audio", "timer (no sound)", "caller"][min(max(c.clock, 0), 3)]),
            ("MIDI", "in \(s.midiIn) (\(s.midiNotes) notes), out \(s.midiOutMsgs)"),
            ("host clock", s.hostClockText),
            ("parameters", s.paramsText),
            ("flash", "\(c.flashSize / 1024) KiB, from \(s.bootedFrom.isEmpty ? "–" : s.bootedFrom)"),
            ("cores", RFMAudioUnit.slotsLine.isEmpty ? "–" : RFMAudioUnit.slotsLine),
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
