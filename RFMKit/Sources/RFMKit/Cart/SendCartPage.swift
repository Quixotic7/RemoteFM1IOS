// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// "Send a DX7 cartridge": the sheet's page for CartSender (Settings › FM-1 firmware, under Install RemoteFM1). Files
// picked with the document picker (.syx, several at once; an .syx opened from Files or AirDrop lands here too), each
// with its 32 voice names and what was fixed (the checksum, the channel), or why it can't be sent; the FM-1 to send to
// when there are several; Send (the cartridges in order, 1 s apart), the progress, the result. 0.3.0 keeps 3 banks.
// 0.3.1: "Banks on the FM-1: n of 16", each stored bank (USERk, its name) with Replace (pick an .syx: TARGET, the dump,
// STORED), Remove (an inline confirm: DELETE) and Rename (NAME, 10 characters); the list read again after each.

#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// a SysEx file (.syx), declared as an imported type in the app's Info.plist
    public static let sysex = UTType(importedAs: "com.quixotic7.remotefm1.syx", conformingTo: .data)
}

public struct SendCartRow: View {
    let sender: CartSender
    var divider = false
    let open: () -> Void

    public init(sender: CartSender, divider: Bool = false, open: @escaping () -> Void) {
        self.sender = sender
        self.divider = divider
        self.open = open
    }

    public var body: some View {
        SheetRow("Send a DX7 cartridge", value: sender.busy ? "sending…" : nil, divider: divider, action: open)
    }
}

public struct SendCartPage: View {
    let sender: CartSender
    let backTitle: String
    let back: () -> Void
    @State private var picking = false
    @State private var shown: CartFile.ID?
    @State private var replacing: Int?
    @State private var openBank: Int?
    @State private var confirmRemove: Int?
    @State private var newName = ""

    public init(sender: CartSender, backTitle: String = "Settings", back: @escaping () -> Void) {
        self.sender = sender
        self.backTitle = backTitle
        self.back = back
    }

    public var body: some View {
        SheetPage("Send a DX7 cartridge", backTitle: backTitle, back: { if !sender.busy { back() } }) {
            SheetNote(sender.firmware == .v031
                      ? "RemoteFM1 keeps up to 16 DX7 32-voice cartridges (.syx) as user banks, USER1 to USER16, after the ROM banks. When all are used, a new one replaces the oldest. Installing other firmware erases them."
                      : "RemoteFM1 0.3.0 keeps a DX7 32-voice cartridge (.syx) as a user bank, USER1 to USER3, after the ROM banks. A fourth replaces the oldest. Installing other firmware erases them.")
            bankList
            files
            port
            send
            if sender.simulated {
                SheetNote("A simulated FM-1: nothing is sent to a real one.", color: .orange)
            }
        }
        .onAppear {
            sender.rescan()
            if shown == nil { shown = sender.files.last?.id }
            Task { await sender.refresh() }
        }
        .sheet(isPresented: $picking, onDismiss: { replacing = nil }) {
            DocumentPicker(types: [.sysex], multiple: replacing == nil) { urls in
                if let slot = replacing, let u = urls.first {
                    let f = CartSender.read(u)
                    Task { await sender.replace(slot: slot, with: f) }
                } else {
                    for u in urls { sender.add(url: u) }
                    shown = sender.files.last?.id
                }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var bankList: some View {
        if sender.firmware == .v031, let l = sender.banks {
            SheetSectionTitle("Banks on the FM-1: \(l.banks.count) of \(l.max)")
            if l.banks.isEmpty {
                SheetNote("None yet. A cartridge sent goes to USER\(l.next + 1).")
            } else {
                SheetList {
                    ForEach(Array(l.banks.enumerated()), id: \.element.id) { i, b in
                        SheetRow(b.label, value: b.name, divider: i < l.banks.count - 1 || openBank == b.slot, chevron: false) {
                            confirmRemove = nil
                            newName = b.name
                            openBank = openBank == b.slot ? nil : b.slot
                        }
                        if openBank == b.slot { bankActions(b) }
                    }
                }
                SheetNote("A cartridge sent goes to USER\(l.next + 1)\(l.banks.contains { $0.slot == l.next } ? ", replacing the oldest" : "").")
            }
            if case .working(let w) = sender.state { SheetStatus(w, dot: Palette.sheetAccent, pulsing: true) }
            else if case .done(let d) = sender.state { SheetStatus(d, dot: Palette.linkedDot) }
            else if case .failed(let f) = sender.state, f.hasPrefix("Rename") { SheetNote(f, color: .orange) }
        } else if sender.firmware == .v030 {
            SheetNote("RemoteFM1 0.3.0: up to 3 banks, sending only. Update RemoteFM1 to list, replace and remove banks.")
        }
    }

    @ViewBuilder private func bankActions(_ b: UserBank) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if confirmRemove == b.slot {
                Text("Remove \(b.label) (\(b.name)) from the FM-1? This can't be undone.")
                    .font(RFMFonts.ui(13)).foregroundStyle(Palette.sheetText)
                HStack(spacing: 8) {
                    SheetButton("Remove", accent: true) {
                        confirmRemove = nil
                        openBank = nil
                        Task { await sender.delete(slot: b.slot) }
                    }
                    SheetButton("Cancel") { confirmRemove = nil }
                }
            } else {
                HStack(spacing: 8) {
                    SheetButton("Replace…") { replacing = b.slot; picking = true }
                    SheetButton("Remove") { confirmRemove = b.slot }
                }
                HStack(spacing: 8) {
                    TextField("Name", text: $newName)
                        .font(.system(size: 14, design: .monospaced)).foregroundStyle(Palette.sheetText)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onChange(of: newName) { _, v in if v.count > 10 { newName = String(v.prefix(10)) } }
                    SheetButton("Rename") {
                        let n = newName
                        Task { await sender.rename(slot: b.slot, to: n) }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newName == b.name)
                }
            }
        }
        .disabled(sender.busy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var files: some View {
        SheetSectionTitle("Cartridges")
        if !sender.files.isEmpty {
            SheetList {
                ForEach(Array(sender.files.enumerated()), id: \.element.id) { i, f in
                    SheetRow(f.name, value: f.error != nil ? "can't send" : f.carts.count > 1 ? "\(f.carts.count) banks" : nil,
                             divider: i < sender.files.count - 1 || shown == f.id, chevron: false) {
                        shown = shown == f.id ? nil : f.id
                    }
                    if shown == f.id { detail(f) }
                }
            }
        }
        HStack(spacing: 8) {
            SheetButton(sender.files.isEmpty ? "Choose .syx files…" : "Add files…") { picking = true }
            if !sender.files.isEmpty { SheetButton("Clear") { shown = nil; sender.clear() } }
        }
        .padding(.top, 10)
        .disabled(sender.busy)
    }

    @ViewBuilder private func detail(_ f: CartFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = f.error {
                Text(e).font(RFMFonts.ui(13)).foregroundStyle(.orange)
            } else {
                if let fx = f.fixes { Text(fx.prefix(1).uppercased() + fx.dropFirst()).font(RFMFonts.ui(12)).foregroundStyle(Palette.sheetMuted) }
                ForEach(Array(f.carts.enumerated()), id: \.offset) { _, c in
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 3) {
                        ForEach(Array(c.voices.enumerated()), id: \.offset) { k, v in
                            Text(String(format: "%2d  ", k + 1) + v)
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.sheetText)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var port: some View {
        if sender.ports.count > 1 {
            SheetSectionTitle("Send to")
            SheetList {
                ForEach(Array(sender.ports.enumerated()), id: \.element.id) { i, p in
                    SheetRow(p.name, value: p.bluetooth ? "Bluetooth" : "USB", divider: i < sender.ports.count - 1,
                             chevron: false, check: sender.chosen == p.id) { sender.chosen = p.id }
                }
            }
        }
        if let p = sender.target, p.bluetooth {
            SheetNote("Over Bluetooth a cartridge takes about a second. USB is faster and surer.")
        }
    }

    @ViewBuilder private var send: some View {
        let n = sender.carts.count
        SheetSectionTitle("Send")
        switch sender.state {
        case .sending(let done, let total):
            SheetStatus("Sending \(min(done + 1, total)) of \(total)…", dot: Palette.sheetAccent, pulsing: true)
            ProgressView(value: Double(done), total: Double(max(total, 1))).tint(Palette.sheetAccent).padding(.top, 8)
        default:
            if sender.ports.isEmpty {
                SheetNote("No FM-1 found. Connect it with USB (or Bluetooth MIDI).", color: .orange)
            }
            SheetButton(n <= 1 ? "Send to the FM-1" : "Send \(n) cartridges to the FM-1", accent: true) {
                Task { await sender.send() }
            }
            .disabled(n == 0 || sender.target == nil)
            .opacity(n == 0 || sender.target == nil ? 0.5 : 1)
            .padding(.top, 4)
            if case .done = sender.state {} else if let r = sender.resultText {
                if case .sent = sender.state { SheetStatus(r, dot: Palette.linkedDot) } else { SheetNote(r, color: .orange) }
            }
            SheetNote("The app's panel lets go of the FM-1 while it sends, then connects again.")
        }
    }
}

/// UIDocumentPickerViewController for opening files (opened in place, security-scoped: CartSender.read copies the bytes);
/// it opens in the folder last picked from (PickerFolder)
struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    var multiple = true
    var folder: PickerFolder = .cart
    let picked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        p.allowsMultipleSelection = multiple
        p.directoryURL = folder.url
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator {
        let f = folder, p = picked
        return Coordinator { urls in f.remember(urls); p(urls) }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picked: ([URL]) -> Void
        init(_ p: @escaping ([URL]) -> Void) { picked = p }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { picked(urls) }
    }
}

#if DEBUG
extension CartSender {
    /// (DEBUG -cartdemo) two made-up cartridges, one with a wrong checksum and channel 2, for the screenshots
    public func addDemo() {
        func dump(_ prefix: String, channel: UInt8, good: Bool) -> Data {
            var b: [UInt8] = [0xF0, 0x43, channel, 0x09, 0x20, 0x00]
            let names = ["BRASS", "STRINGS", "E.PIANO", "BELLS", "BASS", "ORGAN", "FLUTE", "CLAV"]
            for k in 0 ..< 32 {
                b += (0 ..< 118).map { UInt8(($0 * 5 + k) & 0x7F) }
                b += Array(String("\(prefix)\(names[k % 8]) \(k / 8 + 1)          ".prefix(10)).utf8)
            }
            b.append(good ? DX7Cart.checksum(b[6...]) : 0x00)
            b.append(0xF7)
            return Data(b)
        }
        add(CartFile(name: "Demo cartridge A.syx", data: dump("", channel: 0, good: true)))
        add(CartFile(name: "Demo cartridge B.syx", data: dump("B ", channel: 2, good: false)))
    }
}
#endif
#endif
