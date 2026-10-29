// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The app's screen: the on-screen FM-1 (RFMKit's FaceplateView) playing the CorePlayer's core, and the pull-down sheet:
// Sound source (This iPhone = the emulator, the FM-1 link stopped; FM-1 = RemoteFM1 over Bluetooth, the link and the
// lease, "Use this FM-1" when another instance holds it, Bluetooth pairing), View, Theme (and its editor), then
// Firmware (the core picker, About), MIDI & audio, Settings (Diagnostics: the old debug screen with the test pattern
// and the AU test). The last view is remembered per sound source. LaunchOptions reaches every state without touches.
// M7: the Firmware page lists the built-in cores and the imported .rfm1 files (Documents/Firmware: FirmwareLibrary),
// with "Add firmware…" (a document picker), a long press to delete one, and each invalid file with its error; a Wasm
// core that can't keep up shows a note over the faceplate (PerfBanner).

import UniformTypeIdentifiers

import RFMKit
import SwiftUI
import UIKit

/// the launch arguments for the faceplate (scripts/sim_shots.sh)
struct LaunchOptions {
    var page: FaceplateUI.Page?
    var deck: FaceplateUI.Deck?
    var knobs: FaceplateUI.KnobSet?
    var source: SoundSource?
    var sheet = false
    var sheetPage: AppSheetPage?
    var themeEditor = false
    var landscape: Bool?
    var steps = false

    init(_ a: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ k: String) -> String? {
            guard let i = a.firstIndex(of: k), i + 1 < a.count else { return nil }
            return a[i + 1]
        }
        page = value("-view").flatMap(FaceplateUI.Page.init(rawValue:))
        deck = value("-deck").flatMap(FaceplateUI.Deck.init(rawValue:))
        knobs = value("-knobs").flatMap(FaceplateUI.KnobSet.init(rawValue:))
        source = value("-source").flatMap(SoundSource.init(rawValue:))
        sheet = a.contains("-sheet")
        sheetPage = value("-sheetpage").flatMap(AppSheetPage.init(rawValue:))
        themeEditor = a.contains("-themeeditor")
        if let o = value("-orientation") { landscape = o == "landscape" }
        steps = a.contains("-steps")
    }
}

enum SoundSource: String { case phone, fm1 }
enum AppSheetPage: String { case firmware, midi, settings }

struct MainScreen: View {
    let controller: RemoteController
    let player: CorePlayer
    let library: FirmwareLibrary
    @State private var ui = FaceplateUI()
    @State private var showImporter = false
    @State private var feed: PanelFeed
    @State private var page: AppSheetPage?
    @State private var showDiagnostics = false
    @State private var showAUTest = false
    @State private var showBluetooth = false
    @State private var showAbout = false
    @State private var source: SoundSource
    @State private var launched = false
    @State private var turned = false                  // (-orientation landscape refused: drawn turned, for screenshots)
    private let store = ThemeStore.shared
    private let options = LaunchOptions()

    init(controller: RemoteController, player: CorePlayer, library: FirmwareLibrary) {
        self.controller = controller
        self.player = player
        self.library = library
        _feed = State(initialValue: PanelFeed(host: player))
        let saved = UserDefaults.standard.string(forKey: "rfm1.source").flatMap(SoundSource.init(rawValue:))
        _source = State(initialValue: LaunchOptions().source ?? saved ?? .fm1)
    }

    var chip: PanelChip {
        guard source == .fm1 else { return .emulator }
        if controller.panel?.heldElsewhere == true { return .inUse }
        return controller.state.isConnected ? .linked : .searching
    }

    var body: some View {
        GeometryReader { geo in
            if turned {                                 // (the screenshot script turns the PNG back)
                screen.frame(width: geo.size.height, height: geo.size.width)
                    .rotationEffect(.degrees(-90))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .statusBarHidden(true)
            } else {
                screen
            }
        }
        .ignoresSafeArea(turned ? .all : [])
    }

    private var screen: some View {
        let theme = store.current
        return ZStack {
            FaceplateView(feed: feed, ui: ui, theme: theme, chip: chip)
                .equatable()
                .ignoresSafeArea()
            if !ui.sheetOpen && !ui.editorOpen {
                VStack { Spacer(); PerfBanner(player.perfNote).padding(.bottom, 12) }
                    .animation(.easeInOut(duration: 0.2), value: player.perfNote.isEmpty)
            }
            PullDownSheet(open: $ui.sheetOpen) { sheet }
            if ui.editorOpen {
                ThemeEditor(store: store, feed: feed) { withAnimation { ui.editorOpen = false } }
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
        }
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(ui.sheetOpen || ui.editorOpen || theme.body.luminance < 0.3 ? .dark : .light)
        .sheet(isPresented: $showBluetooth) { BluetoothSheet() }
        .sheet(isPresented: $showAbout) {
            AboutFirmware(info: player.current, onDelete: deleteAction(player.current))
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [FirmwareLibrary.fileType, .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var last: ImportedFirmware?
            for u in urls { last = (try? library.importFile(u)) ?? last }
            player.catalogChanged()
            if let f = last, f.error == nil { player.select(f.key) }
        }
        .fullScreenCover(isPresented: $showDiagnostics) {
            DiagnosticsScreen(controller: controller, player: player) { showDiagnostics = false }
        }
        .fullScreenCover(isPresented: $showAUTest) { AUTestView(host: AUTestHost(auto: false)).preferredColorScheme(.dark) }
        .onAppear(perform: launch)
        .onChange(of: ui.page) { _, _ in saveView() }
        .onChange(of: ui.deck) { _, _ in saveView() }
        .onChange(of: ui.knobSet) { _, _ in saveView() }
        .onChange(of: ui.sheetOpen) { _, open in if !open { page = nil } }
    }

    // MARK: launch, the view per source

    private func launch() {
        guard !launched else { return }
        launched = true
        store.observe()
        loadView(source)
        if let p = options.page { ui.page = p }
        if let d = options.deck { ui.deck = d }
        if let k = options.knobs { ui.knobSet = k }
        if options.steps { ui.stepNumbers = true }
        if options.sheet || options.sheetPage != nil { ui.sheetOpen = true }
        page = options.sheetPage
        if options.themeEditor { ui.editorOpen = true }
        if source == .fm1 { controller.appeared() } else if controller.isRunning { controller.stop() }
        if let l = options.landscape, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            // (an iPad's windowing mode refuses it: the faceplate is then drawn turned, for scripts/sim_shots.sh)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: l ? .landscapeRight : .portrait)) { err in
                RFMShared.log("ui").error("orientation: \(err.localizedDescription, privacy: .public)")
                if l { DispatchQueue.main.async { turned = true } }
            }
        }
    }

    private func viewKey(_ s: SoundSource) -> String { "rfm1.view.\(s.rawValue)" }

    private func saveView() {
        UserDefaults.standard.set([ui.page.rawValue, ui.deck.rawValue, ui.knobSet.rawValue], forKey: viewKey(source))
    }

    /// the last view used with this source (Full by default)
    private func loadView(_ s: SoundSource) {
        let v = UserDefaults.standard.stringArray(forKey: viewKey(s)) ?? []
        ui.page = v.first.flatMap(FaceplateUI.Page.init(rawValue:)) ?? .full
        ui.deck = v.dropFirst().first.flatMap(FaceplateUI.Deck.init(rawValue:)) ?? .buttons
        ui.knobSet = v.dropFirst(2).first.flatMap(FaceplateUI.KnobSet.init(rawValue:)) ?? .main
    }

    private func pick(_ s: SoundSource) {
        guard s != source else {
            if s == .fm1, !controller.isRunning, controller.panel?.heldElsewhere != true { controller.start() }
            return
        }
        saveView()
        source = s
        UserDefaults.standard.set(s.rawValue, forKey: "rfm1.source")
        withAnimation(.easeInOut(duration: 0.25)) { loadView(s) }
        switch s {
        case .phone: if controller.isRunning { controller.stop() }   // (the emulator: no link)
        case .fm1: if controller.panel?.heldElsewhere != true { controller.start() }   // (else: Use this FM-1)
        }
    }

    // MARK: the sheet

    @ViewBuilder private var sheet: some View {
        switch page {
        case .firmware: firmwarePage
        case .midi: midiPage
        case .settings: settingsPage
        case nil: mainSheet
        }
    }

    private func close() { withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = false } }

    private var mainSheet: some View {
        VStack(spacing: 0) {
            SheetHeader("Controls", done: close)
            ScrollView {
                VStack(spacing: 0) {
                    SheetSectionTitle("Sound source", top: 18)
                    HStack(spacing: 8) {
                        SourceCard(title: "This iPhone", sub: "Emulator, play by touch", selected: source == .phone,
                                   dot: Palette.sheetAccent) { pick(.phone) }
                        SourceCard(title: "FM-1", sub: fm1Line, selected: source == .fm1,
                                   dot: chip == .inUse ? Palette.sheetAccent : Palette.linkedDot) { pick(.fm1) }
                    }
                    if source == .fm1, chip != .linked { fm1Actions }     // (not linked: claim it, or pair it)
                    SheetSectionTitle("View · or swipe sideways")
                    ViewTiles(ui: ui)
                    SheetSectionTitle("Theme")
                    ThemeSwatches(store: store) { withAnimation { ui.editorOpen = true } }
                    SheetList {
                        SheetRow("Firmware", value: player.current?.name ?? "–") { page = .firmware }
                        SheetRow("MIDI & audio") { page = .midi }
                        SheetRow("Settings", divider: false) { page = .settings }
                    }
                    .padding(.top, 20)
                    if !player.message.isEmpty { SheetNote(player.message, color: .orange) }
                }
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var fm1Line: String {
        if let p = controller.panel, p.heldElsewhere {
            return p.ownerName.isEmpty ? "In use by another instance" : "In use by \(p.ownerName)"
        }
        switch controller.state {
        case .connected(let ble): return "RemoteFM1 · \(ble ? "Bluetooth" : "USB")\(controller.backend.isFake ? " (fake)" : "")"
        case .notFound: return "Not found · pair over Bluetooth"
        default: return "RemoteFM1 · Bluetooth"
        }
    }

    /// the FM-1 card's actions: Use this FM-1 (design section 10) and the Bluetooth pairing
    private var fm1Actions: some View {
        HStack(spacing: 8) {
            if controller.panel?.heldElsewhere == true || (!controller.isRunning && controller.panel?.owner != true) {
                SheetButton("Use this FM-1", accent: true) { controller.start() }
            }
            SheetButton("Bluetooth…") { showBluetooth = true }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
    }

    /// Delete for an imported file (nil for a built-in core)
    private func deleteAction(_ c: CoreInfo?) -> (() -> Void)? {
        guard let c, c.imported, let f = library.files.first(where: { $0.key == c.id }) else { return nil }
        return {
            library.delete(f)
            player.catalogChanged()
        }
    }

    private var firmwarePage: some View {
        let builtIn = player.cores.filter { !$0.imported }
        let imported = player.cores.filter(\.imported)
        let broken = library.files.filter { $0.error != nil }
        return SheetPage("Firmware", back: { page = nil }) {
            SheetSectionTitle("Built in", top: 12)
            SheetList {
                ForEach(Array(builtIn.enumerated()), id: \.element.id) { i, c in
                    SheetRow("\(c.name)", value: c.version, divider: i < builtIn.count - 1, chevron: false,
                             check: c.id == player.selected) { player.select(c.id) }
                }
            }
            SheetSectionTitle("Imported")
            SheetList {
                ForEach(imported) { c in
                    SheetRow("\(c.name)", value: c.version, chevron: false, check: c.id == player.selected) { player.select(c.id) }
                        .contextMenu {
                            Button("About \(c.name)") { player.select(c.id); showAbout = true }
                            if let del = deleteAction(c) { Button("Delete", role: .destructive, action: del) }
                        }
                }
                ForEach(broken) { f in
                    SheetRow(f.file, value: "can't load", chevron: false) {}
                        .opacity(0.55)
                        .contextMenu { Button("Delete", role: .destructive) { library.delete(f) } }
                }
                SheetRow("Add firmware…", divider: false) { showImporter = true }
            }
            SheetNote(imported.isEmpty && broken.isEmpty
                      ? "Put .rfm1 firmware files in Files › On My \(UIDevice.current.model) › RemoteFM1 › Firmware, or add one here."
                      : "Touch and hold an imported firmware to delete it. Files › On My \(UIDevice.current.model) › RemoteFM1 › Firmware holds them.")
            ForEach(broken) { f in SheetNote("\(f.file): \(f.error ?? "")", color: .orange) }
            if !library.message.isEmpty { SheetNote(library.message) }
            SheetList {
                SheetRow("About this firmware") { showAbout = true }
                    .disabled(player.current == nil)
                SheetRow("Restart the firmware", divider: false, chevron: false) { player.powerCycle() }
            }
            .padding(.top, 16)
            if player.current?.imported == true, player.status.booted {
                SheetNote(player.status.coreWakes == 0 ? "Runs in the WebAssembly interpreter (no sound yet)."
                          : String(format: "Runs in the WebAssembly interpreter: %u%% of the audio time on the core thread, "
                                   + "%u underruns.", player.status.coreLoadPct, player.status.underruns))
            }
            if !player.perfNote.isEmpty { SheetNote(player.perfNote, color: .orange) }
            if player.mode != .core {
                SheetNote("The test pattern is on (Settings · Diagnostics): the keys play nothing.")
                SheetButton("Run the firmware") { player.setMode(.core) }.padding(.top, 8)
            }
            if !player.message.isEmpty { SheetNote(player.message, color: .orange) }
        }
    }

    private var midiPage: some View {
        SheetPage("MIDI & audio", back: { page = nil }) {
            SheetSectionTitle("Audio", top: 12)
            SheetList {
                SheetToggle("Sound", on: Binding(get: { player.audioOn }, set: { player.setAudio($0) }), divider: false)
            }
            SheetNote(player.audioRunning ? player.audioText + String(format: "; %.1f ms ahead, %u underruns",
                                                                      player.status.latencyMs, player.status.underruns)
                      : "No sound: the firmware runs on a timer.")
            SheetSectionTitle("MIDI")
            SheetList {
                SheetRow("Bluetooth MIDI devices") { showBluetooth = true }
                SheetRow("Look for the FM-1 again", divider: false, chevron: false) { controller.rescan() }
            }
            SheetNote("FM-1 link: \(controller.statusText)")
        }
    }

    private var settingsPage: some View {
        SheetPage("Settings", back: { page = nil }) {
            SheetSectionTitle("Keys", top: 12)
            SheetList {
                SheetToggle("Step numbers on the keys", on: $ui.stepNumbers, divider: false)
            }
            SheetNote("Shows 1–16 on the lower keys, for a firmware in a step mode.")
            SheetSectionTitle("Diagnostics")
            SheetList {
                SheetRow("Diagnostics") { showDiagnostics = true }
                SheetRow("AU test", divider: false) { showAUTest = true }
            }
            SheetNote("Diagnostics has the link, the core, the unit's HELLO_R and the test pattern mode.")
        }
    }
}
