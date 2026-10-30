// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Diagnostics (the sheet's Settings -> Diagnostics; the app's one screen before the faceplate): the link's state and
// controls, the mode (M1's test pattern, or a firmware core: M3), the firmware, the sound, the frame being sent, the
// core's numbers, the unit's HELLO_R (with the RemoteFM1 version on it, "Update available" and the installer's page),
// the link's numbers and the panel's last events, and the AU test. Two columns on a regular width (iPad), one on an
// iPhone.

import RFMKit
import SwiftUI

struct DiagnosticsScreen: View {
    let controller: RemoteController
    let player: CorePlayer
    var done: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showBluetooth = false
    @State private var showAUTest = false
    @State private var showAbout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                controls
                coreControls
                if !player.message.isEmpty {
                    Text(player.message).font(.footnote).foregroundStyle(.orange)
                }
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 16) { preview; PanelCard(controller: controller) }
                            .frame(maxWidth: 480)
                        VStack(spacing: 16) {
                            if player.mode == .core { CoreCard(player: player) }
                            UnitCard(controller: controller)
                            LinkCard(controller: controller)
                        }
                    }
                } else {
                    preview.frame(maxWidth: .infinity)
                    if player.mode == .core { CoreCard(player: player) }
                    PanelCard(controller: controller)
                    UnitCard(controller: controller)
                    LinkCard(controller: controller)
                }
            }
            .padding(16)
        }
        .background(DebugTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { controller.appeared() }
        .sheet(isPresented: $showBluetooth) { BluetoothSheet() }
        .sheet(isPresented: $showAbout) { AboutFirmware(info: player.current) }
        .fullScreenCover(isPresented: $showAUTest) { AUTestView(host: AUTestHost(auto: false)) }
    }

    private var header: some View {
        HStack {
            Text("Diagnostics").font(.title2.bold()).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 8)
            if let done { Button("Done", action: done).buttonStyle(.borderedProminent).fixedSize() }
            Button("AU test") { showAUTest = true }.buttonStyle(.bordered).fixedSize()
            StatusPill(state: controller.state, fake: controller.backend.isFake)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { showBluetooth = true } label: { Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right").lineLimit(1) }
                .buttonStyle(.bordered)
                .fixedSize()
            Button(controller.isRunning ? "Disconnect" : "Use this FM-1") {
                controller.isRunning ? controller.stop() : controller.start()
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            if let p = controller.panel, p.heldElsewhere {
                Text(p.line).font(.footnote).foregroundStyle(DebugTheme.accent).lineLimit(2)
            } else if let w = controller.panel?.leaseWarning {
                Text(w).font(.footnote).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    // the mode, the firmware, About, the sound; in Pattern mode the pattern's own switch
    private var coreControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: Binding(get: { player.mode }, set: { player.setMode($0) })) {
                Text("Test pattern").tag(CorePlayer.Mode.pattern)
                Text("Firmware core").tag(CorePlayer.Mode.core)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                Picker("Firmware", selection: Binding(get: { player.selected }, set: { player.select($0) })) {
                    ForEach(player.cores) { c in Text(c.title).tag(c.id) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(player.cores.isEmpty)
                Button { showAbout = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("About this firmware")
                    .disabled(player.current == nil)
                Spacer(minLength: 0)
                modeButtons
            }
        }
    }

    @ViewBuilder private var modeButtons: some View {
        Group {
            if player.mode == .core {
                if player.status.halted {
                    Button("Restart") { player.powerCycle() }.buttonStyle(.bordered).fixedSize()
                }
                Toggle(isOn: Binding(get: { player.audioOn }, set: { player.setAudio($0) })) {
                    Label("Sound", systemImage: player.audioOn ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .toggleStyle(.button)
                .fixedSize()
            } else {
                Toggle("Moving", isOn: Binding(get: { controller.patternOn }, set: { controller.patternOn = $0 }))
                    .toggleStyle(.button)
                    .fixedSize()
            }
        }
    }

    private var preview: some View {
        Group {
            if let img = player.mode == .core ? player.preview : controller.preview {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)
                    .resizable()
            } else {
                DebugTheme.card
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: sizeClass == .regular ? 480 : 260)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DebugTheme.line))
        .accessibilityLabel("The screen being sent to the FM-1")
    }
}

enum DebugTheme {
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
        .background(RoundedRectangle(cornerRadius: 10).fill(DebugTheme.card))
    }
}


struct PanelCard: View {
    let controller: RemoteController

    var body: some View {
        Card(title: "Panel") {
            HStack(spacing: 2) {
                ForEach(0..<27, id: \.self) { k in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(controller.heldKeys & (1 << UInt32(k)) != 0 ? DebugTheme.accent : Color.white.opacity(0.12))
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
                            controller.heldButtons & (1 << UInt32(b)) != 0 ? DebugTheme.teal : Color.white.opacity(0.08)))
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
    @State private var showInstall = false

    var body: some View {
        let installer = FirmwareInstaller.shared(for: controller)
        Card(title: "Unit (HELLO_R)") {
            if let h = controller.hello {
                Rows(rows: [
                    ("name", h.name),
                    ("firmware", "\(h.firmwareVersion) (ver \(h.version))"),
                    ("RemoteFM1", installer.unitVersion.map { v in
                        "\(v)" + (installer.updateAvailable.map { " · update available: \($0.version)" } ?? " · the newest")
                    } ?? "–"),
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
            Button(installer.updateAvailable.map { "Update available: install RemoteFM1 \($0.version)…" }
                   ?? "Install RemoteFM1 on the FM-1…") { showInstall = true }
                .buttonStyle(.bordered)
                .tint(installer.updateAvailable == nil ? nil : DebugTheme.accent)
        }
        .task { await installer.releases.refreshIfStale() }
        .sheet(isPresented: $showInstall) {
            InstallFirmwareScreen(installer: installer) { showInstall = false }
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

/// the core: which slot, its clock, its load, its flash
struct CoreCard: View {
    let player: CorePlayer

    var body: some View {
        let s = player.status
        let clock = ["stopped", "audio", "timer (no sound)", "caller"][min(max(s.clock, 0), 3)]
        let info = player.current
        Card(title: "Core") {
            Rows(rows: [
                ("firmware", info.map { "\($0.name) \($0.version), slot \(s.slot) of \($0.slots)" } ?? "none"),
                ("state", s.halted ? String(format: "halted (exit %u)", s.haltCode & 0xFF)
                    : s.booted ? "running, clock \(clock)" : "not booted"),
                ("device", String(format: "%.1f s, %u screens, %u keys", Double(s.devMs) / 1000, s.snapshots,
                                  s.keysPressed)),
                ("core load", s.haveStats ? "\(s.cpuPct)% (its own), shed \(s.shed)" : "–"),
                ("render", s.renders == 0 ? "–" : String(format: "avg %u us, max %u us per %u frames (%.0f%%)",
                                                         s.renderAvgUs, s.renderMaxUs, s.renderLastFrames,
                                                         s.renderLoad * 100)),
                ("audio", player.audioRunning ? player.audioText : "off"),
                ("ahead", player.audioRunning ? s.aheadText : "–"),
                ("flash", "\(player.saves) saves" + (player.lastSave.map { ", last " + Self.time($0) } ?? "")
                    + ", Application Support/cores/\(player.flashURL(player.selected).lastPathComponent)"),
            ])
        }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
