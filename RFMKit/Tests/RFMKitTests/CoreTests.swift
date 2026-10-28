// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// M3 on the Mac: the four cores (ChoralRoot, Felucca, Melodee, FIZZ) through the slot loader and the engine (RFMEngine.h), on the macOS builds of
// scripts/build_cores.sh macos (build/cores/macos/frameworks, or RFM_CORES_DIR). Skipped, saying so, when they are
// not built. The engine runs on the test's thread (RFME_CLOCK_CALLER); the only link is libremotefm1's fake unit.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

/// a NUL-terminated C string in an array
func cstr(_ a: [CChar]) -> String {
    String(decoding: a.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// one engine on the caller's clock
final class TestCore {
    let e: OpaquePointer
    let id: String

    init(_ id: String, link: OpaquePointer? = nil) throws {
        self.id = id
        e = rfme_new(link)
        var err = [CChar](repeating: 0, count: 256)
        guard rfme_load(e, id, &err, 256) != 0 else {     // (deinit frees e: every property is set)
            throw NSError(domain: "core", code: 1, userInfo: [NSLocalizedDescriptionKey: cstr(err)])
        }
    }
    deinit { rfme_free(e) }

    func boot(_ flash: [UInt8]? = nil) {
        if let flash { _ = flash.withUnsafeBufferPointer { rfme_boot(e, $0.baseAddress, UInt32($0.count)) } }
        else { _ = rfme_boot(e, nil, 0) }
        rfme_set_clock(e, Int32(RFME_CLOCK_CALLER))
    }
    @discardableResult func run(_ ms: UInt32) -> rfme_audio_t {
        var a = rfme_audio_t()
        rfme_run_ms(e, ms, &a)
        return a
    }
    var status: rfme_status_t { var s = rfme_status_t(); rfme_status(e, &s); return s }
    var lcd: UInt32 { rfme_lcd_hash(e) }
    func key(_ k: Int, _ down: Bool) { _ = rfme_event(e, UInt8(RFMC_EV_KEY), UInt8(k), down ? 1 : 0) }
    func button(_ label: Int32, _ down: Bool) {
        _ = rfme_event(e, UInt8(RFMC_EV_BUTTON), UInt8(rfme_matrix_button(e, label)), down ? 1 : 0)
    }
    func knob(_ role: Int32, _ detents: Int16) {
        _ = rfme_event(e, UInt8(RFMC_EV_ENC), UInt8(rfme_matrix_encoder(e, role)), detents)
    }
    func param(_ name: String) -> Int32? {
        var v: Int32 = 0
        return rfme_param_get(e, name, &v) != 0 ? v : nil
    }
    /// flash_sync and the image now
    func flash() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(rfme_flash_size(e)))
        let ok = out.withUnsafeMutableBufferPointer { rfme_final_flash(e, $0.baseAddress, UInt32($0.count)) }
        return ok != 0 ? out : []
    }
}

final class CoreTests: XCTestCase {
    static let ids = ["choralroot", "felucca", "melodee", "fizz"]
    static let licences = ["fizz": "MPL-2.0"]    // (the others: GPL-3.0-only)
    /// a button tapped before a key sounds (conformance.txt's "sound" prelude): FIZZ's keys are its steps until REC
    static let keyPrelude: [String: Int32] = ["fizz": Int32(RFME_B_REC)]
    static let keyD4 = 9                // (conformance: the note key D4; key 0 is F3)

    static var coresDir: String {
        if let d = ProcessInfo.processInfo.environment["RFM_CORES_DIR"], !d.isEmpty { return d }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../build/cores/macos/frameworks").standardized.path
    }

    override func setUpWithError() throws {
        let dir = Self.coresDir
        guard FileManager.default.fileExists(atPath: dir) else {
            throw XCTSkip("no macOS core builds in \(dir): run scripts/build_cores.sh macos")
        }
        XCTAssertEqual(rfms_scan(dir), Int32(Self.ids.count), "cores in \(dir): \(Self.text(rfms_errors))")
    }

    static func text(_ f: (UnsafeMutablePointer<CChar>?, UInt32) -> UInt32) -> String {
        var b = [CChar](repeating: 0, count: 4096)
        _ = f(&b, 4096)
        return cstr(b)
    }

    func testSlotsAreProbed() throws {
        for id in Self.ids {
            var i = rfms_info_t()
            XCTAssertEqual(rfms_find(id, &i), 1, id)
            let name = RemoteController.string(i.name), ver = RemoteController.string(i.version)
            XCTAssertEqual(i.slots, 4, id)
            XCTAssertEqual(i.in_use, 0, id)
            XCTAssertEqual(i.abi, 6, id)
            XCTAssertGreaterThanOrEqual(i.flash_size, 1 << 20, id)
            XCTAssertEqual(RemoteController.string(i.license), Self.licences[id] ?? "GPL-3.0-only", id)
            XCTAssertEqual(RemoteController.string(i.gated), "", id)
            XCTAssertFalse(name.isEmpty || ver.isEmpty, id)
            let credits = rfms_credits(id, nil, 0)
            print("core \(id): \(name) \(ver), \(RemoteController.string(i.source_url)), credits \(credits) bytes")
        }
        XCTAssertGreaterThan(rfms_credits("melodee", nil, 0), 0)        // (CZ / Prophet data, the uPD933 notice)
    }

    /// each core: boots from an empty flash, runs 3 device seconds, draws; a held key sounds
    func testEachCoreBootsAndPlays() throws {
        for id in Self.ids {
            let c = try TestCore(id)
            c.boot()
            let blank = c.lcd
            let a0 = c.run(3000)
            let s0 = c.status
            let h0 = c.lcd
            XCTAssertEqual(s0.dev_ms, 2999, id)
            XCTAssertGreaterThan(s0.lcd_writes, 0, id)
            XCTAssertNotEqual(h0, blank, "\(id): the LCD never changed")
            if let b = Self.keyPrelude[id] {
                c.button(b, true)
                c.run(60)
                c.button(b, false)
                c.run(100)
            }
            c.key(Self.keyD4, true)
            let a1 = c.run(500)
            c.key(Self.keyD4, false)
            c.run(300)
            let s1 = c.status
            print(String(format: "core %@: slot %d, idle rms %.5f peak %d; key rms %.5f peak %d; LCD %08x -> %08x -> %08x, "
                         + "writes %u -> %u, stats %u (cpu %u%%, shed %u)", id, s1.slot, a0.rms, a0.peak, a1.rms, a1.peak,
                         blank, h0, c.lcd, s0.lcd_writes, s1.lcd_writes, s1.have_stats, s1.cpu_pct, s1.shed))
            XCTAssertEqual(s1.keys_pressed, 1, id)
            XCTAssertGreaterThan(a1.peak, 64, "\(id): a held D4 is silent")
            XCTAssertGreaterThan(a1.rms, 1e-4, id)
            XCTAssertEqual(a1.frames, 22050, accuracy: 128, id)
            XCTAssertEqual(s1.halted, 0, id)
        }
    }

    /// FIZZ: its descriptor (MPL-2.0, the source at its commit, the third parties' notices); its screen draws (not
    /// one colour); PLAY starts the demo project's pattern, which sounds with no key held
    func testFizz() throws {
        var i = rfms_info_t()
        XCTAssertEqual(rfms_find("fizz", &i), 1)
        XCTAssertEqual(RemoteController.string(i.name), "FIZZ")
        XCTAssertEqual(RemoteController.string(i.version), "0.12.0-beta.12")
        let url = RemoteController.string(i.source_url)
        XCTAssertTrue(url.hasPrefix("https://github.com/Quixotic7/FIZZ@") && url.count == 34 + 40, url)
        let credits = CorePlayer.credits("fizz")
        for s in ["FIZZ", "plutovg", "The FreeType Project", "stb", "Inter Tight", "Mozilla Public License Version 2.0",
                  "SIL OPEN FONT LICENSE"] {
            XCTAssertTrue(credits.contains(s), "fizz credits lack \(s)")
        }

        let c = try TestCore("fizz")
        c.boot()
        c.run(1500)
        var rgba = [UInt8](repeating: 0, count: Int(RFMC_W * RFMC_H * 4))
        XCTAssertNotEqual(rgba.withUnsafeMutableBufferPointer { rfme_preview(c.e, 0, $0.baseAddress) }, 0)
        var colours = Set<UInt32>()
        for p in stride(from: 0, to: rgba.count, by: 4) {
            colours.insert(UInt32(rgba[p]) << 16 | UInt32(rgba[p + 1]) << 8 | UInt32(rgba[p + 2]))
        }
        XCTAssertGreaterThan(colours.count, 8, "FIZZ's screen is (nearly) one colour")
        let quiet = c.run(500)
        XCTAssertEqual(quiet.peak, 0, "FIZZ sounds before PLAY")
        c.button(Int32(RFME_B_PLAY), true)
        c.run(60)
        c.button(Int32(RFME_B_PLAY), false)
        var peak: Int32 = 0, rms = 0.0
        for _ in 0..<8 {
            let a = c.run(500)
            peak = max(peak, a.peak)
            rms = max(rms, Double(a.rms))
        }
        print(String(format: "core fizz: %d colours on screen, demo after PLAY: peak %d, rms %.5f, keys %u",
                     colours.count, peak, rms, c.status.keys_pressed))
        XCTAssertGreaterThan(peak, 64, "FIZZ's demo pattern is silent after PLAY")
        XCTAssertEqual(c.status.halted, 0)
    }

    /// the default core: the preferred one if this build has it, else the first in CorePlayer.order (a store build
    /// has FIZZ only)
    func testDefaultCoreFallsBack() {
        let all = CorePlayer.catalog()
        XCTAssertEqual(all.map(\.id), Self.ids, "the picker's order")
        XCTAssertEqual(CorePlayer.pick("melodee", in: all), "melodee")
        XCTAssertEqual(CorePlayer.pick(nil, in: all), "choralroot")
        XCTAssertEqual(CorePlayer.pick("nosuchcore", in: all), "choralroot")
        let store = all.filter { $0.id == "fizz" }
        XCTAssertEqual(CorePlayer.pick("choralroot", in: store), "fizz")
        XCTAssertEqual(CorePlayer.pick(nil, in: store), "fizz")
        XCTAssertNil(CorePlayer.pick("choralroot", in: []))
        XCTAssertEqual(CorePlayer.missingNote("choralroot", "fizz", store), "choralroot is not in this build: FIZZ instead")
    }

    /// two slots of one core are two firmwares: the same boot gives the same screen; input in one changes only it.
    /// Four slots, and no fifth.
    func testSlotsIsolateState() throws {
        let a = try TestCore("choralroot"), b = try TestCore("choralroot")
        XCTAssertEqual(a.status.slot, 1)
        XCTAssertEqual(b.status.slot, 2)
        a.boot()
        b.boot()
        a.run(1500)
        b.run(1500)
        XCTAssertEqual(a.lcd, b.lcd, "two fresh units differ after the same 1.5 s")
        let tempoB = b.param("Tempo")
        a.knob(Int32(RFME_E_SELECT), 1)              // (the view: SELECT is the tempo)
        a.key(Self.keyD4, true)
        let pa = a.run(600), pb = b.run(600)
        XCTAssertNotEqual(a.lcd, b.lcd, "a knob turn on slot 1 did not change its screen, or changed slot 2's too")
        XCTAssertGreaterThan(pa.peak, 64)
        XCTAssertEqual(pb.peak, 0, "slot 2 sounds though only slot 1's key is down")
        XCTAssertEqual(a.param("Tempo"), tempoB.map { $0 + 1 })
        XCTAssertEqual(b.param("Tempo"), tempoB)
        XCTAssertEqual(a.status.keys_pressed, 1)
        XCTAssertEqual(b.status.keys_pressed, 0)

        let c = try TestCore("choralroot"), d = try TestCore("choralroot")
        XCTAssertEqual([c.status.slot, d.status.slot], [3, 4])
        var i = rfms_info_t()
        XCTAssertEqual(rfms_find("choralroot", &i), 1)
        XCTAssertEqual(i.in_use, 4)
        XCTAssertThrowsError(try TestCore("choralroot")) { err in
            XCTAssertTrue(err.localizedDescription.contains("at most 4 ChoralRoot"), err.localizedDescription)
        }
        // another core's slots are its own
        XCTAssertNoThrow(try TestCore("felucca"))
    }

    /// a released slot is unloaded (not retired) and taken again, fresh
    func testReleasedSlotIsReused() throws {
        do {
            let a = try TestCore("felucca")
            a.boot()
            a.run(500)
            XCTAssertEqual(a.status.slot, 1)
        }
        var i = rfms_info_t()
        XCTAssertEqual(rfms_find("felucca", &i), 1)
        XCTAssertEqual(i.in_use, 0)
        XCTAssertEqual(i.retired, 0, "the image stayed loaded after dlclose")
        let b = try TestCore("felucca")
        XCTAssertEqual(b.status.slot, 1)
        XCTAssertEqual(b.status.booted, 0)
        b.boot()
        b.run(500)
        let fresh = try TestCore("felucca")
        fresh.boot()
        fresh.run(500)
        XCTAssertEqual(b.lcd, fresh.lcd, "slot 1 taken again does not start as a fresh unit")
    }

    /// the flash: an image staged back reads back the same; a change saved the way the panel saves it survives a reboot
    func testFlashRoundTrip() throws {
        // ChoralRoot: the tempo one detent up, SAVE held (conformance_choralroot.txt), then a reboot from the image
        var image: [UInt8]
        do {
            let c = try TestCore("choralroot")
            c.boot()
            c.run(600)
            XCTAssertEqual(c.param("Tempo"), 120)
            c.knob(Int32(RFME_E_SELECT), 1)
            c.run(300)
            c.button(Int32(RFME_B_SAVE), true)
            c.run(1000)
            c.button(Int32(RFME_B_SAVE), false)
            c.run(600)
            XCTAssertEqual(c.param("Tempo"), 121)
            image = c.flash()
            XCTAssertEqual(image.count, Int(rfme_flash_size(c.e)))
        }
        do {
            let c = try TestCore("choralroot")
            c.boot(image)
            XCTAssertEqual(c.flash(), image, "the image staged back is not the image read")
            c.run(1000)
            XCTAssertEqual(c.param("Tempo"), 121, "the saved tempo did not survive the reboot")
        }
        // Melodee: its first FM1P_PERSIST parameter changed (conformance.txt's default round trip)
        var name = [CChar](repeating: 0, count: 64)
        var pname: String { cstr(name) }
        var lo: Int32 = 0, hi: Int32 = 0, v0: Int32 = 0, want: Int32 = 0
        do {
            let c = try TestCore("melodee")
            c.boot()
            c.run(600)
            XCTAssertEqual(rfme_param_persist(c.e, &name, 64, &lo, &hi, &v0), 1)
            want = v0 < hi ? v0 + 1 : lo
            XCTAssertEqual(rfme_param_set(c.e, name, want), 1)
            c.run(1000)
            image = c.flash()
        }
        do {
            let c = try TestCore("melodee")
            c.boot(image)
            c.run(1000)
            XCTAssertEqual(c.param(pname), want, "melodee's \(pname)")
        }
        // Felucca: the palette from its menu (HOME held, KNOB 1, HOME), the screen after a reboot not a fresh one's
        do {
            let c = try TestCore("felucca")
            c.boot()
            c.run(1500)
            c.button(Int32(RFME_B_HOME), true)
            c.run(1200)
            c.button(Int32(RFME_B_HOME), false)
            c.run(400)
            c.knob(Int32(RFME_E_K1), 1)
            c.run(400)
            c.button(Int32(RFME_B_HOME), true)
            c.run(100)
            c.button(Int32(RFME_B_HOME), false)
            c.run(600)
            image = c.flash()
        }
        let saved = try TestCore("felucca"), fresh = try TestCore("felucca")
        saved.boot(image)
        fresh.boot()
        saved.run(1500)
        fresh.run(1500)
        XCTAssertNotEqual(saved.lcd, fresh.lcd, "felucca's saved palette did not come back")
    }

    /// the firmware's own reboot (ChoralRoot's update gesture, OCT- OCT+ HOME held: exit(0)): halted, then a power
    /// cycle reloads the slot and boots from the kept flash (the saved tempo survives)
    func testHaltedCoreIsPowerCycled() throws {
        let c = try TestCore("choralroot")
        c.boot()
        c.run(600)
        c.knob(Int32(RFME_E_SELECT), 1)
        c.run(300)
        c.button(Int32(RFME_B_SAVE), true)
        c.run(1000)
        c.button(Int32(RFME_B_SAVE), false)
        c.run(600)
        for b in [RFME_B_OCTDN, RFME_B_OCTUP, RFME_B_HOME] { c.button(Int32(b), true) }
        c.run(6500)
        let h = c.status
        XCTAssertEqual(h.halted, 1, "the update gesture did not halt the firmware")
        XCTAssertEqual(h.halt_code, 0x100)
        var err = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(rfme_power_cycle(c.e, &err, 256), 1, cstr(err))
        var image = [UInt8](repeating: 0, count: Int(rfme_flash_size(c.e)))
        XCTAssertEqual(image.withUnsafeMutableBufferPointer { rfme_take_flash(c.e, $0.baseAddress, UInt32($0.count)) }, 1,
                       "the power cycle's image was not offered for saving")
        let s = c.status
        XCTAssertEqual(s.halted, 0)
        XCTAssertEqual(s.booted, 1)
        XCTAssertEqual(s.slot, 1, "the slot was not taken again (its image stayed loaded?)")
        c.run(1000)
        XCTAssertEqual(c.param("Tempo"), 121)
    }

    /// the whole panel path, headless: the fake unit's key reaches the core through RemoteLink, and the core's frames
    /// reach the fake unit
    func testCoreOnTheFakeUnit() throws {
        var cfg = rfmc_cfg_t()
        cfg.backend = Int32(RFMC_FAKE)
        cfg.fps = 20
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("rfm-m3-\(UUID().uuidString).lock").path
        let link = lock.withCString { lp in "RFMKit test".withCString { hn in
            cfg.lock_path = lp
            cfg.host_name = hn
            return rfmc_new(&cfg)!
        } }
        defer { rfmc_free(link) }
        let c = try TestCore("choralroot", link: link)
        c.boot()
        rfme_attach(c.e, 1)
        rfmc_start(link)
        var st = rfmc_status_t()
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            c.run(20)
            rfmc_status(link, &st)
            if Int(st.state) == RFMC_CONNECTED { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(Int(st.state), RFMC_CONNECTED)
        var f0 = rfmc_fake_t()
        _ = rfmc_fake_state(link, &f0)
        rfmc_fake_key(link, UInt32(Self.keyD4), 1)
        var peak: Int32 = 0
        for _ in 0..<60 {                            // (~1.2 s of device time, paced by the wall clock)
            peak = max(peak, c.run(20).peak)
            Thread.sleep(forTimeInterval: 0.02)
        }
        rfmc_fake_key(link, UInt32(Self.keyD4), 0)
        c.run(100)
        var f1 = rfmc_fake_t()
        _ = rfmc_fake_state(link, &f1)
        var keys: UInt32 = 0, buttons: UInt32 = 0, master: Int32 = 0
        var ev = [rfmc_event_t](repeating: rfmc_event_t(), count: 16)
        let nev = rfmc_events(link, 0, &ev, 16)
        rfmc_panel(link, &keys, &buttons, &master)
        print("fake unit + choralroot: frames \(f0.frames) -> \(f1.frames), keys pressed \(c.status.keys_pressed), "
              + "peak \(peak), snapshots \(c.status.snapshots), panel events seen \(nev)")
        XCTAssertEqual(c.status.keys_pressed, 1, "the fake's key never reached the core")
        XCTAssertGreaterThan(peak, 64)
        XCTAssertGreaterThan(f1.frames, f0.frames, "no frames from the core reached the fake unit")
        XCTAssertGreaterThanOrEqual(nev, 2, "the Panel card's log saw no key down / up")
        rfme_attach(c.e, 0)
    }
}
