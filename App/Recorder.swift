// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Recording in the app (RFMKit's Recording.swift has the settings and the file names, RecordingMux the mix): the
// app's sound from the player's output tap, the microphone (the default input: the built-in mic or an interface) from a
// tap on the player's input (it switches the session to playAndRecord meanwhile), the camera from an AVCaptureSession
// that leaves the app's audio session alone, the screen from the app's own window (RecordingOverlay.swift: the badge and
// the camera's picture are in windows of their own, so a screen video never has them). Each sound is written to its own WAV and each
// picture to a video of its own as it comes; at the end the sounds are mixed into each video (RecordingMux: the picture
// copied, not encoded again). Every stream is timed by the host clock, so they line up.
// A take is written on one queue (Take); the app stops it when it leaves the front (the camera stops then).

import AVFoundation
import CoreMedia
import Photos
import RFMKit
import SwiftUI
import UIKit

@MainActor
@Observable
final class Recorder {
    var settings: RecordingSettings {
        didSet {
            settings.save(defaults)
            if isRecording, settings.cameraPreview != oldValue.cameraPreview { showPreview() }
        }
    }
    private(set) var isRecording = false
    private(set) var busy = false
    private(set) var started: Date?
    /// the camera while it records (the preview in the corner, when that's on)
    private(set) var cameraSession: AVCaptureSession?
    /// what the last start, stop or screenshot did ("" none)
    private(set) var note = ""
    /// the screen is in the take
    private(set) var recordingScreen = false

    /// what was just saved: the card that opens it (Open, Show in Files, Photos); it goes after a while
    struct Saved: Identifiable, Equatable {
        let id = UUID()
        let text: String
        /// the files still here (not moved to Photos), the first opened by Open
        let files: [URL]
        let inPhotos: Bool
    }
    var saved: Saved?

    @ObservationIgnored private let player: CorePlayer
    @ObservationIgnored private let feed: PanelFeed
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var take: Take?
    @ObservationIgnored private var screenCapture: ScreenCapture?
    @ObservationIgnored private let overlay = RecordingOverlay()
    @ObservationIgnored private let log = RFMShared.log("recording")

    init(player: CorePlayer, feed: PanelFeed, defaults: UserDefaults = .standard) {
        self.player = player
        self.feed = feed
        self.defaults = defaults
        settings = RecordingSettings(defaults: defaults)
        DispatchQueue.global(qos: .utility).async { RecordingFiles.lowercaseOldFolders() }
    }

    // MARK: recording

    func start() async {
        guard !isRecording, !busy else { return }
        let s = settings
        guard s.canRecord else { return show("Turn on Audio, Screen or Camera first.", .bad) }
        busy = true
        defer { busy = false }
        if s.camera, !(await Self.allowed(.video)) {
            return show("RemoteFM1 can't use the camera: allow it in Settings › RemoteFM1 › Camera.", .bad)
        }
        guard let main = Self.mainWindow else { return show("No screen to record.", .bad) }
        var mic = s.recordsMic
        if mic, !(await Self.allowed(.audio)) {
            mic = false
            show("Recording without the microphone: allow it in Settings › RemoteFM1 › Microphone.", .bad)
        }
        if s.audio, !player.audioRunning { log.info("recording: the sound is off; the app's track is silent until it plays") }

        let name = RecordingFiles.name(firmware: player.current?.name ?? "RemoteFM1")
        let audioDir = RecordingFiles.audio(), videoDir = RecordingFiles.videos()
        let t = Take()
        do {
            if s.audio { t.app = try WavStem(RecordingFiles.newFile(audioDir, name + (mic ? " app" : ""), "wav")) }
            if mic { t.mic = try WavStem(RecordingFiles.newFile(audioDir, name + " mic", "wav")) }
            if s.screen {
                t.screen = try Movie(RecordingFiles.newFile(videoDir, name + (s.camera ? " screen" : ""), "mp4"), sound: s.audio)
            }
            if s.camera {
                let cap = try CaptureSource(side: s.cameraSide, zoom: s.zoom)
                t.capture = cap
                t.camera = try Movie(RecordingFiles.newFile(videoDir, name + (s.screen ? " camera" : ""), "mp4"),
                                     sound: s.audio, transform: cap.transform)
            }
        } catch {
            t.discard()
            return show("Couldn't start recording: \(error.localizedDescription)", .bad)
        }
        if t.app != nil { player.setOutputTap(t.soundTap()) }
        if mic {                                        // (the session records too: the sound restarts once)
            player.setInputTap(t.micTap())
            player.recordingInput = true
        }
        if let cap = t.capture {
            cap.start(on: t.q, deliver: t.cameraFrame())
            cameraSession = cap.session
        }
        if t.screen != nil {
            let c = ScreenCapture(window: main, deliver: t.screenFrame())
            c.start()
            screenCapture = c
        }
        take = t
        started = Date()
        recordingScreen = t.screen != nil
        isRecording = true
        overlay.show(recorder: self, over: main)
        showPreview()
        if note.hasPrefix("Recording without") == false { note = "" }
        log.info("recording: started (\(s.summary, privacy: .public)\(mic ? "" : s.recordsMic ? ", no mic" : "", privacy: .public))")
    }

    func stop() async {
        guard isRecording, let t = take, !busy else { return }
        busy = true
        defer { busy = false }
        isRecording = false
        recordingScreen = false
        take = nil
        started = nil
        await stopStreams(t)
        if t.screen != nil || t.camera != nil { feed.toast.show("Saving the video…", .neutral, seconds: 30) }
        let r = await t.finish()
        feed.toast.hide()
        let files = r.videos + r.sounds
        guard !files.isEmpty else { return show("Nothing was recorded.", .bad) }
        if r.videos.isEmpty, settings.screen || settings.camera {
            return show("The video didn't record; the sound is saved in RemoteFM1 › audio › recordings.", .bad)
        }
        let sounds = r.sounds.isEmpty ? "" : r.sounds.count == 1 ? " The sound is in audio › recordings." :
            " The app's sound and the mic are in audio › recordings."
        if settings.copyToPhotos, !r.videos.isEmpty {
            let moved = await Self.toPhotos(r.videos, video: true)
            let left = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            offer(moved == 0 ? "Photos didn't take it: saved in RemoteFM1 › recordings." : "Saved to Photos." + sounds,
                  left, photos: moved > 0)
        } else {
            offer(r.videos.isEmpty ? "Saved in RemoteFM1 › audio › recordings." : "Saved in RemoteFM1 › recordings." + sounds,
                  files)
        }
    }

    private func stopStreams(_ t: Take) async {
        player.setOutputTap(nil)
        player.setInputTap(nil)
        screenCapture?.stop()
        screenCapture = nil
        overlay.hide()
        if let cap = t.capture { await cap.stop(on: t.q) }
        cameraSession = nil
        player.recordingInput = false
    }

    /// the camera's picture beside the badge, when that's on (it can be dragged)
    private func showPreview() {
        guard let main = Self.mainWindow else { return }
        if settings.cameraPreview, let s = cameraSession { overlay.showPreview(s, over: main) } else { overlay.hidePreview() }
    }

    /// the app's own window (the overlay's never become key)
    static var mainWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    // MARK: screenshots

    /// the whole screen (the sheet closed first by the caller), or the firmware's own 240x240 screen
    func screenshot() async {
        let png: Data?
        switch settings.screenshot {
        case .raw:
            png = feed.screen.image.flatMap { UIImage(cgImage: $0).pngData() }
        case .screen:
            guard let w = Self.mainWindow else {
                return show("No screen to take.", .bad)
            }
            let f = UIGraphicsImageRendererFormat(for: w.traitCollection)
            png = UIGraphicsImageRenderer(bounds: w.bounds, format: f).image { _ in
                w.drawHierarchy(in: w.bounds, afterScreenUpdates: false)
            }.pngData()
        }
        guard let png else { return show("No screen to take.", .bad) }
        let name = RecordingFiles.name(firmware: player.current?.name ?? "RemoteFM1",
                                       tag: settings.screenshot == .raw ? "240" : "")
        let url = RecordingFiles.newFile(RecordingFiles.screenshots(), name, "png")
        do { try png.write(to: url) } catch { return show("Couldn't save the screenshot: \(error.localizedDescription)", .bad) }
        if settings.copyToPhotos, await Self.toPhotos([url], video: false) == 1 {
            offer("Screenshot saved to Photos.", [], photos: true)
        } else {
            offer(settings.copyToPhotos ? "Photos didn't take it: saved in RemoteFM1 › screenshots."
                                        : "Screenshot saved in RemoteFM1 › screenshots.", [url])
        }
    }

    // MARK: permissions and Photos

    private static func allowed(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    /// the files added to Photos (asked the first time) and removed here once it has them; how many it took
    private static func toPhotos(_ files: [URL], video: Bool) async -> Int {
        let st = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard st == .authorized || st == .limited else { return 0 }
        var n = 0
        for u in files {
            do {
                try await SystemCalls.addToPhotos(u, video: video)
                try? FileManager.default.removeItem(at: u)
                n += 1
            } catch {
                RFMShared.log("recording").error("photos: \(error.localizedDescription, privacy: .public)")
            }
        }
        return n
    }

    /// the saved card (instead of a toast): it goes after 12 s unless another replaced it
    private func offer(_ text: String, _ files: [URL], photos: Bool = false) {
        note = text
        let s = Saved(text: text, files: files, inPhotos: photos)
        saved = s
        UIAccessibility.post(notification: .announcement, argument: text)
        log.info("recording: \(text, privacy: .public)")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if self?.saved?.id == s.id { self?.saved = nil }
        }
    }

    private func show(_ text: String, _ tone: ToastCenter.Tone) {
        note = text
        feed.toast.show(text, tone)
        log.info("recording: \(text, privacy: .public)")
    }
}

// MARK: - system calls

/// calls whose callbacks come on the system's own queues, made outside the main actor: a callback written inside it
/// asserts it runs there and stops the app (2026-11-07 on a phone: Photos' changes queue)
enum SystemCalls {
    static func addToPhotos(_ u: URL, video: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: video ? .video : .photo, fileURL: u, options: nil)
        }
    }
}

/// a time on the host clock, in seconds (what every stream is timed by)
private func hostSeconds(_ t: CMTime) -> Double { CMTimeGetSeconds(t) }

// MARK: - one take, written on its queue

/// one recording's files and streams; the pictures and the mic arrive on `q`, the app's sound on the tap's thread
final class Take: @unchecked Sendable {
    let q = DispatchQueue(label: "com.quixotic7.remotefm1.recording", qos: .userInitiated)
    var app: WavStem?
    var mic: WavStem?
    var screen: Movie?
    var camera: Movie?
    var capture: CaptureSource?

    /// the player's output tap: the app's sound to its WAV
    func soundTap() -> CorePlayer.OutputTap { { [self] b, t in app?.write(b, at: Self.host(t)) } }

    /// the player's input tap: the microphone to its WAV
    func micTap() -> CorePlayer.OutputTap { { [self] b, t in mic?.write(b, at: Self.host(t)) } }

    static func host(_ t: AVAudioTime) -> Double {
        hostSeconds(t.isHostTimeValid ? CMClockMakeHostTimeFromSystemUnits(t.hostTime) : CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func cameraFrame() -> (CMSampleBuffer) -> Void {
        { [self] sb in camera?.append(sb) }            // (already on q: the output's queue)
    }

    /// ScreenCapture's frames (already on the host clock)
    func screenFrame() -> (CMSampleBuffer) -> Void {
        { [self] sb in q.async { [self] in screen?.append(sb) } }
    }

    /// the videos (each with the sounds mixed in) and the sound files
    func finish() async -> (videos: [URL], sounds: [URL]) {
        await withCheckedContinuation { c in q.async { c.resume() } }      // (frames still queued go in first)
        let sounds = [app, mic].compactMap { $0?.close() }
        var stems: [(url: URL, start: Double)] = []
        for s in [app, mic] { if let s, let u = s.written, let at = s.start { stems.append((u, at)) } }
        var videos: [URL] = []
        for m in [screen, camera].compactMap({ $0 }) {
            guard let pic = await m.finish(), let start = m.start else { continue }
            let use = m.sound ? stems.map { RecordingMux.Stem($0.url, offset: $0.start - start) } : []
            do {
                if use.isEmpty {
                    try FileManager.default.moveItem(at: pic, to: m.url)
                } else {
                    try await RecordingMux.mux(video: pic, stems: use, to: m.url)
                    try? FileManager.default.removeItem(at: pic)
                }
                videos.append(m.url)
            } catch {
                RFMShared.log("recording").error("mix: \(error.localizedDescription, privacy: .public); the picture kept alone")
                try? FileManager.default.removeItem(at: m.url)
                if (try? FileManager.default.moveItem(at: pic, to: m.url)) != nil { videos.append(m.url) }
            }
        }
        return (videos, sounds)
    }

    func discard() {
        for s in [app, mic] { if let u = s?.close() { try? FileManager.default.removeItem(at: u) } }
        for m in [screen, camera].compactMap({ $0 }) { m.cancel() }
    }
}

// MARK: - a sound's WAV

/// one sound to a 24-bit WAV, made at its first buffer (its rate and channels); when that buffer began (host seconds)
final class WavStem: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var failed = false
    private var first: Double?

    init(_ url: URL) throws {
        try Data().write(to: url)                       // (the name taken now)
        self.url = url
    }

    func write(_ b: AVAudioPCMBuffer, at host: Double) {
        lock.withLock {
            if file == nil, !failed {
                let f = b.format
                let set: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: f.sampleRate,
                                          AVNumberOfChannelsKey: f.channelCount, AVLinearPCMBitDepthKey: 24,
                                          AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                          AVLinearPCMIsNonInterleaved: false]
                do {
                    file = try AVAudioFile(forWriting: url, settings: set, commonFormat: f.commonFormat, interleaved: f.isInterleaved)
                    first = host
                } catch {
                    failed = true
                    RFMShared.log("recording").error("wav \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let w = file, b.format == w.processingFormat else { return }   // (a rate change mid-take: left out)
            try? w.write(from: b)
        }
    }

    /// the file once something was written
    var written: URL? { lock.withLock { file != nil || first != nil ? url : nil } }
    var start: Double? { lock.withLock { first } }

    /// closed: the file, or nil (nothing came: removed)
    @discardableResult
    func close() -> URL? {
        lock.withLock {
            let had = file != nil
            file = nil
            if !had { try? FileManager.default.removeItem(at: url) }
            return had ? url : nil
        }
    }
}

// MARK: - a video's picture

/// the picture alone (H.264) to a hidden file beside `url`, its timeline from the first frame; the sounds are mixed in
/// at the end (Take.finish)
final class Movie: @unchecked Sendable {
    let url: URL
    let sound: Bool
    var orientation: CGAffineTransform
    private let picture: URL
    private let writer: AVAssetWriter
    private var video: AVAssetWriterInput?
    /// the first frame's time (host seconds)
    private(set) var start: Double?
    private var first: CMTime?

    init(_ url: URL, sound: Bool, transform: CGAffineTransform = .identity) throws {
        self.url = url
        self.sound = sound
        orientation = transform
        try? FileManager.default.removeItem(at: url)    // (newFile only named it)
        picture = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).picture.mp4")
        try? FileManager.default.removeItem(at: picture)
        writer = try AVAssetWriter(outputURL: picture, fileType: .mp4)
    }

    func append(_ sb: CMSampleBuffer) {
        if video == nil, !begin(sb) { return }
        guard writer.status == .writing, let v = video, v.isReadyForMoreMediaData, let f = first,
              let r = Self.retimed(sb, by: CMTimeSubtract(.zero, f)) else { return }
        v.append(r)
    }

    private func begin(_ sb: CMSampleBuffer) -> Bool {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return false }
        let dim = CMVideoFormatDescriptionGetDimensions(fd)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(dim.width), AVVideoHeightKey: Int(dim.height)])
        v.expectsMediaDataInRealTime = true
        v.transform = orientation
        guard writer.canAdd(v) else { return false }
        writer.add(v)
        video = v
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        first = pts
        start = hostSeconds(pts)
        return true
    }

    /// the picture's file, or nil (no frame came, or it failed: removed)
    func finish() async -> URL? {
        guard first != nil, writer.status == .writing else { cancel(); return nil }
        video?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .completed { return picture }
        RFMShared.log("recording").error("video: \(self.writer.error?.localizedDescription ?? "failed", privacy: .public)")
        try? FileManager.default.removeItem(at: picture)
        return nil
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: picture)
    }

    static func retimed(_ sb: CMSampleBuffer, by shift: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb),
                                        presentationTimeStamp: CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sb), shift),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

// MARK: - the camera

/// the front or rear camera at a zoom (no microphone: that comes through the player's engine, on the app's clock); it
/// leaves the app's audio session alone
final class CaptureSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// the rotation that makes the video upright as the phone is held now
    let transform: CGAffineTransform
    private let output = AVCaptureVideoDataOutput()
    private var deliver: ((CMSampleBuffer) -> Void)?

    /// the camera a side records with (the rear: the virtual one with the ultra wide, so 0.5x works)
    static func device(_ side: RecordingSettings.Camera) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = side == .rear
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                position: side == .rear ? .back : .front).devices.first
    }

    /// the device's zoom factor for a zoom as the Camera app shows it (1x: the wide camera)
    static func factor(_ d: AVCaptureDevice, zoom: Double) -> CGFloat {
        let wide = d.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 1
        let hasUltraWide = d.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let f = CGFloat(zoom) * (hasUltraWide ? wide : 1)
        return min(max(f, d.minAvailableVideoZoomFactor), min(d.maxAvailableVideoZoomFactor, 16))
    }

    init(side: RecordingSettings.Camera, zoom: Double) throws {
        guard let d = Self.device(side) else { throw RecordingError.noCamera }
        session.automaticallyConfiguresApplicationAudioSession = false     // (the firmware's sound left alone)
        session.beginConfiguration()
        for p in [AVCaptureSession.Preset.hd1920x1080, .high] where session.canSetSessionPreset(p) {
            session.sessionPreset = p
            break
        }
        let input = try AVCaptureDeviceInput(device: d)
        guard session.canAddInput(input) else { throw RecordingError.noCamera }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { throw RecordingError.noCamera }
        session.addOutput(output)
        session.commitConfiguration()
        let angle = AVCaptureDevice.RotationCoordinator(device: d, previewLayer: nil).videoRotationAngleForHorizonLevelCapture
        transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
        try d.lockForConfiguration()
        d.videoZoomFactor = Self.factor(d, zoom: zoom)
        d.unlockForConfiguration()
        super.init()
    }

    func start(on q: DispatchQueue, deliver: @escaping (CMSampleBuffer) -> Void) {
        self.deliver = deliver
        output.setSampleBufferDelegate(self, queue: q)
        q.async { [session] in session.startRunning() }
    }

    func stop(on q: DispatchQueue) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            q.async { [self] in
                session.stopRunning()
                output.setSampleBufferDelegate(nil, queue: nil)
                deliver = nil
                c.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        // (the session's clock to the host clock, which the sounds use)
        guard let clock = session.synchronizationClock else { deliver?(sb); return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        if CMTimeCompare(host, pts) == 0 { deliver?(sb); return }
        if let r = Movie.retimed(sb, by: CMTimeSubtract(host, pts)) { deliver?(r) }
    }
}

enum RecordingError: LocalizedError {
    case noCamera
    var errorDescription: String? { "no camera to record with" }
}
