// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The app's screen: the on-screen FM-1 (RFMKit's FaceplateView) playing the CorePlayer's core, and the pull-down sheet:
// Sound source (This iPhone = the emulator, the FM-1 link stopped; FM-1 = RemoteFM1 over Bluetooth, the link and the
// lease, "Use this FM-1" when another instance holds it, Bluetooth pairing), View, Theme (and its editor), then
// Firmware (the core picker, About), MIDI & audio, Settings (Diagnostics: the old debug screen with the test pattern
// and the AU test). The last view is remembered per sound source. LaunchOptions reaches every state without touches.
// M7: the Firmware page lists the built-in cores and the imported .rfm1 files (Documents/Firmware: FirmwareLibrary),
// with "Add firmware…" (a document picker), Edit (a delete control per imported file, "Delete?" asked in the row; the
// selection moves to the same firmware's other version, its built-in core or the first core first), and each invalid
// file with its error; a Wasm core that can't keep up shows a note over the faceplate (PerfBanner).
// M8: the MIDI & audio page has the MIDI input (a sub-page), the notes' settings, Knobs from MIDI (MIDI learn, the
// knob speed, the mappings) and the OMX-27; Learn closes the sheet and puts the faceplate in learn mode (its bar and
// the toasts: FaceplateOverlay, over the sheet). Opening the sheet ends learn mode.
// Get firmware (GetFirmware.swift): a row on the Firmware page (its badge: the updates) opens the list of firmware to
// download (RFMKit's FirmwareStore); a row there opens the firmware's page. The Firmware row shows the badge too.
// Settings › Install RemoteFM1 on the FM-1 (RFMKit's Install/: FM1Kit over USB; -sheetpage install). An FM-1 that isn't
// running RemoteFM1, or an older RemoteFM1, gets a prompt over the faceplate (InstallPrompter; DEBUG: -fm1prompt
// install | unanswered | bluetooth | update) whose Install opens that page. Settings › Send a DX7 cartridge (RFMKit's
// Cart/: a .syx sent as a user bank; -sheetpage cart, DEBUG -cartdemo); an .syx opened from Files lands there.

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
    var learn = false                                   // (M8) learn mode at launch; learnPick: a control picked
    var learnPick: String?
    var sheetScroll: String?                            // an id on the sheet's page shown at the top (knobs, omx)
    var demoMap = false                                 // a few mappings, as if learned (writes the global map)
    var catalogItem: String?                            // (DEBUG) -catalogitem <id>: that firmware's Get firmware page
    var catalogGet: String?                             // (DEBUG) -catalogget <id>: download and install it at launch
    var cartDemo = false                                // (DEBUG) -cartdemo: two made-up cartridges on the cart page
    var firmwareEdit: String?                           // (DEBUG) -firmwareedit [ask]: the Firmware page in Edit (ask:
                                                        // the first imported row asks "Delete?")
    var askReset = false                                // (DEBUG) -askreset: the Firmware page asks "Reset firmware?"
    var safetyDemo = false                              // (DEBUG) -safetydemo: a few made-up safety copies

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
        learnPick = value("-learnpick")
        learn = a.contains("-learn") || learnPick != nil
        demoMap = a.contains("-demomap")
        sheetScroll = value("-sheetscroll")
        #if DEBUG
        catalogItem = value("-catalogitem")
        catalogGet = value("-catalogget")
        cartDemo = a.contains("-cartdemo")
        if a.contains("-firmwareedit") { firmwareEdit = value("-firmwareedit") ?? "" }
        askReset = a.contains("-askreset")
        safetyDemo = a.contains("-safetydemo")
        #endif
    }
}

enum SoundSource: String { case phone, fm1 }
enum AppSheetPage: String {
    case firmware, getFirmware = "getfirmware", catalogItem = "catalogitem", midi, midiInput = "midiinput", settings, install, cart
    case keyChannel = "keychannel", midiMode = "midimode", safetyCopies = "safetycopies"
}

struct MainScreen: View {
    let controller: RemoteController
    let player: CorePlayer
    let library: FirmwareLibrary
    let catalog: FirmwareStore
    let midi: AppMidi
    @State private var ui = FaceplateUI()
    @State private var showImporter = false
    @State private var feed: PanelFeed
    @State private var page: AppSheetPage?
    @State private var catalogItem: String?             // the firmware a Get firmware page shows
    @State private var modeSource: String?              // the mapping the Knob mode page shows
    @State private var midiScroll: String?              // where the MIDI & audio page opens (back from Knob mode)
    @State private var editingFirmware = false          // the Firmware page's Edit: a delete control per imported row
    @State private var confirmDelete: String?           // the file (its name) whose row asks "Delete?"
    @State private var showDiagnostics = false
    @State private var showAUTest = false
    @State private var showBluetooth = false
    @State private var showAbout = false
    @State private var askReset = false                 // Reset firmware… asked inline
    @State private var askRestore: String?              // the safety copy whose row asks "Restore?"
    @State private var source: SoundSource
    @State private var prompter: InstallPrompter
    @State private var launched = false
    @State private var turned = false                  // (-orientation landscape refused: drawn turned, for screenshots)
    private let store = ThemeStore.shared
    private let options = LaunchOptions()

    init(controller: RemoteController, player: CorePlayer, library: FirmwareLibrary, catalog: FirmwareStore, midi: AppMidi) {
        self.controller = controller
        self.player = player
        self.library = library
        self.catalog = catalog
        self.midi = midi
        _feed = State(initialValue: midi.feed)
        _prompter = State(initialValue: InstallPrompter(controller: controller, installer: .shared(for: controller)))
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
                VStack(spacing: 10) {
                    Spacer()
                    if !midi.learn.active {
                        InstallPromptView(prompt: prompter.prompt, install: openInstall) { prompter.notNow() }
                    }
                    PerfBanner(player.perfNote)
                }
                .padding(.bottom, 12)
                .animation(.easeInOut(duration: 0.2), value: player.perfNote.isEmpty)
            }
            PullDownSheet(open: $ui.sheetOpen) { sheet }
            if ui.editorOpen {
                ThemeEditor(store: store, feed: feed) { withAnimation { ui.editorOpen = false } }
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
            // MIDI learn's bar and the toasts (over the sheet; above the perf note when it shows)
            FaceplateOverlay(feed: feed, bottom: !ui.sheetOpen && !ui.editorOpen && !player.perfNote.isEmpty ? 64 : 14,
                             barAtTop: ui.page == .controls && ui.deck == .buttons)
                .zIndex(3)
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
            PickerFolder.firmware.remember(urls)
            var last: ImportedFirmware?
            for u in urls { last = (try? library.importFile(u)) ?? last }
            player.catalogChanged()
            if let f = last, f.error == nil { player.select(f.key) }
        }
        .fileDialogDefaultDirectory(showImporter ? PickerFolder.firmware.url : nil)
        .fullScreenCover(isPresented: $showDiagnostics) {
            DiagnosticsScreen(controller: controller, player: player) { showDiagnostics = false }
        }
        .fullScreenCover(isPresented: $showAUTest) { AUTestView(host: AUTestHost(auto: false)).preferredColorScheme(.dark) }
        .onAppear(perform: launch)
        .onOpenURL { url in                             // (an .syx from Files or AirDrop: the cartridge page)
            guard url.isFileURL, url.pathExtension.lowercased() == "syx" else { return }
            CartSender.shared(for: controller).add(url: url)
            page = .cart
            withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true }
        }
        .task { await catalog.refreshIfOlder(than: 86_400) }     // (at launch, at most once a day)
        .onChange(of: ui.page) { _, _ in saveView() }
        .onChange(of: ui.deck) { _, _ in saveView() }
        .onChange(of: ui.knobSet) { _, _ in saveView() }
        .onChange(of: ui.sheetOpen) { _, open in
            if open { midi.learn.stop() } else { page = nil }
        }
        .onChange(of: page) { _, p in
            if p != .firmware { editingFirmware = false; confirmDelete = nil }
            prompter.installPageOpen = p == .install
        }
    }

    // MARK: launch, the view per source

    private func launch() {
        guard !launched else { return }
        launched = true
        store.observe()
        prompter.start()
        loadView(source)
        if let p = options.page { ui.page = p }
        if let d = options.deck { ui.deck = d }
        if let k = options.knobs { ui.knobSet = k }
        if options.steps { ui.stepNumbers = true }
        if options.sheet || options.sheetPage != nil { ui.sheetOpen = true }
        page = options.sheetPage
        prompter.installPageOpen = page == .install
        if let id = options.catalogItem {
            catalogItem = id
            page = .catalogItem
            ui.sheetOpen = true
        }
        if let id = options.catalogGet { Task { await launchInstall(id) } }
        if let e = options.firmwareEdit {
            page = .firmware
            ui.sheetOpen = true
            editingFirmware = true
            if e == "ask" { confirmDelete = library.files.first?.file }
        }
        #if DEBUG
        if options.cartDemo { CartSender.shared(for: controller).addDemo() }
        if options.askReset { askReset = true }
        if options.safetyDemo { safetyDemo() }
        #endif
        if options.themeEditor { ui.editorOpen = true }
        if options.demoMap { midi.demoMap() }
        if options.learn {
            midi.learn.start(ui)
            if let t = options.learnPick { midi.learn.pick(t) }
        }
        if source == .fm1 { controller.appeared() } else if controller.isRunning { controller.stop() }
        if let l = options.landscape, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            // (an iPad's windowing mode refuses it: the faceplate is then drawn turned, for scripts/sim_shots.sh)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: l ? .landscapeRight : .portrait)) { err in
                RFMShared.log("ui").error("orientation: \(err.localizedDescription, privacy: .public)")
                if l { DispatchQueue.main.async { turned = true } }
            }
        }
    }

    /// (DEBUG) -catalogget: the list read (if it has no entry yet), then the firmware installed
    private func launchInstall(_ id: String) async {
        while catalog.checking { try? await Task.sleep(for: .milliseconds(100)) }
        if !catalog.available.contains(where: { $0.id == id }) { await catalog.refresh() }
        guard let e = catalog.available.first(where: { $0.id == id }) else {
            RFMShared.log("catalog").error("-catalogget \(id, privacy: .public): not in the list")
            return
        }
        let f = await catalog.install(e)
        RFMShared.log("catalog").info("-catalogget \(id, privacy: .public): \(f?.file ?? catalog.failure, privacy: .public)")
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
        case .safetyCopies: safetyCopiesPage
        case .getFirmware:
            GetFirmwarePage(store: catalog, builtIn: builtIn, scrollTo: options.sheetScroll, back: { page = .firmware }) { id in
                catalogItem = id
                page = .catalogItem
            }
        case .catalogItem:
            CatalogDetailPage(store: catalog, id: catalogItem ?? "", library: library, back: { page = .getFirmware },
                              delete: delete) { key in
                player.select(key)
                if player.mode != .core { player.setMode(.core) }
                page = .firmware
            }
        case .midi: midiPage
        case .midiInput: midiInputPage
        case .keyChannel:
            SheetPage("Keys from MIDI", backTitle: "MIDI & audio", back: { page = .midi }) {
                KeyChannelList(channel: Binding(get: { player.midiSettings.keyChannel },
                                                set: { player.midiSettings.keyChannel = $0 }))
            }
        case .midiMode:
            SheetPage("Knob mode", backTitle: "MIDI & audio", back: { midiScroll = "knobs"; page = .midi }) {
                MidiModeList(src: modeSource ?? MidiMapStore.shared.mappings.first { $0.mode != nil }?.src ?? "")
            }
        case .settings: settingsPage
        case .install: InstallFirmwarePage(installer: .shared(for: controller)) { page = .settings }
        case .cart: SendCartPage(sender: .shared(for: controller)) { page = .settings }
        case nil: mainSheet
        }
    }

    private func close() { withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = false } }

    /// the prompt's Install: the sheet opens at the install page
    private func openInstall() {
        page = .install
        withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true }
    }

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
                    SheetList {
                        SheetToggle("Firmware's button names", on: Binding(get: { player.midiSettings.buttonNames },
                                                                         set: { player.midiSettings.buttonNames = $0 }),
                                    divider: false)
                    }
                    .padding(.top, 12)
                    SheetSectionTitle("Theme")
                    ThemeSwatches(store: store) { withAnimation { ui.editorOpen = true } }
                    SheetList {
                        SheetRow("Firmware", value: player.current?.name ?? "–", badge: updates) { page = .firmware }
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

    /// the cores built into the app (Get firmware doesn't list them)
    private var builtIn: [CoreInfo] { player.cores.filter { !$0.imported } }

    /// the firmware here with a newer version to download
    private var updates: Int { catalog.updates(builtIn: builtIn).count }

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
        return { delete(f) }
    }

    /// an imported file deleted (the folder, the App Group's mirror); the selection moves first when it was this one
    private func delete(_ f: ImportedFirmware) {
        if f.error == nil { player.willDelete(f.key) }
        library.delete(f)
        player.catalogChanged()
        if confirmDelete == f.file { confirmDelete = nil }
        if library.files.isEmpty { editingFirmware = false }
    }

    private var firmwarePage: some View {
        let builtIn = player.cores.filter { !$0.imported }
        let imported = player.cores.filter(\.imported)
        let broken = library.files.filter { $0.error != nil }
        let files = library.files
        return SheetPage("Firmware", scrollTo: options.sheetScroll, back: { page = nil }) {
            SheetSectionTitle("Built in", top: 12)
            SheetList {
                ForEach(Array(builtIn.enumerated()), id: \.element.id) { i, c in
                    SheetRow("\(c.name)", value: c.version, divider: i < builtIn.count - 1, chevron: false,
                             check: c.id == player.selected) { player.select(c.id) }
                }
            }
            SheetSectionTitle("Imported")
                .overlay(alignment: .bottomTrailing) {
                    if !files.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                editingFirmware.toggle()
                                confirmDelete = nil
                            }
                        } label: {
                            Text(editingFirmware ? "Done" : "Edit").font(RFMFonts.ui(14, 700))
                                .foregroundStyle(Palette.sheetAccent)
                                .padding(.horizontal, 6).frame(height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(editingFirmware ? "Done deleting" : "Edit imported firmware")
                    }
                }
            SheetList {
                ForEach(imported) { c in
                    if editingFirmware, let f = files.first(where: { $0.key == c.id && $0.error == nil }) {
                        FirmwareDeleteRow(title: c.name, value: c.version, playing: c.id == player.selected,
                                          divider: !broken.isEmpty || c.id != imported.last?.id,
                                          asking: confirmDelete == f.file,
                                          ask: { withAnimation { confirmDelete = f.file } },
                                          cancel: { withAnimation { confirmDelete = nil } },
                                          delete: { withAnimation { delete(f) } })
                    } else {
                        SheetRow("\(c.name)", value: c.version, chevron: false, check: c.id == player.selected) {
                            player.select(c.id)
                        }
                    }
                }
                ForEach(broken) { f in
                    if editingFirmware {
                        FirmwareDeleteRow(title: f.file, value: "can't load", playing: false,
                                          divider: f.file != broken.last?.file,
                                          asking: confirmDelete == f.file,
                                          ask: { withAnimation { confirmDelete = f.file } },
                                          cancel: { withAnimation { confirmDelete = nil } },
                                          delete: { withAnimation { delete(f) } })
                    } else {
                        SheetRow(f.file, value: "can't load", chevron: false) {}
                            .opacity(0.55)
                    }
                }
                if !editingFirmware {
                    SheetRow("Get firmware", badge: updates) { page = .getFirmware }
                    SheetRow("Add firmware…", divider: false) { showImporter = true }
                }
            }
            SheetNote(files.isEmpty
                      ? "Put .rfm1 firmware files in Files › On My \(UIDevice.current.model) › RemoteFM1 › Firmware, or add one here."
                      : editingFirmware
                      ? "Deleting removes the file from this \(UIDevice.current.model) and from the AU instrument. The "
                        + "firmware built into the app can't be deleted. An AU instance playing it keeps playing until "
                        + "its project is opened again; then it plays another version, or another firmware."
                      : "Edit deletes imported firmware. Files › On My \(UIDevice.current.model) › RemoteFM1 › Firmware holds them.")
            ForEach(broken) { f in SheetNote("\(f.file): \(f.error ?? "")", color: .orange) }
            if !library.message.isEmpty { SheetNote(library.message) }
            SheetList {
                SheetRow("About this firmware") { showAbout = true }
                    .disabled(player.current == nil)
                SheetRow("Restart the firmware", chevron: false) { player.powerCycle() }
                SheetRow("Safety copies", value: "\(player.safetyCopies.count)") { page = .safetyCopies }
                    .disabled(player.current == nil)
                ResetFirmwareRow(name: player.current?.name ?? "the firmware", asking: $askReset, divider: false) {
                    Task { await player.resetFlash() }
                }
                .disabled(player.current == nil)
            }
            .id("reset")
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

    /// the selected firmware's safety copies (PLAN.md section 18), Restore asked inline
    private var safetyCopiesPage: some View {
        SheetPage("Safety copies", backTitle: "Firmware", back: { askRestore = nil; page = .firmware }) {
            SheetSectionTitle(player.current.map { "\($0.name) \($0.version)" } ?? "Firmware", top: 12)
            SafetyCopiesList(copies: player.safetyCopies, asking: $askRestore) { s in
                Task { await player.restore(s) }
            }
            SheetNote("A copy of the firmware's memory is kept before an update, a delete, a reset or a restore, and "
                      + "while you play: the last 10 saves and one a day for a week. Restore puts a copy back (the "
                      + "current memory is kept as a copy first).")
            if !player.message.isEmpty { SheetNote(player.message) }
        }
    }

    #if DEBUG
    /// (-safetydemo) made-up copies of the selected firmware's flash, for screenshots
    private func safetyDemo() {
        guard let c = player.current else { return }
        let h = FlashHistory(root: player.history.root, now: { Date().addingTimeInterval(-86400 * 2) })
        let size = max(Int(c.flashSize), 1024)
        h.record(Data(repeating: 1, count: size), firmwareID: c.firmwareID, version: "1.6.0", reason: .rolling)
        let h2 = FlashHistory(root: player.history.root, now: { Date().addingTimeInterval(-86400) })
        h2.record(Data(repeating: 2, count: size), firmwareID: c.firmwareID, version: "1.6.0",
                  reason: .beforeUpdate(from: "1.6.0", to: c.version))
        let h3 = FlashHistory(root: player.history.root, now: { Date().addingTimeInterval(-3600) })
        h3.record(Data(repeating: 3, count: size), firmwareID: c.firmwareID, version: c.version, reason: .beforeReset)
        player.history.record(Data(repeating: 4, count: size), firmwareID: c.firmwareID, version: c.version, reason: .rolling)
    }
    #else
    private func safetyDemo() {}
    #endif

    private var midiPage: some View {
        let m = Binding(get: { player.midiSettings }, set: { player.midiSettings = $0 })
        return SheetPage("MIDI & audio", scrollTo: midiScroll ?? options.sheetScroll, back: { midiScroll = nil; page = nil }) {
            SheetSectionTitle("Audio", top: 12)
            SheetList {
                SheetToggle("Sound", on: Binding(get: { player.audioOn }, set: { player.setAudio($0) }))
                AudioOutputRow(value: AudioRoute.name(player.outputs.isEmpty ? AudioRoute.current : player.outputs),
                               divider: false)
            }
            if let h = AudioRoute.hint(player.outputs) { SheetNote(h) }
            SheetNote(player.audioRunning ? player.audioText + String(format: "; %.1f ms ahead, %u underruns",
                                                                      player.status.latencyMs, player.status.underruns)
                      : "No sound: the firmware runs on a timer.")
            SheetSectionTitle("MIDI")
            SheetList {
                SheetRow("MIDI input", value: MidiInputList.value(midi.input)) { midiScroll = nil; page = .midiInput }
                KeyChannelRows(channel: player.midiSettings.keyChannel, toFirmware: m.keyNotesToFirmware) {
                    midiScroll = nil
                    page = .keyChannel
                }
                SheetStepper("Transpose", value: m.transpose, in: -2...2) { t in
                    t == 0 ? "0" : "\(t > 0 ? "+" : "−")\(abs(t)) oct"
                }
                SheetToggle("Velocity & pressure from my FM-1", on: m.keyTouch)
                SheetRow("Bluetooth MIDI devices") { showBluetooth = true }
                SheetRow("Look for the FM-1 again", divider: false, chevron: false) { controller.rescan() }
            }
            SheetNote("Keys from MIDI: notes on that channel (or any) play the keys, transposed by octaves. Notes on "
                      + "other channels, notes outside the keys, every note when Off, and whatever the learned knobs "
                      + "don't take go to the firmware's MIDI in. Velocity & pressure: the FM-1's keys play at their own "
                      + "velocity and send their pressure to the firmware (RemoteFM1 0.3.1 or later; off: velocity 100).")
            SheetNote("FM-1 link: \(controller.statusText)")
            MidiMapSection(useMap: m.useLearnedMap, names: feed.names.value, pickMode: { src in
                modeSource = src
                page = .midiMode
            }, learn: startLearn).id("knobs")
            SheetSectionTitle("OMX-27").id("omx")
            OmxSection(link: midi.omx)
        }
    }

    /// Learn: the sheet closes, the faceplate picks controls (a MIDI input on: All when it was None)
    private func startLearn() {
        if midi.input.selection == .none { midi.input.selection = .all }
        withAnimation(.easeInOut(duration: 0.28)) { midi.learn.start(ui) }
    }

    private var midiInputPage: some View {
        SheetPage("MIDI input", backTitle: "MIDI & audio", back: { page = .midi }) {
            MidiInputList(input: midi.input).padding(.top, 12)
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
            SheetSectionTitle("FM-1 firmware")
            SheetList {
                InstallFirmwareRow(installer: .shared(for: controller), divider: true) { page = .install }
                SendCartRow(sender: .shared(for: controller)) { page = .cart }
            }
            SheetNote("A DX7 cartridge (.syx) becomes a user bank on RemoteFM1 0.3.0 or later.")
        }
    }
}

/// an imported firmware's row in the Firmware page's Edit: the red minus asks "Delete?" in the row itself
struct FirmwareDeleteRow: View {
    let title: String
    let value: String
    let playing: Bool
    var divider = true
    let asking: Bool
    let ask: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if asking {
                SheetConfirm("Delete \(title)?", action: "Delete", cancel: cancel, confirm: delete)
            } else {
                Button(action: ask) {
                    Image(systemName: "minus.circle.fill").font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, SheetConfirm.red)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(title)")
                Text(title).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText).lineLimit(1)
                Spacer(minLength: 8)
                if playing {
                    Text("playing").font(RFMFonts.ui(12, 600)).foregroundStyle(Palette.sheetAccent)
                }
                Text(value).font(RFMFonts.ui(15, 500)).foregroundStyle(Palette.sheetMuted2).lineLimit(1)
            }
        }
        .padding(.leading, asking ? 16 : 8).padding(.trailing, asking ? 4 : 16)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
    }
}
