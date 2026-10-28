// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Bluetooth LE MIDI pairing: iOS's own panel (CoreAudioKit), as FIZZ does it. A connected FM-1 is then an ordinary
// CoreMIDI device, which the link finds by its name ("FM-1 ..."). Shared by the app and the AUv3 extension (PLAN.md
// section 5: whether the panel works inside an extension's view is one of M2's questions).

#if os(iOS)
import CoreAudioKit
import SwiftUI
import UIKit

public struct BluetoothSheet: View {
    public init() {}
    public var body: some View { BluetoothPanel().ignoresSafeArea() }
}

/// The panel in a navigation controller, for UIKit presentation (the extension presents it this way).
/// done: a Done button that dismisses it.
@MainActor
public func bluetoothPanelController(done: Bool) -> UINavigationController {
    let central = BTMIDICentralViewController()
    let nav = UINavigationController(rootViewController: central)
    nav.overrideUserInterfaceStyle = .dark
    if done {
        central.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
    }
    return nav
}

/// On the iOS 27.0 simulator UIScreen.main.applicationFrame is (0, nan, w, nan), CABTMIDICentralViewController's own
/// loadView makes its table from it and UIKit throws (CALayerInvalidGeometry), in the app as in the extension. It is
/// a UITableViewController, so when that frame isn't finite the table is made here instead (the controller stays its
/// data source and delegate, as usual).
final class BTMIDICentralViewController: CABTMIDICentralViewController {
    static var screenFrameBroken: Bool {
        let f = UIScreen.main.applicationFrame
        return !(f.origin.y.isFinite && f.size.width.isFinite && f.size.height.isFinite)
    }

    override func loadView() {
        guard Self.screenFrameBroken else { return super.loadView() }
        let t = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), style: .grouped)
        t.dataSource = self
        t.delegate = self
        t.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView = t
    }
}

/// true where the panel's table is made by BTMIDICentralViewController (the screen's application frame isn't finite)
@MainActor public var bluetoothPanelUsesOwnTable: Bool { BTMIDICentralViewController.screenFrameBroken }

private struct BluetoothPanel: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController { bluetoothPanelController(done: false) }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}
#endif
