// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The Firmware panel's parts (the app's and the AU's): the running firmware's card (its thumbnail, name, version,
// author, the catalog's tag and description trimmed to three lines with More, View source on GitHub) and the firmware
// list as a grid of small boxes (the thumbnail, else the name on a colour of its own; name and version under it; the
// running one outlined; a tap switches; a long press gives an imported one's Delete).

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// a firmware's thumbnail, or its name on a colour of its own
public struct FirmwareThumb: View {
    let id: String, name: String
    var corner: CGFloat = 14
    let thumbs: FirmwareThumbs

    public init(id: String, name: String, corner: CGFloat = 14, thumbs: FirmwareThumbs = .shared) {
        self.id = id
        self.name = name
        self.corner = corner
        self.thumbs = thumbs
    }

    /// a stable hue per firmware
    static func hue(_ s: String) -> Double {
        Double(s.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % 360) / 360
    }

    public var body: some View {
        ZStack {
            if let img = thumbs.image(id) {
                Image(decorative: img, scale: 1).resizable().interpolation(.medium).aspectRatio(1, contentMode: .fit)
            } else {
                let h = Self.hue(id.isEmpty ? name : id)
                LinearGradient(colors: [Color(hue: h, saturation: 0.55, brightness: 0.55),
                                        Color(hue: h, saturation: 0.7, brightness: 0.28)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { g in
                    Text(name.isEmpty ? "?" : name)
                        .font(RFMFonts.title(max(10, g.size.width * 0.15)))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.5)
                        .padding(8)
                        .frame(width: g.size.width, height: g.size.height)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// the firmware list as a grid of boxes
public struct FirmwareTileGrid: View {
    let cores: [CoreInfo]
    let selected: String
    let select: (String) -> Void
    let delete: ((CoreInfo) -> (() -> Void)?)?

    public init(cores: [CoreInfo], selected: String, select: @escaping (String) -> Void,
                delete: ((CoreInfo) -> (() -> Void)?)? = nil) {
        self.cores = cores
        self.selected = selected
        self.select = select
        self.delete = delete
    }

    public var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 10)], spacing: 12) {
            ForEach(cores) { c in tile(c) }
        }
    }

    @ViewBuilder private func tile(_ c: CoreInfo) -> some View {
        let on = c.id == selected
        let del = delete?(c)
        Button { select(c.id) } label: {
            VStack(spacing: 6) {
                FirmwareThumb(id: c.firmwareID, name: c.name)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(on ? Palette.sheetAccent : Palette.sheetBorder, lineWidth: on ? 2.5 : 1))
                    .overlay(alignment: .topTrailing) {
                        if on {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .bold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Palette.sheetBackground, Palette.sheetAccent)
                                .padding(5)
                        }
                    }
                VStack(spacing: 1) {
                    Text(c.name).font(RFMFonts.ui(13, 700)).foregroundStyle(on ? Palette.sheetAccent : Palette.sheetText)
                        .lineLimit(1)
                    Text(c.version).font(RFMFonts.ui(11, 500)).foregroundStyle(Palette.sheetMuted2).lineLimit(1)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(on ? Palette.sheetRaised : Palette.sheetSurface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let del {
                Button(role: .destructive, action: del) { Label("Delete \(c.name) \(c.version)", systemImage: "trash") }
            }
        }
        .accessibilityLabel("\(c.name) \(c.version)\(c.imported ? ", imported" : "")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// the running firmware's card at the top of the Firmware panel
public struct FirmwareInfoCard: View {
    let info: FirmwareInfo
    let running: Bool
    /// opens the link; its answer false: the link is shown to copy instead (an AU host that opens nothing)
    let open: (URL, @escaping (Bool) -> Void) -> Void
    @State private var more = false
    @State private var failed = false

    public init(info: FirmwareInfo, running: Bool, open: @escaping (URL, @escaping (Bool) -> Void) -> Void) {
        self.info = info
        self.running = running
        self.open = open
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                FirmwareThumb(id: info.id, name: info.name, corner: 12).frame(width: 92, height: 92)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.sheetBorder, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.name).font(RFMFonts.title(19)).foregroundStyle(Palette.sheetText).lineLimit(2)
                    Text([info.version, running ? "running" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(RFMFonts.ui(13, 600)).foregroundStyle(Palette.sheetAccent)
                    if !info.author.isEmpty {
                        Text("by \(info.author)").font(RFMFonts.ui(13, 500)).foregroundStyle(Palette.sheetMuted2).lineLimit(2)
                    }
                    if !info.tag.isEmpty {
                        Text(info.tag).font(RFMFonts.ui(13, 600)).foregroundStyle(Palette.sheetText).lineLimit(3)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            if !info.about.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.about).font(RFMFonts.ui(13)).foregroundStyle(Palette.sheetMuted)
                        .lineLimit(more ? nil : 3).fixedSize(horizontal: false, vertical: true)
                    if info.about.count > 140 {
                        Button(more ? "Less" : "More") { withAnimation(.easeInOut(duration: 0.2)) { more.toggle() } }
                            .font(RFMFonts.ui(13, 700)).foregroundStyle(Palette.sheetAccent).buttonStyle(.plain)
                    }
                }
            }
            if let u = info.source {
                Button {
                    open(u) { ok in failed = !ok }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 14, weight: .bold))
                        Text(u.host?.contains("github") == true ? "View source on GitHub" : "View source")
                            .font(RFMFonts.ui(15, 700))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(Palette.sheetBackground)
                    .padding(.horizontal, 16).frame(height: 46)
                    .background(Capsule().fill(Palette.sheetAccent))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(u.absoluteString)
                if failed {
                    HStack(spacing: 8) {
                        Text(u.absoluteString).font(RFMFonts.mono(12)).foregroundStyle(Palette.sheetMuted)
                            .textSelection(.enabled).lineLimit(2)
                        Spacer(minLength: 0)
                        #if os(iOS)
                        Button("Copy") { UIPasteboard.general.url = u }
                            .font(RFMFonts.ui(13, 700)).foregroundStyle(Palette.sheetAccent).buttonStyle(.plain)
                        #endif
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.sheetSurface))
        .onChange(of: info.id) { more = false; failed = false }
    }
}
