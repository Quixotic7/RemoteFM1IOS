// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Bluetooth LE MIDI pairing: iOS's own panel (CoreAudioKit), as FIZZ does it. A connected FM-1 is then an ordinary
// CoreMIDI device, which the link finds by its name ("FM-1 ...").

import CoreAudioKit
import SwiftUI
import UIKit

struct BluetoothSheet: View {
    var body: some View { BluetoothPanel().ignoresSafeArea() }
}

private struct BluetoothPanel: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let nav = UINavigationController(rootViewController: CABTMIDICentralViewController())
        nav.overrideUserInterfaceStyle = .dark
        return nav
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}
