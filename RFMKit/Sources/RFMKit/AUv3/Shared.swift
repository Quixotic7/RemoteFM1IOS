// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Names the app and the AUv3 extension share: the App Group, the component, the notification names, the lease's file.
// The AU's state: the instance (InstanceState) and, from M4, its core (CoreState).

import AudioToolbox
import Foundation
import os

public enum RFMShared {
    public static let appGroup = "group.com.quixotic7.remotefm1"
    public static let subsystem = "com.quixotic7.remotefm1"
    public static let diagnosticsChannel = "com.quixotic7.remotefm1.diagnostics"   // AUMessageChannel
    /// the lease's Darwin notification (PLAN.md section 4)
    public static let leaseNotification = "\(appGroup).lease"
    /// the extension's link backend, written by the app's AU test before it instantiates (the extension has no
    /// launch arguments): a file in the App Group container holding "fake" or "device"
    public static let extensionBackendFile = "au-backend.txt"

    /// type aumu, subtype Rfm1, manufacturer Qx7u (FM1VST's)
    public static let component = AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice, componentSubType: fourCC("Rfm1"),
        componentManufacturer: fourCC("Qx7u"), componentFlags: 0, componentFlagsMask: 0)

    /// Darwin notification / notify(3) names: prefixed with the App Group (what a sandbox lets through)
    static func name(_ what: String, _ role: ProbeRole) -> String { "\(appGroup).\(what).\(role.rawValue)" }

    public static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    public static func log(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }

    /// The App Group container, nil when the process has no working group (no entitlement, or not signed with it)
    public static func groupContainer() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Where a process writes files the shell (scripts/sim_autest.sh) or the other process can read: the App Group
    /// container if it works, else the process's own Documents (or tmp).
    public static func outputDirectory() -> (url: URL, shared: Bool) {
        if let g = groupContainer() { return (g, true) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docs, (try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)) != nil {
            return (docs, false)
        }
        return (FileManager.default.temporaryDirectory, false)
    }

    /// The lease's file: the App Group container's lease.bin, else (shared false) this process's own Application
    /// Support (the lease then covers only this process)
    public static func leaseLocation() -> (url: URL, shared: Bool) {
        if let g = groupContainer() { return (g.appendingPathComponent("lease.bin"), true) }
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("lease.bin"), false)
    }

    /// The extension's backend as the App Group file says ("fake", "device"), nil: no file
    public static func extensionBackend() -> String? {
        guard let g = groupContainer(),
              let s = try? String(contentsOf: g.appendingPathComponent(extensionBackendFile), encoding: .utf8)
        else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public static func setExtensionBackend(_ b: String?) {
        guard let g = groupContainer() else { return }
        let url = g.appendingPathComponent(extensionBackendFile)
        if let b { try? Data(b.utf8).write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
    }
}

/// The AU's own part of its fullState: the instance UUID (the identity PLAN.md section 4's lease uses) and a format
/// version (1: M2; 2: M4, with CoreState). Plist types only, so any host can store it.
public struct InstanceState: Equatable, Sendable {
    public static let currentFormat = 2
    public static let instanceKey = "rfm1.instance"
    public static let formatKey = "rfm1.format"

    public var instance: UUID
    public var format: Int

    public init(instance: UUID = UUID(), format: Int = InstanceState.currentFormat) {
        self.instance = instance
        self.format = format
    }

    /// nil when the dictionary has no (valid) instance UUID: a state from before M2, or not ours
    public init?(_ dict: [String: Any]?) {
        guard let s = dict?[Self.instanceKey] as? String, let u = UUID(uuidString: s) else { return nil }
        instance = u
        format = (dict?[Self.formatKey] as? NSNumber)?.intValue ?? 0
    }

    public func encode(into dict: inout [String: Any]) {
        dict[Self.instanceKey] = instance.uuidString
        dict[Self.formatKey] = format
    }

    public var short: String { String(instance.uuidString.prefix(8)) }
}

/// The instance's per-instance settings (FM1VST's MIDI options; the host's clock, PLAN.md section 11)
public struct AUSettings: Equatable, Sendable {
    public var notesPlayKeys = true             // MIDI notes 53.. play the FM-1's keys
    public var transpose = 0                    // octaves, -2..2
    public var keyNotesToFirmware = false       // the notes that played a key also go to the firmware's MIDI in
    public var hostClock = true                 // the host's tempo and transport as MIDI clock to the firmware
    public init() {}

    init(_ d: [String: Any]?) {
        notesPlayKeys = (d?["notesPlayKeys"] as? NSNumber)?.boolValue ?? true
        transpose = max(-2, min(2, (d?["transpose"] as? NSNumber)?.intValue ?? 0))
        keyNotesToFirmware = (d?["keyNotesToFirmware"] as? NSNumber)?.boolValue ?? false
        hostClock = (d?["hostClock"] as? NSNumber)?.boolValue ?? true
    }

    var dict: [String: Any] {
        ["notesPlayKeys": notesPlayKeys, "transpose": transpose, "keyNotesToFirmware": keyNotesToFirmware,
         "hostClock": hostClock]
    }
}

/// The core part of the AU's fullState (M4): which firmware, its version, its flash image (LZFSE-compressed; taken
/// after flash_sync) and the instance's settings. Restoring boots the core from this flash, also when the version
/// changed (as FM1VST does). No flash: a fresh one. M7: also its kind ("native", or "wasm": an imported .rfm1) and the
/// file's SHA-256 (RFM1-FORMAT.md section 7 step 5); `core` stays the firmware's own id. A state from before M7 has
/// neither: a built-in core.
public struct CoreState: Equatable, Sendable {
    public static let coreKey = "rfm1.core"
    public static let versionKey = "rfm1.coreVersion"
    public static let flashKey = "rfm1.flash"
    public static let flashSizeKey = "rfm1.flashSize"
    public static let flashCodecKey = "rfm1.flashCodec"
    public static let settingsKey = "rfm1.settings"
    public static let kindKey = "rfm1.coreKind"
    public static let sha256Key = "rfm1.coreSHA256"

    public var core: String
    public var version: String
    public var flash: Data?                     // the image, uncompressed
    public var settings: AUSettings
    public var kind: String                     // "native" | "wasm"
    public var sha256: String                   // an imported file's ("" for a built-in core)

    public init(core: String, version: String, flash: Data?, settings: AUSettings = AUSettings(), kind: String = "native",
                sha256: String = "") {
        self.core = core
        self.version = version
        self.flash = flash
        self.settings = settings
        self.kind = kind
        self.sha256 = sha256
    }

    /// the firmware this state names, for CoreRef.resolve
    public var ref: CoreRef { CoreRef(kind: kind, id: core, version: version, sha256: sha256) }

    /// nil: no core in the dictionary (a state from M2, or a new instance)
    public init?(_ dict: [String: Any]?) {
        guard let d = dict, let c = d[Self.coreKey] as? String, !c.isEmpty else { return nil }
        core = c
        version = d[Self.versionKey] as? String ?? ""
        settings = AUSettings(d[Self.settingsKey] as? [String: Any])
        kind = d[Self.kindKey] as? String ?? "native"
        sha256 = d[Self.sha256Key] as? String ?? ""
        flash = nil
        if let z = d[Self.flashKey] as? Data {
            let n = (d[Self.flashSizeKey] as? NSNumber)?.intValue ?? 0
            if (d[Self.flashCodecKey] as? String ?? "lzfse") == "raw" {
                flash = z
            } else if let raw = try? (z as NSData).decompressed(using: .lzfse) as Data, n == 0 || raw.count == n {
                flash = raw
            }
        }
    }

    public func encode(into d: inout [String: Any]) {
        d[Self.coreKey] = core
        d[Self.versionKey] = version
        d[Self.settingsKey] = settings.dict
        d[Self.kindKey] = kind
        if !sha256.isEmpty { d[Self.sha256Key] = sha256 }
        if let flash {
            if let z = try? (flash as NSData).compressed(using: .lzfse) as Data {
                d[Self.flashKey] = z
                d[Self.flashCodecKey] = "lzfse"
            } else {
                d[Self.flashKey] = flash
                d[Self.flashCodecKey] = "raw"
            }
            d[Self.flashSizeKey] = flash.count
        }
    }
}
