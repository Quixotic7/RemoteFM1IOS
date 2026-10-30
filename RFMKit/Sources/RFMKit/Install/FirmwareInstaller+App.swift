// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The app's one installer (it outlives the page, so an install keeps going if the sheet closes), its transport and its
// keep-awake. On an iPhone or iPad with the device backend: CoreMIDI, USB only. Otherwise (the simulator, the fake
// backend): FM1Kit's SimulatedFM1 running RemoteFM1 0.2.2, so nothing is ever sent to a real FM-1 from there.
// DEBUG: -installdemo check|writing|finished|cutoff runs the page by itself on the SimulatedFM1 (screenshots):
// check stops at the confirmation, writing and finished install (slower writes, so a shot catches the bar), cutoff
// pulls the simulated cable at 45 % and stops at "Finish the install".

import FM1Kit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension FirmwareInstaller {
    private static var appInstaller: FirmwareInstaller?

    /// the app's installer, made on first use for the app's link
    public static func shared(for controller: RemoteController) -> FirmwareInstaller {
        if let i = appInstaller { return i }
        var demo: String?
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-installdemo") { demo = i + 1 < args.count ? args[i + 1] : "check" }
        #endif
        let releases = RemoteFM1Releases()
        let packages = FirmwarePackages()
        var made: FirmwareInstaller?
        #if os(iOS) && !targetEnvironment(simulator)
        if controller.backend == .device && demo == nil {
            made = FirmwareInstaller(releases: releases, packages: packages, panel: controller,
                                     transport: InstallTransport.usb(), simulated: false, timing: .standard,
                                     awake: .system())
        }
        #endif
        if made == nil {
            var o = SimulatedFM1.Options()
            o.installedIdentity = FM1Identity(text: RemoteFM1Version(0, 2, 2).identity)!
            o.serialNumber = nil                    // (felucca-bsp's USB device reports none)
            o.checksAfterWriting = true             // (felucca-bsp's loader reads the image again)
            o.rebootDuration = .milliseconds(1200)
            if demo != nil { o.requestInterval = .milliseconds(9) }
            if demo == "cutoff" { o.unplugDuringWriteAt = 0.45 }
            made = FirmwareInstaller(releases: releases, packages: packages, panel: controller,
                                     transport: InstallTransport.simulated(o), simulated: true,
                                     timing: simulatedTiming, awake: .system())
        }
        let installer = made!
        installer.demoStep = demo
        appInstaller = installer
        return installer
    }

    /// shorter waits for the SimulatedFM1 (it restarts in about a second)
    static var simulatedTiming: UpdaterTiming {
        var t = UpdaterTiming()
        t.loaderBoot = .milliseconds(800)
        t.firmwareBoot = .milliseconds(800)
        t.scanInterval = .milliseconds(250)
        t.loaderSearch = .seconds(10)
        t.returnSearch = .seconds(10)
        return t
    }

    /// the page appeared: the list refreshed (at most every 10 minutes); DEBUG's demo runs once
    public func pageAppeared() async {
        await releases.refreshIfStale()
        guard let step = demoStep else { return }
        demoStep = nil
        await check()
        guard step != "check", stage == .ready else { return }
        confirmed = true
        await install()
    }
}

extension InstallAwake {
    /// the screen stays on (isIdleTimerDisabled) and a background task asks iOS for its grace period if the app
    /// leaves the foreground anyway (FM1Kit: an update cut off waits in the loader, and resume finishes it)
    @MainActor public static func system() -> InstallAwake {
        #if os(iOS)
        let box = BackgroundTaskBox()
        return InstallAwake(begin: {
            UIApplication.shared.isIdleTimerDisabled = true
            box.end()
            box.id = UIApplication.shared.beginBackgroundTask(withName: "RemoteFM1 firmware install") { box.end() }
        }, end: {
            UIApplication.shared.isIdleTimerDisabled = false
            box.end()
        })
        #else
        return .none
        #endif
    }
}

#if os(iOS)
@MainActor private final class BackgroundTaskBox: @unchecked Sendable {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        id = .invalid
    }
}
#endif
