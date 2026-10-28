// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The extension's principal class: the AU's view controller and its factory, as in Apple's AUv3 template. The audio
// unit itself (RFMAudioUnit) and the probes are in RFMKit.

import CoreAudioKit
import RFMKit
import SwiftUI
import UIKit

@objc(AudioUnitViewController)
public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private let model = AUViewModel()
    private let log = RFMShared.log("auview")

    public override func viewDidLoad() {
        super.viewDidLoad()
        model.onBluetooth = { [weak self] in self?.presentBluetooth() }
        let hosting = UIHostingController(rootView: AUView(model: model))
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        view.backgroundColor = UIColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1)
        preferredContentSize = CGSize(width: 420, height: 480)
        log.info("view loaded, pid \(getpid())")
    }

    /// iOS's Bluetooth MIDI panel over the AU's view (UIKit presentation; see bluetoothPanelController)
    func presentBluetooth() {
        guard isViewLoaded, view.window != nil, presentedViewController == nil else {
            log.info("Bluetooth panel not presented: no view on screen")
            return
        }
        log.info("presenting the Bluetooth panel over \(Int(self.view.bounds.width))x\(Int(self.view.bounds.height))")
        let nav = bluetoothPanelController(done: true)
        nav.modalPresentationStyle = .overCurrentContext
        definesPresentationContext = true
        present(nav, animated: false)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        log.info("view appeared, \(Int(self.view.bounds.width))x\(Int(self.view.bounds.height))")
    }

    // Called by the extension's host-facing machinery, not necessarily on the main thread: the AU is created here,
    // the view model attached on the main thread.
    public nonisolated func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try RFMAudioUnit(componentDescription: componentDescription, options: [])
        let ref = UnitRef(au: au)
        DispatchQueue.main.async { self.model.attach(ref.au) }
        return au
    }
}

private struct UnitRef: @unchecked Sendable { let au: RFMAudioUnit }

@MainActor
@Observable
final class AUViewModel {
    var instance = "–"
    var report: ProbeReport?
    @ObservationIgnored var onBluetooth: (@MainActor () -> Void)?
    @ObservationIgnored private var au: RFMAudioUnit?
    @ObservationIgnored private var poller: Task<Void, Never>?

    func attach(_ au: RFMAudioUnit) {
        self.au = au
        au.onEvent = { [weak self] e in
            Task { @MainActor in
                switch e {
                case .stateRestored: self?.refresh()
                case .bluetoothRequested: self?.onBluetooth?()
                }
            }
        }
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refresh() {
        guard let au else { return }
        instance = au.state.short
        let ref = UnitRef(au: au)
        Task.detached {
            let r = ref.au.probe.report(write: false)
            await MainActor.run { [weak self] in self?.report = r }
        }
    }
}
