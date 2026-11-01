// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Moving states to another device: the .rfm1transfer file (made, read back, a damaged one refused, imported into a
// fresh device with its firmware file) and the older versions read from GitHub's releases.

import Foundation
import XCTest
@testable import RFMKit

@MainActor
final class TransferTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rfm1-xfer-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func device(_ n: String) -> (StateLibrary, FirmwareLibrary) {
        let d = root.appendingPathComponent(n), mirror = d.appendingPathComponent("mirror")
        let fw = FirmwareLibrary(folder: d.appendingPathComponent("Firmware"), mirror: mirror, catalog: FirmwareCatalog(dir: mirror))
        fw.sync()
        return (StateLibrary(root: d.appendingPathComponent("States")), fw)
    }

    func testMakeReadAndImport() throws {
        let (states, fw) = device("iphone")
        let amb = try fw.importFile(URL(fileURLWithPath: RFM1Files.amb))
        XCTAssertNil(amb.error)
        let flash = Data((0..<4096).map { UInt8($0 & 0xFF) })
        _ = try states.save(name: "Pads", firmwareID: "amb", firmwareName: "Amb", kind: "wasm", version: amb.version,
                            flash: flash, master: 700, origin: "app")
        _ = try states.save(name: "Old one", firmwareID: "fizz", firmwareName: "FIZZ", kind: "native", version: "0.9",
                            flash: Data(repeating: 3, count: 1024), origin: "app")
        let cur = [Backup.Current(firmwareID: "amb", firmwareName: "Amb", kind: "wasm", version: amb.version,
                                  flash: Data(repeating: 9, count: 4096)),
                   Backup.Current(firmwareID: "loom", firmwareName: "LOOM-8", kind: "native", version: "1.0",
                                  flash: Data(repeating: 0xFF, count: 4096))]          // (erased: left out)
        let files = fw.files.map { ($0, fw.folder.appendingPathComponent($0.file)) }
        let data = TransferFile.make(library: states, current: cur, files: files, device: "iPhone", app: "0.1 (16)")

        let d = try TransferFile.decode(data)
        XCTAssertEqual(d.device, "iPhone")
        XCTAssertEqual(d.states.count, 3)
        XCTAssertEqual(d.states.filter(\.current).map(\.state.state.name), ["Current memory from iPhone"])
        XCTAssertEqual(d.firmware.count, 1, "amb's file; FIZZ is built in")

        // damaged: one byte changed, cut short, not one
        var bad = data
        bad[bad.count - 10] ^= 0xFF
        XCTAssertThrowsError(try TransferFile.decode(bad)) { XCTAssertEqual($0 as? TransferFile.FileError, .damaged) }
        XCTAssertThrowsError(try TransferFile.decode(data.prefix(data.count - 1))) { XCTAssertEqual($0 as? TransferFile.FileError, .damaged) }
        XCTAssertThrowsError(try TransferFile.decode(Data("hello".utf8))) { XCTAssertEqual($0 as? TransferFile.FileError, .notTransfer) }

        // the iPad: nothing yet. Everything comes in; FIZZ 0.9's state waits (FIZZ is there, another version)
        let (iStates, iFw) = device("ipad")
        let r = TransferFile.importInto(d, states: iStates, firmware: iFw) { [("fizz", "1.0")] + iFw.files.map { ($0.coreID, $0.version) } }
        XCTAssertEqual(r.statesAdded, 3)
        XCTAssertEqual(r.firmwareAdded, ["\(amb.name) \(amb.version)"])
        XCTAssertTrue(r.failed.isEmpty, "\(r.failed)")
        XCTAssertEqual(r.current.map(\.firmwareID), ["amb"])
        XCTAssertTrue(r.missing.isEmpty)
        XCTAssertEqual(try iStates.flash(r.current[0]), Data(repeating: 9, count: 4096))
        XCTAssertEqual(iStates.list("amb").first { $0.name == "Pads" }?.master, 700)
        XCTAssertEqual(iFw.files.first?.sha256, amb.sha256)

        // opened again: nothing doubled
        let again = TransferFile.importInto(d, states: iStates, firmware: iFw) { [] }
        XCTAssertEqual(again.statesAdded, 0)
        XCTAssertEqual(again.statesHere, 3)
        XCTAssertEqual(again.firmwareHere, 1)
        XCTAssertEqual(again.current.count, 1, "the current memory still offered")
        XCTAssertEqual(again.missing, ["Amb \(amb.version)", "FIZZ 0.9"], "nothing installed: both said")
    }

    func testOlderVersionsFromReleases() async throws {
        func release(_ tag: String, _ names: [String]) -> [String: Any] {
            ["tag_name": tag, "draft": false, "assets": names.map {
                ["name": $0, "size": 10, "browser_download_url": "https://github.com/x/\(tag)/\($0)", "digest": "sha256:AB"]
            }]
        }
        let list: [[String: Any]] = [release("c", ["choralroot-0.29.rfm1", "amb-1.3.rfm1", "notes.txt"]),
                                     release("b", ["choralroot-0.28.rfm1", "amb-1.3.rfm1"]),
                                     ["tag_name": "draft", "draft": true, "assets": [["name": "choralroot-9.rfm1", "browser_download_url": "https://x/y"]]],
                                     release("a", ["choralroot-0.26.1.rfm1"])]
        let data = try JSONSerialization.data(withJSONObject: list)
        let v = try FeedSnapshot.versions(data, feed: "test")
        XCTAssertEqual(v["choralroot"]?.map(\.version), ["0.29", "0.28", "0.26.1"])
        XCTAssertEqual(v["amb"]?.map(\.version), ["1.3"])
        XCTAssertEqual(v["amb"]?.first?.downloads.first?.url.absoluteString, "https://github.com/x/c/amb-1.3.rfm1", "the newest release's")
        XCTAssertEqual(v["amb"]?.first?.sha256, "ab")

        // the store: read on demand, cached for offline, details filled
        let (_, fw) = device("store")
        let t = FakeTransport()
        t.pages = [FirmwareFeed.allReleases: data]
        let cache = root.appendingPathComponent("cache/feeds.json")
        let s = FirmwareStore(library: fw, transport: t, cache: cache, thumbs: FirmwareThumbs(directory: root.appendingPathComponent("th")))
        XCTAssertNil(s.version("choralroot", "0.28"))
        await s.loadVersions()
        XCTAssertEqual(s.version("choralroot", "0.28")?.displayName, "Choralroot")
        t.fail = .notConnectedToInternet
        let s2 = FirmwareStore(library: fw, transport: t, cache: cache, thumbs: s.thumbs)
        XCTAssertEqual(s2.versions(of: "choralroot").count, 3, "the cache, offline")
        await s2.loadVersions(maxAge: 0)
        XCTAssertEqual(s2.versions(of: "choralroot").count, 3, "a failure keeps it")
    }
}
