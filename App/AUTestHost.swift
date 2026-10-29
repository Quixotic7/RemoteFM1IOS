// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AU test (M2): this app as a minimal AUv3 host for its own extension. It finds the component, loads two
// instances out of process, plays them (silence) on an AVAudioEngine with a MIDI note, collects each instance's
// probe report through the AU's message channel, saves one instance's fullState into a third, shows the AU's view,
// and writes everything to autest.json (Documents, and the App Group container when there is one). With -autest it
// runs by itself at launch and then asks the extension to present its Bluetooth panel (autest-bt.json); with -aupage
// <midi | learn | learn:KN1> (M8) it asks the view for that page instead (autest-page.json).
//
// It never starts the FM-1 link, and the probes never send MIDI or connect to an endpoint.

import AVFoundation
import AudioToolbox
import RFMKit
import SwiftUI
import UIKit

struct AUTestSummary: Codable, Sendable {
    struct Step: Codable, Sendable, Identifiable {
        var id: Int
        var name: String
        var ok: Bool?           // nil: no answer (skipped, or only a device can say)
        var detail: String
    }
    struct Instance: Codable, Sendable {
        var label: String
        var instance: String?
        var pid: Int?
        var report: ProbeReport?
    }

    var done = false
    var started = Date().timeIntervalSince1970
    var device = ""
    var system = ""
    var simulator = false
    var appPid = Int(getpid())
    var steps: [Step] = []
    var components: [String] = []
    var instances: [Instance] = []
    var app: ProbeReport?
}

@MainActor
@Observable
final class AUTestHost {
    private(set) var summary = AUTestSummary()
    private(set) var running = false
    private(set) var auView: UIViewController?
    private(set) var appReport: ProbeReport?

    @ObservationIgnored private let probe = Probe(role: .app)
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var units: [AVAudioUnit] = []
    @ObservationIgnored private let log = RFMShared.log("autest")
    let auto: Bool

    init(auto: Bool) { self.auto = auto }

    // MARK: the run

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        summary = AUTestSummary()
        let dev = UIDevice.current
        summary.device = dev.model + " " + dev.name
        summary.system = dev.systemName + " " + dev.systemVersion
        #if targetEnvironment(simulator)
        summary.simulator = true
        #endif

        // 0: the app's own probes (they also start the app's side of the App Group checks). An extension's file from
        // an earlier run is removed first, so only this run's can be read.
        for dir in Self.outputDirs() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("probe-ext.json"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("autest-bt.json"))
        }
        probe.start()
        probe.ping()
        appReport = probe.report()
        step("app probes", appReport?.midi?.clientStatus == 0, appReport.map(Self.brief) ?? "")

        // 1: the audio session
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, options: [.mixWithOthers])
            try s.setActive(true)
            step("audio session", true, "playback, \(Int(s.sampleRate)) Hz, io buffer \(s.ioBufferDuration)")
        } catch {
            step("audio session", false, Self.describe(error))
        }

        // 2: the component
        let desc = RFMShared.component
        let found = AVAudioUnitComponentManager.shared().components(matching: desc)
        summary.components = found.map {
            "\($0.manufacturerName): \($0.name) v\($0.versionString), sandboxSafe \($0.isSandboxSafe), "
                + "tags \($0.allTagNames)"
        }
        var cd = desc
        let ac = AudioComponentFindNext(nil, &cd)
        step("component found", !found.isEmpty || ac != nil,
             "AVAudioUnitComponentManager: \(found.count); AudioComponentFindNext: \(ac == nil ? "none" : "found")")
        if found.isEmpty && ac == nil {
            return finish()
        }

        // 3: two instances, out of process
        for label in ["A", "B"] {
            do {
                let u = try await AVAudioUnit.instantiate(with: desc, options: .loadOutOfProcess)
                units.append(u)
                step("instantiate \(label)", true, "\(type(of: u)), \(type(of: u.auAudioUnit))")
            } catch {
                step("instantiate \(label)", false, Self.describe(error))
            }
        }
        guard !units.isEmpty else { return finish() }
        try? await Task.sleep(for: .milliseconds(800))           // (the extension's probes run on its main thread)
        let before = units.map { call($0, "report") }

        // 4: the engine: both on the main mixer, silence for 2 s, a note through scheduleMIDIEventBlock
        for u in units {
            engine.attach(u)
            engine.connect(u, to: engine.mainMixerNode, format: nil)
        }
        do {
            try engine.start()
            let a = units[0].auAudioUnit
            let midi = a.scheduleMIDIEventBlock
            var on: [UInt8] = [0x90, 60, 100]
            midi?(AUEventSampleTimeImmediate, 0, 3, &on)
            try? await Task.sleep(for: .seconds(1))
            var off: [UInt8] = [0x80, 60, 0]
            midi?(AUEventSampleTimeImmediate, 0, 3, &off)
            try? await Task.sleep(for: .seconds(1))
            step("engine", true, "ran 2 s, scheduleMIDIEventBlock \(midi == nil ? "nil" : "set"), "
                 + "output \(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)) Hz")
        } catch {
            step("engine", false, Self.describe(error))
        }

        // 5: the other process's side of the App Group checks: ask each instance to ping, then read both sides
        probe.ping()
        for u in units { _ = call(u, "ping") }
        try? await Task.sleep(for: .milliseconds(600))
        let after = units.map { call($0, "report") }
        appReport = probe.report()

        for (i, r) in after.enumerated() {
            summary.instances.append(.init(label: i == 0 ? "A" : "B", instance: r.instance, pid: r.pid, report: r.report))
            let b = before[i].report?.render, x = r.report?.render
            let dr = (x?.renders ?? 0) - min(x?.renders ?? 0, b?.renders ?? 0)
            let dt = (r.report?.thread.ticks ?? 0) - min(r.report?.thread.ticks ?? 0, before[i].report?.thread.ticks ?? 0)
            step("instance \(i == 0 ? "A" : "B") rendered", r.report != nil ? dr > 0 : nil,
                 r.report == nil ? "no report: \(r.error ?? "?")"
                    : "\(dr) renders while running, thread +\(dt) ticks, MIDI \(x?.midiEvents ?? 0)"
                      + (x?.lastMIDI.isEmpty == false ? " last " + x!.lastMIDI.map { String(format: "%02X", $0) }
                         .joined(separator: " ") : ""))
        }
        if let r = after.first?.report { step("extension probes", r.midi?.clientStatus == 0, Self.brief(r)) }
        let pids = after.compactMap(\.pid)
        if pids.count == 2 {
            step("one process for both instances", pids[0] == pids[1], "pids \(pids[0]), \(pids[1]); app \(getpid())")
        }
        if let a = appReport, let x = after.first?.report {
            // each side must see the other's pid from this run (the shared file and notify state outlive a run)
            let g = a.group, xg = x.group, ap = getpid(), xp = Set(after.compactMap { $0.report?.pid })
            let fileOK = g.otherFile.map { xp.contains($0.pid) } == true && xg.otherFile?.pid == ap
            let mmapOK = g.mmapShared && g.mmapOtherPid.map { xp.contains($0) } == true && xg.mmapOtherPid == ap
            let notifyOK = xp.contains(Int32(truncatingIfNeeded: g.notifyOther >> 32))
                && Int32(truncatingIfNeeded: xg.notifyOther >> 32) == ap
            step("App Group container", (g.container != nil && xg.container != nil),
                 "app \(g.container == nil ? "none" : "ok"), extension \(xg.container == nil ? "none" : "ok")")
            step("group file both ways", fileOK,
                 "app read ext's: \(g.otherFile.map { "pid \($0.pid)" } ?? "no"); "
                    + "ext read app's: \(xg.otherFile.map { "pid \($0.pid)" } ?? "no")")
            step("mmap'd shared file", mmapOK,
                 "app: ok \(g.mmapOK) shared \(g.mmapShared) other \(g.mmapOtherPid.map(String.init) ?? "none"); "
                    + "ext: ok \(xg.mmapOK) shared \(xg.mmapShared) other \(xg.mmapOtherPid.map(String.init) ?? "none")")
            step("Darwin notification both ways", g.darwinReceived > 0 && xg.darwinReceived > 0,
                 "app received \(g.darwinReceived), ext received \(xg.darwinReceived)")
            step("notify(3) state both ways", notifyOK,
                 "app sees ext pid \(g.notifyOther >> 32) (get \(g.notifyGetStatus)); "
                    + "ext sees app pid \(xg.notifyOther >> 32) (get \(xg.notifyGetStatus), set \(xg.notifySetStatus))")
            step("extension memory", nil,
                 "os_proc_available_memory \(x.memory.available), footprint \(x.memory.footprint)")
            step("extension CoreMIDI", x.midi?.clientStatus == 0,
                 x.midi.map { "client \($0.clientStatus), in port \($0.inPortStatus), out port \($0.outPortStatus); "
                    + "\($0.sources.count) sources \($0.sources), \($0.destinations.count) destinations, "
                    + "candidates \($0.candidates)" } ?? "no result")
        }

        // 6: state: A's fullState into a new instance C while A lives: a duplicate (M4), so C must get a new UUID
        if let a = units.first, let saved = a.auAudioUnit.fullState {
            let want = InstanceState(saved)?.instance.uuidString
            do {
                let c = try await AVAudioUnit.instantiate(with: desc, options: .loadOutOfProcess)
                let fresh = call(c, "report").instance
                c.auAudioUnit.fullState = saved
                let got = call(c, "report")
                let fromState = InstanceState(c.auAudioUnit.fullState)?.instance.uuidString
                summary.instances.append(.init(label: "C", instance: got.instance, pid: got.pid, report: got.report))
                // (M4: A is still alive in the same process, so C is a duplicate: it takes a new UUID, PLAN.md
                // section 4; the restore of an owner's UUID is in -aucoretest)
                step("fullState restore (a duplicate of a live A)",
                     want != nil && got.instance != nil && got.instance != want && fromState == got.instance,
                     "A \(Self.short(want)), C new \(Self.short(fresh)), C restored \(Self.short(got.instance)), "
                        + "C's fullState \(Self.short(fromState)); keys \(saved.keys.sorted())")
                units.append(c)
            } catch {
                step("fullState restore", false, "instantiate C: \(Self.describe(error))")
            }
        } else {
            step("fullState restore", false, "A has no fullState")
        }

        // 7: A's view
        if let a = units.first {
            let vc = await withCheckedContinuation { (k: CheckedContinuation<UIViewControllerBox, Never>) in
                a.auAudioUnit.requestViewController { vc in k.resume(returning: UIViewControllerBox(vc: vc)) }
            }.vc
            auView = vc
            try? await Task.sleep(for: .milliseconds(500))
            log.info("AU view in the host: \(vc.map { "\($0.view.frame), window \($0.view.window != nil)" } ?? "nil", privacy: .public)")
            step("view controller", vc != nil, vc.map { "\(type(of: $0)), preferred \($0.preferredContentSize)" } ?? "nil")
        }
        finish()

        if auto, let i = CommandLine.arguments.firstIndex(of: "-aupage"), i + 1 < CommandLine.arguments.count {
            // (M8) a page of the AU's view instead (scripts/sim_autest.sh AUPAGE=midi | learn | learn:KN1)
            try? await Task.sleep(for: .seconds(2))
            let what = CommandLine.arguments[i + 1]
            let r = units.first.map { call($0, "show", ["what": what]) }
            try? await Task.sleep(for: .seconds(1))
            write(["page": what, "reply": r?.error ?? "ok", "time": Date().timeIntervalSince1970], name: "autest-page.json")
        } else if auto {
            // the Bluetooth panel inside the extension's view, for the second screenshot
            try? await Task.sleep(for: .seconds(3))
            let r = units.first.map { call($0, "bluetooth") }
            try? await Task.sleep(for: .seconds(1))
            write(["requested": true, "reply": r?.error ?? "ok", "time": Date().timeIntervalSince1970],
                  name: "autest-bt.json")
            // the panel's view loaded in the app too (BTMIDICentralViewController: see BluetoothSheet.swift)
            let scr = UIScreen.main
            var info: [String: Any] = ["screen": "\(scr.bounds)", "applicationFrame": "\(scr.applicationFrame)",
                                       "statusBar": "\(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.statusBarManager?.statusBarFrame })"]
            info["ownTable"] = bluetoothPanelUsesOwnTable
            let nav = bluetoothPanelController(done: true)
            info["loaded"] = "\(nav.topViewController?.view.bounds.size ?? .zero)"
            write(info, name: "autest-appbt.json")
        }
    }

    // MARK: helpers

    private func finish() {
        summary.app = appReport
        summary.done = true
        do {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try e.encode(summary)
            for dir in Self.outputDirs() {
                try data.write(to: dir.appendingPathComponent("autest.json"), options: .atomic)
            }
            log.info("autest: \(String(decoding: data, as: UTF8.self), privacy: .public)")
        } catch {
            log.error("autest: cannot write the summary: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write(_ obj: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        for dir in Self.outputDirs() { try? data.write(to: dir.appendingPathComponent(name), options: .atomic) }
    }

    /// Documents (always: the script reads the app's data container) and the App Group container if it works
    static func outputDirs() -> [URL] {
        var d: [URL] = []
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            d.append(docs)
        }
        if let g = RFMShared.groupContainer() { d.append(g) }
        return d
    }

    private func step(_ name: String, _ ok: Bool?, _ detail: String) {
        summary.steps.append(.init(id: summary.steps.count, name: name, ok: ok, detail: detail))
        log.info("autest step \(name, privacy: .public): \(ok.map { $0 ? "ok" : "FAILED" } ?? "-", privacy: .public) \(detail, privacy: .public)")
    }

    struct Reply {
        var instance: String?
        var pid: Int?
        var report: ProbeReport?
        var error: String?
    }

    /// one message to the instance's diagnostics channel (AUMessageChannel: works out of process)
    private func call(_ u: AVAudioUnit, _ cmd: String, _ extra: [String: Any] = [:]) -> Reply {
        // (through the ObjC runtime: an extension that died gives a nil channel, which the Swift signature can't hold)
        let sel = NSSelectorFromString("messageChannelFor:")
        guard let obj = u.auAudioUnit.perform(sel, with: RFMShared.diagnosticsChannel)?.takeUnretainedValue(),
              let ch = obj as? AUMessageChannel, let call = ch.callAudioUnit
        else { return Reply(error: "no message channel (the extension may have exited)") }
        var msg: [AnyHashable: Any] = ["cmd": cmd]
        for (k, v) in extra { msg[k] = v }
        let m = call(msg)
        var r = Reply(instance: m["instance"] as? String, pid: (m["pid"] as? NSNumber)?.intValue)
        if let j = m["json"] as? String { r.report = ProbeReport.decode(Data(j.utf8)) }
        if r.instance == nil && m["ok"] == nil { r.error = "empty reply: \(m)" }
        return r
    }

    static func brief(_ r: ProbeReport) -> String {
        r.lines.map { "\($0.0): \($0.1)" }.joined(separator: "; ")
    }

    static func short(_ s: String?) -> String { s.map { String($0.prefix(8)) } ?? "nil" }

    static func describe(_ e: Error) -> String {
        let n = e as NSError
        return "\(n.domain) \(n.code): \(n.localizedDescription)"
    }
}

struct UIViewControllerBox: @unchecked Sendable { let vc: UIViewController? }
