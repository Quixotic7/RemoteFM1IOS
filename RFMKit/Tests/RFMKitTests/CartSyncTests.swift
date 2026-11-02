// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Syncing RemoteFM1 in the app with an FM-1: banks copied both ways from the app's kept copies (CartKeep), by CRC.

import Foundation
import XCTest
@testable import RFMKit

/// two pretend 0.3.1 units, one as "RemoteFM1 in this app", one as an FM-1
final class TwoUnits: CartTransport, @unchecked Sendable {
    let app = FakeFM1(), dev = FakeFM1()
    private let lock = NSLock()
    private var heard: (@Sendable ([UInt8]) -> Void)?
    func ports() -> [CartPort] { [CoreCartTransport.port, CartPort(id: "fm1", name: "FM-1", bluetooth: false)] }
    func listen(_ h: @escaping @Sendable ([UInt8]) -> Void) { lock.withLock { heard = h } }
    func send(_ bytes: [UInt8], to port: CartPort) async throws {
        let u = port.id == CoreCartTransport.port.id ? app : dev
        if let h = lock.withLock({ heard }) { for m in u.receive(bytes) { h(m) } }
    }
}

@MainActor
final class CartSyncTests: XCTestCase {
    private func cart(_ seed: UInt8) throws -> DX7Cart {
        var b: [UInt8] = [0xF0, 0x43, 0x00, 0x09, 0x20, 0x00] + (0..<4096).map { UInt8(($0 &* Int(seed) &+ 3) & 0x7F) }
        let sum = b[6 ..< 4102].reduce(0) { ($0 + Int($1)) & 0x7F }
        b += [UInt8((128 - sum) & 0x7F), 0xF7]
        return try DX7Cart.parse(b)
    }

    func testSyncCopiesBothWaysFromKeptCopies() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString)")
        let (a, b, c) = (try cart(3), try cart(5), try cart(7))
        let t = TwoUnits()
        var timing = CartSender.Timing()
        timing.reply = 50; timing.stored = 50; timing.poll = 1; timing.namePoll = 1; timing.nameSettle = 6
        let s = CartSender(transport: t, panel: nil, clock: SystemCartClock(), timing: timing, simulated: true)
        // a on the app's side, b on the FM-1, c on the FM-1 but never kept by the app
        _ = t.app.receive(a.bytes)
        _ = t.dev.receive(b.bytes)
        _ = t.dev.receive(c.bytes)
        CartKeep.keep(a, in: dir)
        CartKeep.keep(b, in: dir)
        XCTAssertEqual(CartKeep.cart(crc: CartKeep.crc(b), in: dir)?.bytes, b.bytes)
        XCTAssertNil(CartKeep.cart(crc: CartKeep.crc(c), in: dir))
        CartKeep.testFolder = dir
        defer { CartKeep.testFolder = nil }
        s.rescan()
        XCTAssertNotNil(s.syncPair)
        await s.sync()
        let r = try XCTUnwrap(s.lastSync)
        XCTAssertNil(r.failed)
        XCTAssertEqual(r.copied["FM-1"]?.count, 1)
        XCTAssertEqual(r.copied[CoreCartTransport.port.name]?.count, 1)
        XCTAssertEqual(r.noCopy.count, 1, "c: the app never had it")
        XCTAssertEqual(Set(t.dev.slots.values.map(\.crc)), Set([a, b, c].map(CartKeep.crc)))
        XCTAssertEqual(Set(t.app.slots.values.map(\.crc)), Set([a, b].map(CartKeep.crc)))
        XCTAssertTrue(CartSender.syncText(r).contains("no copy of"))
    }
}
