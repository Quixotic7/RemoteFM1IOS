// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The firmware list's thumbnails. Shipped first: Resources/Thumbs/<firmwareID>.png, each firmware's LCD after a chord
// of white keys and PLAY (Tests' ThumbnailMaker makes them for the built-in cores and the released .rfm1 files).
// Others (a firmware the app doesn't know): its own LCD, captured once it has run ~3 s after boot, as a 240x240 PNG
// in the App Group's Thumbs/<firmwareID>.png, so the app and every AU instance show the same ones. An all-black (or nearly) frame isn't kept: the capture retries on the next frames up to ~10 s
// after the 3 s, then gives up until the firmware boots again.
// FirmwareInfo: what the Firmware panel says about the running firmware (name, version, author, the catalog's one-line
// tag and description, the source link), from the site catalog's details by the firmware's id, else the core's own.

import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@MainActor @Observable public final class FirmwareThumbs {
    public static let shared = FirmwareThumbs()

    @ObservationIgnored public let directory: URL
    /// bumped when a thumbnail is written (the tiles read again)
    public private(set) var generation = 0
    @ObservationIgnored private var cache: [String: CGImage] = [:]
    @ObservationIgnored private var missing: Set<String> = []

    /// directory nil: the App Group's Thumbs (else Application Support/Thumbs)
    public init(directory: URL? = nil) {
        let fm = FileManager.default
        self.directory = directory ?? RFMShared.groupContainer()?.appendingPathComponent("Thumbs")
            ?? (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory)
                .appendingPathComponent("Thumbs")
    }

    public func url(_ id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".png")
    }

    /// a shipped thumbnail (the app's resources)
    public nonisolated static func shipped(_ id: String) -> URL? {
        Bundle.module.url(forResource: id, withExtension: "png", subdirectory: "Thumbs")
    }

    public func exists(_ id: String) -> Bool { Self.shipped(id) != nil || FileManager.default.fileExists(atPath: url(id).path) }

    /// the thumbnail (cached; read again after another process wrote one: `reload`)
    public func image(_ id: String) -> CGImage? {
        _ = generation
        if let c = cache[id] { return c }
        if missing.contains(id) { return nil }
        guard let src = CGImageSourceCreateWithURL((Self.shipped(id) ?? url(id)) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { missing.insert(id); return nil }
        cache[id] = img
        return img
    }

    /// forgets what was read (the other process may have written thumbnails)
    public func reload() {
        cache = [:]
        missing = []
        generation += 1
    }

    /// writes the frame (RGBX, 240x240) as the firmware's thumbnail; false: blank or not written
    @discardableResult
    public func save(rgba: [UInt8], width: Int = 240, height: Int = 240, id: String) -> Bool {
        guard !id.isEmpty, rgba.count >= width * height * 4, !Self.isBlank(rgba),
              let img = Self.image(rgba, width: width, height: height) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).png")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { return false }
        let fm = FileManager.default
        try? fm.removeItem(at: url(id))
        guard (try? fm.moveItem(at: tmp, to: url(id))) != nil else { try? fm.removeItem(at: tmp); return false }
        cache[id] = img
        missing.remove(id)
        generation += 1
        return true
    }

    /// nearly all black: fewer than 0.5 % of the pixels with a channel over 24
    public nonisolated static func isBlank(_ rgba: [UInt8]) -> Bool {
        let n = rgba.count / 4
        guard n > 0 else { return true }
        var lit = 0
        for i in 0..<n {
            let o = i * 4
            if rgba[o] > 24 || rgba[o + 1] > 24 || rgba[o + 2] > 24 { lit += 1 }
        }
        return lit * 200 < n
    }

    nonisolated static func image(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let p = CGDataProvider(data: Data(rgba.prefix(width * height * 4)) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: p, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// when to take a firmware's thumbnail: fed every new frame with the running firmware's id and whether it booted
@MainActor public final class ThumbCapture {
    public let thumbs: FirmwareThumbs
    public var delay: TimeInterval = 3
    public var window: TimeInterval = 10
    private var id = ""
    private var since: TimeInterval?
    private var done = false

    public init(thumbs: FirmwareThumbs = .shared) { self.thumbs = thumbs }

    /// true when this frame was written
    @discardableResult
    public func frame(_ rgba: [UInt8], id: String?, booted: Bool,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let id = id ?? ""
        guard booted, !id.isEmpty else { since = nil; return false }
        if id != self.id || since == nil {
            self.id = id
            since = now
            done = thumbs.exists(id)
        }
        guard !done, let s = since, now - s >= delay else { return false }
        if now - s > delay + window { done = true; return false }
        if thumbs.save(rgba: rgba, id: id) { done = true; return true }
        return false
    }
}

/// what the Firmware panel says about a firmware
public struct FirmwareInfo: Equatable, Sendable {
    public var id = "", name = "", version = "", author = "", tag = "", about = "", license = ""
    /// the firmware's source on GitHub (or wherever its manifest points); nil: none known
    public var source: URL?

    public init() {}

    /// from the catalog's details by the firmware's id (built-in cores and imported files alike), else the core's own
    public static func lookup(_ c: CoreInfo, details: [String: AvailableFirmware]) -> FirmwareInfo {
        var i = FirmwareInfo()
        i.id = c.firmwareID
        i.name = c.name
        i.version = c.version
        i.license = c.license
        let d = details[c.firmwareID] ?? details[c.id] ?? details[c.firmwareID.lowercased()]
        if let d {
            if i.name.isEmpty { i.name = d.displayName }
            i.author = d.author
            i.tag = d.summary
            i.about = d.about
            if i.license.isEmpty { i.license = d.license }
        }
        if i.about.isEmpty { i.about = c.credits.trimmingCharacters(in: .whitespacesAndNewlines) }
        // the catalog's source (at its version), its repo; the core's manifest otherwise
        var links: [String] = []
        if let d {
            let same = FirmwareVersion.compare(d.version, c.version) == .orderedSame
            if same || d.repo.isEmpty { links.append(d.sourceURL) }
            if !d.repo.isEmpty { links.append("https://github.com/\(d.repo)") }
        }
        links.append(c.sourceURL)
        i.source = links.lazy.compactMap { s -> URL? in
            guard !s.isEmpty, let u = URL(string: s), let sc = u.scheme?.lowercased(), sc == "https" || sc == "http" else { return nil }
            return u
        }.first
        return i
    }
}

/// the catalog's details shared with the AU through the App Group (the AU reads no feeds)
public enum FirmwareDetailsShare {
    public static func url(_ dir: URL? = RFMShared.groupContainer()) -> URL? {
        dir?.appendingPathComponent("catalog-details.json")
    }

    public static func save(_ d: [String: AvailableFirmware], dir: URL? = RFMShared.groupContainer()) {
        guard !d.isEmpty, let u = url(dir), let data = try? JSONEncoder().encode(d) else { return }
        if let old = try? Data(contentsOf: u), old == data { return }
        try? data.write(to: u, options: .atomic)
    }

    public static func load(dir: URL? = RFMShared.groupContainer()) -> [String: AvailableFirmware] {
        guard let u = url(dir), let data = try? Data(contentsOf: u) else { return [:] }
        return (try? JSONDecoder().decode([String: AvailableFirmware].self, from: data)) ?? [:]
    }
}

extension FirmwareStore {
    /// every firmware's details by id: the site catalogs' (not only the downloadable ones), then the merged list's
    public var details: [String: AvailableFirmware] {
        var out: [String: AvailableFirmware] = [:]
        for e in available { out[e.id] = e }
        for s in snapshots { for (k, v) in s.details where out[k] == nil { out[k] = v } }
        return out
    }
}
