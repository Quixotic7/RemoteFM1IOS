// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// How the firmware lists show the cores (the owner, 2026-11-01):
//   superseded   a built-in core with a newer imported .rfm1 of the same firmware is left out of the lists (the
//                newer one is what the user wants; two of the same name confused testers). Shown again when the
//                newer file is deleted, and while it is the one selected
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

    /// the built-in cores that an imported, newer version of the same firmware replaces in the lists
    public static func superseded(_ cores: [CoreInfo]) -> Set<String> {
        let imported = cores.filter(\.imported)
        return Set(cores.filter { b in
            !b.imported && imported.contains { $0.firmwareID == b.firmwareID && FirmwareVersion.less(b.version, $0.version) }
        }.map(\.id))
    }

    /// the cores to list: the superseded built-ins left out (unless selected)
    public static func visible(_ cores: [CoreInfo], selected: String) -> [CoreInfo] {
        let hide = superseded(cores)
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
