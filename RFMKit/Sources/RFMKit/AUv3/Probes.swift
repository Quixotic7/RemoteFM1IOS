// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// M2's probes (PLAN.md section 5), the same code in the app and in the AUv3 extension: CoreMIDI from this process,
// the App Group (a file each way, an mmap'd shared file, a Darwin notification each way, notify(3) state), memory,
// a thread, and the process. Each report is written as JSON (probe-<role>.json) where the shell can read it, and
// logged (subsystem com.quixotic7.remotefm1, category probe).
//
// CoreMIDI is only read: a client and two ports are created (and the ports disposed at once), the endpoint list is
// read, and nothing is ever sent or connected.

import Foundation
import RFMCore
import os
#if canImport(CoreMIDI)
import CoreMIDI
#endif

public enum ProbeRole: String, Codable, Sendable {
    case app, ext

    var other: ProbeRole { self == .app ? .ext : .app }
    var slot: Int32 { self == .app ? 0 : 1 }          // in the shared file
}

public struct ProbeReport: Codable, Sendable, Equatable {
    public struct MIDI: Codable, Sendable, Equatable {
        public var clientStatus: Int32 = 0          // MIDIClientCreateWithBlock's OSStatus
        public var inPortStatus: Int32 = 0
        public var outPortStatus: Int32 = 0
        public var notifications = 0                // the client's notify block calls so far
        public var sources: [String] = []
        public var destinations: [String] = []
        public var candidates: [String] = []        // what RemoteCandidates (RemoteMidi.c's scan) would offer HELLO to
    }
    public struct Other: Codable, Sendable, Equatable {
        public var pid: Int32
        public var instance: String?
        public var time: Double
    }
    public struct Group: Codable, Sendable, Equatable {
        public var id = RFMShared.appGroup
        public var container: String?               // nil: no working group in this process
        public var wroteFile = false
        public var otherFile: Other?                // the other process's probe file, read from the group
        public var mmapOK = false
        public var mmapShared = false               // the file is in the group container (else tmp: this process only)
        public var mmapErrno: Int32 = 0
        public var mmapCounter: UInt64 = 0
        public var mmapOtherPid: Int32?             // the other role's last writer seen in the file
        public var darwinPosted = ""
        public var darwinReceived: UInt32 = 0       // the other process's pings seen here
        public var notifySetStatus: UInt32 = 0
        public var notifyGetStatus: UInt32 = 0
        public var notifyOther: UInt64 = 0          // the other process's notify state (its pid << 32 | counter)
    }
    public struct Memory: Codable, Sendable, Equatable {
        public var available: Int64 = -1            // os_proc_available_memory(); -1: not on this OS
        public var footprint: Int64 = -1            // task_info phys_footprint
    }
    public struct Thread: Codable, Sendable, Equatable {
        public var started = false
        public var ticks: UInt64 = 0                // a 5 ms tick
    }
    public struct Render: Codable, Sendable, Equatable {
        public var renders: UInt64 = 0
        public var frames: UInt64 = 0
        public var midiEvents: UInt64 = 0
        public var lastMIDI: [UInt8] = []
        public var sampleRate: Double = 0
        public var maxFrames: UInt32 = 0
    }

    public var role: ProbeRole
    public var pid: Int32
    public var process: String
    public var bundleID: String
    public var simulator: Bool
    public var instance: String?                    // the AU instance's UUID (ext)
    public var time: Double                         // seconds since 1970
    public var midi: MIDI?
    public var group = Group()
    public var memory = Memory()
    public var thread = Thread()
    public var render: Render?                      // ext: the render kernel's counters
    public var file: String?                        // where this report was written

    public init(role: ProbeRole, pid: Int32, process: String, bundleID: String, simulator: Bool, instance: String?,
                time: Double) {
        self.role = role
        self.pid = pid
        self.process = process
        self.bundleID = bundleID
        self.simulator = simulator
        self.instance = instance
        self.time = time
    }

    public func json(pretty: Bool = true) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func decode(_ data: Data) -> ProbeReport? { try? JSONDecoder().decode(ProbeReport.self, from: data) }

    /// The short lines the Diagnostics panels show
    public var lines: [(String, String)] {
        var r: [(String, String)] = []
        r.append(("process", "\(role.rawValue) pid \(pid)" + (simulator ? ", simulator" : "")))
        if let instance { r.append(("instance", String(instance.prefix(8)))) }
        if let m = midi {
            r.append(("CoreMIDI", "client \(m.clientStatus), ports in \(m.inPortStatus) out \(m.outPortStatus), "
                      + "\(m.notifications) notif."))
            r.append(("endpoints", "\(m.sources.count) src, \(m.destinations.count) dst"))
            r.append(("candidates", m.candidates.isEmpty ? "none" : m.candidates.joined(separator: ", ")))
        }
        let g = group
        r.append(("group", g.container == nil ? "no container" : "container ok" + (g.wroteFile ? ", wrote" : "")))
        r.append(("other file", g.otherFile.map { "pid \($0.pid)" } ?? "not seen"))
        r.append(("mmap", g.mmapOK ? "ok\(g.mmapShared ? "" : " (not shared)"), counter \(g.mmapCounter), other "
                  + (g.mmapOtherPid.map { "pid \($0)" } ?? "none") : "failed (errno \(g.mmapErrno))"))
        r.append(("darwin", "\(g.darwinReceived) received"))
        r.append(("notify", "set \(g.notifySetStatus) get \(g.notifyGetStatus), other "
                  + (g.notifyOther == 0 ? "none" : "pid \(g.notifyOther >> 32)")))
        r.append(("memory", "available \(Self.mb(memory.available)), footprint \(Self.mb(memory.footprint))"))
        r.append(("thread", thread.started ? "running, \(thread.ticks) ticks" : "did not start"))
        if let x = render {
            r.append(("render", "\(x.renders) renders, \(x.frames) frames, \(x.midiEvents) MIDI"
                      + (x.lastMIDI.isEmpty ? "" : " (last " + x.lastMIDI.map { String(format: "%02X", $0) }
                         .joined(separator: " ") + ")")))
        }
        return r
    }

    static func mb(_ v: Int64) -> String { v < 0 ? "n/a" : String(format: "%.1f MB", Double(v) / 1_048_576) }
}

/// One process's probe. start() once (on the main thread: CoreMIDI delivers the client's notifications there), then
/// ping() to tell the other process and report() whenever: report() re-reads everything and writes the file.
public final class Probe: @unchecked Sendable {
    public let role: ProbeRole
    private let lock = NSLock()
    private let log = RFMShared.log("probe")
    private var instance: String?
    private var started = false
    private var shm: OpaquePointer?
    private var shmErrno: Int32 = 0
    private var notifySet: UInt32 = 0
    private var ticker: OpaquePointer?
    private var tickerOK: Int32 = 0
    private var midi: ProbeReport.MIDI?
    private var counter: UInt64 = 0
    /// the extension's thread and render counters (its render kernel); nil: the probe's own ticker
    private let kernel: (@Sendable () -> (thread: ProbeReport.Thread, render: ProbeReport.Render))?
    private let includeMIDI: Bool
    private let dir: URL
    private let shared: Bool                    // dir is the App Group container
    #if canImport(CoreMIDI)
    private var client = MIDIClientRef()
    private let notifications = OSAllocatedUnfairLock(initialState: 0)
    #endif

    /// includeMIDI false: no CoreMIDI at all; directory: instead of RFMShared.outputDirectory() (both for the Mac tests)
    public init(role: ProbeRole, instance: String? = nil, includeMIDI: Bool = true, directory: URL? = nil,
                kernel: (@Sendable () -> (thread: ProbeReport.Thread, render: ProbeReport.Render))? = nil) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            (dir, shared) = (directory, false)
        } else {
            (dir, shared) = RFMShared.outputDirectory()
        }
        self.role = role
        self.instance = instance
        self.includeMIDI = includeMIDI
        self.kernel = kernel
    }

    deinit {
        if let shm { rfmp_shm_close(shm) }
        if let ticker { rfmp_ticker_stop(ticker) }
        #if canImport(CoreMIDI)
        if client != 0 { MIDIClientDispose(client) }
        #endif
    }

    public func setInstance(_ s: String?) { lock.withLock { instance = s } }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        #if canImport(CoreMIDI)
        if includeMIDI { midi = startMIDI() }
        #endif
        rfmp_darwin_observe(RFMShared.name("ping", role.other))
        var err: Int32 = 0
        shm = rfmp_shm_open(dir.appendingPathComponent("lease-probe.bin").path, &err)
        shmErrno = err
        if kernel == nil { ticker = rfmp_ticker_start(&tickerOK) }
        log.info("probe \(self.role.rawValue, privacy: .public) started, pid \(getpid())")
    }

    /// Tells the other process: a Darwin notification, our notify(3) state, our slot in the shared file
    public func ping() {
        lock.lock()
        defer { lock.unlock() }
        if let shm { counter = rfmp_shm_bump(shm, role.slot) }
        notifySet = rfmp_notify_set(RFMShared.name("state", role), UInt64(UInt32(bitPattern: getpid())) << 32 | counter)
        rfmp_darwin_post(RFMShared.name("ping", role))
    }

    @discardableResult
    public func report(write: Bool = true) -> ProbeReport {
        lock.lock()
        defer { lock.unlock() }
        let info = ProcessInfo.processInfo
        #if targetEnvironment(simulator)
        let sim = true
        #else
        let sim = false
        #endif
        var r = ProbeReport(role: role, pid: getpid(), process: info.processName,
                            bundleID: Bundle.main.bundleIdentifier ?? "", simulator: sim, instance: instance,
                            time: Date().timeIntervalSince1970)
        #if canImport(CoreMIDI)
        if includeMIDI, var m = midi {
            m.notifications = notifications.withLock { $0 }
            (m.sources, m.destinations) = Self.endpoints()
            m.candidates = Self.candidates()
            r.midi = m
        }
        #endif
        let group = RFMShared.groupContainer()
        r.group.container = group?.path
        if let d = try? Data(contentsOf: dir.appendingPathComponent("probe-\(role.other.rawValue).json")),
           let o = ProbeReport.decode(d) {
            r.group.otherFile = .init(pid: o.pid, instance: o.instance, time: o.time)
        }
        r.group.mmapOK = shm != nil
        r.group.mmapShared = shared
        r.group.mmapErrno = shmErrno
        if let shm {
            var v = rfmp_shm_view_t()
            rfmp_shm_read(shm, &v)
            r.group.mmapCounter = v.counter
            let other = rfmp_shm_slot(&v, role.other.slot)
            if other.seq != 0 { r.group.mmapOtherPid = other.pid }
        }
        r.group.darwinPosted = RFMShared.name("ping", role)
        r.group.darwinReceived = rfmp_darwin_count(RFMShared.name("ping", role.other))
        r.group.notifySetStatus = notifySet
        var ov: UInt64 = 0
        r.group.notifyGetStatus = rfmp_notify_get(RFMShared.name("state", role.other), &ov)
        r.group.notifyOther = ov
        r.memory = .init(available: rfmp_available_memory(), footprint: rfmp_footprint())
        if let kernel {
            let k = kernel()
            r.thread = k.thread
            r.render = k.render
        } else {
            r.thread = .init(started: tickerOK != 0, ticks: rfmp_ticker_ticks(ticker))
        }
        if write {
            let url = dir.appendingPathComponent("probe-\(role.rawValue).json")
            r.file = url.path
            r.group.wroteFile = shared
            do {
                try Data(r.json().utf8).write(to: url, options: .atomic)
            } catch {
                r.group.wroteFile = false
                log.error("probe: cannot write \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("probe \(self.role.rawValue, privacy: .public): \(r.json(pretty: false), privacy: .public)")
        return r
    }

    // MARK: CoreMIDI (read-only)

    #if canImport(CoreMIDI)
    private func startMIDI() -> ProbeReport.MIDI {
        var m = ProbeReport.MIDI()
        let n = notifications
        m.clientStatus = MIDIClientCreateWithBlock("RemoteFM1 probe" as CFString, &client) { _ in
            n.withLock { $0 += 1 }
        }
        guard m.clientStatus == noErr else { client = 0; return m }
        // the ports are created to see that they can be, and disposed at once: never connected, nothing sent
        var inPort = MIDIPortRef(), outPort = MIDIPortRef()
        m.inPortStatus = MIDIInputPortCreateWithProtocol(client, "RemoteFM1 probe in" as CFString, ._1_0, &inPort) { _, _ in }
        m.outPortStatus = MIDIOutputPortCreate(client, "RemoteFM1 probe out" as CFString, &outPort)
        if m.inPortStatus == noErr { MIDIPortDispose(inPort) }
        if m.outPortStatus == noErr { MIDIPortDispose(outPort) }
        return m
    }

    static func endpoints() -> ([String], [String]) {
        let src = (0..<MIDIGetNumberOfSources()).map { name(of: MIDIGetSource($0)) }
        let dst = (0..<MIDIGetNumberOfDestinations()).map { name(of: MIDIGetDestination($0)) }
        return (src, dst)
    }

    static func name(of o: MIDIObjectRef) -> String {
        var s: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(o, kMIDIPropertyDisplayName, &s) != noErr || s == nil {
            MIDIObjectGetStringProperty(o, kMIDIPropertyName, &s)
        }
        return s?.takeRetainedValue() as String? ?? "?"
    }

    static func candidates() -> [String] {
        var c = [rfmp_candidate_t](repeating: rfmp_candidate_t(), count: 16)
        let n = Int(rfmp_midi_candidates(&c, 16))
        return c.prefix(n).map { RemoteController.string($0.name) }
    }
    #endif
}
