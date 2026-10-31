// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// CorePlayer (M3): the standalone app's FM-1 firmware. One engine (RFMCore's rfme_t) on the app's RemoteController
// link: the core in a slot (rfms_*), its clock on the audio callback of an AVAudioEngine source node (audio on), or on
// the engine's timer thread (audio off: the FM-1 still plays the screen, no sound). Pattern mode stops the clock and
// gives the link back to M1's test pattern.
//
// M7: the catalog also lists imported .rfm1 firmware (Firmware.swift: FirmwareCatalog), keyed "rfm1:<sha256>"; such a
// core runs in wasm3 (rfme_load_wasm) instead of a slot. `selected` is a catalog key; the app saves it as a CoreRef
// (kind, id, version, SHA-256). A Wasm core that can't keep up gets a note (perfNote) rather than crackling silently.
//
// The flash: Documents/cores/<id>.bin (an imported firmware: rfm1-<id>.bin, shared by its versions). A boot reads it (none: a fresh flash); the clock copies the image every 30
// device seconds when it changed, and this class writes the copy on a background queue. flash_sync and a save also
// come with a core switch, Pattern mode, the app going to the background, and stop(). A firmware that reboots
// itself (halted, exit code 0) is powered on again from its flash, as FM1VST does.
//
// PLAN.md section 18 step 1 (FlashHistory.swift): the writes are FlashFile's (checked, the previous file kept as
// .prev, which a boot uses when the file is damaged); each write may also be a rolling safety copy (FlashHistory). A
// boot whose flash file was written by another version of the firmware (the sidecar's) keeps a copy first ("before
// update"). resetFlash, restore and safetyCopy (the hook for later steps: loading a state, a manager's write).

import AVFoundation
import CoreGraphics
import Foundation
import Observation
import RFMCore

/// one entry of the firmware catalog: a built-in core (kind "native", in slots) or an imported .rfm1 (kind "wasm")
public struct CoreInfo: Sendable, Equatable, Identifiable {
    /// the catalog key: a built-in core's id ("felucca"); an imported file's "rfm1:<sha256>" (FirmwareCatalog), so
    /// an imported Felucca and the built-in one are separate entries
    public var id: String
    public var name = "", version = "", family = "", license = "", sourceURL = "", credits = "", gated = ""
    public var abi: UInt32 = 0, flashSize: UInt32 = 0
    public var slots = 0, inUse = 0, retired = 0
    // M7
    public var kind = "native"                  // "native" | "wasm"
    public var coreID = ""                      // the firmware's own id ("" = id: a built-in core)
    public var sha256 = "", path = "", fileName = ""   // an imported file: its hash, its mirrored path, its name
    public var fileSize = 0

    public var imported: Bool { kind == "wasm" }
    /// the firmware's own id (a saved state's, the flash file's)
    public var firmwareID: String { coreID.isEmpty ? id : coreID }
    /// "Felucca 1.6.1", "Felucca 1.6.1 (imported)"
    public var title: String { "\(name) \(version)" + (imported ? " (imported)" : "") }
}

/// (M7) whether a Wasm core keeps up: its core thread's time over the audio's in windows of ~2 s (from the status's
/// totals); the note when it is over ~90 %, or 3 or more underruns in a window. Native cores: never a note
public struct PerfGuard: Sendable {
    private var window: (at: Date, ticks: Double, frames: UInt64, underruns: UInt32)?
    public private(set) var load = 0.0          // the last window's (0..1+)
    public private(set) var note = ""
    public init() {}

    public mutating func update(_ s: CoreStatus, name: String, now: Date = Date()) -> String {
        guard s.kind == "wasm", s.booted, s.coreWakes > 0, s.rate > 0 else {
            window = nil
            note = ""
            return note
        }
        let ticks = Double(s.coreAvgUs) * Double(s.coreWakes)
        guard let w = window, s.coreFrames >= w.frames, ticks >= w.ticks else {
            window = (now, ticks, s.coreFrames, s.underruns)      // (the first, or the stats were reset)
            return note
        }
        guard now.timeIntervalSince(w.at) >= 2 else { return note }
        let audioUs = Double(s.coreFrames - w.frames) / s.rate * 1e6
        load = audioUs > 0 ? (ticks - w.ticks) / audioUs : 0
        let under = s.underruns >= w.underruns ? s.underruns - w.underruns : 0
        window = (now, ticks, s.coreFrames, s.underruns)
        note = Self.note(load: load, underruns: under, name: name)
        return note
    }

    /// the note for a Wasm core's load (0..1+) and its underruns in the last window; "" when it keeps up
    public static func note(load: Double, underruns: UInt32, name: String) -> String {
        guard load > 0.9 || underruns >= 3 else { return "" }
        return String(format: "%@ is too heavy for this device (%.0f%% of the audio time%@): expect crackles. A "
                      + "built-in core, or fewer instances, plays cleanly.", name, load * 100,
                      underruns > 0 ? ", \(underruns) dropouts" : "")
    }
}

/// A saved choice of firmware (the app's selection, an AU state: RFM1-FORMAT.md section 7 step 5): its kind, id,
/// version and, for an imported file, its SHA-256. resolve finds it in a catalog: the same file; else the same id
/// and kind (another version or build, with a note); else the same id of the other kind (a note); else the first
/// core (a note; the saved flash is not for it)
public struct CoreRef: Codable, Equatable, Sendable {
    public var kind: String
    public var id: String
    public var version: String
    public var sha256: String

    public init(kind: String = "native", id: String, version: String = "", sha256: String = "") {
        self.kind = kind.isEmpty ? "native" : kind
        self.id = id
        self.version = version
        self.sha256 = sha256
    }

    public init(_ c: CoreInfo) { self.init(kind: c.kind, id: c.firmwareID, version: c.version, sha256: c.sha256) }

    public struct Resolved: Equatable, Sendable {
        public var key: String
        public var note: String                 // "" when it is the same firmware file / core
        public var keepFlash: Bool              // the saved flash is this firmware's (its id)
    }

    public func resolve(in cores: [CoreInfo]) -> Resolved? {
        let name = { (c: CoreInfo) in c.name.isEmpty ? c.firmwareID : c.name }
        if kind == "wasm" {
            if let c = cores.first(where: { $0.imported && $0.sha256 == sha256 }) { return Resolved(key: c.id, note: "", keepFlash: true) }
            let same = cores.filter { $0.imported && $0.firmwareID == id }
            if let c = same.first(where: { $0.version == version }) ?? same.max(by: { Self.older($0.version, $1.version) }) {
                let note = c.version == version ? "\(name(c)) \(version): another build of the file (\(c.sha256.prefix(8)))"
                    : "\(name(c)) \(c.version) instead of \(version)"
                return Resolved(key: c.id, note: note, keepFlash: true)
            }
            if let c = cores.first(where: { !$0.imported && $0.firmwareID == id }) {
                return Resolved(key: c.id, note: "\(name(c)) \(version) (imported) is not here: the built-in \(name(c)) \(c.version) instead",
                                keepFlash: true)
            }
        } else {
            if let c = cores.first(where: { !$0.imported && $0.id == id }) { return Resolved(key: c.id, note: "", keepFlash: true) }
            let same = cores.filter { $0.imported && $0.firmwareID == id }
            if let c = same.first(where: { $0.version == version }) ?? same.max(by: { Self.older($0.version, $1.version) }) {
                return Resolved(key: c.id, note: "\(id) is not in this build: \(name(c)) \(c.version) (imported) instead",
                                keepFlash: true)
            }
        }
        guard let first = CorePlayer.pick(nil, in: cores) else { return nil }
        return Resolved(key: first, note: CorePlayer.missingNote(kind == "wasm" ? "\(id) \(version) (imported)" : id, first, cores),
                        keepFlash: false)
    }

    /// version a before b ("1.6.1" < "1.6.10", "1.0-beta.2" < "1.0": FirmwareVersion)
    static func older(_ a: String, _ b: String) -> Bool { FirmwareVersion.less(a, b) }

    // ---- UserDefaults / plist form
    public var dict: [String: String] { ["kind": kind, "id": id, "version": version, "sha256": sha256] }
    public init?(_ d: [String: Any]?) {
        guard let d, let id = d["id"] as? String, !id.isEmpty else { return nil }
        self.init(kind: d["kind"] as? String ?? "native", id: id, version: d["version"] as? String ?? "",
                  sha256: d["sha256"] as? String ?? "")
    }
}

public struct CoreStatus: Sendable, Equatable {
    public var loaded = false, booted = false, halted = false, attached = false
    public var haltCode: UInt32 = 0
    public var clock = 0                // RFME_CLOCK_*
    public var slot = 0
    public var coreID = ""
    public var devMs: UInt32 = 0, lcdWrites: UInt32 = 0, snapshots: UInt32 = 0
    public var eventsApplied: UInt32 = 0, keysPressed: UInt32 = 0, midiOut: UInt32 = 0
    public var haveStats = false
    public var shed: UInt32 = 0, cpuPct: UInt32 = 0
    public var renders: UInt64 = 0, renderFrames: UInt64 = 0
    public var renderLastUs: UInt32 = 0, renderAvgUs: UInt32 = 0, renderMaxUs: UInt32 = 0, renderLastFrames: UInt32 = 0
    public var rate: Double = 0
    public var flashSize: UInt32 = 0, flashDirty: UInt32 = 0, flashCopies: UInt32 = 0
    // M7: the core thread renders ahead of the callback (RFMEngine.h)
    public var latencyFrames: UInt32 = 0, ringTarget: UInt32 = 0, ringFillMin: UInt32 = 0
    public var underruns: UInt32 = 0, underrunFrames: UInt32 = 0
    public var coreWakes: UInt64 = 0, coreAvgUs: UInt32 = 0, coreMaxUs: UInt32 = 0, coreLoadPct: UInt32 = 0
    public var frameMaxUs: UInt32 = 0
    public var realtime = false, workgroup = false
    public var kind = ""                // "native", "wasm" (M7)
    public var coreFrames: UInt64 = 0

    /// the render-ahead latency in ms (0: no render yet)
    public var latencyMs: Double { rate > 0 ? Double(latencyFrames) / rate * 1000 : 0 }

    /// the core thread, for the diagnostics: its latency, its time per render, the longest screen redraw, underruns
    public var aheadText: String {
        guard latencyFrames > 0 else { return "–" }
        let fill = ringFillMin == UInt32.max ? "–" : String(ringFillMin)
        return String(format: "%.1f ms ahead (%u frames, ring min %@ of %u); core %u us avg, %u max (%u%%), frame() max %u us; "
                      + "%u underruns (%u frames)%@%@", latencyMs, latencyFrames, fill, ringTarget, coreAvgUs, coreMaxUs,
                      coreLoadPct, frameMaxUs, underruns, underrunFrames, realtime ? ", real time" : "",
                      workgroup ? ", in the audio workgroup" : "")
    }

    /// the render callback's average time over its buffer's duration
    public var renderLoad: Double {
        guard renderLastFrames > 0, rate > 0 else { return 0 }
        return Double(renderAvgUs) / (Double(renderLastFrames) / rate * 1e6)
    }
}

@MainActor
@Observable
public final class CorePlayer {
    public enum Mode: String, Sendable { case pattern, core }

    public private(set) var cores: [CoreInfo] = []
    public private(set) var selected: String
    public private(set) var mode: Mode = .pattern
    public private(set) var audioOn = true
    public private(set) var audioRunning = false
    public private(set) var status = CoreStatus()
    public private(set) var preview: CGImage?
    public private(set) var message = ""
    public private(set) var audioText = ""
    /// the audio output route now (MIDI & audio › Audio output), read again on every route change
    public private(set) var outputs: [AudioRoute.Output] = []
    /// route changes seen, engine restarts they caused (Diagnostics, tests)
    public private(set) var routeChanges = 0
    public private(set) var saves = 0
    public private(set) var lastSave: Date?
    public private(set) var reboots = 0
    /// the process footprint just before the last load and just after its boot (bytes; -1 unknown)
    public private(set) var footprintBefore: Int64 = -1
    public private(set) var footprintAfter: Int64 = -1

    /// (M8) the app's MIDI settings (the AU's are its AUSettings): notes play keys, transpose, key notes also to the
    /// firmware; for host MIDI from a controller (ControllerInput). Remembered in the app's defaults
    public var midiSettings: AUSettings {
        didSet {
            guard midiSettings != oldValue else { return }
            applyMidiSettings()
            midiDefaults.set(midiSettings.dict, forKey: Self.midiSettingsKey)
        }
    }
    nonisolated static let midiSettingsKey = "rfm1.midiSettings"

    public let flashDir: URL
    /// (section 18) the safety copies
    public let history: FlashHistory
    @ObservationIgnored nonisolated(unsafe) let e: OpaquePointer
    @ObservationIgnored private let mapFollower: MidiMapFollower   // (M8) the global learned map
    @ObservationIgnored private let midiDefaults: UserDefaults
    @ObservationIgnored private let link: RemoteController?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var node: AVAudioSourceNode?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var previewSeq: UInt32 = 0
    @ObservationIgnored private var rgba = [UInt8](repeating: 0, count: Int(RFMC_W * RFMC_H * 4))
    @ObservationIgnored private var flashBuf: [UInt8] = []
    @ObservationIgnored private var bootedID: String?
    @ObservationIgnored private var fallbackNote = ""    // (kept as the message until another core is picked)
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    @ObservationIgnored private var routeObserver: NSObjectProtocol?
    @ObservationIgnored private let io = DispatchQueue(label: "com.quixotic7.remotefm1.flash")
    @ObservationIgnored private let log = RFMShared.log("core")

    /// slotsDir: where the slot frameworks are (nil: the app's Frameworks). selected: the core to start with (a catalog
    /// key); nil, or one this build doesn't have: the first of `order` that it has. ref: a saved choice (CoreRef),
    /// resolved in the catalog (the same file, else the same firmware with a note), before `selected`
    /// midiDefaults: where midiSettings is remembered
    public init(link: RemoteController?, slotsDir: String? = nil, flashDir: URL? = nil, selected: String? = nil,
                ref: CoreRef? = nil, midiDefaults: UserDefaults = .standard, history: FlashHistory? = nil) {
        self.link = link
        self.history = history ?? FlashHistory(root: flashDir?.appendingPathComponent(".history"))
        self.midiDefaults = midiDefaults
        midiSettings = AUSettings(midiDefaults.dictionary(forKey: Self.midiSettingsKey))
        self.selected = selected ?? ""
        // the flash files live in Application Support, out of the Files app's view (Documents shows the firmware folder)
        self.flashDir = flashDir ?? Self.defaultFlashDir()
        try? FileManager.default.createDirectory(at: self.flashDir, withIntermediateDirectories: true)
        if flashDir == nil { Self.migrateFlashFiles(to: self.flashDir) }
        e = rfme_new(link?.core)
        mapFollower = MidiMapFollower(engine: e)
        applyMidiSettings()
        rfms_scan(slotsDir)
        rescan()
        if let ref, selected == nil, let r = ref.resolve(in: cores) {
            self.selected = r.key
            fallbackNote = r.note
            message = r.note
        } else if let pick = Self.pick(selected, in: cores) {
            self.selected = pick
            if let selected, pick != selected { fallbackNote = Self.missingNote(selected, pick, cores) }
            message = fallbackNote
        }
        if cores.isEmpty { message = "no cores in the app (" + Self.text(rfms_dirs) + ")" }
        startPolling()
    }

    /// the cores' order in the picker and for a default: the first of these this build has
    public nonisolated static let order = ["choralroot", "felucca", "melodee", "fizz", "saadet", "boardwalk", "loom"]

    /// `preferred` if `cores` has it, else the first of `cores` (sorted by `order`; built-in cores first); nil when
    /// there are none
    public nonisolated static func pick(_ preferred: String?, in cores: [CoreInfo]) -> String? {
        if let preferred, cores.contains(where: { $0.id == preferred }) { return preferred }
        return (cores.first { !$0.imported } ?? cores.first)?.id
    }

    /// the status line for a core this build doesn't have
    nonisolated static func missingNote(_ missing: String, _ used: String, _ cores: [CoreInfo]) -> String {
        let name = cores.first { $0.id == used }?.name ?? used
        return "\(missing) is not in this build: \(name.isEmpty ? used : name) instead"
    }

    deinit {
        poller?.cancel()
        mapFollower.stop()
        rfme_free(e)
    }

    public var current: CoreInfo? { cores.first { $0.id == selected } }

    /// the selection as saved (kind, id, version, SHA-256)
    public var selectedRef: CoreRef? { current.map(CoreRef.init) }

    /// the catalog read again (the app's firmware folder changed: an import, a delete). A selection that went away
    /// while nothing runs falls back to the first core
    /// an imported file is about to be deleted: when it is the selection, the selection moves first (replacement)
    public func willDelete(_ key: String) {
        if let c = cores.first(where: { $0.id == key }) { safetyCopy(of: key, .beforeDelete("\(c.name) \(c.version)")) }
        guard let k = Self.replacement(deleting: key, selected: selected, in: cores) else { return }
        select(k)
    }

    /// the core to select when `key` is deleted: nil when it isn't the selection; else the same firmware's other file
    /// (its newest version), else its built-in core, else the first core (CoreRef.resolve without the deleted file)
    public nonisolated static func replacement(deleting key: String, selected: String, in cores: [CoreInfo]) -> String? {
        guard key == selected, let c = cores.first(where: { $0.id == key }) else { return nil }
        let rest = cores.filter { $0.id != key }
        var ref = CoreRef(c)
        ref.version = ""                        // (any version of it, the newest)
        return ref.resolve(in: rest)?.key
    }

    public func catalogChanged() {
        rescan()
        if !cores.contains(where: { $0.id == selected }), bootedID == nil, let p = Self.pick(nil, in: cores) {
            selected = p
        }
    }

    /// (M7) the Wasm core can't keep up: its core thread over ~90 % of the audio time, or underruns piling up; ""
    /// otherwise
    public private(set) var perfNote = ""
    @ObservationIgnored private var perf = PerfGuard()

    // MARK: control

    public func select(_ id: String) {
        guard id != selected || bootedID == nil else { return }
        guard cores.contains(where: { $0.id == id }) else { return }
        if id != selected { fallbackNote = "" }
        if bootedID != nil, bootedID != id {
            saveStopped()
            rfme_unload(e)
            bootedID = nil
        }
        selected = id
        if mode == .core { _ = bootSelected() }
        refresh()
    }

    public func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        if m == .core {
            guard bootSelected() else { mode = .pattern; return }
            rfme_attach(e, 1)
            applyClock()
        } else {
            rfme_set_clock(e, Int32(RFME_CLOCK_NONE))
            stopAudio()
            saveStopped()
            rfme_attach(e, 0)
        }
        refresh()
    }

    private func applyMidiSettings() {
        let m = midiSettings
        rfme_set_midi(e, m.keyChannel.engineValue, Int32(m.transpose), m.keyNotesToFirmware ? 1 : 0, m.useLearnedMap ? 1 : 0)
        if let core = link?.core { rfmc_set_key_touch(core, m.keyTouchFlags) }
        rfme_set_button_names(e, m.buttonNames ? 1 : 0)
    }

    public func setAudio(_ on: Bool) {
        audioOn = on
        if mode == .core { applyClock() }
    }

    /// flash_sync and the image written now (also while the clock runs); true when a file was written
    @discardableResult
    public func saveNow() async -> Bool {
        guard let id = bootedID, status.booted || rfme_clock(e) == Int32(RFME_CLOCK_NONE) else { return false }
        let clock = rfme_clock(e)
        if clock == Int32(RFME_CLOCK_AUDIO) || clock == Int32(RFME_CLOCK_TIMER) {
            _ = takeFlash()                                  // (an older copy waiting: written first)
            rfme_request_flash(e)
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(10))
                if takeFlash() { await flush(); return true }
            }
            log.error("flash: the clock did not answer; saved with the clock stopped")
        }
        guard bootedID == id else { return false }
        saveStopped()
        await flush()
        return true
    }

    /// the app goes to the background (the clock keeps running with the audio)
    public func didEnterBackground() async { await saveNow() }

    /// Pattern mode, the audio stopped, the flash saved
    public func stop() {
        setMode(.pattern)
    }

    /// power the firmware off and on again from its flash (a halted core, or the user's Restart)
    public func powerCycle() {
        guard bootedID != nil else { return }
        let before = Self.status(e)
        var err = [CChar](repeating: 0, count: 256)
        if rfme_power_cycle(e, &err, 256) == 0 {
            message = "restart failed: " + Self.string(err)
            bootedID = nil
        } else {
            reboots += 1
            message = before.halted ? String(format: "the firmware rebooted (exit %u): powered on again from its flash",
                                             before.haltCode & 0xFF) : ""
        }
        _ = takeFlash()
        rescan()
        refresh()
    }

    // MARK: internals

    private func bootSelected() -> Bool {
        if bootedID == selected { return true }
        footprintBefore = rfmp_footprint()
        var err = [CChar](repeating: 0, count: 512)
        let info = current
        let loaded = info?.imported == true ? rfme_load_wasm(e, info!.path, &err, 512) : rfme_load(e, selected, &err, 512)
        guard loaded != 0 else {
            message = Self.string(err)
            log.error("load \(self.selected, privacy: .public): \(self.message, privacy: .public)")
            return false
        }
        let url = flashURL(selected)
        let r = io.sync { FlashFile.read(url, expectedSize: Int(rfme_flash_size(e))) }
        let bytes = r.data
        if !r.note.isEmpty { log.error("flash \(url.lastPathComponent, privacy: .public): \(r.note, privacy: .public)") }
        if let info, let bytes { checkVersion(bytes, url, info) }
        let ok: Int32
        if let bytes, !bytes.isEmpty {
            ok = bytes.withUnsafeBytes { rfme_boot(e, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) }
        } else {
            ok = rfme_boot(e, nil, 0)
        }
        footprintAfter = rfmp_footprint()
        bootedID = selected
        flashBuf = [UInt8](repeating: 0, count: Int(rfme_flash_size(e)))
        message = ok == 0 ? "boot failed" : [fallbackNote, r.note].filter { !$0.isEmpty }.joined(separator: " ")
        log.info("booted \(self.selected, privacy: .public) from \(bytes == nil ? "a fresh flash" : "\(url.lastPathComponent)", privacy: .public)")
        rescan()
        return ok != 0
    }

    private func applyClock() {
        if audioOn {
            if !audioRunning { startAudio() }
            rfme_set_clock(e, Int32(audioRunning ? RFME_CLOCK_AUDIO : RFME_CLOCK_TIMER))
        } else {
            rfme_set_clock(e, Int32(RFME_CLOCK_TIMER))
            stopAudio()
        }
    }

    private func startAudio() {
        #if os(iOS)
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback)
            // ~10 ms buffers: the USB route (the FM-1 as a sound card) otherwise gets very short ones, and a firmware's
            // screen redraw inside one callback then makes it late (a dropout); the speaker's default is longer anyway
            try? s.setPreferredIOBufferDuration(0.010)
            try s.setActive(true)
        } catch {
            message = "audio session: \(error.localizedDescription)"
        }
        #endif
        let eng = AVAudioEngine()
        var rate = eng.outputNode.outputFormat(forBus: 0).sampleRate
        if rate <= 0 { rate = 48000 }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let n: AVAudioSourceNode = rfme_source_node(e, fmt)
        eng.attach(n)
        eng.connect(n, to: eng.mainMixerNode, format: fmt)
        do {
            try eng.start()
        } catch {
            message = "audio: \(error.localizedDescription)"
            return
        }
        engine = eng
        node = n
        audioRunning = true
        // the core thread rendering ahead joins the output's audio workgroup (kAudioOutputUnitProperty_OSWorkgroup)
        if let au = eng.outputNode.audioUnit { rfme_use_output_workgroup(e, UnsafeMutableRawPointer(au)) }
        observeRoute()
        #if os(iOS)
        outputs = AudioRoute.current
        #endif
        updateAudioText()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: eng, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioConfigurationChanged() }
        }
    }

    /// AVAudioSession.routeChangeNotification (the app's whole life: the route shows even with the sound off)
    private func observeRoute() {
        #if os(iOS)
        guard routeObserver == nil else { return }
        outputs = AudioRoute.current
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let r = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            let cause = r.map(AudioRoute.cause) ?? .other
            MainActor.assumeIsolated { self?.routeChanged(cause) }
        }
        #endif
    }

    func routeChanged(_ cause: AudioRoute.Cause) {
        routeChanges += 1
        #if os(iOS)
        outputs = AudioRoute.current
        #endif
        switch AudioRoute.action(cause, audioOn: mode == .core && audioOn, engineRunning: engine?.isRunning ?? false) {
        case .none: break
        case .rename: updateAudioText()
        case .restart: audioConfigurationChanged()
        }
    }

    private func updateAudioText() {
        guard let eng = engine else { return }
        let rate = eng.outputNode.outputFormat(forBus: 0).sampleRate
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        audioText = String(format: "%.0f Hz, io buffer %.1f ms, %@", rate, s.ioBufferDuration * 1000, AudioRoute.name(outputs))
        #else
        audioText = String(format: "%.0f Hz", rate)
        #endif
    }

    private func stopAudio() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine?.stop()
        engine = nil
        rfme_set_workgroup(e, nil)
        node = nil
        audioRunning = false
        audioText = ""
    }

    private func audioConfigurationChanged() {   // (a route or rate change: a new engine at the new rate)
        guard mode == .core, audioOn else { return }
        rfme_set_clock(e, Int32(RFME_CLOCK_TIMER))
        stopAudio()
        applyClock()
    }

    /// The main mixer, for taps (the core test)
    public var mixer: AVAudioMixerNode? { engine?.mainMixerNode }

    /// flash_sync with the clock stopped, the image queued for writing
    private func saveStopped() {
        guard let id = bootedID, !flashBuf.isEmpty else { return }
        let ok = flashBuf.withUnsafeMutableBufferPointer { rfme_final_flash(e, $0.baseAddress, UInt32($0.count)) }
        if ok != 0 { write(Data(flashBuf), id) }
    }

    /// a copy the clock made, queued for writing; true when there was one
    private func takeFlash() -> Bool {
        guard let id = bootedID, !flashBuf.isEmpty else { return false }
        let ok = flashBuf.withUnsafeMutableBufferPointer { rfme_take_flash(e, $0.baseAddress, UInt32($0.count)) }
        if ok != 0 { write(Data(flashBuf), id) }
        return ok != 0
    }

    private func write(_ data: Data, _ id: String) {
        let url = flashURL(id)
        let log = self.log, history = self.history
        let info = cores.first { $0.id == id }
        let fid = info?.firmwareID ?? id, version = info?.version ?? ""
        io.async {
            do {
                try FlashFile.write(data, to: url, firmwareID: fid, version: version)
                history.record(data, firmwareID: fid, version: version, reason: .rolling)
            } catch { log.error("flash: \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
        saves += 1
        lastSave = Date()
    }

    /// (a boot) the flash file was written by another version of this firmware: a copy first, the sidecar then
    /// names this version. A file from before the sidecars: a first copy (its version unknown)
    private func checkVersion(_ bytes: Data, _ url: URL, _ info: CoreInfo) {
        let m = FlashFile.meta(url)
        guard m?.version != info.version else { return }
        let reason: FlashHistory.Reason = m.map { .beforeUpdate(from: $0.version, to: info.version) } ?? .firstCopy
        history.record(bytes, firmwareID: info.firmwareID, version: m?.version ?? "", reason: reason)
        log.info("flash \(url.lastPathComponent, privacy: .public): \(reason.text, privacy: .public): a safety copy")
        try? FlashFile.writeMeta(.init(firmwareID: info.firmwareID, version: info.version, size: bytes.count,
                                       sha256: FlashFile.sha256(bytes), date: Date()), for: url)
    }

    /// a safety copy of a catalog key's saved flash (the running one's latest copy written first); nil: none to copy
    @discardableResult
    public func safetyCopy(of key: String, _ reason: FlashHistory.Reason) -> FlashHistory.Snapshot? {
        if key == bootedID { _ = takeFlash() }
        let url = flashURL(key)
        let c = cores.first { $0.id == key }
        let r = io.sync { FlashFile.read(url, expectedSize: 0) }
        guard let d = r.data else { return nil }
        return history.record(d, firmwareID: c?.firmwareID ?? key, version: FlashFile.meta(url)?.version ?? c?.version ?? "",
                              reason: reason)
    }

    /// (section 18's hook: before loading a state, a web manager's write) the running firmware saved now, then a
    /// safety copy
    @discardableResult
    public func safetyCopy(_ reason: FlashHistory.Reason) async -> FlashHistory.Snapshot? {
        if bootedID == selected { await saveNow() }
        return safetyCopy(of: selected, reason)
    }

    /// the safety copies of the selected firmware, newest first
    public var safetyCopies: [FlashHistory.Snapshot] {
        _ = saves                                       // (observed: a save may add one)
        return current.map { history.list($0.firmwareID) } ?? []
    }

    /// Reset firmware…: a safety copy, then the selected firmware started with a fresh flash (its file removed)
    @discardableResult
    public func resetFlash() async -> FlashHistory.Snapshot? {
        let snap = await safetyCopy(.beforeReset)
        let key = selected
        let wasBooted = bootedID == key
        if wasBooted { saveStopped(); rfme_unload(e); bootedID = nil }
        let url = flashURL(key)
        io.sync { FlashFile.remove(url) }
        if wasBooted || mode == .core { _ = bootSelected() }
        message = "\(current?.name ?? key) started with a clean memory; a copy of the old one is in Safety copies."
        saves += 1
        log.info("reset \(key, privacy: .public)")
        refresh()
        return snap
    }

    /// a safety copy restored into the selected firmware (a copy of the current flash first); false: not this
    /// firmware's, or its bytes are gone
    @discardableResult
    public func restore(_ s: FlashHistory.Snapshot) async -> Bool {
        guard let c = current, s.firmwareID == c.firmwareID, let d = history.data(s) else {
            message = "That safety copy can't be read."
            return false
        }
        await safetyCopy(.beforeRestore)
        let key = selected
        let wasBooted = bootedID == key
        if wasBooted { saveStopped(); rfme_unload(e); bootedID = nil }
        let url = flashURL(key)
        do { try io.sync { try FlashFile.write(d, to: url, firmwareID: c.firmwareID, version: c.version) } }
        catch {
            message = "Restore failed: \(error.localizedDescription)"
            if wasBooted || mode == .core { _ = bootSelected() }
            return false
        }
        if wasBooted || mode == .core { _ = bootSelected() }
        message = "Restored the copy of \(s.date.formatted(date: .abbreviated, time: .shortened)) (\(s.reason))."
        saves += 1
        refresh()
        return true
    }

    /// waits until the queued writes are on disk
    private func flush() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in io.async { k.resume() } }
    }

    /// the flash file of a catalog key: <id>.bin, an imported firmware's rfm1-<its id>.bin
    /// Application Support/cores: each firmware's flash image
    public nonisolated static func defaultFlashDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("cores")
    }

    /// moves flash files an older build kept in Documents/cores (visible in Files) to `dir`, once
    nonisolated static func migrateFlashFiles(to dir: URL) {
        let fm = FileManager.default
        let old = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("cores")
        guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        for n in names where !fm.fileExists(atPath: dir.appendingPathComponent(n).path) {
            try? fm.moveItem(at: old.appendingPathComponent(n), to: dir.appendingPathComponent(n))
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty ?? false { try? fm.removeItem(at: old) }
    }

    public func flashURL(_ key: String) -> URL {
        if let c = cores.first(where: { $0.id == key }), c.imported {
            return flashDir.appendingPathComponent("rfm1-\(c.firmwareID).bin")
        }
        return flashDir.appendingPathComponent("\(key).bin")
    }

    private func startPolling() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    public func refresh() {
        let s = Self.status(e)
        if s != status { status = s }
        updatePerf(s)
        let seq = rgba.withUnsafeMutableBufferPointer { rfme_preview(e, previewSeq, $0.baseAddress) }
        if seq != previewSeq, seq != 0 {
            previewSeq = seq
            preview = RemoteController.image(rgba)
        }
        _ = takeFlash()
        if s.halted && s.haltCode == 0x100 { powerCycle() }   // (CR_REBOOT: exit(0); others stay halted)
    }

    private func rescan() {
        let list = Self.catalog()
        if list != cores { cores = list }
    }

    /// the Wasm core's load over the last ~2 s (perfNote)
    private func updatePerf(_ s: CoreStatus) {
        let note = perf.update(s, name: current?.name ?? s.coreID)
        if note != perfNote { perfNote = note }
    }

    /// the cores the slot loader found (rfms_scan), in `order`, then the imported firmware (FirmwareCatalog)
    nonisolated static func catalog() -> [CoreInfo] {
        var list: [CoreInfo] = []
        for i in 0..<rfms_count() {
            var r = rfms_info_t()
            guard rfms_info(i, &r) != 0 else { continue }
            var c = CoreInfo(id: Self.string(r.id))
            c.coreID = c.id
            c.name = Self.string(r.name)
            c.version = Self.string(r.version)
            c.family = Self.string(r.family)
            c.license = Self.string(r.license)
            c.sourceURL = Self.string(r.source_url)
            c.gated = Self.string(r.gated)
            c.abi = r.abi
            c.flashSize = r.flash_size
            c.slots = Int(r.slots)
            c.inUse = Int(r.in_use)
            c.retired = Int(r.retired)
            c.credits = Self.credits(c.id)
            list.append(c)
        }
        let order = Self.order
        list.sort { (order.firstIndex(of: $0.id) ?? 99, $0.id) < (order.firstIndex(of: $1.id) ?? 99, $1.id) }
        return list + FirmwareCatalog.shared.cores()
    }

    // MARK: conversions

    nonisolated static func status(_ e: OpaquePointer) -> CoreStatus {
        var r = rfme_status_t()
        rfme_status(e, &r)
        var s = CoreStatus()
        s.loaded = r.loaded != 0
        s.booted = r.booted != 0
        s.halted = r.halted != 0
        s.attached = r.attached != 0
        s.haltCode = r.halt_code
        s.clock = Int(r.clock)
        s.slot = Int(r.slot)
        s.coreID = string(r.core_id)
        s.devMs = r.dev_ms
        s.lcdWrites = r.lcd_writes
        s.snapshots = r.snapshots
        s.eventsApplied = r.events_applied
        s.keysPressed = r.keys_pressed
        s.midiOut = r.midi_out
        s.haveStats = r.have_stats != 0
        s.shed = r.shed
        s.cpuPct = r.cpu_pct
        s.renders = r.renders
        s.renderFrames = r.render_frames
        s.renderLastUs = r.render_last_us
        s.renderAvgUs = r.render_avg_us
        s.renderMaxUs = r.render_max_us
        s.renderLastFrames = r.render_last_frames
        s.rate = r.rate
        s.flashSize = r.flash_size
        s.flashDirty = r.flash_dirty
        s.flashCopies = r.flash_copies
        s.latencyFrames = r.latency_frames
        s.ringTarget = r.ring_target
        s.ringFillMin = r.ring_fill_min
        s.underruns = r.underruns
        s.underrunFrames = r.underrun_frames
        s.coreWakes = r.core_wakes
        s.coreAvgUs = r.core_avg_us
        s.coreMaxUs = r.core_max_us
        s.coreLoadPct = r.core_load_pct
        s.frameMaxUs = r.frame_max_us
        s.realtime = r.realtime != 0
        s.workgroup = r.workgroup != 0
        s.kind = string(r.kind)
        s.coreFrames = r.core_frames
        return s
    }

    public func resetRenderStats() { rfme_reset_render_stats(e) }

    nonisolated static func string<T>(_ t: T) -> String { RemoteController.string(t) }

    nonisolated static func string(_ a: [CChar]) -> String {
        String(decoding: a.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    nonisolated static func credits(_ id: String) -> String {
        let n = Int(rfms_credits(id, nil, 0))
        guard n > 0 else { return "" }
        var b = [CChar](repeating: 0, count: n + 1)
        _ = rfms_credits(id, &b, UInt32(n + 1))
        return string(b)
    }

    nonisolated static func text(_ f: (UnsafeMutablePointer<CChar>?, UInt32) -> UInt32) -> String {
        var b = [CChar](repeating: 0, count: 2048)
        _ = f(&b, 2048)
        return string(b)
    }
}
