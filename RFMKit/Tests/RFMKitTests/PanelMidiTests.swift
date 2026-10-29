// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// (M8) the faceplate's MIDI side, without a core: touches and the OMX-27 holding keys and buttons as two sources
// (PanelOmxTarget), MASTER's pickup mark and its timing, MIDI learn on the faceplate (MidiLearnMode: the bar's text,
// the bound marks, Forget, the toasts), touches on a knob telling the OMX which knob its encoder turns.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

@MainActor
final class PanelMidiTests: XCTestCase {
    private func bit(_ k: Int) -> UInt32 { 1 << UInt32(k) }

    /// a key held by a finger and by the OMX: down until both let go; the screen's releaseAll keeps the OMX's
    func testOmxHoldsAreItsOwn() {
        let feed = PanelFeed(host: nil)
        let omx = PanelOmxTarget(feed: feed)
        omx.omxKey(5, down: true)
        feed.keyDown(5)
        feed.keyDown(7)
        XCTAssertTrue(feed.holds(key: 5, .omx))
        XCTAssertTrue(feed.holds(key: 5, .screen))
        feed.releaseAll()                                   // (the faceplate went away)
        XCTAssertFalse(feed.holds(key: 5, .screen))
        XCTAssertFalse(feed.holds(key: 7, .screen))
        XCTAssertTrue(feed.holds(key: 5, .omx))
        XCTAssertEqual(feed.lights.touchedKeys, bit(5), "the OMX's key stays down")
        omx.omxKey(5, down: true)                           // (again: still one hold)
        omx.omxKey(5, down: false)
        XCTAssertEqual(feed.lights.touchedKeys, 0)

        // a finger lifting doesn't let go of the OMX's hold, and the other way round
        omx.omxKey(9, down: true)
        feed.keyDown(9)
        feed.keyUp(9)
        XCTAssertEqual(feed.lights.touchedKeys, bit(9))
        feed.keyDown(9)
        omx.omxKey(9, down: false)
        XCTAssertEqual(feed.lights.touchedKeys, bit(9))
        feed.keyUp(9)
        XCTAssertEqual(feed.lights.touchedKeys, 0)

        // buttons the same way; omxReleaseAll lets go of the OMX's only
        omx.omxButton(.play, down: true)
        feed.button(.home, down: true)
        feed.button(.play, down: true)
        omx.omxKey(3, down: true)
        feed.keyDown(4)
        omx.omxReleaseAll()
        XCTAssertFalse(feed.holds(.play, .omx))
        XCTAssertTrue(feed.holds(.play, .screen))
        XCTAssertEqual(feed.lights.touchedLabels, bit(PanelFeed.Label.home.rawValue) | bit(PanelFeed.Label.play.rawValue))
        XCTAssertEqual(feed.lights.touchedKeys, bit(4))
        feed.releaseAll()
        XCTAssertEqual(feed.lights.touchedLabels, 0)
        XCTAssertEqual(feed.lights.touchedKeys, 0)
        feed.keyUp(4)                                       // (a late lift: nothing to let go)
        XCTAssertEqual(feed.lights.touchedKeys, 0)
    }

    /// a touch on a knob tells the OMX (knobUsed); the OMX's own turns and MASTER don't
    func testKnobTouches() {
        let feed = PanelFeed(host: nil)
        let omx = PanelOmxTarget(feed: feed)
        var used: [PanelFeed.Knob] = []
        feed.onKnobTouched = { used.append($0) }
        feed.turn(.k2, 1)
        feed.master(300)
        omx.omxTurn(.k3, 2)
        omx.omxMaster(400)
        XCTAssertEqual(used, [.k2, .master])
        XCTAssertEqual(feed.knobs.turns[PanelFeed.Knob.k3.rawValue], 2)
        XCTAssertEqual(feed.knobs.master, 400)
        XCTAssertEqual(omx.omxMasterNow, 400)
    }

    /// the mark shows where the pot is, for 4 s after it last moved; MASTER reached (-1) hides it
    func testPickupMarkTiming() {
        let feed = PanelFeed(host: nil)
        var p = rfme_panel_t()
        p.master = 512
        p.master_pot = -1
        feed.apply(p, now: 100)
        XCTAssertNil(feed.pickup.pot)
        XCTAssertNil(feed.toast.current, "the first snapshot only seeds pickup_seq")

        p.master_pot = 200
        p.pickup_seq = 1
        feed.apply(p, now: 101)
        XCTAssertEqual(feed.pickup.pot, 200)
        XCTAssertEqual(feed.toast.current?.text, "MASTER: turn the pot to 50% to pick it up")
        feed.pickup.expire(now: 104.9)
        XCTAssertEqual(feed.pickup.pot, 200)
        p.master_pot = 260                                  // (it moved: 4 s again from now)
        feed.apply(p, now: 104)
        feed.pickup.expire(now: 106)
        XCTAssertEqual(feed.pickup.pot, 260)
        feed.pickup.expire(now: 108)
        XCTAssertNil(feed.pickup.pot)

        p.master_pot = 300                                  // (the same wait: no new word)
        feed.toast.hide()
        feed.apply(p, now: 110)
        XCTAssertEqual(feed.pickup.pot, 300)
        XCTAssertNil(feed.toast.current)
        p.master_pot = -1                                   // picked up
        feed.apply(p, now: 111)
        XCTAssertNil(feed.pickup.pot)

        // the OMX's K5: the same mark, the word on `first` only; MASTER set by it hides the mark
        let omx = PanelOmxTarget(feed: feed)
        omx.omxPickup(pot: 900, at: 1023, first: true)
        XCTAssertEqual(feed.pickup.pot, 900)
        XCTAssertEqual(feed.toast.current?.text, "MASTER: turn the pot to 100% to pick it up")
        feed.toast.hide()
        omx.omxPickup(pot: 950, at: 1023, first: false)
        XCTAssertEqual(feed.pickup.pot, 950)
        XCTAssertNil(feed.toast.current)
        omx.omxMaster(1000)
        XCTAssertNil(feed.pickup.pot)
        XCTAssertEqual(PickupFeed.text(0), "MASTER: turn the pot to 0% to pick it up")
    }

    /// learn mode on the faceplate: nothing picked, picked and waiting, bound (the toast, the mark), Forget, Done
    func testLearnMode() {
        let store = MidiMapStore(url: MidiMapTests.tempFile())
        let feed = PanelFeed(host: nil)
        let mode = MidiLearnMode(feed: feed, host: nil, store: store)
        let ui = FaceplateUI()
        ui.page = .screen
        ui.sheetOpen = true
        store.bind("note:1:60", to: "PLAY")
        feed.keyDown(3)
        mode.start(ui)
        XCTAssertFalse(ui.sheetOpen)
        XCTAssertEqual(ui.page, .full, "the controls to tap are on the panel")
        XCTAssertEqual(feed.lights.touchedKeys, 0, "what the screen held let go")
        XCTAssertTrue(feed.learn.active)
        XCTAssertNotNil(feed.onTick)
        XCTAssertEqual(feed.learn.bound, ["PLAY"])
        XCTAssertNil(feed.learn.selected)
        XCTAssertEqual(feed.learn.text, "Tap a knob or button, then move a control on your MIDI device")
        XCTAssertFalse(feed.learn.canForget)

        feed.learn.pick(MidiTarget.knob(.k1))
        XCTAssertEqual(feed.learn.selected, "KN1")
        XCTAssertEqual(feed.learn.text, "KN1: now turn a knob or a pot on your MIDI device")
        feed.learn.pick(MidiTarget.button(.seq))
        XCTAssertEqual(feed.learn.text, "SEQ: now press a button or a key on your MIDI device")
        feed.learn.pick(MidiTarget.knob(.k1))

        // a note on a knob: refused, said in red
        if let r = mode.learn.take([0x90, 60, 100]) { mode.took(r) }
        XCTAssertEqual(feed.toast.current?.tone, .bad)
        // a CC binds: the toast, the mark, the bar
        if let r = mode.learn.take([0xB0, 21, 64]) { mode.took(r) }
        XCTAssertEqual(feed.toast.current?.text, "KN1 ← CC 21,\u{a0}channel\u{a0}1 (absolute)")
        XCTAssertEqual(feed.toast.current?.tone, .ok)
        mode.tick()
        XCTAssertEqual(feed.learn.bound, ["PLAY", "KN1"])
        XCTAssertEqual(feed.learn.text, "KN1 ← CC 21 ch 1")
        XCTAssertTrue(feed.learn.canForget)

        // the map changed elsewhere (the sheet, another process): seen on the next tick
        store.bind("cc:2:5", to: "KN1", mode: .rel2c)
        mode.tick()
        XCTAssertEqual(feed.learn.text, "KN1 ← CC 21 ch 1, CC 5 ch 2")

        feed.learn.forget()
        XCTAssertEqual(feed.toast.current?.text, "KN1: its 2 bindings forgotten")
        XCTAssertEqual(feed.learn.bound, ["PLAY"])
        XCTAssertFalse(feed.learn.canForget)
        feed.learn.forget()
        XCTAssertEqual(feed.toast.current?.text, "KN1 has no binding")

        feed.learn.done()
        XCTAssertFalse(feed.learn.active)
        XCTAssertNil(feed.learn.selected)
        XCTAssertEqual(feed.learn.bound, [])
        XCTAssertNil(feed.onTick)
        feed.learn.pick(MidiTarget.knob(.k2))               // (not learning: nothing)
        XCTAssertNil(mode.learn.selected)
        try? FileManager.default.removeItem(at: store.url)
    }

    func testLearnTexts() {
        XCTAssertEqual(MidiLearnMode.boundText(MidiMapping(src: "note:10:36", target: "PLAY")),
                       "PLAY ← note 36,\u{a0}channel\u{a0}10")
        XCTAssertEqual(MidiLearnMode.boundText(MidiMapping(src: "cc:1:22", target: "KN2", mode: .rel64)),
                       "KN2 ← CC 22,\u{a0}channel\u{a0}1 (relative 64±)")
        XCTAssertEqual(MidiLearnMode.barText(selected: "MASTER", sources: []),
                       "MASTER: now turn a knob or a pot on your MIDI device")
    }
}
