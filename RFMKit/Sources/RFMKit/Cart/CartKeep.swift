// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The cartridges the app has sent, kept so a bank can be copied between RemoteFM1 in the app and an FM-1 (the
// owner, 2026-11-01). RemoteFM1 0.3.1 can list its banks (each with the CRC-32 of its 4,096 voice bytes) but not send
// one back, so a bank is copied from the app's own copy, found by that CRC: Documents/Cartridges/<name> <crc>.syx,
// which the Files app shows (a .syx put there by hand counts too: its CRC is worked out).

import Foundation

public enum CartKeep {
    nonisolated(unsafe) static var testFolder: URL?
    public static var folder: URL {
        if let t = testFolder { return t }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Cartridges")
    }

    public static func crc(_ c: DX7Cart) -> UInt32 { crc32(c.bytes[6 ..< 4102]) }
    static func hex(_ crc: UInt32) -> String { String(format: "%08x", crc) }

    /// a sent cartridge kept (once per CRC)
    public static func keep(_ c: DX7Cart, in dir: URL = folder) {
        let h = hex(crc(c))
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let names = try? fm.contentsOfDirectory(atPath: dir.path), names.contains(where: { $0.hasSuffix(" \(h).syx") }) { return }
        let first = (c.voices.first ?? "BANK").trimmingCharacters(in: .whitespaces)
        let safe = String(first.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "_" }).prefix(20)
        try? Data(c.bytes).write(to: dir.appendingPathComponent("\(safe.isEmpty ? "BANK" : String(safe)) \(h).syx"), options: .atomic)
    }

    /// the kept cartridge with this CRC, nil: none (by name first, then any .syx in the folder)
    public static func cart(crc want: UInt32, in dir: URL = folder) -> DX7Cart? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let h = hex(want)
        let syx = names.filter { $0.lowercased().hasSuffix(".syx") }
        for n in syx.sorted(by: { a, _ in a.hasSuffix(" \(h).syx") }) {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n)),
                  let carts = try? DX7Cart.parseFile(d) else { continue }
            if let c = carts.first(where: { crc($0) == want }) { return c }
        }
        return nil
    }
}
