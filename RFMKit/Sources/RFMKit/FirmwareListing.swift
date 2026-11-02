// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// How the firmware lists show the cores (the owner, 2026-11-01):
//   superseded   only each firmware's newest version is listed (older ones, built in or imported, confused
//                testers); an older one still loads a state made with it, and shows while it is the one selected
//   sorting      by name (the catalog's order), recently used (each firmware's last selection, UserDefaults by
//                firmware id), or recently updated (the release date of its newest version, FirmwareStore.updated)

import Foundation

public enum FirmwareListing {
    public enum Sort: String, CaseIterable, Identifiable, Sendable {
        case name, used, updated
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .name: "Name"
            case .used: "Recently used"
            case .updated: "Recently updated"
            }
        }
    }

    static let usedKey = "firmware.lastUsed"

    /// the cores a newer version of the same firmware replaces in the lists: every older version, built in or
    /// imported; of two of the same version, the built-in one stays (it runs natively), else the one added last (a
    /// rebuild: RemoteFM1FW keeps the version when only the glue changed), else the first. added: by SHA-256
    public static func superseded(_ cores: [CoreInfo], added: [String: Date] = [:]) -> Set<String> {
        var best: [String: CoreInfo] = [:]
        for c in cores {
            guard let b = best[c.firmwareID] else { best[c.firmwareID] = c; continue }
            switch FirmwareVersion.compare(c.version, b.version) {
            case .orderedDescending: best[c.firmwareID] = c
            case .orderedSame where b.imported && !c.imported: best[c.firmwareID] = c
            case .orderedSame where b.imported && c.imported && (added[c.sha256] ?? .distantPast) > (added[b.sha256] ?? .distantPast):
                best[c.firmwareID] = c
            default: break
            }
        }
        return Set(cores.filter { best[$0.firmwareID]?.id != $0.id }.map(\.id))
    }

    /// the cores to list: each firmware's newest version (and the selected one)
    public static func visible(_ cores: [CoreInfo], selected: String, added: [String: Date] = [:]) -> [CoreInfo] {
        let hide = superseded(cores, added: added)
        return cores.filter { !hide.contains($0.id) || $0.id == selected }
    }

    /// a firmware selected now (recently used)
    public static func used(_ c: CoreInfo, at: Date = Date(), defaults: UserDefaults = .standard) {
        var d = defaults.dictionary(forKey: usedKey) as? [String: Double] ?? [:]
        d[c.firmwareID] = at.timeIntervalSince1970
        defaults.set(d, forKey: usedKey)
    }

    public static func lastUsed(_ firmwareID: String, defaults: UserDefaults = .standard) -> Date? {
        (defaults.dictionary(forKey: usedKey) as? [String: Double])?[firmwareID].map { Date(timeIntervalSince1970: $0) }
    }

    /// the cores in this order (ties and unknown dates keep the given order, after the dated ones)
    public static func sorted(_ cores: [CoreInfo], by sort: Sort, updated: (String) -> Date?,
                              defaults: UserDefaults = .standard) -> [CoreInfo] {
        if sort == .name { return cores }
        return cores.enumerated().map {
            ($0.offset, $0.element, sort == .used ? lastUsed($0.element.firmwareID, defaults: defaults) : updated($0.element.firmwareID))
        }
            .sorted { a, b in
                switch (a.2, b.2) {
                case let (x?, y?) where x != y: x > y
                case (_?, nil): true
                case (nil, _?): false
                default: a.0 < b.0
                }
            }
            .map(\.1)
    }
}
