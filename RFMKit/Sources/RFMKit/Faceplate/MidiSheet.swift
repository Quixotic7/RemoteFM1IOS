// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// (M8) the sheet's MIDI pieces (js/sheet.js's Playing section, js/omx-link.js mountOmx), in Sheet.swift's style:
//   MidiMapSection  Knobs from MIDI: Learn, the knob speed, the learned mappings (an encoder's mode, remove), Clear all
//                   (asked again inline: no alert, as the extension can't present one safely)
//   MidiModeList    an encoder mapping's mode, a page of its own (opened from MidiMapSection's row)
//   MidiInputList   the MIDI input: all, none, or one device (the app's ControllerInput)
//   OmxSection      the OMX-27: what it does, Connect / Disconnect, its status, the note (the app)
//   KeyChannelRows  Keys from MIDI (its value opens KeyChannelList) and "...and reach the firmware's MIDI in"
//   KeyChannelList  the Keys from MIDI page: Any, Channel 1–16, Off
// The app's MIDI & audio page and the AU's sheet use them. Choices open a page in the sheet, never a SwiftUI Menu,
// popover or dialog: in an AU host those are clipped to the extension's view and can't be used (AUM, on an iPhone).

#if os(iOS)
import SwiftUI

/// sheet.js MODE_SHORT: an encoder's mode, short
func modeShort(_ m: MidiMode) -> String {
    switch m {
    case .abs: "absolute"
    case .rel64: "rel. 64 ± n"
    case .rel2c: "rel. 2's comp."
    case .relsign: "rel. sign bit"
    }
}

/// Keys from MIDI: the channel whose notes play the keys (a row that opens KeyChannelList), and whether those notes
/// reach the firmware too (dimmed when Off). Two rows of a SheetList
public struct KeyChannelRows: View {
    let channel: AUSettings.KeyChannel
    @Binding var toFirmware: Bool
    let open: () -> Void

    /// open: shows the Keys from MIDI page (the host's own page navigation)
    public init(channel: AUSettings.KeyChannel, toFirmware: Binding<Bool>, open: @escaping () -> Void) {
        self.channel = channel
        _toFirmware = toFirmware
        self.open = open
    }

    public var body: some View {
        SheetRow("Keys from MIDI", value: channel.label, action: open)
            .accessibilityValue(channel.longLabel)
        SheetToggle("...and reach the firmware's MIDI in", on: $toFirmware)
            .disabled(channel == .off)
            .opacity(channel == .off ? 0.45 : 1)
    }
}

/// the Keys from MIDI page's content: Any, Channel 1–16, Off, the current one checked
public struct KeyChannelList: View {
    @Binding var channel: AUSettings.KeyChannel

    public init(channel: Binding<AUSettings.KeyChannel>) { _channel = channel }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(AUSettings.KeyChannel.groups.enumerated()), id: \.offset) { g, group in
                SheetList {
                    ForEach(Array(group.enumerated()), id: \.offset) { i, k in
                        SheetRow(k.longLabel, divider: i < group.count - 1, chevron: false, check: k == channel) {
                            channel = k
                        }
                    }
                }
                .padding(.top, g == 0 ? 12 : 14)
                if g == 0 { SheetNote("Notes on every channel play the keys.") }
                if g == 2 { SheetNote("Every note goes to the firmware's MIDI in; none play the keys.") }
            }
            SheetNote("Notes on other channels go to the firmware's MIDI in.")
        }
    }
}

/// an encoder mapping's mode, as a page: how its CC values turn the knob
public struct MidiModeList: View {
    let store: MidiMapStore
    let src: String

    public init(store: MidiMapStore = .shared, src: String) {
        self.store = store
        self.src = src
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let m = store.mappings.first(where: { $0.src == src }), let mode = m.mode {
                Text("\(m.target) ← \(MidiSource.label(m.src))").font(RFMFonts.ui(15, 700))
                    .foregroundStyle(Palette.sheetText)
                    .padding(.top, 8).padding(.bottom, 10)
                SheetList {
                    ForEach(Array(MidiMode.allCases.enumerated()), id: \.offset) { i, md in
                        SheetRow(md.label, divider: i < MidiMode.allCases.count - 1, chevron: false, check: md == mode) {
                            store.setMode(m.src, md)
                        }
                    }
                }
                SheetNote("How the controller's CC values turn the knob. Absolute: a pot or fader (0–127). The "
                          + "relative ones are endless encoders: 64 ± n, two's complement (1 up, 127 down), or a sign "
                          + "bit (1 up, 65 down). Learn guesses it; change it if the knob jumps or turns the wrong way.")
            } else {
                SheetNote("This mapping is gone.")
            }
        }
    }
}

public struct MidiMapSection: View {
    let store: MidiMapStore
    let learn: () -> Void
    var top: CGFloat
    var titled: Bool
    var useMap: Binding<Bool>?
    let pickMode: (String) -> Void
    var names: ButtonNames
    @State private var confirming = false

    /// learn: starts learn mode (the host closes its sheet). titled: the section's title (not on a page of its own).
    /// useMap: the "Use learned knobs" switch (AUSettings.useLearnedMap), nil: none. pickMode: opens the mode page
    /// (MidiModeList) for a mapping's source. names: the firmware's button names (a renamed button "PERF (ARP)")
    public init(store: MidiMapStore = .shared, top: CGFloat = 20, titled: Bool = true, useMap: Binding<Bool>? = nil,
                names: ButtonNames = .standard, pickMode: @escaping (String) -> Void, learn: @escaping () -> Void) {
        self.names = names
        self.store = store
        self.top = top
        self.titled = titled
        self.useMap = useMap
        self.pickMode = pickMode
        self.learn = learn
    }

    public var body: some View {
        let maps = store.mappings
        VStack(alignment: .leading, spacing: 0) {
            if titled { SheetSectionTitle("Knobs from MIDI", top: top) } else { Color.clear.frame(height: top) }
            SheetList {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MIDI learn").font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText)
                        Text(maps.isEmpty ? "Your controller's knobs, pots and buttons on the panel"
                             : "\(maps.count) learned")
                            .font(RFMFonts.ui(12)).foregroundStyle(Palette.sheetMuted2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    SheetButton("Learn", accent: true, action: learn)
                        .accessibilityHint("Tap a knob or button, then move a control on your MIDI device")
                }
                .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
                .frame(minHeight: 60)
                .overlay(alignment: .bottom) { Palette.sheetLine.frame(height: 1) }
                if let useMap { SheetToggle("Use learned knobs", on: useMap) }
                SheetSegmented("Knob speed", options: ["½×", "1×", "2×"],
                               selected: MidiMap.speeds.firstIndex(of: store.speed) ?? 1, divider: false) { i in
                    store.setSpeed(MidiMap.speeds[i])
                }
            }
            SheetNote("Tap Learn, then a knob or button on the panel, then move a control on your MIDI device. "
                      + "Knob speed: detents per CC step, for learned knobs."
                      + (useMap == nil ? "" : " Use learned knobs off: the mappings are kept but do nothing, and their "
                         + "messages go on to the keys and the firmware. Learn still works."))
            if !maps.isEmpty {
                SheetList {
                    ForEach(Array(maps.enumerated()), id: \.element.id) { i, m in
                        row(m, divider: i < maps.count - 1)
                    }
                }
                .padding(.top, 12)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("MIDI mappings")
                clearAll.padding(.top, 10)
            }
        }
        .onChange(of: maps.isEmpty) { _, e in if e { confirming = false } }
    }

    private func row(_ m: MidiMapping, divider: Bool) -> some View {
        HStack(spacing: 6) {
            (Text(names.title(m.target)).font(RFMFonts.ui(14, 700)).foregroundColor(Palette.sheetText)
             + Text(" ← ").font(RFMFonts.ui(14, 500)).foregroundColor(Palette.sheetMuted)
             + Text(MidiSource.label(m.src)).font(RFMFonts.ui(14, 500)).foregroundColor(Palette.sheetMuted2))
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityLabel(m.description)
            Spacer(minLength: 4)
            if let mode = m.mode {
                Button { pickMode(m.src) } label: {
                    HStack(spacing: 4) {
                        Text(modeShort(mode)).font(RFMFonts.ui(13, 600)).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Palette.sheetText)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Capsule().fill(Palette.sheetRaised))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(names.title(m.target)): how CC values turn it")
                .accessibilityValue(mode.label)
            }
            Button { store.remove(m.src) } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.sheetMuted2)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(names.title(m.target)) ← \(MidiSource.label(m.src))")
        }
        .padding(.leading, 16).padding(.trailing, 4)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { if divider { Palette.sheetLine.frame(height: 1) } }
    }

    @ViewBuilder private var clearAll: some View {
        if confirming {
            SheetConfirm("Clear every mapping?", action: "Clear all", cancel: { confirming = false }) {
                confirming = false
                store.clear()
            }
        } else {
            HStack {
                Spacer()
                Button { confirming = true } label: {
                    Text("Clear all").font(RFMFonts.ui(13, 600)).foregroundStyle(Palette.sheetText)
                        .padding(.horizontal, 16).frame(height: 44)
                        .overlay(Capsule().strokeBorder(Palette.sheetBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// the MIDI input's choices: All inputs, None, each device (the FM-1 and the OMX-27 in remote mode left out)
public struct MidiInputList: View {
    let input: ControllerInput

    public init(input: ControllerInput) { self.input = input }

    /// the row's value: All, None, the device's name
    public static func value(_ input: ControllerInput) -> String {
        switch input.selection {
        case .all: "All"
        case .none: "None"
        case .one(let id): input.sources.first { $0.id == id }?.name ?? "Not connected"
        }
    }

    public var body: some View {
        let sel = input.selection
        let missing: Int32? = if case .one(let id) = sel, !input.sources.contains(where: { $0.id == id }) { id } else { nil }
        VStack(alignment: .leading, spacing: 0) {
            SheetList {
                SheetRow("All inputs", divider: true, chevron: false, check: sel == .all) { input.selection = .all }
                SheetRow("None", divider: !input.sources.isEmpty || missing != nil, chevron: false, check: sel == .none) {
                    input.selection = .none
                }
                ForEach(Array(input.sources.enumerated()), id: \.element.id) { i, s in
                    SheetRow(s.name, divider: i < input.sources.count - 1 || missing != nil, chevron: false,
                             check: sel == .one(s.id)) { input.selection = .one(s.id) }
                }
                if missing != nil {
                    SheetRow("The device picked before", value: "not connected", divider: false, chevron: false,
                             check: true) {}
                }
            }
            SheetNote(input.sources.isEmpty ? "No MIDI device found: plug one in over USB, or pair one over Bluetooth."
                      : "\(input.sources.count) found. A MIDI keyboard plays the keys; its knobs can be learned. "
                      + "The FM-1, and an OMX-27 in remote mode, are not listed.")
        }
    }
}

/// js/omx-link.js mountOmx: the OMX-27 as the FM-1's controller
public struct OmxSection: View {
    let link: OmxLink

    public init(link: OmxLink) { self.link = link }

    public var body: some View {
        let live = link.want && link.tone != .bad
        VStack(alignment: .leading, spacing: 0) {
            Text("An OMX-27 becomes this FM-1's controller: its keys, encoder and pots play it, and the app lights its "
                 + "keys and draws its screen. K1 picks the view (Base, Seq, Keyboard, Quick Keys), K2 the colours, K5 "
                 + "is MASTER.")
                .font(RFMFonts.ui(13)).foregroundStyle(Palette.sheetMuted2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            HStack {
                SheetButton(link.buttonTitle, accent: !live) { link.toggle() }
                Spacer(minLength: 0)
            }
            SheetStatus(link.detail, dot: Self.dot(link.tone), pulsing: link.tone == .busy,
                        color: link.tone == .on ? Palette.linkedDot : link.tone == .bad ? Self.bad : Palette.sheetMuted)
            SheetNote("Needs the OMX-27 firmware with REMOTE mode, connected over USB. Once connected, it connects by "
                      + "itself when the app opens or the OMX-27 is plugged in. \(OmxViews.themes.count) colour themes on "
                      + "K2. \(OmxLink.leave)")
        }
    }

    static let bad = Color(.sRGB, red: 1, green: 0.42, blue: 0.4, opacity: 1)

    static func dot(_ t: OmxLink.Tone) -> Color {
        switch t {
        case .off: Palette.sheetDim
        case .busy: Palette.sheetAccent
        case .on: Palette.linkedDot
        case .bad: bad
        }
    }
}
#endif
