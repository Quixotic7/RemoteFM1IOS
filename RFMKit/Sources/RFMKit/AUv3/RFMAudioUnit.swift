// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AUv3 instrument. M2: one stereo output bus, MIDI in, a C++ render kernel (RFMCore's RFMKernel), the instance
// UUID in fullState, and a message channel for the probes. M4: the instance plays a firmware core and shares one FM-1
// with every other instance (PLAN.md section 4):
//
//   the core     a core from the app bundle's slot frameworks (ChoralRoot, Felucca, Melodee, FIZZ, Saadet, Boardwalk, LOOM-8; a store build: FIZZ, Saadet, Boardwalk, LOOM-8) (rfms_scan finds
//                <appex>/../../Frameworks); loaded and booted off the render thread (the caller's, under `ctl`),
//                the clock handed over explicitly: the render callback while render resources are allocated
//                (RFME_CLOCK_AUDIO), the engine's timer otherwise (the panel keeps working, no sound). A core this
//                build doesn't have (a default, a restored state): the first it has, with a note (Status.coreNote)
//   MIDI         the host's MIDI to the core at its frame (FM1VST's mapping); the core's MIDI out to the host's
//                MIDI output (midiOutputNames, MIDIOutputEventBlock)
//   fullState    the instance UUID and format (InstanceState), the core, its version, its flash (flash_sync first,
//                LZFSE) and the settings (CoreState); restoring boots the core from that flash
//   the panel    a RemoteLink of its own (CoreMIDI, or on the simulator the process-wide shared fake unit) run only
//                while this instance holds the lease (PanelSession)
//   halted       exit code 0 (0x100): powered on again from its flash; otherwise it stays halted (restartCore())
//   M7           imported .rfm1 firmware too (the app's mirror in the App Group: FirmwareCatalog), run in wasm3; the
//                catalog keys (CoreInfo.id) pick a core; fullState keeps its kind and SHA-256 and a restore resolves
//                them (CoreRef.resolve: the same file, else the same firmware with a note, else as before)
//
// It lives in RFMKit, not in the extension, so the Mac tests can create and render it directly.

import AVFoundation
import AudioToolbox
import CoreGraphics
import Foundation
import RFMCore

public final class RFMAudioUnit: RFMAudioUnitBase, @unchecked Sendable {
    public struct Config: Sendable {
        public enum Link: Sendable, Equatable {
            case none                           // no panel (the Mac tests of M2)
            case fake                           // a fake unit of its own
            case sharedFake                     // the process-wide shared fake unit
            case device                         // CoreMIDI (FM-1 candidates only)
            case auto                           // device; the simulator: the shared fake; the App Group file decides
        }
        public var runProbes = true
        public var defaultCore: String? = ""    // "": the first this build has; nil: none; one it lacks: the first, with a note
        public var link: Link = .auto
        public var panel = PanelSession.Config()
        public var slotsDir: String?            // nil: the bundle (and from an appex the app's) Frameworks
        public init() {}
    }

    private let kernel: OpaquePointer
    let e: OpaquePointer                        // rfme_t (the faceplate plays it: PanelEngineHost)
    private let link: OpaquePointer?            // rfmc_t
    public let session: PanelSession?
    public let backend: String                  // "none", "fake", "shared fake", "device"
    public let fakeLabel: String
    private let outBus: AUAudioUnitBus
    private var outputs: AUAudioUnitBusArray!
    private var inputs: AUAudioUnitBusArray!
    private let lock = NSLock()                 // instanceState, channel
    private let ctl = NSLock()                  // the core: load, boot, power cycle, flash, settings
    let pvLock = NSLock()                       // the preview (rfme_preview has one reader at a time)
    private var instanceState = InstanceState()
    private var coreID: String?                 // the catalog key of the core asked for (CoreInfo.id)
    private var coreInfo: CoreInfo?             // its entry when it was loaded
    private var coreError = ""
    private var coreNote = ""                   // a core asked for that this build doesn't have
    private var unrestored: CoreState?          // a restored state whose core is missing here: saved back as it was
    private var settings_ = AUSettings()
    private var bootedFrom = ""
    private var powerCycles = 0
    private var lastName = ""
    private var pvSeq: UInt32 = 0
    private var pvRGBA = [UInt8](repeating: 0, count: Int(RFMC_W * RFMC_H * 4))
    private var timer: DispatchSourceTimer?
    private var lastLatency: UInt32 = 0
    private let log = RFMShared.log("au")
    private var channel: DiagnosticsChannel?

    public let probe: Probe
    /// Called (on any thread) when the instance's identity changed (a restored state) or a host asked for the
    /// Bluetooth panel. The extension's view controller sets it.
    public nonisolated(unsafe) var onEvent: (@Sendable (Event) -> Void)?
    public enum Event: Sendable { case stateRestored, bluetoothRequested }

    public init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = [],
                config: Config) throws {
        let k = rfmk_new()!
        kernel = k
        let ref = KernelRef(p: k)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rfm-au-\(UUID().uuidString)")
        probe = Probe(role: .ext, includeMIDI: config.runProbes, directory: config.runProbes ? nil : tmp) {
            var s = rfmk_stats_t()
            rfmk_stats(ref.p, &s)
            let last = Array(withUnsafeBytes(of: s.last_midi) { Array($0) }.prefix(Int(s.last_midi_len)))
            return (.init(started: s.thread_ok != 0, ticks: s.ticks),
                    .init(renders: s.renders, frames: s.frames, midiEvents: s.midi_events, lastMIDI: last,
                          sampleRate: s.sample_rate, maxFrames: s.max_frames))
        }

        // the panel's link
        var mode = config.link
        if mode == .auto {
            #if targetEnvironment(simulator)
            mode = RFMShared.extensionBackend() == "device" ? .device : .sharedFake
            #else
            mode = RFMShared.extensionBackend() == "fake" ? .sharedFake : .device
            #endif
        }
        let state = InstanceState()
        let label = "AU-" + String(state.instance.uuidString.prefix(8))
        fakeLabel = mode == .sharedFake || mode == .fake ? label : ""
        backend = ["none": "none", "fake": "fake", "shared": "shared fake", "device": "device"][
            mode == .none ? "none" : mode == .fake ? "fake" : mode == .sharedFake ? "shared" : "device"]!
        if mode != .none {
            var cfg = rfmc_cfg_t()
            cfg.backend = Int32(mode == .device ? RFMC_DEVICE : RFMC_FAKE)
            cfg.shared_fake = mode == .sharedFake ? 1 : 0
            cfg.fps = 20
            link = "RemoteFM1 AU".withCString { hn in label.withCString { lb in
                cfg.host_name = hn
                cfg.label = lb
                cfg.lock_path = nil                 // (no unit lock: the lease decides)
                return rfmc_new(&cfg)
            } }
        } else {
            link = nil
        }
        e = rfme_new(link)
        rfmk_set_engine(k, e)
        instanceState = state

        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else {
            rfmk_free(k)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        outBus = try AUAudioUnitBus(format: fmt)
        outBus.maximumChannelCount = 2
        if let link {
            var pc = config.panel
            pc.fake = mode != .device
            session = PanelSession(link: link, identity: state.instance, name: "RemoteFM1 AU", config: pc)
        } else {
            session = nil
        }
        try super.init(componentDescription: componentDescription, options: options)
        rfmSetRenderContextEngine(e)            // (the core thread joins the host's render workgroup: RFMKernel.h)
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [])
        maximumFramesToRender = 4096
        probe.setInstance(instanceState.instance.uuidString)
        Self.register(self)

        // the core (a new instance: the default firmware, a fresh flash; a restored state replaces it)
        if let d = config.slotsDir { rfms_scan(d) } else if rfms_count() == 0 { rfms_scan(nil) }
        if link != nil { rfme_attach(e, 1) }
        if let want = config.defaultCore,
           let id = want.isEmpty ? CorePlayer.pick(nil, in: CorePlayer.catalog()) : want {
            _ = ctl.withLock { loadLocked(id, flash: nil, from: "a fresh flash") }
        }
        rfme_set_clock(e, Int32(RFME_CLOCK_TIMER))
        updateName()
        session?.appeared()
        log.info("instance \(self.instanceState.short, privacy: .public) created, pid \(getpid()), panel \(self.backend, privacy: .public)")
        if config.runProbes {
            let p = probe
            // CoreMIDI delivers a client's notifications on the run loop it was created on: the main thread's
            DispatchQueue.main.async {
                p.start()
                p.ping()
                p.report()
            }
        }
        startTimer()
    }

    /// M2's: runProbes false is the Mac tests' AU (no core, no panel, no CoreMIDI)
    public convenience init(componentDescription: AudioComponentDescription,
                            options: AudioComponentInstantiationOptions = [], runProbes: Bool) throws {
        var c = Config()
        c.runProbes = runProbes
        if !runProbes {
            c.defaultCore = nil
            c.link = .none
        }
        try self.init(componentDescription: componentDescription, options: options, config: c)
    }

    public override convenience init(componentDescription: AudioComponentDescription,
                                     options: AudioComponentInstantiationOptions = []) throws {
        try self.init(componentDescription: componentDescription, options: options, config: Config())
    }

    deinit {
        timer?.cancel()
        Self.unregister(self)
        rfmSetRenderContextEngine(nil)
        rfme_free(e)                            // (the clock stopped, the slot released; before the link goes)
        if let session { session.finish() }     // (the link and the lease freed in the background)
        rfmk_free(kernel)
    }

    public var state: InstanceState { lock.withLock { instanceState } }

    // MARK: AUAudioUnit

    public override var outputBusses: AUAudioUnitBusArray { outputs }
    public override var inputBusses: AUAudioUnitBusArray { inputs }
    public override var isMusicDeviceOrEffect: Bool { true }
    public override var virtualMIDICableCount: Int { 1 }
    public override var midiOutputNames: [String] { ["RemoteFM1"] }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let f = outBus.format
        if rfmk_allocate(kernel, f.sampleRate, f.channelCount, maximumFramesToRender) == 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        rfmk_set_midi_out(kernel, midiOutputEventBlock)
        rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))     // (the core thread renders ahead of the host's callback)
    }

    /// A host's offline render (a bounce, faster than real time): each render waits for the core thread instead of
    /// playing silence where its frames aren't made yet
    public override var isRenderingOffline: Bool {
        didSet { rfme_set_offline(e, isRenderingOffline ? 1 : 0) }
    }

    /// The core thread renders ahead of the host (RFMEngine.h, render ahead): this much later than the host's time,
    /// host MIDI included. Before the first render: as it will be with buffers of up to 512 frames
    public override var latency: TimeInterval {
        let rate = outBus.format.sampleRate
        guard rate > 0 else { return 0 }
        return Double(rfme_latency(e, rate, UInt32(min(maximumFramesToRender, 512)))) / rate
    }

    public override func deallocateRenderResources() {
        rfme_set_clock(e, Int32(RFME_CLOCK_TIMER))     // (the core thread runs by the wall clock again)
        rfmk_set_midi_out(kernel, nil)
        rfmk_deallocate(kernel)
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock { rfmk_render_block(kernel) }

    public override var fullState: [String: Any]? {
        get {
            var s = super.fullState ?? [:]
            state.encode(into: &s)
            if let c = coreStateForSave() { c.encode(into: &s) }
            return s
        }
        set {
            // (not passed to super: AUAudioUnit's own setter only reads a v2 unit's "data", and logs "no data")
            guard let restored = InstanceState(newValue) else { return }
            if let c = CoreState(newValue) {
                ctl.withLock {
                    settings_ = c.settings
                    applySettingsLocked()
                    let cores = CorePlayer.catalog()
                    guard let r = c.ref.resolve(in: cores) else {
                        coreError = "no firmware in this build"
                        unrestored = c
                        return
                    }
                    if let i = cores.first(where: { $0.id == r.key }), r.keepFlash, !c.version.isEmpty, i.version != c.version {
                        log.info("restore: \(c.core, privacy: .public) \(c.version, privacy: .public) saved, \(i.version, privacy: .public) here: booting from the saved flash anyway")
                    }
                    let flash = r.keepFlash ? c.flash : nil
                    _ = loadLocked(r.key, flash: flash, from: !r.keepFlash ? "a fresh flash"
                                   : flash == nil ? "a fresh flash (none saved)" : "the saved flash")
                    coreNote = r.note
                    unrestored = r.keepFlash ? nil : c
                    if !r.keepFlash && !coreNote.isEmpty { coreNote += " (the saved state is kept)" }
                    log.info("restore: \(c.kind, privacy: .public) \(c.core, privacy: .public) \(c.version, privacy: .public) \(c.sha256.prefix(12), privacy: .public) -> \(r.key, privacy: .public)\(r.note.isEmpty ? "" : ": " + r.note, privacy: .public)")
                }
            }
            let id = session?.restore(restored.instance) ?? restored.instance
            lock.withLock { instanceState = InstanceState(instance: id) }
            probe.setInstance(id.uuidString)
            updateName()
            log.info("instance \(restored.short, privacy: .public) restored from state, format \(restored.format)\(id == restored.instance ? "" : ": a duplicate, now \(String(id.uuidString.prefix(8)))", privacy: .public)")
            onEvent?(.stateRestored)
        }
    }

    public override func messageChannel(for channelName: String) -> any AUMessageChannel {
        guard channelName == RFMShared.diagnosticsChannel else { return super.messageChannel(for: channelName) }
        return lock.withLock {
            if channel == nil { channel = DiagnosticsChannel(owner: self) }
            return channel!
        }
    }

    // MARK: the core (any thread but the render thread)

    /// the cores this instance can pick
    public var cores: [CoreInfo] { CorePlayer.catalog() }

    /// loads the catalog key `id` with a fresh flash (the old core's flash is not kept: the host's project holds an
    /// instance's flash)
    public func selectCore(_ id: String) {
        ctl.withLock {
            guard CorePlayer.catalog().contains(where: { $0.id == id }) else {
                coreNote = "\(id) is not in this build"
                return
            }
            guard id != coreID || !CorePlayer.status(e).booted else { return }
            unrestored = nil
            _ = loadLocked(id, flash: nil, from: "a fresh flash")
        }
        updateName()
    }

    /// the firmware powered off and on again from its flash (a halted core, or the user's Restart)
    public func restartCore() {
        ctl.withLock {
            guard coreID != nil else { return }
            var err = [CChar](repeating: 0, count: 256)
            if rfme_power_cycle(e, &err, 256) == 0 {
                coreError = "restart failed: " + CorePlayer.string(err)
            } else {
                powerCycles += 1
                coreError = ""
            }
            var scratch = [UInt8](repeating: 0, count: Int(rfme_flash_size(e)))
            _ = scratch.withUnsafeMutableBufferPointer { rfme_take_flash(e, $0.baseAddress, UInt32($0.count)) }
        }
    }

    public var settings: AUSettings {
        get { ctl.withLock { settings_ } }
        set { ctl.withLock { settings_ = newValue; applySettingsLocked() } }
    }

    private func applySettingsLocked() {
        rfme_set_midi(e, settings_.notesPlayKeys ? 1 : 0, Int32(settings_.transpose), settings_.keyNotesToFirmware ? 1 : 0)
    }

    /// (ctl held) the core loaded into a free slot and booted; the clock given back to its owner
    private func loadLocked(_ wanted: String, flash wantedFlash: Data?, from wantedFrom: String) -> Bool {
        var id = wanted, flash = wantedFlash, from = wantedFrom
        coreNote = ""
        let cores = CorePlayer.catalog()
        var info = cores.first { $0.id == wanted }
        if info == nil, let use = CorePlayer.pick(nil, in: cores) {     // (another core's flash means nothing to this one)
            coreNote = CorePlayer.missingNote(wanted, use, cores)
            log.error("load \(wanted, privacy: .public): not in this build, \(use, privacy: .public) instead")
            id = use
            info = cores.first { $0.id == use }
            flash = nil
            from = "a fresh flash"
        }
        coreInfo = info
        var err = [CChar](repeating: 0, count: 512)
        let loaded = info?.imported == true ? rfme_load_wasm(e, info!.path, &err, 512) : rfme_load(e, id, &err, 512)
        guard loaded != 0 else {
            coreError = CorePlayer.string(err)
            coreID = id
            log.error("load \(id, privacy: .public): \(self.coreError, privacy: .public)")
            return false
        }
        let ok: Int32
        if let flash, !flash.isEmpty {
            ok = flash.withUnsafeBytes { rfme_boot(e, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) }
        } else {
            ok = rfme_boot(e, nil, 0)
        }
        applySettingsLocked()
        coreID = id
        coreError = ok != 0 ? "" : "boot failed"
        bootedFrom = from
        log.info("booted \(id, privacy: .public) from \(from, privacy: .public)")
        return ok != 0
    }

    /// (main thread, possibly while the host renders) flash_sync and the image, by the clock's rules: the clock
    /// makes the copy at its next between hook; a clock that doesn't answer in 200 ms is stopped for it
    private func coreStateForSave() -> CoreState? {
        ctl.withLock {
            if var u = unrestored {
                u.settings = settings_
                return u
            }
            let s = CorePlayer.status(e)
            guard let id = coreID, s.booted else { return nil }
            let info = coreInfo ?? CoreInfo(id: id)
            var buf = [UInt8](repeating: 0, count: Int(rfme_flash_size(e)))
            var got = false
            let clock = rfme_clock(e)
            if !buf.isEmpty && (clock == Int32(RFME_CLOCK_AUDIO) || clock == Int32(RFME_CLOCK_TIMER)) {
                _ = buf.withUnsafeMutableBufferPointer { rfme_take_flash(e, $0.baseAddress, UInt32($0.count)) }  // (an old copy)
                rfme_request_flash(e)
                for _ in 0..<100 where !got {
                    usleep(2000)
                    got = buf.withUnsafeMutableBufferPointer { rfme_take_flash(e, $0.baseAddress, UInt32($0.count)) } != 0
                }
            }
            if !got && !buf.isEmpty {
                got = buf.withUnsafeMutableBufferPointer { rfme_final_flash(e, $0.baseAddress, UInt32($0.count)) } != 0
            }
            return CoreState(core: info.firmwareID, version: info.version, flash: got ? Data(buf) : nil,
                             settings: settings_, kind: info.kind, sha256: info.sha256)
        }
    }

    // MARK: status

    public struct Status: Sendable {
        public var instance = ""
        public var coreID = "", coreName = "", coreVersion = "", coreError = "", coreNote = "", bootedFrom = ""
        public var coreKey = "", coreKind = ""  // (M7) the catalog key; "native" | "wasm"
        public var coreInfo: CoreInfo?
        public var core = CoreStatus()
        public var panel: PanelStatus?
        public var settings = AUSettings()
        public var renders: UInt64 = 0, sounding: UInt64 = 0, midiEvents: UInt64 = 0, midiOutMsgs: UInt32 = 0
        public var levelRMS = 0.0
        public var midiIn: UInt32 = 0, midiNotes: UInt32 = 0
        public var powerCycles = 0
        public init() {}
    }

    public func status() -> Status {
        var s = Status()
        s.instance = state.short
        ctl.withLock {
            s.coreKey = coreID ?? ""
            s.coreID = coreInfo?.firmwareID ?? coreID ?? ""
            s.coreInfo = coreInfo
            s.coreKind = coreInfo?.kind ?? ""
            s.coreName = coreInfo?.name ?? ""
            s.coreVersion = coreInfo?.version ?? ""
            s.coreError = coreError
            s.coreNote = coreNote
            s.bootedFrom = bootedFrom
            s.settings = settings_
            s.powerCycles = powerCycles
        }
        s.core = CorePlayer.status(e)
        s.panel = session?.status()
        var k = rfmk_stats_t()
        rfmk_stats(kernel, &k)
        s.renders = k.renders
        s.sounding = k.sounding
        s.midiEvents = k.midi_events
        s.midiOutMsgs = k.midi_out_msgs
        s.levelRMS = k.level_rms
        var r = rfme_status_t()
        rfme_status(e, &r)
        s.midiIn = r.midi_in
        s.midiNotes = r.midi_notes
        return s
    }

    public func resetLevel() {
        rfmk_reset_level(kernel)
        rfme_reset_render_stats(e)
    }

    /// the LCD as last published: a new image when its number differs from `have`
    public func preview(have: UInt32) -> (seq: UInt32, image: CGImage?) {
        pvLock.withLock {
            let seq = pvRGBA.withUnsafeMutableBufferPointer { rfme_preview(e, pvSeq, $0.baseAddress) }
            pvSeq = seq
            guard seq != have, seq != 0 else { return (seq, nil) }
            return (seq, RemoteController.image(pvRGBA))
        }
    }

    /// the LCD as last published, RGBA (for the shared fake's comparison)
    func previewRGBA() -> [UInt8] {
        pvLock.withLock {
            pvSeq = pvRGBA.withUnsafeMutableBufferPointer { rfme_preview(e, pvSeq, $0.baseAddress) }
            return pvRGBA
        }
    }

    /// a core parameter, read with the clock stopped for a moment (diagnostics, the AU test)
    public func param(_ name: String) -> Int32? {
        ctl.withLock {
            var v: Int32 = 0
            return rfme_param_read(e, name, &v) != 0 ? v : nil
        }
    }

    /// (the fake backends) a press, a turn on the fake unit's panel: by label / knob role, as this core maps them
    public func fakePanel(button label: Int32? = nil, knob role: Int32? = nil, key: Int? = nil, down: Bool = true,
                          detents: Int32 = 1) {
        guard let link else { return }
        if let label {
            let id = rfme_matrix_button(e, label)
            if id >= 0 { rfmc_fake_button(link, UInt32(id), down ? 1 : 0) }
        }
        if let role {
            let id = rfme_matrix_encoder(e, role)
            if id >= 0 { rfmc_fake_enc(link, UInt32(id), detents) }
        }
        if let key { rfmc_fake_key(link, UInt32(key), down ? 1 : 0) }
    }

    // MARK: the panel

    public func claimPanel() { session?.claim() }

    /// the owner's name in the lease: "<host's context name, or this process's name> / <core name>"
    private func updateName() {
        guard let session else { return }
        let ctx = (contextName?.isEmpty == false ? contextName : nil) ?? ProcessInfo.processInfo.processName
        let core = ctl.withLock { coreInfo?.name ?? coreID } ?? "no core"
        let name = "\(ctx) / \(core)"
        guard name != lastName else { return }
        lastName = name
        session.setName(name)
    }

    /// the main queue, 4 times a second: a firmware that rebooted itself (exit 0) is powered on again; the owner's
    /// name follows the host's context name
    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var r = rfme_status_t()
            rfme_status(self.e, &r)
            if r.halted != 0 && r.halt_code == 0x100 {
                self.log.info("the firmware rebooted (exit 0): powered on again from its flash")
                self.restartCore()
            }
            if r.latency_frames != self.lastLatency {   // (hosts observe `latency`)
                self.willChangeValue(forKey: "latency")
                self.lastLatency = r.latency_frames
                self.didChangeValue(forKey: "latency")
            }
            self.updateName()
        }
        t.resume()
        timer = t
    }

    // MARK: the instances in this process (the AU test's view of the shared fake)

    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var liveUnits: [ObjectIdentifier: Weak] = [:]
    private struct Weak { weak var au: RFMAudioUnit? }
    private static func register(_ a: RFMAudioUnit) { liveLock.withLock { liveUnits[ObjectIdentifier(a)] = Weak(au: a) } }
    private static func unregister(_ a: RFMAudioUnit) { liveLock.withLock { liveUnits[ObjectIdentifier(a)] = nil } }
    static var live: [RFMAudioUnit] { liveLock.withLock { liveUnits.values.compactMap(\.au) } }

    /// the process-wide shared fake: who started its session, what each link sent, and how much of the fake's
    /// screen each live instance's LCD matches
    public static func sharedFakeReport() -> [String: Any] {
        var r = rfmc_shared_t()
        rfmc_shared_fake(&r)
        var panel = [UInt8](repeating: 0, count: Int(RFMC_W * RFMC_H * 4))
        rfmc_shared_fake_panel(&panel)
        var senders: [[String: Any]] = []
        for i in 0..<r.nsenders {
            let s = rfmc_shared_sender(&r, i)
            senders.append(["label": RemoteController.string(s.label), "msgs": s.msgs, "starts": s.starts,
                            "stops": s.stops, "tiles": s.tiles, "afterOther": s.after_other,
                            "afterOtherTiles": s.after_other_tiles])
        }
        var match: [String: Double] = [:]
        for au in live where !au.fakeLabel.isEmpty {
            let p = au.previewRGBA()
            var same = 0
            for i in stride(from: 0, to: p.count, by: 4) where p[i] == panel[i] && p[i + 1] == panel[i + 1] && p[i + 2] == panel[i + 2] {
                same += 1
            }
            match[au.fakeLabel] = Double(same) / Double(p.count / 4)
        }
        return ["session": r.session, "lastStarter": RemoteController.string(r.last_starter), "starts": r.starts,
                "frames": r.frames, "acks": r.acks, "openPorts": r.open_ports, "senders": senders, "screenMatch": match]
    }

    // MARK: for the Mac tests

    /// a panel event straight into the core (as the FM-1 sends it), by label / knob role
    func panelEvent(button label: Int32? = nil, knob role: Int32? = nil, down: Bool = true, detents: Int16 = 1) {
        if let label {
            let id = rfme_matrix_button(e, label)
            if id >= 0 { _ = rfme_event(e, UInt8(RFMC_EV_BUTTON), UInt8(id), down ? 1 : 0) }
        }
        if let role {
            let id = rfme_matrix_encoder(e, role)
            if id >= 0 { _ = rfme_event(e, UInt8(RFMC_EV_ENC), UInt8(id), detents) }
        }
    }

    /// renders `frames` frames with no host, plus one MIDI message
    public func renderForTest(frames: Int, midi: [UInt8] = []) -> [[Float]] {
        var a = [Float](repeating: 1, count: frames), b = [Float](repeating: 1, count: frames)
        a.withUnsafeMutableBufferPointer { pa in
            b.withUnsafeMutableBufferPointer { pb in
                let bufs: [UnsafeMutablePointer<Float>?] = [pa.baseAddress, pb.baseAddress]
                bufs.withUnsafeBufferPointer { pp in
                    midi.withUnsafeBufferPointer { m in
                        rfmk_render_test(kernel, pp.baseAddress, 2, UInt32(frames), m.baseAddress, UInt32(m.count))
                    }
                }
            }
        }
        return [a, b]
    }
}

/// The host's way to the probes and the instance, through AUMessageChannel (plist types only). Messages, by "cmd":
///   "report"    → ["json": the probe report, "instance": the UUID, "pid": the extension's pid]
///   "ping"      → posts this process's Darwin ping again, then as "report"
///   "bluetooth" → asks the view controller to present the Bluetooth MIDI panel
///   (M4) "status" → ["json": this instance (AUReport)]; "claim" → Use this FM-1; "core" + "id" → another core;
///   "param" + "name" → a core parameter; "fake" → the shared fake unit's record (sharedFakeReport);
///   "fakePanel" + "button" (label) / "knob" (role) / "key", "down", "detents" → the fake unit's panel
final class DiagnosticsChannel: NSObject, AUMessageChannel, @unchecked Sendable {
    private weak var owner: RFMAudioUnit?
    /// set by an out-of-process host's side of the channel when it connects (not used yet; without it the
    /// extension dies with an unrecognized selector)
    var callHostBlock: CallHostBlock?

    init(owner: RFMAudioUnit) { self.owner = owner }

    func callAudioUnit(_ message: [AnyHashable: Any]) -> [AnyHashable: Any] {
        guard let au = owner else { return ["error": "gone"] }
        let num = { (k: String) -> Int32? in (message[k] as? NSNumber)?.int32Value }
        switch message["cmd"] as? String {
        case "bluetooth":
            au.onEvent?(.bluetoothRequested)
            return ["ok": true]
        case "status":
            return ["json": AUReport(au).json, "instance": au.state.instance.uuidString, "pid": Int(getpid())]
        case "claim":
            au.claimPanel()
            return ["ok": true]
        case "core":
            au.selectCore(message["id"] as? String ?? "")
            return ["ok": true]
        case "param":
            return au.param(message["name"] as? String ?? "").map { ["value": Int($0)] } ?? ["error": "no such parameter"]
        case "fake":
            let r = RFMAudioUnit.sharedFakeReport()
            let data = (try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys])) ?? Data()
            return ["json": String(decoding: data, as: UTF8.self)]
        case "fakePanel":
            au.fakePanel(button: num("button"), knob: num("knob"), key: num("key").map(Int.init),
                         down: (message["down"] as? NSNumber)?.boolValue ?? true, detents: num("detents") ?? 1)
            return ["ok": true]
        case "resetLevel":
            au.resetLevel()
            return ["ok": true]
        case "ping":
            au.probe.ping()
            fallthrough
        default:
            let r = au.probe.report()
            return ["json": r.json(pretty: false), "instance": au.state.instance.uuidString, "pid": Int(getpid())]
        }
    }
}

/// One instance as the AU test reads it (JSON through the message channel)
public struct AUReport: Codable, Sendable {
    public var instance = "", fakeLabel = "", backend = ""
    public var pid = Int(getpid())
    public var core = "", coreName = "", coreVersion = "", coreError = "", coreNote = "", bootedFrom = ""
    public var coreKey = "", kind = "", coreLoadPct = 0
    public var slot = 0, booted = false, halted = false, clock = 0, powerCycles = 0
    public var renders: UInt64 = 0, sounding: UInt64 = 0, renderAvgUs = 0, renderMaxUs = 0, renderFrames = 0
    public var rate = 0.0, renderLoadPct = 0.0, levelRMS = 0.0
    public var latencyFrames = 0, underruns = 0, coreAvgUs = 0, coreMaxUs = 0, frameMaxUs = 0, ringFillMin = 0
    public var realtime = false, workgroup = false
    public var midiEvents: UInt64 = 0, midiIn = 0, midiNotes = 0, midiOut = 0, keysPressed = 0, devMs = 0
    public var owner = false, ownerName = "", ownerPid = 0, ownerStale = true, epoch: UInt64 = 0
    public var link = "", linkText = "", line = ""
    public var drops = 0, gateBlocked = 0, duplicate = false, autoClaims = 0, claims = 0
    public var claimWaited = false, claimAcked = false, claimWaitMs = 0
    public var leaseWarning: String?
    public var foreignSession = false
    public var transpose = 0

    public init() {}

    init(_ au: RFMAudioUnit) {
        let s = au.status()
        instance = au.state.instance.uuidString
        fakeLabel = au.fakeLabel
        backend = au.backend
        core = s.coreID
        coreName = s.coreName
        coreVersion = s.coreVersion
        coreError = s.coreError
        coreNote = s.coreNote
        bootedFrom = s.bootedFrom
        coreKey = s.coreKey
        kind = s.coreKind
        coreLoadPct = Int(s.core.coreLoadPct)
        slot = s.core.slot
        booted = s.core.booted
        halted = s.core.halted
        clock = s.core.clock
        powerCycles = s.powerCycles
        renders = s.core.renders
        sounding = s.sounding
        renderAvgUs = Int(s.core.renderAvgUs)
        renderMaxUs = Int(s.core.renderMaxUs)
        renderFrames = Int(s.core.renderLastFrames)
        rate = s.core.rate
        renderLoadPct = s.core.renderLoad * 100
        levelRMS = s.levelRMS
        latencyFrames = Int(s.core.latencyFrames)
        underruns = Int(s.core.underruns)
        coreAvgUs = Int(s.core.coreAvgUs)
        coreMaxUs = Int(s.core.coreMaxUs)
        frameMaxUs = Int(s.core.frameMaxUs)
        ringFillMin = s.core.ringFillMin == UInt32.max ? -1 : Int(s.core.ringFillMin)
        realtime = s.core.realtime
        workgroup = s.core.workgroup
        midiEvents = s.midiEvents
        midiIn = Int(s.midiIn)
        midiNotes = Int(s.midiNotes)
        midiOut = Int(s.core.midiOut)
        keysPressed = Int(s.core.keysPressed)
        devMs = Int(s.core.devMs)
        transpose = s.settings.transpose
        if let p = s.panel {
            owner = p.owner
            ownerName = p.ownerName
            ownerPid = Int(p.ownerPid)
            ownerStale = p.ownerStale
            epoch = p.epoch
            link = p.link.title
            linkText = p.linkText
            line = p.line
            drops = Int(p.drops)
            gateBlocked = Int(p.gateBlocked)
            duplicate = p.duplicate
            autoClaims = p.autoClaims
            claims = p.claims
            claimWaited = p.lastClaimWaited
            claimAcked = p.lastClaimAcked
            claimWaitMs = Int(p.lastClaimWaitMs)
            leaseWarning = p.leaseWarning
            foreignSession = p.foreignSession
        }
    }

    public var json: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func decode(_ s: String) -> AUReport? { try? JSONDecoder().decode(AUReport.self, from: Data(s.utf8)) }
}

private struct KernelRef: @unchecked Sendable { let p: OpaquePointer }
