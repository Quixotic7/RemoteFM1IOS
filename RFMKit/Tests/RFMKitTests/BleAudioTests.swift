// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Bluetooth audio (RemoteFM1 0.3.6: caps RFM_CAP_BLE_AUDIO, AUDIO_MODE / AUDIO / AUDIO_R; docs/PROTOCOL.md section 9):
// with the link's option on, a Bluetooth session asks libremotefm1's fake unit for the audio mode, the attached
// engine's output (the echo core's test tone, CC 23) goes to it as AUDIO blocks the fake decodes, and the engine's own
// output is silent while the unit plays. Off, over USB, or a unit before 0.3.6: no mode, the sound stays here.
// Offline renders, needs no core builds.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class BleAudioTests: XCTestCase {
    private var link: OpaquePointer!
    private var e: OpaquePointer!
    /// the largest output sample of the last until()'s last half
    private var localPeak: Float = 0

    private func open(ble: Bool = true, noAudio: Bool = false, on: Bool = true) {
        var cfg = rfmc_cfg_t()
        cfg.backend = Int32(RFMC_FAKE)
        cfg.fps = 20
        cfg.fake_ble = ble ? 1 : 0
        cfg.fake_no_audio = noAudio ? 1 : 0
        link = "RFMKit audio".withCString { hn in
            cfg.host_name = hn
            return rfmc_new(&cfg)
        }
        rfmc_set_ble_audio(link, on ? 1 : 0)
        e = rfme_new(link)
        XCTAssertEqual(rfme_test_load_echo(e), 1)
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))
        rfme_set_offline(e, 1)
        rfme_attach(e, 1)
        rfmc_start(link)
        XCTAssertTrue(until(3) { Int(self.status().state) == RFMC_CONNECTED }, "no session")
        tone(127)
    }

    override func tearDown() {
        if let e {
            rfme_attach(e, 0)
            rfme_free(e)
        }
        if let link { rfmc_free(link) }
    }

    private func tone(_ level: UInt8) {
        var cc: [UInt8] = [0xB0, 23, level]
        XCTAssertEqual(rfme_midi_in(e, &cc, 3, 1), 1)
    }

    private func status() -> rfmc_status_t {
        var st = rfmc_status_t()
        rfmc_status(link, &st)
        return st
    }

    private func fake() -> rfmc_fake_t {
        var f = rfmc_fake_t()
        _ = rfmc_fake_state(link, &f)
        return f
    }

    /// renders at about real time until `ok` (or `seconds`); localPeak: the output's largest sample over the last
    /// 0.2 s rendered
    @discardableResult
    private func until(_ seconds: Double = 0.6, _ ok: () -> Bool) -> Bool {
        var L = [Float](repeating: 0, count: 256), R = L
        var peaks: [Float] = []
        let end = Date().addingTimeInterval(seconds)
        defer { localPeak = peaks.suffix(34).max() ?? 0 }
        while Date() < end {
            _ = L.withUnsafeMutableBufferPointer { l in
                R.withUnsafeMutableBufferPointer { r in rfme_render_midi(e, l.baseAddress, r.baseAddress, 256, 44100, nil, 0) }
            }
            peaks.append(max(L.map(abs).max() ?? 0, R.map(abs).max() ?? 0))
            if ok() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }

    func testSoundGoesToTheFM1AndIsSilentHere() {
        open()
        XCTAssertNotEqual(Int(status().caps) & 0x800, 0, "the fake's HELLO_R has no RFM_CAP_BLE_AUDIO")
        XCTAssertTrue(until(3) { self.status().audio == 1 }, "the unit never went into the audio mode")
        XCTAssertEqual(rfmc_ble_audio_on(link), 1)
        let before = fake().audio_blocks
        until(1) { false }
        let st = status(), f = fake()
        XCTAssertEqual(st.audio_wanted, 1)
        XCTAssertEqual(st.audio_rate, 22050)
        XCTAssertEqual(f.audio_on, 1)
        XCTAssertEqual(f.audio_bad, 0)
        // ~86 blocks a second at 22,050 Hz (renders paced only roughly: at least half of that)
        XCTAssertGreaterThan(f.audio_blocks - before, 40, "AUDIO blocks in a second")
        XCTAssertGreaterThan(f.audio_peak, 11000, "the tone (half of full scale) decoded on the unit")
        XCTAssertLessThan(f.audio_peak, 22000)
        XCTAssertEqual(localPeak, 0, "this device is silent while the FM-1 plays")
        XCTAssertTrue(LinkStats(audio: true, rate: st.audio_rate).audioText.contains("22.050 kHz"))
    }

    func testOffBringsTheSoundBack() {
        open()
        XCTAssertTrue(until(3) { self.status().audio == 1 })
        until(0.3) { false }
        XCTAssertEqual(localPeak, 0)
        rfmc_set_ble_audio(link, 0)
        XCTAssertTrue(until(3) { self.status().audio == 0 && self.fake().audio_on == 0 }, "the mode never ended")
        XCTAssertEqual(rfmc_ble_audio_on(link), 0)
        until(1) { false }
        XCTAssertGreaterThan(localPeak, 0.4, "the tone plays here again")
        // (the screen sent again: libremotefm1's own test_ble_audio; the echo core's screen is black, as the unit's is)
        let blocks = fake().audio_blocks
        until(0.3) { false }
        XCTAssertEqual(fake().audio_blocks, blocks, "no AUDIO once off")
    }

    func testOffByDefaultAndNeverOverUSB() {
        open(ble: false)
        until(1.5) { false }
        XCTAssertEqual(status().audio, 0)
        XCTAssertEqual(fake().audio_modes, 0, "AUDIO_MODE sent over USB")
        XCTAssertGreaterThan(localPeak, 0.4)
        tearDown()
        open(on: false)
        until(1.5) { false }
        XCTAssertEqual(fake().audio_modes, 0, "AUDIO_MODE sent with the option off")
        XCTAssertGreaterThan(localPeak, 0.4)
    }

    func testAUnitBefore036KeepsItsScreen() {
        open(noAudio: true)
        XCTAssertEqual(Int(status().caps) & 0x800, 0)
        until(1.5) { false }
        XCTAssertEqual(status().audio, 0)
        XCTAssertEqual(fake().audio_blocks, 0)
        XCTAssertGreaterThan(localPeak, 0.4, "the sound stays here")
    }

    /// rfmc_relink (the FM-1's USB port came during a Bluetooth session): the session starts again (a USB port would be
    /// picked first; the fake has only its Bluetooth one) and asks for the audio mode again
    func testRelinkStartsTheSessionAgain() {
        open()
        XCTAssertTrue(until(3) { self.status().audio == 1 })
        let sessions = status().sessions
        rfmc_relink(link)
        XCTAssertTrue(until(3) { self.status().relinks == 1 && self.status().sessions > sessions }, "no new session")
        XCTAssertTrue(until(3) { self.status().audio == 1 && Int(self.status().state) == RFMC_CONNECTED },
                      "the audio mode not asked again")
    }

    func testAudioText() {
        var s = LinkStats()
        XCTAssertEqual(s.audioText, "Off")
        s.audioWanted = true
        XCTAssertTrue(s.audioText.hasPrefix("Asking"))
        s = LinkStats(audio: true, rate: 22050)
        s.audioBufferMs = 120
        s.audioFillMs = 118
        XCTAssertEqual(s.audioText, "Your FM-1 plays the sound: 22.050 kHz, 120 ms buffer (118 ms now), 0 underruns, 0 lost")
    }
}

private extension LinkStats {
    init(audio: Bool, rate: UInt32) {
        self.init()
        self.audio = audio
        audioWanted = audio
        audioRate = rate
    }
}
