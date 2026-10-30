// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// A DX7 32-voice cartridge (a .syx bulk dump) for RemoteFM1 0.3.0's user banks (RemoteFM1's docs/CART-UPLOAD.md on its
// cart-upload branch): one SysEx of exactly 4104 bytes, F0 43 0n 09 20 00, 4096 bytes of packed voices (VMEM, 128 per
// voice, each 0..0x7F; a voice's name is bytes 118..127), the checksum (128 - (sum & 0x7F)) & 0x7F, F7. The unit drops
// anything else, so a dump is fixed before it is sent: the checksum recomputed (many files carry a wrong one) and the
// channel set to 0. A file may hold several dumps back to back: each is its own cartridge.

import Foundation

public struct DX7Cart: Equatable, Sendable {
    public static let size = 4104
    public static let dataSize = 4096

    /// the dump as it is sent: channel 0, the right checksum
    public let bytes: [UInt8]
    /// the 32 voice names (trailing spaces trimmed)
    public let voices: [String]
    /// the file's checksum was wrong (fixed here)
    public let checksumFixed: Bool
    /// the file's channel (fixed to 0 here)
    public let originalChannel: Int

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case wrongSize(Int)
        case notDX7
        case notCartridge
        case badByte(Int)
        case noEnd

        public var errorDescription: String? {
            switch self {
            case .empty: "The file is empty."
            case .wrongSize(let n):
                "This isn't a DX7 32-voice cartridge: it is \(n) bytes, a cartridge is \(DX7Cart.size)."
            case .notDX7: "This isn't a Yamaha DX7 SysEx file."
            case .notCartridge: "This is a DX7 file, but not a 32-voice cartridge (a single voice or another dump)."
            case .badByte(let i): "The cartridge is damaged: byte \(i) is out of range."
            case .noEnd: "The cartridge is damaged: it doesn't end with F7."
            }
        }
    }

    /// the cartridges in a file (one or more dumps back to back)
    public static func parseFile(_ data: Data) throws -> [DX7Cart] {
        let b = [UInt8](data)
        guard !b.isEmpty else { throw ParseError.empty }
        guard b.count % size == 0 else { throw ParseError.wrongSize(b.count) }
        return try stride(from: 0, to: b.count, by: size).map { try parse(Array(b[$0 ..< $0 + size])) }
    }

    /// one dump of exactly 4104 bytes
    public static func parse(_ b: [UInt8]) throws -> DX7Cart {
        guard b.count == size else { throw b.isEmpty ? ParseError.empty : ParseError.wrongSize(b.count) }
        guard b[0] == 0xF0, b[1] == 0x43 else { throw ParseError.notDX7 }
        guard b[2] & 0xF0 == 0, b[3] == 0x09, b[4] == 0x20, b[5] == 0x00 else { throw ParseError.notCartridge }
        guard b[size - 1] == 0xF7 else { throw ParseError.noEnd }
        for i in 6 ..< 6 + dataSize where b[i] > 0x7F { throw ParseError.badByte(i) }
        var out = b
        out[2] = 0
        let sum = checksum(b[6 ..< 6 + dataSize])
        out[size - 2] = sum
        let names = (0 ..< 32).map { k -> String in
            let o = 6 + k * 128 + 118
            let s = String(decoding: b[o ..< o + 10].map { (0x20 ... 0x7E).contains($0) ? $0 : 0x20 }, as: UTF8.self)
            return s.trimmingCharacters(in: .whitespaces)
        }
        return DX7Cart(bytes: out, voices: names, checksumFixed: b[size - 2] != sum, originalChannel: Int(b[2]))
    }

    public static func checksum<C: Collection>(_ data: C) -> UInt8 where C.Element == UInt8 {
        let s = data.reduce(0) { $0 &+ Int($1) }
        return UInt8((128 - (s & 0x7F)) & 0x7F)
    }
}
