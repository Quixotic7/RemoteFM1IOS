// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Installing RemoteFM1 on the FM-1 from the app, with FM1Kit (MIT, github.com/ocean/FM1Kit) instead of the website's
// installer. The flow:
//
//   idle       a release and its package are chosen (default: the newest, its Bluetooth package)
//   check      the package is downloaded and checked (FirmwarePackages: SHA-256, FwscPackage, the identity); then the
//              app's panel lets go of the FM-1 (PanelLinkPausing: its session stopped, its CoreMIDI links closed, the
//              lease held so no AU instance in another app starts one); then FM1Kit asks the FM-1 what it runs
//              (identify: a unit waiting in its loader is offered the resume; check: what the install would do)
//   ready      what is on the FM-1, what will be installed; a firmware switch (FM1Kit can't tell custom firmwares
//              apart: RemoteFM1 0.2.2 -> 0.2.3 is one too) or a reinstall needs confirming
//   installing FM1Kit's install (or resume), its events folded by InstallProgress; the screen kept awake and a
//              background task asked for (InstallAwake)
//   finished   the identity the FM-1 reports now; the panel back (its session restarted if it was running)
//   failed     FM1Advice's words; "Finish the install" (FM1Kit's resume, the same package) when it was cut off
//
// Leaving the page (leave()) gives the FM-1 back to the panel, except while it waits in its loader.

import FM1Kit
import Foundation
import Observation

/// what the installer needs from the app's own link to the FM-1 (RemoteController; a fake in the tests)
@MainActor
public protocol PanelLinkPausing: AnyObject {
    /// another instance (an AU in another app) holds the FM-1: its name ("" unnamed); nil: nobody else
    var panelHolder: String? { get }
    /// the unit's HELLO_R, when the link has one
    var unitHello: UnitHello? { get }
    /// stops the panel's session and its MIDI connections to the FM-1 and keeps other instances off it; returns
    /// whether the panel was running (to restart it after)
    func pauseForInstall() async -> Bool
    /// lets go of the FM-1 again; restart: the panel's session starts again
    func resumeAfterInstall(restart: Bool)
}

/// what installing the chosen package would do (from FM1Kit's check)
public struct InstallSummary: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case remoteFM1(from: RemoteFM1Version)     // another RemoteFM1 release is on it (FM1Kit: a firmware switch)
        case switching                             // another firmware: switching can erase its projects and samples
        case sameIdentity                          // this release is already on it: a reinstall
        case reinstall                             // FM1Kit won't (V15 over itself)
        case midUpdate                             // the FM-1 waits in its loader: finish the install (resume)
    }

    public var deviceIdentity: String
    public var deviceName: String
    public var kind: Kind
    public var package: FirmwarePackageRef
    public var size: Int
    /// the package's firmware refuses M-VAVE's V15 once the FM-1's bootloader was changed (FM1Kit's check)
    public var refusesV15: Bool

    public var needsConfirm: Bool {
        switch kind {
        case .remoteFM1, .switching, .sameIdentity: true
        case .reinstall, .midUpdate: false
        }
    }
    public var canInstall: Bool { kind != .reinstall }

    /// a firmware's name from what the FM-1 reports
    public static func name(of identity: String) -> String {
        if let v = RemoteFM1Version(identity: identity) { return "RemoteFM1 \(v)" }
        if identity == "FM-1_015" { return "M-VAVE V15 (or RemoteFM1 0.1)" }
        if identity == RemoteFM1Version.identityPrefix + "00" { return "a RemoteFM1 development build" }
        if let id = FM1Identity(text: identity) {
            if id.isLoader { return "its update loader (part-way through an update)" }
            if id.isOpenFirmware { return "M-VAVE's open firmware" }
        }
        return "another firmware"
    }
}

/// a problem, in words (FM1Advice for FM1Kit's errors)
public struct InstallProblem: Equatable, Sendable {
    public var headline: String
    public var explanation: String
    public var deviceFine: Bool                 // the FM-1 still works as before
    public var canResume: Bool                  // cut off: FM1Kit's resume, with the same package
    public var details: String
}

/// the screen kept awake and a background task's grace period during an install (FM1Kit: keep the app open)
public struct InstallAwake: Sendable {
    public var begin: @MainActor @Sendable () -> Void
    public var end: @MainActor @Sendable () -> Void

    public init(begin: @escaping @MainActor @Sendable () -> Void, end: @escaping @MainActor @Sendable () -> Void) {
        self.begin = begin
        self.end = end
    }

    public static let none = InstallAwake(begin: {}, end: {})
}

@MainActor
@Observable
public final class FirmwareInstaller {
    public enum Stage: Equatable, Sendable { case idle, preparing, ready, installing, finished, failed }

    public let releases: RemoteFM1Releases
    /// the FM-1 is FM1Kit's SimulatedFM1 (the simulator, DEBUG's demo mode, tests)
    public let simulated: Bool

    public private(set) var stage: Stage = .idle
    public private(set) var activity = ""                   // (preparing) what is happening
    public private(set) var summary: InstallSummary?
    public private(set) var problem: InstallProblem?
    public private(set) var progress = InstallProgress()
    public private(set) var phase = ""                      // (installing) "Writing 42 %"
    public private(set) var installed: String?              // (finished) the identity the FM-1 reports
    public private(set) var panelPaused = false
    public private(set) var events: [String] = []           // FM1Kit's events, oldest first (diagnostics, tests)
    public var confirmed = false
    /// the package chosen; nil: the newest release's default package
    public private(set) var choice: FirmwarePackageRef?

    @ObservationIgnored let packages: FirmwarePackages
    @ObservationIgnored weak var panel: (any PanelLinkPausing)?
    @ObservationIgnored let transport: InstallTransportFactory
    @ObservationIgnored let timing: UpdaterTiming
    @ObservationIgnored let awake: InstallAwake
    @ObservationIgnored private var restartPanel = false
    @ObservationIgnored private var verified: VerifiedPackage?
    @ObservationIgnored var demoStep: String?              // (DEBUG's -installdemo) where the page goes by itself

    public init(releases: RemoteFM1Releases, packages: FirmwarePackages, panel: (any PanelLinkPausing)?,
                transport: @escaping InstallTransportFactory, simulated: Bool, timing: UpdaterTiming = .standard,
                awake: InstallAwake = .none) {
        self.releases = releases
        self.packages = packages
        self.panel = panel
        self.transport = transport
        self.simulated = simulated
        self.timing = timing
        self.awake = awake
    }

    // MARK: what is chosen, what the FM-1 has

    public var selected: FirmwarePackageRef? { choice ?? releases.newest?.package(.standard) }
    public var selectedRelease: RemoteFM1Release? { selected.flatMap { s in releases.releases.first { $0.version == s.version } } }
    /// the page can't be left, nor the choice changed
    public var isBusy: Bool { stage == .preparing || stage == .installing }
    /// the choice is fixed: a cut-off install resumes with the same package
    public var choiceLocked: Bool { isBusy || problem?.canResume == true || summary?.kind == .midUpdate }

    public func select(_ ref: FirmwarePackageRef) {
        guard !choiceLocked, ref != selected else { return }
        choice = ref
        reset()
    }

    /// the RemoteFM1 version on the FM-1: HELLO_R's (the link's), else what FM1Kit last saw
    public var unitVersion: RemoteFM1Version? {
        if let h = panel?.unitHello {
            if let v = RemoteFM1Version(identity: h.identity) ?? RemoteFM1Version(string: h.firmwareVersion) { return v }
        }
        return (installed ?? summary?.deviceIdentity).flatMap { RemoteFM1Version(identity: $0) }
    }

    /// a newer release than the FM-1's
    public var updateAvailable: RemoteFM1Release? { releases.update(over: unitVersion) }

    public var panelHolder: String? { panel?.panelHolder }

    // MARK: the flow

    /// downloads and checks the package, lets go of the FM-1, asks it what installing would do
    public func check() async {
        guard !isBusy, let ref = selected else { return }
        problem = nil
        summary = nil
        installed = nil
        confirmed = false
        stage = .preparing
        activity = "Downloading \(ref.title)…"
        do {
            let v = try await packages.fetch(ref)
            verified = v
            try await pausePanel()
            activity = "Asking the FM-1…"
            let updater = try makeUpdater(v)
            if let id = await updater.identify(), id.isLoader {
                summary = InstallSummary(deviceIdentity: id.text, deviceName: InstallSummary.name(of: id.text),
                                         kind: .midUpdate, package: ref, size: v.size,
                                         refusesV15: v.package.refusesV15OverOtherBootloaders)
                stage = .ready
                return
            }
            let c = try await updater.check(v.package)
            let kind: InstallSummary.Kind
            switch c.kind {
            case .reinstall: kind = .reinstall
            case .sameIdentity: kind = .sameIdentity
            case .update, .switchingFirmware:
                kind = RemoteFM1Version(identity: c.device.text).map { .remoteFM1(from: $0) } ?? .switching
            }
            summary = InstallSummary(deviceIdentity: c.device.text, deviceName: InstallSummary.name(of: c.device.text),
                                     kind: kind, package: ref, size: v.size,
                                     refusesV15: v.package.refusesV15OverOtherBootloaders)
            stage = .ready
        } catch {
            fail(error)
        }
    }

    /// installs (or, on a unit waiting in its loader, finishes) the checked package
    public func install() async {
        guard stage == .ready, let s = summary, s.canInstall, !s.needsConfirm || confirmed, let v = verified else { return }
        await run(v) { updater, sink in
            if s.kind == .midUpdate { return try await updater.resume(v.package, events: sink) }
            let options = InstallOptions(confirmsSwitchingFirmware: self.confirmed, confirmsSameIdentity: self.confirmed)
            return try await updater.install(v.package, options: options, events: sink)
        }
    }

    /// a cut-off install: FM1Kit's resume with the same package
    public func resume() async {
        guard stage == .failed, problem?.canResume == true, let v = verified else { return }
        await run(v) { updater, sink in try await updater.resume(v.package, events: sink) }
    }

    /// leaving the page: the FM-1 goes back to the panel (not while it waits in its loader); a result is forgotten
    public func leave() {
        guard !isBusy else { return }
        let midUpdate = problem.map { !$0.deviceFine } ?? (summary?.kind == .midUpdate)
        guard !midUpdate else { return }            // (kept: the page offers the resume when it is opened again)
        if panelPaused { resumePanel() }
        reset()
    }

    /// back to the choice (a check's result dropped)
    public func reset() {
        guard !isBusy else { return }
        stage = .idle
        summary = nil
        problem = nil
        installed = nil
        confirmed = false
        progress = InstallProgress()
        phase = ""
    }

    // MARK: internals

    private func run(_ v: VerifiedPackage,
                     _ body: @escaping (FM1Updater, @escaping @Sendable (UpdateEvent) -> Void) async throws -> FM1Identity) async {
        problem = nil
        progress = InstallProgress()
        phase = "Getting ready"
        stage = .installing
        awake.begin()
        defer { awake.end() }
        do {
            try await pausePanel()
            let updater = try makeUpdater(v)
            let sink: @Sendable (UpdateEvent) -> Void = { [weak self] e in Task { @MainActor in self?.record(e) } }
            let id = try await body(updater, sink)
            record(.finished(id))
            installed = id.text
            summary = nil
            stage = .finished
            resumePanel()
        } catch {
            fail(error)
        }
    }

    private func pausePanel() async throws {
        guard !panelPaused else { return }
        activity = "Letting go of the FM-1…"
        restartPanel = await panel?.pauseForInstall() ?? false
        panelPaused = true
    }

    private func resumePanel() {
        guard panelPaused else { return }
        panelPaused = false
        panel?.resumeAfterInstall(restart: restartPanel)
    }

    private func makeUpdater(_ v: VerifiedPackage) throws -> FM1Updater {
        FM1Updater(transport: try transport(v.package), timing: timing)
    }

    func record(_ e: UpdateEvent) {
        guard stage == .installing else { return }  // (an event hopping over after the end)
        progress.record(e)
        switch e {
        case .connected(let id): log("connected: \(id)")
        case .staging(let n): phase = "Getting ready (the FM-1 checks the package)"; if n == 1 { log("staging") }
        case .waitingForLoader: phase = "Restarting into its update loader"; log("waiting for the loader")
        case .loaderFound(let id): phase = "Writing"; log("loader: \(id)")
        case .writing(let f, _): phase = "Writing \(Int(f * 100)) %"
        case .checking(let f, _): phase = "Checking \(Int(f * 100)) %"
        case .rebooting: phase = "Restarting with the new firmware"; log("rebooting")
        case .finished(let id): phase = "Finished"; log("finished: \(id)")
        }
    }

    private func log(_ s: String) {
        events.append(s)
        if events.count > 40 { events.removeFirst(events.count - 40) }
    }

    func fail(_ error: any Error) {
        problem = Self.problem(for: error)
        stage = .failed
        log("failed: \(problem?.details ?? "")")
    }

    nonisolated static func problem(for error: any Error) -> InstallProblem {
        let details = String(reflecting: error)
        switch error {
        case let p as PackageProblem:
            return InstallProblem(headline: "This package was refused", explanation: p.errorDescription ?? "",
                                  deviceFine: true, canResume: false, details: details)
        case is URLError, is InstallerFetchError:
            return InstallProblem(headline: "The download didn't work", explanation: RemoteFM1Releases.words(error)
                                  + " Nothing was sent to the FM-1.", deviceFine: true, canResume: false, details: details)
        case FM1UpdateError.deviceNotFound:
            return InstallProblem(headline: "No FM-1 answered over USB",
                                  explanation: "Connect the FM-1 with a USB cable (Bluetooth can't install firmware), "
                                  + "switch it on, and try again. Close other apps that use the FM-1.",
                                  deviceFine: true, canResume: false, details: details)
        case FM1UpdateError.multipleDevices(let n):
            return InstallProblem(headline: "More than one FM-1 is connected",
                                  explanation: "\(n) FM-1s answered. Leave only the one to install on connected, "
                                  + "then try again.", deviceFine: true, canResume: false, details: details)
        default:
            let a = FM1Advice(for: error)
            var text = a.explanation
            if a.action == .resume { text += " \"Finish the install\" picks it up with the same package." }
            if a.action == .needsComputer { text += " That needs a computer (the FM-1's download mode)." }
            return InstallProblem(headline: a.headline, explanation: text, deviceFine: a.isDeviceFine,
                                  canResume: a.action == .resume, details: a.technicalDetails)
        }
    }
}
