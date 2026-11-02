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

/// "FANTASY CFW": a firmware that runs only in RemoteFM1 hosts (its manifest's "virtual"), never on an FM-1
public struct FantasyTag: View {
    var small = false
    public init(small: Bool = false) { self.small = small }
    public var body: some View {
        Text(small ? "FANTASY" : "FANTASY CFW").font(RFMFonts.ui(small ? 8 : 9, 700)).tracking(0.8)
            .foregroundStyle(Color(red: 0.62, green: 0.5, blue: 1))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(small ? 0.6 : 0)))
            .overlay(Capsule().strokeBorder(Color(red: 0.62, green: 0.5, blue: 1).opacity(0.8), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel("Fantasy CFW")
    }

    /// what its manifest's "folders" let it do, in words ("reads your audio and code folders, saves in data")
    public static func folders(_ f: [String: String]) -> String {
        let reads = ["audio", "code", "data"].filter { f[$0] == "r" || (f[$0] == "rw" && $0 != "data") }
        var parts: [String] = []
        if !reads.isEmpty { parts.append("reads " + reads.joined(separator: " and ")) }
        if f["data"] == "rw" { parts.append("saves in data") }
        return parts.joined(separator: ", ")
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
                    .overlay(alignment: .bottomLeading) {
                        if c.isVirtual { FantasyTag(small: true).padding(5) }
                    }
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
        .accessibilityLabel("\(c.name) \(c.version)\(c.imported ? ", imported" : "")\(c.isVirtual ? ", Fantasy CFW" : "")")
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
                    if info.fantasy { FantasyTag().padding(.vertical, 2) }
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

/// the big "Get more firmware" button under the built-in firmware (testers missed the row at the bottom)
public struct GetMoreButton: View {
    let count: Int
    let updates: Int
    let action: () -> Void

    public init(count: Int, updates: Int, action: @escaping () -> Void) {
        self.count = count
        self.updates = updates
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 28, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get more firmware").font(RFMFonts.ui(17, 800))
                    Text(sub).font(RFMFonts.ui(13, 600)).opacity(0.8)
                }
                Spacer(minLength: 0)
                if updates > 0 {
                    Text("\(updates)").font(RFMFonts.ui(13, 800)).foregroundStyle(Palette.sheetAccent)
                        .padding(.horizontal, 8).frame(minWidth: 24, minHeight: 24)
                        .background(Capsule().fill(Palette.sheetBackground))
                }
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold))
            }
            .foregroundStyle(Palette.sheetBackground)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.sheetAccent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Get more firmware\(updates > 0 ? ", \(updates) updates" : "")")
    }

    private var sub: String {
        let more = count > 0 ? "\(count) to download" : "Download firmware from the catalog"
        return updates > 0 ? "\(more) · \(updates) update\(updates == 1 ? "" : "s")" : more
    }
}

/// a row of chips, one picked (sorting, filters)
public struct ChipPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selected: T

    public init(_ options: [(T, String)], selected: Binding<T>) {
        self.options = options
        _selected = selected
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { o in
                    let on = o.0 == selected
                    Button { withAnimation(.easeInOut(duration: 0.15)) { selected = o.0 } } label: {
                        Text(o.1).font(RFMFonts.ui(13, 700))
                            .foregroundStyle(on ? Palette.sheetBackground : Palette.sheetText)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Capsule().fill(on ? Palette.sheetAccent : Palette.sheetSurface))
                            .overlay(Capsule().strokeBorder(on ? Color.clear : Palette.sheetBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

/// the firmware sidebar (the owner, 2026-11-01): a swipe in from the left edge shows one column of firmware; a tap
/// switches to it and closes the sidebar. It stays in the view tree while closed (moved off screen), so it opens
/// where it was scrolled to
public struct FirmwareSidebar: View {
    let cores: [CoreInfo]
    let selected: String
    @Binding var open: Bool
    let select: (String) -> Void
    let getMore: () -> Void
    @GestureState private var drag: CGFloat = 0

    public init(cores: [CoreInfo], selected: String, open: Binding<Bool>, select: @escaping (String) -> Void,
                getMore: @escaping () -> Void) {
        self.cores = cores
        self.selected = selected
        _open = open
        self.select = select
        self.getMore = getMore
    }

    public var body: some View {
        GeometryReader { g in
            let w = min(320, g.size.width * 0.78)
            let shift = open ? min(0, drag) : -w - 24 + max(0, min(w + 24, drag))
            let shown = (w + 24 + shift) / (w + 24)
            ZStack(alignment: .leading) {
                Color.black.opacity(0.45 * shown)
                    .ignoresSafeArea()
                    .allowsHitTesting(open)
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                list(width: w)
                    .offset(x: shift)
                    .gesture(DragGesture(minimumDistance: 12)
                        .updating($drag) { v, s, _ in if open { s = v.translation.width } }
                        .onEnded { v in if open, v.translation.width < -w / 4 || v.predictedEndTranslation.width < -w / 2 { close() } })
                // (the edge: a drag in from the left opens it)
                if !open {
                    Color.clear.frame(width: 14).contentShape(Rectangle())
                        .padding(.top, 90)                          // (not over the status row's chip)
                        .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                            .updating($drag) { v, s, _ in s = v.translation.width }
                            .onEnded { v in
                                if v.translation.width > 60 || v.predictedEndTranslation.width > w / 2 {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { open = true }
                                }
                            })
                        .accessibilityHidden(true)
                }
            }
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.86), value: drag)
        }
    }

    private func close() { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { open = false } }

    private func list(width: CGFloat) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                Text("Firmware").font(RFMFonts.ui(13, 800)).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(Palette.sheetMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.bottom, 4)
                ForEach(cores) { c in row(c) }
                Button {
                    close()
                    getMore()
                } label: {
                    Label("Get more firmware", systemImage: "arrow.down.circle.fill").font(RFMFonts.ui(15, 700))
                        .foregroundStyle(Palette.sheetAccent)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.sheetAccent, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(.horizontal, 10).padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .frame(width: width)
        .background(Palette.sheetBackground.opacity(0.97).ignoresSafeArea())
        .overlay(alignment: .trailing) { Palette.sheetBorder.frame(width: 1).ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Firmware sidebar")
        .accessibilityAction(.escape) { close() }
    }

    private func row(_ c: CoreInfo) -> some View {
        let on = c.id == selected
        return Button {
            select(c.id)
            close()
        } label: {
            HStack(spacing: 12) {
                FirmwareThumb(id: c.firmwareID, name: c.name, corner: 10).frame(width: 52, height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Palette.sheetAccent : Palette.sheetBorder, lineWidth: on ? 2 : 1))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.name).font(RFMFonts.ui(15, 700)).foregroundStyle(on ? Palette.sheetAccent : Palette.sheetText)
                            .lineLimit(1)
                        if c.isVirtual { FantasyTag(small: true) }
                    }
                    Text(c.version + (c.imported ? "" : " · built in")).font(RFMFonts.ui(12, 500))
                        .foregroundStyle(Palette.sheetMuted2).lineLimit(1)
                }
                Spacer(minLength: 0)
                if on {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Palette.sheetAccent)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? Palette.sheetRaised : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(c.name) \(c.version)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// a thin strip on the right edge: a swipe in from it (to the left) runs `action` (the firmware's web editor)
public struct RightEdgeSwipe: View {
    let action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Color.clear.frame(width: 14).contentShape(Rectangle())
                .padding(.top, 90)                              // (not over the status row's firmware name)
                .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onEnded { v in
                        if v.translation.width < -60 || v.predictedEndTranslation.width < -160 { action() }
                    })
                .accessibilityHidden(true)
        }
    }
}
