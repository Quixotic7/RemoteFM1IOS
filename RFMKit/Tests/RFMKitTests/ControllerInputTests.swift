// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// ControllerInput against real CoreMIDI: a virtual source in this process sends a note, which CoreMIDI delivers on its
// own thread (as a USB keyboard's on the iPhone), and it must reach the engine (rfme_midi_in's count). Build 5's first
// M8 build stopped here: its receive block was main-actor isolated. No core is needed: rfme_midi_in counts what it
// queues.

#if canImport(CoreMIDI)
import CoreMIDI
import Foundation
import RFMCore
import XCTest
@testable import RFMKit

private final class BareEngine: PanelEngineHost {
    let e: OpaquePointer = rfme_new(nil)
    deinit { rfme_free(e) }
    func withPanelEngine<R>(_ body: (OpaquePointer) -> R) -> R { body(e) }
    var midiIn: UInt32 { var st = rfme_status_t(); rfme_status(e, &st); return st.midi_in }
}

final class ControllerInputTests: XCTestCase {
    @MainActor func testNoteFromCoreMIDIThreadReachesEngine() throws {
        var client = MIDIClientRef(), src = MIDIEndpointRef()
        guard MIDIClientCreateWithBlock("RFM test" as CFString, &client, nil) == noErr else { throw XCTSkip("no CoreMIDI") }
        defer { MIDIClientDispose(client) }
        guard MIDISourceCreateWithProtocol(client, "RFM test keyboard" as CFString, ._1_0, &src) == noErr else {
            throw XCTSkip("no virtual source")
        }
        defer { MIDIEndpointDispose(src) }

        let engine = BareEngine()
        let suite = "rfm1.test.controllerinput"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let input = ControllerInput(host: engine, defaults: defaults)
        input.exclude = { $0 != src }                  // (only this test's source, never the Mac's own devices)
        input.reconnect()

        var list = MIDIEventList()
        let pkt = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, [0x2090_3C64])   // note-on C4, ch 1
        let until = Date().addingTimeInterval(3)
        while engine.midiIn == 0, Date() < until {
            _ = MIDIReceivedEventList(src, &list)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(engine.midiIn, 0, "the note never reached the engine")
        withExtendedLifetime(input) {}
    }
}
#endif
