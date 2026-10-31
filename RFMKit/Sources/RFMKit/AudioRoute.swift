// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The standalone app's audio output (MIDI & audio › Audio output): the route's name, what a route change asks of the
// engine, and the system route picker (AVRoutePickerView) opened from a sheet row. With the FM-1 on USB it is also a
// USB sound card and iOS sends the app's sound there; the picker lets the user choose the iPhone, AirPods or headphones
// instead (the session is .playback without mixing: every output route, AirPods by A2DP, is allowed). We never force a
// route: the OS's choice stands until the user picks. Not in the AU (the host owns its audio).

import Foundation
#if os(iOS)
import AVFAudio
import AVKit
import SwiftUI
#endif

public enum AudioRoute {
    /// why the route changed, as far as the engine cares (AVAudioSession.RouteChangeReason mapped)
    public enum Cause: Sendable, Equatable { case newDevice, oldDeviceGone, categoryChange, override, other }
    public enum Action: Sendable, Equatable { case none, rename, restart }

    /// after a route change: the name always read again; the engine started again when it stopped (iOS stops it when the
    /// device in use goes, e.g. the FM-1's USB cable pulled) or never ran. A rate or buffer change also posts
    /// AVAudioEngineConfigurationChange, which restarts it (CorePlayer.audioConfigurationChanged).
    public static func action(_ cause: Cause, audioOn: Bool, engineRunning: Bool) -> Action {
        guard audioOn else { return .none }
        return engineRunning ? .rename : .restart
    }

    public struct Output: Sendable, Equatable {
        public var name: String
        public var usb: Bool
        public init(name: String, usb: Bool) { self.name = name; self.usb = usb }
    }

    /// the row's value: the outputs' names ("iPhone Speaker", "AirPods Pro", "FM-1")
    public static func name(_ outs: [Output]) -> String {
        outs.isEmpty ? "None" : outs.map(\.name).joined(separator: ", ")
    }

    /// a hint under the row when the sound goes to a USB sound card (the FM-1)
    public static func hint(_ outs: [Output]) -> String? {
        outs.contains(where: \.usb) ? "The sound goes out of the FM-1's USB audio. Tap Audio output for the iPhone, AirPods or headphones." : nil
    }

    #if os(iOS)
    public static func cause(_ r: AVAudioSession.RouteChangeReason) -> Cause {
        switch r {
        case .newDeviceAvailable: .newDevice
        case .oldDeviceUnavailable: .oldDeviceGone
        case .categoryChange: .categoryChange
        case .override: .override
        default: .other
        }
    }

    @MainActor public static var current: [Output] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { Output(name: $0.portName, usb: $0.portType == .usbAudio) }
    }
    #endif
}

#if os(iOS)
/// a sheet row "Audio output  <route>" that opens the system's route picker (an AVRoutePickerView kept out of sight,
/// its button triggered from the row)
public struct AudioOutputRow: View {
    let value: String
    var divider = true
    @State private var picker = RoutePicker.Box()

    public init(value: String, divider: Bool = true) {
        self.value = value
        self.divider = divider
    }

    public var body: some View {
        SheetRow("Audio output", value: value, divider: divider) { picker.open() }
            .background(RoutePicker(box: picker).frame(width: 1, height: 1).clipped().opacity(0.001).allowsHitTesting(false))
    }
}

struct RoutePicker: UIViewRepresentable {
    @MainActor final class Box {
        weak var view: AVRoutePickerView?
        func open() {
            guard let v = view else { return }
            func button(_ u: UIView) -> UIButton? { (u as? UIButton) ?? u.subviews.lazy.compactMap(button).first }
            button(v)?.sendActions(for: .touchUpInside)
        }
    }
    let box: Box

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        box.view = v
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) { box.view = v }
}
#endif
