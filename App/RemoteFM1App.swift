// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RemoteFM1 for iPhone and iPad: an FM-1 running RemoteFM1 firmware as the panel of a firmware core played on the
// phone (M3), or of M1's test pattern. Launch arguments: -fake runs against libremotefm1's fake unit in the app,
// -fakeble the fake over Bluetooth. The simulator uses the fake unless launched with -device (its CoreMIDI may see the
// Mac's MIDI devices). -autest (M2): only the AU test (AUTestView), run at launch; the FM-1 link is never created.
// -coretest (M3): the core test (CoreTest.swift) runs on the normal screen; -core <id> picks the firmware.
// M4: the app's link shares the FM-1 with the AU's instances through the lease (PLAN.md section 4), under its own
// UUID (UserDefaults rfm1.instance). -aucoretest (M4): only the AU core test (AUCoreTest.swift), run at launch.
// The screen is the on-screen FM-1 (MainScreen); its launch arguments (-view, -deck, -knobs, -source, -sheet,
// -sheetpage, -themeeditor, -theme, -orientation, -steps) are in MainScreen.swift's LaunchOptions.
// M7: imported firmware (RFMKit's Firmware.swift): Documents/Firmware, synced into the App Group at launch, on
// returning to the foreground and after an import or a delete; an opened .rfm1 (Files, Safari, AirDrop) is copied in
// and selected. The selection is saved as a CoreRef (UserDefaults rfm1.coreRef; rfm1.core, the key, as before).
// M8: the MIDI side (AppMidi: controllers, MIDI learn, the OMX-27) is made here with the player and lives as long as
// the app.
// Get firmware: the FirmwareStore (RFMKit) is made here too; an install tells the player the catalog changed, and an
// update that replaces the selected file selects the new one first.

import RFMKit
import SwiftUI
import UIKit

@main
struct RemoteFM1App: App {
    @State private var controller: RemoteController?
    @State private var player: CorePlayer?
    @State private var library: FirmwareLibrary?
    @State private var store: FirmwareStore?
    @State private var midi: AppMidi?
    @Environment(\.scenePhase) private var phase
    private let coreTest: Bool

    init() {
        let args = ProcessInfo.processInfo.arguments
        coreTest = args.contains("-coretest")
        RFMFonts.register()
        DispatchQueue.global(qos: .utility).async { CoreSlotMirror.syncOnMac() }   // (a Mac only: the AU's way to the cores)
        guard !args.contains("-autest") && !args.contains("-aucoretest") else { return }
        let backend = Self.backend(args)
        let d = UserDefaults.standard
        let id = d.string(forKey: "rfm1.instance").flatMap(UUID.init(uuidString:)) ?? UUID()
        d.set(id.uuidString, forKey: "rfm1.instance")
        let c = RemoteController(backend: backend, demoInput: backend.isFake, lease: PanelSession.Config(),
                                 identity: id, ownerName: "RemoteFM1 app")
        _controller = State(initialValue: c)
        let lib = FirmwareLibrary()
        lib.sync()                              // (before the player: the catalog lists the imported files)
        _library = State(initialValue: lib)
        var core: String? = nil                 // (-core <key or id>; else the saved choice, resolved by CoreRef)
        if let i = args.firstIndex(of: "-core"), i + 1 < args.count {
            core = Self.coreArg(args[i + 1], lib)
        }
        let ref = CoreRef(d.dictionary(forKey: "rfm1.coreRef"))
            ?? d.string(forKey: "rfm1.core").map { CoreRef(id: $0) }   // (a choice saved before M7)
        let p = CorePlayer(link: c, selected: core, ref: core == nil ? ref : nil)
        _player = State(initialValue: p)
        let st = FirmwareStore(library: lib)
        st.didChange = { p.catalogChanged() }
        st.willReplace = { old, new in            // (section 18: a safety copy of the flash first; one file per id)
            if let o = old.first { p.safetyCopy(of: o.key, .beforeUpdate(from: o.version, to: new.version)) }
            if old.contains(where: { $0.key == p.selected }) { p.select(new.key) }   // (the flash is shared by id)
        }
        _store = State(initialValue: st)
        _midi = State(initialValue: AppMidi(player: p))
        if !coreTest {                          // (the last choices; the core test sets its own)
            p.setAudio(d.object(forKey: "rfm1.audio") as? Bool ?? true)
            if (d.string(forKey: "rfm1.mode") ?? "core") == "core" { p.setMode(.core) }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let controller, let player, let library, let store, let midi {
                    MainScreen(controller: controller, player: player, library: library, catalog: store, midi: midi)
                        .task { if coreTest { await CoreTest(controller: controller, player: player).run() } }
                        .onChange(of: player.mode) { _, m in
                            UserDefaults.standard.set(m.rawValue, forKey: "rfm1.mode")
                            controller.setOwnerName(Self.ownerName(player))
                        }
                        .onChange(of: player.selected) { _, id in
                            UserDefaults.standard.set(id, forKey: "rfm1.core")
                            if let r = player.selectedRef { UserDefaults.standard.set(r.dict, forKey: "rfm1.coreRef") }
                            controller.setOwnerName(Self.ownerName(player))
                        }
                        .onOpenURL { url in Self.open(url, library, player) }
                        .onAppear { controller.setOwnerName(Self.ownerName(player)) }
                        .onChange(of: player.audioOn) { _, on in UserDefaults.standard.set(on, forKey: "rfm1.audio") }
                } else if ProcessInfo.processInfo.arguments.contains("-aucoretest") {
                    AUCoreTestView(host: AUCoreTestHost()).preferredColorScheme(.dark)
                } else {
                    AUTestView(host: AUTestHost(auto: true)).preferredColorScheme(.dark)
                }
            }
        }
        .onChange(of: phase) { _, p in
            if p == .background, let player { Self.saveInBackground(player) }
            if p == .active, let library, let player {          // (files added in the Files app meanwhile)
                library.sync()
                player.catalogChanged()
            }
        }
    }

    /// an .rfm1 opened from Files, Safari's downloads or AirDrop: copied into Documents/Firmware and selected
    @MainActor static func open(_ url: URL, _ library: FirmwareLibrary, _ player: CorePlayer) {
        guard url.isFileURL, url.pathExtension.lowercased() != "syx" else { return }   // (.syx: MainScreen)
        do {
            let f = try library.importFile(url)
            player.catalogChanged()
            if f.error == nil {
                player.select(f.key)
                if player.mode != .core { player.setMode(.core) }
            }
        } catch {
            RFMShared.log("firmware").error("open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// -core's argument: a catalog key, a built-in core's id, or an imported firmware's id ("rfm1:felucca": the
    /// imported Felucca)
    @MainActor static func coreArg(_ a: String, _ lib: FirmwareLibrary) -> String {
        guard a.hasPrefix(FirmwareCatalog.keyPrefix) else { return a }
        let rest = String(a.dropFirst(FirmwareCatalog.keyPrefix.count))
        return lib.files.first { $0.error == nil && ($0.coreID == rest || $0.sha256 == rest) }?.key ?? a
    }

    /// the flash saved as the app leaves the foreground (the core keeps playing if the sound is on)
    @MainActor static func saveInBackground(_ player: CorePlayer) {
        let app = UIApplication.shared
        let task = TaskBox()
        task.id = app.beginBackgroundTask(withName: "flash") { task.end() }
        Task { @MainActor in
            await player.didEnterBackground()
            task.end()
        }
    }

    /// the lease's owner name: "RemoteFM1 app / <core>" (or the test pattern)
    @MainActor static func ownerName(_ p: CorePlayer) -> String {
        "RemoteFM1 app / " + (p.mode == .core ? (p.current?.name ?? p.selected) : "test pattern")
    }

    static func backend(_ args: [String]) -> Backend {
        if args.contains("-fakeble") { return .fake(bluetooth: true) }
        if args.contains("-fake") { return .fake(bluetooth: false) }
        #if targetEnvironment(simulator)
        if !args.contains("-device") { return .fake(bluetooth: false) }
        #endif
        return .device
    }
}

@MainActor final class TaskBox: @unchecked Sendable {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        id = .invalid
    }
}
