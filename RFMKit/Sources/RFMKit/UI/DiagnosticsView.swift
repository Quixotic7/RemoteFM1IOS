// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The Diagnostics panel: a probe report's lines (ProbeReport.lines), in small monospace.

import SwiftUI

public struct DiagnosticsView: View {
    let title: String
    let report: ProbeReport?

    public init(title: String = "Diagnostics", report: ProbeReport?) {
        self.title = title
        self.report = report
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            if let report {
                let rows = report.lines
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    ForEach(rows.indices, id: \.self) { i in
                        GridRow {
                            Text(rows[i].0).foregroundStyle(.secondary)
                            Text(rows[i].1).textSelection(.enabled)
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            } else {
                Text("Probing…").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }
}
