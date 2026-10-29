// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RemoteController: the app's handle on one RemoteLink (RFMCore). It starts and stops the link, turns the test pattern
// on and off, and publishes what the link knows, read from RFMCore about 15 times a second on the main actor. M4: with
// a lease (PanelSession), start() is the claim ("Use this FM-1"), stop() the owner's explicit disconnect, and
// appeared() applies the automatic rules (PLAN.md section 4) with the app's own UUID.

import CoreGraphics
import Foundation
import Observation
import RFMCore
#if canImport(CoreMIDI)
import CoreMIDI
#endif

@MainActor
@Observable
public final class RemoteController {
    public let backend: Backend
    public private(set) var isRunning = false
    public var patternOn: Bool {
        didSet { if let core { rfmc_set_pattern(core, patternOn ? 1 : 0) } }
    }

    public private(set) var state: LinkState = .stopped("")
    public private(set) var statusText = "off"       // RemoteLink's own words
    public private(set) var lastLog = ""
    public private(set) var hello: UnitHello?
    public private(set) var stats = LinkStats()
    public private(set) var events: [PanelEvent] = []   // newest first
    public private(set) var heldKeys: UInt32 = 0
    public private(set) var heldButtons: UInt32 = 0
    public private(set) var master: Int?
    public private(set) var preview: CGImage?          // the frame being sent (also while not connected)
    public private(set) var midiSetupChanges = 0
    public private(set) var panel: PanelStatus?        // (with a lease) who holds the FM-1
    @ObservationIgnored public private(set) var session: PanelSession?

    public static let maxEvents = 12
    nonisolated static let notFoundAfter: TimeInterval = 3

    @ObservationIgnored nonisolated(unsafe) var core: OpaquePointer?     // (rfmc_t; CorePlayer runs its engine on it)
    @ObservationIgnored private var lastSeq: UInt32 = 0
    @ObservationIgnored private var previewSeq: UInt32 = 0
    @ObservationIgnored private var rgba = [UInt8](repeating: 0, count: Int(RFMC_W * RFMC_H * 4))
    @ObservationIgnored private var searchingSince: Date?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var demo: Task<Void, Never>?
    #if canImport(CoreMIDI)
    @ObservationIgnored private var watcher: MIDISetupWatcher?
    #endif

    /// demoInput (fake only): the fake unit presses keys and turns an encoder by itself, so the panel path shows.
    /// lease: the shared-session lease (M4) under `identity` (no unit lock then); nil: M1's flock at lockPath
    public init(backend: Backend, patternOn: Bool = true, fps: UInt32 = 20, hostName: String = "RemoteFM1 iOS",
                demoInput: Bool = false,
                lockPath: String = FileManager.default.temporaryDirectory
                    .appendingPathComponent("remotefm1-unit.lock").path,
                lease: PanelSession.Config? = nil, identity: UUID = UUID(), ownerName: String = "RemoteFM1") {
        self.backend = backend
        self.patternOn = patternOn
        var cfg = rfmc_cfg_t()
        cfg.fps = fps
        if case .fake(let ble) = backend {
            cfg.backend = Int32(RFMC_FAKE)
            cfg.fake_ble = ble ? 1 : 0
        } else {
            cfg.backend = Int32(RFMC_DEVICE)
        }
        let lp0 = lease == nil ? lockPath : ""
        core = lp0.withCString { lp in
            hostName.withCString { hn in
                cfg.lock_path = lp
                cfg.host_name = hn
                return rfmc_new(&cfg)                  // (copies both strings)
            }
        }
        if let core { rfmc_set_pattern(core, patternOn ? 1 : 0) }
        if let core, var lease {
            lease.fake = backend.isFake
            session = PanelSession(link: core, identity: identity, name: ownerName, config: lease)
        }
        #if canImport(CoreMIDI)
        if backend == .device {
            watcher = MIDISetupWatcher { [weak self] in
                Task { @MainActor in self?.midiSetupChanged() }
            }
        }
        #endif
        if demoInput, backend.isFake { startDemo() }
        startPolling()
    }

    deinit {
        poller?.cancel()
        demo?.cancel()
        if let session {
            session.finish()                    // (frees the link, then the lease, in the background)
        } else if let core {
            let ref = LinkRef(p: core)
            DispatchQueue.global(qos: .utility).async { rfmc_free(ref.p) }   // (a stop waits up to ~600 ms)
        }
    }

    // MARK: control

    /// starts the link; with a lease, "Use this FM-1": the claim first (on the session's queue)
    public func start() {
        guard let core else { return }
        if let session { session.claim() } else { rfmc_start(core) }
        isRunning = true
        refresh()
    }

    public func stop() {
        guard let core else { return }
        if let session { session.release() } else { rfmc_stop(core) }
        isRunning = false
        refresh()
    }

    /// the app came up: with a lease, PLAN.md section 4's automatic rules; without, start()
    public func appeared() {
        if let session { session.appeared() } else if !isRunning { start() }
    }

    public func setOwnerName(_ name: String) { session?.setName(name) }

    /// Stops and frees the link now (SESSION 0 first, at most ~600 ms). The controller is inert afterwards.
    public func shutdown() {
        poller?.cancel()
        demo?.cancel()
        if let session { session.finish() } else if let core { rfmc_free(core) }
        session = nil
        core = nil
        isRunning = false
        state = .stopped("")
    }

    /// Asks the link to look at CoreMIDI's endpoints again.
    public func rescan() {
        if let core { rfmc_rescan(core) }
    }

    func midiSetupChanged() {
        midiSetupChanges += 1
        rescan()
    }

    // MARK: the fake unit's panel (tests, -fake)

    public func fakeKey(_ k: Int, down: Bool) { if let core { rfmc_fake_key(core, UInt32(k), down ? 1 : 0) } }
    public func fakeButton(_ b: Int, down: Bool) { if let core { rfmc_fake_button(core, UInt32(b), down ? 1 : 0) } }
    public func fakeEncoder(_ e: Int, detents: Int) { if let core { rfmc_fake_enc(core, UInt32(e), Int32(detents)) } }
    public func fakeMaster(_ adc: Int) { if let core { rfmc_fake_master(core, UInt32(adc)) } }

    /// The fake unit as it is now (nil: not the fake backend).
    public struct FakeUnit: Sendable {
        public var session: Int
        public var frames: UInt32, acks: UInt32, heldFrames: UInt32, hellos: UInt32
    }
    public func fakeUnit() -> FakeUnit? {
        guard let core else { return nil }
        var f = rfmc_fake_t()
        guard rfmc_fake_state(core, &f) != 0 else { return nil }
        return FakeUnit(session: Int(f.session), frames: f.frames, acks: f.acks, heldFrames: f.held_frames,
                        hellos: f.hellos)
    }
    /// The fake unit shows note key k's LED lit.
    public func fakeKeyLit(_ k: Int) -> Bool { core.map { rfmc_fake_key_lit($0, UInt32(k)) != 0 } ?? false }
    public func fakeButtonLit(_ b: Int) -> Bool { core.map { rfmc_fake_button_lit($0, UInt32(b)) != 0 } ?? false }

    // MARK: reading RFMCore

    private func startPolling() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    private func startDemo() {
        demo = Task { [weak self] in
            var k = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard let self else { return }
                guard self.state.isConnected else { continue }
                self.fakeKey(k, down: true)
                try? await Task.sleep(for: .milliseconds(450))
                self.fakeKey(k, down: false)
                if k % 3 == 0 { self.fakeEncoder(k % 7, detents: k % 2 == 0 ? 2 : -1) }
                k = (k + 4) % 27
            }
        }
    }

    /// Reads the link's state, events and frame now (the poller does this ~15 times a second).
    public func refresh() {
        guard let core else { return }
        var st = rfmc_status_t()
        rfmc_status(core, &st)
        isRunning = st.wanted != 0
        let s = Self.state(of: st, searchingSince: &searchingSince)
        if s != state { state = s }
        let text = Self.string(st.text), log = Self.string(st.log)
        if text != statusText { statusText = text }
        if log != lastLog { lastLog = log }
        let h = st.have_hello != 0 ? Self.hello(of: st) : nil
        if h != hello { hello = h }
        let ls = Self.stats(of: st)
        if ls != stats { stats = ls }
        if let session {
            let p = session.status()
            if p != panel { panel = p }
        }

        var buf = [rfmc_event_t](repeating: rfmc_event_t(), count: Self.maxEvents)
        let n = Int(rfmc_events(core, lastSeq, &buf, UInt32(Self.maxEvents)))
        if n > 0 {
            let new = buf[0..<n].map(Self.event(of:))
            lastSeq = buf[n - 1].seq
            events = Array((new.reversed() + events).prefix(Self.maxEvents))
        }
        var keys: UInt32 = 0, buttons: UInt32 = 0, m: Int32 = -1
        rfmc_panel(core, &keys, &buttons, &m)
        if keys != heldKeys { heldKeys = keys }
        if buttons != heldButtons { heldButtons = buttons }
        let mv: Int? = m < 0 ? nil : Int(m)
        if mv != master { master = mv }

        let seq = rgba.withUnsafeMutableBufferPointer { rfmc_preview(core, previewSeq, $0.baseAddress) }
        if seq != previewSeq {
            previewSeq = seq
            preview = Self.image(rgba)
        }
    }

    // MARK: conversions

    nonisolated static func state(of st: rfmc_status_t, searchingSince: inout Date?) -> LinkState {
        let text = string(st.text)
        var searching = false
        defer { if !searching { searchingSince = nil } }
        switch Int(st.state) {
        case RFMC_IN_USE: return .inUse(text)
        case RFMC_ERROR: return .error(text)
        case RFMC_STOPPING: return .stopping
        case RFMC_CONNECTED: return .connected(bluetooth: st.ble != 0)
        case RFMC_LOST: return .lost
        case RFMC_SEARCHING:
            if Int(st.session_state) == RFMC_S_STARTING { return .starting }
            searching = true
            let since = searchingSince ?? Date()
            searchingSince = since
            return Date().timeIntervalSince(since) > notFoundAfter ? .notFound : .searching
        default:
            if st.wanted != 0 {                         // (the link's thread is about to start a run)
                searching = true
                searchingSince = searchingSince ?? Date()
                return .searching
            }
            return .stopped("")
        }
    }

    nonisolated static func hello(of st: rfmc_status_t) -> UnitHello {
        var h = UnitHello()
        h.name = string(st.name)
        h.version = string(st.ver)
        h.firmwareVersion = string(st.fw_ver)
        h.identity = string(st.identity)
        h.proto = st.proto
        h.transports = st.transports
        h.usbMode = st.usb_mode
        h.caps = st.caps
        h.sxq = st.sxq
        h.sxBodyMax = st.sx_body_max
        h.bkBodyMax = st.bk_body_max
        h.screenW = st.screen_w
        h.screenH = st.screen_h
        h.maxInFlight = st.max_in_flight
        h.isBluetooth = st.hello_ble != 0
        h.session = st.session != 0
        return h
    }

    nonisolated static func stats(of st: rfmc_status_t) -> LinkStats {
        var s = LinkStats()
        s.fps = st.fps
        s.runs = st.runs
        s.sessions = st.sessions
        s.discoveries = st.discoveries
        s.frames = st.frames
        s.acks = st.acks
        s.pending = st.pending
        s.inFlight = st.in_flight
        s.ackMsLast = st.ack_ms_last
        s.ackMsAvg = st.ack_ms_avg
        s.ackMsMax = st.ack_ms_max
        s.ackTimeouts = st.ack_timeouts
        s.wireBytes = st.wire_bytes
        s.bodyBytes = st.body_bytes
        s.budget = st.budget
        s.wireCap = st.wire_cap
        s.frameMs = st.frame_ms
        s.ble = st.ble != 0
        s.hold = st.hold != 0
        s.held = st.held
        s.reduced = st.reduced
        s.refined = st.refined
        s.colors = st.colors
        s.eventsIn = st.events_in
        s.eventsDropped = st.events_dropped
        s.snapshots = st.snapshots
        return s
    }

    static func event(of e: rfmc_event_t) -> PanelEvent {
        let kind: PanelEvent.Kind
        switch Int(e.type) {
        case RFMC_EV_KEY: kind = .key
        case RFMC_EV_BUTTON: kind = .button
        case RFMC_EV_ENC: kind = .encoder
        case RFMC_EV_MASTER: kind = .master
        default: kind = .release
        }
        return PanelEvent(id: e.seq, kind: kind, index: Int(e.index), value: Int(e.value), resync: e.source != 0)
    }

    /// a fixed-size C char array (imported as a tuple), up to its NUL
    nonisolated static func string<T>(_ t: T) -> String {
        withUnsafeBytes(of: t) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }

    nonisolated static func image(_ rgba: [UInt8]) -> CGImage? {
        let w = Int(RFMC_W), h = Int(RFMC_H)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private struct LinkRef: @unchecked Sendable { let p: OpaquePointer }

#if canImport(CoreMIDI)
/// A CoreMIDI client on the main thread that only listens: its setup notifications (a Bluetooth MIDI device
/// connected or gone) ask the link to rescan. It sends nothing and connects to nothing.
final class MIDISetupWatcher {
    private var client = MIDIClientRef()

    init(onChange: @escaping @Sendable () -> Void) {
        let st = MIDIClientCreateWithBlock("RemoteFM1 watch" as CFString, &client) { n in
            if n.pointee.messageID == .msgSetupChanged { onChange() }
        }
        if st != noErr { client = 0 }
    }

    deinit { if client != 0 { MIDIClientDispose(client) } }
}
#endif
