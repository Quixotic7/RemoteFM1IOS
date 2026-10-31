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
                if !model.ui.sheetOpen && !model.ui.displayAlone {
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
        .onAppear {
            store.observe()
            model.ui.onWord = { [model] in       // (the word: the firmware's name) the sheet on the Firmware page
                model.page = .firmware
                withAnimation(.easeInOut(duration: 0.28)) { model.ui.sheetOpen = true }
            }
        }
        .onChange(of: model.status.coreName, initial: true) { _, n in model.ui.firmwareName = n }
    }
}

/// the sheet's items (its own view: the instance's numbers it reads redraw only it)
struct AUSheet: View {
    @Bindable var model: AUViewModel
    private let store = ThemeStore.shared
    @State private var askReset = false         // (section 18) Reset firmware… asked inline
    @State private var askRestore: String?      // the safety copy whose row asks "Restore?"
    @State private var saveOpen = false         // Save state…: the States page with its field open
    @State private var statesFromMain = false   // the States page goes back to the main sheet

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
        case .states: statesPage
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
                        SheetSectionTitle(model.status.coreName.isEmpty ? "Firmware"
                                          : "\(model.status.coreName) \(model.status.coreVersion)", top: 18)
                        dataRows(fromMain: true)
                        SheetSectionTitle("FM-1")
                        fm1Card
                        SheetSectionTitle("View · or swipe sideways")
                        ViewTiles(ui: model.ui) { model.userPicked = true }
                        SheetList {
                            SheetToggle("Firmware's button names",
                                        on: Binding(get: { model.status.settings.buttonNames },
                                                    set: { v in model.changeSettings { $0.buttonNames = v } }),
                                        divider: true)
                            SheetToggle("Screen protector", on: Binding(get: { ScreenProtector.shared.on },
                                                                        set: { ScreenProtector.shared.on = $0 }),
                                        divider: false)
                        }
                        .padding(.top, 12)
                        SheetNote("Double-tap the display to see it alone; double-tap again or swipe down to close.")
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

    /// the firmware's data here: Save state…, States & safety copies, Reset firmware… (backups: the app)
    @ViewBuilder private func dataRows(fromMain: Bool) -> some View {
        let off = !model.status.core.booted
        SheetList {
            SheetRow("Save state…", chevron: false) { openStates(fromMain: fromMain, saving: true) }.disabled(off)
            SheetRow("States & safety copies", value: "\(model.states.count) · \(model.copies.count)") {
                openStates(fromMain: fromMain)
            }
            .disabled(off)
            ResetFirmwareRow(name: model.status.coreName.isEmpty ? "the firmware" : model.status.coreName,
                             asking: $askReset, divider: false) { model.resetFlash() }
        }
        .onAppear { model.reloadStates() }
    }

    private func openStates(fromMain: Bool, saving: Bool = false) {
        model.reloadStates()
        model.stateMessage = ""
        statesFromMain = fromMain
        saveOpen = saving
        model.page = .states
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
                SheetToggle("Velocity & pressure from my FM-1", on: Binding(get: { s.keyTouch },
                                                                           set: { v in set { $0.keyTouch = v } }))
                SheetToggle("Send the host's clock and transport", on: Binding(get: { s.hostClock },
                                                                              set: { v in set { $0.hostClock = v } }))
                SheetToggle("Use learned knobs", on: useMap)
                SheetRow("Knobs from MIDI", value: MidiMapStore.shared.mappings.isEmpty ? nil
                         : "\(MidiMapStore.shared.mappings.count) learned", divider: false) { model.page = .midi }
            }
            SheetNote("Keys from MIDI: notes on that channel (or any) play the keys. Notes on other channels, every "
                      + "note when Off (FIZZ's tracks), and whatever the learned knobs don't take go to the firmware's "
                      + "MIDI in. Velocity & pressure: the FM-1's keys play at their own velocity, and their pressure "
                      + "reaches the firmware (RemoteFM1 0.3.1 or later; off: velocity 100, as before). Use learned knobs off: the mappings are kept but do nothing; Learn still works. The host's clock: its tempo, start, stop and position as MIDI clock (clock "
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
            if let p, p.owner, p.hasUnit, !p.fake, p.link == .notFound {   // (the AU can't install: the app does)
                SheetNote("An FM-1 is connected but isn't answering as RemoteFM1. Install RemoteFM1 from the "
                          + "RemoteFM1 app (Settings › FM-1 firmware).", color: .orange)
            }
            if p?.foreignSession == true { SheetNote("The FM-1 had a session from elsewhere.", color: .orange) }
            if let w = p?.leaseWarning { SheetNote(w, color: .orange) }
        }
    }

    private var firmwarePage: some View {
        let builtIn = model.cores.filter { !$0.imported }, imported = model.cores.filter(\.imported)
        return SheetPage(model.status.coreName.isEmpty ? "Firmware" : model.status.coreName, back: { model.page = nil }) {
            if let c = model.current {
                FirmwareInfoCard(info: FirmwareInfo.lookup(c, details: model.details), running: model.status.core.booted) { u, done in
                    if let o = model.onOpenURL { o(u, done) } else { done(false) }
                }
                .padding(.top, 12)
                .onAppear {
                    model.details = FirmwareDetailsShare.load()
                    FirmwareThumbs.shared.reload()
                }
            }
            SheetSectionTitle("This firmware", top: 12)
            SheetList {
                SheetRow("About this firmware") { model.onAbout?(model.current) }
                SheetRow("Restart the firmware", divider: false, chevron: false) { model.restart() }
            }
            dataRows(fromMain: false).padding(.top, 12)
            SheetSectionTitle("Built in")
            FirmwareTileGrid(cores: builtIn, selected: model.status.coreKey) { model.select($0) }
            SheetSectionTitle("Imported")
            if !imported.isEmpty {
                FirmwareTileGrid(cores: imported, selected: model.status.coreKey) { model.select($0) }
            }
            if model.fileGone {
                SheetNote("\(model.status.coreName.isEmpty ? "This firmware" : model.status.coreName)'s file was deleted in "
                          + "the RemoteFM1 app. It keeps playing here; when the project is opened again, another version "
                          + "of it (or another firmware) plays.", color: .orange)
            }
            SheetNote("Add .rfm1 firmware in the RemoteFM1 app (Firmware › Add firmware…, or Files › RemoteFM1 › Firmware); "
                      + "open the app once after adding files so the instrument sees them.")
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

    /// (section 18 step 2) the library's states of this instance's firmware (the app's too) and its safety copies
    private var statesPage: some View {
        let name = model.status.coreName
        return SheetPage("States", backTitle: statesFromMain ? "Controls" : "Firmware",
                         back: { askRestore = nil; model.page = statesFromMain ? nil : .firmware }) {
            SheetSectionTitle("\(name.isEmpty ? "Firmware" : name) \(model.status.coreVersion)", top: 12)
            StatesList(firmware: name, version: model.status.coreVersion, states: model.states,
                       saveTitle: "Save to library…", startSaving: saveOpen, save: { model.saveState($0) }, load: { model.loadState($0) },
                       rename: { model.renameState($0, $1) }, delete: { model.deleteState($0) },
                       shareNote: "Share it from the RemoteFM1 app (Firmware › States); it's in Files › RemoteFM1 › States too.")
            SheetNote("Save to library keeps this instance's memory, MASTER, the octave and the keys' touch under a name; "
                      + "the RemoteFM1 app and every AU instance share the library. Loading replaces this instance's "
                      + "memory (a safety copy is kept first); the host keeps it in the project at its next save.")
            if !model.stateMessage.isEmpty { SheetNote(model.stateMessage, color: .orange) }
            SheetSectionTitle("Safety copies")
            SafetyCopiesList(copies: model.copies, asking: $askRestore) { model.restore($0) }
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
            MidiMapSection(top: 12, titled: false, useMap: useMap, names: model.feed.names.value, pickMode: { src in
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
            r.append(("touch", p.touchText))
            if p.duplicate { r.append(("identity", "a duplicated state: a new UUID")) }
        }
        return r
    }
}
