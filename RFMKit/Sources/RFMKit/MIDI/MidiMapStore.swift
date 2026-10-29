// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The learned map is global (as the website's prefs.midiMap): one set for the app and every AU instance. It lives in
// midi-map.json in the App Group container (without a working App Group: this process's Application Support, as the
// lease does). A save posts a Darwin notification, so every process reads it again.
//   MidiMapStore     the UI's (main actor): the map, its changes, saved at once
//   MidiMapFollower  an engine (CorePlayer's, each AU's) that keeps the map: applied at start and on every change,
//                    from this process at once, from another on its notification

import Foundation
import Observation
import RFMCore

@MainActor
@Observable
public final class MidiMapStore {
    public static let shared = MidiMapStore()
    public nonisolated static let fileName = "midi-map.json"
    public nonisolated static let changedNotification = "\(RFMShared.appGroup).midimap"

    /// where the map is: the App Group's midi-map.json, else this process's Application Support
    public nonisolated static var defaultURL: URL {
        if let g = RFMShared.groupContainer() { return g.appendingPathComponent(fileName) }
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    /// the map in a file (none, or unreadable: empty)
    public nonisolated static func read(_ url: URL) -> MidiMap {
        guard let d = try? Data(contentsOf: url) else { return MidiMap() }
        return MidiMap(json: d)
    }

    public private(set) var map: MidiMap
    public let url: URL
    @ObservationIgnored private var observing = false

    /// url: nil = defaultURL (tests: a file of their own)
    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        map = Self.read(self.url)
    }

    public var mappings: [MidiMapping] { map.mappings }
    public var speed: Double { map.speed }
    public var boundTargets: Set<String> { map.boundTargets }
    public func sourcesOf(_ target: String) -> [MidiMapping] { map.sourcesOf(target) }
    public func describe(_ m: MidiMapping) -> String { m.description }
    public var entries: [rfme_map_entry_t] { map.entries }

    @discardableResult public func bind(_ src: String, to target: String, mode: MidiMode? = nil) -> MidiMapping? {
        var m = map
        let mp = m.bind(src, to: target, mode: mode)
        if mp != nil { change(m) }
        return mp
    }

    public func setMode(_ src: String, _ mode: MidiMode) {
        var m = map
        m.setMode(src, mode)
        change(m)
    }

    @discardableResult public func remove(_ src: String) -> Bool {
        var m = map
        let ok = m.remove(src)
        change(m)
        return ok
    }

    /// a target's bindings removed; how many
    @discardableResult public func forget(_ target: String) -> Int {
        var m = map
        let n = m.forget(target)
        change(m)
        return n
    }

    public func clear() {
        var m = map
        m.clear()
        change(m)
    }

    public func setSpeed(_ v: Double) {
        var m = map
        m.setSpeed(v)
        change(m)
    }

    /// reads the file again (another process changed it)
    public func load() {
        let m = Self.read(url)
        if m != map { map = m }
    }

    /// listens for the other processes' changes (call once from the UI)
    public func observe() {
        guard !observing else { return }
        observing = true
        let me = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), me, { _, obs, _, _, _ in
            guard let obs else { return }
            let ref = MapStoreRef(store: Unmanaged<MidiMapStore>.fromOpaque(obs).takeUnretainedValue())
            DispatchQueue.main.async { MainActor.assumeIsolated { ref.store.load() } }
        }, Self.changedNotification as CFString, nil, .deliverImmediately)
    }

    // saved, this process's engines given it at once, the others told
    private func change(_ m: MidiMap) {
        guard m != map else { return }
        map = m
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? m.json.write(to: url, options: .atomic)
        MidiMapFollower.changed(m, url: url)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Self.changedNotification as CFString), nil, nil, true)
    }
}

private struct MapStoreRef: @unchecked Sendable { let store: MidiMapStore }

/// An engine that keeps the global map: applied now, and again whenever it changes (this process: at once; another:
/// on the Darwin notification, the file read again). stop() before the engine is freed.
public final class MidiMapFollower: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()                 // rfme_set_midi_map has one writer at a time
    private var e: OpaquePointer?
    private var applied: MidiMap?

    public init(engine: OpaquePointer, url: URL = MidiMapStore.defaultURL) {
        self.url = url
        e = engine
        apply(MidiMapStore.read(url))
        Self.register(self)
    }

    deinit { stop() }

    /// the engine is let go (before rfme_free)
    public func stop() {
        lock.withLock { e = nil }
        Self.unregister(self)
    }

    /// the map the engine has now (nil: none yet, or stopped)
    public var current: MidiMap? { lock.withLock { applied } }

    /// reads the file again
    public func reload() { apply(MidiMapStore.read(url)) }

    func apply(_ m: MidiMap) {
        lock.withLock {
            guard let e, m != applied else { return }
            applied = m
            m.apply(to: e)
        }
    }

    // ---- every follower in this process, and one observer for them all
    private struct Weak { weak var f: MidiMapFollower? }
    private nonisolated(unsafe) static var all: [ObjectIdentifier: Weak] = [:]
    private nonisolated(unsafe) static var observing = false
    private static let allLock = NSLock()

    private static func register(_ f: MidiMapFollower) {
        let start = allLock.withLock { () -> Bool in
            all[ObjectIdentifier(f)] = Weak(f: f)
            defer { observing = true }
            return !observing
        }
        guard start else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            MidiMapFollower.reloadAll()
        }, MidiMapStore.changedNotification as CFString, nil, .deliverImmediately)
    }

    private static func unregister(_ f: MidiMapFollower) { _ = allLock.withLock { all.removeValue(forKey: ObjectIdentifier(f)) } }

    private static func followers() -> [MidiMapFollower] { allLock.withLock { all.values.compactMap(\.f) } }

    /// (the store, after a save) this process's engines on that file get the map now
    static func changed(_ m: MidiMap, url: URL) {
        for f in followers() where f.url == url { f.apply(m) }
    }

    static func reloadAll() {
        for f in followers() { f.reload() }
    }
}
