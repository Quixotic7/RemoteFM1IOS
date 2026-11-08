// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// What RemoteController publishes: the link's state, the unit's HELLO_R, the session's numbers, the panel's events.

import Foundation

public enum Backend: Sendable, Equatable {
    case device                         // CoreMIDI: HELLO only to endpoints that can be an FM-1
    case fake(bluetooth: Bool)          // libremotefm1's fake unit, in this process

    public var isFake: Bool { if case .fake = self { true } else { false } }
}

public enum LinkState: Sendable, Equatable {
    case stopped(String)                // why ("" when asked to)
    case searching
    case notFound                       // still searching, nothing answered for a while
    case starting                       // found the unit, SESSION sent
    case connected(bluetooth: Bool)
    case inUse(String)                  // another RemoteLink holds the unit lock
    case lost                           // was connected; searching again
    case error(String)
    case stopping

    public var title: String {
        switch self {
        case .stopped: "Stopped"
        case .searching: "Searching…"
        case .notFound: "Not found"
        case .starting: "Starting…"
        case .connected(let ble): ble ? "Connected over Bluetooth" : "Connected over USB"
        case .inUse: "In use"
        case .lost: "Unit lost: searching…"
        case .error: "Error"
        case .stopping: "Stopping…"
        }
    }

    public var isConnected: Bool { if case .connected = self { true } else { false } }
}

/// The unit's HELLO_R (docs/PROTOCOL.md section 2).
public struct UnitHello: Sendable, Equatable {
    public var name = "", version = "", firmwareVersion = "", identity = ""
    public var proto: UInt8 = 0
    public var transports: UInt8 = 0    // RFM_TR_* bits
    public var usbMode: UInt8 = 0
    public var caps: UInt16 = 0         // RFM_CAP_* bits
    public var sxq: UInt16 = 0
    public var sxBodyMax: UInt16 = 0, bkBodyMax: UInt16 = 0
    public var screenW: UInt16 = 0, screenH: UInt16 = 0
    public var maxInFlight: UInt8 = 0
    public var isBluetooth = false      // rfm_hello_is_ble: this reply came over Bluetooth MIDI
    public var session = false          // session8: a session is running (anyone's)

    public init() {}

    public var transportNames: String {
        Self.bits(Int(transports), ["USB", "bulk", "SysEx heard", "bulk heard", "BLE", "BLE heard"])
    }
    public var capNames: String {
        Self.bits(Int(caps), ["shadow", "COPY", "RLE", "PAL", "battery", "PLAY green", "5 LED levels", "HOLD",
                              "BLE fast", "MIDI in", "TOUCH", "BLE audio"])
    }
    /// RemoteFM1 0.3.6: the FM-1 can play the host's sound over Bluetooth (RFM_CAP_BLE_AUDIO)
    public var hasBleAudio: Bool { caps & 0x800 != 0 }
    static func bits(_ v: Int, _ names: [String]) -> String {
        let on = names.indices.filter { v & (1 << $0) != 0 }.map { names[$0] }
        return on.isEmpty ? "none" : on.joined(separator: " ")
    }
}

/// The session's numbers (rfm_session_stats_t, through RemoteLink's status).
public struct LinkStats: Sendable, Equatable {
    public var fps: Float = 0
    public var runs: UInt32 = 0, sessions: UInt32 = 0, discoveries: UInt32 = 0
    public var frames: UInt32 = 0, acks: UInt32 = 0, pending: UInt32 = 0, inFlight: UInt32 = 0
    public var ackMsLast: UInt32 = 0, ackMsAvg: UInt32 = 0, ackMsMax: UInt32 = 0, ackTimeouts: UInt32 = 0
    public var wireBytes: UInt32 = 0, bodyBytes: UInt32 = 0
    public var budget: UInt32 = 0, wireCap: UInt32 = 0, frameMs: UInt32 = 0
    public var ble = false, hold = false
    public var held: UInt32 = 0, reduced: UInt32 = 0, refined: UInt32 = 0, colors: UInt32 = 0
    public var eventsIn: UInt32 = 0, eventsDropped: UInt32 = 0, snapshots: UInt32 = 0
    public var trsMidiIn: UInt32 = 0, trsMidiDropped: UInt32 = 0   // the unit's TRS MIDI in (RFM_CAP_MIDI_IN) to the core
    // TOUCH (RemoteFM1 0.3.1): asked (RFMC_TOUCH_*), in force as the unit's PANEL_R confirms, TOUCH messages sent
    public var touchWanted: UInt32 = 0, touch: UInt32 = 0, touchSent: UInt32 = 0
    // Bluetooth audio (RemoteFM1 0.3.6): asked; the FM-1 plays the sound (no screen sent); the stream's rate; AUDIO
    // blocks sent, their bytes; the unit's last AUDIO_R; samples the link's ring had no room for
    public var audioWanted = false, audio = false
    public var audioRate: UInt32 = 0, audioBlocks: UInt32 = 0, audioWire: UInt32 = 0
    public var audioBufferMs: UInt32 = 0, audioFillMs: UInt32 = 0, audioLost: UInt32 = 0, audioUnderruns: UInt32 = 0
    public var audioSkipped: UInt32 = 0, audioOverflow: UInt32 = 0
    public init() {}

    /// the settings line while the FM-1 plays the sound
    public var audioText: String {
        guard audio else { return audioWanted ? "Asking the FM-1 to play the sound…" : "Off" }
        return String(format: "Your FM-1 plays the sound: %.3f kHz, %u ms buffer (%u ms now), %u underruns, %u lost",
                      Double(audioRate) / 1000, audioBufferMs, audioFillMs, audioUnderruns, audioLost)
    }

    /// the Diagnostics line: whether the firmware has TOUCH (HELLO_R caps), what was asked, what PANEL_R confirms
    public func touchText(hello: UnitHello?) -> String {
        Self.touchText(caps: hello?.caps, wanted: touchWanted, inForce: touch, sent: touchSent)
    }

    public static func touchText(caps: UInt16?, wanted: UInt32, inForce: UInt32, sent: UInt32) -> String {
        func names(_ f: UInt32) -> String {
            let n = [f & 1 != 0 ? "velocity" : nil, f & 2 != 0 ? "pressure" : nil].compactMap { $0 }
            return n.isEmpty ? "none" : n.joined(separator: " + ")
        }
        guard let caps else { return wanted == 0 ? "off" : "on (no FM-1 yet)" }
        guard caps & 0x400 != 0 else {
            return "not in this firmware (RemoteFM1 0.3.1+): velocity 100, no pressure"
        }
        if wanted == 0 { return "off: velocity 100, no pressure (firmware has TOUCH)" }
        return "asked \(names(wanted)); FM-1 confirms \(names(inForce))" + (inForce == wanted ? "" : " (not yet)")
            + ", \(sent) sent"
    }
}

/// One panel event from the unit (matrix numbers, as the protocol has them).
public struct PanelEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case key, button, encoder, master, pressure, release }
    public let id: UInt32               // arrival order
    public let kind: Kind
    public let index: Int
    public let value: Int               // key / button 1 down 0 up; encoder detents; MASTER 0..1023; pressure 0..127
    public var velocity = 0             // a key down: its velocity (TOUCH), 0 none given
    public let resync: Bool             // a PANEL_R correction, not a MIDI event

    public static let buttonNames = ["OCT-", "OCT+", "FX", "SEL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE", "ARP",
                                     "SEQ", "PLAY", "REC"]
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// note key k (0 = F3, MIDI 53)
    public static func keyName(_ k: Int) -> String {
        let n = 53 + k
        return "\(noteNames[n % 12])\(n / 12 - 1)"
    }

    public var text: String {
        let r = resync ? " (PANEL_R)" : ""
        switch kind {
        case .key: return "key \(index) \(Self.keyName(index)) \(value != 0 ? "down" : "up")"
            + (value != 0 && velocity > 0 ? " vel \(velocity)" : "") + r
        case .pressure: return "key \(index) \(Self.keyName(index)) pressure \(value)\(r)"
        case .button:
            let n = index < Self.buttonNames.count ? Self.buttonNames[index] : "\(index)"
            return "button \(n) \(value != 0 ? "down" : "up")\(r)"
        case .encoder: return "encoder \(index) \(value > 0 ? "+" : "")\(value)\(r)"
        case .master: return "MASTER \(value)\(r)"
        case .release: return "all up (session ended)"
        }
    }
}
