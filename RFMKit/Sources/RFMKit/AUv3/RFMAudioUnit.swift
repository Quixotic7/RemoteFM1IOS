// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The AUv3 instrument (M2: no core yet). One stereo output bus, MIDI in, a render kernel in C++ (RFMCore's
// RFMKernel) that writes silence and counts renders and MIDI. Its fullState carries the instance UUID and a format
// version (InstanceState). A message channel (RFMShared.diagnosticsChannel) gives a host the probe report, which
// out-of-process hosts can't get from a custom property.
//
// It lives in RFMKit, not in the extension, so the Mac tests can create and render it directly.

import AVFoundation
import AudioToolbox
import Foundation
import RFMCore

public final class RFMAudioUnit: AUAudioUnit, @unchecked Sendable {
    private let kernel: OpaquePointer
    private let outBus: AUAudioUnitBus
    private var outputs: AUAudioUnitBusArray!
    private var inputs: AUAudioUnitBusArray!
    private let lock = NSLock()
    private var instanceState = InstanceState()
    private let log = RFMShared.log("au")
    private var channel: DiagnosticsChannel?

    public let probe: Probe
    /// Called (on any thread) when the instance's identity changed (a restored state) or a host asked for the
    /// Bluetooth panel. The extension's view controller sets it.
    public nonisolated(unsafe) var onEvent: (@Sendable (Event) -> Void)?
    public enum Event: Sendable { case stateRestored, bluetoothRequested }

    /// runProbes false: no CoreMIDI and no shared files (the Mac tests); the probe then writes only to a temp folder
    public init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = [],
                runProbes: Bool) throws {
        let k = rfmk_new()!
        kernel = k
        let ref = KernelRef(p: k)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rfm-au-\(UUID().uuidString)")
        probe = Probe(role: .ext, includeMIDI: runProbes, directory: runProbes ? nil : tmp) {
            var s = rfmk_stats_t()
            rfmk_stats(ref.p, &s)
            let last = Array(withUnsafeBytes(of: s.last_midi) { Array($0) }.prefix(Int(s.last_midi_len)))
            return (.init(started: s.thread_ok != 0, ticks: s.ticks),
                    .init(renders: s.renders, frames: s.frames, midiEvents: s.midi_events, lastMIDI: last,
                          sampleRate: s.sample_rate, maxFrames: s.max_frames))
        }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else {
            rfmk_free(k)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        outBus = try AUAudioUnitBus(format: fmt)
        outBus.maximumChannelCount = 2
        try super.init(componentDescription: componentDescription, options: options)
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [])
        maximumFramesToRender = 4096
        probe.setInstance(instanceState.instance.uuidString)
        log.info("instance \(self.instanceState.short, privacy: .public) created, pid \(getpid())")
        if runProbes {
            let p = probe
            // CoreMIDI delivers a client's notifications on the run loop it was created on: the main thread's
            DispatchQueue.main.async {
                p.start()
                p.ping()
                p.report()
            }
        }
    }

    public override convenience init(componentDescription: AudioComponentDescription,
                                     options: AudioComponentInstantiationOptions = []) throws {
        try self.init(componentDescription: componentDescription, options: options, runProbes: true)
    }

    deinit {
        rfmk_free(kernel)
    }

    public var state: InstanceState { lock.withLock { instanceState } }

    // MARK: AUAudioUnit

    public override var outputBusses: AUAudioUnitBusArray { outputs }
    public override var inputBusses: AUAudioUnitBusArray { inputs }
    public override var isMusicDeviceOrEffect: Bool { true }
    public override var virtualMIDICableCount: Int { 1 }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let f = outBus.format
        if rfmk_allocate(kernel, f.sampleRate, f.channelCount, maximumFramesToRender) == 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
    }

    public override func deallocateRenderResources() {
        rfmk_deallocate(kernel)
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock { rfmk_render_block(kernel) }

    public override var fullState: [String: Any]? {
        get {
            var s = super.fullState ?? [:]
            state.encode(into: &s)
            return s
        }
        set {
            // (not passed to super: AUAudioUnit's own setter only reads a v2 unit's "data", and logs "no data")
            guard let restored = InstanceState(newValue) else { return }
            lock.withLock { instanceState = restored }
            probe.setInstance(restored.instance.uuidString)
            log.info("instance \(restored.short, privacy: .public) restored from state, format \(restored.format)")
            onEvent?(.stateRestored)
        }
    }

    public override func messageChannel(for channelName: String) -> any AUMessageChannel {
        guard channelName == RFMShared.diagnosticsChannel else { return super.messageChannel(for: channelName) }
        return lock.withLock {
            if channel == nil { channel = DiagnosticsChannel(owner: self) }
            return channel!
        }
    }

    // MARK: for the Mac tests

    /// renders `frames` frames with no host, plus one MIDI message
    public func renderForTest(frames: Int, midi: [UInt8] = []) -> [[Float]] {
        var a = [Float](repeating: 1, count: frames), b = [Float](repeating: 1, count: frames)
        a.withUnsafeMutableBufferPointer { pa in
            b.withUnsafeMutableBufferPointer { pb in
                let bufs: [UnsafeMutablePointer<Float>?] = [pa.baseAddress, pb.baseAddress]
                bufs.withUnsafeBufferPointer { pp in
                    midi.withUnsafeBufferPointer { m in
                        rfmk_render_test(kernel, pp.baseAddress, 2, UInt32(frames), m.baseAddress, UInt32(m.count))
                    }
                }
            }
        }
        return [a, b]
    }
}

/// The host's way to the probes, through AUMessageChannel (plist types only). Messages, by "cmd":
///   "report"    → ["json": the probe report, "instance": the UUID, "pid": the extension's pid]
///   "ping"      → posts this process's Darwin ping again, then as "report"
///   "bluetooth" → asks the view controller to present the Bluetooth MIDI panel
final class DiagnosticsChannel: NSObject, AUMessageChannel, @unchecked Sendable {
    private weak var owner: RFMAudioUnit?
    /// set by an out-of-process host's side of the channel when it connects (not used yet; without it the
    /// extension dies with an unrecognized selector)
    var callHostBlock: CallHostBlock?

    init(owner: RFMAudioUnit) { self.owner = owner }

    func callAudioUnit(_ message: [AnyHashable: Any]) -> [AnyHashable: Any] {
        guard let au = owner else { return ["error": "gone"] }
        switch message["cmd"] as? String {
        case "bluetooth":
            au.onEvent?(.bluetoothRequested)
            return ["ok": true]
        case "ping":
            au.probe.ping()
            fallthrough
        default:
            let r = au.probe.report()
            return ["json": r.json(pretty: false), "instance": au.state.instance.uuidString, "pid": Int(getpid())]
        }
    }
}

private struct KernelRef: @unchecked Sendable { let p: OpaquePointer }
