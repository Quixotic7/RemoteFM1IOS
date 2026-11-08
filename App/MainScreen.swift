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
// PLAN.md section 18 step 3: a state's … has Share… (a .rfm1state through the share sheet); an opened .rfm1state is
// imported into the library and shown on its firmware's States page (not installed: said, with Get firmware when the
// catalog has it); Documents/States mirrors the library (StateMirror: at launch, on a library change, back in the
// foreground); Settings › Your data: Back up everything (Documents/Backups, then Share… as a zip) and Restore from
// backup… (a folder or .rfm1state files; duplicates skipped). DEBUG -backupdemo: a backup made at launch (screenshots).

import UniformTypeIdentifiers

import QuickLook
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
    var faceFrame: CGSize?                              // (DEBUG) -faceframe 353x284: the faceplate in a box that size (an AU in AUM)
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
    var openReader = false                              // (DEBUG) -openreader: the screen reader
    var openManager = false                             // (DEBUG) -openmanager: the running firmware's web manager
    var safetyDemo = false                              // (DEBUG) -safetydemo: a few made-up safety copies
    var statesDemo = false                              // (DEBUG) -statesdemo: a few made-up states (one of another version)
    var statesSave = false                              // (DEBUG) -statessave: the States page's Save as… field open
    var statesShare: String?                            // (DEBUG) -statesshare <name>: that state's … open (Share…)
    var backupDemo = false                              // (DEBUG) -backupdemo: Back up everything run at launch
    var makeThumbs = false                              // (DEBUG) -makethumbs: each built-in core run ~6 s for its thumbnail
    var displayAlone = false                            // -displayalone: the display alone, full size
    var protector: Bool?                                // -protector on|off: the screen protector put on or taken off
    var peel: Double?                                   // -peel 0.3: the film drawn that far peeled (screenshots)

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
        if let f = value("-faceframe")?.split(separator: "x").compactMap({ Double($0) }), f.count == 2 {
            faceFrame = CGSize(width: f[0], height: f[1])
        }
        if let o = value("-orientation") { landscape = o == "landscape" }
        steps = a.contains("-steps")
        displayAlone = a.contains("-displayalone")
        if let p = value("-protector") { protector = p == "on" }
        peel = value("-peel").flatMap(Double.init)
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
        openManager = a.contains("-openmanager")
        openReader = a.contains("-openreader")
        safetyDemo = a.contains("-safetydemo")
        statesDemo = a.contains("-statesdemo")
        statesSave = a.contains("-statessave")
        statesShare = value("-statesshare")
        backupDemo = a.contains("-backupdemo")
        makeThumbs = a.contains("-makethumbs")
        #endif
    }
}

enum SoundSource: String { case phone, fm1 }
enum AppSheetPage: String {
    case firmware, getFirmware = "getfirmware", catalogItem = "catalogitem", midi, midiInput = "midiinput", settings, install, cart
    case keyChannel = "keychannel", midiMode = "midimode", safetyCopies = "safetycopies"
    case states, transfer, recording
}

struct MainScreen: View {
    let controller: RemoteController
    let player: CorePlayer
    let library: FirmwareLibrary
    let catalog: FirmwareStore
    let midi: AppMidi
    let battery: Battery
    @State private var ui = FaceplateUI()
    @State private var showImporter = false
    @State private var feed: PanelFeed
    @State private var page: AppSheetPage?
    @State private var catalogItem: String?             // the firmware a Get firmware page shows
    @State private var modeSource: String?              // the mapping the Knob mode page shows
    @State private var midiScroll: String?              // where the MIDI & audio page opens (back from Knob mode)
    @AppStorage("firmware.sort") private var firmwareSort = FirmwareListing.Sort.name
    @State private var sidebarOpen = false              // the firmware sidebar (a swipe in from the left edge)
    @State private var editingFirmware = false          // the Firmware page's Edit: a delete control per imported row
    @State private var confirmDelete: String?           // the file (its name) whose row asks "Delete?"
    @State private var askRemoveOld = false             // Remove old versions: asking
    @State private var showDiagnostics = false
    @State private var settingsOpened = Date.distantPast    // (a tap so soon after is the press that opened it)
    @State private var showBluetooth = false
    @State private var chipMenu = false                 // the chip's quick menu: where the firmware runs, Bluetooth
    @State private var showAbout = false
    @State private var cartBack: AppSheetPage = .settings   // where the cartridge page goes back to
    @State private var inputNote = ""                  // (ain1) why the input couldn't be turned on
    @State private var updateNotice: UpdateNotice?      // the launch notice (a newer build, firmware updates)
    @State private var readerOpen = false              // the manager layer shows the screen reader, not the editor
    @State private var showManager = false             // (section 18 step 5) the firmware's own web manager
    @State private var askReset = false                 // Reset firmware… asked inline
    @State private var askRestore: String?              // the safety copy whose row asks "Restore?"
    @State private var source: SoundSource
    @State private var prompter: InstallPrompter
    @State private var launched = false
    @State private var shareItem: ShareItem?            // (section 18 step 3) a file in the share sheet
    @State private var stateNotice = ""                 // an opened .rfm1state: what happened (the States page)
    @State private var stateNeeds: String?              // its firmware, not installed: the catalog's id (Get firmware)
    @State private var stateNeedsVersion: SavedState?   // ... and its own version can be downloaded: Get it and load
    @State private var transfer: TransferFile.Report?   // an opened .rfm1transfer: what came in (the transfer page)
    @State private var transferNote = ""
    @State private var sending = false                  // Send to another device… being made
    @State private var importingBackup = false          // the document picker picks a backup, not firmware
    @State private var backingUp = false
    @State private var backupNote = ""
    @State private var lastBackup: URL?
    @State private var dataBack: AppSheetPage? = .firmware   // where States and Safety copies go back to
    @State private var saveOpen = false                 // Save state…: the States page with its field open
    @State private var recorder: Recorder
    @State private var previewFile: URL?               // a recording or screenshot in Quick Look
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    private static let mirror = StateMirror()
    private static let mirrorQueue = DispatchQueue(label: "rfm1.mirror", qos: .utility)
    @State private var turned = false                  // (-orientation landscape refused: drawn turned, for screenshots)
    private let store = ThemeStore.shared
    private let skins = SkinStore.shared
    private let options = LaunchOptions()

    init(controller: RemoteController, player: CorePlayer, library: FirmwareLibrary, catalog: FirmwareStore, midi: AppMidi,
         battery: Battery) {
        self.controller = controller
        self.player = player
        self.library = library
        self.catalog = catalog
        self.midi = midi
        self.battery = battery
        _feed = State(initialValue: midi.feed)
        _recorder = State(initialValue: Recorder(player: player, feed: midi.feed))
        _prompter = State(initialValue: InstallPrompter(controller: controller, installer: .shared(for: controller)))
        let saved = UserDefaults.standard.string(forKey: "rfm1.source").flatMap(SoundSource.init(rawValue:))
        _source = State(initialValue: LaunchOptions().source ?? saved ?? .fm1)
        if let f = LaunchOptions().peel { ScreenProtector.shared.startFold = f }   // (before the film is first drawn)
    }

    var chip: PanelChip {
        guard source == .fm1 else { return .emulator }
        if controller.lease.heldElsewhere { return .inUse }
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
        // the theme's colour to every edge (landscape: the Dynamic Island's side showed the window's black)
        .background(faceTheme.body.color.ignoresSafeArea())
    }

    /// the image behind the faceplate: the playing firmware's own skin, else the user's background (SkinStore)
    private var skin: Skin? { skins.skin(for: player.mode == .core ? player.current?.id : nil) }
    /// the theme, or the firmware skin's colours
    private var faceTheme: Theme { skin?.theme ?? store.current }

    private var screen: some View {
        let skin = skin
        let theme = skin?.theme ?? store.current
        return ZStack {
            if let f = options.faceFrame {                // (DEBUG) the AU's size in a host
                FaceplateView(feed: feed, ui: ui, theme: theme, chip: chip, skin: skin)
                    .frame(width: f.width, height: f.height)
                    .border(Color.white)
            } else {
                FaceplateView(feed: feed, ui: ui, theme: theme, chip: chip, skin: skin)
                    .equatable()
                    .ignoresSafeArea()
            }
            if !ui.sheetOpen && !ui.editorOpen && !ui.displayAlone {
                VStack(spacing: 10) {
                    Spacer()
                    if !midi.learn.active {
                        if let c = player.wipedCopy {
                            WipedMemoryCard(copy: c, firmware: player.current?.name ?? "The firmware") { restore in
                                Task { _ = await player.answerWiped(restore: restore) }
                            }
                        }
                        InstallPromptView(prompt: prompter.prompt, install: openInstall) { prompter.notNow() }
                    }
                    PerfBanner(player.perfNote)
                }
                .padding(.bottom, 12)
                .animation(.easeInOut(duration: 0.2), value: player.perfNote.isEmpty)
            }
            if chipMenu && !ui.sheetOpen && !ui.editorOpen {
                chipMenuView.zIndex(4)
            }
            if !ui.sheetOpen && !ui.editorOpen && !ui.displayAlone && !midi.learn.active {
                FirmwareSidebar(cores: FirmwareListing.sorted(FirmwareListing.visible(player.cores, selected: player.selected, added: addedDates),
                                                              by: firmwareSort, updated: catalog.updated),
                                selected: player.selected, open: $sidebarOpen,
                                select: { id in
                                    player.select(id)
                                    if player.mode != .core { player.setMode(.core) }
                                },
                                getMore: {
                                    page = .getFirmware
                                    withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true }
                                })
                    .zIndex(1)
                if !sidebarOpen, !showManager, let c = player.current {
                    if ManagerList.editor(for: c.firmwareID, details: catalog.details) != nil {
                        RightEdgeSwipe { readerOpen = false; showManager = true }   // (a swipe in from the right: its editor)
                            .zIndex(1)
                    } else if c.firmwareID == CoreCartTransport.firmwareID {
                        RightEdgeSwipe {                          // (RemoteFM1's editor: its cartridge page)
                            cartBack = .firmware
                            page = .cart
                            withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true }
                        }
                        .zIndex(1)
                    }
                }
            }
            PullDownSheet(open: $ui.sheetOpen) { sheet }
            if ui.editorOpen {
                ThemeEditor(store: store, feed: feed) { withAnimation { ui.editorOpen = false } }
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
            // the firmware's web editor: a layer that slides in from the right (where the swipe that opens it starts)
            // and back out on Done (a full-screen cover rose from the bottom)
            if showManager, let c = player.current,
               let u = readerOpen ? ManagerList.reader : ManagerList.editor(for: c.firmwareID, details: catalog.details) {
                ManagerPage(player: player, url: u, port: ManagerList.port(for: c.firmwareID, name: c.name, details: catalog.details),
                            firmware: c.name, title: readerOpen ? "Screen reader" : nil) { showManager = false; readerOpen = false }
                    .id(u)
                    .transition(.move(edge: .trailing))
                    .zIndex(4)
            }
            if recorder.isRecording && !ui.sheetOpen && !recorder.recordingScreen {   // (not in a screen video)
                RecordingBadge(recorder: recorder).zIndex(5)
            }
            if !ui.sheetOpen {
                SavedCard(recorder: recorder, preview: $previewFile)
                    .animation(.easeOut(duration: 0.2), value: recorder.saved?.id)
                    .zIndex(5)
            }
            // MIDI learn's bar and the toasts (over the sheet; above the perf note when it shows)
            FaceplateOverlay(feed: feed, bottom: !ui.sheetOpen && !ui.editorOpen && !player.perfNote.isEmpty ? 64 : 14,
                             barAtTop: ui.page == .controls && ui.deck == .buttons)
                .zIndex(3)
        }
        .animation(.easeInOut(duration: 0.3), value: showManager)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(ui.displayAlone || recorder.isRecording)
        .onChange(of: player.current?.name, initial: true) { _, n in ui.firmwareName = n }
        .onChange(of: player.current?.firmwareID, initial: true) { _, id in
            CoreCartTransport.running = id == CoreCartTransport.firmwareID && player.mode == .core
        }
        .onChange(of: catalog.checked, initial: true) { FirmwareDetailsShare.save(catalog.details) }   // (the AU's panel)
        .preferredColorScheme(ui.sheetOpen || ui.editorOpen || showManager || theme.body.luminance < 0.3 ? .dark : .light)
        .sheet(isPresented: $showBluetooth) { BluetoothSheet() }
        .quickLookPreview($previewFile)
        .sheet(isPresented: $showAbout) {
            AboutFirmware(info: player.current, onDelete: deleteAction(player.current))
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importingBackup ? [.folder, Self.stateType, Self.transferType] : [FirmwareLibrary.fileType, .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            if importingBackup {
                importingBackup = false
                PickerFolder.restore.remember(urls)
                let xfer = urls.filter { $0.pathExtension.lowercased() == TransferFile.fileExtension }
                if let u = xfer.first { openTransfer(u) }
                let rest = urls.filter { $0.pathExtension.lowercased() != TransferFile.fileExtension }
                if !rest.isEmpty { restore(rest) }
                return
            }
            PickerFolder.firmware.remember(urls)
            var last: ImportedFirmware?
            for u in urls { last = (try? library.importFile(u)) ?? last }
            player.catalogChanged()
            if let f = last, f.error == nil { player.select(f.key) }
        }
        .fileDialogDefaultDirectory(showImporter ? (importingBackup ? PickerFolder.restore : PickerFolder.firmware).url : nil)
        .fullScreenCover(isPresented: $showDiagnostics) {
            DiagnosticsScreen(controller: controller, player: player) { showDiagnostics = false }
        }
        .onAppear(perform: launch)
        .sheet(item: $shareItem) { ActivitySheet(url: $0.url) }
        .onReceive(NotificationCenter.default.publisher(for: StateLibrary.didChange)) { _ in syncMirror() }
        .onChange(of: phase) { _, p in
            if p == .active { syncMirror() }
            if p == .background { Task { await recorder.stop() } }   // (the camera and ReplayKit stop in the background)
        }   // (files put in Documents/States meanwhile)
        .onOpenURL { url in                             // (a .rfm1state: imported, its States page)
            guard url.isFileURL, url.pathExtension.lowercased() == StateFile.fileExtension else { return }
            openState(url)
        }
        .onOpenURL { url in                             // (a .rfm1transfer: everything imported, the transfer page)
            guard url.isFileURL, url.pathExtension.lowercased() == TransferFile.fileExtension else { return }
            openTransfer(url)
        }
        .onOpenURL { url in                             // (an .syx from Files or AirDrop: the cartridge page)
            guard url.isFileURL, url.pathExtension.lowercased() == "syx" else { return }
            CartSender.shared(for: controller).add(url: url)
            page = .cart
            withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true }
        }
        .task { await catalog.refreshIfOlder(than: 86_400) }     // (at launch, at most once a day)
        .task { await checkUpdates() }                            // (the launch notice: a newer build, firmware updates)
        .alert(updateNotice?.title ?? "", isPresented: Binding(get: { updateNotice != nil }, set: { if !$0 { closeNotice() } }),
               presenting: updateNotice) { n in
            if n.newBuild != nil, let u = n.url {
                Button("Open TestFlight") { closeNotice(); UIApplication.shared.open(u) }
            }
            if !n.firmware.isEmpty {
                Button("Get firmware") {
                    closeNotice()
                    page = .getFirmware
                    withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true }
                }
            }
            Button("Close", role: .cancel) { closeNotice() }
        } message: { n in
            Text(n.message(current: Self.appBuild))
        }
        .task { await catalog.loadVersions(maxAge: 86_400) }     // (the release dates: sorting by Recently updated)
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
        skins.observe()
        prompter.start()
        ui.onWord = { openFirmwarePanel() }
        ui.onChip = { withAnimation(.easeOut(duration: 0.15)) { chipMenu = true } }   // (the quick menu under it)
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
        if options.openManager, options.catalogGet == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showManager = true } }
        if options.openReader { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { readerOpen = true; showManager = true } }
        if options.safetyDemo { safetyDemo() }
        if options.statesDemo { statesDemo() }
        syncMirror()
        if options.backupDemo { backUp() }
        if options.makeThumbs { Task { await makeThumbs() } }
        #endif
        if options.themeEditor { ui.editorOpen = true }
        if options.displayAlone { ui.displayAlone = true }
        if let p = options.protector { ScreenProtector.shared.on = p }
        if options.demoMap { midi.demoMap() }
        if options.learn {
            midi.learn.start(ui)
            if let t = options.learnPick { midi.learn.pick(t) }
        }
        if source == .fm1 { controller.appeared() } else if controller.isRunning { controller.stop() }
        if let l = options.landscape, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            // (an iPad's windowing mode refuses it: the faceplate is then drawn turned, for scripts/sim_shots.sh)
            // (@Sendable: iOS calls the handler off the main thread; a main-actor closure here stopped the app)
            let turn = { @MainActor in turned = true }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: l ? .landscapeRight : .portrait)) { @Sendable err in
                RFMShared.log("ui").error("orientation: \(err.localizedDescription, privacy: .public)")
                if l { Task { @MainActor in turn() } }
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
        // (with -openmanager: that firmware played, then its editor)
        if options.openManager, let f {
            player.catalogChanged()
            player.select(f.key)
            try? await Task.sleep(for: .seconds(3))
            showManager = true
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
            if s == .fm1, !controller.isRunning, !controller.lease.heldElsewhere { controller.start() }
            return
        }
        saveView()
        source = s
        UserDefaults.standard.set(s.rawValue, forKey: "rfm1.source")
        withAnimation(.easeInOut(duration: 0.25)) { loadView(s) }
        switch s {
        case .phone: if controller.isRunning { controller.stop() }   // (the emulator: no link)
        case .fm1: if !controller.lease.heldElsewhere { controller.start() }   // (else: Use this FM-1)
        }
    }

    // MARK: the sheet

    @ViewBuilder private var sheet: some View {
        switch page {
        case .firmware: firmwarePage
        case .safetyCopies: safetyCopiesPage
        case .states: statesPage
        case .transfer: transferPage
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
        case .recording:
            RecordingPage(recorder: recorder, back: { page = nil }) { work in closeSheet(then: work) }
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
        case .cart:
            SendCartPage(sender: .shared(for: controller), backTitle: cartBack == .firmware ? "Firmware" : "Settings") {
                page = cartBack
            }
            .onDisappear { CartSender.coreTransport?.close() }
        case nil: mainSheet
        }
    }

    private func close() { withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = false } }

    #if DEBUG
    /// (DEBUG) -makethumbs: each built-in core without a thumbnail run until it has one (screenshots), then the first
    private func makeThumbs() async {
        let start = player.selected
        for c in builtIn where !FirmwareThumbs.shared.exists(c.firmwareID) {
            player.select(c.id)
            for _ in 0..<40 where !FirmwareThumbs.shared.exists(c.firmwareID) {
                midi.feed.poll()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        player.select(start)
    }
    #endif

    /// the status row's firmware name: the sheet opens on the Firmware panel
    private func openFirmwarePanel() {
        page = .firmware
        withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true }
    }

    /// States (Save state…: its field open) or Safety copies, back to `from`
    private func openData(_ p: AppSheetPage, from: AppSheetPage?, saving: Bool = false) {
        dataBack = from
        saveOpen = saving
        page = p
    }

    private var dataBackTitle: String { dataBack == nil ? "Controls" : "Firmware" }

    /// the running firmware's data: Save state…, States, Safety copies, Back up everything, Reset firmware…
    @ViewBuilder private func dataRows(from: AppSheetPage?) -> some View {
        let none = player.current == nil
        SheetList {
            SheetRow("Save state…", chevron: false) { openData(.states, from: from, saving: true) }.disabled(none)
            SheetRow("States", value: "\(player.states.count)") { openData(.states, from: from) }.disabled(none)
            SheetRow("Safety copies", value: "\(player.safetyCopies.count)") { openData(.safetyCopies, from: from) }
                .disabled(none)
            SheetRow(backingUp ? "Backing up…" : "Back up everything", chevron: false) { if !backingUp { backUp() } }
            if let lastBackup {
                SheetRow("Share the backup…", chevron: false) { shareBackup(lastBackup) }
            }
            ResetFirmwareRow(name: player.current?.name ?? "the firmware", asking: $askReset, divider: false) {
                Task { await player.resetFlash() }
            }
            .disabled(none)
        }
        if !backupNote.isEmpty { SheetNote(backupNote) }
    }

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
                    SheetSectionTitle(player.current.map { "\($0.name) \($0.version)" } ?? "Firmware", top: 18)
                        .accessibilityLabel("This firmware")
                    dataRows(from: nil)
                    // (was "Sound source": testers read it as where the sound comes out. This picks where the
                    // firmware runs; where the sound comes out is Audio output, right under it)
                    SheetSectionTitle("Firmware runs on")
                    HStack(spacing: 8) {
                        SourceCard(title: "This \(UIDevice.current.model)", sub: "Emulator, play by touch", selected: source == .phone,
                                   dot: Palette.sheetAccent) { pick(.phone) }
                        SourceCard(title: "My FM-1", sub: fm1Line, selected: source == .fm1,
                                   dot: chip == .inUse ? Palette.sheetAccent : Palette.linkedDot) { pick(.fm1) }
                    }
                    if source == .fm1, chip != .linked { fm1Actions }     // (not linked: claim it, or pair it)
                    if source == .phone {
                        SheetList {
                            AudioOutputRow(value: AudioRoute.name(player.outputs.isEmpty ? AudioRoute.current : player.outputs),
                                           divider: false)
                        }
                        .padding(.top, 10)
                    } else {
                        SheetNote("The FM-1 plays through its own speaker and headphone jack; this \(UIDevice.current.model) is its remote.")
                    }
                    SheetSectionTitle("View · or swipe sideways")
                    ViewTiles(ui: ui)
                    SheetList {
                        SheetToggle("Firmware's button names", on: Binding(get: { player.midiSettings.buttonNames },
                                                                         set: { player.midiSettings.buttonNames = $0 }),
                                    divider: true)
                        SheetToggle("Screen protector", on: Binding(get: { ScreenProtector.shared.on },
                                                                    set: { ScreenProtector.shared.on = $0 }),
                                    divider: false)
                    }
                    .padding(.top, 12)
                    SheetNote("Double-tap the display to see it alone; double-tap again or swipe down to close.")
                    SheetSectionTitle("Theme")
                    ThemeSwatches(store: store) { withAnimation { ui.editorOpen = true } }
                    SheetSectionTitle("Background")
                    SkinSettings(skins: skins)
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

    /// when each imported file came (by SHA-256): of two of the same version, the lists show the later
    private var addedDates: [String: Date] { Dictionary(library.files.map { ($0.sha256, $0.added) }, uniquingKeysWith: max) }

    /// (ain1) a firmware that takes audio in: on/off (the microphone asked on the first turn on), the input to use
    @ViewBuilder private func audioInputSection(_ c: CoreInfo) -> some View {
        let on = AudioInput.isOn(for: c.firmwareID) && AudioInput.granted
        SheetSectionTitle("Audio input", top: 14)
        SheetList {
            SheetToggle("Use audio input", on: Binding(get: { on && player.inputLive }, set: { v in
                Task { inputNote = await player.setAudioInput(v) ?? "" }
            }), divider: on && player.inputLive)
            if on && player.inputLive {
                let inputs = player.audioInputs, now = player.currentInputName
                ForEach(Array(inputs.enumerated()), id: \.element.uid) { i, p in
                    SheetRow(p.name, divider: i < inputs.count - 1, chevron: false, check: p.name == now) {
                        Task { inputNote = await player.setAudioInput(true, port: p.uid) ?? "" }
                    }
                }
            }
        }
        SheetNote(c.audioIn == 2 ? "\(c.name) needs audio in: it plays silence without it."
                  : "\(c.name) can take audio in: the microphone, a headset or an audio interface.")
        if !inputNote.isEmpty { SheetNote(inputNote, color: .orange) }
    }

    /// this app's build (CFBundleVersion)
    static var appBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    /// the launch notice, once per launch (not for launches with options: the screenshots, the tests; -updatenotice
    /// shows it anyway, its dismissal forgotten)
    private func checkUpdates() async {
        let force = ProcessInfo.processInfo.arguments.contains("-updatenotice")
        guard force || ProcessInfo.processInfo.arguments.dropFirst().allSatisfy({ !$0.hasPrefix("-") }) else { return }
        async let latest = UpdateNotice.latest()
        await catalog.refreshIfOlder(than: 86_400)
        // (only RemoteFM1's own firmware: the owner, 2026-11-02; the other firmware's updates stay in Get firmware)
        let ups = catalog.updates(builtIn: builtIn).filter { UpdateNotice.firmwareIDs.contains($0.id) }
            .map { (name: $0.displayName, version: $0.version) }
        guard let n = UpdateNotice.make(build: Self.appBuild, latest: await latest, updates: ups),
              force || !n.dismissed() else { return }
        updateNotice = n
    }

    private func closeNotice() {
        updateNotice?.dismiss()
        updateNotice = nil
    }

    /// the cores built into the app (Get firmware doesn't list them)
    private var builtIn: [CoreInfo] { player.cores.filter { !$0.imported } }

    /// the firmware here with a newer version to download
    private var updates: Int { catalog.updates(builtIn: builtIn).count }

    private var fm1Line: String {
        if controller.lease.heldElsewhere {
            let p = controller.lease
            return p.ownerName.isEmpty ? "In use by another instance" : "In use by \(p.ownerName)"
        }
        switch controller.state {
        case .connected(let ble): return "Remote control · \(ble ? "Bluetooth" : "USB")\(controller.backend.isFake ? " (fake)" : "")"
        case .notFound: return "Not found · pair over Bluetooth"
        default: return "Remote control · Bluetooth"
        }
    }

    /// the chip's quick menu (a tap on the chip; the grabber opens the full sheet): where the firmware runs, the FM-1's
    /// Use this FM-1 when another instance has it, Bluetooth. Any choice or a tap outside closes it.
    private var chipMenuView: some View {
        let done = { withAnimation(.easeOut(duration: 0.15)) { chipMenu = false } }
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { done() }
                .accessibilityLabel("Close").accessibilityAddTraits(.isButton)
            VStack(alignment: .leading, spacing: 0) {
                Text("FIRMWARE RUNS ON").font(RFMFonts.ui(11, 700)).tracking(1.2).foregroundStyle(Palette.sheetMuted)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                SheetRow("This \(UIDevice.current.model)", chevron: false, check: source == .phone) { pick(.phone); done() }
                SheetRow("My FM-1", value: source == .fm1 ? chip.text : nil, chevron: false, check: source == .fm1) { pick(.fm1); done() }
                if source == .fm1, controller.lease.heldElsewhere || (!controller.isRunning && !controller.lease.owner) {
                    SheetRow("Use this FM-1", chevron: false) { controller.start(); done() }
                }
                SheetRow("Bluetooth…", divider: false) { done(); showBluetooth = true }
                Text("RECORDING").font(RFMFonts.ui(11, 700)).tracking(1.2).foregroundStyle(Palette.sheetMuted)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                if recorder.isRecording {
                    SheetRow("Stop recording", chevron: false) { done(); Task { await recorder.stop() } }
                } else {
                    SheetRow("Record", value: recorder.settings.canRecord ? recorder.settings.shortSummary : "nothing on",
                             chevron: false) { done(); Task { await recorder.start() } }
                        .disabled(!recorder.settings.canRecord || recorder.busy)
                }
                SheetRow("Take screenshot", value: recorder.settings.screenshot == .raw ? "FM-1 screen" : "whole screen",
                         chevron: false) { done(); closeSheet { await recorder.screenshot() } }
                SheetRow("Recording settings…", divider: false) {
                    done()
                    page = .recording
                    withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true }
                }
            }
            .frame(width: 290)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.sheetSurface)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10))
            .environment(\.colorScheme, .dark)
            .padding(.leading, 14)
            .padding(.top, 54)
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
        }
    }

    /// the sheet (and the quick menu) closed, then `work` (a screenshot without them in it, a recording started)
    private func closeSheet(then work: @escaping @MainActor () async -> Void) {
        let open = ui.sheetOpen
        withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = false }
        Task {
            try? await Task.sleep(for: .milliseconds(open ? 450 : 200))
            await work()
        }
    }

    /// the FM-1 card's actions: Use this FM-1 (design section 10) and the Bluetooth pairing
    private var fm1Actions: some View {
        HStack(spacing: 8) {
            if controller.lease.heldElsewhere || (!controller.isRunning && !controller.lease.owner) {
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
    /// Remove old versions: every imported file a newer version replaces (the lists hide them), not the one playing
    private func removeOldVersions() {
        for f in library.oldVersions(cores: player.cores, keep: player.selected) { player.willDelete(f.key) }
        library.removeOldVersions(cores: player.cores, keep: player.selected)
        player.catalogChanged()
        askRemoveOld = false
    }

    private func delete(_ f: ImportedFirmware) {
        if f.error == nil { player.willDelete(f.key) }
        library.delete(f)
        player.catalogChanged()
        if confirmDelete == f.file { confirmDelete = nil }
        if library.files.isEmpty { editingFirmware = false }
    }

    private var firmwarePage: some View {
        let shown = FirmwareListing.sorted(FirmwareListing.visible(player.cores, selected: player.selected, added: addedDates),
                                           by: firmwareSort, updated: catalog.updated)
        let builtIn = shown.filter { !$0.imported }
        let imported = shown.filter(\.imported)
        let broken = library.files.filter { $0.error != nil }
        let files = library.files
        return SheetPage(player.current?.name ?? "Firmware", scrollTo: options.sheetScroll, back: { page = nil }) {
            if let c = player.current {
                FirmwareInfoCard(info: FirmwareInfo.lookup(c, details: catalog.details), running: player.running) { u, done in
                    openURL(u) { done($0) }
                }
                .padding(.top, 12)
                SheetNote("\(c.version)\(c.imported ? " · imported" : " · built in")\(player.running ? " · running" : "")")
                if c.isVirtual { fantasyNote(c) }
                if c.audioIn > 0 { audioInputSection(c) }
            }
            SheetSectionTitle("This firmware", top: 12)
            SheetList {
                if let c = player.current, ManagerList.editor(for: c.firmwareID, details: catalog.details) != nil {
                    SheetRow("Open its editor", value: "presets, backups") { readerOpen = false; showManager = true }
                } else if player.current?.firmwareID == CoreCartTransport.firmwareID {
                    SheetRow("Open its editor", value: "DX7 cartridges") { cartBack = .firmware; page = .cart }
                }
                if let c = player.current, ManagerList.hasReader(c.firmwareID, details: catalog.details) {
                    SheetRow("Screen reader", value: "reads the screen out") { readerOpen = true; showManager = true }
                }
                SheetRow("About this firmware") { showAbout = true }
                    .disabled(player.current == nil)
                SheetRow("Restart the firmware", divider: false, chevron: false) { player.powerCycle() }
            }
            dataRows(from: .firmware).padding(.top, 12)
                .id("reset")
            SheetSectionTitle("Sort")
            ChipPicker(FirmwareListing.Sort.allCases.map { ($0, $0.title) }, selected: $firmwareSort)
            SheetSectionTitle("Built in", top: 14)
            FirmwareTileGrid(cores: builtIn, selected: player.selected) { player.select($0) }
                .id("builtin")
            GetMoreButton(count: catalog.list(builtIn: self.builtIn).filter {
                if case .notInstalled = catalog.state($0) { true } else { false }
            }.count, updates: updates) { page = .getFirmware }
                .padding(.top, 14)
                .id("getmore")
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
            if !editingFirmware, !imported.isEmpty {
                FirmwareTileGrid(cores: imported, selected: player.selected, select: { player.select($0) },
                                 delete: { c in deleteAction(c).map { d in { withAnimation { d() } } } })
                    .padding(.bottom, 10)
            }
            SheetList {
                ForEach(editingFirmware ? imported : []) { c in
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
                    SheetRow("Add firmware file…", divider: false) { showImporter = true }
                }
            }
            // (each update keeps the version before it, so a firmware's way back: these pile up)
            let old = library.oldVersions(cores: player.cores, keep: player.selected)
            if !editingFirmware, !old.isEmpty {
                if askRemoveOld {
                    SheetConfirm("Remove \(old.count) older version\(old.count == 1 ? "" : "s")?",
                                 action: "Remove", cancel: { withAnimation { askRemoveOld = false } },
                                 confirm: { withAnimation { removeOldVersions() } })
                        .padding(.top, 10)
                } else {
                    SheetButton("Remove old versions (\(old.count))") { withAnimation { askRemoveOld = true } }
                        .padding(.top, 10)
                }
                SheetNote("Each update keeps the version before it. This removes those, not the one playing; Get "
                          + "firmware has them again if you need one.")
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
            if player.current?.imported == true, player.running {
                Live { SheetNote(player.status.coreWakes == 0 ? "Runs in the WebAssembly interpreter (no sound yet)."
                          : String(format: "Runs in the WebAssembly interpreter: %u%% of the audio time on the core thread, "
                                   + "%u underruns.", player.status.coreLoadPct, player.status.underruns)) }
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
    /// (Fantasy CFW) what it does in the RemoteFM1 folder and where that is; a prompt when its code folder is empty
    @ViewBuilder private func fantasyNote(_ c: CoreInfo) -> some View {
        let id = c.firmwareID, where_ = "Files › On My \(UIDevice.current.model) › RemoteFM1 › RemoteFM1"
        let empty = c.folders["code"] != nil && RemoteFM1Folder.codeFiles(id) == 0
        if c.folders.isEmpty {
            SheetNote("A Fantasy CFW: it runs only in RemoteFM1, never on an FM-1.")
        } else {
            SheetNote("A Fantasy CFW: it runs only in RemoteFM1, never on an FM-1. It \(FantasyTag.folders(c.folders)) in "
                      + "the RemoteFM1 folder (\(where_)): audio/ for everyone, code/\(id)/ and data/\(id)/ for it.")
                .task(id: id) { RemoteFM1Folder.prepare(id) }
            if empty {
                SheetNote("Nothing in code/\(id)/ yet. Put its files there with the Files app"
                          + (id == "ripple" ? " (droplets/*.lua)" : "") + ", then come back to RemoteFM1.", color: .orange)
            }
        }
    }

    private var safetyCopiesPage: some View {
        SheetPage("Safety copies", backTitle: dataBackTitle, back: { askRestore = nil; page = dataBack }) {
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

    /// the selected firmware's named states (PLAN.md section 18 step 2): the App Group's library, the AU's too
    private var statesPage: some View {
        let c = player.current
        return SheetPage("States", backTitle: dataBackTitle, back: { page = dataBack }) {
            if !stateNotice.isEmpty {
                SheetNote(stateNotice, color: .orange).padding(.top, 12)
                HStack(spacing: 8) {
                    if let s = stateNeedsVersion {
                        SheetButton("Get \(s.version) and load", accent: true) {
                            stateNeedsVersion = nil
                            stateNeeds = nil
                            Task { stateNotice = await loadAnywhere(s) }
                        }
                    }
                    if let id = stateNeeds {
                        SheetButton("Get firmware") { catalogItem = id; stateNeeds = nil; stateNeedsVersion = nil; page = .catalogItem }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
            SheetSectionTitle(c.map { "\($0.name) \($0.version)" } ?? "Firmware", top: 12)
            StatesList(firmware: c?.name ?? "", version: c?.version ?? "", states: player.states,
                       startSaving: options.statesSave || saveOpen, startEditing: options.statesShare,
                       save: { n in Task { await player.saveState(name: n) } },
                       load: { s in Task { await player.loadState(s) } },
                       rename: { s, n in _ = try? player.library.rename(s, to: n) },
                       delete: { s in player.library.delete(s) },
                       share: { s in share(s) },
                       otherVersion: { s in otherVersion(s) })
            SheetNote("A state is the firmware's memory (its patches, banks, sequences) with MASTER, the octave and the "
                      + "keys' touch, under a name. The app and every AU instance share them: a state saved here loads "
                      + "in the AU instrument, and the other way. Loading keeps a safety copy of the current memory first. "
                      + "Each state is also a .rfm1state file in Files › RemoteFM1 › States; Share… sends one.")
            SheetList {
                SheetRow("Safety copies", value: "\(player.safetyCopies.count)", divider: false) { page = .safetyCopies; saveOpen = false }
            }
            .padding(.top, 12)
            if !player.message.isEmpty { SheetNote(player.message) }
        }
        .task { await catalog.loadVersions() }
    }

    // MARK: older versions, the transfer file

    /// a state made with another version: switch to its version (here), or get it (on GitHub), then load
    private func otherVersion(_ s: SavedState) -> (title: String, action: () -> Void)? {
        let go = { Task { stateNotice = await loadAnywhere(s) } }
        if player.cores.contains(where: { $0.firmwareID == s.firmwareID && $0.version == s.version }) {
            return ("Switch to \(s.version) and load", { _ = go() })
        }
        if catalog.version(s.firmwareID, s.version) != nil { return ("Get \(s.version) and load", { _ = go() }) }
        return nil
    }

    /// what Load does for a state of the transfer page
    private func loadLabel(_ s: SavedState) -> String {
        if player.cores.contains(where: { $0.firmwareID == s.firmwareID && $0.version == s.version }) { return "Load" }
        if catalog.version(s.firmwareID, s.version) != nil { return "Get \(s.version) and load" }
        if let c = player.cores.first(where: { $0.firmwareID == s.firmwareID }) { return "Load into \(c.version)" }
        return "Not here"
    }

    /// s loaded into its own version of the firmware: the one here, else downloaded (GitHub's releases), else the
    /// firmware's other version here (the version note says so). Returns what happened
    private func loadAnywhere(_ s: SavedState) async -> String {
        let name = s.firmwareName.isEmpty ? s.firmwareID : s.firmwareName
        if player.mode != .core { player.setMode(.core) }
        if let c = player.cores.first(where: { $0.firmwareID == s.firmwareID && $0.version == s.version }) {
            player.select(c.id)
        } else {
            await catalog.loadVersions()
            if let e = catalog.version(s.firmwareID, s.version) {
                guard let f = await catalog.install(e) else {
                    return catalog.failure.isEmpty ? catalog.message : "\(name) \(s.version): \(catalog.failure)"
                }
                player.catalogChanged()
                player.select(f.key)
            } else if let c = player.cores.first(where: { $0.firmwareID == s.firmwareID && $0.id == player.selected })
                        ?? player.cores.first(where: { $0.firmwareID == s.firmwareID }) {
                player.select(c.id)
            } else {
                return "\(name) \(s.version) isn't on this device or in Get firmware."
            }
        }
        await player.loadState(s)
        return player.message
    }

    /// Send to another device…: one .rfm1transfer (every state, each firmware's current memory, their firmware
    /// files) to the share sheet
    private func sendTransfer() {
        sending = true
        backupNote = ""
        let lib = player.library
        let files = library.files.map { ($0, library.folder.appendingPathComponent($0.file)) }
        let device = UIDevice.current.model
        let app = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")"
        Task {
            let cur = await player.currentFlashes()
            let r = await Task.detached { () -> Result<URL, Error> in
                Result {
                    let data = TransferFile.make(library: lib, current: cur, files: files, device: device, app: app)
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID().uuidString.prefix(8))")
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let day = Date().formatted(.iso8601.year().month().day())
                    let u = dir.appendingPathComponent("RemoteFM1 from \(device) \(day).\(TransferFile.fileExtension)")
                    try data.write(to: u, options: .atomic)
                    return u
                }
            }.value
            sending = false
            switch r {
            case .success(let u): shareItem = ShareItem(url: u)
            case .failure(let e): backupNote = "Can't make the file: \(e.localizedDescription)"
            }
        }
    }

    /// a .rfm1transfer opened: its firmware files and states imported, then the transfer page
    private func openTransfer(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        transferNote = ""
        do {
            let d = try TransferFile.decode(try Data(contentsOf: url))
            let r = TransferFile.importInto(d, states: player.library, firmware: library) {
                player.cores.map { ($0.firmwareID, $0.version) }
            }
            player.catalogChanged()
            transfer = r
        } catch {
            transfer = nil
            transferNote = "\(url.lastPathComponent) wasn't read: \(error.localizedDescription)"
        }
        page = .transfer
        withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true }
    }

    private var transferPage: some View {
        SheetPage("From another device", back: { page = nil }) {
            if let r = transfer {
                SheetNote(r.text).padding(.top, 12)
                if !r.current.isEmpty {
                    SheetSectionTitle("Its current memory")
                    SheetList {
                        ForEach(Array(r.current.enumerated()), id: \.element.id) { i, s in
                            SheetRow("\(s.firmwareName) \(s.version)", value: loadLabel(s), divider: i < r.current.count - 1,
                                     chevron: false) {
                                Task { transferNote = await loadAnywhere(s) }
                            }
                            .disabled(catalog.progress != nil)
                        }
                    }
                    SheetNote("Load makes the firmware here play what it played on the other device. The memory here "
                              + "is kept as a safety copy first. Every state that came in is in its firmware's States page.")
                }
                if !r.missing.isEmpty {
                    SheetNote("Not on this \(UIDevice.current.model): \(r.missing.joined(separator: ", ")). Get it in Get "
                              + "firmware, then load its states from its States page.")
                }
            }
            if let p = catalog.progress { SheetNote("Getting \(p.id)… \(CatalogText.progress(p))") }
            if !transferNote.isEmpty { SheetNote(transferNote) }
        }
        .task { await catalog.loadVersions() }
    }

    #if DEBUG
    /// (-statesdemo) made-up states of the selected firmware, for screenshots
    private func statesDemo() {
        guard let c = player.current else { return }
        let size = max(Int(c.flashSize), 1024)
        let lib = player.library
        guard lib.list(c.firmwareID).isEmpty else { return }
        for (i, (n, v, ago)) in [("Pads for the bridge", "1.0.0", 86400.0 * 9), ("Live set, Friday", c.version, 86400 * 2),
                                  ("Bass sketches", c.version, 3600)].enumerated() {
            let l = StateLibrary(root: lib.root, now: { Date().addingTimeInterval(-ago) })
            _ = try? l.save(name: n, firmwareID: c.firmwareID, firmwareName: c.name, kind: c.kind, version: v,
                            flash: Data(repeating: UInt8(i + 1), count: size), master: 800, origin: i == 1 ? "au" : "app")
        }
    }

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
    private func statesDemo() {}
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
            SheetList {
                SheetToggle("Play alongside other apps", on: Binding(get: { player.mixWithOthers }, set: { player.mixWithOthers = $0 }),
                            divider: false)
            }
            .padding(.top, 14)
            SheetNote("Play alongside other apps: a camera or music app no longer stops the sound, so the firmware keeps "
                      + "playing and your FM-1 stays linked. The lock screen's play controls don't show while it's on.")
            Live {
                SheetNote(player.audioRunning ? player.audioText + String(format: "; %.1f ms ahead, %u underruns",
                                                                          player.status.latencyMs, player.status.underruns)
                          : "No sound: the firmware runs on a timer.")
            }
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
            SheetList {
                SheetToggle("Clock and start/stop", on: Binding(get: { midi.input.clockIn }, set: { midi.input.clockIn = $0 }),
                            divider: false)
            }
            .padding(.top, 14)
            SheetNote("A controller's or drum machine's MIDI clock, start, stop and song position go to the firmware, "
                      + "so it follows that tempo and transport.")
        }
    }

    /// (the battery) what the app does when you leave it or lock the screen: one row a choice, a check on the chosen
    private var backgroundSection: some View {
        let modes = BackgroundMode.allCases, now = battery.policy.mode
        return VStack(alignment: .leading, spacing: 0) {
            SheetSectionTitle("When you leave the app", top: 12).id("background")
            SheetList {
                ForEach(modes, id: \.self) { m in
                    SheetRow(m.title, chevron: false, check: m == now) { battery.policy.mode = m }
                }
                SheetToggle("Stop after 10 quiet minutes", on: Binding(get: { battery.policy.idleStop },
                                                                       set: { battery.policy.idleStop = $0 }), divider: false)
            }
            SheetNote(now.detail + " Quiet: no key, knob, MIDI or sound. Pause on the lock screen stops it too; it saves "
                      + "first and plays again when you come back."
                      + (battery.lastStop.isEmpty ? "" : " Last stopped: \(battery.lastStop)."))
        }
    }

    private var settingsPage: some View {
        SheetPage("Settings", scrollTo: options.sheetScroll, back: { page = nil }) {
            Color.clear.frame(height: 0).onAppear { settingsOpened = Date() }
            backgroundSection
            SheetSectionTitle("Keys")
            SheetList {
                SheetToggle("Step numbers on the keys", on: $ui.stepNumbers, divider: false)
            }
            SheetNote("Shows 1–16 on the lower keys, for a firmware in a step mode.")
            SheetSectionTitle("Diagnostics")
            SheetList {
                // (not in the first half second: a slow tap on Settings landed here; the AU test is inside Diagnostics)
                SheetRow("Diagnostics", divider: false) {
                    if Date().timeIntervalSince(settingsOpened) > 0.5 { showDiagnostics = true }
                }
            }
            SheetNote("Diagnostics has the link, the core, the unit's HELLO_R, the test pattern mode and the AU test.")
            SheetSectionTitle("FM-1 firmware")
            SheetList {
                InstallFirmwareRow(installer: .shared(for: controller), divider: true) { page = .install }
                SendCartRow(sender: .shared(for: controller)) { cartBack = .settings; page = .cart }
            }
            SheetNote("A DX7 cartridge (.syx) becomes a user bank on RemoteFM1 0.3.0 or later.")
            SheetSectionTitle("Your data").id("data")
            SheetList {
                SheetRow(backingUp ? "Backing up…" : "Back up everything", chevron: false) { if !backingUp { backUp() } }
                if let lastBackup {
                    SheetRow("Share the backup…", chevron: false) { shareBackup(lastBackup) }
                }
                SheetRow("Restore from backup…", chevron: false) {
                    importingBackup = true
                    showImporter = true
                }
                SheetRow(sending ? "Making the file…" : "Send to another device…", divider: false, chevron: false) {
                    if !sending { sendTransfer() }
                }
            }
            SheetNote(backupNote.isEmpty
                      ? "Back up everything writes every state, each firmware's current memory and the newest safety "
                        + "copies into Files › RemoteFM1 › Backups. Restore adds a backup's states to the library; "
                        + "nothing is overwritten."
                      : backupNote)
            SheetNote("Send to another device makes one file with every state, each firmware's current memory and "
                      + "the firmware files they need. AirDrop it or save it to Files, then open it on the other "
                      + "device: everything is added there, and its current memory loads with one tap.")
        }
    }

    // MARK: files and backups (section 18 step 3)

    static let stateType = UTType(exportedAs: StateFile.typeIdentifier, conformingTo: .data)
    static let transferType = UTType(exportedAs: TransferFile.typeIdentifier, conformingTo: .data)

    /// Documents/States made like the library (off the main thread; a file the user added there: imported)
    private func syncMirror() {
        let lib = player.library
        Self.mirrorQueue.async {
            let r = StateMirror(root: Self.mirror.root, library: lib).sync()
            if r.imported > 0 || !r.failed.isEmpty {
                RFMShared.log("states").info("mirror: \(r.imported) imported, \(r.failed.count) unreadable")
            }
        }
    }

    private func share(_ s: SavedState) {
        do { shareItem = ShareItem(url: try StateFile.temporaryFile(s, library: player.library)) }
        catch { stateNotice = "Can't share \"\(s.name)\": \(error.localizedDescription)" }
    }

    /// a .rfm1state opened (Files, AirDrop, Mail): into the library, then its firmware's States page
    private func openState(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        stateNeeds = nil
        stateNeedsVersion = nil
        do {
            let i = try player.library.importFile(url)
            let s = i.state
            let what = i.duplicate ? "\"\(s.name)\" is already in the library." : "Imported \"\(s.name)\"."
            if let c = player.cores.first(where: { $0.firmwareID == s.firmwareID && $0.id == player.selected })
                ?? player.cores.first(where: { $0.firmwareID == s.firmwareID }) {
                if c.id != player.selected { player.select(c.id) }
                stateNotice = what + " Load it below."
            } else {
                let name = s.firmwareName.isEmpty ? s.firmwareID : s.firmwareName
                let a = catalog.available.first { $0.id == s.firmwareID }
                stateNeeds = a?.id
                stateNeedsVersion = catalog.version(s.firmwareID, s.version) != nil ? s : nil
                stateNotice = what + " It's a state of \(name) \(s.version), which isn't installed"
                    + (a == nil ? ": add that firmware to load it." : ": get it, then load the state from its States page.")
            }
        } catch {
            stateNotice = "\(url.lastPathComponent) wasn't imported: \(error.localizedDescription)"
        }
        page = .states
        withAnimation(.easeInOut(duration: 0.28)) { ui.sheetOpen = true }
    }

    private func backUp() {
        backingUp = true
        backupNote = ""
        let lib = player.library, hist = player.history
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        Task {
            let cur = await player.currentFlashes()
            let r = await Task.detached { Result { try Backup.write(library: lib, history: hist, current: cur, app: app) } }.value
            backingUp = false
            switch r {
            case .success(let (dir, m)):
                lastBackup = dir
                backupNote = "Backed up \(m.states.count) state\(m.states.count == 1 ? "" : "s"), \(m.current.count) "
                    + "firmware memor\(m.current.count == 1 ? "y" : "ies") and \(m.safetyCopies.count) safety "
                    + "cop\(m.safetyCopies.count == 1 ? "y" : "ies") into Files › RemoteFM1 › Backups › \(dir.lastPathComponent)."
            case .failure(let e):
                backupNote = "The backup failed: \(e.localizedDescription)"
            }
        }
    }

    private func shareBackup(_ dir: URL) {
        do { shareItem = ShareItem(url: try Backup.zip(dir)) }
        catch { backupNote = "Can't zip the backup: \(error.localizedDescription)" }
    }

    private func restore(_ urls: [URL]) {
        var all = Backup.RestoreReport()
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            let r = Backup.restore(from: u, into: player.library)
            if scoped { u.stopAccessingSecurityScopedResource() }
            all.imported += r.imported; all.duplicates += r.duplicates; all.failed += r.failed
        }
        let ids = Set(player.cores.map(\.firmwareID))
        let missing = Set(all.imported.filter { !ids.contains($0.firmwareID) }.map { $0.firmwareName.isEmpty ? $0.firmwareID : $0.firmwareName })
        backupNote = all.text + (missing.isEmpty ? "" : " Not installed: \(missing.sorted().joined(separator: ", ")) (its states wait in the library).")
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

/// (section 18 step 3) a file for the share sheet
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// the system share sheet with one file (AirDrop, Mail, Save to Files, ...)
struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// a small view that reads fast-changing state (the player's status) in its own body, so only it redraws, not the
/// page around it (SwiftUI's observation tracks what a body reads)
struct Live<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}
