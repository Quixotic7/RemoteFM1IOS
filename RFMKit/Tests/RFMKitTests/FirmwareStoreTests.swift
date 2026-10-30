// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Get firmware on the Mac: version order, the two feeds read from saved copies of their answers (Fixtures:
// catalog-2026-10-29.json, releases-latest-2026-10-29.json, trimmed), the merge, the install state, the cache (shown
// offline), and installs through a fake network: checked and imported (amb-1.3.rfm1), a checksum mismatch, a file
// the loader refuses, another feed's copy, an update removing the older file, Cancel, a plain-http address.

import CryptoKit
import Foundation
import XCTest
@testable import RFMKit

/// the network, from memory
final class FakeTransport: FirmwareTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pages_: [URL: Data] = [:]
    private var files_: [URL: Data] = [:]
    private var fail_: URLError.Code?
    private var hang_ = false
    private var started_ = 0

    var pages: [URL: Data] { get { lock.withLock { pages_ } } set { lock.withLock { pages_ = newValue } } }
    var files: [URL: Data] { get { lock.withLock { files_ } } set { lock.withLock { files_ = newValue } } }
    var fail: URLError.Code? { get { lock.withLock { fail_ } } set { lock.withLock { fail_ = newValue } } }
    var hang: Bool { get { lock.withLock { hang_ } } set { lock.withLock { hang_ = newValue } } }
    var started: Int { lock.withLock { started_ } }

    func data(from url: URL) async throws -> Data {
        if let c = fail { throw URLError(c) }
        guard let d = pages[url] else { throw FirmwareStoreError.server(404) }
        return d
    }

    func download(from url: URL, to: URL, limit: Int, progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        lock.withLock { started_ += 1 }
        if hang { try await Task.sleep(for: .seconds(30)) }
        if let c = fail { throw URLError(c) }
        guard let d = files[url] else { throw FirmwareStoreError.server(404) }
        if d.count > limit { throw FirmwareStoreError.tooLarge }
        progress(d.count / 2, d.count)
        try d.write(to: to)
        progress(d.count, d.count)
    }
}

@MainActor
final class FirmwareStoreTests: XCTestCase {
    private var root: URL!

    static let ambSHA = "ccacdb2801a8ac39aa86128f1650b071775c4fa131446011189f77a34961f053"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rfm1-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func fixture(_ n: String) throws -> Data { try Data(contentsOf: RFM1Files.fixtures.appendingPathComponent(n)) }
    private var siteJSON: Data { get throws { try fixture("catalog-2026-10-29.json") } }
    private var releaseJSON: Data { get throws { try fixture("releases-latest-2026-10-29.json") } }
    private var amb: Data { get throws { try Data(contentsOf: URL(fileURLWithPath: RFM1Files.amb)) } }

    private func library() -> FirmwareLibrary {
        let mirror = root.appendingPathComponent("mirror")
        return FirmwareLibrary(folder: root.appendingPathComponent("Firmware"), mirror: mirror,
                               catalog: FirmwareCatalog(dir: mirror))
    }

    private func transport() throws -> FakeTransport {
        let t = FakeTransport()
        t.pages = [FirmwareFeed.remotefm1.url: try siteJSON, FirmwareFeed.releases.url: try releaseJSON]
        return t
    }

    private func store(_ lib: FirmwareLibrary, _ t: FakeTransport) -> FirmwareStore {
        FirmwareStore(library: lib, transport: t, cache: root.appendingPathComponent("cache/feeds.json"))
    }

    private func entry(_ id: String, version: String, sha: String, size: Int, urls: [String]) -> AvailableFirmware {
        var e = AvailableFirmware(id: id)
        e.name = id.uppercased()
        e.version = version
        e.downloads = urls.map { .init(url: URL(string: $0)!, feed: "test", sha256: sha, size: size, fileName: "\(id)-\(version).rfm1") }
        return e
    }

    private func file(_ id: String, _ v: String, sha: String = UUID().uuidString) -> ImportedFirmware {
        ImportedFirmware(sha256: sha, coreID: id, name: id, version: v, license: "", fileSize: 1)
    }

    // MARK: versions, the feeds, the merge

    func testVersionOrder() {
        let less: [(String, String)] = [
            ("1.6.1", "1.6.10"), ("0.26.1", "0.27"), ("0.12.0-beta.12", "0.12.0"), ("0.12.0-beta.2", "0.12.0-beta.12"),
            ("1.0-alpha", "1.0-beta"), ("1.0-beta", "1.0-beta.1"), ("1.0-rc.1", "1.0"), ("0.9.9", "1.0"), ("1.2", "v1.10"),
            ("1.0.0", "1.0.1"), ("2", "10"),
        ]
        for (a, b) in less {
            XCTAssertTrue(FirmwareVersion.less(a, b), "\(a) < \(b)")
            XCTAssertFalse(FirmwareVersion.less(b, a), "not \(b) < \(a)")
        }
        for (a, b) in [("1.0", "1.0.0"), ("v1.3", "1.3"), ("1.3+build.5", "1.3"), ("0.11", "0.11")] {
            XCTAssertEqual(FirmwareVersion.compare(a, b), .orderedSame, "\(a) == \(b)")
        }
        XCTAssertTrue(CoreRef.older("1.6.2-beta.1", "1.6.2"))
    }

    func testFileNames() {
        XCTAssertTrue(FeedSnapshot.idAndVersion("choralroot-0.26.1.rfm1")! == ("choralroot", "0.26.1"))
        XCTAssertTrue(FeedSnapshot.idAndVersion("fizz-0.12.0-beta.12.rfm1")! == ("fizz", "0.12.0-beta.12"))
        XCTAssertTrue(FeedSnapshot.idAndVersion("hortator-bt-1.0.rfm1")! == ("hortator-bt", "1.0"))
        XCTAssertTrue(FeedSnapshot.idAndVersion("x0x-v2.1.rfm1")! == ("x0x", "v2.1"))
        XCTAssertNil(FeedSnapshot.idAndVersion("noversion.rfm1"))
        XCTAssertNil(FeedSnapshot.idAndVersion("amb-1.3.zip"))
    }

    func testSiteCatalog() throws {
        let s = try FeedSnapshot.parse(try siteJSON, feed: .remotefm1)
        XCTAssertEqual(s.details.count, 7)                  // (every firmware: details for the other feeds)
        XCTAssertEqual(s.firmware.map(\.id).sorted(), ["fizz", "s1vave"])   // (only those with an .rfm1)
        let fizz = try XCTUnwrap(s.firmware.first { $0.id == "fizz" })
        XCTAssertEqual(fizz.name, "FIZZ")
        XCTAssertEqual(fizz.version, "0.12.0-beta.12")
        XCTAssertEqual(fizz.author, "Michael P Jones (Quixotic7)")
        XCTAssertEqual(fizz.category, "Groovebox")
        XCTAssertEqual(fizz.summary, "FM TONE step sequencer")
        XCTAssertTrue(fizz.about.hasPrefix("A step sequencer for FM TONE"))
        XCTAssertTrue(fizz.beta)
        XCTAssertEqual(fizz.downloads.count, 1)
        XCTAssertEqual(fizz.downloads[0].url.absoluteString, "https://remotefm1.com/fw/fizz-0.12.0-beta.12.rfm1")
        XCTAssertEqual(fizz.sha256, "e511348e9716f3144e7e4b7679a2a563af093322c7b9d2ed043d03fd5508bd99")
        XCTAssertEqual(fizz.size, 1_260_254)
        XCTAssertEqual(fizz.fileName, "fizz-0.12.0-beta.12.rfm1")
        XCTAssertThrowsError(try FeedSnapshot.parse(Data("<html>".utf8), feed: .remotefm1))
    }

    func testGitHubRelease() throws {
        let s = try FeedSnapshot.parse(try releaseJSON, feed: .releases)
        XCTAssertEqual(s.firmware.map(\.id), ["amb", "choralroot", "coralflower", "felucca", "s1vave"])
        let a = s.firmware[0]
        XCTAssertEqual(a.version, "1.3")
        XCTAssertEqual(a.sha256, Self.ambSHA)
        XCTAssertEqual(a.size, 214_629)
        XCTAssertEqual(a.downloads[0].url.absoluteString,
                       "https://github.com/Quixotic7/RemoteFM1FW/releases/download/2026-10-29/amb-1.3.rfm1")
        XCTAssertEqual(a.name, "")                          // (filled in by the merge)
        XCTAssertThrowsError(try FeedSnapshot.parse(Data("{\"message\":\"Not Found\"}".utf8), feed: .releases))
    }

    func testMerge() throws {
        let site = try FeedSnapshot.parse(try siteJSON, feed: .remotefm1)
        let rel = try FeedSnapshot.parse(try releaseJSON, feed: .releases)
        let m = FeedSnapshot.merge([site, rel])
        XCTAssertEqual(m.map(\.id), ["amb", "choralroot", "coralflower", "felucca", "fizz", "s1vave"])   // (by name)
        let s1 = try XCTUnwrap(m.first { $0.id == "s1vave" })
        XCTAssertEqual(s1.downloads.map(\.feed), [FirmwareFeed.remotefm1.name, FirmwareFeed.releases.name])
        XCTAssertEqual(Set(s1.downloads.map(\.sha256)).count, 1)
        // a release-only file: the catalog's details, the file's version (the catalog's 0.27 is the FM-1 package's)
        let cr = try XCTUnwrap(m.first { $0.id == "choralroot" })
        XCTAssertEqual(cr.name, "ChoralRoot")
        XCTAssertEqual(cr.version, "0.26.1")
        XCTAssertEqual(cr.category, "Chords")
        XCTAssertEqual(cr.sourceURL, "https://github.com/Quixotic7/ChoralRootFM1")   // (the repo, not 0.27's tag)
        XCTAssertFalse(cr.about.isEmpty)
        let amb = try XCTUnwrap(m.first { $0.id == "amb" })
        XCTAssertEqual(amb.name, "AMB-1")
        XCTAssertEqual(amb.license, "MPL-2.0")
        XCTAssertTrue(amb.sourceURL.contains("fm1-amb"))
        // no site catalog: the name from the id
        XCTAssertEqual(FeedSnapshot.merge([rel]).first { $0.id == "coralflower" }?.name, "Coralflower")
        // a newer version in a later feed wins, with only its own download
        var newer = rel
        newer.feed = FirmwareFeed(kind: .github, url: URL(string: "https://example.com/feed")!, name: "an author's feed")
        newer.firmware = [entry("amb", version: "1.4", sha: "ab", size: 9, urls: ["https://example.com/amb-1.4.rfm1"])]
        let m2 = FeedSnapshot.merge([site, rel, newer])
        let amb2 = try XCTUnwrap(m2.first { $0.id == "amb" })
        XCTAssertEqual(amb2.version, "1.4")
        XCTAssertEqual(amb2.downloads.count, 1)
        XCTAssertEqual(amb2.name, "AMB")                    // (the entry's own name; empty fields come from the others)
        XCTAssertEqual(amb2.license, "MPL-2.0")
    }

    func testInstallState() {
        let e = entry("felucca", version: "1.6.2", sha: "new", size: 1, urls: ["https://x/f.rfm1"])
        XCTAssertEqual(e.state([]), .notInstalled)
        XCTAssertEqual(e.state([file("felucca", "1.6.1")]), .update("1.6.1"))
        XCTAssertEqual(e.state([file("felucca", "1.6.1"), file("felucca", "1.6.2")]), .installed("1.6.2"))
        XCTAssertEqual(e.state([file("felucca", "1.7")]), .installed("1.7"))                 // (a newer one by hand)
        XCTAssertEqual(e.state([file("other", "0.1", sha: "new")]), .installed("0.1"))       // (the same file)
        var broken = file("felucca", "1.6.1")
        broken.error = "bad"
        XCTAssertEqual(e.state([broken]), .notInstalled)
        XCTAssertEqual(e.state([file("amb", "1.3")]), .notInstalled)
        // a built-in core of the same id and version (or newer) hides it; an older built-in one doesn't
        var native = CoreInfo(id: "felucca")
        native.version = "1.6.2"
        XCTAssertTrue(e.builtIn([native]))
        native.version = "1.6.1"
        XCTAssertFalse(e.builtIn([native]))
    }

    // MARK: the store: the check, the cache

    func testCheckCachesAndShowsTheCacheOffline() async throws {
        let lib = library()
        lib.sync()
        let t = try transport()
        let s = store(lib, t)
        XCTAssertTrue(s.available.isEmpty)
        XCTAssertNil(s.checked)
        await s.refresh()
        XCTAssertEqual(s.available.count, 6)
        XCTAssertEqual(s.problem, "")
        let when = try XCTUnwrap(s.checked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.cacheURL.path))
        var native = CoreInfo(id: "fizz")
        native.version = "0.12.0-beta.12"
        XCTAssertEqual(s.list(builtIn: [native]).count, 5)

        // offline: a new store shows the cached list and its date; a check keeps it and says why
        t.fail = .notConnectedToInternet
        let s2 = store(lib, t)
        XCTAssertEqual(s2.available, s.available)
        XCTAssertEqual(s2.checked?.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 1)
        await s2.refresh()
        XCTAssertEqual(s2.available.count, 6)
        XCTAssertTrue(s2.problem.contains("offline"), s2.problem)
        XCTAssertEqual(s2.checked?.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 1)

        // one feed down: the other's new answer, the cached list of the one that failed
        t.fail = nil
        t.pages[FirmwareFeed.releases.url] = nil
        await s2.refresh()
        XCTAssertEqual(s2.available.count, 6)
        XCTAssertTrue(s2.problem.contains("404"), s2.problem)

        // at most once a day: a list from now isn't checked again
        t.pages = [:]
        let s3 = store(lib, t)
        await s3.refreshIfOlder(than: 86_400)
        XCTAssertEqual(s3.problem, "")
    }

    // MARK: installs

    func testInstallChecksAndImports() async throws {
        let lib = library()
        lib.sync()
        let t = try transport()
        let s = store(lib, t)
        await s.refresh()
        let e = try XCTUnwrap(s.available.first { $0.id == "amb" })
        t.files[e.downloads[0].url] = try amb
        var changed = 0
        s.didChange = { changed += 1 }
        XCTAssertEqual(s.state(e), .notInstalled)
        let f = await s.install(e)
        XCTAssertEqual(f?.sha256, Self.ambSHA)
        XCTAssertEqual(s.failure, "")
        XCTAssertEqual(s.message, "Installed AMB-1 1.3.")
        XCTAssertNil(s.progress)
        XCTAssertEqual(s.state(e), .installed("1.3"))
        XCTAssertGreaterThan(changed, 0)
        // as an import by hand: in the folder under the feed's name, mirrored by SHA-256, in the index
        XCTAssertEqual(lib.files.map(\.file), ["amb-1.3.rfm1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.mirror.appendingPathComponent("\(Self.ambSHA).rfm1").path))
        XCTAssertEqual(FirmwareCatalog(dir: lib.mirror).cores().map(\.coreID), ["amb"])
    }

    func testChecksumMismatchIsRefused() async throws {
        let lib = library()
        lib.sync()
        let t = try transport()
        let s = store(lib, t)
        var bytes = try amb
        bytes[bytes.count - 1] ^= 1
        let e = entry("amb", version: "1.3", sha: Self.ambSHA, size: bytes.count, urls: ["https://a.test/amb-1.3.rfm1"])
        t.files[e.downloads[0].url] = bytes
        let f = await s.install(e)
        XCTAssertNil(f)
        XCTAssertEqual(s.failure, FirmwareStoreError.checksum.message)
        XCTAssertTrue(lib.files.isEmpty)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: lib.folder.path)) ?? []).allSatisfy { !$0.hasSuffix(".rfm1") })

        // the wrong size: refused before the checksum
        let short = entry("amb", version: "1.3", sha: Self.ambSHA, size: bytes.count + 5, urls: ["https://a.test/amb-1.3.rfm1"])
        await s.install(short)
        XCTAssertEqual(s.failure, FirmwareStoreError.size(expected: bytes.count + 5, got: bytes.count).message)

        // another feed's copy is tried next
        let two = entry("amb", version: "1.3", sha: Self.ambSHA, size: bytes.count,
                        urls: ["https://a.test/amb-1.3.rfm1", "https://b.test/amb-1.3.rfm1"])
        t.files[two.downloads[1].url] = try amb
        let g = await s.install(two)
        XCTAssertEqual(g?.sha256, Self.ambSHA)
        XCTAssertEqual(s.failure, "")
    }

    func testAFileTheLoaderRefusesIsRemoved() async throws {
        let lib = library()
        lib.sync()
        let t = try transport()
        let s = store(lib, t)
        let junk = Data("not an rfm1 at all".utf8)
        let sha = SHA256.hash(data: junk).map { String(format: "%02x", $0) }.joined()
        let e = entry("junk", version: "1.0", sha: sha, size: junk.count, urls: ["https://a.test/junk-1.0.rfm1"])
        t.files[e.downloads[0].url] = junk
        let f = await s.install(e)
        XCTAssertNil(f)
        XCTAssertTrue(s.failure.hasPrefix("The file isn't a valid .rfm1 firmware ("), s.failure)
        XCTAssertTrue(lib.files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.folder.appendingPathComponent("junk-1.0.rfm1").path))
    }

    func testNotHTTPSIsRefused() async throws {
        let lib = library()
        let t = try transport()
        let s = store(lib, t)
        let e = entry("amb", version: "1.3", sha: Self.ambSHA, size: 214_629, urls: ["http://a.test/amb-1.3.rfm1"])
        t.files[e.downloads[0].url] = try amb
        await s.install(e)
        XCTAssertEqual(s.failure, FirmwareStoreError.notHTTPS.message)
        XCTAssertEqual(t.started, 0)
    }

    /// an update: the new file in, the older one of the same id out (willReplace told first)
    func testUpdateRemovesTheOlderFile() async throws {
        // another build of AMB-1 1.3: the fixture with a custom section added (a different SHA-256, still valid)
        var other = try amb
        other.append(contentsOf: [0x00, 0x06, 0x01, UInt8(ascii: "x")] + Array("test".utf8))
        let lib = library()
        try FileManager.default.createDirectory(at: lib.folder, withIntermediateDirectories: true)
        try other.write(to: lib.folder.appendingPathComponent("amb-local.rfm1"))
        lib.sync()
        let old = try XCTUnwrap(lib.files.first)
        XCTAssertNil(old.error, "the fixture with a custom section added should still load")
        XCTAssertNotEqual(old.sha256, Self.ambSHA)

        let t = try transport()
        let s = store(lib, t)
        await s.refresh()
        var e = try XCTUnwrap(s.available.first { $0.id == "amb" })
        e.downloads = [e.downloads[0]]
        t.files[e.downloads[0].url] = try amb
        var replaced: ([String], String)?
        s.willReplace = { o, n in replaced = (o.map(\.sha256), n.sha256) }
        await s.install(e)
        XCTAssertEqual(s.failure, "")
        XCTAssertEqual(s.message, "Updated AMB-1 to 1.3.")
        XCTAssertEqual(replaced?.0, [old.sha256])
        XCTAssertEqual(replaced?.1, Self.ambSHA)
        XCTAssertEqual(lib.files.map(\.sha256), [Self.ambSHA])
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.mirror.appendingPathComponent("\(old.sha256).rfm1").path))
        // a saved choice of the old file finds the new one by id
        let r = CoreRef(kind: "wasm", id: "amb", version: "1.3", sha256: old.sha256)
            .resolve(in: FirmwareCatalog(dir: lib.mirror).cores())
        XCTAssertEqual(r?.key, FirmwareCatalog.keyPrefix + Self.ambSHA)
        XCTAssertEqual(r?.keepFlash, true)
    }

    func testCancel() async throws {
        let lib = library()
        lib.sync()
        let t = try transport()
        t.hang = true
        let s = store(lib, t)
        let e = entry("amb", version: "1.3", sha: Self.ambSHA, size: 214_629, urls: ["https://a.test/amb-1.3.rfm1"])
        t.files[e.downloads[0].url] = try amb
        let run = Task { await s.install(e) }
        for _ in 0..<200 where t.started == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(s.progress?.id, "amb")
        let second = await s.install(e)                     // (one at a time)
        XCTAssertNil(second)
        s.cancel()
        let f = await run.value
        XCTAssertNil(f)
        XCTAssertEqual(s.message, "Cancelled.")
        XCTAssertEqual(s.failure, "")
        XCTAssertNil(s.progress)
        XCTAssertTrue(lib.files.isEmpty)
    }
}
