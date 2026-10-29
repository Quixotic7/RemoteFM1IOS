// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// CorePlayer (M3): the standalone app's FM-1 firmware. One engine (RFMCore's rfme_t) on the app's RemoteController
// link: the core in a slot (rfms_*), its clock on the audio callback of an AVAudioEngine source node (audio on), or on
// the engine's timer thread (audio off: the FM-1 still plays the screen, no sound). Pattern mode stops the clock and
// gives the link back to M1's test pattern.
//
// The flash: Documents/cores/<id>.bin. A boot reads it (none: a fresh flash); the clock copies the image every 30
// device seconds when it changed, and this class writes the copy on a background queue. flash_sync and a save also
// come with a core switch, Pattern mode, the app going to the background, and stop(). A firmware that reboots
// itself (halted, exit code 0) is powered on again from its flash, as FM1VST does.

import AVFoundation
import CoreGraphics
import Foundation
import Observation
import RFMCore

public struct CoreInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var name = "", version = "", family = "", license = "", sourceURL = "", credits = "", gated = ""
    public var abi: UInt32 = 0, flashSize: UInt32 = 0
    public var slots = 0, inUse = 0, retired = 0
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
    public private(set) var saves = 0
    public private(set) var lastSave: Date?
    public private(set) var reboots = 0
    /// the process footprint just before the last load and just after its boot (bytes; -1 unknown)
    public private(set) var footprintBefore: Int64 = -1
    public private(set) var footprintAfter: Int64 = -1

    public let flashDir: URL
    @ObservationIgnored nonisolated(unsafe) let e: OpaquePointer
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
    @ObservationIgnored private let io = DispatchQueue(label: "com.quixotic7.remotefm1.flash")
    @ObservationIgnored private let log = RFMShared.log("core")

    /// slotsDir: where the slot frameworks are (nil: the app's Frameworks). selected: the core to start with (a saved
    /// choice); nil, or one this build doesn't have: the first of `order` that it has
    public init(link: RemoteController?, slotsDir: String? = nil, flashDir: URL? = nil, selected: String? = nil) {
        self.link = link
        self.selected = selected ?? ""
        self.flashDir = flashDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cores")
        try? FileManager.default.createDirectory(at: self.flashDir, withIntermediateDirectories: true)
        e = rfme_new(link?.core)
        rfms_scan(slotsDir)
        rescan()
        if let pick = Self.pick(selected, in: cores) {
            self.selected = pick
            if let selected, pick != selected { fallbackNote = Self.missingNote(selected, pick, cores) }
            message = fallbackNote
        }
        if cores.isEmpty { message = "no cores in the app (" + Self.text(rfms_dirs) + ")" }
        startPolling()
    }

    /// the cores' order in the picker and for a default: the first of these this build has
    public nonisolated static let order = ["choralroot", "felucca", "melodee", "fizz", "saadet", "boardwalk", "loom"]

    /// `preferred` if `cores` has it, else the first of `cores` (sorted by `order`); nil when there are none
    public nonisolated static func pick(_ preferred: String?, in cores: [CoreInfo]) -> String? {
        if let preferred, cores.contains(where: { $0.id == preferred }) { return preferred }
        return cores.first?.id
    }

    /// the status line for a core this build doesn't have
    nonisolated static func missingNote(_ missing: String, _ used: String, _ cores: [CoreInfo]) -> String {
        let name = cores.first { $0.id == used }?.name ?? used
        return "\(missing) is not in this build: \(name.isEmpty ? used : name) instead"
    }

    deinit {
        poller?.cancel()
        rfme_free(e)
    }

    public var current: CoreInfo? { cores.first { $0.id == selected } }

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
        var err = [CChar](repeating: 0, count: 256)
        guard rfme_load(e, selected, &err, 256) != 0 else {
            message = Self.string(err)
            log.error("load \(self.selected, privacy: .public): \(self.message, privacy: .public)")
            return false
        }
        let url = flashURL(selected)
        let bytes: Data? = io.sync { try? Data(contentsOf: url) }
        let ok: Int32
        if let bytes, !bytes.isEmpty {
            ok = bytes.withUnsafeBytes { rfme_boot(e, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) }
        } else {
            ok = rfme_boot(e, nil, 0)
        }
        footprintAfter = rfmp_footprint()
        bootedID = selected
        flashBuf = [UInt8](repeating: 0, count: Int(rfme_flash_size(e)))
        message = ok != 0 ? fallbackNote : "boot failed"
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
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        audioText = String(format: "%.0f Hz, io buffer %.1f ms, %@", rate, s.ioBufferDuration * 1000, route)
        #else
        audioText = String(format: "%.0f Hz", rate)
        #endif
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: eng, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioConfigurationChanged() }
        }
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
        let log = self.log
        io.async {
            do { try data.write(to: url, options: .atomic) }
            catch { log.error("flash: \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
        saves += 1
        lastSave = Date()
    }

    /// waits until the queued writes are on disk
    private func flush() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in io.async { k.resume() } }
    }

    public func flashURL(_ id: String) -> URL { flashDir.appendingPathComponent("\(id).bin") }

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

    /// the cores the slot loader found (rfms_scan), in `order`
    nonisolated static func catalog() -> [CoreInfo] {
        var list: [CoreInfo] = []
        for i in 0..<rfms_count() {
            var r = rfms_info_t()
            guard rfms_info(i, &r) != 0 else { continue }
            var c = CoreInfo(id: Self.string(r.id))
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
        return list
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
