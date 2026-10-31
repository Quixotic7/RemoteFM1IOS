// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// PLAN.md section 18 step 2 in the sheet (the app's States page, the AU's): Save as… (a name, "<Firmware> <date>"
// to start with), the firmware's states newest first (name; date, version, "made with" another one), Load asked
// again inline, and per state Rename and Delete (asked again). Step 3: the … also has Share… (the app: a .rfm1state
// through the share sheet) or, without one (the AU), a note where to share from.

#if os(iOS)
import SwiftUI

public struct StatesList: View {
    let firmware: String                // the running firmware's name (the default name)
    let version: String                 // its version ("made with" another)
    let states: [SavedState]
    let saveTitle: String
    let save: (String) -> Void
    let load: (SavedState) -> Void
    let rename: (SavedState, String) -> Void
    let delete: (SavedState) -> Void
    let share: ((SavedState) -> Void)?
    let shareNote: String
    let startEditing: String?           // (screenshots) the first state whose name starts so: its … open
    @State private var started = false

    private enum Ask: Equatable { case load(String), delete(String) }
    @State private var saving = false
    @State private var saveName = ""
    @State private var ask: Ask?
    @State private var editing: String?
    @State private var editName = ""

    /// startSaving: the Save as… field open (screenshots)
    public init(firmware: String, version: String, states: [SavedState], saveTitle: String = "Save as…",
                startSaving: Bool = false, startEditing: String? = nil,
                save: @escaping (String) -> Void, load: @escaping (SavedState) -> Void,
                rename: @escaping (SavedState, String) -> Void, delete: @escaping (SavedState) -> Void,
                share: ((SavedState) -> Void)? = nil, shareNote: String = "") {
        self.firmware = firmware
        self.version = version
        self.states = states
        self.saveTitle = saveTitle
        self.save = save
        self.load = load
        self.rename = rename
        self.delete = delete
        self.share = share
        self.shareNote = shareNote
        self.startEditing = startEditing
        _saving = State(initialValue: startSaving)
        _saveName = State(initialValue: startSaving ? StateLibrary.defaultName(firmware) : "")
    }

    public var body: some View {
        VStack(spacing: 0) {
            SheetList {
                if saving {
                    nameField($saveName, action: "Save", cancel: { saving = false }) {
                        saving = false
                        save(saveName)
                    }
                } else {
                    SheetRow(saveTitle, divider: false, chevron: false) {
                        withAnimation { saveName = StateLibrary.defaultName(firmware); saving = true }
                    }
                }
            }
            if states.isEmpty {
                SheetNote("No states of \(firmware) yet. Save as… keeps the firmware's memory under a name; the app "
                          + "and the AU instrument share them.")
            } else {
                SheetList {
                    ForEach(Array(states.enumerated()), id: \.element.id) { i, s in
                        entry(s).overlay(alignment: .bottom) {
                            if i < states.count - 1 { Palette.sheetLine.frame(height: 1) }
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
        .task(id: states.count) {
            guard let n = startEditing, !started, let s = states.first(where: { $0.name.hasPrefix(n) }) else { return }
            started = true
            editName = s.name
            editing = s.id
        }
    }

    @ViewBuilder private func entry(_ s: SavedState) -> some View {
        if ask == .load(s.id) {
            SheetAsk(question: "Load \"\(s.name)\"\(s.versionNote(running: version).isEmpty ? "" : " (\(s.versionNote(running: version)))")? "
                     + "The current memory is kept as a safety copy first.",
                     action: "Load", cancel: { withAnimation { ask = nil } },
                     confirm: { withAnimation { ask = nil }; load(s) })
        } else if ask == .delete(s.id) {
            SheetAsk(question: "Delete \"\(s.name)\" from the library? The app and the AU instrument both lose it.",
                     action: "Delete", cancel: { withAnimation { ask = nil } },
                     confirm: { withAnimation { ask = nil; editing = nil }; delete(s) })
        } else if editing == s.id {
            VStack(spacing: 0) {
                nameField($editName, action: "Rename", cancel: { editing = nil }) {
                    editing = nil
                    rename(s, editName)
                }
                HStack {
                    if let share {
                        Button { share(s) } label: {
                            Label("Share…", systemImage: "square.and.arrow.up").font(RFMFonts.ui(14, 700))
                                .foregroundStyle(Palette.sheetAccent)
                                .padding(.horizontal, 16).frame(height: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else if !shareNote.isEmpty {
                        Text(shareNote).font(RFMFonts.ui(12, 500)).foregroundStyle(Palette.sheetMuted2)
                            .padding(.leading, 16).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { withAnimation { ask = .delete(s.id) } } label: {
                        Text("Delete…").font(RFMFonts.ui(14, 700)).foregroundStyle(SheetConfirm.red)
                            .padding(.horizontal, 16).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            row(s)
        }
    }

    private func row(_ s: SavedState) -> some View {
        let v = s.versionNote(running: version)
        return HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText).lineLimit(1)
                Text([SafetyCopiesList.date(s.date), s.version, v].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(RFMFonts.ui(12, 500)).foregroundStyle(v.isEmpty ? Palette.sheetMuted2 : .orange).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { withAnimation { editName = s.name; editing = s.id; ask = nil } } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(Palette.sheetMuted)
                    .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(share == nil ? "Rename or delete \(s.name)" : "Rename, share or delete \(s.name)")
            Button { withAnimation { ask = .load(s.id); editing = nil } } label: {
                Text("Load").font(RFMFonts.ui(14, 700)).foregroundStyle(Palette.sheetAccent)
                    .padding(.horizontal, 6).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Load \(s.name)")
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(minHeight: 56)
    }

    private func nameField(_ text: Binding<String>, action: String, cancel: @escaping () -> Void,
                           confirm: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: text)
                .font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit(confirm)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                SheetButton("Cancel") { withAnimation(.default, cancel) }
                SheetButton(action, accent: true) { withAnimation(.default, confirm) }
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
#endif
