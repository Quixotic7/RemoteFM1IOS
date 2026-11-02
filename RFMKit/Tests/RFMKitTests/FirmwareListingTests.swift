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

    func testSupersededBuiltInsHidden() {
        let cores = [core("choralroot", "choralroot", "0.26", wasm: false), core("felucca", "felucca", "1.6.1", wasm: false),
                     core("rfm1:choralroot", "choralroot", "0.29", wasm: true),
                     core("rfm1:felucca", "felucca", "1.6.1", wasm: true)]
        XCTAssertEqual(FirmwareListing.superseded(cores), ["choralroot"], "only a strictly newer import hides a built-in")
        XCTAssertEqual(FirmwareListing.visible(cores, selected: "felucca").map(\.id), ["felucca", "rfm1:choralroot", "rfm1:felucca"])
        XCTAssertEqual(FirmwareListing.visible(cores, selected: "choralroot").count, 4, "the selected one stays listed")
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

    func testHeadroomGrowsOnDropouts() {
        var g = PerfGuard()
        var s = CoreStatus()
        s.kind = "wasm"; s.booted = true; s.rate = 48000; s.coreID = "rainbow"
        s.coreWakes = 100; s.coreAvgUs = 100; s.coreFrames = 48000
        var t = Date(timeIntervalSince1970: 0)
        _ = g.update(s, name: "Rainbow Mode", now: t)
        XCTAssertEqual(g.headroomUs, PerfGuard.defaultHeadroomUs)
        var notes: [String] = []
        for _ in 0..<5 {                                      // 40 % load, 20 dropouts each window
            t += 2
            s.coreWakes += 1000; s.coreFrames += 96000; s.coreAvgUs = 800; s.underruns += 20
            notes.append(g.update(s, name: "Rainbow Mode", now: t))
        }
        XCTAssertEqual(g.headroomUs, PerfGuard.maxHeadroomUs)
        XCTAssertEqual(notes.prefix(3), ["", "", ""], "more headroom first, no note")
        XCTAssertTrue(notes.last!.contains("too heavy"), "still dropping out at the most headroom: the note")
        s.coreID = "choralroot"                               // (another firmware: back to the default)
        _ = g.update(s, name: "ChoralRoot", now: t + 2)
        XCTAssertEqual(g.headroomUs, PerfGuard.defaultHeadroomUs)
    }
}
