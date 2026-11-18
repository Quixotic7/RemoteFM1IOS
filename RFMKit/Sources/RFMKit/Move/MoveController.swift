// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The Ableton Move as the emulated FM-1's controller (RFMMove.h, MoveLink.h): the link's switch and address, its
// status, its settings (kept in defaults) and the sequencer's 32 projects (MoveProjectStore, one file a slot). The
// link's core runs on the player's engine, so it works while a firmware plays here (Firmware runs on This iPhone or
// My FM-1). The app's side of js/move-link.js: the requests answered as the web's store does.

import Foundation
import Observation
import RFMCore

public struct MoveStatus: Equatable, Sendable {
    public enum State: Int, Sendable { case off = 0, connecting, connected, retrying, error }
    public var state: State = .off
    public var text = "Off"
    public var name = ""
    public var overUSB = false
    public var battery: Int? = nil
    public var mode = 0
    public var project = -1
    public var playing = false
    public var ticking = false
    public var inputs: UInt32 = 0, screens: UInt32 = 0, connects: UInt32 = 0, seqMidi: UInt32 = 0

    public static let modeNames = ["FM-1", "MIDI", "Control", "Sequencer"]
    /// a line for the settings page
    public var summary: String {
        guard state == .connected else { return text }
        var s = text
        if let battery { s += ", battery \(battery) %" }
        s += ". \(Self.modeNames[min(max(mode, 0), 3)]) mode"
        if project >= 0 { s += ", \(MoveProjectFile.displayName(project))" }
        if playing { s += ", playing" }
        if !ticking { s += ". Play a firmware for the Move to drive it" }
        return s + "."
    }
}

@MainActor @Observable
public final class MoveController {
    public static let enabledKey = "rfm1.move.enabled", hostKey = "rfm1.move.host"
    public static let settingsKey = "rfm1.move.settings", projectKey = "rfm1.move.project"

    public private(set) var status = MoveStatus()
    /// the link wanted (off by default)
    public var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            apply()
        }
    }
    /// the Move's address: move.local (Wi-Fi) by default, or an IP address
    public var host: String {
        didSet {
            guard host != oldValue else { return }
            defaults.set(host, forKey: Self.hostKey)
            if enabled { apply() }
        }
    }
    public private(set) var projects: [MoveProject] = []
    /// a message for the app (a project that couldn't be kept); nil once shown
    public var problem: String?

    @ObservationIgnored nonisolated(unsafe) let link: OpaquePointer
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public let store: MoveProjectStore
    @ObservationIgnored private weak var player: CorePlayer?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var buffer: [UInt8]?                 // cut / copy in projects mode
    @ObservationIgnored private var data = [UInt8](repeating: 0, count: Int(rfmm_project_max()))

    public init(player: CorePlayer, store: MoveProjectStore = MoveProjectStore(folder: MoveProjectStore.app),
                defaults: UserDefaults = .standard, hostName: String = "RemoteFM1 iOS") {
        self.player = player
        self.store = store
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        host = defaults.string(forKey: Self.hostKey) ?? "move.local"
        let settings = [UInt8](defaults.data(forKey: Self.settingsKey) ?? Data())
        link = settings.withUnsafeBufferPointer { b in
            hostName.withCString { rfmm_new(b.count > 0 ? b.baseAddress : nil, UInt32(b.count), $0) }
        }
        player.attachMove(link)
        loadProjects()
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.poll()
            }
        }
        apply()
    }

    /// (the app quits, tests) the link stopped and let go of; the player no longer runs it
    public func shutdown() {
        poller?.cancel()
        rfmm_project_flush(link)
        rfmm_stop(link)
        player?.attachMove(nil)
    }

    /// the app goes to the background or the Move is turned off: the open project saved now if it changed
    public func flush() { rfmm_project_flush(link) }

    private func apply() {
        if enabled {
            host.withCString { rfmm_start(link, $0) }
        } else {
            rfmm_project_flush(link)
            rfmm_stop(link)
        }
    }

    // MARK: the projects

    private func loadProjects() {
        projects = store.all()
        for p in projects { info(p) }
        let open = min(max(defaults.integer(forKey: Self.projectKey), 0), MoveProjectFile.slots - 1)
        let blob = projects.first { $0.slot == open }?.bytes ?? []
        blob.withUnsafeBufferPointer {
            rfmm_projects_init(link, MoveProjectStore.dirBits(projects), Int32(open), $0.baseAddress, UInt32($0.count))
        }
    }

    private func info(_ p: MoveProject) {
        p.bytes.withUnsafeBufferPointer { rfmm_project_info(link, Int32(p.slot), $0.baseAddress, UInt32($0.count)) }
    }

    /// the store read again (after a request, or a file added in Files): the slots and each one's picture
    public func refreshProjects() {
        projects = store.all()
        rfmm_project_dir(link, MoveProjectStore.dirBits(projects))
        for p in projects { info(p) }
    }

    private func save(_ slot: Int, _ blob: [UInt8]) {
        do {
            try store.write(slot, blob)
        } catch {
            problem = "The Move's \(MoveProjectFile.displayName(slot)) was not kept: \(error.localizedDescription)."
        }
    }

    // MARK: the link's requests and status

    func poll() {
        var r = rfmm_request_t()
        var changed = false
        while data.withUnsafeMutableBufferPointer({ rfmm_take_request(link, &r, $0.baseAddress, UInt32($0.count)) }) != 0 {
            let slot = Int(r.slot), bytes = Array(data[0..<Int(r.len)])
            switch Int(r.kind) {
            case Int(RFMM_REQ_SETTINGS):
                defaults.set(Data(bytes), forKey: Self.settingsKey)
            case Int(RFMM_REQ_PROJECT_SAVE):
                save(slot, bytes)
                changed = true
            case Int(RFMM_REQ_PROJECT_LOAD):
                let blob = store.read(slot)?.bytes ?? []
                blob.withUnsafeBufferPointer { rfmm_project_answer(link, Int32(slot), $0.baseAddress, UInt32($0.count)) }
            case Int(RFMM_REQ_PROJECT_DELETE):
                store.delete(slot)
                changed = true
            case Int(RFMM_REQ_PROJECT_CUT), Int(RFMM_REQ_PROJECT_COPY):
                if let p = store.read(slot) { buffer = p.bytes }
                if Int(r.kind) == Int(RFMM_REQ_PROJECT_CUT) {
                    store.delete(slot)
                    changed = true
                }
            case Int(RFMM_REQ_PROJECT_PASTE):
                if let buffer {
                    save(slot, buffer)
                    changed = true
                }
            case Int(RFMM_REQ_PROJECT_COLOR):
                if let p = store.read(slot) {
                    save(slot, MoveProjectFile.withColor(p.bytes, Int(r.value)))
                    changed = true
                }
            default:
                break
            }
        }
        if changed { refreshProjects() }
        var st = rfmm_status_t()
        rfmm_status(link, &st)
        let s = Self.status(of: st)
        if s.project >= 0, s.project != status.project { defaults.set(s.project, forKey: Self.projectKey) }
        if s != status { status = s }
    }

    nonisolated static func status(of st: rfmm_status_t) -> MoveStatus {
        var s = MoveStatus()
        s.state = MoveStatus.State(rawValue: Int(st.state)) ?? .error
        s.text = RemoteController.string(st.text)
        s.name = RemoteController.string(st.name)
        s.overUSB = Int(st.via) == Int(RFMM_VIA_USB)
        s.battery = st.battery >= 0 ? Int(st.battery) : nil
        s.mode = Int(st.mode)
        s.project = Int(st.project)
        s.playing = st.playing != 0
        s.ticking = st.ticking != 0
        s.inputs = st.inputs
        s.screens = st.screens
        s.connects = st.connects
        s.seqMidi = st.seq_midi
        return s
    }
}
