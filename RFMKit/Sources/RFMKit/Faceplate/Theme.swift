// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The faceplate's colours (design/README.md section 6, design/tokens.json): the five presets read from the bundled
// tokens.json, the fixed colours, the rules that derive a custom theme from its five chosen colours, and the store
// that keeps the choice in the App Group's defaults, so the app and the AUv3 share it.

import Foundation
import Observation
import SwiftUI

/// an sRGB colour, kept as its 0...1 components; Codable as "#RRGGBB"
public struct RGB: Hashable, Sendable, Codable, CustomStringConvertible {
    public var r: Double, g: Double, b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255)
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
    public var description: String { hex }
    public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = RGB(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not #RRGGBB: \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    // MARK: colour math (sRGB D65, CIE L*a*b*, WCAG contrast)

    static func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gam(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    /// WCAG relative luminance
    public var luminance: Double { 0.2126 * Self.lin(r) + 0.7152 * Self.lin(g) + 0.0722 * Self.lin(b) }

    /// WCAG contrast ratio, 1...21
    public func contrast(_ o: RGB) -> Double {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static let white = (x: 0.95047, y: 1.0, z: 1.08883)

    public var lab: (l: Double, a: Double, b: Double) {
        let R = Self.lin(r), G = Self.lin(g), B = Self.lin(b)
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / Self.white.x
        let y = (0.2126 * R + 0.7152 * G + 0.0722 * B) / Self.white.y
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / Self.white.z
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    public init(l: Double, a: Double, b: Double) {
        let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func fi(_ t: Double) -> Double { t * t * t > 216.0 / 24389 ? t * t * t : (116 * t - 16) / (24389.0 / 27) }
        let x = fi(fx) * Self.white.x, y = fi(fy) * Self.white.y, z = fi(fz) * Self.white.z
        let R = 3.2406 * x - 1.5372 * y - 0.4986 * z
        let G = -0.9689 * x + 1.8758 * y + 0.0415 * z
        let B = 0.0557 * x - 0.2040 * y + 1.0570 * z
        self.init(Self.gam(max(0, R)), Self.gam(max(0, G)), Self.gam(max(0, B)))
    }

    /// the same colour with its L* moved by dl (+ lighter)
    public func lightness(_ dl: Double) -> RGB {
        let c = lab
        return RGB(l: min(max(c.l + dl, 0), 100), a: c.a, b: c.b)
    }
}

/// One faceplate theme: the roles of tokens.json ("roles")
public struct Theme: Hashable, Sendable, Codable, Identifiable {
    public var name: String
    public var body, label, bed, key, hi, lo, keyText, knob, mark, bezel, lcd, ink, led, ledOff: RGB
    public var id: String { name }

    public static let roles = ["body", "label", "bed", "key", "hi", "lo", "keyText", "knob", "mark", "bezel", "lcd",
                               "ink", "led", "ledOff"]
    public static let customName = "My theme"
    public static let nearWhite = RGB(hex: "#F6F0E8")!
    public static let nearBlack = RGB(hex: "#1B1714")!

    /// a theme from a role -> "#RRGGBB" table (tokens.json); nil when a role is missing or not a colour
    public init?(name: String, roles t: [String: String]) {
        func c(_ k: String) -> RGB? { t[k].flatMap(RGB.init(hex:)) }
        guard let body = c("body"), let label = c("label"), let bed = c("bed"), let key = c("key"), let hi = c("hi"),
              let lo = c("lo"), let keyText = c("keyText"), let knob = c("knob"), let mark = c("mark"),
              let bezel = c("bezel"), let lcd = c("lcd"), let ink = c("ink"), let led = c("led"), let ledOff = c("ledOff")
        else { return nil }
        self.init(name: name, body: body, label: label, bed: bed, key: key, hi: hi, lo: lo, keyText: keyText,
                  knob: knob, mark: mark, bezel: bezel, lcd: lcd, ink: ink, led: led, ledOff: ledOff)
    }

    public init(name: String, body: RGB, label: RGB, bed: RGB, key: RGB, hi: RGB, lo: RGB, keyText: RGB, knob: RGB,
                mark: RGB, bezel: RGB, lcd: RGB, ink: RGB, led: RGB, ledOff: RGB) {
        self.name = name
        self.body = body; self.label = label; self.bed = bed; self.key = key; self.hi = hi; self.lo = lo
        self.keyText = keyText; self.knob = knob; self.mark = mark; self.bezel = bezel; self.lcd = lcd; self.ink = ink
        self.led = led; self.ledOff = ledOff
    }

    /// The five colours a user picks (section 6: Faceplate, Keys and buttons, Knobs, LEDs, and the display row,
    /// which is the bezel here: the LCD colour is the design's mock only)
    public struct Choice: Hashable, Sendable, Codable {
        public var body, key, knob, led, bezel: RGB
        public init(body: RGB, key: RGB, knob: RGB, led: RGB, bezel: RGB) {
            self.body = body; self.key = key; self.knob = knob; self.led = led; self.bezel = bezel
        }
    }

    public var choice: Choice { Choice(body: body, key: key, knob: knob, led: led, bezel: bezel) }

    /// the text colour, near-white or near-black, with the better contrast on `bg` (4.5:1 when either reaches it)
    public static func text(on bg: RGB) -> RGB {
        bg.contrast(nearWhite) >= bg.contrast(nearBlack) ? nearWhite : nearBlack
    }

    /// A custom theme from its five colours (section 6's suggested rules): hi = key + 8 L*, lo = key - 18 L*,
    /// bed = key - 6 L*, keyText / label = near-white or near-black for contrast on key / body, mark = near-white on
    /// a dark knob and near-black on a light one, ledOff = a grey 20 L* lighter than bed. lcd / ink (the design's
    /// mock LCD) come from `base`.
    public static func derived(_ c: Choice, name: String = customName, base: Theme? = nil) -> Theme {
        let bed = c.key.lightness(-6)
        return Theme(name: name, body: c.body, label: text(on: c.body), bed: bed, key: c.key,
                     hi: c.key.lightness(8), lo: c.key.lightness(-18), keyText: text(on: c.key), knob: c.knob,
                     mark: c.knob.lab.l < 55 ? nearWhite : nearBlack, bezel: c.bezel,
                     lcd: base?.lcd ?? RGB(hex: "#C9D6EA")!, ink: base?.ink ?? RGB(hex: "#13203A")!, led: c.led,
                     ledOff: RGB(l: min(bed.lab.l + 20, 100), a: 0, b: 0))
    }

    public subscript(role: String) -> RGB? {
        switch role {
        case "body": body
        case "label": label
        case "bed": bed
        case "key": key
        case "hi": hi
        case "lo": lo
        case "keyText": keyText
        case "knob": knob
        case "mark": mark
        case "bezel": bezel
        case "lcd": lcd
        case "ink": ink
        case "led": led
        case "ledOff": ledOff
        default: nil
        }
    }
}

/// tokens.json: the presets in the design's order, the default, the fixed colours
public struct ThemeTokens: Sendable {
    public var presets: [Theme]
    public var defaultName: String
    public var fixed: [String: RGB]             // indicatorLed, playGlyph, recGlyph, linkedDot
    public var sheet: [String: RGB]             // fixedColors.sheet

    /// the design's order of the presets (JSON objects have none)
    public static let order = ["Tangerine", "Midnight", "Mint", "Lilac", "Cream"]

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let themes = root["themes"] as? [String: [String: String]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let names = Self.order.filter { themes[$0] != nil } + themes.keys.filter { !Self.order.contains($0) }.sorted()
        presets = names.compactMap { n in themes[n].flatMap { Theme(name: n, roles: $0) } }
        guard !presets.isEmpty else { throw CocoaError(.coderValueNotFound) }
        defaultName = root["defaultTheme"] as? String ?? presets[0].name
        var fixed: [String: RGB] = [:], sheet: [String: RGB] = [:]
        if let f = root["fixedColors"] as? [String: Any] {
            for (k, v) in f {
                if let s = v as? String, let c = RGB(hex: s) { fixed[k] = c }
                if k == "sheet", let d = v as? [String: String] {
                    for (sk, sv) in d { if let c = RGB(hex: sv) { sheet[sk] = c } }
                }
            }
        }
        self.fixed = fixed
        self.sheet = sheet
    }

    /// the bundled copy of design/tokens.json
    public static var bundledURL: URL? { Bundle.module.url(forResource: "tokens", withExtension: "json") }

    public static let bundled: ThemeTokens = {
        if let url = bundledURL,
           let data = try? Data(contentsOf: url), let t = try? ThemeTokens(data: data) {
            return t
        }
        return ThemeTokens.fallback
    }()

    // (only if the resource were missing: Tangerine alone)
    static let fallback: ThemeTokens = {
        let json = ##"{"defaultTheme":"Tangerine","themes":{"Tangerine":{"body":"#EE7A3C","label":"#3A1606","bed":"#874332","key":"#924E3A","hi":"#A9614B","lo":"#64301F","keyText":"#FBEDE3","knob":"#1B1715","mark":"#F4EDE6","bezel":"#141210","lcd":"#C9D6EA","ink":"#13203A","led":"#FFE6A8","ledOff":"#6F6668"}}}"##
        return try! ThemeTokens(data: Data(json.utf8))
    }()
}

/// The fixed colours (tokens.json fixedColors), with the design's values as defaults
public enum Palette {
    static func f(_ k: String, _ d: String) -> Color { (ThemeTokens.bundled.fixed[k] ?? RGB(hex: d)!).color }
    static func s(_ k: String, _ d: String) -> Color { (ThemeTokens.bundled.sheet[k] ?? RGB(hex: d)!).color }
    public static let indicatorLed = f("indicatorLed", "#FF3B2F")
    public static let playGlyph = f("playGlyph", "#4FE08A")
    public static let recGlyph = f("recGlyph", "#FF4436")
    public static let linkedDot = f("linkedDot", "#3BD47A")
    public static let sheetBackground = s("background", "#17140F")
    public static let sheetSurface = s("surface", "#211E19")
    public static let sheetRaised = s("raised", "#2A251F")
    public static let sheetLine = s("line", "#2E2A23")
    public static let sheetBorder = s("border", "#3A352D")
    public static let sheetText = s("text", "#F3EBDC")
    public static let sheetMuted = s("muted", "#A69C8A")
    public static let sheetMuted2 = s("muted2", "#B5AB99")
    public static let sheetAccent = s("accent", "#FF8A4C")
    public static let sheetDim = Color(.sRGB, red: 0x6E / 255.0, green: 0x65 / 255.0, blue: 0x57 / 255.0, opacity: 1)
}

/// The chosen theme, shared by the app and the extension: the App Group's defaults (else this process's), and a
/// Darwin notification so the other process reads it again.
@MainActor
@Observable
public final class ThemeStore {
    public static let shared = ThemeStore()
    static let selectedKey = "rfm1.theme"
    static let customKey = "rfm1.theme.custom"
    public static let changedNotification = "\(RFMShared.appGroup).theme"

    public let presets: [Theme]
    public private(set) var custom: Theme?
    public private(set) var current: Theme
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let override: String?
    @ObservationIgnored private var observing = false

    /// defaults: nil = the App Group's suite (else standard). override: a theme name used without being stored (the
    /// -theme launch argument)
    public init(defaults: UserDefaults? = nil, tokens: ThemeTokens = .bundled,
                override: String? = ThemeStore.launchOverride()) {
        self.defaults = defaults ?? UserDefaults(suiteName: RFMShared.appGroup) ?? .standard
        presets = tokens.presets
        self.override = override
        let fallback = tokens.presets.first { $0.name == tokens.defaultName } ?? tokens.presets[0]
        current = fallback
        load()
    }

    public nonisolated static func launchOverride() -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-theme"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    /// every theme to choose from: the presets, then the user's
    public var all: [Theme] { presets + (custom.map { [$0] } ?? []) }

    public func theme(named n: String) -> Theme? { all.first { $0.name == n } }

    public func select(_ name: String) {
        guard let t = theme(named: name) else { return }
        current = t
        defaults.set(name, forKey: Self.selectedKey)
        notify()
    }

    /// stores `t` as the user's theme (one slot, named "My theme") and selects it
    public func saveCustom(_ t: Theme) {
        var c = t
        c.name = Theme.customName
        custom = c
        if let d = try? JSONEncoder().encode(c) { defaults.set(d, forKey: Self.customKey) }
        current = c
        defaults.set(c.name, forKey: Self.selectedKey)
        notify()
    }

    /// reads the stored choice again (another process changed it)
    public func load() {
        if let d = defaults.data(forKey: Self.customKey), let c = try? JSONDecoder().decode(Theme.self, from: d) {
            custom = c
        }
        let name = override ?? defaults.string(forKey: Self.selectedKey)
        if let name, let t = theme(named: name), t != current { current = t }
    }

    /// listens for the other process's changes (call once from the UI)
    public func observe() {
        guard !observing else { return }
        observing = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let me = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, me, { _, obs, _, _, _ in
            guard let obs else { return }
            let store = Unmanaged<ThemeStore>.fromOpaque(obs).takeUnretainedValue()
            let ref = StoreRef(store: store)
            DispatchQueue.main.async { MainActor.assumeIsolated { ref.store.load() } }
        }, Self.changedNotification as CFString, nil, .deliverImmediately)
    }

    private func notify() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Self.changedNotification as CFString), nil, nil, true)
    }
}

private struct StoreRef: @unchecked Sendable { let store: ThemeStore }
