// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The core test (M3, -coretest): the app's real path with the fake unit. It waits for the fake's session, boots the
// firmware (-core <id>, default the app's) in Core mode with the sound on, lets the fake's demo input play (FIZZ:
// PLAY on the fake unit first, its keys being steps), taps the main mixer for 3 s, saves the flash, powers the
// firmware off and on again, and writes coretest.json to Documents (scripts/sim_coretest.sh reads it). The screen stays as the user would see it, for the screenshot.

import AVFoundation
import Foundation
import RFMCore
import RFMKit
import UIKit

struct CoreTestSummary: Codable, Sendable {
    struct Step: Codable, Sendable {
        var name: String
        var ok: Bool?
        var detail: String
    }
    var done = false
    var device = "", system = ""
    var simulator = false
    var core = "", name = "", version = "", license = ""
    var slot = 0, slots = 0
    var steps: [Step] = []
    var sampleRate = 0.0, ioBufferMs = 0.0
    var renderFrames = 0, renders: UInt64 = 0, renderAvgUs = 0, renderMaxUs = 0, renderLoadPct = 0.0
    var coreCpuPct: Int?, coreShed: Int?
    var tapSeconds = 0.0, tapFrames = 0, outputRMS = 0.0, outputPeak = 0.0
    var lcdChanged = false, lcdWritesAtBoot = 0, lcdWritesAtEnd = 0, previewChanges = 0
    var keysPressed = 0, fakeFramesBefore = 0, fakeFramesAfter = 0, fakeHeldFrames = 0
    var flashFile = "", flashBytes = 0, flashSaves = 0
    var footprintBefore: Int64 = 0, footprintAfterBoot: Int64 = 0, footprintDelta: Int64 = 0
    var powerCycleSlot = 0, retiredSlots = 0
}

/// sums the tap's buffers (the tap runs on its own thread)
final class TapMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sum = 0.0, peak: Float = 0, frames = 0, samples = 0

    func add(_ b: AVAudioPCMBuffer) {
        guard let ch = b.floatChannelData else { return }
        let n = Int(b.frameLength), c = Int(b.format.channelCount)
        var s = 0.0, p: Float = 0
        for i in 0..<c {
            for k in 0..<n {
                let v = ch[i][k]
                s += Double(v * v)
                p = max(p, abs(v))
            }
        }
        lock.lock()
        sum += s
        peak = max(peak, p)
        frames += n
        samples += n * c
        lock.unlock()
    }

    func reset() {
        lock.lock()
        sum = 0
        peak = 0
        frames = 0
        samples = 0
        lock.unlock()
    }

    var result: (rms: Double, peak: Double, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (samples > 0 ? (sum / Double(samples)).squareRoot() : 0, Double(peak), frames)
    }
}

@MainActor
final class CoreTest {
    let controller: RemoteController
    let player: CorePlayer
    private var s = CoreTestSummary()
    private let log = RFMShared.log("coretest")

    init(controller: RemoteController, player: CorePlayer) {
        self.controller = controller
        self.player = player
    }

    func run() async {
        let dev = UIDevice.current
        s.device = dev.model + " " + dev.name
        s.system = dev.systemName + " " + dev.systemVersion
        #if targetEnvironment(simulator)
        s.simulator = true
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("coretest.json"))
        // a fresh flash for the test's firmware (its file is written again below)
        try? FileManager.default.removeItem(at: player.flashURL(player.selected))

        // 1: the fake unit's session
        if !controller.isRunning { controller.start() }
        var waited = 0
        while !controller.state.isConnected && waited < 100 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        step("fake unit connected", controller.state.isConnected, "\(controller.statusText) after \(waited * 100) ms")
        let f0 = controller.fakeUnit()

        // 2: the core, booted, in Core mode with sound
        player.setAudio(true)
        player.setMode(.core)
        player.refresh()
        let info = player.current
        s.core = player.selected
        s.name = info?.name ?? ""
        s.version = info?.version ?? ""
        s.license = info?.license ?? ""
        s.slots = info?.slots ?? 0
        s.slot = player.status.slot
        s.footprintBefore = player.footprintBefore
        s.footprintAfterBoot = player.footprintAfter
        s.footprintDelta = player.footprintAfter - player.footprintBefore
        step("core booted", player.status.booted, "\(s.name) \(s.version) in slot \(s.slot) of \(s.slots); "
             + "footprint +\(s.footprintDelta / 1024) KiB; \(player.message)")
        step("audio running", player.audioRunning, player.audioText)
        let session = AVAudioSession.sharedInstance()
        s.ioBufferMs = session.ioBufferDuration * 1000

        // (FIZZ: the fake's keys are steps, silent; PLAY on the fake unit starts its demo pattern)
        if let label = Self.startButton[player.selected] {
            let id = player.withPanelEngine { rfme_matrix_button($0, label) }
            controller.fakeButton(Int(id), down: true)
            try? await Task.sleep(for: .milliseconds(80))
            controller.fakeButton(Int(id), down: false)
            step("start button", id >= 0, "button \(label) (btn_id \(id)) tapped on the fake unit")
        }

        // 3: let it play; the tap on the main mixer for 3 s
        try? await Task.sleep(for: .milliseconds(500))
        player.refresh()
        s.lcdWritesAtBoot = Int(player.status.lcdWrites)
        let firstPreview = Self.hash(player.preview)
        var lastPreview = firstPreview
        player.resetRenderStats()
        let meter = TapMeter()
        if let mixer = player.mixer {
            s.sampleRate = mixer.outputFormat(forBus: 0).sampleRate
            mixer.installTap(onBus: 0, bufferSize: 4096, format: nil, block: Self.tap(meter))
            let t0 = Date()
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                player.refresh()
                let h = Self.hash(player.preview)
                if h != lastPreview { s.previewChanges += 1; lastPreview = h }
            }
            mixer.removeTap(onBus: 0)
            s.tapSeconds = Date().timeIntervalSince(t0)
        }
        let m = meter.result
        s.tapFrames = m.frames
        s.outputRMS = m.rms
        s.outputPeak = m.peak
        let st = player.status
        s.renders = st.renders
        s.renderFrames = Int(st.renderLastFrames)
        s.renderAvgUs = Int(st.renderAvgUs)
        s.renderMaxUs = Int(st.renderMaxUs)
        s.renderLoadPct = st.renderLoad * 100
        s.coreCpuPct = st.haveStats ? Int(st.cpuPct) : nil
        s.coreShed = st.haveStats ? Int(st.shed) : nil
        s.keysPressed = Int(st.keysPressed)
        s.lcdWritesAtEnd = Int(st.lcdWrites)
        s.lcdChanged = s.lcdWritesAtEnd > s.lcdWritesAtBoot && lastPreview != firstPreview
        step("sound", m.rms > 1e-4, String(format: "tap %.1f s, %d frames at %.0f Hz, rms %.4f, peak %.3f; %d keys "
                                           + "from the fake", s.tapSeconds, m.frames, s.sampleRate, m.rms, m.peak,
                                           s.keysPressed))
        step("render callback", st.renders > 0, String(format: "%llu renders of %u frames, avg %u us, max %u us (%.1f%% "
                                                       + "of the buffer)", st.renders, st.renderLastFrames,
                                                       st.renderAvgUs, st.renderMaxUs, s.renderLoadPct))
        step("LCD changed", s.lcdChanged, "lcd_writes \(s.lcdWritesAtBoot) -> \(s.lcdWritesAtEnd), "
             + "\(s.previewChanges) preview changes")
        let f1 = controller.fakeUnit()
        s.fakeFramesBefore = Int(f0?.frames ?? 0)
        s.fakeFramesAfter = Int(f1?.frames ?? 0)
        s.fakeHeldFrames = Int(f1?.heldFrames ?? 0)
        step("frames to the fake unit", s.fakeFramesAfter > s.fakeFramesBefore,
             "\(s.fakeFramesBefore) -> \(s.fakeFramesAfter) (held \(s.fakeHeldFrames))")

        // 4: the flash, saved now (flash_sync on the clock)
        let saved = await player.saveNow()
        let url = player.flashURL(player.selected)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        s.flashFile = "Documents/cores/" + url.lastPathComponent
        s.flashBytes = size ?? 0
        s.flashSaves = player.saves
        step("flash file written", saved && s.flashBytes == Int(info?.flashSize ?? 0),
             "\(s.flashFile), \(s.flashBytes) bytes, \(player.saves) saves")

        // 5: a power cycle (as after the firmware's own reboot): the slot reloaded, booted from the flash
        player.powerCycle()
        try? await Task.sleep(for: .milliseconds(500))
        player.refresh()
        s.powerCycleSlot = player.status.slot
        s.retiredSlots = player.current?.retired ?? -1
        step("power cycle", player.status.booted && !player.status.halted && player.status.devMs > 100,
             "slot \(s.slot) -> \(s.powerCycleSlot), retired \(s.retiredSlots), device \(player.status.devMs) ms; "
                + player.message)

        s.done = true
        do {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try e.encode(s)
            try data.write(to: docs.appendingPathComponent("coretest.json"), options: .atomic)
            log.info("coretest: \(String(decoding: data, as: UTF8.self), privacy: .public)")
        } catch {
            log.error("coretest: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// a button tapped before listening, by label (RFME_B_*), for a core whose keys alone don't sound
    static let startButton: [String: Int32] = ["fizz": Int32(RFME_B_PLAY)]

    private func step(_ name: String, _ ok: Bool?, _ detail: String) {
        s.steps.append(.init(name: name, ok: ok, detail: detail))
        log.info("coretest \(name, privacy: .public): \(ok.map { $0 ? "ok" : "FAILED" } ?? "-", privacy: .public) \(detail, privacy: .public)")
    }

    /// the tap's block, made outside the main actor (it runs on AVFAudio's queue)
    nonisolated static func tap(_ m: TapMeter) -> AVAudioNodeTapBlock { { b, _ in m.add(b) } }

    static func hash(_ img: CGImage?) -> Int {
        guard let d = img?.dataProvider?.data as Data? else { return 0 }
        return d.hashValue
    }
}
