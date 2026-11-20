// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The Ableton Move link (RFMMove.h, MoveLink.h) against a fake Move: a loopback TCP server speaking Move Remote's
// protocol (proto.h: u16 len | u8 type | payload): HELLO, STATUS every 300 ms, INPUT on request; it records the
// host's LEDs, screens and CONFIG. The engine runs the echo core on its timer clock, so the Move's core ticks.

import Foundation
import RFMCore
import CoreGraphics
import XCTest
@testable import RFMKit

/// a Move on 127.0.0.1 (one connection at a time)
final class FakeMove: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var thread: Thread?
    private var stopped = false
    private(set) var ledMsgs = 0, rgbMsgs = 0, screens = 0, configs: [(Int, Int32)] = [], hellos = 0
    private(set) var lastScreen = [UInt8]()

    init() throws {
        let lfd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        a.sin_port = 0
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(lfd, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(lfd, $0, &len) } }
        listenFD = lfd
        port = UInt16(bigEndian: a.sin_port)
        let t = Thread { [weak self] in self?.run() }
        thread = t
        t.start()
    }

    func stop() {
        lock.withLock { stopped = true }
        dropClient()
        close(listenFD)
    }

    /// the connection closed by the Move (a lost link)
    func dropClient() {
        lock.withLock {
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        }
    }

    private func run() {
        while !lock.withLock({ stopped }) {
            let c = accept(listenFD, nil, nil)
            if c < 0 { return }
            lock.withLock { fd = c }
            serve(c)
            lock.withLock { fd = -1 }
            close(c)
        }
    }

    private func serve(_ c: Int32) {
        var buf = [UInt8]()
        var lastStatus = Date.distantPast
        var tmp = [UInt8](repeating: 0, count: 8192)
        while !lock.withLock({ stopped }) {
            var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 50) > 0 {
                let n = read(c, &tmp, tmp.count)
                if n <= 0 { return }
                buf += tmp[0..<n]
                while buf.count >= 2 {
                    let len = Int(buf[0]) | Int(buf[1]) << 8
                    guard buf.count >= 2 + len else { break }
                    message(c, buf[2], Array(buf[3..<(2 + len)]))
                    buf.removeFirst(2 + len)
                }
            }
            if Date().timeIntervalSince(lastStatus) > 0.3 {
                lastStatus = Date()
                var s = [UInt8](repeating: 0, count: 32)
                s[4] = 77                                           // battery 77 %
                send(c, 0x04, s)
            }
        }
    }

    private func message(_ c: Int32, _ type: UInt8, _ p: [UInt8]) {
        switch type {
        case 0x81:                                                   // H_HELLO
            var h = [UInt8]("MOVR".utf8) + [1, 0, 0, 0] + le32(44100) + [128, 0, 128, 64, 0, 0] + le32(4096)
            var name = [UInt8]("Fake Move".utf8)
            name += [UInt8](repeating: 0, count: 24 - name.count)
            h += name
            lock.withLock { hellos += 1 }
            send(c, 0x01, h)
        case 0x82: lock.withLock { ledMsgs += 1 }
        case 0x83: lock.withLock { rgbMsgs += 1 }
        case 0x84: lock.withLock { screens += 1; lastScreen = p }
        case 0x87:
            var i = 0
            while i + 5 <= p.count {
                let v = Int32(bitPattern: UInt32(p[i + 1]) | UInt32(p[i + 2]) << 8 | UInt32(p[i + 3]) << 16 | UInt32(p[i + 4]) << 24)
                lock.withLock { configs.append((Int(p[i]), v)) }
                i += 5
            }
        case 0x88:                                                   // PING -> PONG
            send(c, 0x05, Array(p.prefix(4)) + [UInt8](repeating: 0, count: 12))
        default: break
        }
    }

    /// one surface event: a USB-MIDI packet (cable 0)
    func input(_ pkt: [UInt8]) {
        lock.withLock {
            guard fd >= 0 else { return }
            send(fd, 0x02, le32(0) + pkt)
        }
    }
    func pad(_ i: Int, _ vel: UInt8) { input(vel > 0 ? [0x09, 0x90, UInt8(68 + i), vel] : [0x08, 0x80, UInt8(68 + i), 0]) }
    func cc(_ n: UInt8, _ v: UInt8) { input([0x0B, 0xB0, n, v]) }
    func button(_ n: UInt8) {
        cc(n, 127)
        Thread.sleep(forTimeInterval: 0.03)
        cc(n, 0)
    }

    var counts: (led: Int, rgb: Int, screens: Int, hellos: Int) { lock.withLock { (ledMsgs, rgbMsgs, screens, hellos) } }
    var configList: [(Int, Int32)] { lock.withLock { configs } }

    private func send(_ c: Int32, _ type: UInt8, _ p: [UInt8]) {
        let n = p.count + 1
        let m = [UInt8(n & 255), UInt8(n >> 8), type] + p
        _ = m.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
    }
    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> ($0 * 8) & 255) } }
}

final class MoveLinkTests: XCTestCase {
    private var e: OpaquePointer!
    private var m: OpaquePointer!
    private var fake: FakeMove!

    override func setUp() async throws {
        fake = try FakeMove()
        e = try XCTUnwrap(rfme_new(nil))
        XCTAssertEqual(rfme_test_load_echo(e), 1)
        XCTAssertEqual(rfme_boot(e, nil, 0), 1)
        m = "RFMKit test".withCString { rfmm_new(nil, 0, $0) }
        rfme_attach_move(e, m)
        rfme_set_clock(e, Int32(RFME_CLOCK_TIMER))
        rfmm_projects_init(m, 0, 0, nil, 0)
        rfmm_start(m, "127.0.0.1:\(fake.port)")
    }

    override func tearDown() async throws {
        rfmm_stop(m)
        rfme_set_clock(e, Int32(RFME_CLOCK_NONE))
        rfme_attach_move(e, nil)
        rfme_free(e)
        rfmm_free(m)
        fake.stop()
    }

    private func status() -> rfmm_status_t {
        var s = rfmm_status_t()
        rfmm_status(m, &s)
        return s
    }
    private func engine() -> rfme_status_t {
        var s = rfme_status_t()
        rfme_status(e, &s)
        return s
    }
    @discardableResult
    private func until(_ seconds: Double = 3, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if ok() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return ok()
    }

    func testConnectsAndDrawsTheMove() {
        XCTAssertTrue(until { Int(self.status().state) == Int(RFMM_CONNECTED) }, RemoteController.string(status().text))
        let s = status()
        XCTAssertEqual(RemoteController.string(s.name), "Fake Move")
        XCTAssertEqual(Int(s.via), Int(RFMM_VIA_WIFI), "the fake says Wi-Fi (MR_VIA_WIFI 0)")
        XCTAssertFalse(MoveController.status(of: s).overUSB)
        XCTAssertTrue(RemoteController.string(s.text).hasPrefix("Fake Move connected over Wi-Fi (TCP)"),
                      "the shared words: \(RemoteController.string(s.text))")
        XCTAssertTrue(until { self.status().battery == 77 }, "STATUS's battery")
        XCTAssertTrue(until { self.fake.counts.rgb > 0 && self.fake.counts.screens > 0 }, "LEDs and the screen")
        XCTAssertEqual(fake.lastScreen.count, 1024)
        XCTAssertTrue(fake.configList.contains { $0.0 == 1 && $0.1 == 0 }, "the audio clock turned off")
        XCTAssertEqual(status().ticking, 1, "the engine runs the Move's core")
    }

    func testAPadPlaysAnFM1Key() {
        XCTAssertTrue(until { Int(self.status().state) == Int(RFMM_CONNECTED) })
        let before = engine().keys_pressed
        fake.pad(16, 100)                                            // row 2 from the top: the low white keys
        XCTAssertTrue(until { self.engine().keys_pressed > before }, "a key pressed on the FM-1")
        fake.pad(16, 0)
        XCTAssertGreaterThan(status().inputs, 0)
    }

    func testMidiModeSendsNotesIntoTheFirmware() {
        XCTAssertTrue(until { Int(self.status().state) == Int(RFMM_CONNECTED) })
        fake.button(42)                                              // Track 2: MIDI mode
        XCTAssertTrue(until { self.status().mode == 1 }, "MIDI mode")
        let before = engine().midi_to_core
        fake.pad(0, 90)
        XCTAssertTrue(until { self.engine().midi_to_core > before }, "the note into the firmware's MIDI in")
        fake.pad(0, 0)
        XCTAssertTrue(until { self.status().seq_midi >= 2 }, "note on and off")
    }

    func testSequencerPlays() {
        XCTAssertTrue(until { Int(self.status().state) == Int(RFMM_CONNECTED) })
        fake.button(40)                                              // Track 4: the sequencer
        XCTAssertTrue(until { self.status().mode == 3 })
        fake.button(85)                                              // Play
        XCTAssertTrue(until { self.status().playing == 1 }, "the transport runs by the engine's clock")
        fake.button(85)
        XCTAssertTrue(until { self.status().playing == 0 })
    }

    func testAStepPlaysItsNoteIntoTheFirmware() {
        XCTAssertTrue(until { Int(self.status().state) == Int(RFMM_CONNECTED) })
        fake.button(40)                                              // Track 4: the sequencer
        XCTAssertTrue(until { self.status().mode == 3 })
        fake.input([0x09, 0x90, 16, 127])                            // step 1 on: a note there
        Thread.sleep(forTimeInterval: 0.05)
        fake.input([0x08, 0x80, 16, 0])
        Thread.sleep(forTimeInterval: 0.05)
        let before = engine().midi_to_core
        fake.button(85)                                              // Play
        XCTAssertTrue(until { self.status().playing == 1 })
        XCTAssertTrue(until(4) { self.engine().midi_to_core > before }, "step 1's note into the firmware on the beat")
        fake.button(85)
    }

    func testLostLinkLetsGoAndConnectsAgain() {
        XCTAssertTrue(until { Int(self.status().state) == Int(RFMM_CONNECTED) })
        fake.pad(16, 100)
        XCTAssertTrue(until { self.engine().keys_pressed > 0 })
        fake.dropClient()
        XCTAssertTrue(until(6) { self.status().connects >= 2 && Int(self.status().state) == Int(RFMM_CONNECTED) },
                      "connected again: \(RemoteController.string(status().text))")
        XCTAssertGreaterThanOrEqual(fake.counts.hellos, 2)
    }

    func testStopTurnsItOff() {
        XCTAssertTrue(until { Int(self.status().state) == Int(RFMM_CONNECTED) })
        rfmm_stop(m)
        XCTAssertTrue(until { Int(self.status().state) == Int(RFMM_OFF) })
    }

    func testProjectFiles() throws {
        var blob = [UInt8](repeating: 0, count: Int(rfmm_project_max()))
        let n = Int(blob.withUnsafeMutableBufferPointer { rfmm_test_empty_project($0.baseAddress, UInt32($0.count)) })
        XCTAssertGreaterThan(n, 0)
        blob = Array(blob[0..<n])
        XCTAssertTrue(MoveProjectFile.check(blob))
        let file = MoveProjectFile.pack([MoveProject(slot: 4, bytes: blob, saved: Date(timeIntervalSince1970: 1_800_000_000))])
        // the shared layout: RMVP, version 1, kind 1, count 1; slot 4, flags 0, saved, len (little-endian), the blob
        let t: UInt32 = 1_800_000_000
        XCTAssertEqual(Array(file[0..<18]), [0x52, 0x4D, 0x56, 0x50, 1, 1, 1, 0, 4, 0,
                                             UInt8(t & 255), UInt8(t >> 8 & 255), UInt8(t >> 16 & 255), UInt8(t >> 24),
                                             UInt8(n & 255), UInt8(n >> 8 & 255), UInt8(n >> 16 & 255), UInt8(n >> 24 & 255)])
        XCTAssertEqual(file.count, 18 + n)
        let back = try MoveProjectFile.unpack(file)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].slot, 4)
        XCTAssertEqual(back[0].bytes, blob)
        XCTAssertEqual(back[0].saved, Date(timeIntervalSince1970: 1_800_000_000))
        let set = MoveProjectFile.pack([MoveProject(slot: 1, bytes: blob, saved: Date()), MoveProject(slot: 9, bytes: blob, saved: Date())])
        XCTAssertEqual(set[5], 2, "a set")
        XCTAssertEqual(try MoveProjectFile.unpack(set).map(\.slot), [1, 9])
        XCTAssertThrowsError(try MoveProjectFile.unpack([1, 2, 3, 4, 5, 6, 7, 8])) { e in
            XCTAssertTrue("\(e)".hasPrefix("Not a Move project file"), "\(e)")
        }
        let red = MoveProjectFile.withColor(blob, 3)
        XCTAssertEqual(red[18], 3)
        XCTAssertTrue(MoveProjectFile.check(red), "the check made again")
        var bad = blob
        bad[30] ^= 0xFF
        XCTAssertThrowsError(try MoveProjectFile.unpack(MoveProjectFile.pack([MoveProject(slot: 0, bytes: bad, saved: Date())])))
        XCTAssertThrowsError(try MoveProjectFile.unpack([1, 2, 3]))
        // the store: a slot a file
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MoveProjectStore(folder: dir)
        try store.write(7, blob)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("move-project-08.rfmmove").path))
        XCTAssertEqual(store.read(7)?.bytes, blob)
        XCTAssertEqual(MoveProjectStore.dirBits(store.all()), 1 << 7)
        store.delete(7)
        XCTAssertNil(store.read(7))
    }

    // (rfm1cs-abletonmove 0.5.10) the firmware browser, one firmware: Track 1 held + step 1 opens it, step 2 is All, a
    // pad picks a firmware, the jog's press asks the app to play it (FW_LOAD, slot 0, the id)
    func testTheBrowserAsksToPlayAFirmware() {
        XCTAssertTrue(until { Int(self.status().state) == Int(RFMM_CONNECTED) })
        let names = [("alpha", "Alpha"), ("beta", "Beta")]
        var keep: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafePointer<CChar>? { let p = strdup(s)!; keep.append(p); return UnsafePointer(p) }
        let list = names.map { rfmm_fw_t(id: c($0.0), name: c($0.1), version: c("1.0"), installed: c("1.0"), desc: c("A test."),
                                         thumb: nil, cats: Int32(RFMM_CAT_SYNTH), cat: 0, virt: 0) }
        list.withUnsafeBufferPointer { rfmm_fw_list(m, $0.baseAddress, Int32($0.count)) }
        keep.forEach { free($0) }                                    // (copied: the array may go)
        rfmm_fw_slot(m, "alpha")
        fake.cc(43, 127)                                             // Track 1 held + step 1: the projects view
        Thread.sleep(forTimeInterval: 0.03)
        fake.input([0x09, 0x90, 16, 127]); Thread.sleep(forTimeInterval: 0.03); fake.input([0x08, 0x80, 16, 0])
        Thread.sleep(forTimeInterval: 0.03)
        fake.cc(43, 0)
        Thread.sleep(forTimeInterval: 0.05)
        fake.input([0x09, 0x90, 17, 127]); Thread.sleep(forTimeInterval: 0.03); fake.input([0x08, 0x80, 17, 0])   // All
        Thread.sleep(forTimeInterval: 0.05)
        fake.pad(25, 100); Thread.sleep(forTimeInterval: 0.03); fake.pad(25, 0)   // the second cell: Beta
        Thread.sleep(forTimeInterval: 0.05)
        fake.button(3)                                               // the jog's press
        var r = rfmm_request_t()
        var data = [UInt8](repeating: 0, count: 256)
        var id = ""
        XCTAssertTrue(until {
            while data.withUnsafeMutableBufferPointer({ rfmm_take_request(self.m, &r, $0.baseAddress, 256) }) != 0 {
                if Int(r.kind) == Int(RFMM_REQ_FW_LOAD) { id = String(decoding: data[0..<Int(r.len)], as: UTF8.self) }
            }
            return !id.isEmpty
        }, "FW_LOAD")
        XCTAssertEqual(id, "beta")
        XCTAssertEqual(r.slot, 0, "one firmware: always slot 0")
        rfmm_fw_progress(m, "beta", 100)
        rfmm_fw_slot(m, "beta")
    }

    @MainActor func testTheFirmwareList() {
        XCTAssertEqual(MoveController.cat("Groovebox"), 1)
        XCTAssertEqual(MoveController.cats("Drums"), Int(RFMM_CAT_DRUMS))
        XCTAssertEqual(MoveController.cat(""), 255)
        XCTAssertEqual(MoveController.ascii("Café “quoted” — ok\nnext"), "Cafe \"quoted\" - ok next")
        let img = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        img.setFillColor(gray: 1, alpha: 1)
        img.fill(CGRect(x: 0, y: 0, width: 4, height: 8))           // the left half white
        let t = MoveController.thumb(img.makeImage()!)!
        XCTAssertEqual(t.count, Int(RFMM_FW_THUMB_BYTES))
        XCTAssertEqual(t[0], 0xFF, "a white left half lit")
        XCTAssertEqual(t[7], 0x00, "a black right half dark")
        var a = CoreInfo(id: "fizz"); a.name = "FIZZ"; a.version = "0.12"
        var b1 = CoreInfo(id: "rfm1:aa"); b1.coreID = "felucca"; b1.kind = "wasm"; b1.name = "Felucca"; b1.version = "1.8.1"
        var b2 = b1; b2.id = "rfm1:bb"; b2.version = "1.8.2"
        let l = MoveController.firmwareList(catalog: nil, cores: [b1, a, b2], current: b1)
        XCTAssertEqual(l.map(\.id), ["felucca", "fizz"], "A-Z by name, one entry an id")
        XCTAssertEqual(l[0].installed, "1.8.1", "the version playing")
        XCTAssertEqual(MoveController.installedKey("felucca", cores: [b1, a, b2], current: a), "rfm1:bb", "else the newest")
    }
}
