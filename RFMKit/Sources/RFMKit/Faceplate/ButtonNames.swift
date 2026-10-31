// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The firmware's own button names (RemoteFM1 docs/BUTTON-LABELS.md): the running core's descriptor button_names
// (fm1core.h, FM1P_B_* order), read through the engine (rfme_button_names), and the rules for drawing them, as the
// website's panel.js buttonLabels: per button the firmware's name trimmed, else the printed one; all printed when the
// list is missing or not 14 long, or when the "Firmware's button names" setting is off; OCT-/OCT+ never renamed. The
// face shows the name upper-cased; a renamed button has its printed name drawn small beside the row.

import Foundation
import Observation
import RFMCore

public struct ButtonNames: Equatable, Sendable {
    /// the printed faceplate, by label (PanelFeed.Label)
    public static let printed = PanelFeed.Label.allCases.map(\.legend)
    public static let standard = ButtonNames(firmware: nil)

    /// what each button's face shows, by label (upper-cased)
    public let labels: [String]
    /// the button shows a name of the firmware's that differs from the printed one
    public let renamed: [Bool]

    public init(firmware: [String?]?, use: Bool = true) {
        let fw = use && firmware?.count == 14 ? firmware! : [String?](repeating: nil, count: 14)
        var l = [String](), r = [Bool]()
        for (i, p) in Self.printed.enumerated() {
            let n = (fw[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let mine = !n.isEmpty && i < PanelFeed.Label.octDown.rawValue && n != p
            l.append(mine ? n : p)
            r.append(mine)
        }
        labels = l
        renamed = r
    }

    public func label(_ l: PanelFeed.Label) -> String { labels[l.rawValue] }
    public func isRenamed(_ l: PanelFeed.Label) -> Bool { renamed[l.rawValue] }
    public var anyRenamed: Bool { renamed.contains(true) }

    /// a MIDI learn target as the user reads it: a renamed button "PERF (ARP)", anything else its id
    public func title(_ target: String) -> String {
        guard let t = MidiTarget.named(target), case .button(let l) = t.kind, isRenamed(l) else { return target }
        return "\(label(l)) (\(target))"
    }

    /// the engine's names now and rfme_button_names' number
    static func read(_ e: OpaquePointer) -> (names: ButtonNames, gen: UInt32) {
        var b = rfme_button_names_t()
        let g = rfme_button_names(e, &b)
        let raw: [String?] = withUnsafeBytes(of: &b.names) { p in
            (0..<14).map { i in String(decoding: p[(i * 48)..<(i * 48 + 48)].prefix { $0 != 0 }, as: UTF8.self) }
        }
        return (ButtonNames(firmware: b.loaded != 0 ? raw : nil, use: b.use != 0), g)
    }
}

/// the faceplate's names, observed by the buttons and MIDI learn's texts
@MainActor @Observable public final class ButtonNameFeed {
    public internal(set) var value = ButtonNames.standard
}
