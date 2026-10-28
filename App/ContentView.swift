// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The one screen: the link's state and controls, the frame being sent, the unit's HELLO_R, the link's numbers and
// the panel's last events. Two columns on a regular width (iPad), one on an iPhone.

import RFMKit
import SwiftUI

struct ContentView: View {
    let controller: RemoteController
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showBluetooth = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                controls
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 16) { preview; PanelCard(controller: controller) }
                            .frame(maxWidth: 480)
                        VStack(spacing: 16) { UnitCard(controller: controller); LinkCard(controller: controller) }
                    }
                } else {
                    preview.frame(maxWidth: .infinity)
                    PanelCard(controller: controller)
                    UnitCard(controller: controller)
                    LinkCard(controller: controller)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { if !controller.isRunning { controller.start() } }
        .sheet(isPresented: $showBluetooth) { BluetoothSheet() }
    }

    private var header: some View {
        HStack {
            Text("RemoteFM1").font(.title2.bold()).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 8)
            StatusPill(state: controller.state, fake: controller.backend.isFake)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { showBluetooth = true } label: { Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right").lineLimit(1) }
                .buttonStyle(.bordered)
                .fixedSize()
            Button(controller.isRunning ? "Disconnect" : "Connect") {
                controller.isRunning ? controller.stop() : controller.start()
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            Spacer(minLength: 4)
            Toggle("Pattern", isOn: Binding(get: { controller.patternOn }, set: { controller.patternOn = $0 }))
                .toggleStyle(.button)
                .fixedSize()
        }
    }

    private var preview: some View {
        Group {
            if let img = controller.preview {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)
                    .resizable()
            } else {
                Theme.card
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: sizeClass == .regular ? 480 : 260)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
        .accessibilityLabel("The screen being sent to the FM-1")
    }
}

enum Theme {
    static let background = Color(red: 0.06, green: 0.07, blue: 0.09)
    static let card = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let line = Color.white.opacity(0.12)
    static let accent = Color(red: 1.0, green: 0.55, blue: 0.16)
    static let teal = Color(red: 0.16, green: 0.78, blue: 0.75)
}

struct StatusPill: View {
    let state: LinkState
    let fake: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(state.title + (fake ? " (fake)" : "")).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.18)))
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .searching, .starting, .lost, .stopping: .yellow
        case .notFound, .inUse: .orange
        case .error: .red
        case .stopped: .gray
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }
}

/// label: value rows in small monospace
struct Rows: View {
    let rows: [(String, String)]

    var body: some View {
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

struct PanelCard: View {
    let controller: RemoteController

    var body: some View {
        Card(title: "Panel") {
            HStack(spacing: 2) {
                ForEach(0..<27, id: \.self) { k in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(controller.heldKeys & (1 << UInt32(k)) != 0 ? Theme.accent : Color.white.opacity(0.12))
                        .frame(height: 18)
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<14, id: \.self) { b in
                    Text(PanelEvent.buttonNames[b])
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(
                            controller.heldButtons & (1 << UInt32(b)) != 0 ? Theme.teal : Color.white.opacity(0.08)))
                }
            }
            Text("MASTER \(controller.master.map(String.init) ?? "–")")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if controller.events.isEmpty {
                Text("No events yet: press a key on the FM-1.")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.events) { e in
                        Text(e.text).font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
    }
}

struct UnitCard: View {
    let controller: RemoteController

    var body: some View {
        Card(title: "Unit (HELLO_R)") {
            if let h = controller.hello {
                Rows(rows: [
                    ("name", h.name),
                    ("firmware", "\(h.firmwareVersion) (ver \(h.version))"),
                    ("proto", "\(h.proto)"),
                    ("identity", h.identity),
                    ("link", h.isBluetooth ? "Bluetooth" : "USB"),
                    ("session", (h.session ? "running" : "none") + " (when it answered)"),
                    ("transports", String(format: "0x%02X ", h.transports) + h.transportNames),
                    ("caps", String(format: "0x%04X ", h.caps) + h.capNames),
                    ("sxq", "\(h.sxq)"),
                    ("body max", "SysEx \(h.sxBodyMax), bulk \(h.bkBodyMax)"),
                    ("screen", "\(h.screenW)x\(h.screenH), \(h.maxInFlight) in flight"),
                ])
            } else {
                Text("No unit has answered yet.")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

struct LinkCard: View {
    let controller: RemoteController

    var body: some View {
        let s = controller.stats
        Card(title: "Link") {
            Rows(rows: [
                ("state", controller.statusText),
                ("frames", "\(s.frames), acks \(s.acks), \(String(format: "%.0f", s.fps)) fps"),
                ("ack ms", "last \(s.ackMsLast), avg \(s.ackMsAvg), max \(s.ackMsMax), timeouts \(s.ackTimeouts)"),
                ("in flight", "\(s.inFlight) frames, pending \(s.pending)"),
                ("bytes", "wire \(s.wireBytes), body \(s.bodyBytes)"),
                ("budget", "\(s.budget) B/frame, cap \(s.wireCap), every \(s.frameMs) ms"),
                ("ble", s.ble ? "1, HOLD \(s.hold ? "on" : "off")" : "0"),
                ("held", "\(s.held), reduced \(s.reduced), refined \(s.refined)"),
                ("sessions", "\(s.sessions), discoveries \(s.discoveries), runs \(s.runs)"),
                ("events", "\(s.eventsIn), dropped \(s.eventsDropped)"),
                ("MIDI setup", "\(controller.midiSetupChanges) changes"),
            ])
            if !controller.lastLog.isEmpty {
                Text(controller.lastLog)
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}
