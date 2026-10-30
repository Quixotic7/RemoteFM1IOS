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
        XCTAssertEqual(log.events, ["0 pause", "400 send 4104", "1400 send 4104", "1400 resume true"])
        XCTAssertEqual(t.sent.map(\.bytes), [Self.dump(), Self.dump(seed: 9)])
        XCTAssertEqual(t.sent.map(\.port), ["1", "1"])
        XCTAssertTrue(p.running)
        XCTAssertEqual(s.resultText, "Sent 2 cartridges: the FM-1 should now show the last one's USER bank.")
    }

    @MainActor func testBluetoothPaced() async {
        let (s, t, _, log) = make(ports: [CartPort(id: "b", name: "FM-1 7938", bluetooth: true)])
        s.add(CartFile(name: "a.syx", data: Data(Self.dump())))
        await s.send()
        XCTAssertEqual(t.sent.count, 9)                       // 8 × 512 + 8
        XCTAssertEqual(t.sent.flatMap(\.bytes), Self.dump())
        XCTAssertEqual(log.events.first, "0 pause")
        XCTAssertEqual(log.events[1], "400 send 512")
        XCTAssertEqual(log.events[9], "1200 send 8")
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
        XCTAssertEqual(t.sent.map(\.port), ["1"])
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
}
