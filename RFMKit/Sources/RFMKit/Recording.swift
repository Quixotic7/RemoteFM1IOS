// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Recording in the app (the owner, 2026-11-07; a tester filming themself playing their FM-1): the quick menu (the
// top-left chip) has Record, Take screenshot and Recording settings…. What it records:
//   Audio        the app's sound (no microphone)                                      on by default
//   Screen       the app's screen, as a video (ReplayKit)                             off
//   Camera       the front or rear camera at a zoom, as a video                       off
// With a picture (screen or camera) the sound goes into each video; Screen and Camera both on make two videos of the
// same take. Audio alone is a WAV in RemoteFM1/audio/recordings (where firmwares read samples, so a sampler can load
// it); videos go to RemoteFM1/recordings and screenshots to RemoteFM1/screenshots (the folders lowercase, the owner's
// call), or to Photos with Copy to Photos (the file kept only if Photos won't take it). Screenshots: the whole screen,
// or the firmware's raw 240x240 screen (for development).
// Permissions are asked only when they're needed: the camera at the first camera recording, Photos at the first copy.
// The app (App/Recorder.swift) does the recording; this is the settings and the file names.

import Foundation

public struct RecordingSettings: Equatable, Sendable {
    public enum Camera: String, CaseIterable, Sendable { case front, rear }
    public enum Screenshot: String, CaseIterable, Sendable { case screen, raw }

    public var audio = true
    public var screen = false
    public var camera = false
    public var cameraSide: Camera = .rear
    /// as the Camera app shows it: 0.5 the ultra wide, 1 the wide, 2 and 3 zoomed in
    public var zoom = 1.0
    public var copyToPhotos = false
    public var screenshot: Screenshot = .screen

    public static let key = "rfm1.recording"
    public static let zooms: [Double] = [0.5, 1, 2, 3]

    public init() {}

    public init(defaults: UserDefaults) {
        let d = defaults.dictionary(forKey: Self.key) ?? [:]
        audio = d["audio"] as? Bool ?? true
        screen = d["screen"] as? Bool ?? false
        camera = d["camera"] as? Bool ?? false
        cameraSide = (d["cameraSide"] as? String).flatMap(Camera.init) ?? .rear
        zoom = d["zoom"] as? Double ?? 1
        copyToPhotos = d["copyToPhotos"] as? Bool ?? false
        screenshot = (d["screenshot"] as? String).flatMap(Screenshot.init) ?? .screen
    }

    public func save(_ defaults: UserDefaults) {
        defaults.set(["audio": audio, "screen": screen, "camera": camera, "cameraSide": cameraSide.rawValue,
                      "zoom": zoom, "copyToPhotos": copyToPhotos, "screenshot": screenshot.rawValue], forKey: Self.key)
    }

    /// what a recording makes
    public enum Output: Equatable, Sendable {
        case audioFile                      // a WAV
        case screenVideo(sound: Bool)
        case cameraVideo(sound: Bool)
    }

    public var outputs: [Output] {
        var o: [Output] = []
        if screen { o.append(.screenVideo(sound: audio)) }
        if camera { o.append(.cameraVideo(sound: audio)) }
        if o.isEmpty, audio { o.append(.audioFile) }
        return o
    }

    /// nothing chosen: no recording to start
    public var canRecord: Bool { !outputs.isEmpty }

    /// for the quick menu: "sound", "screen + sound", "camera + screen"
    public var shortSummary: String {
        let parts = [screen ? "screen" : nil, camera ? "camera" : nil, audio ? "sound" : nil].compactMap { $0 }
        return parts.isEmpty ? "nothing on" : parts.joined(separator: " + ")
    }

    /// what Start records, in a few words
    public var summary: String {
        let pics = [screen ? "the screen" : nil, camera ? "the \(cameraSide.rawValue) camera" : nil].compactMap { $0 }
        if pics.isEmpty { return audio ? "the app's sound" : "nothing" }
        return pics.joined(separator: " and ") + (audio ? " with the app's sound" : ", no sound")
    }
}

public enum RecordingFiles {
    public static func videos(in root: URL = RemoteFM1Folder.app) -> URL { root.appendingPathComponent("recordings") }
    public static func screenshots(in root: URL = RemoteFM1Folder.app) -> URL { root.appendingPathComponent("screenshots") }
    /// sound only: in audio/, where firmwares read samples
    public static func audio(in root: URL = RemoteFM1Folder.app) -> URL { root.appendingPathComponent("audio/recordings") }

    /// (the first test build, 2026-11-07) Recordings and audio/Recordings renamed lowercase, their files kept
    public static func lowercaseOldFolders(in root: URL = RemoteFM1Folder.app) {
        let fm = FileManager.default
        for (old, new) in [("Recordings", videos(in: root)), ("audio/Recordings", audio(in: root))] {
            let o = root.appendingPathComponent(old)
            guard let names = try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(old).deletingLastPathComponent().path),
                  names.contains(o.lastPathComponent) else { continue }      // (a listing: exact case, on any volume)
            let tmp = o.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            guard (try? fm.moveItem(at: o, to: tmp)) != nil else { continue }
            if !fm.fileExists(atPath: new.path), (try? fm.moveItem(at: tmp, to: new)) != nil { continue }
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)   // (both there: the files moved in)
            for f in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] {
                let dst = new.appendingPathComponent(f)
                if !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: tmp.appendingPathComponent(f), to: dst) }
            }
            if ((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []).isEmpty { try? fm.removeItem(at: tmp) }
            else { try? fm.moveItem(at: tmp, to: o) }                      // (clashing names: left as they were)
        }
    }

    /// "Fizz 2026-11-07 19-43-02" (a camera take adds " camera"): what files of one take are called
    public static func name(firmware: String, date: Date = Date(), tag: String = "") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let safe = firmware.map { "/\\:?*\"<>|".contains($0) ? "-" : $0 }
        let base = String(safe).trimmingCharacters(in: .whitespaces)
        return [base.isEmpty ? "RemoteFM1" : base, f.string(from: date), tag].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// a file in `dir` that doesn't exist yet (" 2", " 3" added when it does); the folder made
    public static func newFile(_ dir: URL, _ name: String, _ ext: String) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var u = dir.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while fm.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return u
    }
}
