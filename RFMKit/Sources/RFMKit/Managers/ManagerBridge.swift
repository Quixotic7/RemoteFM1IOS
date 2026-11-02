// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The firmwares' own web editors (PLAN.md section 18 step 5), opened at their authors' pages. The app injects a whole
// Web MIDI into the page (ManagerPage.webMIDI): one port named as the firmware's USB port, MIDI both ways through a
// WKScriptMessageHandler. What the page sends goes to the running firmware's MIDI in (SysEx whole:
// rfme_sysex_in; the rest: rfme_midi_in to the firmware); what the firmware sends (rfme_midi_out_take's USB-MIDI
// packets, put back together by UsbMidiDecoder) goes to the page.
//   ManagerList     the managers the site has, by firmware id, and each firmware's USB port name
//   UsbMidiDecoder  USB-MIDI event packets -> whole MIDI messages (SysEx across packets)

import Foundation

/// the firmwares' editors: always the author's own page (the owner, 2026-11-01). remotefm1.com's copies of five of
/// them (made for the site's player, which needs its fm1-shim.js) fell behind their authors' pages; the app needs no
/// copy, as its Web MIDI works on any page
public enum ManagerList {
    /// the authors' pages for the firmwares the catalog may not list an editor for (or before the catalog is read)
    public static let authors: [String: URL] = [
        "choralroot": URL(string: "https://quixotic7.github.io/ChoralRootFM1/webapp/installer/manager.html")!,
        "purplemonkey": URL(string: "https://quixotic7.github.io/ChoralRootFM1/webapp/installer/manager.html")!,
        "felucca": URL(string: "https://hugelton.github.io/Felucca/webapp/editor/")!,
        "melodee": URL(string: "https://keremimo.github.io/melodee/webapp/editor/")!,
        "jiant": URL(string: "https://juanjiant-bit.github.io/JIANT/webapp/editor/")!,
        "ghoulbox": URL(string: "https://jasonpersinger.me/ghoulbox-fm1-dungeon-synth/webapp/editor/")!,
    ]

    /// each firmware's real USB MIDI port name: the name the page's port takes (managers.json "ports")
    public static let ports: [String: String] = [
        "choralroot": "ChoralRoot FM-1", "purplemonkey": "ChoralRoot FM-1", "coralflower": "CoralFlower FM-1",
        "felucca": "Felucca", "ghoulbox": "Felucca", "amb": "Felucca", "obervave": "Felucca", "frodhes": "Felucca",
        "melodee": "Melodee FM-1", "jiant": "JIANT FM", "fomni": "FoMni FM-1", "fimba": "FiMba FM-1",
        "loom": "LOOM-8 FM-1", "duell": "DUELL", "minitone": "Felucca", "fmini": "FM-1 Midi", "skiff": "Felucca",
        "grimm": "Felucca", "pigeon": "PIGEON", "tonitor": "FM-1 Tonitor", "speak37": "Speak37",
    ]

    /// managers opened at their author's page rather than the site's copy, which lags behind (ChoralRoot's reads
    /// Digitone .syx, .dn2pst and .dn2snd; the site's copy of 2026-11 didn't). The app's Web MIDI works on any page
    public static let upstream: [String: URL] = [
        "choralroot": URL(string: "https://quixotic7.github.io/ChoralRootFM1/webapp/installer/manager.html")!,
        "purplemonkey": URL(string: "https://quixotic7.github.io/ChoralRootFM1/webapp/installer/manager.html")!,
    ]

    /// the author's editor known to the app, nil: none
    public static func url(for firmwareID: String) -> URL? { authors[firmwareID] }

    public static func port(for firmwareID: String, name: String) -> String { ports[firmwareID] ?? name }

    /// the editor page to open: the catalog's `editor` (the author's page, https only), else the one the app knows;
    /// nil: none
    public static func editor(for firmwareID: String, details: [String: AvailableFirmware]) -> URL? {
        if let s = details[firmwareID]?.editor, let u = URL(string: s), u.scheme == "https" { return u }
        return url(for: firmwareID)
    }
}

/// USB-MIDI event packets (cable 0, the CIN in the low nibble, bytes 1..3 above it: rfme_midi_out_take's packing) back
/// into whole messages; SysEx over several packets
public struct UsbMidiDecoder {
    private var sysex: [UInt8] = []
    public static let maxSysEx = 64 * 1024

    public init() {}

    /// the message this packet completes, if any
    public mutating func feed(_ p: UInt32) -> [UInt8]? {
        let cin = p & 0xF
        let b = [UInt8(truncatingIfNeeded: p >> 8), UInt8(truncatingIfNeeded: p >> 16), UInt8(truncatingIfNeeded: p >> 24)]
        switch cin {
        case 0x4:                                        // SysEx starts or goes on: three bytes
            if b[0] == 0xF0 { sysex = [] }
            if sysex.count < Self.maxSysEx { sysex += b }
            return nil
        case 0x5, 0x6, 0x7:                              // SysEx ends with 1 / 2 / 3 bytes (or a 1-byte system common)
            let n = Int(cin) - 4
            if cin == 0x5, b[0] != 0xF7, sysex.isEmpty { return [b[0]] }
            let end = sysex + b.prefix(n)
            sysex = []
            return end.first == 0xF0 ? end : nil
        case 0x2: return Array(b.prefix(2))              // two-byte system common
        case 0x3: return Array(b.prefix(3))              // three-byte system common
        case 0x8, 0x9, 0xA, 0xB, 0xE: return Array(b.prefix(3))
        case 0xC, 0xD: return Array(b.prefix(2))
        case 0xF: return [b[0]]                          // single byte (realtime)
        default: return nil
        }
    }
}
