// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The app's MIDI input from controllers (M8): a CoreMIDI client and an input port (MIDI 1.0 UMP), connected to the
// sources the user picked: all (the default), none, or one (by its unique ID; remembered, also while it is away).
// Never the FM-1 (RemoteMidi.c's rule, rfme_fm1_candidate; a source with no device: the website's name test) and never
// a source `exclude` claims (the OMX-27 while it is in REMOTE mode). Channel messages go to the engine as host MIDI
// (rfme_midi_in: learn, the learned map, notes play keys, the rest to the firmware); SysEx, clock and the other system
// messages don't. Reconnects when the MIDI setup changes (notifications on the main thread, as MIDISetupWatcher).

import Foundation
import Observation
import RFMCore
#if canImport(CoreMIDI)
import CoreMIDI
#endif

@MainActor
@Observable
public final class ControllerInput {
    public struct Source: Identifiable, Equatable, Sendable {
        public let id: Int32                    // kMIDIPropertyUniqueID
        public let name: String
        public var connected: Bool
    }

    public enum Selection: Equatable, Sendable {
        case all, none, one(Int32)

        /// the website's prefs.midi: "*" all, "" none, else the source's id
        public var stored: String {
            switch self {
            case .all: "*"
            case .none: ""
            case .one(let id): String(id)
            }
        }

        public init(stored s: String?) {
            if s == nil || s == "*" { self = .all } else if let id = Int32(s!) { self = .one(id) } else { self = .none }
        }
    }

    static let selectionKey = "rfm1.midiInput"

    /// the sources that can be picked (not the FM-1, not excluded), as CoreMIDI lists them
    public private(set) var sources: [Source] = []
    public var selection: Selection {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.stored, forKey: Self.selectionKey)
            reconnect()
        }
    }
    /// a source someone else owns (the OMX-27 in REMOTE mode): never connected here. Call reconnect() when it changes
    @ObservationIgnored public var exclude: ((UInt32) -> Bool)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sink = Sink()
    #if canImport(CoreMIDI)
    @ObservationIgnored nonisolated(unsafe) private var client = MIDIClientRef()
    @ObservationIgnored nonisolated(unsafe) private var port = MIDIPortRef()
    @ObservationIgnored private var connected: [Int32: MIDIEndpointRef] = [:]
    #endif

    public init(host: (any PanelEngineHost)?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = Selection(stored: defaults.string(forKey: Self.selectionKey))
        sink.set(host)
        #if canImport(CoreMIDI)
        // (both blocks are @Sendable: CoreMIDI calls them on its own threads, and a block made here without it would be
        // main-actor isolated, which Swift 6 checks at run time: the app stopped at the first message)
        let st = MIDIClientCreateWithBlock("RemoteFM1 controllers" as CFString, &client) { @Sendable [weak self] n in
            let id = n.pointee.messageID
            guard id == .msgSetupChanged || id == .msgObjectAdded || id == .msgObjectRemoved else { return }
            Task { @MainActor in self?.reconnect() }
        }
        if st != noErr { client = 0 }
        if client != 0 {
            let s = sink
            let ps = MIDIInputPortCreateWithProtocol(client, "RemoteFM1 controllers in" as CFString, ._1_0, &port) { @Sendable list, _ in
                for p in list.unsafeSequence() { Self.decode(p.words()) { s.send($0, $1) } }
            }
            if ps != noErr { port = 0 }
        }
        reconnect()
        #endif
    }

    deinit {
        #if canImport(CoreMIDI)
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
        #endif
    }

    /// the engine the messages go to
    public func attach(_ host: (any PanelEngineHost)?) { sink.set(host) }

    /// the sources listed again and the picked ones connected (a setup change, `exclude` changed)
    public func reconnect() {
        #if canImport(CoreMIDI)
        var list: [Source] = []
        var want: [Int32: MIDIEndpointRef] = [:]
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0, !Self.offline(src), !Self.isFM1(src), exclude?(src) != true else { continue }
            var uid: Int32 = 0
            MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &uid)
            let on: Bool
            switch selection {
            case .all: on = true
            case .none: on = false
            case .one(let id): on = id == uid
            }
            if on { want[uid] = src }
            list.append(Source(id: uid, name: Self.name(src), connected: on && port != 0))
        }
        if port != 0 {
            for (uid, src) in connected where want[uid] != src { MIDIPortDisconnectSource(port, src) }
            for (uid, src) in want where connected[uid] != src { MIDIPortConnectSource(port, src, nil) }
            connected = want
        }
        if list != sources { sources = list }
        #endif
    }

    // MARK: the messages

    /// MIDI 1.0 UMP words -> channel messages (status, then 1 or 2 data bytes); every other message type is left out
    public nonisolated static func decode<S: Sequence>(_ words: S, _ emit: (UnsafePointer<UInt8>, Int) -> Void)
    where S.Element == UInt32 {
        var skip = 0
        for w in words {
            if skip > 0 {                               // (the rest of a longer message)
                skip -= 1
                continue
            }
            let mt = Int(w >> 28)
            skip = umpWords[mt] - 1
            if mt == 2 {                                // (MIDI 1.0 channel voice)
                let st = UInt8(truncatingIfNeeded: w >> 16)
                if st >= 0x80 && st < 0xF0 {
                    var b = (st, UInt8(truncatingIfNeeded: w >> 8) & 0x7F, UInt8(truncatingIfNeeded: w) & 0x7F)
                    let n = st & 0xE0 == 0xC0 ? 2 : 3   // (program change, channel pressure: one data byte)
                    withUnsafeBytes(of: &b) { emit($0.baseAddress!.assumingMemoryBound(to: UInt8.self), n) }
                }
            }
        }
    }
    private nonisolated static let umpWords = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]   // by message type

    /// decode, as arrays (tests)
    public nonisolated static func messages(_ words: [UInt32]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        decode(words) { out.append(Array(UnsafeBufferPointer(start: $0, count: $1))) }
        return out
    }

    /// the website's test for a port that is the FM-1 (RemoteFM1 on it), where RemoteMidi.c's rule can't look
    public nonisolated static func unitName(_ name: String) -> Bool {
        let n = name.lowercased()
        return (n.contains("fm-1") || n.contains("remotefm1")) && !n.contains("update")
    }

    // the CoreMIDI thread -> the engine (any thread but the audio thread: rfme_midi_in)
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private weak var host: (any PanelEngineHost)?
        func set(_ h: (any PanelEngineHost)?) { lock.withLock { host = h } }
        func send(_ b: UnsafePointer<UInt8>, _ n: Int) {
            guard let h = lock.withLock({ host }) else { return }
            h.withPanelEngine { _ = rfme_midi_in($0, b, UInt32(n), 0) }
        }
    }

    #if canImport(CoreMIDI)
    nonisolated static func name(_ o: MIDIObjectRef) -> String {
        var s: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(o, kMIDIPropertyDisplayName, &s) != noErr || s == nil {
            MIDIObjectGetStringProperty(o, kMIDIPropertyName, &s)
        }
        return (s?.takeRetainedValue() as String?) ?? ""
    }

    nonisolated static func offline(_ o: MIDIObjectRef) -> Bool {
        var v: Int32 = 0
        return MIDIObjectGetIntegerProperty(o, kMIDIPropertyOffline, &v) == noErr && v != 0
    }

    /// RemoteMidi.c's cm_scan, for a source: its device's USB IDs (none on Bluetooth MIDI), else an "FM-1" name; a
    /// source with no device (a virtual one): the website's name test
    nonisolated static func isFM1(_ src: MIDIEndpointRef) -> Bool {
        var ent = MIDIEntityRef(), dev = MIDIDeviceRef()
        guard MIDIEndpointGetEntity(src, &ent) == noErr, ent != 0 else { return unitName(name(src)) }
        MIDIEntityGetDevice(ent, &dev)
        var drv: Unmanaged<CFString>?
        if dev != 0 { MIDIObjectGetStringProperty(dev, kMIDIPropertyDriverOwner, &drv) }
        let bluetooth = ((drv?.takeRetainedValue() as String?) ?? "").localizedCaseInsensitiveContains("Bluetooth")
        var usb: Int32 = 0
        let key = "USBVendorProduct" as CFString      // (kMIDIPropertyUSBVendorProduct, no longer in the SDK)
        let hasUSB = !bluetooth && (MIDIObjectGetIntegerProperty(ent, key, &usb) == noErr
                                    || (dev != 0 && MIDIObjectGetIntegerProperty(dev, key, &usb) == noErr))
        let devName = dev != 0 ? name(dev) : ""
        return devName.withCString { d in name(src).withCString { e in rfme_fm1_candidate(hasUSB ? 1 : 0, usb, d, e) } } != 0
    }
    #endif
}
