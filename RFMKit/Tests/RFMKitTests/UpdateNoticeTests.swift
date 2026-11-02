// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The launch notice: a newer build, firmware updates, closed once per set.

import XCTest
@testable import RFMKit

final class UpdateNoticeTests: XCTestCase {
    func testNotice() throws {
        let latest = LatestBuild(build: 20, version: "0.1", url: "https://testflight.apple.com/join/e6A47Xap")
        XCTAssertNil(UpdateNotice.make(build: 20, latest: latest, updates: []), "nothing new")
        XCTAssertNil(UpdateNotice.make(build: 21, latest: latest, updates: []), "newer than the file (a local build)")
        XCTAssertNil(UpdateNotice.make(build: 19, latest: nil, updates: []), "offline")
        let n = try XCTUnwrap(UpdateNotice.make(build: 19, latest: latest, updates: [("JIANT", "10.26"), ("Rainbow Mode", "1.1.5-rb"),
                                                                                      ("AMB-1", "1.4"), ("Felucca", "1.8.1")]))
        XCTAssertEqual(n.newBuild, 20)
        XCTAssertEqual(n.url?.host, "testflight.apple.com")
        XCTAssertEqual(n.message(current: 19), "Build 20 is on TestFlight; you have build 19. Please update before sending "
                       + "feedback.\n\nUpdates for AMB-1, Felucca, JIANT and 1 more in Get firmware.")
        XCTAssertEqual(UpdateNotice.make(build: 20, latest: latest, updates: [("Ripple", "0.5"), ("DUELL", "1.1")])?.message(current: 20),
                       "Updates for DUELL and Ripple in Get firmware.")
        let fw = try XCTUnwrap(UpdateNotice.make(build: 20, latest: latest, updates: [("Ripple", "0.5")]))
        XCTAssertNil(fw.newBuild)
        XCTAssertEqual(fw.title, "Firmware updates")
        // closed: not again for the same set; again when something newer comes
        let d = UserDefaults(suiteName: "notice-\(UUID().uuidString)")!
        XCTAssertFalse(n.dismissed(d))
        n.dismiss(d)
        XCTAssertTrue(n.dismissed(d))
        XCTAssertTrue(try XCTUnwrap(UpdateNotice.make(build: 19, latest: latest, updates: [("JIANT", "10.26"), ("Rainbow Mode", "1.1.5-rb"),
                                                                                          ("Felucca", "1.8.1"), ("AMB-1", "1.4")])).dismissed(d),
                      "the same set in another order")
        XCTAssertFalse(try XCTUnwrap(UpdateNotice.make(build: 19, latest: LatestBuild(build: 21), updates: [])).dismissed(d))
        XCTAssertEqual(try JSONDecoder().decode(LatestBuild.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../release/ios.json").standardized)).url,
                       "https://testflight.apple.com/join/e6A47Xap")
    }
}
