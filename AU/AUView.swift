// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The extension's view (M4), compact for a host's plug-in window (~400 x 400 pt): the firmware picker and About, the
// LCD mirror, the panel's status, "Use this FM-1", Bluetooth, and Settings + M2's Diagnostics behind a disclosure.

import RFMKit
import SwiftUI

struct AUView: View {
    @Bindable var model: AUViewModel

    private static let bg = Color(red: 0.10, green: 0.11, blue: 0.14)
    private static let accent = Color(red: 1.0, green: 0.55, blue: 0.16)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                HStack(alignment: .top, spacing: 10) {
                    lcd
                    panel
                }
                if !model.status.coreError.isEmpty {
                    Text(model.status.coreError).font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("Settings and diagnostics", isExpanded: $model.diagnosticsOpen) {
                    VStack(alignment: .leading, spacing: 8) {
                        settings
                        Rows(rows: rows)
                        DiagnosticsView(report: model.report)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
            .padding(10)
        }
        .background(Self.bg)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Picker("Firmware", selection: Binding(get: { model.status.coreID }, set: { model.select($0) })) {
                ForEach(model.cores) { c in Text("\(c.name) \(c.version)").tag(c.id) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.cores.isEmpty)
            Button { model.onAbout?(model.current) } label: { Image(systemName: "info.circle") }
                .accessibilityLabel("About this firmware")
                .disabled(model.current == nil)
            Spacer(minLength: 4)
            Text(model.instance).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private var lcd: some View {
        Group {
            if let img = model.preview {
                Image(decorative: img, scale: 1).interpolation(.none).resizable()
            } else {
                Color.white.opacity(0.06)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 200)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12)))
        .accessibilityLabel("The firmware's screen")
    }

    private var panel: some View {
        let p = model.status.panel
        let s = model.status.core
        return VStack(alignment: .leading, spacing: 8) {
            Text(p?.line ?? "No panel link").font(.footnote.weight(.semibold))
                .foregroundStyle(p?.owner == true && p?.link.isConnected == true ? .green : p?.heldElsewhere == true ? Self.accent : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if p?.foreignSession == true {
                Text("The FM-1 had a session from elsewhere.").font(.caption2).foregroundStyle(.orange)
            }
            if let w = p?.leaseWarning { Text(w).font(.caption2).foregroundStyle(.orange) }
            if p?.owner != true {
                useButton(p)
            }
            Button { model.onBluetooth?() } label: {
                Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if s.halted {
                Text(String(format: "Firmware halted (exit %u)", s.haltCode & 0xFF)).font(.caption2).foregroundStyle(.orange)
                Button("Restart") { model.restart() }.buttonStyle(.bordered).controlSize(.small)
            }
            Text(s.booted ? "\(model.status.coreName), slot \(s.slot)" : "no firmware running")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func useButton(_ p: PanelStatus?) -> some View {
        let reason: String? = p == nil ? "no panel link" : p?.hasUnit == false ? "No FM-1 found: pair it over Bluetooth." : nil
        if p?.heldElsewhere == true {
            Button("Use this FM-1") { model.claim() }.buttonStyle(.borderedProminent).tint(Self.accent).disabled(reason != nil)
        } else {
            Button("Use this FM-1") { model.claim() }.buttonStyle(.bordered).disabled(reason != nil)
        }
        if let reason { Text(reason).font(.caption2).foregroundStyle(.secondary) }
    }

    private var settings: some View {
        Stepper(value: Binding(get: { model.status.settings.transpose }, set: { model.setTranspose($0) }), in: -2...2) {
            Text("MIDI octave \(model.status.settings.transpose > 0 ? "+" : "")\(model.status.settings.transpose)")
        }
        .font(.caption)
    }

    private var rows: [(String, String)] {
        let s = model.status, c = s.core, p = s.panel
        var r: [(String, String)] = [
            ("render", c.renders == 0 ? "–" : String(format: "avg %u us, max %u us per %u frames (%.0f%%)",
                                                    c.renderAvgUs, c.renderMaxUs, c.renderLastFrames, c.renderLoad * 100)),
            ("clock", ["stopped", "audio", "timer (no sound)", "caller"][min(max(c.clock, 0), 3)]),
            ("MIDI", "in \(s.midiIn) (\(s.midiNotes) notes), out \(s.midiOutMsgs)"),
            ("flash", "\(c.flashSize / 1024) KiB, from \(s.bootedFrom.isEmpty ? "–" : s.bootedFrom)"),
        ]
        if let p {
            r.append(("lease", "epoch \(p.epoch), \(p.owner ? "owner" : p.leaseEmpty ? "empty" : p.ownerStale ? "stale" : "held")"
                      + (p.ownerName.isEmpty ? "" : ": \(p.ownerName)")))
            r.append(("link", p.linkText))
            if p.duplicate { r.append(("identity", "a duplicated state: a new UUID")) }
        }
        return r
    }
}
