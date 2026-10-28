// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// "About this firmware" (the app's and the AU's): name, version, licence, source and credits of a core; and Rows,
// label: value rows in small monospace. Moved here from the app in M4.

import SwiftUI

/// label: value rows in small monospace
public struct Rows: View {
    let rows: [(String, String)]

    public init(rows: [(String, String)]) { self.rows = rows }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0).foregroundStyle(.secondary)
                    Text(rows[i].1).textSelection(.enabled)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
    }
}

/// name, version, licence, source and credits of the firmware: the GPL and the cores' notices, visible
public struct AboutFirmware: View {
    let info: CoreInfo?
    let onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// onDone: how a UIKit presentation closes it (the extension: SwiftUI's sheet crashed there, M2); nil: dismiss
    public init(info: CoreInfo?, onDone: (() -> Void)? = nil) {
        self.info = info
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let c = info {
                        Text("\(c.name) \(c.version)").font(.title2.bold())
                        Rows(rows: [
                            ("licence", c.license),
                            ("family", c.family),
                            ("core ABI", "\(c.abi)"),
                            ("flash", "\(c.flashSize / 1024) KiB"),
                            ("slots", "\(c.slots) (\(c.inUse) in use)"),
                        ])
                        Text("Source").font(.headline)
                        Text(c.sourceURL).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        if !c.credits.isEmpty {
                            Text("Credits and notices").font(.headline)
                            Text(c.credits).font(.footnote).textSelection(.enabled)
                        }
                    }
                    Text("RemoteFM1").font(.headline)
                    Text("This app and the firmware above are free software under the GNU General Public License, "
                         + "version 3 (GPL-3.0-only). The firmware runs as built from the source named above, through "
                         + "FM1VST's core interface.")
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle("About this firmware")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { if let onDone { onDone() } else { dismiss() } } } }
        }
        .preferredColorScheme(.dark)
    }
}
