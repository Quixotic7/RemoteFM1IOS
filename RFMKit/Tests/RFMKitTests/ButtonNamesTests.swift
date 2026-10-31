// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The firmware's own button names (RemoteFM1 docs/BUTTON-LABELS.md): the drawing rules (ButtonNames), the names read
// from a running core through the engine (the echo test core's, the macOS builds of the native cores', .rfm1 files'),
// the setting, and the faceplate's feed following a core change.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class ButtonNamesTests: XCTestCase {
    static let printed = ["FX", "SEL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE", "ARP", "SEQ", "PLAY", "REC",
                          "OCT−", "OCT+"]

    func testRules() {
        XCTAssertEqual(ButtonNames.standard.labels, Self.printed)
        XCTAssertFalse(ButtonNames.standard.anyRenamed)
        XCTAssertEqual(ButtonNames(firmware: nil).labels, Self.printed)
        XCTAssertEqual(ButtonNames(firmware: ["KEY", "PERF"]).labels, Self.printed, "not 14: all printed")
        XCTAssertEqual(ButtonNames(firmware: [String?](repeating: "X", count: 15)).labels, Self.printed)

        var fw = [String?](repeating: nil, count: 14)
        fw[1] = "key"; fw[2] = ""; fw[3] = "  \t"; fw[4] = "EDIT"; fw[8] = "  Perf "; fw[12] = "DOWN"; fw[13] = "UP"
        let n = ButtonNames(firmware: fw)
        XCTAssertEqual(n.label(.sel), "KEY")
        XCTAssertTrue(n.isRenamed(.sel))
        XCTAssertEqual(n.label(.env), "ENV")
        XCTAssertEqual(n.label(.lfo), "LFO", "blank: printed")
        XCTAssertEqual(n.label(.edit), "EDIT")
        XCTAssertFalse(n.isRenamed(.edit), "its own printed name: no small label")
        XCTAssertEqual(n.label(.arp), "PERF", "trimmed, upper-cased")
        XCTAssertEqual(n.label(.octDown), "OCT−", "OCT is never renamed")
        XCTAssertEqual(n.label(.octUp), "OCT+")
        XCTAssertFalse(n.isRenamed(.octDown))
        XCTAssertEqual(n.renamed.filter { $0 }.count, 2)

        let off = ButtonNames(firmware: fw, use: false)
        XCTAssertEqual(off.labels, Self.printed, "the setting off")
        XCTAssertFalse(off.anyRenamed)

        XCTAssertEqual(n.title("ARP"), "PERF (ARP)")
        XCTAssertEqual(n.title("EDIT"), "EDIT")
        XCTAssertEqual(n.title("KN1"), "KN1")
        XCTAssertEqual(MidiLearnMode.barText(selected: "SEL", sources: [], names: n),
                       "KEY (SEL): now press a button or a key on your MIDI device")
    }

    func testEchoCoreThroughTheEngine() {
        let e = rfme_new(nil)!
        defer { rfme_free(e) }
        let g0 = rfme_button_names_gen(e)
        XCTAssertEqual(ButtonNames.read(e).names, .standard, "no core")
        XCTAssertEqual(rfme_test_load_echo(e), 1)
        XCTAssertNotEqual(rfme_button_names_gen(e), g0, "a core change moves it")
        let n = ButtonNames.read(e).names
        XCTAssertEqual(n.label(.sel), "KEY")
        XCTAssertEqual(n.label(.arp), "PERF")
        XCTAssertEqual(n.label(.play), "LOOPER-LONG")
        XCTAssertEqual(n.label(.fx), "FX")
        XCTAssertEqual(n.label(.env), "ENV")
        XCTAssertFalse(n.isRenamed(.edit))
        XCTAssertEqual(n.label(.octDown), "OCT−")

        let g1 = rfme_button_names_gen(e)
        rfme_set_button_names(e, 0)
        XCTAssertNotEqual(rfme_button_names_gen(e), g1, "the setting moves it")
        XCTAssertEqual(ButtonNames.read(e).names, .standard)
        let g2 = rfme_button_names_gen(e)
        rfme_set_button_names(e, 0)
        XCTAssertEqual(rfme_button_names_gen(e), g2, "the same setting again: no change")
        rfme_set_button_names(e, 1)
        XCTAssertEqual(ButtonNames.read(e).names, n)
    }

    @MainActor func testFeedFollowsTheCore() throws {
        let player = CorePlayer(link: nil, slotsDir: "/nonexistent", midiDefaults: UserDefaults(suiteName: "bn-\(UUID())")!)
        let feed = PanelFeed(host: player)
        
        feed.pollNames()
        XCTAssertEqual(feed.names.value, ButtonNames.standard)
        XCTAssertEqual(rfme_test_load_echo(player.e), 1)
        feed.pollNames()
        XCTAssertEqual(feed.names.value.label(.sel), "KEY")
        player.midiSettings.buttonNames = false
        feed.pollNames()
        XCTAssertEqual(feed.names.value, ButtonNames.standard)
        XCTAssertEqual(AUSettings(player.midiSettings.dict).buttonNames, false, "kept with the settings")
        XCTAssertEqual(AUSettings(nil).buttonNames, true, "on by default")
    }

    /// the macOS builds of the native cores (scripts/build_cores.sh macos): each one's names, printed for the record;
    /// ChoralRoot's full build renames SEL and ARP
    func testNativeCores() throws {
        let dir = CoreTests.coresDir
        guard FileManager.default.fileExists(atPath: dir) else { throw XCTSkip("no macOS core builds in \(dir)") }
        rfms_scan(dir)
        for id in CoreTests.ids {
            let c = try TestCore(id)
            let n = ButtonNames.read(c.e).names
            print("button names \(id): \(n.labels.enumerated().map { n.renamed[$0.offset] ? $0.element : "-" })")
            if id == "choralroot" {
                XCTAssertEqual(n.label(.sel), "KEY")
                XCTAssertEqual(n.label(.arp), "PERF")
            }
        }
    }

    /// .rfm1 files: the names read from the module's memory through rfm1_layout (the fixture, and FM1VST's build of
    /// the others when it is there)
    func testWasmCores() throws {
        var paths = [RFM1Files.amb]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: RFM1Files.dir) {
            paths += names.sorted().filter { $0.hasSuffix(".rfm1") && $0 != "amb-1.3.rfm1" }
                .map { (RFM1Files.dir as NSString).appendingPathComponent($0) }
        }
        for path in paths {
            let e = rfme_new(nil)!
            defer { rfme_free(e) }
            var err = [CChar](repeating: 0, count: 256)
            guard rfme_load_wasm(e, path, &err, 256) == 1 else {
                print("button names \((path as NSString).lastPathComponent): not loaded: \(cstr(err))")
                continue
            }
            let n = ButtonNames.read(e).names
            print("button names \((path as NSString).lastPathComponent): "
                  + "\(n.labels.enumerated().map { n.renamed[$0.offset] ? $0.element : "-" })")
            XCTAssertEqual(n.labels.count, 14)
            if path.hasSuffix("/choralroot-0.26.1.rfm1") {
                XCTAssertEqual(n.label(.sel), "KEY")
                XCTAssertEqual(n.label(.arp), "PERF")
            }
        }
    }
}
