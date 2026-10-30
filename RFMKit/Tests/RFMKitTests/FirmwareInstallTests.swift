// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Installing RemoteFM1 from the app (Install/), on the Mac: releases.json and its cache, the package checks (SHA-256,
// FM1Kit's FwscPackage, the identity), and FirmwareInstaller's flow on FM1Kit's SimulatedFM1 with RemoteFM1 0.2.3's
// real package (Fixtures/RemoteFM1): a full install, a refused checksum and identity (nothing reaches the FM-1, the panel
// is never paused), a cut-off install resumed, a unit waiting in its loader, a switch from another firmware, no FM-1;
// the panel paused before FM1Kit's first word and restarted after (a fake), and RemoteController's hold of the lease
// on a fake link. No CoreMIDI transport is made here; no network: the fetcher is a fake.

import FM1Kit
import Foundation
import RFMCore
import XCTest
@testable import RFMKit

private final class FakeFetcher: InstallerFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var _requests: [String] = []
    var offline = false

    init(_ files: [String: Data]) { self.files = files }

    var requests: [String] { lock.withLock { _requests } }
    func set(_ name: String, _ data: Data) { lock.withLock { files[name] = data } }

    func data(from url: URL) async throws -> Data {
        let (d, off) = lock.withLock { () -> (Data?, Bool) in
            _requests.append(url.lastPathComponent)
            return (files[url.lastPathComponent], offline)
        }
        if off { throw URLError(.notConnectedToInternet) }
        guard let d else { throw InstallerFetchError.http(404, url.lastPathComponent) }
        return d
    }
}

@MainActor
private final class FakePanel: PanelLinkPausing {
    var running = true
    var calls: [String] = []
    var panelHolder: String?
    var unitHello: UnitHello?

    func pauseForInstall() async -> Bool {
        calls.append("pause")
        defer { running = false }
        return running
    }

    func resumeAfterInstall(restart: Bool) {
        calls.append("resume(\(restart))")
        if restart { running = true }
    }
}

/// a transport with no ports (no FM-1 connected)
private final class NoPorts: MIDITransport, Sendable {
    func ports() async -> [MIDIPortDescriptor] { [] }
    func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection { throw MIDITransportError.portGone }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

final class FirmwareInstallTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/RemoteFM1")
    static let packageFile = "remote-0.2.3.fwsc"
    static let packageSHA = "211f06f63e8ca09de2812c017db9bb229713ce8e5a102eba887031551b2b403c"

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfmkit-install-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }

    private func fetcher() throws -> FakeFetcher {
        FakeFetcher(["releases.json": try fixture("releases.json"), Self.packageFile: try fixture(Self.packageFile)])
    }

    static var fastTiming: UpdaterTiming {
        var t = UpdaterTiming()
        t.afterUpgradeCommand = .milliseconds(20)
        t.finishSettle = .milliseconds(20)
        t.stagingIdleLimit = .seconds(2)
        t.loaderBoot = .milliseconds(20)
        t.loaderSearch = .seconds(3)
        t.writeIdleLimit = .seconds(2)
        t.firmwareBoot = .milliseconds(20)
        t.returnSearch = .seconds(3)
        t.scanInterval = .milliseconds(30)
        t.handshakeWait = .milliseconds(200)
        return t
    }

    /// a SimulatedFM1 running RemoteFM1 0.2.2 (or `installed`), with felucca-bsp's loader's second read, fast
    static func device(_ installed: String = "FM-1_52000202", configure: (inout SimulatedFM1.Options) -> Void = { _ in })
        -> SimulatedFM1.Options {
        var o = SimulatedFM1.Options()
        o.installedIdentity = FM1Identity(text: installed)!
        o.stagingRequestCount = 5
        o.requestInterval = .zero
        o.rebootDuration = .milliseconds(100)
        o.responseTimeout = .seconds(1)
        o.checksAfterWriting = true
        o.serialNumber = nil
        configure(&o)
        return o
    }

    /// an installer on a SimulatedFM1 (returned, to look at), the fake panel and fetcher; the list fetched
    @MainActor
    private func installer(_ options: SimulatedFM1.Options = device(), fetcher f: FakeFetcher? = nil,
                           transport: InstallTransportFactory? = nil) async throws
        -> (FirmwareInstaller, SimulatedFM1, FakePanel, FakeFetcher) {
        let fetch = try f ?? fetcher()
        let panel = FakePanel()
        let sim = SimulatedFM1(options: options)
        let factory: InstallTransportFactory = transport ?? { pkg in
            panel.calls.append("transport")
            sim.prepare(for: pkg)
            return sim
        }
        let releases = RemoteFM1Releases(cacheDirectory: dir, fetcher: fetch)
        await releases.refresh()
        let i = FirmwareInstaller(releases: releases,
                                  packages: FirmwarePackages(directory: dir.appendingPathComponent("packages"), fetcher: fetch),
                                  panel: panel, transport: factory, simulated: true, timing: Self.fastTiming)
        return (i, sim, panel, fetch)
    }

    // MARK: releases.json

    @MainActor
    func testReleasesAndVersions() async throws {
        let list = try RemoteFM1ReleaseList.parse(try fixture("releases.json"))
        XCTAssertEqual(list.releases.first?.version, "0.2.3")
        let r = list.releases[0]
        XCTAssertEqual(r.package(.standard), FirmwarePackageRef(version: "0.2.3", kind: .standard, file: Self.packageFile,
                                                                sha256: Self.packageSHA, identity: "FM-1_52000203"))
        XCTAssertEqual(r.package(.usbOnly)?.file, "remote-usb-0.2.3.fwsc")
        XCTAssertTrue(r.installable)
        let old = try XCTUnwrap(list.releases.first { $0.version == "0.1.1" })
        XCTAssertFalse(old.installable, "0.1.1 answers as V15 (FM-1_015)")
        XCTAssertNil(old.package(.usbOnly))

        XCTAssertEqual(RemoteFM1Version(identity: "FM-1_52000203"), RemoteFM1Version(0, 2, 3))
        XCTAssertEqual(RemoteFM1Version(identity: "FM-1_52011005"), RemoteFM1Version(1, 10, 5))
        XCTAssertNil(RemoteFM1Version(identity: "FM-1_5200"), "a dev build has no version")
        XCTAssertNil(RemoteFM1Version(identity: "FM-1_015"))
        XCTAssertNil(RemoteFM1Version(identity: "ota-FM-1_900"))
        XCTAssertEqual(RemoteFM1Version(0, 2, 3).identity, "FM-1_52000203")
        XCTAssertEqual(RemoteFM1Version(string: "v0.2.2"), RemoteFM1Version(0, 2, 2))
        XCTAssertEqual(RemoteFM1Version(string: "0.2.2-dev+5"), RemoteFM1Version(0, 2, 2))
        XCTAssertNil(RemoteFM1Version(string: "remote"))
        XCTAssertLessThan(RemoteFM1Version(0, 2, 9), RemoteFM1Version(0, 10, 0))
        for r in list.releases where r.installable {
            XCTAssertEqual(RemoteFM1Version(identity: r.identity), r.parsedVersion, "\(r.version)'s identity")
        }

        let releases = RemoteFM1Releases(cacheDirectory: dir, fetcher: try fetcher())
        await releases.refresh()
        XCTAssertEqual(releases.newest?.version, "0.2.3")
        XCTAssertEqual(releases.update(over: RemoteFM1Version(0, 2, 2))?.version, "0.2.3")
        XCTAssertNil(releases.update(over: RemoteFM1Version(0, 2, 3)))
        XCTAssertNil(releases.update(over: nil))
        XCTAssertEqual(releases.release(identity: "FM-1_52000202")?.version, "0.2.2")

        XCTAssertThrowsError(try RemoteFM1ReleaseList.parse(Data(#"{"releases":[]}"#.utf8)))
        XCTAssertThrowsError(try RemoteFM1ReleaseList.parse(Data("<html>".utf8)))
    }

    /// the last good list is kept: a later fetch that fails (offline, or a broken list) keeps it, with the reason
    @MainActor
    func testReleasesCache() async throws {
        let f = try fetcher()
        let a = RemoteFM1Releases(cacheDirectory: dir, fetcher: f)
        XCTAssertTrue(a.releases.isEmpty)
        await a.refresh()
        XCTAssertFalse(a.fromCache)
        XCTAssertNil(a.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("releases.json").path))

        f.offline = true
        let b = RemoteFM1Releases(cacheDirectory: dir, fetcher: f)
        XCTAssertTrue(b.fromCache)
        XCTAssertEqual(b.newest?.version, "0.2.3", "the cached list")
        await b.refresh()
        XCTAssertEqual(b.error, "No internet connection.")
        XCTAssertEqual(b.newest?.version, "0.2.3")

        f.offline = false
        f.set("releases.json", Data("{\"releases\": 3}".utf8))
        await b.refresh()
        XCTAssertNotNil(b.error)
        XCTAssertEqual(b.newest?.version, "0.2.3", "a broken list replaced the good one")
        let c = RemoteFM1Releases(cacheDirectory: dir, fetcher: f)
        XCTAssertEqual(c.newest?.version, "0.2.3", "a broken list was cached")
    }

    // MARK: the package

    func testPackageChecks() async throws {
        let data = try fixture(Self.packageFile)
        let ref = FirmwarePackageRef(version: "0.2.3", kind: .standard, file: Self.packageFile, sha256: Self.packageSHA,
                                     identity: "FM-1_52000203")
        let ok = try FirmwarePackages.verify(data, ref)
        XCTAssertEqual(ok.package.product, "FM-1_52000203")
        XCTAssertEqual(ok.package.sha256, Self.packageSHA)
        XCTAssertEqual(ok.size, 611_496)
        XCTAssertTrue(ok.package.isFirmware)
        print("RemoteFM1 0.2.3: Felucca's update code \(ok.package.usesFeluccaUpdateCode), "
              + "refuses V15 over other bootloaders \(ok.package.refusesV15OverOtherBootloaders)")

        // one byte changed: refused on its SHA-256, before FM1Kit reads it
        var bad = data
        bad[bad.count / 2] ^= 0x01
        XCTAssertThrowsError(try FirmwarePackages.verify(bad, ref)) { e in
            guard case PackageProblem.checksumMismatch(_, let expected, let got)? = e as? PackageProblem else {
                return XCTFail("\(e)")
            }
            XCTAssertEqual(expected, Self.packageSHA)
            XCTAssertNotEqual(got, Self.packageSHA)
        }
        // the right file, listed as another identity: refused
        var other = ref
        other.identity = "FM-1_52000202"
        XCTAssertThrowsError(try FirmwarePackages.verify(data, other)) { e in
            XCTAssertEqual(e as? PackageProblem, .identityMismatch(file: Self.packageFile, expected: "FM-1_52000202",
                                                                  got: "FM-1_52000203"))
        }
        // not a package at all (its SHA-256 listed as right): FwscPackage refuses it
        let junk = Data(repeating: 0x5A, count: 4000)
        var junkRef = ref
        junkRef.sha256 = FwscPackage.sha256Hex(junk)
        XCTAssertThrowsError(try FirmwarePackages.verify(junk, junkRef)) { e in
            guard case PackageProblem.unreadable? = e as? PackageProblem else { return XCTFail("\(e)") }
        }

        // fetch: downloaded once, then from the cache (checked again); a tampered download is neither used nor kept
        let f = try fetcher()
        let store = FirmwarePackages(directory: dir.appendingPathComponent("p"), fetcher: f)
        _ = try await store.fetch(ref)
        _ = try await store.fetch(ref)
        XCTAssertEqual(f.requests, [Self.packageFile])
        try FileManager.default.removeItem(at: store.directory)
        f.set(Self.packageFile, bad)
        do {
            _ = try await store.fetch(ref)
            XCTFail("a tampered download was accepted")
        } catch {
            XCTAssertNotNil(error as? PackageProblem)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(Self.packageFile).path))
    }

    // MARK: the flow on the SimulatedFM1

    /// RemoteFM1 0.2.2 -> 0.2.3: checked (a firmware switch to FM1Kit: confirmed), installed, the panel paused first
    @MainActor
    func testFullInstall() async throws {
        let (i, sim, panel, _) = try await installer()
        XCTAssertEqual(i.selected?.file, Self.packageFile, "the newest release's default package")
        panel.unitHello = { var h = UnitHello(); h.identity = "FM-1_52000202"; return h }()
        XCTAssertEqual(i.unitVersion, RemoteFM1Version(0, 2, 2))
        XCTAssertEqual(i.updateAvailable?.version, "0.2.3")

        await i.check()
        XCTAssertEqual(i.stage, .ready, "\(i.problem?.details ?? "")")
        let s = try XCTUnwrap(i.summary)
        XCTAssertEqual(s.kind, .remoteFM1(from: RemoteFM1Version(0, 2, 2)))
        XCTAssertEqual(s.deviceIdentity, "FM-1_52000202")
        XCTAssertEqual(s.deviceName, "RemoteFM1 0.2.2")
        XCTAssertEqual(s.package.identity, "FM-1_52000203")
        XCTAssertEqual(s.size, 611_496)
        XCTAssertTrue(s.needsConfirm)
        XCTAssertEqual(panel.calls, ["pause", "transport"], "FM1Kit spoke before the panel let go")
        XCTAssertTrue(i.panelPaused)

        await i.install()                               // (not confirmed: nothing happens)
        XCTAssertEqual(i.stage, .ready)
        XCTAssertEqual(sim.currentIdentity?.text, "FM-1_52000202")

        i.confirmed = true
        let t0 = Date()
        await i.install()
        print("install of RemoteFM1 0.2.3 on the SimulatedFM1: \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        XCTAssertEqual(i.stage, .finished, "\(i.problem?.details ?? "")")
        XCTAssertEqual(i.installed, "FM-1_52000203")
        XCTAssertEqual(sim.currentIdentity?.text, "FM-1_52000203")
        XCTAssertEqual(i.progress.fraction, 1)
        XCTAssertTrue(i.progress.isFinished)
        XCTAssertEqual(i.events.last, "finished: FM-1_52000203")
        XCTAssertEqual(panel.calls, ["pause", "transport", "transport", "resume(true)"])
        XCTAssertTrue(panel.running, "the panel didn't restart")
        XCTAssertFalse(i.panelPaused)
        XCTAssertEqual(i.unitVersion, RemoteFM1Version(0, 2, 2), "(HELLO_R's, until the link has the new one)")
        panel.unitHello = nil
        XCTAssertEqual(i.unitVersion, RemoteFM1Version(0, 2, 3))
        XCTAssertNil(i.updateAvailable)

        i.leave()
        XCTAssertEqual(i.stage, .idle)
        XCTAssertEqual(panel.calls.count, 4, "leave resumed twice")
    }

    /// a tampered download: refused; the panel is never paused and FM1Kit never makes a transport
    @MainActor
    func testChecksumMismatchRefused() async throws {
        let f = try fetcher()
        var bad = try fixture(Self.packageFile)
        bad[100_000] ^= 0x80
        f.set(Self.packageFile, bad)
        let (i, sim, panel, _) = try await installer(fetcher: f)
        await i.check()
        XCTAssertEqual(i.stage, .failed)
        XCTAssertEqual(i.problem?.headline, "This package was refused")
        XCTAssertTrue(i.problem?.explanation.contains("SHA-256") ?? false)
        XCTAssertEqual(i.problem?.deviceFine, true)
        XCTAssertEqual(i.problem?.canResume, false)
        XCTAssertEqual(panel.calls, [])
        XCTAssertEqual(sim.currentIdentity?.text, "FM-1_52000202")
        await i.install()
        XCTAssertEqual(i.stage, .failed)
        XCTAssertEqual(panel.calls, [])
    }

    /// releases.json says another identity than the package carries: refused before anything reaches the FM-1
    @MainActor
    func testIdentityMismatchRefused() async throws {
        let f = try fetcher()
        let text = String(decoding: try fixture("releases.json"), as: UTF8.self)
            .replacingOccurrences(of: "\"FM-1_52000203\"", with: "\"FM-1_52000299\"")
        f.set("releases.json", Data(text.utf8))
        let (i, _, panel, _) = try await installer(fetcher: f)
        XCTAssertEqual(i.selected?.identity, "FM-1_52000299")
        await i.check()
        XCTAssertEqual(i.stage, .failed)
        XCTAssertTrue(i.problem?.explanation.contains("installs as FM-1_52000203, not FM-1_52000299") ?? false,
                      i.problem?.explanation ?? "")
        XCTAssertEqual(panel.calls, [])
    }

    /// the cable pulled at half the write: the FM-1 waits in its loader; the panel stays off it (also on leave);
    /// "Finish the install" resumes with the same package
    @MainActor
    func testCutOffInstallResumed() async throws {
        let (i, sim, panel, _) = try await installer(Self.device { $0.unplugDuringWriteAt = 0.5 })
        await i.check()
        i.confirmed = true
        await i.install()
        XCTAssertEqual(i.stage, .failed)
        let p = try XCTUnwrap(i.problem)
        XCTAssertTrue(p.canResume, p.details)
        XCTAssertFalse(p.deviceFine)
        XCTAssertEqual(p.headline, "The install was interrupted")
        XCTAssertTrue(sim.currentIdentity?.isLoader ?? false, "\(String(describing: sim.currentIdentity))")
        XCTAssertTrue(i.choiceLocked)
        if let usb = i.releases.newest?.package(.usbOnly) {
            i.select(usb)
            XCTAssertEqual(i.selected?.file, Self.packageFile, "the choice changed under a cut-off install")
        }
        i.leave()
        XCTAssertEqual(i.stage, .failed, "leave forgot the cut-off install")
        XCTAssertTrue(i.panelPaused)
        XCTAssertFalse(panel.calls.contains { $0.hasPrefix("resume") }, "the panel came back to an FM-1 in its loader")

        await i.resume()
        XCTAssertEqual(i.stage, .finished, "\(i.problem?.details ?? "")")
        XCTAssertEqual(i.installed, "FM-1_52000203")
        XCTAssertEqual(sim.currentIdentity?.text, "FM-1_52000203")
        XCTAssertEqual(panel.calls.last, "resume(true)")
    }

    /// a unit already waiting in its loader (an install cut off earlier, or the app closed): offered the resume
    @MainActor
    func testUnitWaitingInItsLoader() async throws {
        let (i, sim, panel, _) = try await installer(Self.device { $0.startsInRecoveryMode = true })
        await i.check()
        XCTAssertEqual(i.stage, .ready, "\(i.problem?.details ?? "")")
        XCTAssertEqual(i.summary?.kind, .midUpdate)
        XCTAssertFalse(i.summary?.needsConfirm ?? true)
        i.leave()
        XCTAssertEqual(i.stage, .ready, "leave dropped the loader's resume")
        XCTAssertFalse(panel.calls.contains { $0.hasPrefix("resume") })
        await i.install()
        XCTAssertEqual(i.stage, .finished, "\(i.problem?.details ?? "")")
        XCTAssertEqual(sim.currentIdentity?.text, "FM-1_52000203")
    }

    /// from another firmware: a switch (projects and samples), confirmed; the same release again: a reinstall
    @MainActor
    func testSwitchAndReinstall() async throws {
        let (a, _, _, _) = try await installer(Self.device("FM-1_900"))
        await a.check()
        XCTAssertEqual(a.summary?.kind, .switching)
        XCTAssertEqual(a.summary?.deviceName, "another firmware")
        a.confirmed = true
        await a.install()
        XCTAssertEqual(a.stage, .finished, "\(a.problem?.details ?? "")")

        let (b, _, _, _) = try await installer(Self.device("FM-1_52000203"))
        await b.check()
        XCTAssertEqual(b.summary?.kind, .sameIdentity)
        XCTAssertTrue(b.summary?.needsConfirm ?? false)
    }

    /// nothing on USB: the words say USB, and Bluetooth can't; the panel comes back when the page is left
    @MainActor
    func testNoFM1() async throws {
        let panel = FakePanel()
        let f = try fetcher()
        let releases = RemoteFM1Releases(cacheDirectory: dir, fetcher: f)
        await releases.refresh()
        let i = FirmwareInstaller(releases: releases,
                                  packages: FirmwarePackages(directory: dir.appendingPathComponent("p"), fetcher: f),
                                  panel: panel, transport: { _ in NoPorts() }, simulated: true, timing: Self.fastTiming)
        await i.check()
        XCTAssertEqual(i.stage, .failed)
        XCTAssertEqual(i.problem?.headline, "No FM-1 answered over USB")
        XCTAssertTrue(i.problem?.explanation.contains("Bluetooth can't") ?? false)
        XCTAssertEqual(panel.calls, ["pause"])
        i.leave()
        XCTAssertEqual(panel.calls, ["pause", "resume(true)"])
        XCTAssertEqual(i.stage, .idle)
    }

    // MARK: the app's link (RemoteController + PanelSession) around an install

    /// the link stops, the lease stays the app's (heartbeaten under "installing firmware", no session), another
    /// instance sees the FM-1 in use and doesn't take it; afterwards the link claims again and connects
    @MainActor
    func testPanelPausedAndRestartedAroundTheInstall() async throws {
        var cfg = PanelSession.Config()
        cfg.leasePath = dir.appendingPathComponent("lease.bin")
        cfg.notifyName = "com.quixotic7.remotefm1.test.\(UUID().uuidString.prefix(8)).lease"
        cfg.staleMs = 1500
        cfg.settle = 0.3
        let c = RemoteController(backend: .fake(bluetooth: false), lease: cfg, identity: UUID(), ownerName: "app / FIZZ")
        defer { c.shutdown() }
        c.start()
        try await waitUntil(5) { c.refresh(); return c.state.isConnected }
        let session = try XCTUnwrap(c.session)

        // another instance (an AU) waits: the app holds the FM-1
        var link2 = rfmc_cfg_t()
        link2.backend = Int32(RFMC_FAKE)
        let l2 = "RFMKit test".withCString { hn in link2.host_name = hn; return rfmc_new(&link2)! }
        let other = PanelSession(link: l2, identity: UUID(), name: "AUM / Felucca", config: cfg)
        defer { other.finish() }

        let wasRunning = await c.pauseForInstall()
        XCTAssertTrue(wasRunning)
        XCTAssertTrue(session.holding)
        c.refresh()
        XCTAssertFalse(c.isRunning, "the link still runs during the install")
        XCTAssertEqual(session.leaseView()?.mine, 1)
        try await Task.sleep(for: .seconds(2))          // (past staleMs: the hold's heartbeat keeps it fresh)
        let v = try XCTUnwrap(other.leaseView())
        XCTAssertEqual(v.stale, 0, "the held lease went stale")
        XCTAssertEqual(RemoteController.string(v.name), "RemoteFM1 app / installing firmware")
        XCTAssertTrue(other.status().heldElsewhere)
        other.appeared()                                // (a new instance: fresh owner, so it waits)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(other.status().owner, "another instance took the FM-1 during the install")
        session.appeared()                              // (rule a: the app's own UUID; no claim while holding)
        try await Task.sleep(for: .milliseconds(300))
        c.refresh()
        XCTAssertFalse(c.isRunning, "an automatic claim restarted the link during the install")

        c.resumeAfterInstall(restart: true)
        XCTAssertFalse(session.holding)
        try await waitUntil(5) { c.refresh(); return c.state.isConnected }
        XCTAssertEqual(RemoteController.string(other.leaseView()!.name), "app / FIZZ")
    }

    @MainActor
    private func waitUntil(_ seconds: Double, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(cond(), "timed out")
    }
}
