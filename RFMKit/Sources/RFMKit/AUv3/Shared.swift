// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Names the app and the AUv3 extension share: the App Group, the component, the notification names.

import AudioToolbox
import Foundation
import os

public enum RFMShared {
    public static let appGroup = "group.com.quixotic7.remotefm1"
    public static let subsystem = "com.quixotic7.remotefm1"
    public static let diagnosticsChannel = "com.quixotic7.remotefm1.diagnostics"   // AUMessageChannel

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
}

/// The AU's own part of its fullState: the instance UUID (the identity PLAN.md section 4's lease uses) and a format
/// version. Plist types only, so any host can store it.
public struct InstanceState: Equatable, Sendable {
    public static let currentFormat = 1
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
