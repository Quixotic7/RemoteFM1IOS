// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The battery (2026-11-01, the owner: users found the app drains the battery in the background). The app keeps its
// audio session so a firmware plays with the screen locked; this decides when it stops instead:
//   BackgroundMode  the setting: keep playing / only with an FM-1 connected / stop when I leave the app
//   IdleWatch       how long nothing happened: no input (keys, panel, MIDI) and no sound above -60 dBFS
//   BackgroundPolicy  the decision, from the setting, the FM-1's link and the idle time
// The app (App/Battery.swift) looks every 15 s while in the background and stops the firmware (saved first: its clock
// and sound off, the audio session let go, so iOS suspends the app) when this says so; it runs again when the app
// comes back.

import Foundation

public enum BackgroundMode: String, CaseIterable, Sendable {
    case always         // keep playing in the background
    case withFM1        // only while an FM-1 is connected
    case never          // stop when I leave the app (locking the screen too)

    public var title: String {
        switch self {
        case .always: "Keep playing"
        case .withFM1: "Only with an FM-1 connected"
        case .never: "Stop playing"
        }
    }

    /// what the choice does, in a line
    public var detail: String {
        switch self {
        case .always: "The firmware keeps playing with the screen locked. This uses the battery."
        case .withFM1: "It keeps playing while an FM-1 is connected, and stops when none is."
        case .never: "It stops when you leave the app or lock the screen."
        }
    }
}

public struct BackgroundPolicy: Equatable, Sendable {
    public static let modeKey = "rfm1.background", idleKey = "rfm1.idleStop"
    public var mode: BackgroundMode = .always
    /// stop after this long with nothing happening, in any mode
    public var idleStop = true
    public var idleAfter: TimeInterval = 600

    public init(mode: BackgroundMode = .always, idleStop: Bool = true) {
        self.mode = mode
        self.idleStop = idleStop
    }

    public init(defaults: UserDefaults) {
        mode = BackgroundMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .always
        idleStop = defaults.object(forKey: Self.idleKey) as? Bool ?? true
    }

    public func save(_ d: UserDefaults) {
        d.set(mode.rawValue, forKey: Self.modeKey)
        d.set(idleStop, forKey: Self.idleKey)
    }

    /// in the background: stop now? (nil: keep going) and why
    public func stop(fm1Linked: Bool, idleFor: TimeInterval) -> String? {
        switch mode {
        case .never: return "set to stop when leaving the app"
        case .withFM1 where !fm1Linked: return "no FM-1 connected"
        default: break
        }
        if idleStop, idleFor >= idleAfter { return "nothing played for \(Int(idleAfter / 60)) minutes" }
        return nil
    }
}

/// how long nothing happened, from the player's Activity samples
public struct IdleWatch: Sendable {
    private var last: CorePlayer.Activity?
    private var since: Date

    public init(now: Date = Date()) { since = now }

    /// a new sample: anything new (an input, a sound) restarts the quiet time
    public mutating func feed(_ a: CorePlayer.Activity, now: Date = Date()) {
        if let l = last, l.inputs == a.inputs, l.lastSoundMs == a.lastSoundMs {
            // (the same: quiet goes on)
        } else {
            since = now
        }
        last = a
    }

    public func idleFor(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(since) }

    public mutating func reset(now: Date = Date()) {
        since = now
        last = nil
    }
}
