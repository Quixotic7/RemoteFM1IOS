// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// M2 on the Mac: the AU's state, its render block (silence, MIDI counted), the probe report's JSON, and the shared
// file, Darwin notification and notify(3) round trips within one process. No CoreMIDI: every probe here is made with
// includeMIDI false, and the AU with runProbes false.

import AVFoundation
import AudioToolbox
import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class AUv3Tests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rfmkit-m2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// runs the main run loop until cond holds or `seconds` pass (Darwin notifications arrive there)
    private func spin(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    // MARK: state

    func testInstanceStateRoundTrip() {
        let s = InstanceState()
        var d: [String: Any] = ["other": 1]
        s.encode(into: &d)
        XCTAssertEqual(InstanceState(d), s)
        XCTAssertEqual(d["other"] as? Int, 1)
        XCTAssertEqual(InstanceState(d)?.format, InstanceState.currentFormat)
        // a plist round trip, as a host stores it
        let data = try? PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0)
        let back = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        XCTAssertEqual(InstanceState(back), s)
    }

    func testInstanceStateRejectsMissingOrBadUUID() {
        XCTAssertNil(InstanceState(nil))
        XCTAssertNil(InstanceState([:]))
        XCTAssertNil(InstanceState([InstanceState.instanceKey: "not a uuid"]))
        XCTAssertNil(InstanceState([InstanceState.instanceKey: 42]))
        let u = UUID()
        XCTAssertEqual(InstanceState([InstanceState.instanceKey: u.uuidString])?.format, 0)   // (no version: 0)
    }

    // MARK: the AU itself

    private func makeAU() throws -> RFMAudioUnit {
        try RFMAudioUnit(componentDescription: RFMShared.component, options: [], runProbes: false)
    }

    func testComponentCodes() {
        XCTAssertEqual(RFMShared.component.componentType, kAudioUnitType_MusicDevice)
        XCTAssertEqual(RFMShared.component.componentSubType, 0x5266_6D31)        // 'Rfm1'
        XCTAssertEqual(RFMShared.component.componentManufacturer, 0x5178_3775)   // 'Qx7u'
    }

    func testFullStateCarriesTheInstanceAndRestores() throws {
        let a = try makeAU(), b = try makeAU()
        XCTAssertNotEqual(a.state.instance, b.state.instance, "a new instance gets a new UUID")
        let saved = try XCTUnwrap(a.fullState)
        XCTAssertEqual(InstanceState(saved), a.state)
        b.fullState = saved
        XCTAssertEqual(b.state.instance, a.state.instance, "the UUID survives a save and restore")
        XCTAssertEqual(InstanceState(b.fullState)?.instance, a.state.instance)
        b.fullState = ["unrelated": true]              // not ours: the instance stays
        XCTAssertEqual(b.state.instance, a.state.instance)
    }

    /// (build 7) the view's size from the resize corner (a Mac) is kept per instance
    func testFullStateCarriesTheViewSize() throws {
        let a = try makeAU(), b = try makeAU()
        XCTAssertNil(a.viewSize)
        XCTAssertNil(a.fullState?[RFMAudioUnit.viewSizeKey], "a size saved that nobody set")
        a.viewSize = CGSize(width: 1100, height: 480)
        b.fullState = a.fullState
        XCTAssertEqual(b.viewSize, CGSize(width: 1100, height: 480))
        let c = try makeAU()
        c.fullState = try makeAU().fullState            // (a state without one)
        XCTAssertNil(c.viewSize)
    }

    func testBussesAndMIDI() throws {
        let au = try makeAU()
        XCTAssertEqual(au.outputBusses.count, 1)
        XCTAssertEqual(au.inputBusses.count, 0)
        XCTAssertEqual(au.outputBusses[0].format.channelCount, 2)
        XCTAssertTrue(au.isMusicDeviceOrEffect)
    }

    func testRenderBlockWritesSilenceIntoHostlessBuffersAndCountsMIDI() throws {
        let au = try makeAU()
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }
        let block = au.internalRenderBlock

        // the host passes no buffers (mData NULL): the kernel's own are used
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer { abl.unsafeMutablePointer.deallocate() }
        for i in 0..<2 { abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil) }
        var midi = AUMIDIEvent(next: nil, eventSampleTime: 0, eventType: .MIDI, reserved: 0, length: 3, cable: 0,
                               data: (0x90, 60, 100))
        var ev = AURenderEvent(MIDI: midi)
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        let st = block(&flags, &ts, 256, 0, abl.unsafeMutablePointer, &ev, nil)
        XCTAssertEqual(st, noErr)
        XCTAssertTrue(flags.contains(.unitRenderAction_OutputIsSilence))
        for i in 0..<2 {
            XCTAssertNotNil(abl[i].mData)
            XCTAssertEqual(abl[i].mDataByteSize, 256 * 4)
            let p = abl[i].mData!.assumingMemoryBound(to: Float.self)
            XCTAssertTrue((0..<256).allSatisfy { p[$0] == 0 })
        }
        midi.data = (0x80, 60, 0)
        ev = AURenderEvent(MIDI: midi)
        _ = block(&flags, &ts, 256, 0, abl.unsafeMutablePointer, &ev, nil)
        XCTAssertEqual(block(&flags, &ts, 1024, 0, abl.unsafeMutablePointer, nil, nil),
                       kAudioUnitErr_TooManyFramesToProcess)

        let r = au.probe.report(write: false)
        XCTAssertEqual(r.render?.renders, 2)
        XCTAssertEqual(r.render?.frames, 512)
        XCTAssertEqual(r.render?.midiEvents, 2)
        XCTAssertEqual(r.render?.lastMIDI, [0x80, 60, 0])
        XCTAssertEqual(r.render?.maxFrames, 512)
        XCTAssertEqual(r.thread.started, true)
    }

    func testKernelThreadKeepsTicking() throws {
        let au = try makeAU()
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }
        let t0 = au.probe.report(write: false).thread.ticks
        _ = au.renderForTest(frames: 64, midi: [0x90, 64, 1])
        Thread.sleep(forTimeInterval: 0.1)
        let r = au.probe.report(write: false)
        XCTAssertGreaterThan(r.thread.ticks, t0)
        XCTAssertEqual(r.render?.midiEvents, 1)
    }

    func testDiagnosticsChannelReport() throws {
        let au = try makeAU()
        let ch = au.messageChannel(for: RFMShared.diagnosticsChannel)
        let reply = try XCTUnwrap(ch.callAudioUnit?(["cmd": "report"]))
        XCTAssertEqual(reply["instance"] as? String, au.state.instance.uuidString)
        XCTAssertEqual(reply["pid"] as? Int, Int(getpid()))
        let json = try XCTUnwrap(reply["json"] as? String)
        let r = try XCTUnwrap(ProbeReport.decode(Data(json.utf8)))
        XCTAssertEqual(r.role, .ext)
        XCTAssertEqual(r.instance, au.state.instance.uuidString)
        // plist types only, so an out-of-process host gets it across XPC
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: reply, format: .binary, options: 0))
    }

    /// an out-of-process host's channel sets callHostBlock on ours when it connects (the extension died on the
    /// simulator without it: unrecognized selector setCallHostBlock:)
    func testDiagnosticsChannelTakesACallHostBlock() throws {
        let au = try makeAU()
        let ch = au.messageChannel(for: RFMShared.diagnosticsChannel) as AnyObject
        XCTAssertTrue(ch.responds(to: NSSelectorFromString("setCallHostBlock:")))
        XCTAssertTrue(ch.responds(to: NSSelectorFromString("callHostBlock")))
        XCTAssertTrue(ch.responds(to: NSSelectorFromString("callAudioUnit:")))
    }

    // MARK: probes

    func testProbeReportJSONRoundTrip() {
        var r = ProbeReport(role: .ext, pid: 42, process: "p", bundleID: "b", simulator: true,
                            instance: UUID().uuidString, time: 1_800_000_000)
        r.midi = .init(clientStatus: 0, inPortStatus: 0, outPortStatus: -10830, notifications: 2,
                       sources: ["FM-1 7938"], destinations: ["FM-1 7938", "Other"], candidates: ["FM-1 7938"])
        r.group.container = "/x"
        r.group.otherFile = .init(pid: 7, instance: nil, time: 1)
        r.group.mmapOtherPid = 7
        r.render = .init(renders: 1, frames: 512, midiEvents: 1, lastMIDI: [0x90, 60, 100], sampleRate: 44100,
                         maxFrames: 4096)
        XCTAssertEqual(ProbeReport.decode(Data(r.json().utf8)), r)
        XCTAssertEqual(ProbeReport.decode(Data(r.json(pretty: false).utf8)), r)
        let keys = r.lines.map(\.0)
        XCTAssertTrue(keys.contains("CoreMIDI"))
        XCTAssertTrue(keys.contains("render"))
        XCTAssertEqual(r.lines.first { $0.0 == "candidates" }?.1, "FM-1 7938")
    }

    func testSharedFileSeenThroughTwoMappings() throws {
        let path = tempDir().appendingPathComponent("lease-probe.bin").path
        var e1: Int32 = 0, e2: Int32 = 0
        let a = try XCTUnwrap(rfmp_shm_open(path, &e1)), b = try XCTUnwrap(rfmp_shm_open(path, &e2))
        defer { rfmp_shm_close(a); rfmp_shm_close(b) }
        XCTAssertEqual(rfmp_shm_bump(a, 0), 1)
        XCTAssertEqual(rfmp_shm_bump(b, 1), 2)
        var v = rfmp_shm_view_t()
        rfmp_shm_read(a, &v)
        XCTAssertEqual(v.magic, RFMP_SHM_MAGIC)
        XCTAssertEqual(v.counter, 2)
        XCTAssertEqual(rfmp_shm_slot(&v, 1).pid, getpid())
        XCTAssertEqual(rfmp_shm_slot(&v, 1).seq, 2)
        XCTAssertEqual(rfmp_shm_slot(&v, 0).seq, 1)
        XCTAssertEqual(rfmp_shm_slot(&v, 2).seq, 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.size] as? NSNumber)?.intValue, Int(RFMP_SHM_SIZE))
    }

    func testSharedFileOpenFailsCleanly() {
        var e: Int32 = 0
        XCTAssertNil(rfmp_shm_open("/nonexistent-dir-rfm/x.bin", &e))
        XCTAssertEqual(e, ENOENT)
    }

    func testDarwinNotificationRoundTrip() {
        let name = "group.com.quixotic7.remotefm1.test.\(UUID().uuidString)"
        rfmp_darwin_observe(name)
        XCTAssertEqual(rfmp_darwin_count(name), 0)
        rfmp_darwin_post(name)
        XCTAssertTrue(spin(3) { rfmp_darwin_count(name) >= 1 }, "the post arrives")
    }

    func testNotifyStateRoundTrip() {
        let name = "group.com.quixotic7.remotefm1.test.\(UUID().uuidString)"
        let v: UInt64 = UInt64(UInt32(bitPattern: getpid())) << 32 | 7
        XCTAssertEqual(rfmp_notify_set(name, v), 0)
        var got: UInt64 = 0
        XCTAssertEqual(rfmp_notify_get(name, &got), 0)
        XCTAssertEqual(got, v)
    }

    func testTwoProbesInOneProcessSeeEachOther() {
        let dir = tempDir()
        let app = Probe(role: .app, includeMIDI: false, directory: dir)
        let ext = Probe(role: .ext, instance: UUID().uuidString, includeMIDI: false, directory: dir)
        app.start()
        ext.start()
        app.ping()
        ext.ping()
        _ = app.report()
        _ = ext.report()                    // both files written
        XCTAssertTrue(spin(3) { app.report(write: false).group.darwinReceived >= 1
                                && ext.report(write: false).group.darwinReceived >= 1 })
        let a = app.report(), x = ext.report()
        XCTAssertEqual(a.group.otherFile?.pid, getpid())
        XCTAssertEqual(a.group.otherFile?.instance, x.instance)
        XCTAssertEqual(x.group.otherFile?.pid, getpid())
        XCTAssertTrue(a.group.mmapOK)
        XCTAssertFalse(a.group.mmapShared)
        XCTAssertEqual(a.group.mmapOtherPid, getpid())
        XCTAssertEqual(a.group.mmapCounter, 2)
        XCTAssertEqual(a.group.notifyOther >> 32, UInt64(UInt32(bitPattern: getpid())))
        XCTAssertEqual(x.group.notifyOther >> 32, UInt64(UInt32(bitPattern: getpid())))
        XCTAssertTrue(a.thread.started)
        XCTAssertNil(a.midi)
        XCTAssertEqual(a.memory.available, -1, "os_proc_available_memory doesn't exist on macOS")
        XCTAssertGreaterThan(a.memory.footprint, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("probe-app.json").path))
        XCTAssertEqual(a.file, dir.appendingPathComponent("probe-app.json").path)
    }
}
