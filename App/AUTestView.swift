// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AU test screen: the extension's own view (instance A) on top, then each step's answer and this app's probes.

import RFMKit
import SwiftUI
import UIKit

struct AUTestView: View {
    @State var host: AUTestHost
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("AU test").font(.title2.bold())
                    Spacer()
                    if !host.auto {
                        Button("Close") { dismiss() }.buttonStyle(.bordered)
                    }
                    Button(host.running ? "Running…" : "Run") { Task { await host.run() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.running)
                }
                if let vc = host.auView {
                    EmbeddedViewController(vc: vc)
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DebugTheme.line))
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(host.summary.steps) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(s.ok.map { $0 ? "ok" : "NO" } ?? "–")
                                .foregroundStyle(s.ok.map { $0 ? Color.green : Color.red } ?? .secondary)
                                .frame(width: 22, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name).fontWeight(.semibold)
                                Text(s.detail).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                DiagnosticsView(title: "This app's probes", report: host.appReport)
            }
            .padding(16)
        }
        .background(DebugTheme.background.ignoresSafeArea())
        .task { if host.auto { await host.run() } }
    }
}

/// a UIKit view controller (the AU's, from requestViewController) as a child of a plain container
private struct EmbeddedViewController: UIViewControllerRepresentable {
    let vc: UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        let c = UIViewController()
        c.addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        c.view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: c.view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: c.view.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: c.view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: c.view.bottomAnchor),
        ])
        vc.didMove(toParent: c)
        return c
    }

    func updateUIViewController(_ c: UIViewController, context: Context) {}
}
