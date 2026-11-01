// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The battery in the app (RFMKit's BackgroundPolicy): in the background, every 15 s, the firmware is stopped when the
// setting says so (no FM-1, stop when leaving) or nothing happened for 10 minutes; it runs again when the app comes
// back. The lock screen shows RemoteFM1 as Now Playing with the firmware's name, and its Pause / Stop stop it there
// (Play starts it again), so a forgotten app is easy to see and to end.

import MediaPlayer
import RFMKit
import UIKit

@MainActor
@Observable
final class Battery {
    var policy: BackgroundPolicy { didSet { policy.save(defaults) } }
    /// why the firmware was stopped last ("" none), shown in Settings
    private(set) var lastStop = ""

    @ObservationIgnored private let player: CorePlayer
    @ObservationIgnored private let controller: RemoteController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watch = IdleWatch()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var commands = false
    @ObservationIgnored private var background = false

    init(player: CorePlayer, controller: RemoteController, defaults: UserDefaults = .standard) {
        self.player = player
        self.controller = controller
        self.defaults = defaults
        policy = BackgroundPolicy(defaults: defaults)
    }

    func enteredBackground() {
        background = true
        watch.reset()
        nowPlaying()
        check()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.check()
            }
        }
    }

    func becameActive() {
        background = false
        loop?.cancel()
        loop = nil
        player.setFrameMs(15)
        if player.suspended { player.resumeFromBattery() }
        nowPlaying()
    }

    /// the screen redrawn every 250 ms in the background unless an FM-1 shows it (its screen is the firmware's)
    private func frameRate() {
        player.setFrameMs(background && !controller.state.isConnected ? 250 : 15)
    }

    private func check() {
        frameRate()
        guard !player.suspended, player.mode == .core else { return }
        watch.feed(player.activity)
        if let why = policy.stop(fm1Linked: controller.state.isConnected, idleFor: watch.idleFor()) { stop(why) }
    }

    private func stop(_ why: String) {
        lastStop = why
        loop?.cancel()
        loop = nil
        Task {
            await player.suspendForBattery(why)
            nowPlaying()
        }
    }

    // MARK: the lock screen

    private func nowPlaying() {
        if !commands { setUpCommands() }
        let c = MPNowPlayingInfoCenter.default()
        guard player.mode == .core else { c.nowPlayingInfo = nil; return }
        c.nowPlayingInfo = [MPMediaItemPropertyTitle: player.current?.name ?? "RemoteFM1",
                            MPMediaItemPropertyArtist: "RemoteFM1",
                            MPNowPlayingInfoPropertyIsLiveStream: true,
                            MPNowPlayingInfoPropertyPlaybackRate: player.suspended ? 0.0 : 1.0]
        c.playbackState = player.suspended ? .paused : .playing
    }

    private func setUpCommands() {
        commands = true
        let rc = MPRemoteCommandCenter.shared()
        let stopIt: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            self?.stop("stopped from the lock screen")
            return .success
        }
        rc.pauseCommand.addTarget(handler: stopIt)
        rc.stopCommand.addTarget(handler: stopIt)
        rc.togglePlayPauseCommand.addTarget { [weak self] e in
            guard let self else { return .commandFailed }
            if self.player.suspended { self.player.resumeFromBattery(); self.nowPlaying(); return .success }
            return stopIt(e)
        }
        rc.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.resumeFromBattery()
            self.watch.reset()
            self.nowPlaying()
            return .success
        }
    }
}
