// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The on-screen FM-1 (design/README.md): the tokens and themes, the derivation of a custom theme, the keybed's
// geometry, the layouts, the bundled fonts, and the on-screen input path into a real core (the macOS core builds, as
// CoreTests; skipped without them) with its LEDs and knobs coming back through rfme_panel.

import CoreGraphics
import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class ThemeTests: XCTestCase {
    func testBundledTokensMatchTheDesign() throws {
        let design = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../design/tokens.json").standardized
        let bundled = try XCTUnwrap(ThemeTokens.bundledURL)
        XCTAssertEqual(try Data(contentsOf: design), try Data(contentsOf: bundled),
                       "RFMKit/Sources/RFMKit/Resources/tokens.json differs from design/tokens.json")
    }

    func testTokensLoadFivePresets() {
        let t = ThemeTokens.bundled
        XCTAssertEqual(t.presets.map(\.name), ["Tangerine", "Midnight", "Mint", "Lilac", "Cream"])
        XCTAssertEqual(t.defaultName, "Tangerine")
        let tan = t.presets[0]
        XCTAssertEqual(tan.body.hex, "#EE7A3C")
        XCTAssertEqual(tan.ledOff.hex, "#6F6668")
        XCTAssertEqual(t.presets[4].knob.hex, "#E8622A")
        XCTAssertEqual(t.fixed["indicatorLed"]?.hex, "#FF3B2F")
        XCTAssertEqual(t.fixed["linkedDot"]?.hex, "#3BD47A")
        XCTAssertEqual(t.sheet["accent"]?.hex, "#FF8A4C")
        for p in t.presets { for r in Theme.roles { XCTAssertNotNil(p[r], "\(p.name).\(r)") } }
    }

    func testHexAndLabRoundTrip() {
        for h in ["#EE7A3C", "#1E2230", "#A8DCC8", "#000000", "#FFFFFF", "#924E3A"] {
            let c = RGB(hex: h)!
            XCTAssertEqual(c.hex, h)
            let l = c.lab
            XCTAssertEqual(RGB(l: l.l, a: l.a, b: l.b).hex, h)
        }
        XCTAssertNil(RGB(hex: "#12345"))
        XCTAssertEqual(RGB(hex: "#FFFFFF")!.contrast(RGB(hex: "#000000")!), 21, accuracy: 0.01)
    }

    /// section 6's rules, on each preset's own five colours
    func testDerivationRules() {
        for p in ThemeTokens.bundled.presets {
            let d = Theme.derived(p.choice, base: p)
            let kl = p.key.lab.l
            XCTAssertEqual(d.hi.lab.l, kl + 8, accuracy: 0.6, "\(p.name) hi")
            XCTAssertEqual(d.lo.lab.l, max(0, kl - 18), accuracy: 0.6, "\(p.name) lo")
            XCTAssertEqual(d.bed.lab.l, kl - 6, accuracy: 0.6, "\(p.name) bed")
            XCTAssertEqual(d.ledOff.lab.l, d.bed.lab.l + 20, accuracy: 0.8, "\(p.name) ledOff")
            XCTAssertEqual(abs(d.ledOff.lab.a) + abs(d.ledOff.lab.b), 0, accuracy: 1.5, "\(p.name) ledOff is grey")
            XCTAssertGreaterThanOrEqual(d.keyText.contrast(d.key), 4.5, "\(p.name) keyText")
            XCTAssertGreaterThanOrEqual(d.label.contrast(d.body), 4.5, "\(p.name) label")
            XCTAssertEqual(d.mark, p.knob.lab.l < 55 ? Theme.nearWhite : Theme.nearBlack, "\(p.name) mark")
            XCTAssertEqual(d.lcd, p.lcd)
            // the derived highlight stays near the designer's (the beds differ more: Midnight's is far darker)
            XCTAssertEqual(d.hi.lab.l, p.hi.lab.l, accuracy: 4, "\(p.name) hi vs design")
        }
        // a light key gets dark legends, a light knob a dark pointer
        let light = Theme.derived(.init(body: RGB(hex: "#F4F1EA")!, key: RGB(hex: "#E8E2D6")!, knob: RGB(hex: "#F0F0F0")!,
                                        led: RGB(hex: "#FF0000")!, bezel: RGB(hex: "#111111")!))
        XCTAssertEqual(light.keyText, Theme.nearBlack)
        XCTAssertEqual(light.label, Theme.nearBlack)
        XCTAssertEqual(light.mark, Theme.nearBlack)
        XCTAssertEqual(light.name, Theme.customName)
    }

    /// the five presets' own text contrast (section 8: 4.5:1 or more)
    func testPresetContrast() {
        for p in ThemeTokens.bundled.presets {
            XCTAssertGreaterThanOrEqual(p.keyText.contrast(p.key), 4.5, p.name)
            XCTAssertGreaterThanOrEqual(p.label.contrast(p.body), 4.5, p.name)
        }
    }

    @MainActor func testStoreKeepsTheChoice() throws {
        let suite = "rfm1.tests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let s = ThemeStore(defaults: d, override: nil)
        XCTAssertEqual(s.current.name, "Tangerine")
        s.select("Mint")
        XCTAssertEqual(ThemeStore(defaults: d, override: nil).current.name, "Mint")
        var c = Theme.derived(s.presets[1].choice, base: s.presets[1])
        c.led = RGB(hex: "#00FF00")!
        s.saveCustom(c)
        let again = ThemeStore(defaults: d, override: nil)
        XCTAssertEqual(again.current.name, Theme.customName)
        XCTAssertEqual(again.current.led.hex, "#00FF00")
        XCTAssertEqual(again.all.count, 6)
        XCTAssertEqual(ThemeStore(defaults: d, override: "Lilac").current.name, "Lilac")
    }

    func testFontsRegister() {
        RFMFonts.register()
        for n in [RFMFonts.hardwareName, RFMFonts.monoName] { XCTAssertTrue(RFMFonts.available(n), n) }
        XCTAssertEqual(CTFontCopyFamilyName(RFMFonts.variable(RFMFonts.uiName, size: 14, weight: 600, opsz: true)) as String,
                       "DM Sans")
        XCTAssertEqual(CTFontCopyFamilyName(RFMFonts.variable(RFMFonts.titleName, size: 22, weight: 700, opsz: false))
                       as String, "Unbounded")
    }
}

final class KeybedGeometryTests: XCTestCase {
    func check(_ g: KeybedGeometry, _ what: String) {
        let nat = g.keys.filter(\.natural), sharp = g.keys.filter { !$0.natural }
        XCTAssertEqual(nat.count, 16, what)
        XCTAssertEqual(sharp.count, 11, what)
        XCTAssertEqual(Set(g.keys.map(\.index)), Set(0..<27), "\(what): every key 0...26 once")
        XCTAssertEqual(nat.map(\.step), Array(0..<16), what)
        for s in sharp {
            let below = nat.first { $0.index == s.index - 1 }!, above = nat.first { $0.index == s.index + 1 }!
            let gapCentre = (below.rect.maxX + above.rect.minX) / 2
            XCTAssertEqual(s.rect.midX, gapCentre, accuracy: 0.01, "\(what): \(PanelEvent.keyName(s.index)) on its gap")
            XCTAssertEqual(s.rect.width, below.rect.width * 0.86, accuracy: 0.01, what)
            XCTAssertLessThan(s.rect.maxY, below.rect.minY, "\(what): the sharps' row is above the naturals'")
        }
        // naturals evenly spaced by the pitch, no overlaps
        for i in 1..<16 {
            XCTAssertEqual(nat[i].rect.minX - nat[i - 1].rect.minX, g.pitch, accuracy: 0.01, what)
            XCTAssertGreaterThan(nat[i].rect.minX, nat[i - 1].rect.maxX, what)
        }
        // no sharp between B and C or E and F
        for n in ["B3", "E4", "B4", "E5"] {
            let k = (0..<27).first { PanelEvent.keyName($0) == n }!
            XCTAssertFalse(sharp.contains { $0.index == k + 1 }, "\(what): no sharp after \(n)")
        }
        // a touch in the middle of each key finds it
        for k in g.keys where g.layout == .row || k.rect.maxX <= g.stage.width {   // (scroll: the keys in view)
            let c = CGPoint(x: k.rect.midX + (g.layout == .row ? 0 : g.stage.minX + g.shift(0)),
                            y: k.rect.midY + (g.layout == .row ? 0 : g.stage.minY))
            XCTAssertEqual(g.key(at: c)?.index, k.index, "\(what): hit \(k.index)")
        }
    }

    func testRowLayouts() {
        // the canvas's row keybeds: iPhone landscape, iPad landscape, iPad portrait, the Keys part
        for (w, h) in [(744.0, 170.0), (1098.0, 362.0), (754.0, 476.0), (800.0, 220.0)] {
            let g = KeybedGeometry(size: CGSize(width: w, height: h), layout: .row)
            check(g, "row \(w)x\(h)")
            let nat = g.keys.filter(\.natural)
            XCTAssertEqual(nat.first!.rect.minX, g.pad, accuracy: 0.01)
            XCTAssertEqual(nat.last!.rect.maxX, w - g.pad, accuracy: 0.01, "the naturals fill the width")
        }
        // Keys.dc.html at 800 x 220: pad 11, gap 6, pitch (800 - 22 + 6) / 16 = 49, sharps 40% of the row (79)
        let g = KeybedGeometry(size: CGSize(width: 800, height: 220), layout: .row)
        XCTAssertEqual(g.pad, 11)
        XCTAssertEqual(g.gap, 6)
        XCTAssertEqual(g.pitch, 49)
        XCTAssertEqual(g.keys.first { !$0.natural }!.rect.height, 79)
        XCTAssertEqual(g.radius, 18)
    }

    func testScrollLayout() {
        // iPhone portrait: 358 x 272, naturals 40 pt
        let g = KeybedGeometry(size: CGSize(width: 358, height: 272), layout: .scroll(keyWidth: 40))
        check(g, "scroll")
        XCTAssertEqual(g.gap, 3)
        XCTAssertEqual(g.pitch, 43)
        XCTAssertEqual(g.stripHeight, 30)
        XCTAssertEqual(g.visible, (358 - 2 * g.pad + 3) / 43, accuracy: 0.001)
        XCTAssertEqual(g.maxOffset, 16 - g.visible, accuracy: 0.001)
        XCTAssertEqual(g.defaultOffset, 4)
        // a scrolled keybed: the key under a point moves with the offset
        let p = CGPoint(x: g.stage.minX + 20, y: g.stage.maxY - 10)
        XCTAssertEqual(g.key(at: p, offset: 0)?.index, 0)            // F3
        XCTAssertEqual(g.key(at: p, offset: 4)?.index, 7)            // C4
        XCTAssertNil(g.key(at: CGPoint(x: 30, y: g.pad + 5)), "the strip is not a key")
        XCTAssertEqual(g.stripIndex(atX: g.stripCell(9).midX), 9)
        XCTAssertEqual(g.offset(centering: 0), 0)
        XCTAssertEqual(g.offset(centering: 15), g.maxOffset, accuracy: 0.001)
    }

    func testSpokenNames() {
        XCTAssertEqual(KeybedGeometry.spokenName(0), "F3")
        XCTAssertEqual(KeybedGeometry.spokenName(8), "C sharp 4")
        XCTAssertEqual(KeybedGeometry.spokenName(26), "G5")
    }
}

final class FaceplateLayoutTests: XCTestCase {
    func testPick() {
        XCTAssertEqual(FaceplateLayout.Kind.pick(CGSize(width: 390, height: 844)), .phonePortrait)
        XCTAssertEqual(FaceplateLayout.Kind.pick(CGSize(width: 402, height: 874)), .phonePortrait)
        XCTAssertEqual(FaceplateLayout.Kind.pick(CGSize(width: 874, height: 402)), .phoneLandscape)
        XCTAssertEqual(FaceplateLayout.Kind.pick(CGSize(width: 1194, height: 834)), .padLandscape)
        XCTAssertEqual(FaceplateLayout.Kind.pick(CGSize(width: 834, height: 1194)), .padPortrait)
    }

    /// the mapping reproduces the canvas's frames at the reference sizes and scales with the screen
    func testMapping() {
        let m = FaceplateLayout.Mapper(ref: CGSize(width: 390, height: 844), size: CGSize(width: 390, height: 844))
        XCTAssertEqual(m.rect(16, 530, 358, 272), CGRect(x: 16, y: 530, width: 358, height: 272))
        let m2 = FaceplateLayout.Mapper(ref: CGSize(width: 390, height: 844), size: CGSize(width: 780, height: 1688))
        XCTAssertEqual(m2.rect(16, 530, 358, 272), CGRect(x: 32, y: 1060, width: 716, height: 544))
        XCTAssertEqual(m2.s, 2)
    }
}

/// a core on the caller's clock, played through PanelFeed (the on-screen path)
final class TestEngineHost: PanelEngineHost {
    let core: TestCore
    init(_ c: TestCore) { core = c }
    func withPanelEngine<R>(_ body: (OpaquePointer) -> R) -> R { body(core.e) }
}

final class OnScreenInputTests: XCTestCase {
    override func setUpWithError() throws {
        let dir = CoreTests.coresDir
        guard FileManager.default.fileExists(atPath: dir) else {
            throw XCTSkip("no macOS core builds in \(dir): run scripts/build_cores.sh macos")
        }
        _ = rfms_scan(dir)
    }

    /// a touch-down on key k reaches the core (it holds k, and plays), its LED comes back; buttons by label, encoder
    /// detents by role and MASTER reach it too and come back in the snapshot
    @MainActor func testTouchesReachTheCoreAndLightsComeBack() throws {
        for id in CoreTests.ids {
            let c = try TestCore(id)
            c.boot()
            c.run(1500)
            for k in CoreTests.stepPrelude[id] ?? [] {      // (LOOM-8: four kicks written, then PLAY)
                c.key(k, true)
                c.run(60)
                c.key(k, false)
                c.run(100)
            }
            if let b = CoreTests.keyPrelude[id] {           // (FIZZ: REC makes the keys a keyboard)
                c.button(b, true)
                c.run(60)
                c.button(b, false)
                c.run(100)
            }
            let host = TestEngineHost(c)
            let feed = PanelFeed(host: host)
            feed.poll()
            XCTAssertTrue(feed.lights.booted, id)
            let k = CoreTests.keyD4
            let before = feed.lights.keys[k]
            feed.keyDown(k)
            feed.keyDown(k)                                 // (a second finger on it: still one press)
            let a = c.run(300)
            feed.poll()
            XCTAssertNotEqual(feed.lights.heldKeys & (1 << UInt32(k)), 0, "\(id): the core holds key \(k)")
            XCTAssertEqual(c.status.keys_pressed, 1 + UInt32(CoreTests.stepPrelude[id]?.count ?? 0), id)
            XCTAssertGreaterThan(a.peak, 64, "\(id): the touched key sounds")
            let lit = feed.lights.keys[k]
            print("faceplate \(id): key \(k) LED \(before) -> \(lit) while held; buttons \(feed.lights.buttons)")
            feed.keyUp(k)
            c.run(50)
            feed.poll()
            XCTAssertNotEqual(feed.lights.heldKeys & (1 << UInt32(k)), 0, "\(id): one finger still on it")
            feed.keyUp(k)
            c.run(300)
            feed.poll()
            XCTAssertEqual(feed.lights.heldKeys & (1 << UInt32(k)), 0, "\(id): released")
            if id == "felucca" || id == "choralroot" {
                XCTAssertGreaterThan(lit, before, "\(id): the held key's LED came back lit")
            }

            // knobs: detents clockwise by role, MASTER absolute
            let t0 = feed.knobs.turns[PanelFeed.Knob.k1.rawValue]
            feed.turn(.k1, 3)
            c.run(50)
            feed.poll()
            XCTAssertEqual(feed.knobs.turns[PanelFeed.Knob.k1.rawValue], t0 + 3, id)
            Thread.sleep(forTimeInterval: PanelFeed.localHold + 0.05)
            c.run(20)
            feed.poll()
            var p = rfme_panel_t()
            rfme_panel(c.e, &p)
            XCTAssertEqual(withUnsafeBytes(of: p.enc) { $0.bindMemory(to: Int32.self)[PanelFeed.Knob.k1.rawValue] }, t0 + 3,
                           "\(id): the engine counted three clockwise detents")
            feed.master(500)
            c.run(50)
            rfme_panel(c.e, &p)
            XCTAssertEqual(p.master, 500, id)

            // a button by label: held in the core while pressed
            feed.button(.home, down: true)
            c.run(50)
            feed.poll()
            XCTAssertNotEqual(feed.lights.heldLabels & (1 << UInt32(PanelFeed.Label.home.rawValue)), 0, id)
            feed.button(.home, down: false)
            c.run(50)
            feed.poll()
            XCTAssertEqual(feed.lights.heldLabels, 0, id)
            XCTAssertEqual(c.status.halted, 0, id)
        }
    }

    /// the snapshot is quiet when nothing changes, and says when the core is gone
    @MainActor func testSnapshotSeq() throws {
        let c = try TestCore("felucca")
        c.boot()
        c.run(2000)
        var p = rfme_panel_t()
        let s1 = rfme_panel(c.e, &p)
        XCTAssertGreaterThan(s1, 0)
        XCTAssertEqual(p.booted, 1)
        XCTAssertEqual(rfme_panel(c.e, &p), s1, "no new state without a clock run")
        rfme_unload(c.e)
        rfme_panel(c.e, &p)
        XCTAssertEqual(p.booted, 0)
    }
}
