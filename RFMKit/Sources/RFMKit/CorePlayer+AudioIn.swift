// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// ain1 in the standalone app (RemoteFM1 web/engine/API.md section 6; the owner, 2026-11-02): a firmware whose
// manifest wants or needs audio input gets the phone's mic or an audio interface, the user's pick, once they turn it on
// (the microphone permission asked then, never before). On and the input chosen are kept per firmware. The input comes
// through an AVAudioSinkNode on the engine's input (small real-time buffers; resampled to 44.1 kHz in the engine:
// rfme_ain_push_f32) into the engine's ring, which the core reads before each audio block. The round trip it reports
// to the firmware: the session's output and input latencies, two IO buffers, the ring's level and the render-ahead
// headroom. The cart monitors its input itself; the app plays nothing of it.

#if os(iOS)
import AVFoundation
import Foundation
import RFMCore

let ainLog = RFMShared.log("audioin")

public enum AudioInput {
    static func key(_ id: String) -> String { "ain.on.\(id)" }
    static func portKey(_ id: String) -> String { "ain.port.\(id)" }

    public static func isOn(for firmwareID: String, _ d: UserDefaults = .standard) -> Bool { d.bool(forKey: key(firmwareID)) }
    public static func preferredUID(for firmwareID: String, _ d: UserDefaults = .standard) -> String? {
        d.string(forKey: portKey(firmwareID))
    }
    static func set(_ on: Bool, port: String?, for firmwareID: String, _ d: UserDefaults = .standard) {
        d.set(on, forKey: key(firmwareID))
        if let port { d.set(port, forKey: portKey(firmwareID)) }
    }

    /// the microphone permission as it stands (never asks)
    public static var granted: Bool { AVAudioApplication.shared.recordPermission == .granted }
    public static var denied: Bool { AVAudioApplication.shared.recordPermission == .denied }

    /// the ring's level at 44.1 kHz: its own share of the round trip
    static let ringFrames: UInt32 = 512
}

extension CorePlayer {
    /// the running firmware takes audio input, and it is on for it (with the permission)
    var inputWanted: Bool {
        guard let c = current, c.audioIn > 0 else { return false }
        return AudioInput.isOn(for: c.firmwareID) && AudioInput.granted
    }

    /// the inputs the session offers now (the phone's mic, a headset, a USB interface ...)
    public var audioInputs: [(uid: String, name: String)] {
        (AVAudioSession.sharedInstance().availableInputs ?? []).map { ($0.uid, $0.portName) }
    }

    /// the input in use now
    public var currentInputName: String? { AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName }

    /// turns the running firmware's input on or off (asking for the microphone first, on); the input picked kept with
    /// it. Returns why it couldn't, nil: done
    public func setAudioInput(_ on: Bool, port: String? = nil) async -> String? {
        guard let c = current, c.audioIn > 0 else { return "This firmware takes no audio input." }
        if on {
            if !AudioInput.granted {
                let ok = await AVAudioApplication.requestRecordPermission()
                if !ok { return "RemoteFM1 may not use the microphone. Allow it in Settings › Privacy & Security › Microphone." }
            }
        }
        AudioInput.set(on, port: port, for: c.firmwareID)
        ainLog.info("input \(on ? "on" : "off", privacy: .public) for \(c.firmwareID, privacy: .public), mode \(String(describing: self.mode), privacy: .public), audioOn \(self.audioOn)")
        restartAudioForInput()
        return nil
    }

    /// the engine made again when the input it should have differs from what it has (on, off, another firmware)
    func restartAudioForInput() {
        guard mode == .core, audioOn else { return }
        if inputWanted == inputLive, !inputWanted || AudioInput.preferredUID(for: current?.firmwareID ?? "") == inputPortInUse {
            return
        }
        rfme_set_clock(e, Int32(RFME_CLOCK_TIMER))
        stopAudio()
        applyClock()
    }

    /// the sink's block runs on the audio input's real-time thread: nothing of the main actor's in it
    nonisolated static func inputSink(core: OpaquePointer, rate: Double, stereo: Bool) -> AVAudioSinkNode {
        nonisolated(unsafe) let core = core
        return AVAudioSinkNode { @Sendable _, frames, abl -> OSStatus in
            let l = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard l.count > 0, let p0 = l[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let p1 = stereo && l.count > 1 ? l[1].mData?.assumingMemoryBound(to: Float.self) : nil
            rfme_ain_push_f32(core, p0, p1, frames, rate)
            return noErr
        }
    }

    /// (startAudio, before the engine starts) the input node into a sink that feeds the engine's ring
    func attachInput(_ eng: AVAudioEngine) {
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        ainLog.info("input format \(fmt.sampleRate) Hz, \(fmt.channelCount) ch")
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return }
        let sink = Self.inputSink(core: e, rate: fmt.sampleRate, stereo: fmt.channelCount > 1)
        eng.attach(sink)
        eng.connect(input, to: sink, format: fmt)
        let s = AVAudioSession.sharedInstance()
        let trip = (s.inputLatency + s.outputLatency + 2 * s.ioBufferDuration + Double(headroomUs) / 1e6) * 44100
        rfme_ain_set(e, 1, UInt32(max(0, trip)) + AudioInput.ringFrames, AudioInput.ringFrames)
        inputLive = true
        inputPortInUse = s.currentRoute.inputs.first?.uid
    }
}
#endif
