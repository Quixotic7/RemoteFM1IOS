// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The sheet's Background section (Skin.swift): the user's image (from Photos), its dim, and whether a firmware's own
// skin shows. picker: false (the AU) leaves out choosing the image; the settings still apply there.

#if os(iOS)
import PhotosUI
import SwiftUI

public struct SkinSettings: View {
    @Bindable var skins: SkinStore
    var picker = true
    @State private var choosing = false
    @State private var item: PhotosPickerItem?
    @State private var failed = false

    public init(skins: SkinStore, picker: Bool = true) {
        self.skins = skins
        self.picker = picker
    }

    public var body: some View {
        SheetList {
            if picker {
                SheetRow("Background image", value: skins.hasImage ? "Photo" : "None") { choosing = true }
                if skins.hasImage {
                    SheetRow("Remove background image", chevron: false) { skins.removeImage() }
                }
            }
            if skins.hasImage {
                HStack(spacing: 12) {
                    Text("Dim").font(RFMFonts.ui(15, 600)).foregroundStyle(Palette.sheetText)
                    Slider(value: $skins.dim, in: 0...SkinStore.maxDim)
                        .tint(Palette.sheetAccent)
                        .accessibilityLabel("Dim the background image")
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .overlay(alignment: .bottom) { Palette.sheetLine.frame(height: 1) }
            }
            SheetToggle("Firmware skins", on: $skins.firmwareSkins, divider: false)
        }
        .photosPicker(isPresented: $choosing, selection: $item, matching: .images)
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                let d = try? await it.loadTransferable(type: Data.self)
                failed = !(d.map { skins.setImage($0) } ?? false)
                item = nil
            }
        }
        if !picker { SheetNote("Choose a background image in the RemoteFM1 app; it shows here too.") }
        if failed { SheetNote("That photo couldn't be read. Try another one.", color: .orange) }
        SheetNote("A firmware that comes with its own skin shows it while it plays. Turn off Firmware skins to keep "
                  + "your background and theme for every firmware.")
    }
}
#endif
