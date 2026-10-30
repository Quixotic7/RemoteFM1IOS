// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Get firmware (PLAN.md section 9): the sheet's pages for RFMKit's FirmwareStore. The list (name, version, author,
// category, size, one line, and Install / Installed / Update, or the download's ring: a tap cancels it), a check, the
// footer (where the list comes from, when it was read); a row opens the firmware's page (its description, the
// details, the links, the button, Play once it is here). Firmware built into the app isn't listed.

import RFMKit
import SwiftUI

/// the list
struct GetFirmwarePage: View {
    let store: FirmwareStore
    let builtIn: [CoreInfo]
    var scrollTo: String?                               // ("footer": the page shown from its footer, screenshots)
    let back: () -> Void
    let open: (String) -> Void

    var body: some View {
        let list = store.list(builtIn: builtIn)
        SheetPage("Get firmware", backTitle: "Firmware", scrollTo: scrollTo, back: back) {
            SheetSectionTitle("Available", top: 12)
            if list.isEmpty {
                SheetNote(store.checking ? "Getting the list…" : store.problem.isEmpty ? "No firmware to download yet." : store.problem,
                          color: store.problem.isEmpty || store.checking ? Palette.sheetMuted : .orange)
            } else {
                SheetList {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                        CatalogRow(item: e, state: store.state(e), progress: store.progress?.id == e.id ? store.progress : nil,
                                   busy: store.progress != nil, divider: i < list.count - 1,
                                   open: { open(e.id) }, install: { Task { await store.install(e) } }, cancel: store.cancel)
                    }
                }
            }
            CatalogNotes(store: store)
            SheetList {
                SheetRow(store.checking ? "Checking…" : "Check for updates", divider: false, chevron: false) {
                    Task { await store.refresh() }
                }
                .disabled(store.checking)
            }
            .padding(.top, 16)
            .id("footer")
            if !store.problem.isEmpty && !list.isEmpty { SheetNote(store.problem, color: .orange) }
            SheetNote(CatalogText.footer(store))
        }
        .task { await store.refreshIfOlder(than: 600) }     // (opening the page checks, unless it just did)
    }
}

/// a firmware's page
struct CatalogDetailPage: View {
    let store: FirmwareStore
    let id: String
    let library: FirmwareLibrary
    let back: () -> Void
    let play: (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let e = store.available.first(where: { $0.id == id }) {
            page(e)
        } else {
            SheetPage(id, backTitle: "Get firmware", back: back) {
                SheetNote(store.checking ? "Getting the list…" : "This firmware isn't in the list any more.").padding(.top, 12)
            }
        }
    }

    private func page(_ e: AvailableFirmware) -> some View {
        let state = store.state(e)
        let p = store.progress?.id == e.id ? store.progress : nil
        let here = library.files.filter { $0.error == nil && $0.coreID == e.id }
            .max { FirmwareVersion.less($0.version, $1.version) }
        let links = [("Source code", e.sourceURL), ("Website", e.site)].filter { URL(string: $0.1)?.host != nil }
        return SheetPage(e.displayName, backTitle: "Get firmware", back: back) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(e.version).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetMuted2)
                if e.beta { BetaTag() }
                if !e.author.isEmpty {
                    Text("· \(e.author)").font(RFMFonts.ui(15, 500)).foregroundStyle(Palette.sheetMuted2).lineLimit(1)
                }
            }
            let text = e.about.isEmpty ? e.summary : e.about
            if !text.isEmpty {
                Text(text).font(RFMFonts.ui(14)).foregroundStyle(Palette.sheetText)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            Group {
                if let p {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: p.fraction ?? 0).tint(Palette.sheetAccent)
                        HStack {
                            Text(CatalogText.progress(p)).font(RFMFonts.ui(13, 600)).foregroundStyle(Palette.sheetMuted2)
                                .monospacedDigit()
                            Spacer()
                            SheetButton("Cancel", action: store.cancel)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        switch state {
                        case .notInstalled:
                            SheetButton("Install · \(CatalogText.size(e.size))", accent: true) { Task { await store.install(e) } }
                                .disabled(store.progress != nil)
                        case .update(let v):
                            SheetButton("Update to \(e.version)", accent: true) { Task { await store.install(e) } }
                                .disabled(store.progress != nil)
                            Text("\(v) is here").font(RFMFonts.ui(13, 500)).foregroundStyle(Palette.sheetMuted2)
                        case .installed(let v):
                            if let f = here ?? library.files.first(where: { $0.error == nil && $0.sha256 == e.sha256 }) {
                                SheetButton("Play \(f.name)", accent: true) { play(f.key) }
                            }
                            Label("Installed \(v)", systemImage: "checkmark").font(RFMFonts.ui(13, 600))
                                .foregroundStyle(Palette.sheetMuted2)
                        }
                        Spacer(minLength: 0)
                    }
                    if case .update = state {
                        SheetNote("The update replaces the version here. Saved sounds and projects that used it open "
                                  + "with the new one.")
                    }
                }
            }
            .padding(.top, 16)
            CatalogNotes(store: store)
            SheetSectionTitle("Details")
            SheetList {
                InfoLine("Version", e.version)
                if !e.author.isEmpty { InfoLine("Author", e.author) }
                if !e.category.isEmpty { InfoLine("Category", e.category) }
                InfoLine("Licence", e.license.isEmpty ? "In the file" : e.license)
                InfoLine("Size", CatalogText.size(e.size))
                if let v = state.installedVersion { InfoLine("On this device", v) }
                InfoLine("SHA-256", e.sha256.isEmpty ? "–" : String(e.sha256.prefix(16)) + "…", divider: false)
            }
            if !links.isEmpty {
                SheetList {
                    ForEach(Array(links.enumerated()), id: \.offset) { i, l in
                        SheetRow(l.0, value: URL(string: l.1)?.host, divider: i < links.count - 1) {
                            if let u = URL(string: l.1) { openURL(u) }
                        }
                    }
                }
                .padding(.top, 12)
            }
            SheetNote("From \(CatalogText.list(Array(Set(e.downloads.map(\.feed))).sorted())). Before it's added, the file "
                      + "is checked against its size and SHA-256, and by the app's .rfm1 loader. It runs only when you "
                      + "pick it.")
        }
    }
}

/// a row of the list: the text opens the firmware's page, the button installs
struct CatalogRow: View {
    let item: AvailableFirmware
    let state: InstallState
    let progress: FirmwareStore.Progress?
    let busy: Bool
    var divider = true
    let open: () -> Void
    let install: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.displayName).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText).lineLimit(1)
                        Text(item.version).font(RFMFonts.ui(13, 500)).foregroundStyle(Palette.sheetMuted2).lineLimit(1)
                        if item.beta { BetaTag() }
                    }
                    Text(CatalogText.byline(item)).font(RFMFonts.ui(12, 500)).foregroundStyle(Palette.sheetMuted)
                        .lineLimit(1)
                    if !item.summary.isEmpty {
                        Text(item.summary).font(RFMFonts.ui(12)).foregroundStyle(Palette.sheetMuted2).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows its details")
            CatalogAction(state: state, progress: progress, busy: busy, install: install, cancel: cancel)
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
    }
}

/// Install, Update, Installed, or the download's ring (a tap cancels)
struct CatalogAction: View {
    let state: InstallState
    let progress: FirmwareStore.Progress?
    let busy: Bool
    let install: () -> Void
    let cancel: () -> Void

    var body: some View {
        if let p = progress {
            Button(action: cancel) {
                ZStack {
                    Circle().stroke(Palette.sheetDim, lineWidth: 3)
                    Circle().trim(from: 0, to: max(0.04, p.fraction ?? 0.04))
                        .stroke(Palette.sheetAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.sheetText)
                }
                .frame(width: 28, height: 28)
                .frame(width: 64, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel the download")
            .accessibilityValue(CatalogText.progress(p))
        } else {
            switch state {
            case .installed:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text("Installed").font(RFMFonts.ui(13, 600))
                }
                .foregroundStyle(Palette.sheetMuted2)
                .padding(.horizontal, 6)
                .frame(height: 44)
            case .notInstalled: pill("Install", accent: false)
            case .update: pill("Update", accent: true)
            }
        }
    }

    private func pill(_ t: String, accent: Bool) -> some View {
        Button(action: install) {
            Text(t).font(RFMFonts.ui(13, 700))
                .foregroundStyle(accent ? Palette.sheetBackground : Palette.sheetText)
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(accent ? Palette.sheetAccent : Palette.sheetRaised))
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
    }
}

/// the last install's result or error
struct CatalogNotes: View {
    let store: FirmwareStore

    var body: some View {
        if !store.failure.isEmpty {
            SheetNote(store.failure, color: .orange)
        } else if !store.message.isEmpty {
            SheetNote(store.message)
        }
    }
}

struct BetaTag: View {
    var body: some View {
        Text("BETA").font(RFMFonts.ui(9, 700)).tracking(0.8).foregroundStyle(Palette.sheetAccent)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Palette.sheetAccent.opacity(0.7), lineWidth: 1))
            .fixedSize()
    }
}

/// a title and a value that may wrap (a licence)
struct InfoLine: View {
    let title: String
    let value: String
    var divider = true

    init(_ title: String, _ value: String, divider: Bool = true) {
        self.title = title
        self.value = value
        self.divider = divider
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            Text(value).font(RFMFonts.ui(15, 500)).foregroundStyle(Palette.sheetMuted2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
        .accessibilityElement(children: .combine)
    }
}

enum CatalogText {
    static func size(_ n: Int) -> String {
        n > 0 ? ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) : "–"
    }

    /// "Andrew GG · Synth · 289 KB"
    static func byline(_ e: AvailableFirmware) -> String {
        [e.author, e.category, e.size > 0 ? size(e.size) : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func progress(_ p: FirmwareStore.Progress) -> String {
        if let f = p.fraction { return "Downloading… \(Int((f * 100).rounded())) %" }
        return "Downloading… \(size(p.received))"
    }

    /// "a, b and c"
    static func list(_ s: [String]) -> String {
        s.count <= 1 ? s.joined() : s.dropLast().joined(separator: ", ") + " and " + s.last!
    }

    /// where the list comes from, when it was read
    @MainActor static func footer(_ store: FirmwareStore) -> String {
        let from = "The list comes from \(list(store.feeds.map(\.name)))."
        let when: String
        if let c = store.checked {
            let ago = Date().timeIntervalSince(c) < 60 ? "just now"
                : RelativeDateTimeFormatter().localizedString(for: c, relativeTo: Date())
            when = " Checked \(ago)."
        } else {
            when = " Not checked yet."
        }
        return from + when + " Firmware built into the app isn't listed."
    }
}
