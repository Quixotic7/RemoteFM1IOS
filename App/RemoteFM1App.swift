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

import RFMKit
import SwiftUI
import UIKit

@main
struct RemoteFM1App: App {
    @State private var controller: RemoteController?
    @State private var player: CorePlayer?
    @Environment(\.scenePhase) private var phase
    private let coreTest: Bool

    init() {
        let args = ProcessInfo.processInfo.arguments
        coreTest = args.contains("-coretest")
        RFMFonts.register()
        guard !args.contains("-autest") && !args.contains("-aucoretest") else { return }
        let backend = Self.backend(args)
        let d = UserDefaults.standard
        let id = d.string(forKey: "rfm1.instance").flatMap(UUID.init(uuidString:)) ?? UUID()
        d.set(id.uuidString, forKey: "rfm1.instance")
        let c = RemoteController(backend: backend, demoInput: backend.isFake, lease: PanelSession.Config(),
                                 identity: id, ownerName: "RemoteFM1 app")
        _controller = State(initialValue: c)
        var core = d.string(forKey: "rfm1.core")      // (nil, or a core this build lacks: CorePlayer picks one)
        if let i = args.firstIndex(of: "-core"), i + 1 < args.count { core = args[i + 1] }
        let p = CorePlayer(link: c, selected: core)
        _player = State(initialValue: p)
        if !coreTest {                          // (the last choices; the core test sets its own)
            p.setAudio(d.object(forKey: "rfm1.audio") as? Bool ?? true)
            if (d.string(forKey: "rfm1.mode") ?? "core") == "core" { p.setMode(.core) }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let controller, let player {
                    MainScreen(controller: controller, player: player)
                        .task { if coreTest { await CoreTest(controller: controller, player: player).run() } }
                        .onChange(of: player.mode) { _, m in
                            UserDefaults.standard.set(m.rawValue, forKey: "rfm1.mode")
                            controller.setOwnerName(Self.ownerName(player))
                        }
                        .onChange(of: player.selected) { _, id in
                            UserDefaults.standard.set(id, forKey: "rfm1.core")
                            controller.setOwnerName(Self.ownerName(player))
                        }
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
        }
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
