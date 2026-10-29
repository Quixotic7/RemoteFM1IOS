// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// (M8) the app's panel as the OMX-27's target: its keys and buttons held as the OMX's own source in the PanelFeed (a
// touch on the screen letting go never lets go of the OMX's, and omxReleaseAll lets go of the OMX's only), turns and
// MASTER through the feed (rfme_event: the main thread, its one producer), the Keyboard view's notes straight to the
// firmware's MIDI in (rfme_midi_in, to_firmware), K5's pickup as MASTER's mark and toast. The key LEDs are read from
// the panel snapshot, polled here when the faceplate's own tick hasn't (no faceplate on screen, or the app in the
// background with its sound on).

import Foundation

@MainActor
public final class PanelOmxTarget: OmxTarget {
    public let feed: PanelFeed
    /// how old the panel snapshot may be when the OMX reads the LEDs
    static let maxAge: TimeInterval = 0.008

    public init(feed: PanelFeed) { self.feed = feed }

    public func omxKey(_ k: Int, down: Bool) {
        if down { feed.keyDown(k, source: .omx) } else { feed.keyUp(k, source: .omx) }
    }

    public func omxButton(_ l: PanelFeed.Label, down: Bool) { feed.button(l, down: down, source: .omx) }

    public func omxTurn(_ k: PanelFeed.Knob, _ detents: Int) { feed.turn(k, detents, source: .omx) }

    /// (nothing shown: the OMX's own screen names the knob)
    public func omxSelect(_ k: PanelFeed.Knob) {}

    public func omxMaster(_ v: Int) {
        feed.master(v, source: .omx)
        feed.pickup.hide()
    }

    public func omxPickup(pot: Int, at: Int, first: Bool) { feed.pickupAt(pot, at: at, first: first) }

    public func omxFirmwareMIDI(_ bytes: [UInt8]) { feed.midiToFirmware(bytes) }

    public var omxMasterNow: Int { Int(feed.knobs.master) }

    public func omxKeyLevel(_ k: Int) -> UInt8 {
        guard (0..<27).contains(k) else { return 0 }
        feed.pollPanel(ifOlderThan: Self.maxAge)
        return feed.lights.keys[k]
    }

    public func omxReleaseAll() { feed.releaseAll(.omx) }
}
