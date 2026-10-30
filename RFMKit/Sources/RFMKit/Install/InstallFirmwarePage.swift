// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// "Install RemoteFM1 on the FM-1": the sheet's page for FirmwareInstaller, in the sheet's parts (Faceplate/Sheet.swift).
// The FM-1's RemoteFM1 and the newest release; the package (the newest, its USB-only variant, older releases under a
// disclosure) and its notes; the warnings (USB only, keep the app open and the phone awake); then the step: Check the
// FM-1, what it has and what will be installed (a switch or a reinstall confirmed), the install, its result. While
// FM1Kit installs, a full-screen cover shows the progress and can't be dismissed, so neither the page nor the sheet
// can be left during the write. InstallFirmwareRow is the sheet's row for it (with "Update available");
// InstallFirmwareScreen the same page on its own (Diagnostics).

#if os(iOS)
import SwiftUI

/// the row that opens the page: its value says whether an update is available
public struct InstallFirmwareRow: View {
    let installer: FirmwareInstaller
    var divider = false
    let open: () -> Void

    public init(installer: FirmwareInstaller, divider: Bool = false, open: @escaping () -> Void) {
        self.installer = installer
        self.divider = divider
        self.open = open
    }

    public var body: some View {
        SheetRow("Install RemoteFM1 on the FM-1", value: Self.badge(installer), divider: divider, action: open)
            .task { await installer.releases.refreshIfStale() }
    }

    static func badge(_ i: FirmwareInstaller) -> String? {
        if i.isBusy { return "installing…" }
        if let u = i.updateAvailable { return "\(u.version) available" }
        return i.unitVersion.map { "\($0)" }
    }
}

public struct InstallFirmwarePage: View {
    let installer: FirmwareInstaller
    let backTitle: String
    let back: () -> Void
    @State private var showOlder = false
    @State private var showDetails = false
    @State private var showLicence = false

    public init(installer: FirmwareInstaller, backTitle: String = "Settings", back: @escaping () -> Void) {
        self.installer = installer
        self.backTitle = backTitle
        self.back = back
    }

    public var body: some View {
        SheetPage("Install RemoteFM1", backTitle: backTitle, back: leave) {
            unit
            if installer.stage == .idle {
                choice
                warnings
                idle
            } else {
                step                                // (after a check: the result first, the choice is fixed)
                warnings
            }
            if installer.simulated {
                SheetNote("A simulated FM-1 (FM1Kit's SimulatedFM1): nothing is sent to a real one.", color: .orange)
            }
            about
        }
        .task { await installer.pageAppeared() }
        .fullScreenCover(isPresented: Binding(get: { installer.stage == .installing }, set: { _ in })) {
            InstallProgressView(installer: installer).interactiveDismissDisabled(true)
        }
    }

    private func leave() {
        guard !installer.isBusy else { return }
        installer.leave()
        back()
    }

    // MARK: the FM-1

    @ViewBuilder private var unit: some View {
        let rel = installer.releases
        SheetSectionTitle("The FM-1", top: 12)
        SheetList {
            SheetRow("On it now", value: unitLine, chevron: false) {}
            SheetRow("Newest RemoteFM1", value: rel.newest.map { "\($0.version) · \($0.displayDate)" } ?? (rel.fetching ? "…" : "–"),
                     divider: false, chevron: false) {}
        }
        if let u = installer.updateAvailable {
            SheetStatus("Update available: RemoteFM1 \(u.version)", dot: Palette.sheetAccent)
        } else if let v = installer.unitVersion, let n = rel.newest?.parsedVersion, v >= n {
            SheetStatus("RemoteFM1 \(v) is the newest", dot: Palette.linkedDot)
        }
        if let e = rel.error {
            SheetNote(rel.releases.isEmpty ? "The list of releases couldn't be fetched: \(e)"
                      : "Couldn't fetch the list (\(e)); showing the one from \(rel.fetchedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "before").",
                      color: .orange)
        }
    }

    private var unitLine: String {
        if let s = installer.summary { return s.deviceName.hasPrefix("RemoteFM1") ? s.deviceName : s.deviceIdentity }
        if installer.simulated { return "Check the FM-1 to see" }    // (the fake link's HELLO_R isn't the simulated FM-1)
        if let v = installer.unitVersion { return "RemoteFM1 \(v)" }
        if let h = installer.panel?.unitHello, !h.identity.isEmpty { return h.identity }
        return "not known yet"
    }

    // MARK: the package

    @ViewBuilder private var choice: some View {
        let rel = installer.releases
        let installable = rel.releases.filter(\.installable)
        SheetSectionTitle("Install")
        if let newest = installable.first {
            SheetList {
                packageRows(newest, last: installable.count < 2)
                if installable.count > 1 {
                    SheetRow("Older releases", value: showOlder ? "hide" : "\(installable.count - 1)", divider: showOlder,
                             chevron: false) { withAnimation { showOlder.toggle() } }
                    if showOlder {
                        ForEach(Array(installable.dropFirst().enumerated()), id: \.element.id) { i, r in
                            packageRows(r, last: i == installable.count - 2)
                        }
                    }
                }
            }
            .disabled(installer.choiceLocked)
            .opacity(installer.choiceLocked ? 0.6 : 1)
            if let r = installer.selectedRelease {
                ForEach(Array(r.notes.prefix(3).enumerated()), id: \.offset) { _, n in SheetNote("• " + n) }
                if let v = r.parsedVersion, v < RemoteFM1Version.appMinimum {
                    SheetNote("This app needs RemoteFM1 \(RemoteFM1Version.appMinimum) or later for its panel.", color: .orange)
                }
                SheetNote("Licence \(r.license). From \(RemoteFM1Releases.site.host() ?? "remotefm1.com"); its SHA-256 and identity are checked before anything is sent.")
            }
            if showOlder, rel.releases.contains(where: { !$0.installable }) {
                SheetNote("RemoteFM1 0.1 isn't offered here: it answers as M-VAVE's V15, so the install couldn't be checked.")
            }
        } else {
            SheetNote(rel.fetching ? "Fetching the list of releases…" : "No releases yet: check the internet connection.")
            if !rel.fetching { SheetButton("Try again") { Task { await rel.refresh() } }.padding(.top, 8) }
        }
    }

    @ViewBuilder private func packageRows(_ r: RemoteFM1Release, last: Bool) -> some View {
        if let p = r.package(.standard) {
            SheetRow("RemoteFM1 \(r.version)", value: "USB + Bluetooth", divider: !last || r.usbOnly != nil, chevron: false,
                     check: installer.selected == p) { installer.select(p) }
        }
        if let p = r.package(.usbOnly) {
            SheetRow("RemoteFM1 \(r.version) USB only", value: "no Bluetooth", divider: !last, chevron: false,
                     check: installer.selected == p) { installer.select(p) }
        }
    }

    // MARK: about (FM1Kit's credit and licence)

    @ViewBuilder private var about: some View {
        SheetSectionTitle("About", top: 24)
        SheetNote(FM1KitCredit.line)
        SheetList {
            SheetRow(showLicence ? "Hide FM1Kit's licence" : "FM1Kit's licence", divider: false, chevron: false) {
                showLicence.toggle()
            }
        }
        .padding(.top, 8)
        if showLicence {
            Text(FM1KitCredit.licence).font(RFMFonts.mono(10)).foregroundStyle(Palette.sheetMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
    }

    // MARK: warnings

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("USB cable only: Bluetooth can't install firmware.", systemImage: "cable.connector")
            Label("Keep RemoteFM1 open and the \(UIDevice.current.model) awake until it finishes (about a minute).",
                  systemImage: "iphone")
            Label("Don't unplug the FM-1 or switch it off while it writes.", systemImage: "exclamationmark.triangle")
        }
        .font(RFMFonts.ui(12, 500))
        .foregroundStyle(Palette.sheetText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.sheetRaised))
        .padding(.top, 14)
    }

    // MARK: the step

    @ViewBuilder private var step: some View {
        switch installer.stage {
        case .idle: idle
        case .preparing:
            SheetSectionTitle("Checking")
            SheetStatus(installer.activity, dot: Palette.sheetAccent, pulsing: true)
        case .ready: ready
        case .installing: SheetStatus(installer.phase, dot: Palette.sheetAccent, pulsing: true)
        case .finished: finished
        case .failed: failed
        }
    }

    @ViewBuilder private var idle: some View {
        if let holder = installer.panelHolder {
            SheetNote("RemoteFM1 in \(holder.isEmpty ? "another app" : holder) is using the FM-1. Close other apps that "
                      + "use RemoteFM1, or check anyway: the app then takes the FM-1 for the install, as Use this FM-1 does.",
                      color: .orange)
        }
        SheetButton("Check the FM-1", accent: true) { Task { await installer.check() } }
            .disabled(installer.selected == nil)
            .padding(.top, 14)
        SheetNote("Checking asks the FM-1 what it runs; nothing is written yet. The panel lets go of the FM-1 until you "
                  + "leave this page.")
    }

    @ViewBuilder private var ready: some View {
        if let s = installer.summary {
            SheetSectionTitle("Ready")
            SheetList {
                SheetRow("On the FM-1", value: s.deviceName, chevron: false) {}
                SheetRow("Installs", value: s.package.title, divider: s.needsConfirm, chevron: false) {}
                if s.needsConfirm {
                    SheetToggle(confirmTitle(s), on: Binding(get: { installer.confirmed }, set: { installer.confirmed = $0 }),
                                divider: false)
                }
            }
            SheetNote(kindNote(s), color: s.kind == .switching ? .orange : Palette.sheetMuted)
            HStack(spacing: 8) {
                if s.canInstall {
                    SheetButton(s.kind == .midUpdate ? "Finish the install" : "Install", accent: true) {
                        Task { await installer.install() }
                    }
                    .disabled(s.needsConfirm && !installer.confirmed)
                    .opacity(s.needsConfirm && !installer.confirmed ? 0.45 : 1)
                }
                SheetButton("Change") { installer.reset() }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            SheetNote("It reports \(s.deviceIdentity); \(s.package.file) ("
                      + ByteCountFormatter.string(fromByteCount: Int64(s.size), countStyle: .file)
                      + ") installs as \(s.package.identity).")
            if s.refusesV15 {
                SheetNote("Going back to M-VAVE's V15 from it later may need a computer if the FM-1's bootloader was ever "
                          + "changed (m-bootloader, M-VAVE's open firmware).")
            }
        }
    }

    private func confirmTitle(_ s: InstallSummary) -> String {
        switch s.kind {
        case .sameIdentity: "Reinstall it"
        case .switching: "Switch, I've backed up"
        default: "Yes, install it"
        }
    }

    private func kindNote(_ s: InstallSummary) -> String {
        let to = s.package.title
        switch s.kind {
        case .remoteFM1(let from):
            let v = RemoteFM1Version(string: s.package.version)
            let what = v.map { $0 > from ? "an update" : $0 < from ? "a step back" : "a reinstall" } ?? "a change"
            return "From RemoteFM1 \(from) to \(to): \(what). FM1Kit counts any change between custom firmwares as a "
                + "firmware switch, which can erase an FM-1's projects and samples, so confirm it."
        case .switching:
            return "This switches the FM-1 from \(s.deviceName) (\(s.deviceIdentity)) to \(to). Switching firmware can erase "
                + "the FM-1's projects and samples: back them up in its current firmware first."
        case .sameIdentity:
            return "\(to) is already on the FM-1. Reinstalling it writes it again."
        case .reinstall:
            return "FM1Kit won't install this over itself."
        case .midUpdate:
            return "The FM-1 is waiting part-way through an update (it reports \(s.deviceIdentity)). Finish it with \(to)."
        }
    }

    @ViewBuilder private var finished: some View {
        SheetSectionTitle("Installed")
        SheetStatus("The FM-1 now runs \(installer.installed.map(InstallSummary.name(of:)) ?? "the new firmware")"
                    + " (\(installer.installed ?? "?"))", dot: Palette.linkedDot)
        SheetNote("The panel connects again by itself. You can leave this page.")
        SheetButton("Done", accent: true, action: leave).padding(.top, 14)
    }

    @ViewBuilder private var failed: some View {
        if let p = installer.problem {
            SheetSectionTitle("Not installed")
            Text(p.headline).font(RFMFonts.ui(16, 700)).foregroundStyle(Palette.sheetText)
                .frame(maxWidth: .infinity, alignment: .leading)
            SheetNote(p.explanation, color: Palette.sheetText)
            SheetNote(p.deviceFine ? "The FM-1 still works as it did." : "The FM-1 waits in its update loader until an install finishes.",
                      color: p.deviceFine ? Palette.sheetMuted : .orange)
            HStack(spacing: 8) {
                if p.canResume {
                    SheetButton("Finish the install", accent: true) { Task { await installer.resume() } }
                }
                SheetButton(p.canResume ? "Check again" : "Try again", accent: !p.canResume) { Task { await installer.check() } }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            SheetRow(showDetails ? "Hide details" : "Details", divider: false, chevron: false) { showDetails.toggle() }
                .padding(.top, 6)
            if showDetails {
                Text(p.details + "\n" + installer.events.suffix(8).joined(separator: "\n"))
                    .font(RFMFonts.mono(10)).foregroundStyle(Palette.sheetMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// the install's progress, full screen (can't be dismissed: the write must not be left)
struct InstallProgressView: View {
    let installer: FirmwareInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("Installing \(installer.selected?.title ?? "RemoteFM1")")
                .font(RFMFonts.title(24)).foregroundStyle(Palette.sheetText)
                .accessibilityAddTraits(.isHeader)
            ProgressView(value: installer.progress.fraction)
                .tint(Palette.sheetAccent)
                .scaleEffect(x: 1, y: 2, anchor: .center)
                .accessibilityValue("\(Int(installer.progress.fraction * 100)) percent")
            HStack {
                Text(installer.progress.stage.title).font(RFMFonts.ui(15, 700))
                Spacer()
                Text("\(Int(installer.progress.fraction * 100)) %").font(RFMFonts.mono(15))
            }
            .foregroundStyle(Palette.sheetText)
            Text(installer.phase).font(RFMFonts.ui(13)).foregroundStyle(Palette.sheetMuted2)
            VStack(alignment: .leading, spacing: 8) {
                Label("Keep the USB cable in and the FM-1 on.", systemImage: "cable.connector")
                Label("Stay in RemoteFM1: the screen stays on until it finishes.", systemImage: "iphone")
                Label("If it's cut off, the FM-1 waits, and the install can be finished.", systemImage: "arrow.clockwise")
            }
            .font(RFMFonts.ui(13, 500)).foregroundStyle(Palette.sheetText)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.sheetRaised))
            if installer.simulated {
                Text("Simulated FM-1 (FM1Kit's SimulatedFM1)").font(RFMFonts.ui(12)).foregroundStyle(.orange)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.sheetBackground.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }
}

/// the page on its own, for a sheet (Diagnostics)
public struct InstallFirmwareScreen: View {
    let installer: FirmwareInstaller
    let done: () -> Void

    public init(installer: FirmwareInstaller, done: @escaping () -> Void) {
        self.installer = installer
        self.done = done
    }

    public var body: some View {
        InstallFirmwarePage(installer: installer, backTitle: "Diagnostics", back: done)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Palette.sheetBackground.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .interactiveDismissDisabled(installer.isBusy)
    }
}
#endif
