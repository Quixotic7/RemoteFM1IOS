// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Recording's settings and file names (RFMKit's Recording.swift).

import Foundation
import XCTest
@testable import RFMKit

final class RecordingTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let suite = "rfm-rec-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let s = RecordingSettings(defaults: d)
        XCTAssertEqual(s, RecordingSettings())
        XCTAssertTrue(s.audio)
        XCTAssertFalse(s.screen || s.camera || s.copyToPhotos || s.cameraPreview)
        XCTAssertTrue(s.microphone && s.recordsMic)
        XCTAssertEqual(s.outputs, [.audioFile])

        var t = s
        t.camera = true
        t.cameraSide = .front
        t.zoom = 2
        t.copyToPhotos = true
        t.screenshot = .raw
        t.microphone = false
        t.cameraPreview = true
        t.save(d)
        XCTAssertEqual(RecordingSettings(defaults: d), t)
    }

    func testOutputs() {
        var s = RecordingSettings()
        s.audio = false
        XCTAssertFalse(s.canRecord)
        XCTAssertEqual(s.summary, "nothing")
        s.screen = true
        XCTAssertEqual(s.outputs, [.screenVideo(sound: false)])
        s.audio = true
        s.camera = true
        XCTAssertEqual(s.outputs, [.screenVideo(sound: true), .cameraVideo(sound: true)], "two videos of one take, no WAV")
        XCTAssertEqual(s.summary, "the screen and the rear camera with the app's sound and the microphone")
        s.microphone = false
        XCTAssertEqual(s.summary, "the screen and the rear camera with the app's sound")
        XCTAssertEqual(s.shortSummary, "screen + camera + sound")
        s.screen = false
        s.camera = false
        XCTAssertEqual(s.summary, "the app's sound")
    }

    func testNamesAndFolders() throws {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 11, 7, 19, 43, 2)
        let date = try XCTUnwrap(Calendar.current.date(from: c))
        XCTAssertEqual(RecordingFiles.name(firmware: "Fizz", date: date), "Fizz 2026-11-07 19-43-02")
        XCTAssertEqual(RecordingFiles.name(firmware: "a/b", date: date, tag: "camera"), "a-b 2026-11-07 19-43-02 camera")
        XCTAssertEqual(RecordingFiles.name(firmware: " ", date: date), "RemoteFM1 2026-11-07 19-43-02")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rfm-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(RecordingFiles.audio(in: root).path, root.path + "/audio/recordings")
        XCTAssertEqual(RecordingFiles.videos(in: root).path, root.path + "/recordings")
        XCTAssertEqual(RecordingFiles.screenshots(in: root).path, root.path + "/screenshots")
        let dir = RecordingFiles.videos(in: root)
        let a = RecordingFiles.newFile(dir, "take", "mp4")
        XCTAssertEqual(a.lastPathComponent, "take.mp4")
        try Data().write(to: a)
        XCTAssertEqual(RecordingFiles.newFile(dir, "take", "mp4").lastPathComponent, "take 2.mp4")
    }

    /// the first test build's Recordings and audio/Recordings: renamed lowercase, the files kept
    func testOldFoldersLowercased() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rfm-rec-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["Recordings", "audio/Recordings"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            try Data([1]).write(to: root.appendingPathComponent("\(d)/take.wav"))
        }
        RecordingFiles.lowercaseOldFolders(in: root)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }.sorted(), ["audio", "recordings"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("audio").path), ["recordings"])
        XCTAssertTrue(fm.fileExists(atPath: RecordingFiles.videos(in: root).appendingPathComponent("take.wav").path))
        XCTAssertTrue(fm.fileExists(atPath: RecordingFiles.audio(in: root).appendingPathComponent("take.wav").path))
        RecordingFiles.lowercaseOldFolders(in: root)            // (again: nothing to do)
        XCTAssertTrue(fm.fileExists(atPath: RecordingFiles.videos(in: root).appendingPathComponent("take.wav").path))
    }
}
