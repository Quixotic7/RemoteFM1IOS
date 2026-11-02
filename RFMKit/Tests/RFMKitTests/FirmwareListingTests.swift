// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The firmware lists (superseded built-ins, sorting), the release dates, and the Wasm core's growing headroom.

import XCTest
@testable import RFMKit

final class FirmwareListingTests: XCTestCase {
    private func core(_ id: String, _ fw: String, _ v: String, wasm: Bool) -> CoreInfo {
        var c = CoreInfo(id: id)
        c.coreID = fw
        c.name = fw
        c.version = v
        c.kind = wasm ? "wasm" : "native"
        return c
    }

    func testOnlyTheNewestVersionListed() {
        let cores = [core("choralroot", "choralroot", "0.26", wasm: false), core("felucca", "felucca", "1.6.1", wasm: false),
                     core("rfm1:choralroot@0.28", "choralroot", "0.28", wasm: true),
                     core("rfm1:choralroot@0.29", "choralroot", "0.29", wasm: true),
                     core("rfm1:felucca", "felucca", "1.6.1", wasm: true),
                     core("rfm1:rainbow@1.1.4", "rainbow", "1.1.4", wasm: true),
                     core("rfm1:rainbow@1.1.5", "rainbow", "1.1.5-rb", wasm: true)]
        XCTAssertEqual(FirmwareListing.superseded(cores),
                       ["choralroot", "rfm1:choralroot@0.28", "rfm1:felucca", "rfm1:rainbow@1.1.4"],
                       "older versions, and an import the same as the built-in")
        XCTAssertEqual(FirmwareListing.visible(cores, selected: "felucca").map(\.id),
                       ["felucca", "rfm1:choralroot@0.29", "rfm1:rainbow@1.1.5"])
        XCTAssertEqual(FirmwareListing.visible(cores, selected: "rfm1:choralroot@0.28").count, 4, "the selected one stays listed")
        // a rebuild of the same version (RemoteFM1FW keeps the version): the one added last is listed
        var r1 = core("rfm1:rb-old", "rainbow", "1.1.5-rb", wasm: true), r2 = core("rfm1:rb-new", "rainbow", "1.1.5-rb", wasm: true)
        r1.sha256 = "old"; r2.sha256 = "new"
        let added = ["old": Date(timeIntervalSince1970: 1), "new": Date(timeIntervalSince1970: 2)]
        XCTAssertEqual(FirmwareListing.visible([r1, r2], selected: "", added: added).map(\.id), ["rfm1:rb-new"])
        XCTAssertEqual(FirmwareListing.visible([r2, r1], selected: "", added: added).map(\.id), ["rfm1:rb-new"])
    }

    func testSorting() {
        let d = UserDefaults(suiteName: "listing-\(UUID().uuidString)")!
        let cores = [core("a", "a", "1", wasm: false), core("b", "b", "1", wasm: false), core("c", "c", "1", wasm: false)]
        FirmwareListing.used(cores[2], at: Date(timeIntervalSince1970: 100), defaults: d)
        FirmwareListing.used(cores[1], at: Date(timeIntervalSince1970: 200), defaults: d)
        XCTAssertEqual(FirmwareListing.sorted(cores, by: .used, updated: { _ in nil }, defaults: d).map(\.id), ["b", "c", "a"])
        let dates = ["a": Date(timeIntervalSince1970: 50), "c": Date(timeIntervalSince1970: 60)]
        XCTAssertEqual(FirmwareListing.sorted(cores, by: .updated, updated: { dates[$0] }, defaults: d).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(FirmwareListing.sorted(cores, by: .name, updated: { dates[$0] }, defaults: d).map(\.id), ["a", "b", "c"])
    }

    func testReleaseDates() throws {
        func release(_ tag: String, _ at: String, _ names: [String]) -> [String: Any] {
            ["tag_name": tag, "draft": false, "published_at": at,
             "assets": names.map { ["name": $0, "size": 10, "browser_download_url": "https://github.com/x/\(tag)/\($0)"] }]
        }
        let list = [release("c", "2026-11-01T20:00:00Z", ["choralroot-0.29.rfm1", "amb-1.3.rfm1"]),
                    release("b", "2026-10-20T10:00:00Z", ["choralroot-0.28.rfm1", "amb-1.3.rfm1"]),
                    release("a", "2026-10-01T10:00:00Z", ["choralroot-0.26.1.rfm1"])]
        let v = try FeedSnapshot.versions(JSONSerialization.data(withJSONObject: list), feed: "test")
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(v["choralroot"]?.first?.released, iso.date(from: "2026-11-01T20:00:00Z"))
        XCTAssertEqual(v["amb"]?.first?.released, iso.date(from: "2026-10-20T10:00:00Z"), "the first release with that version")
        XCTAssertEqual(v["amb"]?.first?.downloads.first?.url.absoluteString, "https://github.com/x/c/amb-1.3.rfm1")
        // (survives the cache)
        let enc = JSONEncoder(), dec = JSONDecoder()
        enc.dateEncodingStrategy = .iso8601
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(AvailableFirmware.self, from: enc.encode(v["amb"]!.first!))
        XCTAssertEqual(back.released, v["amb"]?.first?.released)
    }

    func testHeadroomAndScreenOnDropouts() {
        var g = PerfGuard()
        var s = CoreStatus()
        s.kind = "wasm"; s.booted = true; s.rate = 48000; s.coreID = "rainbow"
        s.coreWakes = 100; s.coreAvgUs = 100; s.coreFrames = 48000
        var t = Date(timeIntervalSince1970: 0)
        _ = g.update(s, name: "Rainbow Mode", now: t)
        XCTAssertEqual(g.headroomUs, PerfGuard.wasmHeadroomUs, "a Wasm core starts with more headroom")
        XCTAssertEqual(g.frameMs, 33, "and a 30 fps screen")
        var notes: [String] = [], frames: [UInt32] = []
        for _ in 0..<4 {                                      // 40 % load, 20 dropouts each window
            t += 2
            s.coreWakes += 1000; s.coreFrames += 96000; s.coreAvgUs = 800; s.underruns += 20
            notes.append(g.update(s, name: "Rainbow Mode", now: t))
            frames.append(g.frameMs)
        }
        XCTAssertEqual(frames, [50, 66, 66, 66])
        XCTAssertEqual(g.headroomUs, PerfGuard.maxHeadroomUs)
        XCTAssertEqual(notes.prefix(2), ["", ""], "more headroom and a slower screen first, no note")
        XCTAssertTrue(notes.last!.contains("too heavy"), "still dropping out with nothing left: the note")

        s.coreID = "choralroot"                               // another Wasm firmware: its own start
        _ = g.update(s, name: "ChoralRoot", now: t + 2)
        XCTAssertEqual(g.headroomUs, PerfGuard.wasmHeadroomUs)
        XCTAssertEqual(g.frameMs, 33)
        s.coreID = "rainbow"                                  // back: what it needed, kept
        _ = g.update(s, name: "Rainbow Mode", now: t + 4)
        XCTAssertEqual(g.headroomUs, PerfGuard.maxHeadroomUs)
        XCTAssertEqual(g.frameMs, 66)
        s.kind = "native"; s.coreID = ""                      // a built-in core: the defaults
        _ = g.update(s, name: "FIZZ", now: t + 6)
        XCTAssertEqual(g.headroomUs, PerfGuard.defaultHeadroomUs)
        XCTAssertEqual(g.frameMs, PerfGuard.defaultFrameMs)
    }

    /// RemoteFM1FW's catalog may give a firmware's editor and its USB MIDI port name; they win over the site's
    func testCatalogEditorAndPort() throws {
        let site = Data(#"{"firmwares":[{"id":"mutabledreams","name":"Mutable Dreams"},{"id":"felucca","name":"Felucca","editor":"https://hugelton.github.io/Felucca/webapp/editor/"}]}"#.utf8)
        let cat = Data(#"{"schema":1,"firmwares":{"mutabledreams":{"editor":"https://mutable-dreams.kidbee85.chatgpt.site/#device-editor","port":"Mutable Dreams FM-1"},"rainbow":{"editor":"http://insecure.example/"}}}"#.utf8)
        let d = FeedSnapshot.details([try FeedSnapshot.parse(site, feed: .remotefm1), try FeedSnapshot.parse(cat, feed: .fwCatalog)])
        XCTAssertEqual(d["mutabledreams"]?.editor, "https://mutable-dreams.kidbee85.chatgpt.site/#device-editor")
        XCTAssertEqual(ManagerList.port(for: "mutabledreams", name: "x", details: d), "Mutable Dreams FM-1")
        XCTAssertEqual(d["felucca"]?.editor, "https://hugelton.github.io/Felucca/webapp/editor/", "the site's, when the catalog has none")
        XCTAssertEqual(d["rainbow"]?.editor ?? "", "", "https only")
        XCTAssertEqual(ManagerList.port(for: "felucca", name: "Felucca", details: d), "Felucca", "the app's list")
    }
}
