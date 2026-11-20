// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The Move's firmware browser on this app: one firmware, no FX (rfm1cs-abletonmove 0.5.10's host guide, section 23).
// The list is what Get firmware offers (FirmwareStore.list: its feeds and rules) plus the firmware here (built in,
// imported), A-Z by name, one entry per id. Pressing the jog plays one here, as choosing it in the app does (the
// newest version here, or the one playing). A download goes through the app's own Get firmware install. Firmware
// stays out of the app: nothing is built in for the Move.

import CoreGraphics
import Foundation
import RFMCore

/// one entry the Move lists (without its thumbnail)
struct MoveFirmware: Equatable {
    var id: String, name: String, version: String
    var installed: String                       // "" not here
    var desc: String
    var cats: Int, cat: Int                     // RFMM_CAT_* bits; the main one 0..4, 255 none
    var virt: Bool
}

extension MoveController {
    /// the catalog the Move's browser lists and downloads from (the app's Get firmware)
    public func attach(catalog: FirmwareStore) {
        self.catalog = catalog
        firmwares = nil
        syncFirmwares()
    }

    /// the list given to the Move again when it changed (a check of the feeds, an install, a firmware imported)
    func syncFirmwares() {
        guard let player else { return }
        let list = Self.firmwareList(catalog: catalog, cores: player.cores, current: player.current)
        guard list != firmwares else { return }
        firmwares = list
        for f in list where thumbs[f.id] == nil {
            thumbs[f.id] = FirmwareThumbs.shared.image(f.id).flatMap(Self.thumb) ?? []
        }
        var keep: [UnsafeMutableRawPointer] = []
        defer { keep.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar>? {
            guard let p = strdup(s) else { return nil }
            keep.append(UnsafeMutableRawPointer(p))
            return UnsafePointer(p)
        }
        let e: [rfmm_fw_t] = list.map { f in
            var t: UnsafePointer<UInt8>? = nil
            if let b = thumbs[f.id], b.count == Int(RFMM_FW_THUMB_BYTES), let p = malloc(b.count) {
                keep.append(p)
                b.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: b.count) }
                t = UnsafePointer(p.assumingMemoryBound(to: UInt8.self))
            }
            return rfmm_fw_t(id: c(f.id), name: c(f.name), version: c(f.version),
                             installed: f.installed.isEmpty ? nil : c(f.installed), desc: f.desc.isEmpty ? nil : c(f.desc),
                             thumb: t, cats: Int32(f.cats), cat: Int32(f.cat), virt: f.virt ? 1 : 0)
        }
        e.withUnsafeBufferPointer { rfmm_fw_list(link, $0.baseAddress, Int32($0.count)) }
        slotID = nil                                // (and what plays, after the list)
        syncSlot()
    }

    /// the Move shows the firmware playing here
    func syncSlot() {
        let id = player?.current?.firmwareID ?? ""
        guard id != slotID else { return }
        slotID = id
        id.withCString { rfmm_fw_slot(link, id.isEmpty ? nil : $0) }
    }

    /// FW_LOAD: that firmware played here (as choosing it in the app)
    func play(_ id: String) {
        guard let player, let key = Self.installedKey(id, cores: player.cores, current: player.current) else {
            progress(id, Int(RFMM_FW_FAILED))
            return
        }
        if player.selected != key { player.select(key) }
        progress(id, 100)
        slotID = nil
        syncSlot()
    }

    /// FW_DOWNLOAD: Get firmware's install (a download or an update), its progress shown on the Move
    func download(_ id: String) {
        guard let catalog, let player,
              let e = catalog.list(builtIn: player.cores.filter { !$0.imported }).first(where: { $0.id == id }) else {
            progress(id, Int(RFMM_FW_FAILED))
            return
        }
        guard catalog.progress == nil else {       // (one download at a time, as in the app)
            progress(id, Int(RFMM_FW_BUSY))
            return
        }
        progress(id, 0)
        Task { @MainActor [weak self] in
            let watch = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let p = catalog.progress, let f = p.fraction { self?.progress(id, min(99, Int(f * 100))) }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            let f = await catalog.install(e)
            watch.cancel()
            guard let self else { return }
            if let f {
                f.version.withCString { rfmm_fw_installed(link, id, $0) }
                progress(id, 100)
                firmwares = nil
                syncFirmwares()
            } else {
                progress(id, Int(RFMM_FW_FAILED))
            }
        }
    }

    private func progress(_ id: String, _ pct: Int) { rfmm_fw_progress(link, id, Int32(pct)) }

    // MARK: the list

    static func firmwareList(catalog: FirmwareStore?, cores: [CoreInfo], current: CoreInfo?) -> [MoveFirmware] {
        var byID: [String: MoveFirmware] = [:]
        let info = Dictionary((catalog?.available ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let catalog {
            for e in catalog.list(builtIn: cores.filter { !$0.imported }) where !e.id.isEmpty {
                byID[e.id] = MoveFirmware(id: e.id, name: e.name.isEmpty ? e.id : e.name, version: e.version,
                                          installed: catalog.state(e).installedVersion ?? "",
                                          desc: ascii(e.about.isEmpty ? e.summary : e.about),
                                          cats: cats(e.category), cat: cat(e.category), virt: e.isVirtual)
            }
        }
        for c in cores {
            let id = c.firmwareID
            guard !id.isEmpty, let key = installedKey(id, cores: cores, current: current),
                  let here = cores.first(where: { $0.id == key }) else { continue }
            if var f = byID[id] {
                if f.installed.isEmpty { f.installed = here.version; byID[id] = f }
                continue
            }
            let e = info[id]
            let category = e?.category ?? c.family
            byID[id] = MoveFirmware(id: id, name: here.name.isEmpty ? id : here.name, version: here.version,
                                    installed: here.version,
                                    desc: ascii(e.map { $0.about.isEmpty ? $0.summary : $0.about } ?? ""),
                                    cats: cats(category), cat: cat(category), virt: here.isVirtual)
        }
        return byID.values.sorted {
            let o = $0.name.localizedCaseInsensitiveCompare($1.name)
            return o == .orderedSame ? $0.id < $1.id : o == .orderedAscending
        }
    }

    /// the catalog key of the version here a jog press plays: the one playing, else the newest
    nonisolated static func installedKey(_ id: String, cores: [CoreInfo], current: CoreInfo?) -> String? {
        if let current, current.firmwareID == id { return current.id }
        return cores.filter { $0.firmwareID == id }.max { FirmwareVersion.less($0.version, $1.version) }?.id
    }

    nonisolated static let categories = ["synth", "groovebox", "chords", "drums", "other"]
    nonisolated static func cat(_ category: String) -> Int {
        let c = category.lowercased()
        return categories.firstIndex { c.hasPrefix($0) } ?? (c.isEmpty ? 255 : 4)
    }
    nonisolated static func cats(_ category: String) -> Int { let c = cat(category); return c == 255 ? 0 : 1 << c }

    /// the Move's text is ASCII: accents dropped, other letters spelled in Latin, the rest left out
    nonisolated static func ascii(_ s: String, max: Int = 1000) -> String {
        var t = s.applyingTransform(.toLatin, reverse: false) ?? s
        t = t.applyingTransform(.stripDiacritics, reverse: false) ?? t
        let swaps: [Character: String] = ["\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"",
                                          "\u{2013}": "-", "\u{2014}": "-", "\u{2026}": "...", "\u{00B7}": "-"]
        var out = ""
        for ch in t {
            if let r = swaps[ch] { out += r; continue }
            guard let a = ch.asciiValue else { continue }
            out.append(a == 10 || a == 13 || a == 9 ? " " : (a >= 32 && a < 127 ? ch : " "))
        }
        out = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(out.prefix(max))
    }

    /// a catalog picture as the Move's thumbnail: squeezed to 64 x 64, then an Atkinson dither on its luma (1: lit)
    nonisolated static func thumb(_ image: CGImage) -> [UInt8]? {
        let n = 64
        var gray = [UInt8](repeating: 0, count: n * n)
        let ok = gray.withUnsafeMutableBytes { b -> Bool in
            guard let ctx = CGContext(data: b.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var v = gray.map(Int.init)
        var out = [UInt8](repeating: 0, count: n * n / 8)
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let lit = v[i] >= 128
                if lit { out[i >> 3] |= 0x80 >> UInt8(i & 7) }
                let err = (v[i] - (lit ? 255 : 0)) / 8
                for (dx, dy) in [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)] {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, xx < n, yy < n { v[yy * n + xx] += err }
                }
            }
        }
        return out
    }
}
