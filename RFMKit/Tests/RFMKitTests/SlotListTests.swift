// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Build 7: an appex on a Mac can't list the containing app's Frameworks, so the slot loader also opens the slots its
// FM1CoreSlots.txt names, by path (rfms_scan_list); and the app's copy of its slots for the App Group (CoreSlotMirror).
// On the macOS core builds (CoreTests.coresDir); skipped without them.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class SlotListTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        guard FileManager.default.fileExists(atPath: CoreTests.coresDir) else {
            throw XCTSkip("no macOS core builds in \(CoreTests.coresDir): run scripts/build_cores.sh macos")
        }
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rfm-slotlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        _ = rfms_scan(CoreTests.coresDir)                  // (the other tests' registry)
    }

    private func real(_ name: String) -> URL { URL(fileURLWithPath: CoreTests.coresDir).appendingPathComponent(name) }

    func testListFindsSlotsByPathOnly() throws {
        let fm = FileManager.default
        // fizz 1: the framework (a link); fizz 2: its binary in the Versions/Current form; loom 1: there but not listed
        try fm.createSymbolicLink(at: tmp.appendingPathComponent("FM1Core_fizz_1.framework"),
                                  withDestinationURL: real("FM1Core_fizz_1.framework"))
        let v = tmp.appendingPathComponent("FM1Core_fizz_2.framework/Versions/Current")
        try fm.createDirectory(at: v, withIntermediateDirectories: true)
        try fm.copyItem(at: real("FM1Core_fizz_2.framework/FM1Core_fizz_2"), to: v.appendingPathComponent("FM1Core_fizz_2"))
        try fm.createSymbolicLink(at: tmp.appendingPathComponent("FM1Core_loom_1.framework"),
                                  withDestinationURL: real("FM1Core_loom_1.framework"))
        let list = """
            # the core slots the app embeds (store build), scripts/embed_cores.sh --list
            FM1Core_fizz_1.framework
              FM1Core_fizz_2.framework\t
            FM1Core_boardwalk_1.framework
            not-a-slot.framework

            """
        XCTAssertEqual(rfms_scan_list(tmp.path, list), 1, CoreTests.text(rfms_errors))
        XCTAssertEqual(CoreTests.text(rfms_source), "list file")
        var i = rfms_info_t()
        XCTAssertEqual(rfms_find("fizz", &i), 1)
        XCTAssertEqual(i.slots, 2)
        XCTAssertEqual(rfms_find("loom", &i), 0, "a slot the list doesn't name was found")
        // a listed slot that isn't there: kept unchecked, its dlopen error recorded
        let errors = CoreTests.text(rfms_errors)
        XCTAssertTrue(errors.contains("FM1Core_boardwalk_1.framework/FM1Core_boardwalk_1"), errors)

        // both slots play (the second by its Versions/Current path)
        let a = try TestCore("fizz"), b = try TestCore("fizz")
        XCTAssertEqual(rfms_find("fizz", &i), 1)
        XCTAssertEqual(i.in_use, 2)
        _ = (a, b)
    }

    func testDirScanSaysSo() {
        XCTAssertGreaterThan(rfms_scan(CoreTests.coresDir), 0)
        XCTAssertEqual(CoreTests.text(rfms_source), "dir listing")
        XCTAssertEqual(rfms_scan_list(tmp.path, ""), 0)
    }

    func testMirrorCopiesWhenChanged() throws {
        let fm = FileManager.default
        let from = tmp.appendingPathComponent("Frameworks"), to = tmp.appendingPathComponent("CoreSlots")
        try fm.createDirectory(at: from, withIntermediateDirectories: true)
        for n in ["FM1Core_fizz_1.framework", "FM1Core_fizz_2.framework"] {
            try fm.copyItem(at: real(n), to: from.appendingPathComponent(n))
        }
        try fm.createDirectory(at: to.appendingPathComponent("FM1Core_old_1.framework"), withIntermediateDirectories: true)
        XCTAssertEqual(CoreSlotMirror.sync(from: from, to: to, build: "7"), 2)
        XCTAssertFalse(fm.fileExists(atPath: to.appendingPathComponent("FM1Core_old_1.framework").path), "a stale slot stayed")
        XCTAssertEqual(CoreSlotMirror.sync(from: from, to: to, build: "7"), 0, "copied again with nothing changed")
        XCTAssertEqual(CoreSlotMirror.sync(from: from, to: to, build: "8"), 2, "a new build wasn't copied")
        try fm.removeItem(at: from.appendingPathComponent("FM1Core_fizz_2.framework"))
        XCTAssertEqual(CoreSlotMirror.sync(from: from, to: to, build: "8"), 1)
        XCTAssertFalse(fm.fileExists(atPath: to.appendingPathComponent("FM1Core_fizz_2.framework").path))
        // the copy is what the AU scans
        XCTAssertEqual(rfms_scan(to.path), 1, CoreTests.text(rfms_errors))
        var i = rfms_info_t()
        XCTAssertEqual(rfms_find("fizz", &i), 1)
        XCTAssertEqual(i.slots, 1)
    }
}
