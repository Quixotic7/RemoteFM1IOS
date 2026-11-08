// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// A take's sound mixed into its video (the owner, 2026-11-07: the camera's video with the app's sound and the
// microphone's, both also kept as WAVs). During the take the picture is written alone (its timeline from 0) and each
// sound to its own WAV; at the end this writes the MP4: the picture copied as it is (no new encode, so it's quick) and
// the sounds summed, each placed at its own start (offset from the first frame), as AAC.

import AVFoundation
import CoreMedia

public enum RecordingMux {
    /// a sound for the video: a WAV and when it began, in seconds after the picture's first frame (negative: before it)
    public struct Stem: Sendable {
        public var url: URL
        public var offset: Double
        public init(_ url: URL, offset: Double) {
            self.url = url
            self.offset = offset
        }
    }

    public enum MuxError: LocalizedError {
        case noPicture, failed(String)
        public var errorDescription: String? {
            switch self {
            case .noPicture: "the video has no picture"
            case .failed(let s): s
            }
        }
    }

    /// `video` (picture only) and `stems` into `out`: the picture as it is, the stems summed (stereo, at the first stem's
    /// rate), as long as the picture
    public static func mux(video: URL, stems: [Stem], to out: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MuxError.noPicture }
        let duration = try await asset.load(.duration)
        let transform = try await track.load(.preferredTransform)
        let hint = try await track.load(.formatDescriptions).first

        let reader = try AVAssetReader(asset: asset)
        let pictures = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        pictures.alwaysCopiesSampleData = false
        reader.add(pictures)

        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        vin.transform = transform
        vin.expectsMediaDataInRealTime = false
        writer.add(vin)

        let rate = stems.lazy.compactMap { try? AVAudioFile(forReading: $0.url).fileFormat.sampleRate }.first ?? 48000
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw MuxError.failed("format") }
        let sources = stems.compactMap { try? StemReader($0, rate: rate) }
        let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
        ain.expectsMediaDataInRealTime = false
        let sound = !sources.isEmpty
        if sound { writer.add(ain) }

        guard reader.startReading() else { throw MuxError.failed(reader.error?.localizedDescription ?? "reading") }
        guard writer.startWriting() else { throw MuxError.failed(writer.error?.localizedDescription ?? "writing") }
        writer.startSession(atSourceTime: .zero)

        let total = AVAudioFramePosition(max(0, duration.seconds) * rate)
        var pos: AVAudioFramePosition = 0
        var pictureDone = false, soundDone = !sound
        while !(pictureDone && soundDone) {
            var moved = false
            if !pictureDone, vin.isReadyForMoreMediaData {
                if let sb = pictures.copyNextSampleBuffer() { vin.append(sb) } else { vin.markAsFinished(); pictureDone = true }
                moved = true
            }
            if !soundDone, ain.isReadyForMoreMediaData {
                let n = AVAudioFrameCount(min(4096, total - pos))
                if n == 0 {
                    ain.markAsFinished()
                    soundDone = true
                } else if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) {
                    buf.frameLength = n
                    let ch = buf.floatChannelData!
                    for c in 0..<2 { ch[c].update(repeating: 0, count: Int(n)) }
                    for s in sources { s.add(into: buf, at: pos) }
                    for c in 0..<2 { for i in 0..<Int(n) { ch[c][i] = max(-1, min(1, ch[c][i])) } }
                    if let sb = sampleBuffer(buf, CMTime(value: pos, timescale: CMTimeScale(rate))) { ain.append(sb) }
                    pos += AVAudioFramePosition(n)
                }
                moved = true
            }
            if writer.status == .failed || reader.status == .failed { break }
            if !moved { try await Task.sleep(for: .milliseconds(2)) }
        }
        if writer.status == .failed || reader.status == .failed {
            writer.cancelWriting()
            throw MuxError.failed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw MuxError.failed(writer.error?.localizedDescription ?? "failed") }
    }

    /// PCM as a sample buffer (the data copied)
    public static func sampleBuffer(_ b: AVAudioPCMBuffer, _ pts: CMTime) -> CMSampleBuffer? {
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
}

/// one WAV read in order at the mix's rate (its own channels; a mono one goes to both sides), placed at its offset
final class StemReader: @unchecked Sendable {
    private let file: AVAudioFile
    private let mid: AVAudioFormat
    private let converter: AVAudioConverter?
    private var eof = false
    /// the mix's frame where this stem's next frame goes
    private var cursor: AVAudioFramePosition

    init(_ stem: RecordingMux.Stem, rate: Double) throws {
        file = try AVAudioFile(forReading: stem.url)
        let src = file.processingFormat
        guard let m = AVAudioFormat(standardFormatWithSampleRate: rate, channels: src.channelCount) else {
            throw RecordingMux.MuxError.failed("stem format")
        }
        mid = m
        converter = src.sampleRate == rate ? nil : AVAudioConverter(from: src, to: m)
        let off = AVAudioFramePosition((stem.offset * rate).rounded())
        cursor = off
        if off < 0 {                                    // (began before the picture: its start left out)
            var skip = -off
            while skip > 0, let b = read(AVAudioFrameCount(min(skip, 4096))) { skip -= AVAudioFramePosition(b.frameLength) }
            cursor = 0
        }
    }

    /// this stem's frames for the mix's [pos, pos + buf.frameLength) added into buf
    func add(into buf: AVAudioPCMBuffer, at pos: AVAudioFramePosition) {
        let end = pos + AVAudioFramePosition(buf.frameLength)
        guard !eof || cursor < end, cursor < end else { return }
        let start = max(pos, cursor)
        guard let b = read(AVAudioFrameCount(end - start)) else { return }
        let dst = buf.floatChannelData!, src = b.floatChannelData!
        let at = Int(start - pos), n = Int(b.frameLength), chans = Int(b.format.channelCount)
        for c in 0..<2 {
            let s = src[min(c, chans - 1)]
            for i in 0..<n { dst[c][at + i] += s[i] }
        }
        cursor = start + AVAudioFramePosition(n)
    }

    private func read(_ n: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard !eof, n > 0, let out = AVAudioPCMBuffer(pcmFormat: mid, frameCapacity: n) else { return nil }
        if let converter {
            var err: NSError?
            _ = converter.convert(to: out, error: &err) { [self] want, status in
                guard !eof, let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: want) else {
                    status.pointee = .endOfStream
                    return nil
                }
                try? file.read(into: b, frameCount: want)
                if b.frameLength == 0 { eof = true; status.pointee = .endOfStream; return nil }
                status.pointee = .haveData
                return b
            }
        } else {
            try? file.read(into: out, frameCount: n)
            if out.frameLength == 0 { eof = true }
        }
        return out.frameLength > 0 ? out : nil
    }
}
