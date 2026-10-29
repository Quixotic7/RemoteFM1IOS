// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AU core test (M4, -aucoretest): this app as a host for two instances of its own extension, out of process,
// with the extension's process-wide shared fake unit as their FM-1 (the App Group file au-backend.txt says "fake"
// before anything is instantiated; the real CoreMIDI back end stays off). It
//   1. instantiates A (ChoralRoot, context "Track A") and B (Felucca, "Track B"), plays them on an AVAudioEngine
//      with host MIDI notes for 3 s, and measures each one's output RMS on a tap of its own node;
//   2. waits for A's automatic claim (empty lease, after the settle delay), then moves the panel A -> B -> A through
//      the message channel and reads the shared fake's record each time (who started the session, what the old
//      owner sent after it, SESSION 0s, whose screen the fake shows);
//   3. changes ChoralRoot's tempo on the fake panel (A owns it), saves A's fullState, destroys A, creates C from
//      that state (same UUID: it reclaims at once; the tempo is back), and D from the same state while C lives (a
//      duplicate: a new UUID, no claim);
//   4. the cross-process case at the lease level: the app's own link (its own fake unit) claims against C, then C
//      claims back.
//   5. (M7) when Documents/Firmware has a valid .rfm1 (scripts/sim_aucoretest.sh RFM1=...): E plays the first imported
//      firmware (a Wasm core in the extension, from the App Group mirror) with host notes; F is made from E's
//      fullState and must find the same file by its SHA-256 and boot from the saved flash. -wasmonly runs only this.
// The summary goes to aucoretest.json (Documents); scripts/sim_aucoretest.sh takes screenshots when the marker files
// aucoretest-shot-<n>.json appear (the test then waits 3 s).

import AVFoundation
import AudioToolbox
import RFMCore
import RFMKit
import SwiftUI
import UIKit

struct AUCoreTestSummary: Codable, Sendable {
    struct Step: Codable, Sendable, Identifiable {
        var id: Int
        var name: String
        var ok: Bool?
        var detail: String
    }
    struct Audio: Codable, Sendable {
        var label = "", core = ""
        var rms = 0.0, peak = 0.0, frames = 0
        var renderAvgUs = 0, renderMaxUs = 0, renderFrames = 0, rate = 0.0, renderLoadPct = 0.0
        var midiNotes = 0, midiIn = 0
        var latencyFrames = 0, underruns = 0, coreAvgUs = 0, coreMaxUs = 0, frameMaxUs = 0, ringFillMin = 0
        var realtime = false, workgroup = false
    }
    var done = false
    var device = "", system = ""
    var simulator = false
    var appPid = Int(getpid())
    var steps: [Step] = []
    var audio: [Audio] = []
    var reports: [String: AUReport] = [:]       // by moment: "A at start", ...
    var fake: [String: String] = [:]            // the shared fake's record (JSON) by moment
    var tempo: Int?                             // ChoralRoot's tempo after the panel's change (A)
    var wasm: [Audio] = []                      // (M7) the imported firmware's instances
}

@MainActor
@Observable
final class AUCoreTestHost {
    private(set) var summary = AUCoreTestSummary()
    private(set) var running = false
    private(set) var views: [(String, UIViewController)] = []

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var units: [String: AVAudioUnit] = [:]
    @ObservationIgnored private var appLink: RemoteController?
    @ObservationIgnored private let log = RFMShared.log("aucoretest")
    @ObservationIgnored private var shot = 0

    private var desc: AudioComponentDescription { RFMShared.component }

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let dev = UIDevice.current
        summary.device = dev.model + " " + dev.name
        summary.system = dev.systemName + " " + dev.systemVersion
        #if targetEnvironment(simulator)
        summary.simulator = true
        #endif
        for d in AUTestHost.outputDirs() {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasPrefix("aucoretest") {
                try? FileManager.default.removeItem(at: d.appendingPathComponent(f))
            }
        }
        // the extension's panel: the shared fake; a fresh lease
        guard let group = RFMShared.groupContainer() else {
            step("App Group", false, "no App Group container: the extension can't be told to use the fake unit")
            return finish()
        }
        RFMShared.setExtensionBackend("fake")
        defer { RFMShared.setExtensionBackend(nil) }    // on every exit: a device's AUs must not stay on the fake
        try? FileManager.default.removeItem(at: group.appendingPathComponent("lease.bin"))
        step("setup", true, "au-backend.txt = fake, lease.bin removed (\(group.lastPathComponent))")

        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            step("audio session", false, AUTestHost.describe(error))
        }

        // the imported firmware, mirrored into the App Group for the extension (the app's own launch does this; this
        // test mode skips the app's setup)
        let library = FirmwareLibrary()
        let files = library.sync()
        step("firmware folder", nil, "\(files.count) file(s) in Documents/Firmware, \(files.filter { $0.error == nil }.count) valid: "
             + files.map { $0.error == nil ? "\($0.name) \($0.version)" : "\($0.file) (\($0.error ?? ""))" }.joined(separator: ", "))
        if ProcessInfo.processInfo.arguments.contains("-wasmonly") {
            await phaseWasm(library)                    // (it starts the engine once E is attached)
            engine.stop()
            return finish()
        }

        // 1-3: A and B (A is released when phaseAB returns: only `units` and the views held it)
        guard let saved = await phaseAB(), let b = units["B"] else { return finish() }
        let savedID = InstanceState(saved)?.instance.uuidString ?? ""
        let goneA = await waitFor(6) { (self.status(b)?.ownerPid ?? -1) == 0 }
        step("A destroyed", goneA, "the lease's owner pid \(status(b)?.ownerPid ?? -1) (0: the owner instance is gone, its UUID kept)")
        await cdAndApp(saved: saved, savedID: savedID)
        await phaseWasm(library)
        engine.stop()
        finish()
    }

    /// 5: an imported firmware in the extension: E plays it, F restores E's state by the file's SHA-256
    private func phaseWasm(_ library: FirmwareLibrary) async {
        guard let f = library.files.first(where: { $0.error == nil }) else {
            step("imported firmware", nil, "none in Documents/Firmware: skipped")
            return
        }
        guard let e = await make("E", core: f.key, context: "Track E") else { return }
        let meter = TapMeter()
        engine.attach(e)
        engine.connect(e, to: engine.mainMixerNode, format: nil)
        e.installTap(onBus: 0, bufferSize: 2048, format: nil, block: CoreTest.tap(meter))
        if !engine.isRunning {
            do { try engine.start() } catch { step("engine", false, AUTestHost.describe(error)) }
        }
        try? await Task.sleep(for: .seconds(2))                 // (the core boots and settles)
        _ = call(e, "resetLevel")
        meter.reset()
        let t0 = Date()
        var on: [UInt8] = [0x90, 62, 100]
        e.auAudioUnit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, &on)
        try? await Task.sleep(for: .seconds(3))
        var off: [UInt8] = [0x80, 62, 0]
        e.auAudioUnit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, &off)
        let m = meter.result
        let r = status(e)
        summary.reports["E (imported)"] = r
        var au = AUCoreTestSummary.Audio(label: "E", core: r?.core ?? "?", rms: m.rms, peak: m.peak, frames: m.frames)
        if let r {
            au.renderAvgUs = r.renderAvgUs
            au.renderMaxUs = r.renderMaxUs
            au.renderFrames = r.renderFrames
            au.rate = r.rate
            au.renderLoadPct = r.renderLoadPct
            au.midiNotes = r.midiNotes
            au.midiIn = r.midiIn
            au.latencyFrames = r.latencyFrames
            au.underruns = r.underruns
            au.coreAvgUs = r.coreAvgUs
            au.coreMaxUs = r.coreMaxUs
            au.frameMaxUs = r.frameMaxUs
            au.ringFillMin = r.ringFillMin
            au.realtime = r.realtime
            au.workgroup = r.workgroup
        }
        summary.wasm.append(au)
        step("E plays \(f.name) \(f.version) (imported)", r?.kind == "wasm" && r?.coreKey == f.key && m.rms > 1e-4,
             String(format: "kind %@, %.1f s: rms %.4f peak %.3f; host notes %d; core thread %d us avg, %d max per render "
                    + "(%d%% load), frame() max %d us, %d underruns; %d-frame renders at %.0f Hz",
                    r?.kind ?? "?", Date().timeIntervalSince(t0), m.rms, m.peak, au.midiNotes, au.coreAvgUs, au.coreMaxUs,
                    r?.coreLoadPct ?? -1, au.frameMaxUs, au.underruns, au.renderFrames, au.rate))
        await screenshot("E plays the imported \(f.name)")
        let saved = e.auAudioUnit.fullState ?? [:]
        let cs = CoreState(saved)
        step("E's fullState", cs?.kind == "wasm" && cs?.sha256 == f.sha256 && cs?.core == f.coreID && cs?.flash != nil,
             "kind \(cs?.kind ?? "?"), id \(cs?.core ?? "?") \(cs?.version ?? ""), sha256 \(cs?.sha256.prefix(12) ?? "?"), "
             + "flash \(cs?.flash?.count ?? 0) bytes")
        e.removeTap(onBus: 0)
        engine.detach(e)
        units["E"] = nil
        if let g = await make("F", core: nil, context: "Track E") {
            g.auAudioUnit.fullState = saved
            try? await Task.sleep(for: .seconds(1))
            let rf = status(g)
            summary.reports["F from E's state"] = rf
            step("F restores E's firmware by its SHA-256", rf?.coreKey == f.key && rf?.kind == "wasm"
                    && rf?.bootedFrom == "the saved flash" && rf?.coreNote == "" && rf?.booted == true,
                 "\(rf?.coreName ?? "?") \(rf?.coreVersion ?? "") (\(rf?.kind ?? "?"), \(rf?.coreKey.prefix(17) ?? "?")) from "
                 + "\(rf?.bootedFrom ?? "?"); note \"\(rf?.coreNote ?? "")\"")
            units["F"] = nil
        }
    }

    /// A and B: the sound, the takeovers, A's flash and fullState; A destroyed at the end
    private func phaseAB() async -> [String: Any]? {
        guard let a = await make("A", core: "choralroot", context: "Track A"),
              let b = await make("B", core: "felucca", context: "Track B") else { return nil }
        let meters = ["A": TapMeter(), "B": TapMeter()]
        for (l, u) in [("A", a), ("B", b)] {
            engine.attach(u)
            engine.connect(u, to: engine.mainMixerNode, format: nil)
            u.installTap(onBus: 0, bufferSize: 2048, format: nil, block: CoreTest.tap(meters[l]!))
        }
        do { try engine.start() } catch { step("engine", false, AUTestHost.describe(error)); return nil }
        try? await Task.sleep(for: .seconds(1))                 // (the cores boot and settle)
        for u in [a, b] { _ = call(u, "resetLevel") }
        meters.values.forEach { $0.reset() }
        let t0 = Date()
        for (i, (u, note)) in [(a, UInt8(62)), (b, UInt8(65))].enumerated() {
            var on: [UInt8] = [0x90, note, 100]
            u.auAudioUnit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, &on)
            _ = i
        }
        try? await Task.sleep(for: .seconds(1.5))
        for (u, note) in [(a, UInt8(62)), (b, UInt8(65))] {
            var off: [UInt8] = [0x80, note, 0]
            u.auAudioUnit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, &off)
            var on: [UInt8] = [0x90, note + 4, 90]
            u.auAudioUnit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, &on)
        }
        try? await Task.sleep(for: .seconds(1.5))
        for (u, note) in [(a, UInt8(66)), (b, UInt8(69))] {
            var off: [UInt8] = [0x80, note, 0]
            u.auAudioUnit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, &off)
        }
        let secs = Date().timeIntervalSince(t0)
        for (l, u) in [("A", a), ("B", b)] {
            let m = meters[l]!.result
            let r = status(u)
            var au = AUCoreTestSummary.Audio(label: l, core: r?.core ?? "?", rms: m.rms, peak: m.peak, frames: m.frames)
            if let r {
                au.renderAvgUs = r.renderAvgUs
                au.renderMaxUs = r.renderMaxUs
                au.renderFrames = r.renderFrames
                au.rate = r.rate
                au.renderLoadPct = r.renderLoadPct
                au.midiNotes = r.midiNotes
                au.midiIn = r.midiIn
                au.latencyFrames = r.latencyFrames
                au.underruns = r.underruns
                au.coreAvgUs = r.coreAvgUs
                au.coreMaxUs = r.coreMaxUs
                au.frameMaxUs = r.frameMaxUs
                au.ringFillMin = r.ringFillMin
                au.realtime = r.realtime
                au.workgroup = r.workgroup
                summary.reports["\(l) after the notes"] = r
            }
            summary.audio.append(au)
            step("\(l) plays \(au.core)", m.rms > 1e-4 && au.midiNotes >= 2,
                 String(format: "tap %.1f s: rms %.4f peak %.3f, %d frames; host notes %d (MIDI in %d); render avg %d us, max %d us per %d frames at %.0f Hz (%.1f%%)",
                        secs, m.rms, m.peak, m.frames, au.midiNotes, au.midiIn, au.renderAvgUs, au.renderMaxUs,
                        au.renderFrames, au.rate, au.renderLoadPct))
            step("\(l) renders ahead", au.latencyFrames > 0,
                 String(format: "latency %d frames (%.1f ms), ring min %d, %d underruns; core thread %d us avg, %d max per render, frame() max %d us%@%@",
                        au.latencyFrames, au.rate > 0 ? Double(au.latencyFrames) / au.rate * 1000 : 0, au.ringFillMin,
                        au.underruns, au.coreAvgUs, au.coreMaxUs, au.frameMaxUs, au.realtime ? ", real time" : "",
                        au.workgroup ? ", in the host's workgroup" : ""))
        }

        // 2. A's automatic claim (the lease was empty), then A -> B -> A
        let la = status(a)?.fakeLabel ?? "?", lb = status(b)?.fakeLabel ?? "?"
        let ownedA = await waitFor(8) { self.status(a).map { $0.owner && $0.link.hasPrefix("Connected") } ?? false }
        let ra = status(a), rb = status(b)
        summary.reports["A owns"] = ra
        summary.reports["B while A owns"] = rb
        let f1 = fake(a)
        summary.fake["A owns"] = f1.json
        step("A claims by itself", ownedA && ra?.autoClaims == 1 && (rb?.claims ?? 1) == 0,
             "A: \(ra?.line ?? "?") (auto claims \(ra?.autoClaims ?? -1)); B: \(rb?.line ?? "?") (claims \(rb?.claims ?? -1))")
        step("the fake shows A", f1.lastStarter == la && f1.match(la) > f1.match(lb),
             "last SESSION start by \(f1.lastStarter) (A is \(la)); screen matches A \(f1.pct(la)), B \(f1.pct(lb))")
        await screenshot("A owns, B in use")

        _ = call(b, "claim")
        let ownedB = await waitFor(6) { self.status(b).map { $0.owner && $0.link.hasPrefix("Connected") } ?? false }
        try? await Task.sleep(for: .milliseconds(800))
        let ra2 = status(a), rb2 = status(b)
        summary.reports["A after B's claim"] = ra2
        summary.reports["B owns"] = rb2
        let f2 = fake(a)
        summary.fake["B owns"] = f2.json
        let sa = f2.sender(la)
        step("B takes the panel", ownedB && rb2?.claimWaited == true && rb2?.claimAcked == true,
             "B: \(rb2?.line ?? "?"), claim waited \(rb2?.claimWaited ?? false) acked \(rb2?.claimAcked ?? false) in \(rb2?.claimWaitMs ?? -1) ms")
        step("A yields without a word", ra2?.owner == false && ra2?.drops == 1 && (sa?.stops ?? 1) == 0 && (sa?.afterOther ?? 1) == 0,
             "A: \(ra2?.line ?? "?"), drops \(ra2?.drops ?? -1); fake: A's SESSION 0s \(sa?.stops ?? -1), A's messages after B's start \(sa?.afterOther ?? -1) (tiles \(sa?.afterOtherTiles ?? -1)); A still sounding: renders \(ra2?.sounding ?? 0)")
        step("the fake shows B", f2.lastStarter == lb && f2.match(lb) > f2.match(la),
             "last SESSION start by \(f2.lastStarter); screen matches B \(f2.pct(lb)), A \(f2.pct(la)); starts \(f2.starts)")
        await screenshot("B owns, A in use")

        _ = call(a, "claim")
        let ownedA2 = await waitFor(6) { self.status(a).map { $0.owner && $0.link.hasPrefix("Connected") } ?? false }
        try? await Task.sleep(for: .milliseconds(800))
        let ra3 = status(a), rb3 = status(b)
        let f3 = fake(a)
        summary.fake["A owns again"] = f3.json
        let sb = f3.sender(lb)
        step("A takes it back, B yields", ownedA2 && rb3?.drops == 1 && (sb?.stops ?? 1) == 0 && (sb?.afterOther ?? 1) == 0
                && f3.lastStarter == la,
             "A: \(ra3?.line ?? "?") (acked \(ra3?.claimAcked ?? false) in \(ra3?.claimWaitMs ?? -1) ms); B: \(rb3?.line ?? "?"); B's SESSION 0s \(sb?.stops ?? -1), after A's start \(sb?.afterOther ?? -1); screen matches A \(f3.pct(la))")

        // 3. the flash through fullState: the tempo on the fake panel (SELECT +1, SAVE held), A saved and destroyed,
        // C from A's state
        let tempo0 = param(a, "Tempo")
        _ = call(a, "fakePanel", ["knob": Int(RFME_E_SELECT), "detents": 1])
        try? await Task.sleep(for: .milliseconds(400))
        _ = call(a, "fakePanel", ["button": Int(RFME_B_SAVE), "down": true])
        try? await Task.sleep(for: .milliseconds(1300))
        _ = call(a, "fakePanel", ["button": Int(RFME_B_SAVE), "down": false])
        try? await Task.sleep(for: .milliseconds(800))
        let tempo1 = param(a, "Tempo")
        summary.tempo = tempo1
        step("tempo on the fake panel", tempo0 != nil && tempo1 == (tempo0 ?? 0) + 1,
             "ChoralRoot tempo \(tempo0.map(String.init) ?? "?") -> \(tempo1.map(String.init) ?? "?") (SELECT +1, SAVE held, through the shared fake)")
        let saved = a.auAudioUnit.fullState ?? [:]
        let flashBytes = (saved[CoreState.flashKey] as? Data)?.count ?? 0
        let savedID = InstanceState(saved)?.instance.uuidString ?? ""
        _ = b
        step("A's fullState", flashBytes > 0 && saved[CoreState.coreKey] as? String == "choralroot",
             "keys \(saved.keys.sorted()); flash \(flashBytes) bytes (lzfse of \(saved[CoreState.flashSizeKey] as? Int ?? 0)); instance \(savedID.prefix(8))")
        a.removeTap(onBus: 0)
        engine.detach(a)
        units["A"] = nil
        if let i = views.firstIndex(where: { $0.0 == "A" }) { views.remove(at: i) }
        return saved
    }

    /// C from A's state, D its duplicate, and the app's own link against C
    private func cdAndApp(saved: [String: Any], savedID: String) async {
        let tempo1 = summary.tempo
        if let c = await make("C", core: nil, context: "Track A") {
            c.auAudioUnit.fullState = saved
            engine.attach(c)
            engine.connect(c, to: engine.mainMixerNode, format: nil)
            let back = await waitFor(4) { self.status(c).map { $0.owner && $0.link.hasPrefix("Connected") } ?? false }
            try? await Task.sleep(for: .milliseconds(500))
            let rc = status(c)
            summary.reports["C restored"] = rc
            let tc = param(c, "Tempo")
            step("C from A's state", rc?.instance == savedID && rc?.core == "choralroot" && rc?.bootedFrom == "the saved flash"
                    && tc == tempo1,
                 "instance \(rc?.instance.prefix(8) ?? "?") (A's \(savedID.prefix(8))), \(rc?.coreName ?? "?") from \(rc?.bootedFrom ?? "?"), tempo \(tc.map(String.init) ?? "?")")
            step("C reconnects (its UUID owns the lease)", back && rc?.autoClaims == 1,
                 "\(rc?.line ?? "?"), auto claims \(rc?.autoClaims ?? -1), duplicate \(rc?.duplicate ?? false)")

            // the duplicate: D from the same state while C lives
            if let d = await make("D", core: nil, context: "Track D") {
                d.auAudioUnit.fullState = saved
                try? await Task.sleep(for: .seconds(3))
                let rd = status(d)
                summary.reports["D duplicate"] = rd
                step("a duplicated state gets a new UUID", rd?.duplicate == true && rd?.instance != savedID && rd?.owner == false
                        && rd?.claims == 0,
                     "D \(rd?.instance.prefix(8) ?? "?") (state's \(savedID.prefix(8))), duplicate \(rd?.duplicate ?? false), owner \(rd?.owner ?? false), claims \(rd?.claims ?? -1)")
                units["D"] = nil
            }

            // 4. across processes, at the lease level: the app's own link (its own fake unit) vs C
            let app = RemoteController(backend: .fake(bluetooth: false), lease: PanelSession.Config(),
                                       identity: UUID(), ownerName: "RemoteFM1 app / test")
            appLink = app
            app.start()
            let appOwns = await waitFor(4) { app.refresh(); return app.panel?.owner == true && app.state.isConnected }
            try? await Task.sleep(for: .milliseconds(500))
            app.refresh()
            let rc2 = status(c)
            summary.reports["C after the app's claim"] = rc2
            let ap = app.panel
            step("the app claims against the extension", appOwns && ap?.lastClaimWaited == true && ap?.lastClaimAcked == true
                    && rc2?.owner == false && rc2?.drops == 1,
                 "app: \(ap?.line ?? "?"), waited \(ap?.lastClaimWaited ?? false) acked \(ap?.lastClaimAcked ?? false) in \(ap?.lastClaimWaitMs ?? 0) ms; C: \(rc2?.line ?? "?"), drops \(rc2?.drops ?? -1)")
            _ = call(c, "claim")
            let cBack = await waitFor(5) { self.status(c).map { $0.owner && $0.link.hasPrefix("Connected") } ?? false }
            try? await Task.sleep(for: .milliseconds(300))
            app.refresh()
            let rc3 = status(c)
            summary.reports["C takes it back from the app"] = rc3
            step("the extension claims back from the app", cBack && rc3?.claimAcked == true && app.panel?.owner == false
                    && (app.panel?.drops ?? 0) == 1,
                 "C: \(rc3?.line ?? "?"), waited \(rc3?.claimWaited ?? false) acked \(rc3?.claimAcked ?? false) in \(rc3?.claimWaitMs ?? -1) ms; app: \(app.panel?.line ?? "?"), drops \(app.panel?.drops ?? 0)")
            app.shutdown()
            appLink = nil
        }
    }

    // MARK: helpers

    private func make(_ label: String, core: String?, context: String) async -> AVAudioUnit? {
        do {
            let u = try await AVAudioUnit.instantiate(with: desc, options: .loadOutOfProcess)
            u.auAudioUnit.contextName = context
            units[label] = u
            try? await Task.sleep(for: .milliseconds(400))
            if let core { _ = call(u, "core", ["id": core]) }
            let vc = await withCheckedContinuation { (k: CheckedContinuation<UIViewControllerBox, Never>) in
                u.auAudioUnit.requestViewController { vc in k.resume(returning: UIViewControllerBox(vc: vc)) }
            }.vc
            if let vc, label == "A" || label == "B" { views.append((label, vc)) }
            let r = status(u)
            step("instantiate \(label)", r != nil,
                 "\(r?.coreName ?? "?") \(r?.coreVersion ?? ""), slot \(r?.slot ?? 0), panel \(r?.backend ?? "?") (\(r?.fakeLabel ?? "")), pid \(r?.pid ?? 0)")
            return u
        } catch {
            step("instantiate \(label)", false, AUTestHost.describe(error))
            return nil
        }
    }

    private func call(_ u: AVAudioUnit, _ cmd: String, _ args: [String: Any] = [:]) -> [AnyHashable: Any] {
        let sel = NSSelectorFromString("messageChannelFor:")
        guard let obj = u.auAudioUnit.perform(sel, with: RFMShared.diagnosticsChannel)?.takeUnretainedValue(),
              let ch = obj as? AUMessageChannel, let call = ch.callAudioUnit
        else { return ["error": "no message channel"] }
        var m: [AnyHashable: Any] = ["cmd": cmd]
        for (k, v) in args { m[k] = v }
        return call(m)
    }

    private func status(_ u: AVAudioUnit) -> AUReport? {
        (call(u, "status")["json"] as? String).flatMap(AUReport.decode)
    }

    private func param(_ u: AVAudioUnit, _ name: String) -> Int? {
        (call(u, "param", ["name": name])["value"] as? NSNumber)?.intValue
    }

    struct Fake {
        var json = "{}"
        var obj: [String: Any] = [:]
        var lastStarter: String { obj["lastStarter"] as? String ?? "" }
        var starts: Int { obj["starts"] as? Int ?? 0 }
        func match(_ l: String) -> Double { (obj["screenMatch"] as? [String: Double])?[l] ?? 0 }
        func pct(_ l: String) -> String { String(format: "%.0f%%", match(l) * 100) }
        struct Sender { var stops = 0, afterOther = 0, afterOtherTiles = 0 }
        func sender(_ l: String) -> Sender? {
            guard let s = (obj["senders"] as? [[String: Any]])?.first(where: { $0["label"] as? String == l }) else { return nil }
            return Sender(stops: s["stops"] as? Int ?? -1, afterOther: s["afterOther"] as? Int ?? -1,
                          afterOtherTiles: s["afterOtherTiles"] as? Int ?? -1)
        }
    }

    private func fake(_ u: AVAudioUnit) -> Fake {
        let j = call(u, "fake")["json"] as? String ?? "{}"
        let o = (try? JSONSerialization.jsonObject(with: Data(j.utf8))) as? [String: Any] ?? [:]
        return Fake(json: j, obj: o)
    }

    private func waitFor(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    /// a marker for scripts/sim_aucoretest.sh, then 3 s for its screenshot
    private func screenshot(_ what: String) async {
        shot += 1
        try? await Task.sleep(for: .milliseconds(700))         // (the views catch up)
        let obj: [String: Any] = ["shot": shot, "what": what, "time": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            for d in AUTestHost.outputDirs() { try? data.write(to: d.appendingPathComponent("aucoretest-shot-\(shot).json")) }
        }
        try? await Task.sleep(for: .seconds(3))
    }

    private func step(_ name: String, _ ok: Bool?, _ detail: String) {
        summary.steps.append(.init(id: summary.steps.count, name: name, ok: ok, detail: detail))
        log.info("aucoretest step \(name, privacy: .public): \(ok.map { $0 ? "ok" : "FAILED" } ?? "-", privacy: .public) \(detail, privacy: .public)")
    }

    private func finish() {
        summary.done = true
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(summary) else { return }
        for d in AUTestHost.outputDirs() { try? data.write(to: d.appendingPathComponent("aucoretest.json"), options: .atomic) }
    }
}

/// The two instances' own views (A above B), then the steps
struct AUCoreTestView: View {
    @State var host: AUCoreTestHost

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("AU core test").font(.headline)
                ForEach(host.views, id: \.0) { v in
                    Text("Track \(v.0)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    EmbeddedAUView(vc: v.1)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DebugTheme.line))
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(host.summary.steps) { s in
                        Text("\(s.ok.map { $0 ? "ok" : "NO" } ?? "–") \(s.name): \(s.detail)")
                            .foregroundStyle(s.ok == false ? Color.red : .primary)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .padding(10)
        }
        .background(DebugTheme.background.ignoresSafeArea())
        .task { await host.run() }
    }
}

/// a UIKit view controller (the AU's) as a child of a plain container
private struct EmbeddedAUView: UIViewControllerRepresentable {
    let vc: UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        let c = UIViewController()
        c.addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        c.view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: c.view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: c.view.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: c.view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: c.view.bottomAnchor),
        ])
        vc.didMove(toParent: c)
        return c
    }

    func updateUIViewController(_ c: UIViewController, context: Context) {}
}
