// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Skins: an image behind the faceplate (PLAN.md section 23; Brian White's idea).
//   the user's    Settings › Theme › Background image: one photo for every firmware, kept in the App Group's
//                 Skins folder (re-encoded, at most 2048 px), so the AU shows it too; the dim lays the faceplate's
//                 colour over it, so the labels (chosen for contrast on that colour) stay legible
//   a firmware's  an .rfm1 may carry its own skin (docs/RFM1-FORMAT.md section 8): custom sections rfm1.skin (JSON:
//                 colours, dim) and rfm1.skin.background / rfm1.skin.background.landscape (PNG or JPEG). Shown while
//                 that firmware plays, unless "Firmware skins" is off
// The firmware's skin wins over the user's image (it was made for that firmware); with neither, the theme's colour.

import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// what the faceplate draws behind itself
public struct Skin: @unchecked Sendable, Equatable {
    public var id: String                       // equal skins draw the same ("user:<stamp>", "rfm1:<sha256>")
    public var portrait: CGImage?
    public var landscape: CGImage?
    public var dim: Double                      // 0...0.8: the faceplate's colour over the image (labels stay legible)
    public var theme: Theme?                    // a firmware skin's colours

    public init(id: String, portrait: CGImage?, landscape: CGImage? = nil, dim: Double = 0, theme: Theme? = nil) {
        self.id = id
        self.portrait = portrait
        self.landscape = landscape
        self.dim = min(max(dim, 0), SkinStore.maxDim)
        self.theme = theme
    }

    /// the image for a view of this size (a wide view: the landscape image, if there is one)
    public func image(wide: Bool) -> CGImage? { wide ? (landscape ?? portrait) : (portrait ?? landscape) }

    public static func == (a: Skin, b: Skin) -> Bool { a.id == b.id && a.dim == b.dim && a.theme == b.theme }
}

/// an .rfm1's skin sections (docs/RFM1-FORMAT.md section 8)
public enum SkinFile {
    public static let section = "rfm1.skin"
    public static let background = "rfm1.skin.background"
    public static let backgroundLandscape = "rfm1.skin.background.landscape"
    public static let maxImageBytes = 4 << 20
    public static let maxPixels = 2048

    /// the custom sections whose names start with "rfm1.skin" (a WebAssembly file's section 0s); empty if it isn't one
    public static func sections(_ b: Data) -> [String: Data] {
        let bytes = [UInt8](b)
        guard bytes.count >= 8, bytes[0] == 0, bytes[1] == 0x61, bytes[2] == 0x73, bytes[3] == 0x6D else { return [:] }
        var at = 8, out: [String: Data] = [:]
        func u32() -> Int? {
            var v = 0, shift = 0
            while at < bytes.count, shift < 35 {
                let c = bytes[at]; at += 1
                v |= Int(c & 0x7F) << shift
                if c & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while at < bytes.count {
            let id = bytes[at]; at += 1
            guard let size = u32(), size <= bytes.count - at else { break }
            let end = at + size
            if id == 0, let n = u32(), n <= end - at {
                let name = String(decoding: bytes[at..<at + n], as: UTF8.self)
                at += n
                if name.hasPrefix(section) { out[name] = Data(bytes[at..<end]) }
            }
            at = end
        }
        return out
    }

    /// the file's skin; nil when it has none (no rfm1.skin section, or no image and no colours)
    public static func read(path: String, id: String) -> Skin? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return read(d, id: id)
    }

    public static func read(_ d: Data, id: String) -> Skin? {
        let s = sections(d)
        guard let j = s[section], let o = try? JSONSerialization.jsonObject(with: j) as? [String: Any],
              (o["skin"] as? Int) == 1 else { return nil }
        let p = s[background].flatMap { decode($0) }, l = s[backgroundLandscape].flatMap { decode($0) }
        let theme = (o["theme"] as? [String: String]).flatMap { theme($0) }
        guard p != nil || l != nil || theme != nil else { return nil }
        return Skin(id: id, portrait: p, landscape: l, dim: o["dim"] as? Double ?? 0, theme: theme)
    }

    /// every role given: those; else the five a user picks (body, key, knob, led, bezel), the rest derived
    static func theme(_ t: [String: String]) -> Theme? {
        if let full = Theme(name: "Firmware skin", roles: t) { return full }
        func c(_ k: String) -> RGB? { t[k].flatMap(RGB.init(hex:)) }
        guard let body = c("body"), let key = c("key"), let knob = c("knob"), let led = c("led"), let bezel = c("bezel")
        else { return nil }
        return Theme.derived(.init(body: body, key: key, knob: knob, led: led, bezel: bezel), name: "Firmware skin")
    }

    /// a PNG or JPEG, scaled down to maxPixels on its longer side (memory: the AU's limit is tight)
    public static func decode(_ d: Data, maxBytes: Int = maxImageBytes) -> CGImage? {
        guard d.count <= maxBytes, let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                  kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }

    /// a JPEG of the image (the user's background as stored)
    static func jpeg(_ img: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}

/// The user's background and the skin settings, shared by the app and the AU (App Group), like ThemeStore
@MainActor @Observable
public final class SkinStore {
    public static let shared = SkinStore()
    public nonisolated static let maxDim = 0.8
    static let dimKey = "rfm1.skin.dim"
    static let firmwareKey = "rfm1.skin.firmware"
    static let stampKey = "rfm1.skin.stamp"
    public static let changedNotification = "\(RFMShared.appGroup).skin"

    public private(set) var userImage: CGImage?
    public private(set) var stamp = 0           // changes with the image (the skin's id)
    public var dim: Double { didSet { if dim != oldValue { defaults.set(dim, forKey: Self.dimKey); notify() } } }
    public var firmwareSkins: Bool {
        didSet { if firmwareSkins != oldValue { defaults.set(firmwareSkins, forKey: Self.firmwareKey); notify() } }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let dir: URL?
    @ObservationIgnored private var cache: [String: Skin?] = [:]
    @ObservationIgnored private var observing = false
    /// an imported firmware's file by SHA-256 (tests give their own)
    @ObservationIgnored var fileFor: (String) -> String? = { FirmwareCatalog.shared.path($0) }

    /// defaults / dir: nil = the App Group's (tests give their own)
    public init(defaults: UserDefaults? = nil, dir: URL? = nil) {
        let d = defaults ?? UserDefaults(suiteName: RFMShared.appGroup) ?? .standard
        self.defaults = d
        self.dir = dir ?? RFMShared.skinsFolder()
        dim = d.object(forKey: Self.dimKey) as? Double ?? 0.25
        firmwareSkins = d.object(forKey: Self.firmwareKey) as? Bool ?? true
        load()
    }

    var imageURL: URL? { dir?.appendingPathComponent("background.jpg") }

    public var hasImage: Bool { userImage != nil }

    /// the user's image, scaled down and stored; false if it isn't an image
    @discardableResult public func setImage(_ data: Data) -> Bool {
        guard let img = SkinFile.decode(data, maxBytes: .max), let jpeg = SkinFile.jpeg(img),
              let url = imageURL else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? jpeg.write(to: url, options: .atomic)) != nil else { return false }
        userImage = img
        stamp += 1
        defaults.set(stamp, forKey: Self.stampKey)
        notify()
        return true
    }

    public func removeImage() {
        if let url = imageURL { try? FileManager.default.removeItem(at: url) }
        userImage = nil
        stamp += 1
        defaults.set(stamp, forKey: Self.stampKey)
        notify()
    }

    /// reads the stored image and settings again (another process changed them)
    public func load() {
        let s = defaults.integer(forKey: Self.stampKey)
        if s != stamp || userImage == nil {
            stamp = s
            userImage = imageURL.flatMap { try? Data(contentsOf: $0) }.flatMap { SkinFile.decode($0, maxBytes: .max) }
        }
        let d = defaults.object(forKey: Self.dimKey) as? Double ?? 0.25
        if d != dim { dim = d }
        let f = defaults.object(forKey: Self.firmwareKey) as? Bool ?? true
        if f != firmwareSkins { firmwareSkins = f }
    }

    /// a firmware's own skin (read once per file); key: the catalog key ("rfm1:<sha256>"), built-in cores have none
    public func firmwareSkin(_ key: String?) -> Skin? {
        guard let key, FirmwareCatalog.isKey(key) else { return nil }
        if let s = cache[key] { return s }
        let sha = String(key.dropFirst(FirmwareCatalog.keyPrefix.count))
        let s = fileFor(sha).flatMap { SkinFile.read(path: $0, id: key) }
        cache[key] = s
        return s
    }

    /// what the faceplate shows for the firmware with this catalog key
    public func skin(for key: String?) -> Skin? {
        if firmwareSkins, let s = firmwareSkin(key) { return s }
        guard let img = userImage else { return nil }
        return Skin(id: "user:\(stamp)", portrait: img, dim: dim)
    }

    /// listens for the other process's changes (call once from the UI)
    public func observe() {
        guard !observing else { return }
        observing = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let me = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, me, { _, obs, _, _, _ in
            guard let obs else { return }
            let ref = SkinRef(store: Unmanaged<SkinStore>.fromOpaque(obs).takeUnretainedValue())
            DispatchQueue.main.async { MainActor.assumeIsolated { ref.store.load() } }
        }, Self.changedNotification as CFString, nil, .deliverImmediately)
    }

    private func notify() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Self.changedNotification as CFString), nil, nil, true)
    }
}

private struct SkinRef: @unchecked Sendable { let store: SkinStore }

#if os(iOS)
/// the skin drawn to fill its frame: the image (cropped to fill), the faceplate's colour over it by the dim
struct SkinBackground: View {
    let skin: Skin
    let size: CGSize
    let tint: Color

    var body: some View {
        if let img = skin.image(wide: size.width > size.height) {
            Image(decorative: img, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay(tint.opacity(skin.dim))
        }
    }
}
#endif
