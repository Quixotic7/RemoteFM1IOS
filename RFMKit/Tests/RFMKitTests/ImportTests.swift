// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// M7 on the Mac: the firmware folder (FirmwareLibrary: the check, the mirror as <sha256>.rfm1, index.json, invalid files
// listed with their error, an import, a delete), the catalog's keys (an imported Felucca next to the built-in one), a
// saved choice resolved (CoreRef: by SHA-256, by id with a note, the fallback), and the AU with a Wasm core: its
// flash through fullState, a restore by SHA-256, by id with a note, and a missing one. Each test has its own folder
// and mirror (FirmwareCatalog.shared pointed at it, put back after). The built-in cores as in CoreTests; the Felucca
// .rfm1 as in WasmTests ($RFM1_DIR); tests that need them say so and skip.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

@MainActor
final class ImportTests: XCTestCase {
    private var root: URL!
    private var savedDir: URL?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rfm1-import-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedDir = FirmwareCatalog.shared.dir
        FirmwareCatalog.shared.dir = root.appendingPathComponent("mirror")
    }

    override func tearDown() async throws {
        FirmwareCatalog.shared.dir = savedDir
        try? FileManager.default.removeItem(at: root)
    }

    private func library() -> FirmwareLibrary {
        FirmwareLibrary(folder: root.appendingPathComponent("Firmware"), mirror: root.appendingPathComponent("mirror"))
    }

    private func put(_ path: String, as name: String? = nil) throws {
        let dir = root.appendingPathComponent("Firmware")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: path)
        try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(name ?? src.lastPathComponent))
    }

    // MARK: the folder

    func testSyncMirrorsValidFilesAndListsInvalidOnes() throws {
        try put(RFM1Files.amb)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Firmware"), withIntermediateDirectories: true)
        try Data("not wasm at all".utf8).write(to: root.appendingPathComponent("Firmware/broken.rfm1"))
        try Data("x".utf8).write(to: root.appendingPathComponent("Firmware/notes.txt"))
        let lib = library()
        let files = lib.sync()
        XCTAssertEqual(files.count, 2)
        let amb = try XCTUnwrap(files.first { $0.coreID == "amb" })
        XCTAssertNil(amb.error)
        XCTAssertEqual(amb.name, "AMB-1")
        XCTAssertEqual(amb.version, "1.3")
        XCTAssertEqual(amb.license, "MPL-2.0")
        XCTAssertEqual(amb.fileSize, 214_629)
        XCTAssertEqual(amb.key, "rfm1:ccacdb2801a8ac39aa86128f1650b071775c4fa131446011189f77a34961f053")
        let broken = try XCTUnwrap(files.first { $0.file == "broken.rfm1" })
        XCTAssertTrue(broken.error?.contains("not a WebAssembly module") == true, broken.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Firmware/README.txt").path))
        // the mirror: the valid file only, by hash, and the index
        let mirror = root.appendingPathComponent("mirror")
        let names = try FileManager.default.contentsOfDirectory(atPath: mirror.path).sorted()
        XCTAssertEqual(names, ["\(amb.sha256).rfm1", "index.json"])
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: mirror.appendingPathComponent("index.json"))) as? [String: Any]
        let first = try XCTUnwrap((index?["firmware"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["sha256"] as? String, amb.sha256)
        XCTAssertEqual(first["id"] as? String, "amb")
        XCTAssertEqual(first["version"] as? String, "1.3")
        XCTAssertEqual(first["license"] as? String, "MPL-2.0")
        XCTAssertEqual(first["file_size"] as? Int, 214_629)
        XCTAssertNotNil(first["added"] as? String)
        // the catalog the AU reads
        let cores = FirmwareCatalog.shared.cores()
        XCTAssertEqual(cores.map(\.id), [amb.key])
        XCTAssertEqual(cores.first?.kind, "wasm")
        XCTAssertEqual(cores.first?.firmwareID, "amb")
        let d = FirmwareCatalog.shared.details(amb.sha256)
        XCTAssertEqual(d.authors, ["Charles Vestal"])
        XCTAssertTrue(d.sourceURL.hasPrefix("https://github.com/charlesvestal/fm1-amb@"))
        XCTAssertEqual(d.licenses.count, 5)
        // a delete: gone from the folder, the mirror and the index
        lib.delete(amb)
        XCTAssertEqual(lib.files.map(\.file), ["broken.rfm1"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mirror.path), ["index.json"])
        XCTAssertEqual(FirmwareCatalog.shared.cores().count, 0)
    }

    func testImportCopiesOnceAndKeepsNames() throws {
        let lib = library()
        lib.sync()
        let a = try lib.importFile(URL(fileURLWithPath: RFM1Files.amb))
        XCTAssertNil(a.error)
        XCTAssertEqual(a.file, "amb-1.3.rfm1")
        XCTAssertEqual(lib.message, "Added AMB-1 1.3")
        let again = try lib.importFile(URL(fileURLWithPath: RFM1Files.amb))
        XCTAssertEqual(again.key, a.key)
        XCTAssertEqual(lib.message, "amb-1.3.rfm1 is already here")
        XCTAssertEqual(lib.files.count, 1)
        // another file under the same name keeps both
        let other = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: other.appendingPathComponent("amb-1.3.rfm1"))
        let bad = try lib.importFile(other.appendingPathComponent("amb-1.3.rfm1"))
        XCTAssertEqual(bad.file, "amb-1.3 2.rfm1")
        XCTAssertNotNil(bad.error)
        XCTAssertEqual(lib.files.count, 2)
        XCTAssertEqual(FirmwareCatalog.shared.cores().count, 1)
    }

    // MARK: the catalog and saved choices

    /// an imported Felucca next to the built-in Felucca: two entries, two keys; picking a default stays built-in
    func testImportedFeluccaNextToTheNativeOne() throws {
        guard FileManager.default.fileExists(atPath: CoreTests.coresDir) else {
            throw XCTSkip("no macOS core builds in \(CoreTests.coresDir): run scripts/build_cores.sh macos")
        }
        _ = rfms_scan(CoreTests.coresDir)
        try put(try RFM1Files.path("felucca"))
        let lib = library()
        lib.sync()
        let cat = CorePlayer.catalog()
        let native = try XCTUnwrap(cat.first { $0.id == "felucca" })
        let wasm = try XCTUnwrap(cat.first { $0.imported && $0.firmwareID == "felucca" })
        XCTAssertEqual(native.kind, "native")
        XCTAssertEqual(wasm.kind, "wasm")
        XCTAssertNotEqual(native.id, wasm.id)
        XCTAssertEqual(wasm.id, "rfm1:" + wasm.sha256)
        XCTAssertEqual(wasm.version, native.version)
        XCTAssertEqual(Set(cat.map(\.id)).count, cat.count, "duplicate keys")
        XCTAssertEqual(CorePlayer.pick(nil, in: cat), "choralroot")
        XCTAssertEqual(cat.last?.id, wasm.id, "imported entries come after the built-in ones")
        // a saved choice of each resolves to itself
        XCTAssertEqual(CoreRef(native).resolve(in: cat), .init(key: "felucca", note: "", keepFlash: true))
        XCTAssertEqual(CoreRef(wasm).resolve(in: cat), .init(key: wasm.id, note: "", keepFlash: true))

        // the standalone player: both play, each with its own flash file
        let p = CorePlayer(link: nil, slotsDir: CoreTests.coresDir, flashDir: root.appendingPathComponent("cores"),
                           ref: CoreRef(wasm))
        XCTAssertEqual(p.selected, wasm.id)
        XCTAssertEqual(p.message, "")
        XCTAssertEqual(p.flashURL(wasm.id).lastPathComponent, "rfm1-felucca.bin")
        XCTAssertEqual(p.flashURL("felucca").lastPathComponent, "felucca.bin")
        p.setAudio(false)
        p.setMode(.core)
        XCTAssertTrue(p.status.booted, p.message)
        XCTAssertEqual(p.status.kind, "wasm")
        XCTAssertEqual(p.selectedRef, CoreRef(kind: "wasm", id: "felucca", version: wasm.version, sha256: wasm.sha256))
        p.select("felucca")
        XCTAssertEqual(p.status.kind, "native")
        XCTAssertEqual(p.status.coreID, "felucca")
        p.stop()
    }

    func testCoreRefResolves() {
        func c(_ key: String, _ id: String, _ v: String, wasm: Bool) -> CoreInfo {
            var i = CoreInfo(id: key)
            i.coreID = id
            i.name = id.capitalized
            i.version = v
            if wasm {
                i.kind = "wasm"
                i.sha256 = String(key.dropFirst(5))
            }
            return i
        }
        let cat = [c("choralroot", "choralroot", "0.26.1", wasm: false), c("felucca", "felucca", "1.6.1", wasm: false),
                   c("rfm1:aaa", "felucca", "1.6.2", wasm: true), c("rfm1:bbb", "felucca", "1.6.10", wasm: true),
                   c("rfm1:ccc", "amb", "1.3", wasm: true)]
        // by SHA-256
        XCTAssertEqual(CoreRef(kind: "wasm", id: "felucca", version: "1.6.2", sha256: "aaa").resolve(in: cat),
                       .init(key: "rfm1:aaa", note: "", keepFlash: true))
        // the same id and kind: the same version if there is one, else the newest, with a note
        XCTAssertEqual(CoreRef(kind: "wasm", id: "felucca", version: "1.6.1", sha256: "old").resolve(in: cat),
                       .init(key: "rfm1:bbb", note: "Felucca 1.6.10 instead of 1.6.1", keepFlash: true))
        XCTAssertEqual(CoreRef(kind: "wasm", id: "felucca", version: "1.6.2", sha256: "zzz").resolve(in: cat)?.key, "rfm1:aaa")
        XCTAssertEqual(CoreRef(kind: "wasm", id: "amb", version: "1.2", sha256: "zzz").resolve(in: cat),
                       .init(key: "rfm1:ccc", note: "Amb 1.3 instead of 1.2", keepFlash: true))
        // an imported one that's gone: the built-in core of that id
        let noWasm = cat.filter { !$0.imported }
        XCTAssertEqual(CoreRef(kind: "wasm", id: "felucca", version: "1.6.2", sha256: "aaa").resolve(in: noWasm),
                       .init(key: "felucca", note: "Felucca 1.6.2 (imported) is not here: the built-in Felucca 1.6.1 instead",
                             keepFlash: true))
        // a built-in one this build lacks: an imported one of that id
        XCTAssertEqual(CoreRef(id: "amb", version: "1.3").resolve(in: cat),
                       .init(key: "rfm1:ccc", note: "amb is not in this build: Amb 1.3 (imported) instead", keepFlash: true))
        // nothing of that id: the first core, the flash not for it
        XCTAssertEqual(CoreRef(kind: "wasm", id: "nosuch", version: "1", sha256: "q").resolve(in: cat),
                       .init(key: "choralroot", note: "nosuch 1 (imported) is not in this build: Choralroot instead",
                             keepFlash: false))
        XCTAssertEqual(CoreRef(id: "nosuch").resolve(in: cat)?.note, "nosuch is not in this build: Choralroot instead")
        XCTAssertNil(CoreRef(id: "x").resolve(in: []))
        // the plist form
        let r = CoreRef(kind: "wasm", id: "felucca", version: "1.6.2", sha256: "aaa")
        XCTAssertEqual(CoreRef(r.dict), r)
        XCTAssertNil(CoreRef(nil))
    }

    // MARK: the AU with a Wasm core

    private func makeAU(_ core: String?) throws -> RFMAudioUnit {
        var c = RFMAudioUnit.Config()
        c.runProbes = false
        c.link = .none
        c.defaultCore = core
        if FileManager.default.fileExists(atPath: CoreTests.coresDir) { c.slotsDir = CoreTests.coresDir }
        let au = try RFMAudioUnit(componentDescription: RFMShared.component, options: [], config: c)
        au.maximumFramesToRender = 512
        au.isRenderingOffline = true
        try au.allocateRenderResources()
        addTeardownBlock { au.deallocateRenderResources() }
        return au
    }

    @discardableResult
    private func render(_ au: RFMAudioUnit, ms: Int, midi: [UInt8] = []) -> Double {
        var sum = 0.0, n = 0
        for i in 0..<(ms / 10) {
            let out = au.renderForTest(frames: 441, midi: i == 0 ? midi : [])
            for ch in out { for v in ch { sum += Double(v * v) } }
            n += 2 * 441
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    /// the flash of a Wasm core through fullState into a new instance (a marked byte comes back); the restore finds
    /// the file by its SHA-256
    func testAUWasmFlashRoundTripBySHA256() throws {
        let path = (try? RFM1Files.path("felucca")) ?? RFM1Files.amb
        try put(path)
        let lib = library()
        lib.sync()
        let f = try XCTUnwrap(lib.files.first { $0.error == nil })
        let a = try makeAU(f.key)
        render(a, ms: 1500)
        var s = a.status()
        XCTAssertTrue(s.core.booted, s.coreError)
        XCTAssertEqual(s.coreKind, "wasm")
        XCTAssertEqual(s.coreKey, f.key)
        XCTAssertEqual(s.coreID, f.coreID)
        XCTAssertGreaterThan(render(a, ms: 600, midi: [0x90, 62, 110]), 0.0005, "a host note on the Wasm core is silent")
        var state = try XCTUnwrap(a.fullState)
        var cs = try XCTUnwrap(CoreState(state))
        XCTAssertEqual(cs.kind, "wasm")
        XCTAssertEqual(cs.sha256, f.sha256)
        XCTAssertEqual(cs.core, f.coreID)
        XCTAssertEqual(cs.version, f.version)
        var flash = try XCTUnwrap(cs.flash)
        let at = flash.count - 7
        flash[at] ^= 0x5A
        cs.flash = flash
        cs.encode(into: &state)

        let b = try makeAU(nil)
        b.fullState = state
        render(b, ms: 800)
        s = b.status()
        XCTAssertTrue(s.core.booted, s.coreError)
        XCTAssertEqual(s.coreKey, f.key)
        XCTAssertEqual(s.coreNote, "")
        XCTAssertEqual(s.bootedFrom, "the saved flash")
        let back = try XCTUnwrap(b.fullState.flatMap(CoreState.init))
        XCTAssertEqual(back.flash?[at], flash[at], "the marked flash byte did not come back")
        XCTAssertEqual(back.sha256, f.sha256)
        print("AU + \(f.coreID) (wasm): fullState flash \(flash.count) bytes round trip; render avg \(s.core.renderAvgUs) us, core thread \(s.core.coreAvgUs) us avg (\(s.core.coreLoadPct)%)")
    }

    /// a state naming another build of the same firmware: the one here, with a note, from the saved flash; a state
    /// naming firmware that isn't here at all: the first core, a fresh flash, and the state kept as it was
    func testAURestoreByIDWithNoteAndFallback() throws {
        try put(RFM1Files.amb)
        library().sync()
        var saved: [String: Any] = [:]
        InstanceState().encode(into: &saved)
        CoreState(core: "amb", version: "1.2", flash: nil, kind: "wasm", sha256: String(repeating: "0", count: 64))
            .encode(into: &saved)
        let a = try makeAU(nil)
        a.fullState = saved
        render(a, ms: 500)
        var s = a.status()
        XCTAssertTrue(s.core.booted, s.coreError)
        XCTAssertEqual(s.coreID, "amb")
        XCTAssertEqual(s.coreKind, "wasm")
        XCTAssertEqual(s.coreNote, "AMB-1 1.3 instead of 1.2")
        XCTAssertEqual(CoreState(a.fullState)?.version, "1.3")

        var gone: [String: Any] = [:]
        InstanceState().encode(into: &gone)
        CoreState(core: "nosuch", version: "1", flash: Data([1, 2, 3]), kind: "wasm", sha256: "ff").encode(into: &gone)
        let b = try makeAU(nil)
        b.fullState = gone
        render(b, ms: 300)
        s = b.status()
        XCTAssertTrue(s.coreNote.hasPrefix("nosuch 1 (imported) is not in this build"), s.coreNote)
        XCTAssertTrue(s.coreNote.hasSuffix("(the saved state is kept)"), s.coreNote)
        XCTAssertEqual(s.bootedFrom, "a fresh flash")
        let back = try XCTUnwrap(b.fullState.flatMap(CoreState.init))
        XCTAssertEqual(back.core, "nosuch")
        XCTAssertEqual(back.kind, "wasm")
        XCTAssertEqual(back.sha256, "ff")
        XCTAssertEqual(back.flash, Data([1, 2, 3]))
    }

    /// two AU instances of one imported file: no slots, each its own memory
    func testAUWasmInstancesAreSeparate() throws {
        let path = (try? RFM1Files.path("felucca")) ?? RFM1Files.amb   // (amb drones by itself: the last check needs Felucca)
        try put(path)
        library().sync()
        let key = try XCTUnwrap(FirmwareCatalog.shared.cores().first?.id)
        let units = try (0..<5).map { _ in try makeAU(key) }
        for u in units { render(u, ms: 1500) }
        XCTAssertTrue(units.allSatisfy { $0.status().core.booted }, "a fifth Wasm instance should boot (no slot cap)")
        XCTAssertTrue(units.allSatisfy { $0.status().core.slot == 0 })
        XCTAssertGreaterThan(render(units[0], ms: 600, midi: [0x90, 62, 110]), 0.0005)
        if path != RFM1Files.amb {
            XCTAssertLessThan(render(units[1], ms: 600), 0.0005, "a note on one instance reached another")
        }
    }
}
