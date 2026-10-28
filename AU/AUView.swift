// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The extension's view (M2): its name, the instance UUID, the Bluetooth MIDI panel and the probes' Diagnostics.

import RFMKit
import SwiftUI

struct AUView: View {
    let model: AUViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("RemoteFM1").font(.title3.bold())
                    Spacer()
                    Text("instance \(model.instance)").font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("AUv3 test build (M2): no core, renders silence.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { model.onBluetooth?() } label: {
                    Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                DiagnosticsView(report: model.report)
            }
            .padding(12)
        }
        .background(Color(red: 0.10, green: 0.11, blue: 0.14))
        .preferredColorScheme(.dark)
    }
}
