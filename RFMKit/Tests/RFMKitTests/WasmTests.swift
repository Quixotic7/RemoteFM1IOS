// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// M7 on the Mac: imported firmware. The .rfm1 loader (RFMWasm.h) refuses broken files (tiny modules made here);
// AMB-1 (Fixtures/amb-1.3.rfm1, MPL-2.0) boots, draws and sounds through WasmCore and the engine (rfme_load_wasm:
// engineLoad); Felucca and ChoralRoot .rfm1 (from $RFM1_DIR, default FM1VST's rfm1 worktree: skipped, saying so,
// when absent) sound, draw and repeat bit for bit in a second instance; two instances of one file share nothing; the
// render-ahead stall test with a Wasm core.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

/// a fixed C char array (a tuple) as a String
func tstr<T>(_ t: T) -> String { RemoteController.string(t) }

/// .rfm1 files for the tests
enum RFM1Files {
    static var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }
    static var amb: String { fixtures.appendingPathComponent("amb-1.3.rfm1").path }

    /// $RFM1_DIR, else FM1VST's rfm1-target worktree's build
    static var dir: String {
        if let d = ProcessInfo.processInfo.environment["RFM1_DIR"], !d.isEmpty { return d }
        return "/Volumes/Q7Media-2025/Projects/Github/ChoralRootFM1/FM1VST/.claude/worktrees/rfm1/build-rfm1/rfm1"
    }

    /// the first <id>-*.rfm1 in dir, or a skip that says where it looked
    static func path(_ id: String) throws -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        guard let n = names.sorted().first(where: { $0.hasPrefix(id + "-") && $0.hasSuffix(".rfm1") }) else {
            print("SKIP: no \(id)-*.rfm1 in \(dir) (set RFM1_DIR)")
            throw XCTSkip("no \(id)-*.rfm1 in \(dir) (set RFM1_DIR to a folder of .rfm1 files)")
        }
        return (dir as NSString).appendingPathComponent(n)
    }
}

/// tiny WebAssembly modules, for the loader's refusals
enum WasmBytes {
    static let header: [UInt8] = [0, 0x61, 0x73, 0x6D, 1, 0, 0, 0]
    static func leb(_ v: Int) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    static func name(_ s: String) -> [UInt8] { leb(s.utf8.count) + Array(s.utf8) }
    static func section(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { [id] + leb(body.count) + body }
    static func custom(_ n: String, _ payload: [UInt8]) -> [UInt8] { section(0, name(n) + payload) }
    static let manifestJSON = #"{"rfm1":1,"abi":6,"id":"tiny","name":"Tiny","version":"0.1","license":"MIT","source_url":"https://example.invalid/tiny@0"}"#
    static var manifest: [UInt8] { custom("rfm1", Array(manifestJSON.utf8)) }
    /// one type: () -> ()
    static let types: [UInt8] = section(1, [1, 0x60, 0, 0])
    static func imports(_ module: String, _ field: String) -> [UInt8] { section(2, [1] + name(module) + name(field) + [0, 0]) }
    /// flags 0 (no maximum: growable) or 1 (initial = maximum)
    static func memory(initial: Int, max: Int?) -> [UInt8] {
        section(5, [1] + (max == nil ? [0] + leb(initial) : [1] + leb(initial) + leb(max!)))
    }

    static func write(_ bytes: [UInt8], _ name: String) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfm1-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? Data(bytes).write(to: url)
        return url.path
    }
}

/// one engine over an .rfm1, on the caller's clock (TestCore's twin)
final class WasmTestCore {
    let e: OpaquePointer
    init(_ path: String) throws {
        e = rfme_new(nil)
        var err = [CChar](repeating: 0, count: 512)
        guard rfme_load_wasm(e, path, &err, 512) != 0 else {
            throw NSError(domain: "wasm", code: 1, userInfo: [NSLocalizedDescriptionKey: cstr(err)])
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
    func flash() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(rfme_flash_size(e)))
        let ok = out.withUnsafeMutableBufferPointer { rfme_final_flash(e, $0.baseAddress, UInt32($0.count)) }
        return ok != 0 ? out : []
    }
    /// settle, then D4 held for `holdMs`: the hold's audio
    func chord(settle: UInt32 = 1500, holdMs: UInt32 = 1500) -> rfme_audio_t {
        run(settle)
        key(CoreTests.keyD4, true)
        let a = run(holdMs)
        key(CoreTests.keyD4, false)
        run(100)
        return a
    }
}

final class WasmTests: XCTestCase {
    private func check(_ path: String) -> (ok: Bool, info: rfmw_info_t, err: String) {
        var info = rfmw_info_t()
        var err = [CChar](repeating: 0, count: 512)
        let ok = rfmw_check(path, &info, &err, 512) != 0
        return (ok, info, cstr(err))
    }

    // MARK: the loader

    func testRefusesBrokenFiles() {
        typealias W = WasmBytes
        let cases: [(String, [UInt8], String)] = [
            ("magic.rfm1", Array("hello, not wasm".utf8), "not a WebAssembly module"),
            ("nomanifest.rfm1", W.header + W.types + W.memory(initial: 1, max: 1), "no rfm1 section"),
            ("import.rfm1", W.header + W.manifest + W.types + W.imports("env", "foo") + W.memory(initial: 1, max: 1),
             "imports env.foo, which the .rfm1 format doesn't allow"),
            ("wasiother.rfm1", W.header + W.manifest + W.types + W.imports("wasi_snapshot_preview1", "random_get"),
             "imports wasi_snapshot_preview1.random_get"),
            ("wrongsig.rfm1", W.header + W.manifest + W.types + W.imports("wasi_snapshot_preview1", "fd_close"),
             "has the signature () -> (), not (i32) -> (i32)"),
            ("grow.rfm1", W.header + W.manifest + W.types + W.memory(initial: 1, max: nil), "its memory can grow"),
            ("grow2.rfm1", W.header + W.manifest + W.types + W.memory(initial: 1, max: 4), "its memory can grow"),
            ("big.rfm1", W.header + W.manifest + W.types + W.memory(initial: 1024, max: 1024), "at most 32 MiB"),
            ("noexports.rfm1", W.header + W.manifest + W.types + W.memory(initial: 1, max: 1),
             "its memory is not exported"),
            ("badjson.rfm1", W.header + W.custom("rfm1", Array("{nope".utf8)) + W.types, "not a JSON object"),
            ("noid.rfm1", W.header + W.custom("rfm1", Array(#"{"rfm1":1,"abi":6,"name":"x","version":"1","license":"MIT","source_url":"u"}"#.utf8)),
             "no \"id\""),
            ("v2.rfm1", W.header + W.custom("rfm1", Array(#"{"rfm1":2,"abi":6}"#.utf8)), "format version 2"),
            ("truncated.rfm1", Array((W.header + W.manifest + W.types).dropLast(2)), "runs past the end"),
        ]
        for (name, bytes, want) in cases {
            let r = check(WasmBytes.write(bytes, name))
            XCTAssertFalse(r.ok, name)
            XCTAssertTrue(r.err.contains(want), "\(name): \(r.err)")
            print("refused \(r.err)")
        }
        XCTAssertFalse(check("/nonexistent/x.rfm1").ok)
    }

    func testAmbChecksAndTexts() throws {
        let t0 = Date()
        let r = check(RFM1Files.amb)
        XCTAssertTrue(r.ok, r.err)
        XCTAssertEqual(tstr(r.info.id), "amb")
        XCTAssertEqual(tstr(r.info.name), "AMB-1")
        XCTAssertEqual(tstr(r.info.version), "1.3")
        XCTAssertEqual(tstr(r.info.license), "MPL-2.0")
        XCTAssertEqual(tstr(r.info.sha256), "ccacdb2801a8ac39aa86128f1650b071775c4fa131446011189f77a34961f053")
        XCTAssertEqual(r.info.abi, 6)
        XCTAssertEqual(r.info.memory_bytes, 8 * 1048576)
        XCTAssertEqual(r.info.file_size, 214_629)
        var b = [CChar](repeating: 0, count: 65)
        XCTAssertEqual(rfmw_sha256(RFM1Files.amb, &b), 1)
        XCTAssertEqual(cstr(b), tstr(r.info.sha256))
        let manifest = text(RFM1Files.amb, "manifest")
        XCTAssertTrue(manifest.contains("\"Charles Vestal\""))
        XCTAssertTrue(text(RFM1Files.amb, "license.0").hasPrefix("MPL-2.0"))
        XCTAssertTrue(text(RFM1Files.amb, "license.2").hasPrefix("GPL-3.0-only"))
        XCTAssertEqual(text(RFM1Files.amb, "license.9"), "")
        print(String(format: "amb: checked in %.1f ms (an instantiation: %.1f ms)", Date().timeIntervalSince(t0) * 1000,
                     Double(r.info.load_us) / 1000))
    }

    func text(_ path: String, _ what: String) -> String {
        let n = Int(rfmw_text(path, what, nil, 0))
        guard n > 0 else { return "" }
        var b = [CChar](repeating: 0, count: n + 1)
        _ = rfmw_text(path, what, &b, UInt32(n + 1))
        return cstr(b)
    }

    // MARK: running

    func testAmbBootsDrawsAndSounds() throws {
        let c = try WasmTestCore(RFM1Files.amb)
        c.boot()
        let s0 = c.status
        XCTAssertEqual(tstr(s0.kind), "wasm")
        XCTAssertEqual(tstr(s0.core_id), "amb")
        XCTAssertEqual(s0.slot, 0)
        XCTAssertEqual(s0.booted, 1)
        let a = c.chord()
        let s = c.status
        XCTAssertEqual(s.halted, 0)
        XCTAssertGreaterThan(s.lcd_writes, 0, "amb drew nothing")
        XCTAssertGreaterThan(a.rms, 0.0005, "amb is silent")
        XCTAssertNotEqual(c.lcd, 0)
        print(String(format: "amb (wasm): rms %.4f peak %d, %u LCD writes", a.rms, a.peak, s.lcd_writes))
    }

    /// Felucca and ChoralRoot: sound, screen, and a second instance repeats the first bit for bit
    func testFeluccaAndChoralRootDeterministic() throws {
        var ran = 0
        for id in ["felucca", "choralroot"] {
            guard let path = try? RFM1Files.path(id) else { continue }
            ran += 1
            let t0 = Date()
            let a = try WasmTestCore(path), b = try WasmTestCore(path)
            let load = Date().timeIntervalSince(t0) / 2
            a.boot()
            b.boot()
            let t1 = Date()
            let ra = a.chord()
            let wall = Date().timeIntervalSince(t1)
            let rb = b.chord()
            XCTAssertEqual(a.status.halted, 0, id)
            XCTAssertGreaterThan(ra.rms, 0.0005, "\(id) is silent")
            XCTAssertGreaterThan(a.status.lcd_writes, 0, "\(id) drew nothing")
            XCTAssertEqual(ra.frames, rb.frames, id)
            XCTAssertEqual(ra.hash, rb.hash, "\(id): two instances' audio differs")
            XCTAssertEqual(a.lcd, b.lcd, "\(id): two instances' screens differ")
            print(String(format: "%@ (wasm): rms %.4f peak %d, hash %08x = %08x, LCD %08x, load %.0f ms, %.1fx real time on this Mac",
                         id, ra.rms, ra.peak, ra.hash, rb.hash, a.lcd, load * 1000, 3.1 / wall))
        }
        if ran == 0 { throw XCTSkip("no felucca / choralroot .rfm1 in \(RFM1Files.dir)") }
    }

    /// two instances of one file: a key on one doesn't reach the other (its audio stays bit for bit that of an
    /// untouched third); each has its own flash
    func testInstancesIsolated() throws {
        let path = (try? RFM1Files.path("felucca")) ?? RFM1Files.amb
        let a = try WasmTestCore(path), b = try WasmTestCore(path), ref = try WasmTestCore(path)
        for c in [a, b, ref] {
            c.boot()
            c.run(1500)
        }
        for k in [9, 13, 16] { a.key(k, true) }              // (a chord: D4 F#4 A4)
        let ra = a.run(1500), rb = b.run(1500), rr = ref.run(1500)
        XCTAssertGreaterThan(ra.rms, 0.0005)
        XCTAssertTrue(ra.hash != rr.hash || a.lcd != ref.lcd, "the keys changed nothing")
        XCTAssertEqual(rb.hash, rr.hash, "keys on one instance reached another: rms \(rb.rms) vs \(rr.rms)")
        XCTAssertEqual(b.lcd, ref.lcd, "keys on one instance changed another's screen")
        XCTAssertEqual(rfme_flash_size(a.e), rfme_flash_size(b.e))
        let fa = a.flash(), fb = b.flash()
        XCTAssertFalse(fa.isEmpty)
        // a different flash staged into a third instance stays there
        var marked = fa
        if marked.count > 100 { marked[marked.count - 7] ^= 0x5A }
        let c = try WasmTestCore(path)
        c.boot(marked)
        c.run(200)
        let fc = c.flash()
        XCTAssertEqual(fc.count, marked.count)
        if fc.count > 100 { XCTAssertEqual(fc[fc.count - 7], marked[marked.count - 7]) }
        XCTAssertEqual(b.flash(), fb, "an instance's flash moved when another's did")
        print("isolated: \(URL(fileURLWithPath: path).lastPathComponent), rms \(ra.rms) with the key, \(rb.rms) without (= the untouched one's)")
    }

    /// the render-ahead test of RenderAheadTests with a Wasm core: frame() 3 ms slower every 15 ms on top of the
    /// interpreter's own cost; 5 s of 128-frame callbacks at 48 kHz without an underrun. Prints the core thread's load
    func testRenderAheadStallWithAWasmCore() throws {
        let path = (try? RFM1Files.path("felucca")) ?? RFM1Files.amb
        let e = rfme_new(nil)!
        defer { rfme_free(e) }
        rfme_test_frame_stall(e, 3000)
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(rfme_load_wasm(e, path, &err, 512), 1, cstr(err))
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        rfme_set_clock(e, Int32(RFME_CLOCK_AUDIO))
        let warm = CallbackDriver(e)
        warm.start(count: 375)
        warm.wait()
        rfme_reset_render_stats(e)
        let d = CallbackDriver(e)
        d.event(at: 10, offset: 0, [0x90, 62, 110])     // (a note held: the sound costs more than silence)
        d.start(count: 1875)
        d.wait()
        let s = CorePlayer.status(e)
        print(String(format: "render ahead, %@ (wasm) + a 3 ms stall, 5 s: core thread %u us avg, %u max per render (%u%%), "
                     + "frame() max %u us, %u underruns, callback avg %u us; driver late %d", URL(fileURLWithPath: path).lastPathComponent,
                     s.coreAvgUs, s.coreMaxUs, s.coreLoadPct, s.frameMaxUs, s.underruns, s.renderAvgUs, d.lateCallbacks))
        XCTAssertEqual(s.kind, "wasm")
        XCTAssertGreaterThanOrEqual(s.frameMaxUs, 3000)
        XCTAssertEqual(s.renders, 1875)
        XCTAssertEqual(s.underruns, 0, "underruns with a Wasm core and a stall below the headroom")
        XCTAssertLessThan(s.renderAvgUs, 100)
    }

    /// a firmware's halt: proc_exit is 0x100 | code, and the engine says so (not run here: no firmware exits on cue);
    /// the power cycle re-instantiates from the same bytes
    func testPowerCycleReinstantiates() throws {
        let c = try WasmTestCore(RFM1Files.amb)
        c.boot()
        c.run(500)
        var err = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(rfme_power_cycle(c.e, &err, 256), 1, cstr(err))
        rfme_set_clock(c.e, Int32(RFME_CLOCK_CALLER))
        let a = c.chord(settle: 800, holdMs: 800)
        XCTAssertEqual(c.status.booted, 1)
        XCTAssertGreaterThan(a.rms, 0.0005)
    }
}
