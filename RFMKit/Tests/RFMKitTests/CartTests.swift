// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// DX7Cart (the parser and its fixes) and CartSender against a fake transport, panel and clock: the panel paused, 400 ms,
// the fixed dump's bytes exactly, 1 s between dumps, Bluetooth in 512-byte parts, the panel started again.

import Foundation
@testable import RFMKit
import XCTest

final class CartTests: XCTestCase {
    /// a cartridge of the real shape: 32 voices "VOICE 01".."VOICE 32", varied data bytes, a right checksum
    static func dump(channel: UInt8 = 0, seed: Int = 0) -> [UInt8] {
        var b: [UInt8] = [0xF0, 0x43, channel, 0x09, 0x20, 0x00]
        for k in 0 ..< 32 {
            var v = (0 ..< 118).map { UInt8(($0 * 7 + k * 13 + seed) & 0x7F) }
            v += Array(String(format: "VOICE %02d  ", k + 1).utf8.prefix(10))
            b += v
        }
        b.append(DX7Cart.checksum(b[6 ..< 4102]))
        b.append(0xF7)
        return b
    }

    func testValid() throws {
        let d = Self.dump()
        XCTAssertEqual(d.count, 4104)
        let c = try DX7Cart.parse(d)
        XCTAssertEqual(c.bytes, d)
        XCTAssertFalse(c.checksumFixed)
        XCTAssertEqual(c.voices.count, 32)
        XCTAssertEqual(c.voices.first, "VOICE 01")
        XCTAssertEqual(c.voices.last, "VOICE 32")
    }

    func testBadChecksumFixed() throws {
        var d = Self.dump()
        let right = d[4102]
        d[4102] = (right + 5) & 0x7F
        let c = try DX7Cart.parse(d)
        XCTAssertTrue(c.checksumFixed)
        XCTAssertEqual(c.bytes, Self.dump())
        XCTAssertEqual(CartFile(name: "a.syx", data: Data(d)).fixes, "checksum corrected")
    }

    func testChannelFixed() throws {
        let c = try DX7Cart.parse(Self.dump(channel: 5))
        XCTAssertEqual(c.originalChannel, 5)
        XCTAssertEqual(c.bytes[2], 0)
        XCTAssertEqual(c.bytes, Self.dump())
    }

    func testRejected() {
        XCTAssertThrowsError(try DX7Cart.parseFile(Data(Self.dump().dropLast()))) {
            XCTAssertEqual($0 as? DX7Cart.ParseError, .wrongSize(4103))
        }
        XCTAssertThrowsError(try DX7Cart.parseFile(Data())) { XCTAssertEqual($0 as? DX7Cart.ParseError, .empty) }
        var single = Self.dump()
        single[3] = 0x00                                      // (format 0: a single voice's header)
        XCTAssertThrowsError(try DX7Cart.parse(single)) { XCTAssertEqual($0 as? DX7Cart.ParseError, .notCartridge) }
        var other = Self.dump()
        other[1] = 0x41
        XCTAssertThrowsError(try DX7Cart.parse(other)) { XCTAssertEqual($0 as? DX7Cart.ParseError, .notDX7) }
        var high = Self.dump()
        high[100] = 0x80
        XCTAssertThrowsError(try DX7Cart.parse(high)) { XCTAssertEqual($0 as? DX7Cart.ParseError, .badByte(100)) }
        let f = CartFile(name: "x.syx", data: Data(repeating: 0, count: 163))
        XCTAssertTrue(f.carts.isEmpty)
        XCTAssertNotNil(f.error)
    }

    func testTwoDumpsInOneFile() throws {
        let cs = try DX7Cart.parseFile(Data(Self.dump() + Self.dump(seed: 3)))
        XCTAssertEqual(cs.count, 2)
    }

    // MARK: the sender

    /// one timeline of what happened, in order
    final class Log: @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        var now = 0
        func add(_ s: String) { lock.withLock { events.append("\(now) \(s)") } }
    }

    struct FakeClock: CartClock {
        let log: Log
        func sleep(ms: Int) async {
            log.lock.withLock { log.now += ms }
        }
    }

    @MainActor final class FakePanel: CartPanelPausing {
        let log: Log
        var running = true
        init(_ log: Log) { self.log = log }
        func pauseForCart() async -> Bool {
            log.add("pause")
            defer { running = false }
            return running
        }
        func resumeAfterCart(restart: Bool) {
            log.add("resume \(restart)")
            running = restart
        }
    }

    private var keep: [AnyObject] = []                  // (the sender's panel is weak, as the app's link)

    @MainActor func make(ports: [CartPort]) -> (CartSender, FakeCartTransport, FakePanel, Log) {
        let log = Log()
        let t = FakeCartTransport(ports: ports)
        t.onSend = { log.add("send \($0.count)") }
        let p = FakePanel(log)
        keep.append(p)
        return (CartSender(transport: t, panel: p, clock: FakeClock(log: log), simulated: true), t, p, log)
    }

    @MainActor func testSendsFixedDumpsInOrder() async throws {
        let (s, t, p, log) = make(ports: [CartPort(id: "1", name: "FM-1", bluetooth: false)])
        var bad = Self.dump(channel: 3)
        bad[4102] ^= 0x11
        s.add(CartFile(name: "a.syx", data: Data(bad)))
        s.add(CartFile(name: "b.syx", data: Data(Self.dump(seed: 9))))
        await s.send()
        XCTAssertEqual(s.state, .sent(2))
        // (BANKS first, no reply in 1 s: 0.3.0, the plain send)
        XCTAssertEqual(log.events, ["0 send 8", "1000 pause", "1400 send 4104", "2400 send 4104", "2400 resume true"])
        XCTAssertEqual(s.firmware, .v030)
        XCTAssertEqual(t.sent.dropFirst().map(\.bytes), [Self.dump(), Self.dump(seed: 9)])
        XCTAssertEqual(t.sent.map(\.port), ["1", "1", "1"])
        XCTAssertTrue(p.running)
        XCTAssertEqual(s.resultText, "Sent 2 cartridges: the FM-1 should now show the last one's USER bank.")
    }

    @MainActor func testBluetoothPaced() async {
        let (s, t, _, log) = make(ports: [CartPort(id: "b", name: "FM-1 7938", bluetooth: true)])
        s.add(CartFile(name: "a.syx", data: Data(Self.dump())))
        await s.send()
        XCTAssertEqual(t.sent.count, 10)                      // BANKS, then 8 × 512 + 8
        XCTAssertEqual(t.sent.dropFirst().flatMap(\.bytes), Self.dump())
        XCTAssertEqual(log.events[1], "1000 pause")
        XCTAssertEqual(log.events[2], "1400 send 512")
        XCTAssertEqual(log.events[10], "2200 send 8")
        XCTAssertEqual(s.resultText, "Sent: the FM-1 should now show the new USER bank.")
    }

    @MainActor func testSeveralPortsAsks() async {
        let (s, t, _, log) = make(ports: [CartPort(id: "1", name: "FM-1", bluetooth: false),
                                          CartPort(id: "2", name: "FM-1 7938", bluetooth: true)])
        s.add(CartFile(name: "a.syx", data: Data(Self.dump())))
        await s.send()
        XCTAssertEqual(s.state, .failed("Choose which FM-1 to send to."))
        XCTAssertTrue(log.events.isEmpty, "the panel isn't touched")
        s.chosen = "1"
        await s.send()
        XCTAssertEqual(t.sent.map(\.port), ["1", "1"])
    }

    @MainActor func testNoPortNoCart() async {
        let (s, _, _, log) = make(ports: [])
        s.add(CartFile(name: "a.syx", data: Data(Self.dump())))
        await s.send()
        if case .failed = s.state {} else { XCTFail() }
        let (s2, _, _, _) = make(ports: [CartPort(id: "1", name: "FM-1", bluetooth: false)])
        s2.add(CartFile(name: "bad.syx", data: Data([0xF0, 0xF7])))
        await s2.send()
        XCTAssertEqual(s2.state, .failed("No cartridge to send."))
        XCTAssertTrue(log.events.isEmpty)
    }

    // MARK: 0.3.1's banks (CartBanks.swift)

    func testPack7() {
        let b = (0 ..< 256).map { UInt8($0) }
        let p = SAInfo.pack7(b)
        XCTAssertEqual(p.count, 256 + (256 + 6) / 7)
        XCTAssertTrue(p.allSatisfy { $0 < 0x80 })
        XCTAssertEqual(SAInfo.unpack7(p), b)
        // remote_proto's golden ECHO and the spec's TARGET slot 4
        XCTAssertEqual(SAInfo.pack7([0x00, 0x7F, 0x80, 0xFF, 1, 2, 3, 0xAA]), [0x0C, 0x00, 0x7F, 0x00, 0x7F, 0x01, 0x02, 0x03, 0x01, 0x2A])
        XCTAssertEqual(SAInfo.encode(cmd: 0x0B, [2, 4]), [0xF0, 0x7D, 0x52, 0x46, 0x0B, 0x00, 0x02, 0x04, 0xF7])
        let r = SAInfo.decode([0xF0, 0x7D, 0x52, 0x46, 0x4B, 0x00, 0x02, 0x04, 0x00, 0xF7])
        XCTAssertEqual(r?.cmd, 0x4B)
        XCTAssertEqual(r?.body, [2, 4, 0])
        XCTAssertNil(SAInfo.decode([0xF0, 0x43, 0xF7]))
    }

    func testBankListBody() {
        let l = BankList(next: 1, banks: [UserBank(slot: 0, arrival: 0x0102_0304, crc: 0xDEAD_BEEF, name: "BRASS 1"),
                                          UserBank(slot: 4, arrival: 9, crc: 0x8000_0001, name: "PIANO 2")])
        XCTAssertEqual(Array(l.body.prefix(6)), [0, 16, 2, 0, 1, 16])
        XCTAssertEqual(Array(l.body[7 ..< 11]), [4, 3, 2, 1])
        XCTAssertEqual(BankList(body: SAInfo.unpack7(SAInfo.pack7(l.body))), l)
        XCTAssertNil(BankList(body: [0, 16, 3, 0, 0, 16]))
        XCTAssertEqual(crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    @MainActor func make031(_ fm1: FakeFM1, bluetooth: Bool = false) -> (CartSender, FakeCartTransport, FakePanel, Log) {
        let log = Log()
        let t = FakeCartTransport(ports: [CartPort(id: "1", name: "FM-1", bluetooth: bluetooth)], fm1: fm1)
        t.onSend = { log.add("send \($0.count)") }
        let p = FakePanel(log)
        keep.append(p)
        return (CartSender(transport: t, panel: p, clock: FakeClock(log: log), simulated: true), t, p, log)
    }

    static let two = [UserBank(slot: 0, arrival: 1, crc: 0, name: "BRASS 1"), UserBank(slot: 4, arrival: 2, crc: 0, name: "PIANO 2")]

    @MainActor func testListWithoutPause() async {
        let (s, _, _, log) = make031(FakeFM1(banks: Self.two))
        await s.refresh()
        XCTAssertEqual(s.firmware, .v031)
        XCTAssertEqual(s.banks?.banks.map(\.label), ["USER1", "USER5"])
        XCTAssertEqual(s.banks?.banks.map(\.name), ["BRASS 1", "PIANO 2"])
        XCTAssertEqual(s.banks?.next, 1)
        XCTAssertEqual(log.events, ["0 send 8"], "no pause for the list")
        XCTAssertEqual(s.state, .idle)
    }

    @MainActor func testSendConfirmedByStored() async {
        let (s, t, p, log) = make031(FakeFM1(banks: Self.two), bluetooth: true)
        s.add(CartFile(name: "a.syx", data: Data(Self.dump())))
        s.add(CartFile(name: "b.syx", data: Data(Self.dump(seed: 4))))
        await s.send()
        XCTAssertEqual(s.state, .sent(2))
        XCTAssertEqual(s.storedSlots, [1, 2])
        XCTAssertEqual(s.resultText, "Stored as USER2, USER3.")
        XCTAssertEqual(s.banks?.banks.map(\.slot), [0, 1, 2, 4], "the list read again")
        XCTAssertEqual(s.banks?.banks[1].name, "VOICE 01")
        XCTAssertEqual(s.banks?.banks[1].crc, crc32(Self.dump()[6 ..< 4102]))
        XCTAssertEqual(t.sent.filter { $0.bytes.count == 512 }.count, 16, "Bluetooth still paced")
        XCTAssertEqual(log.events.filter { $0.hasSuffix("pause") }.count, 1)
        XCTAssertEqual(log.events.last, "\(log.now) resume true")
        XCTAssertTrue(p.running)
        XCTAssertEqual(log.now, 2000, "400 ms, 2 × 8 Bluetooth gaps, no 1 s wait: STORED says when")
    }

    @MainActor func testReplace() async {
        let fm1 = FakeFM1(banks: Self.two)
        let (s, t, _, log) = make031(fm1)
        await s.refresh()
        await s.replace(slot: 4, with: CartFile(name: "new.syx", data: Data(Self.dump(seed: 7))))
        XCTAssertEqual(s.state, .done("USER5 replaced with new.syx."))
        XCTAssertEqual(s.banks?.banks.count, 2)
        XCTAssertEqual(s.banks?.banks[1].arrival, 3)
        XCTAssertEqual(SAInfo.decode(t.sent[1].bytes)?.body, [2, 4], "TARGET before the dump")
        XCTAssertEqual(t.sent[2].bytes.count, 4104)
        XCTAssertEqual(log.events[1], "0 pause")
        // a refused dump says so in words
        fm1.nextDumpStatus = 1
        await s.replace(slot: 0, with: CartFile(name: "x.syx", data: Data(Self.dump())))
        XCTAssertEqual(s.resultText, SAInfo.words(1))
        // a file of two
        await s.replace(slot: 0, with: CartFile(name: "two.syx", data: Data(Self.dump() + Self.dump(seed: 1))))
        if case .failed(let e) = s.state { XCTAssertTrue(e.contains("holds 2")) } else { XCTFail() }
    }

    @MainActor func testDeleteAndRename() async {
        let fm1 = FakeFM1(banks: Self.two)
        let (s, _, _, log) = make031(fm1)
        await s.refresh()
        await s.delete(slot: 0)
        XCTAssertEqual(s.state, .done("USER1 removed."))
        XCTAssertEqual(s.banks?.banks.map(\.slot), [4])
        XCTAssertTrue(log.events.contains { $0.hasSuffix("pause") })
        await s.delete(slot: 0)
        XCTAssertEqual(s.resultText, SAInfo.words(2))
        let before = log.events.filter { $0.hasSuffix("pause") }.count
        await s.rename(slot: 4, to: "My Pianos!!!")
        XCTAssertEqual(s.state, .done("USER5 renamed."))
        XCTAssertEqual(s.banks?.banks.first?.name, "My Pianos!")
        XCTAssertEqual(log.events.filter { $0.hasSuffix("pause") }.count, before, "NAME needs no pause")
        fm1.inSession = true
        await s.delete(slot: 4)
        XCTAssertEqual(s.resultText, SAInfo.words(4))
    }

    @MainActor func testSilentIsV030() async {
        let (s, t, _, log) = make031(FakeFM1(silent: true))
        await s.refresh()
        XCTAssertEqual(s.firmware, .v030)
        XCTAssertNil(s.banks)
        XCTAssertEqual(log.now, 1000, "1 s timeout")
        await s.replace(slot: 0, with: CartFile(name: "a.syx", data: Data(Self.dump())))
        if case .failed = s.state {} else { XCTFail() }
        s.add(CartFile(name: "a.syx", data: Data(Self.dump())))
        await s.send()
        XCTAssertEqual(s.state, .sent(1))
        XCTAssertEqual(s.resultText, "Sent: the FM-1 should now show the new USER bank.")
        XCTAssertEqual(t.sent.last?.bytes.count, 4104)
    }

    @MainActor func testNoStoredTimesOut() async {
        let fm1 = FakeFM1()
        let (s, _, p, log) = make031(fm1)
        await s.refresh()
        fm1.silent = true                                     // (answers nothing from now on)
        s.add(CartFile(name: "a.syx", data: Data(Self.dump())))
        let t0 = log.now
        await s.send()
        XCTAssertEqual(s.resultText, "Cartridge 1: the FM-1 didn't confirm it. Check its screen.")
        XCTAssertGreaterThanOrEqual(log.now - t0, 2400)
        XCTAssertTrue(p.running, "the panel started again")
    }
}
