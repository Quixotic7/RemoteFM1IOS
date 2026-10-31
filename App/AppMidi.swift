// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// (M8) the app's MIDI side, made once at launch and kept as long as the app: the faceplate's PanelFeed on the player,
// the controllers' input (ControllerInput: never the FM-1, never the OMX-27 while it is in remote mode), MIDI learn on
// the faceplate (MidiLearnMode) and the OMX-27 (OmxLink, its target the same PanelFeed through PanelOmxTarget: its
// holds are its own, touches on a knob tell it which knob its encoder turns, its toasts are the faceplate's). The OMX
// keeps playing in the background (the sound on); its LEDs and screen are cleared only when the app terminates. In
// the simulator the controllers' input starts with no source connected unless the app was launched with -device.

import Foundation
import RFMKit
import UIKit

@MainActor
final class AppMidi {
    let feed: PanelFeed
    let input: ControllerInput
    let learn: MidiLearnMode
    let omx: OmxLink
    let omxTarget: PanelOmxTarget
    let thumbCapture = ThumbCapture()
    private var terminate: NSObjectProtocol?

    init(player: CorePlayer) {
        MidiMapStore.shared.observe()
        let feed = PanelFeed(host: player)
        self.feed = feed
        input = ControllerInput(host: player, defaults: Self.inputDefaults())
        learn = MidiLearnMode(feed: feed, host: player)
        omxTarget = PanelOmxTarget(feed: feed)
        omx = OmxLink(target: omxTarget)
        let omx = omx, input = input
        input.exclude = { e in MainActor.assumeIsolated { omx.owns(e) } }
        input.reconnect()
        omx.onActive = { _ in input.reconnect() }
        omx.onToast = { text, ok in feed.toast.show(text, ok ? .ok : .neutral) }
        feed.onKnobTouched = { k in omx.knobUsed(k) }
        let capture = thumbCapture
        feed.onFrame = { [weak player] rgba in
            guard let player else { return }
            capture.frame(rgba, id: player.current?.firmwareID, booted: player.status.booted && player.mode == .core)
        }
        terminate = NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { omx.willClose() }
        }
        omx.auto()
    }

    /// the simulator (without -device): its own defaults, no source connected at first (it may see the Mac's)
    private static func inputDefaults() -> UserDefaults {
        #if targetEnvironment(simulator)
        if !ProcessInfo.processInfo.arguments.contains("-device"), let d = UserDefaults(suiteName: "rfm1.simulator") {
            if d.string(forKey: "rfm1.midiInput") == nil { d.set("", forKey: "rfm1.midiInput") }
            return d
        }
        #endif
        return .standard
    }

    /// -demomap (screenshots): a few mappings, as if learned
    func demoMap() {
        let s = MidiMapStore.shared
        s.clear()
        s.bind("cc:1:21", to: "KN1", mode: .abs)
        s.bind("cc:1:22", to: "KN2", mode: .rel64)
        s.bind("cc:1:7", to: "MASTER")
        s.bind("note:10:36", to: "PLAY")
    }
}
