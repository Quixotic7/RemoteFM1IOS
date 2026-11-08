// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// A take's sounds mixed into its video (RecordingMux): the picture kept, one sound track, each stem at its offset.

import AVFoundation
import CoreVideo
import XCTest
@testable import RFMKit

final class RecordingMuxTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfm-mux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// the app's sound (stereo, 48 kHz, from the start) and the microphone (mono, 44.1 kHz, from 0.5 s): both heard,
    /// the second only after its offset; the picture's frames all there
    func testStemsMixedAtTheirOffsets() async throws {
        let video = dir.appendingPathComponent("picture.mp4")
        try await Self.writePicture(video, frames: 30, fps: 30)
        let app = dir.appendingPathComponent("app.wav"), mic = dir.appendingPathComponent("mic.wav")
        try Self.writeSine(app, rate: 48000, channels: 2, seconds: 1.0, hz: 440, level: 0.25)
        try Self.writeSine(mic, rate: 44100, channels: 1, seconds: 0.5, hz: 660, level: 0.25)
        let out = dir.appendingPathComponent("take.mp4")
        try await RecordingMux.mux(video: video, stems: [.init(app, offset: 0), .init(mic, offset: 0.5)], to: out)

        let asset = AVURLAsset(url: out)
        let v = try await asset.loadTracks(withMediaType: .video)
        let a = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(v.count, 1, "the picture")
        XCTAssertEqual(a.count, 1, "one sound track: the stems mixed")
        let d = try await asset.load(.duration).seconds
        XCTAssertEqual(d, 1.0, accuracy: 0.1)

        let pcm = try await Self.decode(out)
        let rate = 48000.0
        func peak(_ from: Double, _ to: Double) -> Float {
            let s = Int(from * rate), e = min(pcm.count, Int(to * rate))
            return s < e ? pcm[s..<e].map(abs).max() ?? 0 : 0
        }
        let before = peak(0.1, 0.4), after = peak(0.6, 0.9)
        XCTAssertEqual(before, 0.25, accuracy: 0.06, "the app's sound alone first")
        XCTAssertGreaterThan(after, before * 1.4, "the microphone joins at 0.5 s")
    }

    /// a stem that began before the picture: its start left out, the rest in place
    func testStemBeforeThePicture() async throws {
        let video = dir.appendingPathComponent("picture.mp4")
        try await Self.writePicture(video, frames: 15, fps: 30)
        let app = dir.appendingPathComponent("app.wav")
        try Self.writeSine(app, rate: 48000, channels: 2, seconds: 0.25, hz: 440, level: 0.5)
        let out = dir.appendingPathComponent("take.mp4")
        try await RecordingMux.mux(video: video, stems: [.init(app, offset: -0.2)], to: out)
        let pcm = try await Self.decode(out)
        let early = pcm.prefix(Int(0.04 * 48000)).map(abs).max() ?? 0
        let late = pcm.dropFirst(Int(0.1 * 48000)).prefix(Int(0.3 * 48000)).map(abs).max() ?? 0
        XCTAssertGreaterThan(early, 0.3, "0.2 s of it before the first frame left out: it plays from the start")
        XCTAssertLessThan(late, 0.05, "and it ends 0.05 s in")
    }

    // MARK: helpers

    static func writePicture(_ url: URL, frames: Int, fps: Int32) async throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64])
        w.add(input)
        XCTAssertTrue(w.startWriting())
        w.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            memset(CVPixelBufferGetBaseAddress(buf), Int32(i * 8), CVPixelBufferGetDataSize(buf))
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await w.finishWriting()
        XCTAssertEqual(w.status, .completed)
    }

    static func writeSine(_ url: URL, rate: Double, channels: AVAudioChannelCount, seconds: Double, hz: Double, level: Float) throws {
        let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24,
                                                            AVLinearPCMIsFloatKey: false],
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(seconds * rate)
        let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n))
        b.frameLength = n
        for c in 0..<Int(channels) {
            for i in 0..<Int(n) { b.floatChannelData![c][i] = level * Float(sin(2 * .pi * hz * Double(i) / rate)) }
        }
        try f.write(from: b)
    }

    /// the left channel, as floats at 48 kHz
    static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let t = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .audio).first)
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
        r.add(o)
        r.startReading()
        var out: [Float] = []
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var p: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &p)
            guard let p else { continue }
            p.withMemoryRebound(to: Float.self, capacity: len / 4) { f in
                for i in stride(from: 0, to: len / 4, by: 2) { out.append(f[i]) }
            }
        }
        return out
    }
}

func XCTUnwrapAsync<T>(_ v: T?) async throws -> T { try XCTUnwrap(v) }
