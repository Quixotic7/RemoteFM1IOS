// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The app's prompt to put RemoteFM1 on an FM-1 (PLAN.md section 13), so the install page is found. Nothing here sends
// MIDI: an FM-1 is seen in CoreMIDI's list (FM1Ports, read-only), and RemoteFM1 is whatever answers the app's link's
// HELLO.
//
//   FM1Ports      each MIDI device entity that is an FM-1: RemoteMidi.c's candidate rule (rfme_fm1_candidate: the
//                 link sends HELLO to these), or a USB port named like an FM-1 with other USB IDs (another firmware:
//                 RemoteFM1 always has 1209:0001, so the link never talks to it). Bluetooth: by its name only
//   the prompt    install: a candidate has been there for a few seconds while the app's link searched and nothing
//                 answered ("isn't answering as RemoteFM1"), or a USB port with other IDs ("isn't running
//                 RemoteFM1"); over Bluetooth only, it says a USB cable is needed. update: the unit answered with an
//                 older RemoteFM1 than releases.json's newest (a smaller notice)
//   never         while an install runs or the install page has the FM-1, while another instance (an AU) holds the
//                 unit, or with the fake unit (the simulator) unless DEBUG's -fm1prompt asks (screenshots:
//                 install | unanswered | bluetooth | update)
// "Not now" is remembered per release version (UserDefaults), so a newer release asks again.

import Foundation
import Observation
import RFMCore
#if canImport(CoreMIDI)
import CoreMIDI
#endif

/// an FM-1 in CoreMIDI's device list
public struct FM1Port: Equatable, Sendable {
    public var name: String
    public var bluetooth: Bool
    /// the link sends it HELLO (RemoteMidi.c's rule); false: a USB FM-1 with other USB IDs (another firmware)
    public var candidate: Bool

    public init(name: String, bluetooth: Bool, candidate: Bool) {
        self.name = name
        self.bluetooth = bluetooth
        self.candidate = candidate
    }
}

public enum FM1Ports {
    /// what a device entity is (nil: not an FM-1). usbID: kMIDIPropertyUSBVendorProduct, nil when it has none (and
    /// always nil over Bluetooth)
    public static func classify(bluetooth: Bool, usbID: Int32?, deviceName: String, endpointName: String) -> FM1Port? {
        let name = endpointName.isEmpty ? deviceName : endpointName
        let usb = bluetooth ? nil : usbID
        let cand = deviceName.withCString { d in
            endpointName.withCString { e in rfme_fm1_candidate(usb == nil ? 0 : 1, usb ?? 0, d, e) }
        }
        if cand != 0 { return FM1Port(name: name, bluetooth: bluetooth, candidate: true) }
        guard usb != nil, !endpointName.lowercased().contains("update") else { return nil }
        let names = (deviceName + " " + endpointName).lowercased()
        guard names.contains("fm-1") || names.contains("felucca") else { return nil }
        return FM1Port(name: name, bluetooth: false, candidate: false)
    }

    /// the FM-1s in CoreMIDI's device list now (read-only: no client, nothing sent; as RemoteMidi.c's cm_scan)
    public static func scan() -> [FM1Port] {
        #if canImport(CoreMIDI)
        var out: [FM1Port] = []
        for i in 0..<MIDIGetNumberOfDevices() {
            let dev = MIDIGetDevice(i)
            guard dev != 0, !offline(dev) else { continue }
            let drv = string(dev, kMIDIPropertyDriverOwner)
            if drv.localizedCaseInsensitiveContains("IAC") || drv.localizedCaseInsensitiveContains("RTP") { continue }
            let ble = drv.localizedCaseInsensitiveContains("Bluetooth")
            let devName = name(dev)
            for k in 0..<MIDIDeviceGetNumberOfEntities(dev) {
                let ent = MIDIDeviceGetEntity(dev, k)
                guard MIDIEntityGetNumberOfSources(ent) > 0, MIDIEntityGetNumberOfDestinations(ent) > 0 else { continue }
                let src = MIDIEntityGetSource(ent, 0), dst = MIDIEntityGetDestination(ent, 0)
                guard !offline(ent), !offline(src), !offline(dst) else { continue }
                var usb: Int32 = 0
                let key = "USBVendorProduct" as CFString      // (kMIDIPropertyUSBVendorProduct)
                let hasUSB = MIDIObjectGetIntegerProperty(ent, key, &usb) == noErr
                    || MIDIObjectGetIntegerProperty(dev, key, &usb) == noErr
                if let p = classify(bluetooth: ble, usbID: hasUSB ? usb : nil, deviceName: devName, endpointName: name(dst)) {
                    out.append(p)
                }
            }
        }
        return out
        #else
        return []
        #endif
    }

    #if canImport(CoreMIDI)
    private static func string(_ o: MIDIObjectRef, _ p: CFString) -> String {
        var s: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(o, p, &s) == noErr, let s else { return "" }
        return s.takeRetainedValue() as String
    }

    private static func name(_ o: MIDIObjectRef) -> String {
        let d = string(o, kMIDIPropertyDisplayName)
        return d.isEmpty ? string(o, kMIDIPropertyName) : d
    }

    private static func offline(_ o: MIDIObjectRef) -> Bool {
        var v: Int32 = 0
        return MIDIObjectGetIntegerProperty(o, kMIDIPropertyOffline, &v) == noErr && v != 0
    }
    #endif
}

/// the prompt's rules, without a clock or CoreMIDI of its own (tests drive it)
public struct InstallPromptState: Equatable, Sendable {
    public enum Prompt: Equatable, Sendable {
        case none
        /// unanswered: an FM-1 the link sent HELLO and nothing answered (it may run RemoteFM1 and be stuck);
        /// false: another firmware's USB IDs. bluetoothOnly: it must be connected with a USB cable to install
        case install(unanswered: Bool, bluetoothOnly: Bool)
        /// a newer RemoteFM1 (its version) for the unit that answered
        case update(version: String, bluetooth: Bool)
    }

    public struct Input: Equatable, Sendable {
        public var enabled = true               // not the fake unit (or DEBUG asked)
        public var installing = false           // an install runs, or the install page has the FM-1
        public var heldElsewhere = false        // another instance (an AU in another app) holds the unit
        public var searching = false            // the app's link is looking for a unit and nothing answers
        public var answered = false             // a RemoteFM1 unit answered HELLO (its session starts or runs)
        public var unitVersion: RemoteFM1Version?
        public var unitOverBluetooth = false
        public var newest: RemoteFM1Version?    // releases.json's newest installable release
        public var ports: [FM1Port] = []
        public var notNowInstall: String?       // the release "Not now" was said for ("" not known then)
        public var notNowUpdate: String?

        public init() {}
    }

    /// how long a candidate has to answer HELLO (a unit that was just plugged in boots first)
    public static let answerWait: TimeInterval = 6
    /// a port with other USB IDs: settled
    public static let otherWait: TimeInterval = 2

    public private(set) var prompt = Prompt.none
    private var candidateSince: Date?
    private var otherSince: Date?

    public init() {}

    @discardableResult
    public mutating func update(_ i: Input, now: Date) -> Prompt {
        prompt = decide(i, now)
        return prompt
    }

    private mutating func decide(_ i: Input, _ now: Date) -> Prompt {
        guard i.enabled, !i.installing, !i.heldElsewhere else {
            candidateSince = nil
            otherSince = nil
            return .none
        }
        if i.answered {
            candidateSince = nil
            otherSince = nil
            guard let v = i.unitVersion, let n = i.newest, n > v, i.notNowUpdate != n.description else { return .none }
            return .update(version: n.description, bluetooth: i.unitOverBluetooth)
        }
        let cands = i.ports.filter(\.candidate), others = i.ports.filter { !$0.candidate }
        candidateSince = i.searching && !cands.isEmpty ? candidateSince ?? now : nil
        otherSince = others.isEmpty ? nil : otherSince ?? now
        if i.notNowInstall == (i.newest?.description ?? "") { return .none }
        if let t = otherSince, now.timeIntervalSince(t) >= Self.otherWait {
            return .install(unanswered: false, bluetoothOnly: false)
        }
        if let t = candidateSince, now.timeIntervalSince(t) >= Self.answerWait {
            return .install(unanswered: true, bluetoothOnly: cands.allSatisfy(\.bluetooth))
        }
        return .none
    }
}

extension InstallPromptState.Prompt {
    public var isInstall: Bool { if case .install = self { true } else { false } }

    /// the prompt's words: a title and a line
    public var title: String {
        switch self {
        case .none: ""
        case .install(let unanswered, _): unanswered ? "This FM-1 isn't answering as RemoteFM1. Install it?"
            : "This FM-1 isn't running RemoteFM1. Install it?"
        case .update(let v, _): "RemoteFM1 \(v) is available for this FM-1"
        }
    }

    public var detail: String {
        switch self {
        case .none: ""
        case .install(let unanswered, let ble):
            (unanswered ? "It may run another firmware. If it runs RemoteFM1, turn it off and on again. " : "")
                + (ble ? "To install, connect it to this device with a USB cable."
                   : "RemoteFM1 lets this app use the FM-1's screen, keys and knobs. It installs over USB.")
        case .update(_, let ble): ble ? "Install it over a USB cable." : "Tap to see what's new and install it."
        }
    }
}

/// the app's prompt: reads the link, the installer and CoreMIDI's list about once a second
@MainActor
@Observable
public final class InstallPrompter {
    public private(set) var prompt = InstallPromptState.Prompt.none
    /// the app shows the install page (the installer has, or may take, the FM-1)
    public var installPageOpen = false {
        didSet { if installPageOpen != oldValue { tick() } }
    }

    public static let notNowInstallKey = "rfm1.installPrompt.notNow"
    public static let notNowUpdateKey = "rfm1.updateNotice.notNow"

    @ObservationIgnored private let controller: RemoteController
    @ObservationIgnored private let installer: FirmwareInstaller
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var machine = InstallPromptState()
    @ObservationIgnored private var forced: InstallPromptState.Prompt?
    @ObservationIgnored private var ports: [FM1Port] = []
    @ObservationIgnored private var scanned = Date.distantPast
    @ObservationIgnored private var fetched = false
    @ObservationIgnored private var poller: Task<Void, Never>?

    public init(controller: RemoteController, installer: FirmwareInstaller, defaults: UserDefaults = .standard,
                arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.controller = controller
        self.installer = installer
        self.defaults = defaults
        #if DEBUG
        if let i = arguments.firstIndex(of: "-fm1prompt"), i + 1 < arguments.count {
            forced = switch arguments[i + 1] {
            case "unanswered": .install(unanswered: true, bluetoothOnly: false)
            case "bluetooth": .install(unanswered: true, bluetoothOnly: true)
            case "update": .update(version: installer.releases.newest?.version ?? "0.2.3", bluetooth: false)
            default: .install(unanswered: false, bluetoothOnly: false)
            }
        }
        #endif
    }

    /// polls once a second while the app runs
    public func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// "Not now": this prompt stays away until a newer release
    public func notNow() {
        switch prompt {
        case .install: defaults.set(installer.releases.newest?.version ?? "", forKey: Self.notNowInstallKey)
        case .update(let v, _): defaults.set(v, forKey: Self.notNowUpdateKey)
        case .none: return
        }
        forced = nil
        prompt = .none
        tick()
    }

    func tick() {
        if let f = forced {
            let p: InstallPromptState.Prompt = installPageOpen || installer.isBusy ? .none : f
            if p != prompt { prompt = p }
            return
        }
        let real = !controller.backend.isFake
        if real, Date().timeIntervalSince(scanned) >= 2 {
            ports = FM1Ports.scan()
            scanned = Date()
        }
        var i = InstallPromptState.Input()
        i.enabled = real
        i.installing = installPageOpen || installer.isBusy || installer.panelPaused
        i.heldElsewhere = controller.panel?.heldElsewhere == true
        let st = controller.state
        i.answered = st.isConnected || st == .starting
        i.searching = controller.isRunning && (st == .searching || st == .notFound || st == .lost)
        if i.answered, let h = controller.hello {
            i.unitVersion = RemoteFM1Version(identity: h.identity) ?? RemoteFM1Version(string: h.firmwareVersion)
            i.unitOverBluetooth = h.isBluetooth
            if real, !fetched, i.unitVersion != nil {       // (the list once per launch, for the update notice)
                fetched = true
                Task { await installer.releases.refreshIfStale(3600) }
            }
        }
        i.newest = installer.releases.newest?.parsedVersion
        i.ports = ports
        i.notNowInstall = defaults.string(forKey: Self.notNowInstallKey)
        i.notNowUpdate = defaults.string(forKey: Self.notNowUpdateKey)
        let p = machine.update(i, now: Date())
        if p != prompt { prompt = p }
    }
}

#if os(iOS)
import SwiftUI

/// the prompt over the faceplate: the install one as a card (Install, Not now), the update one as a smaller line
/// (a tap opens the page, × is Not now). Drawn in the sheet's dark style
public struct InstallPromptView: View {
    let prompt: InstallPromptState.Prompt
    let install: () -> Void
    let notNow: () -> Void

    public init(prompt: InstallPromptState.Prompt, install: @escaping () -> Void, notNow: @escaping () -> Void) {
        self.prompt = prompt
        self.install = install
        self.notNow = notNow
    }

    public var body: some View {
        Group {
            switch prompt {
            case .none: EmptyView()
            case .install: card
            case .update: notice
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: prompt)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt.title).font(RFMFonts.ui(16, 700)).foregroundStyle(Palette.sheetText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(prompt.detail).font(RFMFonts.ui(13)).foregroundStyle(Palette.sheetMuted2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SheetButton("Install", accent: true, action: install)
                    .accessibilityHint("Opens the page that installs RemoteFM1 on the FM-1")
                SheetButton("Not now", action: notNow)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.sheetBackground.opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.sheetAccent, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .transition(.opacity.combined(with: .offset(y: 16)))
        .accessibilityElement(children: .contain)
    }

    private var notice: some View {
        HStack(spacing: 4) {
            Button(action: install) {
                HStack(spacing: 8) {
                    Circle().fill(Palette.sheetAccent).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt.title).font(RFMFonts.ui(13, 700)).foregroundStyle(Palette.sheetText)
                            .lineLimit(2).minimumScaleFactor(0.85)
                        Text(prompt.detail).font(RFMFonts.ui(12)).foregroundStyle(Palette.sheetMuted2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.sheetMuted2)
                }
                .padding(.leading, 14).padding(.vertical, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: notNow) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.sheetMuted2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not now")
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.sheetBackground.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.sheetBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .frame(maxWidth: 460)
        .padding(.horizontal, 16)
        .transition(.opacity.combined(with: .offset(y: 12)))
    }
}
#endif
