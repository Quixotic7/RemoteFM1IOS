// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// M4 on the Mac: the AU playing a core (the macOS builds of scripts/build_cores.sh macos, as CoreTests; skipped
// without them). Host MIDI through the render block, fullState with the flash (ChoralRoot's saved tempo survives a
// restore into a new instance), a state without flash boots fresh, and a fifth ChoralRoot renders silence with the
// slot error. No panel link (Config.link .none): nothing touches CoreMIDI.

import AVFoundation
import AudioToolbox
import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class AUCoreTests: XCTestCase {
    override func setUpWithError() throws {
        guard FileManager.default.fileExists(atPath: CoreTests.coresDir) else {
            throw XCTSkip("no macOS core builds in \(CoreTests.coresDir): run scripts/build_cores.sh macos")
        }
    }

    private func makeAU(_ core: String? = "choralroot") throws -> RFMAudioUnit {
        var c = RFMAudioUnit.Config()
        c.runProbes = false
        c.link = .none
        c.defaultCore = core
        c.slotsDir = CoreTests.coresDir
        let au = try RFMAudioUnit(componentDescription: RFMShared.component, options: [], config: c)
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()
        addTeardownBlock { au.deallocateRenderResources() }
        return au
    }

    /// `ms` of device time through the kernel (44.1 kHz, 441-frame renders); the RMS
    @discardableResult
    private func render(_ au: RFMAudioUnit, ms: Int, midi: [UInt8] = []) -> Double {
        var sum = 0.0, n = 0
        for i in 0..<(ms / 10) {
            let out = au.renderForTest(frames: 441, midi: i == 0 ? midi : [])
            for ch in out { for v in ch { sum += Double(v * v) } }
            n += 2 * 441
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    func testHostMIDIPlaysTheCoreThroughTheRenderBlock() throws {
        let au = try makeAU()
        render(au, ms: 800)
        XCTAssertTrue(au.status().core.booted)
        // a note on, at frame 100 of a render through the real render block
        let block = au.internalRenderBlock
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer { abl.unsafeMutablePointer.deallocate() }
        var midi = AUMIDIEvent(next: nil, eventSampleTime: 100, eventType: .MIDI, reserved: 0, length: 3, cable: 0,
                               data: (0x90, 62, 110))   // D4: key 9
        var ev = AURenderEvent(MIDI: midi)
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mFlags = .sampleTimeValid
        var peak: Float = 0
        for i in 0..<100 {
            for c in 0..<2 { abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil) }
            flags = []
            let st = i == 0 ? block(&flags, &ts, 441, 0, abl.unsafeMutablePointer, &ev, nil)
                : block(&flags, &ts, 441, 0, abl.unsafeMutablePointer, nil, nil)
            XCTAssertEqual(st, noErr)
            XCTAssertFalse(flags.contains(.unitRenderAction_OutputIsSilence))
            let p = abl[0].mData!.assumingMemoryBound(to: Float.self)
            for k in 0..<441 { peak = max(peak, abs(p[k])) }
            ts.mSampleTime += 441
        }
        midi.data = (0x80, 62, 0)
        ev = AURenderEvent(MIDI: midi)
        _ = block(&flags, &ts, 441, 0, abl.unsafeMutablePointer, &ev, nil)
        let s = au.status()
        print("AU + choralroot: host note peak \(peak), MIDI in \(s.midiIn), notes \(s.midiNotes), render avg \(s.core.renderAvgUs) us")
        XCTAssertGreaterThan(peak, 0.002, "a host note is silent")
        XCTAssertEqual(s.midiNotes, 1)
        XCTAssertEqual(s.midiIn, 2)
        XCTAssertEqual(s.core.keysPressed, 0, "a host note counted as an FM-1 key")
        // a pitch bend and a CC go to the core's MIDI in (not to the keys)
        render(au, ms: 20, midi: [0xE0, 0x00, 0x50])
        render(au, ms: 20, midi: [0xB0, 1, 64])
        XCTAssertEqual(au.status().midiIn, 4)
        XCTAssertEqual(au.status().midiNotes, 1)
    }

    /// fullState: the flash (ChoralRoot's tempo saved on the panel) comes back in a new instance
    func testFullStateCarriesTheFlash() throws {
        let a = try makeAU()
        render(a, ms: 600)
        XCTAssertEqual(a.param("Tempo"), 120)
        a.panelEvent(knob: Int32(RFME_E_SELECT), detents: 1)
        render(a, ms: 300)
        a.panelEvent(button: Int32(RFME_B_SAVE), down: true)
        render(a, ms: 1000)
        a.panelEvent(button: Int32(RFME_B_SAVE), down: false)
        render(a, ms: 600)
        XCTAssertEqual(a.param("Tempo"), 121)
        a.settings.transpose = 1

        // the getter while a render thread runs the clock (the clock makes the copy), then the dictionary as a host
        // stores it
        let stop = Locked(false)
        let t = Thread { while !stop.value { _ = a.renderForTest(frames: 441); usleep(2000) } }
        t.start()
        let saved = try XCTUnwrap(a.fullState)
        stop.value = true
        Thread.sleep(forTimeInterval: 0.05)
        let data = try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
        let back = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(back[InstanceState.formatKey] as? Int, 2)
        XCTAssertEqual(back[CoreState.coreKey] as? String, "choralroot")
        XCTAssertFalse((back[CoreState.versionKey] as? String ?? "").isEmpty)
        let z = try XCTUnwrap(back[CoreState.flashKey] as? Data)
        XCTAssertEqual(back[CoreState.flashSizeKey] as? Int, 1 << 20)
        print("fullState: flash 1 MiB -> \(z.count) bytes (lzfse), plist \(data.count) bytes")
        XCTAssertLessThan(z.count, 1 << 19)
        let cs = try XCTUnwrap(CoreState(back))
        XCTAssertEqual(cs.flash?.count, 1 << 20)
        XCTAssertEqual(cs.settings.transpose, 1)

        let b = try makeAU("felucca")              // (another core first: the state replaces it)
        b.fullState = back
        XCTAssertEqual(b.state.instance, a.state.instance)
        render(b, ms: 1000)
        XCTAssertEqual(b.status().coreID, "choralroot")
        XCTAssertEqual(b.status().bootedFrom, "the saved flash")
        XCTAssertEqual(b.param("Tempo"), 121, "the saved tempo did not survive the restore")
        XCTAssertEqual(b.settings.transpose, 1)

        // a state with a core and no flash: a fresh one
        var fresh: [String: Any] = [:]
        InstanceState().encode(into: &fresh)
        CoreState(core: "choralroot", version: "", flash: nil).encode(into: &fresh)
        let c = try makeAU(nil)
        c.fullState = fresh
        render(c, ms: 800)
        XCTAssertEqual(c.param("Tempo"), 120)
        XCTAssertEqual(c.status().bootedFrom, "a fresh flash (none saved)")
    }

    /// a fifth ChoralRoot in one process: the slot error, silence, no crash
    func testFifthInstanceRendersSilence() throws {
        let four = try (0..<4).map { _ in try makeAU() }
        XCTAssertEqual(Set(four.map { $0.status().core.slot }), [1, 2, 3, 4])
        let fifth = try makeAU()
        let s = fifth.status()
        XCTAssertFalse(s.core.booted)
        XCTAssertTrue(s.coreError.contains("at most 4 ChoralRoot"), s.coreError)
        XCTAssertEqual(render(fifth, ms: 100, midi: [0x90, 62, 100]), 0)
        let block = fifth.internalRenderBlock
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer { abl.unsafeMutablePointer.deallocate() }
        for c in 0..<2 { abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil) }
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        XCTAssertEqual(block(&flags, &ts, 256, 0, abl.unsafeMutablePointer, nil, nil), noErr)
        XCTAssertTrue(flags.contains(.unitRenderAction_OutputIsSilence))
        render(four[0], ms: 800)
        XCTAssertGreaterThan(render(four[0], ms: 300, midi: [0x90, 62, 100]), 0)
    }
}

/// a value shared with a thread
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
