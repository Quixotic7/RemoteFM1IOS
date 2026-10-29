// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The extension's principal class: the AU's view controller and its factory, as in Apple's AUv3 template. The audio
// unit itself (RFMAudioUnit) and the probes are in RFMKit. Sheets (Bluetooth, About this firmware) are presented with
// UIKit: SwiftUI's .sheet crashed inside the extension (M2).

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
        RFMFonts.register()
        model.onBluetooth = { [weak self] in self?.presentBluetooth() }
        model.onAbout = { [weak self] info in self?.presentAbout(info) }
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
        let body = ThemeStore.shared.current.body
        view.backgroundColor = UIColor(red: body.r, green: body.g, blue: body.b, alpha: 1)
        preferredContentSize = CGSize(width: 760, height: 352)      // (the iPhone-landscape faceplate's shape)
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

    /// the app's "About this firmware", over the AU's view
    func presentAbout(_ info: CoreInfo?) {
        guard isViewLoaded, view.window != nil, presentedViewController == nil else { return }
        let host = UIHostingController(rootView: AboutFirmware(info: info, onDone: { [weak self] in
            self?.dismiss(animated: false)
        }))
        host.modalPresentationStyle = .overCurrentContext
        definesPresentationContext = true
        present(host, animated: false)
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
    enum Page { case firmware, diagnostics }
    var instance = "–"
    var status = RFMAudioUnit.Status()
    var cores: [CoreInfo] = []
    var report: ProbeReport?
    var diagnosticsOpen = false
    var page: Page?
    var chip = PanelChip.emulator                       // (set only when it changes: the faceplate reads it)
    let ui = FaceplateUI()
    let feed = PanelFeed(host: nil)
    @ObservationIgnored var userPicked = false          // (a view picked in the sheet: no more fitting to the size)
    @ObservationIgnored var onBluetooth: (@MainActor () -> Void)?
    @ObservationIgnored var onAbout: (@MainActor (CoreInfo?) -> Void)?
    @ObservationIgnored private weak var au: RFMAudioUnit?     // (weak: the view never keeps an instance alive)
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var ticks = 0

    var current: CoreInfo? { cores.first { $0.id == status.coreKey } ?? status.coreInfo }
    var perfNote = ""                                   // (M7) a Wasm core that can't keep up
    @ObservationIgnored private var perf = PerfGuard()

    func attach(_ au: RFMAudioUnit) {
        self.au = au
        feed.attach(au)
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
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func refresh() {
        guard let au else { return }
        instance = au.state.short
        status = au.status()
        let note = perf.update(status.core, name: status.coreName)
        if note != perfNote { perfNote = note }
        let c = Self.chip(status.panel)
        if c != chip { chip = c }
        ticks += 1
        if ticks % 10 == 1 {
            let c = au.cores
            if c != cores { cores = c }
            if diagnosticsOpen {
                let ref = UnitRef(au: au)
                Task.detached {
                    let r = ref.au.probe.report(write: false)
                    await MainActor.run { [weak self] in self?.report = r }
                }
            }
        }
    }

    static func chip(_ p: PanelStatus?) -> PanelChip {
        guard let p else { return .emulator }
        if p.heldElsewhere { return .inUse }
        if p.owner { return p.link.isConnected ? .linked : .searching }
        return .emulator
    }

    /// the view for the host's size: very small -> Screen, tall -> Controls, else Full
    func fit(_ size: CGSize) {
        guard !userPicked, size.width > 0, size.height > 0 else { return }
        let p: FaceplateUI.Page = min(size.width, size.height) < 260 ? .screen : size.height > size.width * 1.1 ? .controls : .full
        if p != ui.page { ui.page = p }
    }

    func select(_ id: String) { au?.selectCore(id) }
    func claim() { au?.claimPanel() }
    func restart() { au?.restartCore() }
    func setTranspose(_ t: Int) { au?.settings.transpose = t }
}
