// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The extension's principal class: the AU's view controller and its factory, as in Apple's AUv3 template. The audio
// unit itself (RFMAudioUnit) and the probes are in RFMKit. Sheets (Bluetooth, About this firmware) are presented with
// UIKit: SwiftUI's .sheet crashed inside the extension (M2). M8: MIDI learn on this instance's host MIDI (MidiLearnMode on
// the faceplate's feed); the learned map is global (MidiMapStore, observed here). On a Mac (a host's window sized to
// preferredContentSize, which it never changes) a resize corner and the sheet's Window size set that size; it is kept
// in the instance's state and as new instances' default. iOS hosts size the view themselves.

import CoreAudioKit
import RFMKit
import SwiftUI
import UIKit

@objc(AudioUnitViewController)
public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private let model = AUViewModel()
    private let log = RFMShared.log("auview")
    private static let isMac = ProcessInfo.processInfo.isiOSAppOnMac
    private static let defaultSize = CGSize(width: 760, height: 352)     // (the iPhone-landscape faceplate's shape)
    private static let sizeKey = "rfm1.auViewSize"                      // (new instances' size on a Mac)
    private var dragFrom = CGSize.zero
    private var dragLogged = Date.distantPast       // (the grip's "changed" log: at most every 250 ms)
    private var dragChecked = false                 // (the bounds after a request: logged once per drag)

    public override func viewDidLoad() {
        super.viewDidLoad()
        RFMFonts.register()
        MidiMapStore.shared.observe()
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
        preferredContentSize = Self.defaultSize
        if Self.isMac {
            let wh = UserDefaults.standard.array(forKey: Self.sizeKey) as? [Double] ?? []
            if wh.count == 2 { preferredContentSize = Self.clamp(CGSize(width: wh[0], height: wh[1])) }
            if let s = model.viewSize { preferredContentSize = Self.clamp(s) }
            model.onViewSize = { [weak self] s in
                guard let self else { return }
                let c = Self.clamp(s)
                guard c != preferredContentSize else { return }
                setSize(c)
                log.info("size from the instance: \(Int(c.width))x\(Int(c.height))")
            }
            model.onPickSize = { [weak self] s in
                guard let self else { return }
                let c = Self.clamp(s)
                setSize(c)
                saveSize(c)
                log.info("window size picked: \(Int(c.width))x\(Int(c.height))")
                checkBounds(c, after: "the pick")
            }
            model.macWindow = true
            let grip = ResizeGrip()
            grip.translatesAutoresizingMaskIntoConstraints = false
            grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragGrip)))
            view.addSubview(grip)
            NSLayoutConstraint.activate([
                grip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                grip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                grip.widthAnchor.constraint(equalToConstant: 22),
                grip.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        model.windowSize = preferredContentSize
        log.info("view loaded, pid \(getpid()), \(Int(self.preferredContentSize.width))x\(Int(self.preferredContentSize.height))")
    }

    private func setSize(_ s: CGSize) {
        if s != preferredContentSize { preferredContentSize = s }
        if s != model.windowSize { model.windowSize = s }
    }

    /// kept in the instance's state and as new instances' default
    private func saveSize(_ s: CGSize) {
        model.viewSize = s
        UserDefaults.standard.set([Double(s.width), Double(s.height)], forKey: Self.sizeKey)
    }

    /// whether the host followed a size request (logs the view's bounds a moment later)
    private func checkBounds(_ s: CGSize, after what: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let b = view.bounds.size
            log.info("bounds \(Int(b.width))x\(Int(b.height)) after \(what, privacy: .public) (\(Int(s.width))x\(Int(s.height)) requested)\(b == s ? "" : ": the host didn't follow", privacy: .public)")
        }
    }

    private static func clamp(_ s: CGSize) -> CGSize {
        CGSize(width: min(max(s.width.rounded(), 380), 2400), height: min(max(s.height.rounded(), 200), 1400))
    }

    /// the resize corner: the size follows the drag (window coordinates: the window grows from its top left)
    @objc private func dragGrip(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            dragFrom = view.bounds.width > 0 ? view.bounds.size : preferredContentSize
            dragLogged = .distantPast
            dragChecked = false
            log.info("grip began at \(Int(self.dragFrom.width))x\(Int(self.dragFrom.height)) (preferred \(Int(self.preferredContentSize.width))x\(Int(self.preferredContentSize.height)))")
        case .changed, .ended:
            let t = g.translation(in: nil)
            let s = Self.clamp(CGSize(width: dragFrom.width + t.x, height: dragFrom.height + t.y))
            setSize(s)
            if !dragChecked {
                dragChecked = true
                checkBounds(s, after: "the grip's first request")
            }
            if g.state == .ended {
                saveSize(s)
                log.info("grip ended: resized to \(Int(s.width))x\(Int(s.height))")
            } else if Date().timeIntervalSince(dragLogged) >= 0.25 {
                dragLogged = Date()
                log.info("grip changed: \(Int(s.width))x\(Int(s.height)) requested")
            }
        case .cancelled:
            log.info("grip cancelled")
        case .failed:
            log.info("grip failed")
        default:
            break
        }
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
        log.info("view appeared, \(Int(self.view.bounds.width))x\(Int(self.view.bounds.height)), preferred \(Int(self.preferredContentSize.width))x\(Int(self.preferredContentSize.height))")
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

/// (a Mac) the resize corner's grip: three diagonal lines, dark under light so they show on any theme. Only its
/// bottom-right half takes touches, so the faceplate's controls beside it keep theirs.
private final class ResizeGrip: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityLabel = "Resize"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        let w = bounds.width, h = bounds.height
        for (color, d) in [(UIColor(white: 0, alpha: 0.5), 1.0), (UIColor(white: 1, alpha: 0.7), 0.0)] {
            let p = UIBezierPath()
            for i in 0..<3 {
                let k = 6 + CGFloat(i) * 5
                p.move(to: CGPoint(x: w - k + d, y: h - 3 + d))
                p.addLine(to: CGPoint(x: w - 3 + d, y: h - k + d))
            }
            p.lineWidth = 1.5
            p.lineCapStyle = .round
            color.setStroke()
            p.stroke()
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) && point.x / bounds.width + point.y / bounds.height >= 1
    }
}

@MainActor
@Observable
final class AUViewModel {
    enum Page { case firmware, states, midi, keyChannel, midiMode, diagnostics }
    var instance = "–"
    var status = RFMAudioUnit.Status()
    var cores: [CoreInfo] = []
    var report: ProbeReport?
    var diagnosticsOpen = false
    var page: Page?
    var modeSource: String?                             // (midiMode) the mapping whose mode the page shows
    @ObservationIgnored var sheetScroll: String?        // (the AU test) a section of the sheet shown at the top
    var chip = PanelChip.emulator                       // (set only when it changes: the faceplate reads it)
    let ui = FaceplateUI()
    let feed = PanelFeed(host: nil)
    @ObservationIgnored private(set) lazy var learn = MidiLearnMode(feed: feed, host: nil)
    @ObservationIgnored var userPicked = false          // (a view picked in the sheet: no more fitting to the size)
    @ObservationIgnored var onBluetooth: (@MainActor () -> Void)?
    @ObservationIgnored var onAbout: (@MainActor (CoreInfo?) -> Void)?
    @ObservationIgnored var onViewSize: (@MainActor (CGSize) -> Void)?    // (a Mac) an instance's own size
    @ObservationIgnored var onPickSize: (@MainActor (CGSize) -> Void)?    // (a Mac) the sheet's Window size
    var macWindow = false                               // (a Mac) the sheet's Window section
    var windowSize = CGSize.zero                        // the view's preferredContentSize
    @ObservationIgnored private weak var au: RFMAudioUnit?     // (weak: the view never keeps an instance alive)
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var ticks = 0

    // (section 18 step 2) the firmware's states in the shared library and its safety copies, read again on a change
    var states: [SavedState] = []
    var copies: [FlashHistory.Snapshot] = []
    var stateMessage = ""
    @ObservationIgnored private var libraryObserver: NSObjectProtocol?

    var current: CoreInfo? { cores.first { $0.id == status.coreKey } ?? status.coreInfo }
    /// the imported firmware playing here was deleted in the app (its mirror is gone; the module stays loaded)
    var fileGone: Bool {
        FirmwareCatalog.isKey(status.coreKey) && status.core.booted && !cores.isEmpty
            && !cores.contains { $0.id == status.coreKey }
    }
    var perfNote = ""                                   // (M7) a Wasm core that can't keep up
    @ObservationIgnored private var perf = PerfGuard()

    /// (a Mac) the sheet's Window sizes (the same shape as the default)
    static let windowSizes: [(String, CGSize)] = [
        ("Small", CGSize(width: 760, height: 352)), ("Medium", CGSize(width: 1000, height: 463)),
        ("Large", CGSize(width: 1280, height: 593)), ("Extra large", CGSize(width: 1600, height: 741)),
    ]

    /// the instance's own view size (the resize corner's, kept in its state)
    var viewSize: CGSize? {
        get { au?.viewSize }
        set { au?.viewSize = newValue }
    }

    func attach(_ au: RFMAudioUnit) {
        self.au = au
        feed.attach(au)
        learn.attach(au)
        au.onEvent = { [weak self] e in
            Task { @MainActor in
                switch e {
                case .stateRestored:
                    self?.refresh()
                    if let s = self?.au?.viewSize { self?.onViewSize?(s) }
                case .bluetoothRequested: self?.onBluetooth?()
                case .show(let what): self?.show(what)
                }
            }
        }
        if let s = au.viewSize { onViewSize?(s) }     // (after onEvent: a restore in between isn't missed)
        if libraryObserver == nil {
            libraryObserver = NotificationCenter.default.addObserver(forName: StateLibrary.didChange, object: nil,
                                                                     queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadStates() }
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

    /// Learn: the sheet closes, the faceplate picks controls (the host's MIDI is what it learns from)
    func startLearn() { withAnimation(.easeInOut(duration: 0.28)) { learn.start(ui) } }

    /// (the AU test) a page for a screenshot
    func show(_ what: String) {
        if what == "midi" {
            ui.sheetOpen = true
            page = .midi
        } else if what == "keychannel" {
            ui.sheetOpen = true
            page = .keyChannel
        } else if what == "midimode" {                  // (the first encoder mapping; none: the page says so)
            modeSource = MidiMapStore.shared.mappings.first { $0.mode != nil }?.src ?? ""
            ui.sheetOpen = true
            page = .midiMode
        } else if what == "window" {
            #if DEBUG
            macWindow = true                            // (a screenshot of the Mac-only section on iOS)
            #endif
            sheetScroll = "window"
        } else if what.hasPrefix("sheet") {             // "sheet:midi": the sheet scrolled to its MIDI section
            sheetScroll = what.split(separator: ":").dropFirst().first.map(String.init)
            page = nil
            ui.sheetOpen = true
        } else if what == "states" {                    // (a state saved here first when the library has none)
            if let au, let f = au.firmware, au.library.list(f.firmwareID).isEmpty {
                _ = try? au.saveState(name: "Saved in the AU")
            }
            reloadStates()
            ui.sheetOpen = true
            page = .states
        } else if what.hasPrefix("learn") {
            learn.start(ui)
            if let t = what.split(separator: ":").dropFirst().first { learn.pick(String(t)) }
        }
    }

    func select(_ id: String) { au?.selectCore(id) }
    func claim() { au?.claimPanel() }
    func restart() { au?.restartCore() }
    /// (section 18) a safety copy, then a fresh flash
    func resetFlash() { au?.resetFlash() }

    // MARK: states (section 18 step 2)

    func reloadStates() {
        guard let au, let f = au.firmware else { states = []; copies = []; return }
        states = au.library.list(f.firmwareID)
        copies = au.history.list(f.firmwareID)
    }

    func saveState(_ name: String) {
        guard let au else { return }
        do { let s = try au.saveState(name: name); stateMessage = "Saved \"\(s.name)\" to the library." }
        catch { stateMessage = "Save failed: \(error.localizedDescription)" }
        reloadStates()
    }

    func loadState(_ s: SavedState) {
        guard let au else { return }
        do {
            try au.loadState(s)
            let v = s.versionNote(running: status.coreVersion)
            stateMessage = "Loaded \"\(s.name)\"" + (v.isEmpty ? "." : " (\(v)).")
                + " The host keeps it in the project when the project is next saved."
        } catch { stateMessage = "Load failed: \(error.localizedDescription)" }
        refresh()
        reloadStates()
    }

    func renameState(_ s: SavedState, _ name: String) { _ = try? au?.library.rename(s, to: name); reloadStates() }
    func deleteState(_ s: SavedState) { au?.library.delete(s); reloadStates() }

    func restore(_ snap: FlashHistory.Snapshot) {
        guard let au else { return }
        do {
            try au.restore(snap)
            stateMessage = "Restored the copy of \(snap.date.formatted(date: .abbreviated, time: .shortened)). The host "
                + "keeps it in the project when the project is next saved."
        } catch { stateMessage = "Restore failed: \(error.localizedDescription)" }
        refresh()
        reloadStates()
    }
    /// the instance's MIDI settings (shown at once; the status catches up on its next poll)
    func changeSettings(_ change: (inout AUSettings) -> Void) {
        guard let au else { return }
        var s = au.settings
        change(&s)
        au.settings = s
        status.settings = s
    }
}
