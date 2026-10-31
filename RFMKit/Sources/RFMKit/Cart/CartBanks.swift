// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RemoteFM1 0.3.1's user-bank messages (docs/CART-UPLOAD.md "0.3.1: list, replace, delete, confirm" and PROTOCOL.md
// section 8 on RemoteFM1's standalone branch): SA_INFO 0x0B requests and SA_INFO_R 0x4B replies, as RemoteFM1 SysEx
// `F0 7D 52 46 cmd <body 7-in-8 packed> F7` (remote_proto.h's rf_pack7: groups of an MSB byte, bit k for data byte k,
// then up to 7 data bytes), little endian. libremotefm1 at the vendored commit has no SA_INFO, so the small codec is
// here. FakeFM1 answers them as 0.3.1 does (the tests, the simulator, DEBUG's -cartdemo), or not at all as 0.3.0.

import Foundation

public enum SAInfo {
    public static let request: UInt8 = 0x0B
    public static let reply: UInt8 = 0x4B
    static let head: [UInt8] = [0xF0, 0x7D, 0x52, 0x46]

    public enum Op: UInt8, Sendable { case banks = 0, name = 1, target = 2, delete = 3, stored = 4 }

    public static func pack7(_ b: [UInt8]) -> [UInt8] {
        var o: [UInt8] = []
        var i = 0
        while i < b.count {
            let g = min(7, b.count - i)
            var msb: UInt8 = 0
            for k in 0 ..< g { msb |= (b[i + k] >> 7) << UInt8(k) }
            o.append(msb)
            for k in 0 ..< g { o.append(b[i + k] & 0x7F) }
            i += g
        }
        return o
    }

    public static func unpack7(_ p: [UInt8]) -> [UInt8] {
        var o: [UInt8] = []
        var msb: UInt8 = 0
        var g = 0
        for x in p {
            if g == 0 { msb = x; g = 1; continue }
            o.append((x & 0x7F) | ((msb >> UInt8(g - 1)) & 1) << 7)
            g = g == 7 ? 0 : g + 1
        }
        return o
    }

    public static func encode(cmd: UInt8, _ body: [UInt8]) -> [UInt8] { head + [cmd] + pack7(body) + [0xF7] }

    /// a whole SysEx message -> (cmd, body), nil if it isn't RemoteFM1's
    public static func decode(_ m: [UInt8]) -> (cmd: UInt8, body: [UInt8])? {
        guard m.count >= 6, Array(m.prefix(4)) == head, m.last == 0xF7 else { return nil }
        return (m[4], unpack7(Array(m[5 ..< m.count - 1])))
    }

    /// what a status byte means, in plain words (nil: done)
    public static func words(_ status: UInt8) -> String? {
        switch status {
        case 0: nil
        case 1: "The FM-1 refused the cartridge (its checksum, header or length)."
        case 2: "The FM-1 refused the request (no bank in that slot)."
        case 3: "The FM-1 was busy writing. Try again in a moment."
        case 4: "The FM-1 is in a session with a host. End it and try again."
        case 5: "The FM-1 couldn't write its flash. Its banks are as they were."
        default: "The FM-1 answered status \(status)."
        }
    }
}

/// one stored bank (BANKS)
public struct UserBank: Equatable, Sendable, Identifiable {
    public var slot: Int
    public var arrival: UInt32
    public var crc: UInt32
    public var name: String
    public var id: Int { slot }
    /// as the unit shows it
    public var label: String { "USER\(slot + 1)" }

    public init(slot: Int, arrival: UInt32, crc: UInt32, name: String) {
        self.slot = slot
        self.arrival = arrival
        self.crc = crc
        self.name = name
    }
}

/// the BANKS reply
public struct BankList: Equatable, Sendable {
    public var max: Int
    public var busy: Bool
    public var next: Int
    public var banks: [UserBank]

    public init(max: Int = 16, busy: Bool = false, next: Int, banks: [UserBank]) {
        self.max = max
        self.busy = busy
        self.next = next
        self.banks = banks
    }

    static func le32(_ b: ArraySlice<UInt8>) -> UInt32 {
        b.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    static func name(_ b: ArraySlice<UInt8>) -> String {
        String(decoding: b.map { (0x20 ... 0x7E).contains($0) ? $0 : 0x20 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    /// a BANKS reply body (starting with op 0)
    public init?(body b: [UInt8]) {
        guard b.count >= 6, b[0] == 0 else { return nil }
        let count = Int(b[2])
        guard b.count >= 6 + count * 19 else { return nil }
        max = Int(b[1])
        busy = b[3] != 0
        next = Int(b[4])
        banks = (0 ..< count).map { i in
            let o = 6 + i * 19
            return UserBank(slot: Int(b[o]), arrival: Self.le32(b[o + 1 ..< o + 5]), crc: Self.le32(b[o + 5 ..< o + 9]),
                            name: Self.name(b[o + 9 ..< o + 19]))
        }
    }

    public var body: [UInt8] {
        var b: [UInt8] = [0, UInt8(max), UInt8(banks.count), busy ? 1 : 0, UInt8(next), 16]
        for k in banks {
            b.append(UInt8(k.slot))
            for v in [k.arrival, k.crc] { b += (0 ..< 4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
            b += Array((k.name + String(repeating: " ", count: 10)).utf8.prefix(10))
        }
        return b
    }
}

/// a pretend FM-1 for FakeCartTransport: 0.3.1 (16 slots, the replies, STORED after each dump) or, `silent`, 0.3.0
public final class FakeFM1: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Int: UserBank] = [:]
    private var arrivals: UInt32 = 0
    private var target: Int?
    private var partial: [UInt8] = []
    public var silent: Bool
    /// a host session (TARGET, DELETE and dumps answer 4)
    public var inSession = false
    /// what STORED says for the next dump (0 normally; 1, 3 or 5 to test)
    public var nextDumpStatus: UInt8 = 0
    /// as the unit: a NAME is written a moment after its reply; BANKS answers busy with the old name this many times
    public var nameLag = 0
    private var pendingName: (slot: Int, name: String, left: Int)?

    public init(silent: Bool = false, banks: [UserBank] = []) {
        self.silent = silent
        for b in banks { slots[b.slot] = b; arrivals = max(arrivals, b.arrival) }
    }

    public var list: BankList {
        lock.withLock {
            let free = (0 ..< 16).first { slots[$0] == nil }
            let oldest = slots.values.min { $0.arrival < $1.arrival }?.slot ?? 0
            return BankList(next: free ?? oldest, banks: slots.values.sorted { $0.slot < $1.slot })
        }
    }

    /// bytes as sent (whole messages or Bluetooth parts) -> the messages it sends back
    public func receive(_ bytes: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for x in bytes {
            if x == 0xF0 { partial = [] }
            partial.append(x)
            if x == 0xF7 { out += message(partial); partial = [] }
        }
        return silent ? [] : out
    }

    private func reply(_ b: [UInt8]) -> [UInt8] { SAInfo.encode(cmd: SAInfo.reply, b) }

    private func message(_ m: [UInt8]) -> [[UInt8]] {
        if m.count == 4104, m[1] == 0x43, m[3] == 0x09 {
            let slot = target ?? list.next
            target = nil
            if inSession { return [reply([4, UInt8(slot), 4])] }
            if nextDumpStatus != 0 { defer { nextDumpStatus = 0 }; return [reply([4, UInt8(slot), nextDumpStatus])] }
            let name = BankList.name(m[6 + 118 ..< 6 + 128])
            lock.withLock {
                arrivals += 1
                slots[slot] = UserBank(slot: slot, arrival: arrivals, crc: crc32(m[6 ..< 4102]), name: name)
            }
            return [reply([4, UInt8(slot), 0])]
        }
        guard let (cmd, b) = SAInfo.decode(m), cmd == SAInfo.request, let op = b.first else { return [] }
        let slot = b.count > 1 ? Int(b[1]) : 0
        let has = lock.withLock { slots[slot] != nil }
        switch op {
        case 0:
            if let p = pendingName {
                if p.left > 0 { pendingName?.left -= 1; var l = list; l.busy = true; return [reply(l.body)] }
                lock.withLock { slots[p.slot]?.name = p.name }
                pendingName = nil
            }
            return [reply(list.body)]
        case 1:
            guard has, b.count > 2, b.count <= 12 else { return [reply([1, UInt8(slot), 2])] }
            if pendingName != nil { return [reply([1, UInt8(slot), 3])] }
            pendingName = (slot, BankList.name(b[2...]), nameLag)
            return [reply([1, UInt8(slot), 0])]
        case 2:
            guard slot < 16 else { return [reply([2, UInt8(slot), 2])] }
            if inSession { return [reply([2, UInt8(slot), 4])] }
            target = slot
            return [reply([2, UInt8(slot), 0])]
        case 3:
            guard has else { return [reply([3, UInt8(slot), 2])] }
            if inSession { return [reply([3, UInt8(slot), 4])] }
            _ = lock.withLock { slots.removeValue(forKey: slot) }
            return [reply([3, UInt8(slot), 0])]
        default: return [reply([op, UInt8(slot), 2])]
        }
    }
}

/// zlib's CRC-32 (BANKS's crc of the 4,096 voice bytes)
public func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes {
        c ^= UInt32(b)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
    }
    return ~c
}
