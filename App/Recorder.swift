// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Recording in the app (RFMKit's Recording.swift has the settings and the file names): the app's sound from the
// player's output tap (never the microphone), the screen from ReplayKit, the camera from an AVCaptureSession that has no
// audio input and leaves the app's audio session alone (so the firmware keeps playing and an FM-1 stays linked: a
// separate camera app took the audio away). Every stream is timed by the host clock, so sound and picture line up.
// A take is written on one queue (Take); the app stops it when it leaves the front (the camera and ReplayKit stop then).

import AVFoundation
import CoreMedia
import Photos
import ReplayKit
import RFMKit
import SwiftUI
import UIKit

@MainActor
@Observable
final class Recorder {
    var settings: RecordingSettings { didSet { settings.save(defaults) } }
    private(set) var isRecording = false
    private(set) var busy = false
    private(set) var started: Date?
    /// the camera while it records (the preview in the corner)
    private(set) var cameraSession: AVCaptureSession?
    /// what the last start, stop or screenshot did ("" none)
    private(set) var note = ""

    @ObservationIgnored private let player: CorePlayer
    @ObservationIgnored private let feed: PanelFeed
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var take: Take?
    @ObservationIgnored private let log = RFMShared.log("recording")

    init(player: CorePlayer, feed: PanelFeed, defaults: UserDefaults = .standard) {
        self.player = player
        self.feed = feed
        self.defaults = defaults
        settings = RecordingSettings(defaults: defaults)
    }

    var screenAvailable: Bool { RPScreenRecorder.shared().isAvailable }
    var cameraAvailable: Bool { CameraSource.device(.rear) != nil || CameraSource.device(.front) != nil }

    // MARK: recording

    func start() async {
        guard !isRecording, !busy else { return }
        let s = settings
        guard s.canRecord else { return show("Turn on Audio, Screen or Camera first.", .bad) }
        busy = true
        defer { busy = false }
        if s.camera, !(await Self.cameraAllowed()) {
            return show("RemoteFM1 can't use the camera: allow it in Settings › RemoteFM1 › Camera.", .bad)
        }
        if s.screen, !screenAvailable { return show("Screen recording isn't available here.", .bad) }
        if s.audio, !player.audioRunning { log.info("recording: the sound is off; the recording is silent until it plays") }

        let name = RecordingFiles.name(firmware: player.current?.name ?? "RemoteFM1")
        let t = Take(rate: player.outputRate ?? AVAudioSession.sharedInstance().sampleRate)
        do {
            for o in s.outputs {
                switch o {
                case .audioFile:
                    try t.openWAV(RecordingFiles.newFile(RecordingFiles.audio(), name, "wav"))
                case .screenVideo(let sound):
                    t.screen = try Movie(RecordingFiles.newFile(RecordingFiles.videos(), name + (s.camera ? " screen" : ""), "mp4"),
                                         sound: sound, rate: t.rate)
                case .cameraVideo(let sound):
                    let cam = try CameraSource(side: s.cameraSide, zoom: s.zoom)
                    t.camera = try Movie(RecordingFiles.newFile(RecordingFiles.videos(), name + (s.screen ? " camera" : ""), "mp4"),
                                         sound: sound, rate: t.rate, transform: cam.transform)
                    t.cameraSource = cam
                }
            }
            // (a video with sound: the sound kept as a WAV too until a video is saved, so a take whose picture
            // never came still has its sound)
            if s.audio, !s.outputs.contains(.audioFile) {
                try t.openWAV(RecordingFiles.newFile(RecordingFiles.audio(), name, "wav"), backup: true)
            }
        } catch {
            t.discard()
            return show("Couldn't start recording: \(error.localizedDescription)", .bad)
        }
        if t.wantsSound { player.setOutputTap(t.soundTap()) }
        if let cam = t.cameraSource {
            cam.start(on: t.q, deliver: t.cameraFrame())
            cameraSession = cam.session
        }
        if t.screen != nil {
            let r = RPScreenRecorder.shared()
            r.isMicrophoneEnabled = false
            r.isCameraEnabled = false
            let err: Error? = await withCheckedContinuation { c in
                r.startCapture(handler: t.screenFrame(), completionHandler: { e in c.resume(returning: e) })
            }
            if let err {
                await stopStreams(t)
                t.discard()
                return show("Screen recording didn't start: \(err.localizedDescription)", .bad)
            }
        }
        take = t
        started = Date()
        isRecording = true
        note = ""
        log.info("recording: started (\(s.summary, privacy: .public))")
    }

    func stop() async {
        guard isRecording, let t = take, !busy else { return }
        busy = true
        defer { busy = false }
        isRecording = false
        take = nil
        started = nil
        await stopStreams(t)
        let files = await t.finish()
        guard !files.isEmpty else { return show("Nothing was recorded.", .bad) }
        let videos = files.filter { $0.pathExtension == "mp4" }
        if videos.isEmpty, settings.screen || settings.camera {
            return show("The video didn't record; the sound is saved in RemoteFM1 › audio › Recordings.", .bad)
        }
        if settings.copyToPhotos, !videos.isEmpty {
            let moved = await Self.toPhotos(videos, video: true)
            let kept = files.count - moved
            show(moved == videos.count && kept == 0 ? "Saved to Photos." :
                 moved > 0 ? "Video saved to Photos; the sound is in RemoteFM1 › audio › Recordings." :
                 "Photos didn't take it: saved in RemoteFM1 › Recordings.", moved > 0 ? .ok : .bad)
        } else {
            show(videos.isEmpty ? "Saved in RemoteFM1 › audio › Recordings." : "Saved in RemoteFM1 › Recordings.", .ok)
        }
    }

    private func stopStreams(_ t: Take) async {
        player.setOutputTap(nil)
        if t.screen != nil, RPScreenRecorder.shared().isRecording {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                RPScreenRecorder.shared().stopCapture { _ in c.resume() }
            }
        }
        if let cam = t.cameraSource { await cam.stop(on: t.q) }
        cameraSession = nil
    }

    // MARK: screenshots

    /// the whole screen (the sheet closed first by the caller), or the firmware's own 240x240 screen
    func screenshot() async {
        let png: Data?
        switch settings.screenshot {
        case .raw:
            png = feed.screen.image.flatMap { UIImage(cgImage: $0).pngData() }
        case .screen:
            guard let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
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
        let url = RecordingFiles.newFile(RecordingFiles.videos(), name, "png")
        do { try png.write(to: url) } catch { return show("Couldn't save the screenshot: \(error.localizedDescription)", .bad) }
        if settings.copyToPhotos {
            show(await Self.toPhotos([url], video: false) == 1 ? "Screenshot saved to Photos." :
                 "Photos didn't take it: saved in RemoteFM1 › Recordings.", .ok)
        } else {
            show("Screenshot saved in RemoteFM1 › Recordings.", .ok)
        }
    }

    // MARK: permissions and Photos

    private static func cameraAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
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
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: video ? .video : .photo, fileURL: u, options: nil)
                }
                try? FileManager.default.removeItem(at: u)
                n += 1
            } catch {
                RFMShared.log("recording").error("photos: \(error.localizedDescription, privacy: .public)")
            }
        }
        return n
    }

    private func show(_ text: String, _ tone: ToastCenter.Tone) {
        note = text
        feed.toast.show(text, tone)
        log.info("recording: \(text, privacy: .public)")
    }
}

// MARK: - one take, written on its queue

/// one recording's files and streams; everything after start runs on `q`
final class Take: @unchecked Sendable {
    let q = DispatchQueue(label: "com.quixotic7.remotefm1.recording", qos: .userInitiated)
    let rate: Double
    var screen: Movie?
    var camera: Movie?
    var cameraSource: CameraSource?
    private var wav: AVAudioFile?                      // (written on the tap's thread: under lock)
    private var wavURL: URL?
    private let lock = NSLock()
    /// ReplayKit's frames: moved to the host clock when theirs is another
    private var screenShift: CMTime?

    init(rate: Double) { self.rate = rate > 0 ? rate : 48000 }

    var wantsSound: Bool { wavURL != nil || screen?.sound == true || camera?.sound == true }

    /// the WAV: made at the first buffer, at its rate and channels (24-bit)
    func openWAV(_ url: URL, backup: Bool = false) throws {
        try Data().write(to: url)                       // (the name taken now)
        wavURL = url
        wavBackup = backup
    }
    /// the WAV only keeps the sound in case no video is saved
    private var wavBackup = false

    private func wavFile(for f: AVAudioFormat) -> AVAudioFile? {
        if let w = wav { return w }
        guard let u = wavURL, !wavFailed else { return nil }
        let set: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: f.sampleRate,
                                  AVNumberOfChannelsKey: f.channelCount, AVLinearPCMBitDepthKey: 24,
                                  AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        do {
            wav = try AVAudioFile(forWriting: u, settings: set, commonFormat: f.commonFormat, interleaved: f.isInterleaved)
        } catch {
            wavFailed = true
            RFMShared.log("recording").error("wav: \(error.localizedDescription, privacy: .public)")
        }
        return wav
    }
    private var wavFailed = false

    /// the player's output tap: each buffer to the WAV (here, on the tap's thread) and to the videos (on q)
    func soundTap() -> CorePlayer.OutputTap {
        { [self] b, t in
            lock.withLock {
                if wavURL != nil, let w = wavFile(for: b.format), b.format == w.processingFormat {
                    try? w.write(from: b)
                }
            }
            guard screen?.sound == true || camera?.sound == true else { return }
            let pts = t.isHostTimeValid ? CMClockMakeHostTimeFromSystemUnits(t.hostTime) : CMClockGetTime(CMClockGetHostTimeClock())
            guard let sb = Self.sampleBuffer(b, pts) else { return }
            q.async { [self] in
                screen?.appendAudio(sb)
                camera?.appendAudio(sb)
            }
        }
    }

    func cameraFrame() -> (CMSampleBuffer) -> Void {
        { [self] sb in camera?.appendVideo(sb) }       // (already on q: the output's queue)
    }

    func screenFrame() -> (CMSampleBuffer, RPSampleBufferType, Error?) -> Void {
        { [self] sb, type, _ in
            guard type == .video, CMSampleBufferDataIsReady(sb) else { return }
            q.async { [self] in
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                if screenShift == nil {             // (host time already: no shift; else the arrival time)
                    let now = CMClockGetTime(CMClockGetHostTimeClock())
                    let off = CMTimeSubtract(now, pts)
                    screenShift = abs(CMTimeGetSeconds(off)) > 1 ? off : .zero
                    screen?.orientation = Self.orientation(sb)
                }
                guard let shift = screenShift else { return }
                screen?.appendVideo(shift == .zero ? sb : Self.retimed(sb, by: shift) ?? sb)
            }
        }
    }

    /// the files written
    func finish() async -> [URL] {
        await withCheckedContinuation { c in q.async { c.resume() } }      // (frames still queued go in first)
        var out: [URL] = []
        var sound: URL?
        if let u = wavURL {
            let wrote = lock.withLock { () -> Bool in
                let w = wav != nil
                wav = nil                               // (closes the file)
                wavURL = nil
                return w
            }
            if wrote { sound = u } else { try? FileManager.default.removeItem(at: u) }
        }
        for m in [screen, camera].compactMap({ $0 }) {
            if let u = await m.finish() { out.append(u) }
        }
        if let u = sound {
            if wavBackup && !out.isEmpty { try? FileManager.default.removeItem(at: u) } else { out.append(u) }
        }
        return out
    }

    func discard() {
        lock.withLock { wav = nil }
        defer { wavURL = nil }
        if let u = wavURL { try? FileManager.default.removeItem(at: u) }
        for m in [screen, camera].compactMap({ $0 }) { m.cancel() }
    }

    // MARK: buffers

    static func sampleBuffer(_ b: AVAudioPCMBuffer, _ pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(b.format.sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: b.format.formatDescription, sampleCount: CMItemCount(b.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: b.audioBufferList) == noErr else { return nil }
        return sb
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

    /// ReplayKit's frame orientation as a rotation for the video
    static func orientation(_ sb: CMSampleBuffer) -> CGAffineTransform {
        let n = CMGetAttachment(sb, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber
        switch n.flatMap({ CGImagePropertyOrientation(rawValue: $0.uint32Value) }) {
        case .right?: return CGAffineTransform(rotationAngle: .pi / 2)
        case .left?: return CGAffineTransform(rotationAngle: -.pi / 2)
        case .down?: return CGAffineTransform(rotationAngle: .pi)
        default: return .identity
        }
    }
}

// MARK: - a video file

/// an MP4 (H.264, AAC): started at its first frame; sound before that left out
final class Movie: @unchecked Sendable {
    let url: URL
    let sound: Bool
    var orientation: CGAffineTransform
    private let writer: AVAssetWriter
    private let rate: Double
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var start: CMTime?

    init(_ url: URL, sound: Bool, rate: Double, transform: CGAffineTransform = .identity) throws {
        self.url = url
        self.sound = sound
        self.rate = rate
        orientation = transform
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    }

    func appendVideo(_ sb: CMSampleBuffer) {
        if video == nil, !begin(sb) { return }
        guard writer.status == .writing, let v = video, v.isReadyForMoreMediaData else { return }
        v.append(sb)
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        guard let s = start, let a = audio, writer.status == .writing, a.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sb) >= s else { return }
        a.append(sb)
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
        if sound {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) { writer.add(a); audio = a }
        }
        guard writer.startWriting() else { return false }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        writer.startSession(atSourceTime: pts)
        start = pts
        return true
    }

    /// the file, or nil (no frame came, or it failed: removed)
    func finish() async -> URL? {
        guard start != nil, writer.status == .writing else { cancel(); return nil }
        video?.markAsFinished()
        audio?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .completed { return url }
        RFMShared.log("recording").error("video: \(self.writer.error?.localizedDescription ?? "failed", privacy: .public)")
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - the camera

/// the front or rear camera at a zoom, no microphone; frames to the take's queue
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let device: AVCaptureDevice
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
        device = d
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
        // (the session's clock to the host clock, which the sound uses)
        guard let clock = session.synchronizationClock else { deliver?(sb); return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        if CMTimeCompare(host, pts) == 0 { deliver?(sb); return }
        if let r = Take.retimed(sb, by: CMTimeSubtract(host, pts)) { deliver?(r) }
    }
}

enum RecordingError: LocalizedError {
    case noCamera
    var errorDescription: String? { "no camera to record with" }
}
