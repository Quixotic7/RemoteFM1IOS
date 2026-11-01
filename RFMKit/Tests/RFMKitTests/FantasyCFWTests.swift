// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Fantasy CFW (FM1VST docs/VIRTUAL-CARTS.md) in the .rfm1 loader: what it lets in (virtual, needs, the rfm1_host_1
// imports and their signatures, the memory and file limits, the memory check), and the file API (section 4) against a
// temporary RemoteFM1 folder: every op, its errors, the sandbox, the limits, cancel, and that an answer reaches the
// module only between two export calls. Ported from the web player's fs-test.mjs (RemoteFM1 branch fantasy-cfw), with
// its module (Fixtures/fs_cart.wasm, fs_cart.c). Then fm1-ripple, the first Fantasy CFW, from FM1VST's build
// (skipped when absent): its droplets read from a folder, one started, sound.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

private enum Op: Int32 { case stat = 1, list, read, write, delete, mkdir }
private enum FsErr: Int32 { case pending = -1, enoent = -2, eacces = -3, eio = -4, enospc = -5, ebusy = -6, ecanceled = -7, enofolder = -8 }

/// module surgery (fs-test.mjs's)
private enum Surgery {
    static func custom(_ name: String, _ payload: [UInt8]) -> [UInt8] {
        let nb = Array(name.utf8)
        let body = WasmBytes.leb(nb.count) + nb + payload
        return [0] + WasmBytes.leb(body.count) + body
    }
    static func withManifest(_ b: [UInt8], _ m: [String: Any]) -> [UInt8] {
        b + custom("rfm1", Array(try! JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])))
    }
    /// the sections: (id, start, end)
    static func sections(_ b: [UInt8]) -> [(id: UInt8, start: Int, end: Int)] {
        var out: [(UInt8, Int, Int)] = [], at = 8
        while at < b.count {
            let start = at, id = b[at]
            at += 1
            var r = 0, sh = 0, x: UInt8
            repeat { x = b[at]; at += 1; r += Int(x & 0x7F) << sh; sh += 7 } while x & 0x80 != 0
            at += r
            out.append((id, start, at))
        }
        return out
    }
    /// the memory: initial = maximum = pages
    static func withMemory(_ b: [UInt8], _ pages: Int) -> [UInt8] {
        let mem = sections(b).first { $0.id == 5 }!
        let nb: [UInt8] = [1, 1] + WasmBytes.leb(pages) + WasmBytes.leb(pages)
        return Array(b[..<mem.start]) + [5] + WasmBytes.leb(nb.count) + nb + Array(b[mem.end...])
    }
    static func rename(_ b: [UInt8], _ from: String, _ to: String) -> [UInt8] {
        let f = Array(from.utf8), t = Array(to.utf8)
        var c = b
        for i in 0...(b.count - f.count) where Array(b[i..<i + f.count]) == f {
            c.replaceSubrange(i..<i + t.count, with: t)
            break
        }
        return c
    }
}

final class FantasyCFWTests: XCTestCase {
    static var man: [String: Any] { ["rfm1": 1, "abi": 6, "id": "fscart", "name": "FS Cart", "version": "1.0",
                                     "license": "MIT", "source_url": "https://example.com/fscart@0"] }
    static var fantasy: [String: Any] {
        var m = man
        m["virtual"] = true
        m["needs"] = ["fs1"]
        m["folders"] = ["audio": "r", "code": "r", "data": "rw"]
        return m
    }
    static func with(_ base: [String: Any], _ changes: [String: Any]) -> [String: Any] { base.merging(changes) { $1 } }

    private var cart: [UInt8] { get throws { [UInt8](try Data(contentsOf: RFM1Files.fixtures.appendingPathComponent("fs_cart.wasm"))) } }
    private var plain: [UInt8] { get throws { [UInt8](try Data(contentsOf: RFM1Files.fixtures.appendingPathComponent("fs_cart_plain.wasm"))) } }
    private var root: URL!
    private var n = 0

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fantasy-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rfmw_set_folder(nil)
        rfmw_set_memory_budget(0)
    }
    override func tearDown() {
        rfmw_set_folder(nil)
        rfmw_set_memory_budget(0)
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ b: [UInt8]) -> String {
        n += 1
        let u = root.appendingPathComponent("m\(n).rfm1")
        try? Data(b).write(to: u)
        return u.path
    }
    /// nil: accepted; else the reason
    private func refused(_ b: [UInt8]) -> String? {
        var info = rfmw_info_t()
        var err = [CChar](repeating: 0, count: 1024)
        return rfmw_check(file(b), &info, &err, 1024) != 0 ? nil : cstr(err)
    }
    private func info(_ b: [UInt8]) -> rfmw_info_t? {
        var info = rfmw_info_t()
        var err = [CChar](repeating: 0, count: 1024)
        return rfmw_check(file(b), &info, &err, 1024) != 0 ? info : nil
    }

    // MARK: the loader

    func testWhatAFantasyCFWMayBe() throws {
        let cart = try cart, plain = try plain, man = Self.man, fantasy = Self.fantasy
        let p = try XCTUnwrap(info(Surgery.withManifest(plain, man)))
        XCTAssertEqual(p.is_virtual, 0)
        XCTAssertEqual(p.uses_folder, 0)
        let f = try XCTUnwrap(info(Surgery.withManifest(cart, fantasy)), refused(Surgery.withManifest(cart, fantasy)) ?? "")
        XCTAssertEqual(f.is_virtual, 1)
        XCTAssertEqual(f.uses_folder, 1)
        XCTAssertEqual(tstr(f.folders), "audio:r code:r data:rw")

        func expect(_ b: [UInt8], _ pattern: String, _ what: String) {
            let m = refused(b)
            XCTAssertNotNil(m, what)
            if let m { XCTAssertNotNil(m.range(of: pattern, options: .regularExpression), "\(what): \(m)") }
        }
        expect(Surgery.withManifest(cart, man), #"imports rfm1_host_1 .*"virtual": true with "fs1""#, "rfm1_host_1 in a plain manifest")
        expect(Surgery.withManifest(cart, Self.with(fantasy, ["needs": [String]()])), "imports rfm1_host_1", "virtual without fs1")
        expect(Surgery.withManifest(cart, Self.with(fantasy, ["needs": ["fs1", "midi9"]])), #"needs a newer RemoteFM1 \(it needs "midi9"\)"#, "an unknown need")
        expect(Surgery.withManifest(plain, Self.with(man, ["needs": ["fs1"]])), #"not "virtual""#, "needs without virtual")
        expect(Surgery.withManifest(Surgery.rename(cart, "fs_changed", "fs_chang3d"), fantasy), #"rfm1_host_1\.fs_chang3d, which this app doesn't know"#, "an unknown host function")
        expect(Surgery.withManifest(Surgery.rename(cart, "rfm1_host_1", "rfm1_host_2"), fantasy), #"imports rfm1_host_2\.\w+, which the \.rfm1 format doesn't allow"#, "another host module")
        expect(Surgery.withManifest(cart, Self.with(fantasy, ["folders": ["data": "w"]])), #"folders.*"w""#, "a folder mode w")
        expect(Surgery.withManifest(Surgery.withMemory(plain, 640), man), "40 MiB: at most 32 MiB", "40 MiB, not virtual")
        let big = try XCTUnwrap(info(Surgery.withManifest(Surgery.withMemory(plain, 640), Self.with(man, ["virtual": true]))))
        XCTAssertEqual(big.memory_bytes, 40 << 20, "40 MiB, virtual (no files): loads")
        XCTAssertEqual(big.is_virtual, 1)
        expect(Surgery.withManifest(Surgery.withMemory(cart, 8208), fantasy), "513 MiB: at most 512 MiB", "513 MiB")
        // (a 512 MiB instance: lazily allocated, so it costs no RAM until touched)
        let huge = try XCTUnwrap(info(Surgery.withManifest(Surgery.withMemory(cart, 8192), fantasy)), "512 MiB accepted")
        XCTAssertEqual(huge.memory_bytes, 512 << 20)
        let pad = Surgery.custom("pad", [UInt8](repeating: 0, count: 16 << 20))
        expect(Surgery.withManifest(cart, fantasy) + pad, "16 MiB", "a virtual file of 16 MiB")
        XCTAssertNil(refused(Surgery.withManifest(plain, man) + pad), "the same size, not virtual: accepted (64 MiB as today)")

        // a wrong signature: one import fs_request (i32) -> i32
        let m = Array("rfm1_host_1".utf8), fld = Array("fs_request".utf8)
        let imp: [UInt8] = [1] + WasmBytes.leb(m.count) + m + WasmBytes.leb(fld.count) + fld + [0, 0]
        let wrong: [UInt8] = WasmBytes.header + [1, 6, 1, 0x60, 1, 0x7F, 1, 0x7F, 2] + WasmBytes.leb(imp.count) + imp
            + Surgery.custom("rfm1", Array(try JSONSerialization.data(withJSONObject: fantasy)))
        expect(wrong, #"fs_request has the signature \(i32\) -> \(i32\), not \(i32, i32, i32, i64, i32, i32\) -> \(i32\)"#, "a wrong signature")
    }

    func testMemoryCheck() throws {
        let b = Surgery.withManifest(Surgery.withMemory(try cart, 4096), Self.fantasy)      // 256 MiB
        rfmw_set_memory_budget(200 << 20)
        let m = refused(b)
        XCTAssertNotNil(m?.range(of: "needs 256 MB of memory; this device can give it 200 MB now"), m ?? "accepted")
        rfmw_set_memory_budget(2 << 30)
        XCTAssertNil(refused(b))
    }

    // MARK: the file API

    private let kick: [UInt8] = (0..<(3 * 1048576 + 17)).map { UInt8(truncatingIfNeeded: $0 * 7 + ($0 >> 9)) }

    /// (written with POSIX calls: the name's bytes as given, NFC; Foundation would store é decomposed)
    private func put(_ p: String, _ b: [UInt8]) {
        let u = root.appendingPathComponent("RemoteFM1/" + p)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = u.deletingLastPathComponent().path + "/" + (p as NSString).lastPathComponent
        guard let f = fopen(path, "wb") else { return }
        _ = b.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, b.count, f) }
        fclose(f)
    }
    private func folder() {
        put("audio/kick.wav", kick)
        put("audio/sub/x.wav", Array("x".utf8))
        put("audio/.hidden", Array("h".utf8))
        put("audio/B.wav", Array("b".utf8)); put("audio/a.wav", Array("a".utf8)); put("audio/Z", Array("z".utf8))
        put("audio/é.wav", Array("e".utf8))
        put("code/fscart/droplets/a.lua", Array("print('a')".utf8))
        put("code/other/secret.lua", Array("secret".utf8))
        try? Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))
        try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("RemoteFM1/code/fscart/escape"),
                                                    withDestinationURL: root.appendingPathComponent("outside.txt"))
    }

    /// one instance of the test module over the folder (nil: none)
    private final class Cart {
        let i: OpaquePointer
        let buf: UInt32
        var P: UInt32 { buf + 1536 * 1024 }
        init(_ path: String, folder: String?) throws {
            var err = [CChar](repeating: 0, count: 1024)
            guard let i = rfmw_inst_open(path, folder, &err, 1024) else {
                throw NSError(domain: "fantasy", code: 1, userInfo: [NSLocalizedDescriptionKey: cstr(err)])
            }
            self.i = i
            var r: Int64 = 0
            _ = rfmw_inst_call(i, "t_buf", nil, 0, &r)
            buf = UInt32(r)
            call("t_demo", 0)                          // (the module's own demo off: these calls alone)
        }
        deinit { rfmw_inst_close(i) }
        @discardableResult func call(_ name: String, _ args: UInt64...) -> Int32 {
            var r: Int64 = 0
            let ok = args.withUnsafeBufferPointer { rfmw_inst_call(i, name, $0.baseAddress, UInt32(args.count), &r) }
            return ok != 0 ? Int32(truncatingIfNeeded: r) : Int32.min
        }
        var mem: UnsafeMutableBufferPointer<UInt8> {
            var n: UInt32 = 0
            let p = rfmw_inst_memory(i, &n)!
            return UnsafeMutableBufferPointer(start: p, count: Int(n))
        }
        func request(_ op: Int32, _ path: [UInt8], _ off: Int64 = 0, _ len: Int32 = 0, at: UInt32? = nil) -> Int32 {
            let m = mem
            for (k, b) in path.enumerated() { m[Int(P) + k] = b }
            return call("t_request", UInt64(op), UInt64(P), UInt64(path.count), UInt64(bitPattern: off), UInt64(at ?? buf), UInt64(UInt32(bitPattern: len)))
        }
        func request(_ op: Op, _ path: String, _ off: Int64 = 0, _ len: Int32 = 0, at: UInt32? = nil) -> Int32 {
            request(op.rawValue, Array(path.utf8), off, len, at: at)
        }
        func settle() { _ = rfmw_inst_settle(i, 10_000) }
        /// a request, settled, polled: (id, result)
        func run(_ op: Op, _ path: String, _ off: Int64 = 0, _ len: Int32 = 0) -> (id: Int32, r: Int32) {
            let id = request(op, path, off, len)
            if id <= 0 { return (id, id) }
            settle()
            return (id, call("t_poll", UInt64(id)))
        }
        func bytes(_ n: Int, at: UInt32? = nil) -> [UInt8] { Array(mem[Int(at ?? buf)..<Int(at ?? buf) + n]) }
        func u64(_ at: UInt32) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(mem[Int(at) + $1]) << (8 * $1) } }
        func u32(_ at: UInt32) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(mem[Int(at) + $1]) << (8 * $1) } }
        func list(_ p: String, _ len: Int32 = 4096, _ off: Int64 = 0) -> (r: Int32, out: [String]) {
            let (_, r) = run(.list, p, off, len)
            var out: [String] = [], at = Int(buf)
            let m = mem
            if r > 0 {
                for _ in 0..<r {
                    let d = m[at], nl = Int(m[at + 1])
                    out.append((d != 0 ? "/" : "") + String(decoding: m[(at + 2)..<(at + 2 + nl)], as: UTF8.self))
                    at += 2 + nl
                }
            }
            return (r, out)
        }
        func write(_ p: String, _ s: String, _ off: Int64) -> Int32 {
            let b = Array(s.utf8), m = mem
            for (k, x) in b.enumerated() { m[Int(buf) + k] = x }
            return run(.write, p, off, Int32(b.count)).r
        }
    }

    private func cartFile(_ manifest: [String: Any]) throws -> String { file(Surgery.withManifest(try cart, manifest)) }

    func testFileAPI() throws {
        folder()
        let c = try Cart(try cartFile(Self.fantasy), folder: root.appendingPathComponent("RemoteFM1").path)
        let E = FsErr.self

        // STAT
        var x = c.run(.stat, "/audio/kick.wav", 0, 16)
        XCTAssertEqual(x.r, 16)
        XCTAssertEqual(c.u64(c.buf), UInt64(kick.count))
        XCTAssertEqual(c.u32(c.buf + 12), 0)
        XCTAssertLessThan(abs(Double(c.u32(c.buf + 8)) - Date().timeIntervalSince1970), 600, "mtime now")
        x = c.run(.stat, "/audio", 0, 16)
        XCTAssertEqual(x.r, 16); XCTAssertEqual(c.u32(c.buf + 12), 1, "STAT /audio: a folder")
        XCTAssertEqual(c.run(.stat, "/audio/kick.wav", 0, 15).r, E.eio.rawValue, "STAT into 15 bytes")
        x = c.run(.stat, "/audio/none.wav", 0, 16)
        XCTAssertGreaterThan(x.id, 0); XCTAssertEqual(x.r, E.enoent.rawValue, "STAT of a missing file: an id, then ENOENT")

        // completion only between export calls
        let id = c.request(.read, "/audio/kick.wav", 1000, 4096)
        XCTAssertEqual(rfmw_inst_wait(c.i, 10_000), 1)          // (the answer is back: not yet in memory)
        let spun = c.call("t_spin", UInt64(id), 100_000)
        for k in 0..<4096 { c.mem[Int(c.buf) + k] = 0xEE }
        rfmw_inst_apply(c.i)                                    // (what each tick does first)
        let after = c.call("t_poll", UInt64(id))
        XCTAssertEqual(spun, E.pending.rawValue, "the answer stays out of the module during a call")
        XCTAssertEqual(after, 4096)
        XCTAssertEqual(c.bytes(4096), Array(kick[1000..<5096]), "READ 4096 at 1000: the bytes")

        // READ
        x = c.run(.read, "/audio/kick.wav", 0, 2 * 1048576)
        XCTAssertEqual(x.r, 1048576, "READ of 2 MiB: 1 MiB (the limit)")
        XCTAssertEqual(c.bytes(1048576), Array(kick[0..<1048576]))
        XCTAssertEqual(c.run(.read, "/audio/kick.wav", Int64(kick.count - 10), 100).r, 10, "READ past the end")
        XCTAssertEqual(c.run(.read, "/audio/kick.wav", Int64(kick.count), 100).r, 0, "READ at the end")
        XCTAssertEqual(c.run(.read, "/audio/kick.wav", 1 << 40, 100).r, 0, "READ at 2^40")
        XCTAssertEqual(c.request(.read, "/audio/kick.wav", -5, 100), E.eio.rawValue)
        XCTAssertEqual(c.request(.read, "/audio/kick.wav", 1 << 60, 100), E.eio.rawValue)
        XCTAssertEqual(c.request(.read, "/audio/kick.wav", 0, 64, at: UInt32(c.mem.count - 10)), E.eio.rawValue, "past the memory's end")
        x = c.run(.read, "/code/droplets/a.lua", 0, 100)
        XCTAssertEqual(x.r, 10); XCTAssertEqual(String(decoding: c.bytes(10), as: UTF8.self), "print('a')", "its own code/fscart/")

        // LIST
        var l = c.list("/audio")
        XCTAssertEqual(l.out.joined(separator: " "), "B.wav Z a.wav kick.wav /sub é.wav", "sorted by bytes, folders marked, no hidden")
        var pages: [String] = [], off: Int64 = 0
        while true {
            let p = c.list("/audio", 12, off)
            if p.r <= 0 { pages.append(String(p.r)); break }
            pages.append(p.out.joined(separator: ",")); off += Int64(p.r)
        }
        XCTAssertEqual(pages.joined(separator: " | "), "B.wav,Z | a.wav | kick.wav | /sub | é.wav | 0", "12-byte pages, never split")
        XCTAssertEqual(c.list("/audio", 4).r, E.eio.rawValue, "LIST into 4 bytes")
        XCTAssertEqual(c.list("/code").out.joined(separator: " "), "/droplets escape")
        l = c.list("/data")
        XCTAssertEqual(l.r, 0)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("RemoteFM1/data/fscart").path, isDirectory: &isDir) && isDir.boolValue, "data/fscart/ made on demand")

        // WRITE, MKDIR, DELETE
        let disk = { (p: String) in (try? String(contentsOf: self.root.appendingPathComponent("RemoteFM1/data/fscart/" + p), encoding: .utf8)) ?? "" }
        XCTAssertEqual(c.write("/data/save.txt", "hello", -1), 5); XCTAssertEqual(disk("save.txt"), "hello")
        XCTAssertEqual(c.write("/data/save.txt", " world", 5), 6); XCTAssertEqual(disk("save.txt"), "hello world")
        XCTAssertEqual(c.write("/data/save.txt", "HE", 0), 2); XCTAssertEqual(disk("save.txt"), "HEllo world")
        XCTAssertEqual(c.write("/data/save.txt", "x", -1), 1); XCTAssertEqual(disk("save.txt"), "x", "-1 truncates")
        XCTAssertEqual(c.run(.mkdir, "/data/sub").r, 0); XCTAssertEqual(c.run(.mkdir, "/data/sub").r, 0, "MKDIR twice")
        XCTAssertEqual(c.write("/data/sub/f.bin", "f", -1), 1)
        XCTAssertEqual(c.write("/data/nofolder/f.bin", "f", -1), E.enoent.rawValue, "into a folder that isn't there")
        XCTAssertLessThan(c.run(.delete, "/data/sub").r, 0, "DELETE of a folder with a file in it")
        XCTAssertEqual(c.run(.delete, "/data/sub/f.bin").r, 0)
        XCTAssertEqual(c.run(.delete, "/data/sub").r, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("RemoteFM1/data/fscart/sub").path))
        XCTAssertEqual(c.run(.stat, "/data/sub", 0, 16).r, E.enoent.rawValue)

        // access (section 3) and the sandbox: refused at once
        let accText: [(Op, String)] = [(.write, "/audio/x.wav"), (.write, "/code/x.lua"), (.mkdir, "/audio/new"), (.delete, "/code/droplets/a.lua"),
            (.delete, "/data"), (.mkdir, "/data"), (.read, "/audio/../code/other/secret.lua"), (.read, "/code/../other/secret.lua"),
            (.read, "/code/./droplets/a.lua"), (.read, "//audio/kick.wav"), (.read, "/audio//kick.wav"), (.list, "/audio/"),
            (.read, "audio/kick.wav"), (.read, "/etc/passwd"), (.read, "/"), (.read, "/Audio/kick.wav"), (.read, "/audio/kick.wav\0"),
            (.read, "/audio\\kick.wav"), (.read, "/audio/" + String(repeating: "x", count: 1100))]
        var acc: [(Op, [UInt8])] = accText.map { ($0.0, Array($0.1.utf8)) }
        acc.append((.read, [0x2F, 0x61, 0x75, 0x64, 0x69, 0x6F, 0x2F, 0xFF]))
        let bad = acc.filter { c.request($0.0.rawValue, $0.1, 0, 16) != E.eacces.rawValue }
        XCTAssertTrue(bad.isEmpty, "\(acc.count) accesses outside section 3: not EACCES: \(bad.map { String(decoding: $0.1.prefix(40), as: UTF8.self) })")
        x = c.run(.read, "/code/escape", 0, 16)
        XCTAssertGreaterThan(x.id, 0); XCTAssertEqual(x.r, E.eacces.rawValue, "a symlink out of the folder")
        XCTAssertEqual(c.request(9, Array("/audio/kick.wav".utf8), 0, 16), E.eio.rawValue)
        XCTAssertEqual(c.request(0, Array("/audio/kick.wav".utf8), 0, 16), E.eio.rawValue)

        // 32 in flight
        let ids = (0..<32).map { c.request(.stat, "/audio/kick.wav", 0, 16, at: c.buf + 16 * UInt32($0)) }
        let over = c.request(.stat, "/audio/kick.wav", 0, 16)
        c.settle()
        let res = ids.map { c.call("t_poll", UInt64($0)) }
        XCTAssertTrue(ids.allSatisfy { $0 > 0 } && Set(ids).count == 32)
        XCTAssertEqual(over, E.ebusy.rawValue, "the 33rd")
        XCTAssertTrue(res.allSatisfy { $0 == 16 })
        XCTAssertGreaterThan(c.request(.stat, "/audio", 0, 16), 0, "room again once polled")
        c.settle()

        // cancel
        for k in 0..<64 { c.mem[Int(c.buf) + k] = 0x55 }
        let cid = c.request(.read, "/audio/kick.wav", 0, 64)
        c.call("t_cancel", UInt64(cid))
        c.settle()
        XCTAssertTrue(c.bytes(64).allSatisfy { $0 == 0x55 }, "the buffer untouched")
        XCTAssertEqual(c.call("t_poll", UInt64(cid)), E.ecanceled.rawValue)
        XCTAssertEqual(c.call("t_poll", UInt64(cid)), E.enoent.rawValue, "then the id is free")
        XCTAssertEqual(c.call("t_poll", 123456), E.enoent.rawValue)

        // fs_changed
        let c0 = c.call("t_changed")
        rfmw_inst_bump(c.i); rfmw_inst_bump(c.i)
        XCTAssertEqual(c.call("t_changed"), c0 + 2)
        rfmw_folder_changed()
        XCTAssertEqual(c.call("t_changed"), c0 + 3, "the app's folder changed")
    }

    func testFoldersTheManifestListsAndNoFolder() throws {
        folder()
        let dir = root.appendingPathComponent("RemoteFM1").path
        let a = try Cart(try cartFile(Self.with(Self.fantasy, ["folders": ["audio": "r"]])), folder: dir)
        XCTAssertEqual(a.request(.read, "/code/droplets/a.lua", 0, 16), FsErr.eacces.rawValue)
        XCTAssertEqual(a.request(.list, "/data", 0, 64), FsErr.eacces.rawValue)
        XCTAssertGreaterThan(a.request(.read, "/audio/kick.wav", 0, 16), 0)
        a.settle()
        let b = try Cart(try cartFile(Self.with(Self.fantasy, ["folders": ["audio": "r", "data": "r"]])), folder: dir)
        XCTAssertEqual(b.request(.write, "/data/x", -1, 1), FsErr.eacces.rawValue, "data r: no writes")
        XCTAssertGreaterThan(b.request(.list, "/data", 0, 64), 0)
        b.settle()
        // no folder: an id, PENDING, then ENOFOLDER after the next apply
        let c = try Cart(try cartFile(Self.fantasy), folder: nil)
        let id = c.request(.read, "/audio/kick.wav", 0, 16)
        XCTAssertGreaterThan(id, 0)
        XCTAssertEqual(c.call("t_poll", UInt64(id)), FsErr.pending.rawValue)
        rfmw_inst_apply(c.i)
        XCTAssertEqual(c.call("t_poll", UInt64(id)), FsErr.enofolder.rawValue)
        // the app's folder (rfmw_set_folder) once set
        rfmw_set_folder(dir)
        let x = c.run(.stat, "/audio/kick.wav", 0, 16)
        XCTAssertEqual(x.r, 16, "the app's folder")
    }

    // MARK: fm1-ripple

    /// ripple-0.4 with FM1VST's test folder: the droplets read, a1tone started (PLAY), the chord sounds
    func testRippleReadsItsDropletsAndPlays() throws {
        let path = "/Volumes/Q7Media-2025/Projects/Github/ChoralRootFM1/FM1VST/.claude/worktrees/virtual-carts/build-rfm1/rfm1/ripple-0.4.rfm1"
        let src = "/Volumes/Q7Media-2025/Projects/Github/ChoralRootFM1/FM1VST/.claude/worktrees/virtual-carts/core-glue/ripple/test_folder"
        guard FileManager.default.fileExists(atPath: path), FileManager.default.fileExists(atPath: src) else {
            throw XCTSkip("no ripple-0.4.rfm1 or its test folder in FM1VST's virtual-carts worktree")
        }
        let dir = root.appendingPathComponent("RemoteFM1")
        try FileManager.default.copyItem(atPath: src, toPath: dir.path)
        rfmw_set_folder(dir.path)
        var info = rfmw_info_t()
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(rfmw_check(path, &info, &err, 512), 1, cstr(err))
        XCTAssertEqual(info.is_virtual, 1)
        XCTAssertEqual(info.uses_folder, 1)
        let c = try WasmTestCore(path)
        let reads0 = rfmw_folder_reads()
        c.boot()
        c.run(3000)
        XCTAssertGreaterThanOrEqual(rfmw_folder_reads() - reads0, 5, "ripple read its droplets and lib from the folder")
        let play = UInt8(rfme_matrix_button(c.e, Int32(RFME_B_PLAY)))
        _ = rfme_event(c.e, UInt8(RFMC_EV_BUTTON), play, 1)
        c.run(60)
        _ = rfme_event(c.e, UInt8(RFMC_EV_BUTTON), play, 0)
        c.run(1440)
        for k in [9, 13, 16] { c.key(k, true) }
        let a = c.run(1500)
        for k in [9, 13, 16] { c.key(k, false) }
        let s = c.status
        print(String(format: "ripple: %llu folder reads, rms %.4f, halted %d, %u LCD writes",
                     rfmw_folder_reads() - reads0, a.rms, s.halted, s.lcd_writes))
        XCTAssertEqual(s.halted, 0)
        XCTAssertGreaterThan(a.rms, 0.0005, "a1tone is silent")
    }
}
