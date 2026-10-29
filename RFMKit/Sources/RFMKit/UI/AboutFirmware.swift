// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// "About this firmware" (the app's and the AU's): name, version, licence, source and credits of a core; and Rows,
// label: value rows in small monospace. Moved here from the app in M4. M7: an imported .rfm1 shows its manifest
// (authors, the source and glue links, tappable), its credits and its licence texts (FirmwareCatalog.details), and,
// in the app, a Delete button.

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
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    /// onDone: how a UIKit presentation closes it (the extension: SwiftUI's sheet crashed there, M2); nil: dismiss.
    /// onDelete: an imported file's Delete button (the app; nil: none)
    public init(info: CoreInfo?, onDone: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self.info = info
        self.onDone = onDone
        self.onDelete = onDelete
    }

    private func close() { if let onDone { onDone() } else { dismiss() } }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let c = info, c.imported {
                        imported(c, FirmwareCatalog.shared.details(c.sha256))
                    } else if let c = info {
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
                    Text("This app is free software under the GNU General Public License, version 3 (GPL-3.0-only). "
                         + (info.map {
                             $0.imported
                                 ? "The firmware above is an imported file under \(Self.licence($0.license)), from its author's "
                                   + "release; it runs in the app's WebAssembly interpreter (wasm3, MIT). Its source is at the "
                                   + "link above."
                                 : "The firmware above is free software under \(Self.licence($0.license)); it runs as "
                                   + "built from the source named above, through FM1VST's core interface." } ?? ""))
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle("About this firmware")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
        }
        .preferredColorScheme(.dark)
    }

    /// an imported .rfm1: the manifest's fields, the links, credits, licence texts, and Delete
    @ViewBuilder private func imported(_ c: CoreInfo, _ d: FirmwareDetails) -> some View {
        Text("\(c.name) \(c.version)").font(.title2.bold())
        Text("Imported firmware (.rfm1)").font(.subheadline).foregroundStyle(.secondary)
        Rows(rows: [
            ("licence", c.license),
            ("authors", d.authors.isEmpty ? "–" : d.authors.joined(separator: ", ")),
            ("id", c.firmwareID),
            ("file", c.fileName.isEmpty ? "–" : c.fileName),
            ("size", "\(c.fileSize / 1024) KiB"),
            ("SHA-256", String(c.sha256.prefix(16)) + "…"),
        ] + (d.builtBy.isEmpty ? [] : [("built by", d.builtBy)]))
        Text("Source").font(.headline)
        link(d.sourceURL)
        if !d.glueURL.isEmpty {
            Text("Build glue").font(.headline)
            link(d.glueURL)
        }
        if !d.credits.isEmpty {
            Text("Credits and notices").font(.headline)
            Text(d.credits).font(.footnote).textSelection(.enabled)
        }
        if !d.licenses.isEmpty {
            Text("Licences").font(.headline)
            ForEach(d.licenses.indices, id: \.self) { i in
                let t = d.licenses[i]
                DisclosureGroup(String(t.prefix { $0 != "\n" })) {
                    Text(t.drop { $0 != "\n" }.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }
        }
        if let onDelete {
            Button(role: .destructive) { confirmDelete = true } label: { Text("Delete this file") }
                .padding(.top, 6)
                .confirmationDialog("Delete \(c.fileName.isEmpty ? c.name : c.fileName)?", isPresented: $confirmDelete,
                                    titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        onDelete()
                        close()
                    }
                }
        }
    }

    @ViewBuilder private func link(_ s: String) -> some View {
        if let u = URL(string: s), u.scheme == "https" || u.scheme == "http" {
            Link(s, destination: u).font(.system(.footnote, design: .monospaced))
        } else {
            Text(s.isEmpty ? "–" : s).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
        }
    }

    static func licence(_ spdx: String) -> String {
        switch spdx {
        case "GPL-3.0-only": return "the GNU General Public License, version 3 (GPL-3.0-only)"
        case "MPL-2.0": return "the Mozilla Public License, version 2.0 (MPL-2.0)"
        case "": return "its own licence"
        default: return spdx
        }
    }
}
