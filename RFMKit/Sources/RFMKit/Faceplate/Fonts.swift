// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The UI's four typefaces (design/README.md section 7, tokens.json "fonts"; all SIL OFL, bundled in Resources/Fonts):
// Chakra Petch Bold for the hardware legends, DM Sans (variable: weight and optical size) for the app's text,
// Unbounded (variable) for titles, DM Mono Medium for hex values. register() once per process (the app and the
// extension each call it at start).

import CoreText
import Foundation
import SwiftUI

public enum RFMFonts {
    nonisolated(unsafe) private static var registered = false
    private static let lock = NSLock()

    /// registers the bundled fonts for this process; returns how many files were registered (0 the second time)
    @discardableResult
    public static func register() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return 0 }
        registered = true
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        var n = 0
        for u in urls {
            var err: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(u as CFURL, .process, &err) { n += 1 } else { err?.release() }
        }
        return n
    }

    static let hardwareName = "ChakraPetch-Bold"
    static let uiName = "DMSans-9ptRegular"
    static let titleName = "Unbounded-Regular"
    static let monoName = "DMMono-Medium"

    private static func tag(_ s: String) -> Int { s.utf8.reduce(0) { $0 << 8 | Int($1) } }

    /// a variable font at a weight (and DM Sans's optical size)
    static func variable(_ name: String, size: CGFloat, weight: CGFloat, opsz: Bool) -> CTFont {
        var axes: [NSNumber: NSNumber] = [NSNumber(value: tag("wght")): NSNumber(value: Double(weight))]
        if opsz { axes[NSNumber(value: tag("opsz"))] = NSNumber(value: Double(min(max(size, 9), 40))) }
        let attrs: [CFString: Any] = [kCTFontNameAttribute: name, kCTFontVariationAttribute: axes]
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
    }

    /// Chakra Petch 700: legends, knob labels, OCT, the wordmark, the faceplate's switches
    public static func hardware(_ size: CGFloat) -> Font { .custom(hardwareName, fixedSize: size) }
    /// DM Sans at a weight 400...700: the chip, the sheet, the theme editor
    public static func ui(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        Font(variable(uiName, size: size, weight: weight, opsz: true))
    }
    /// Unbounded 700: the sheet's and the editor's titles
    public static func title(_ size: CGFloat) -> Font { Font(variable(titleName, size: size, weight: 700, opsz: false)) }
    /// DM Mono 500: hex values
    public static func mono(_ size: CGFloat) -> Font { .custom(monoName, fixedSize: size) }

    /// whether a registered font answers to `name` (tests)
    public static func available(_ name: String) -> Bool {
        let f = CTFontCreateWithName(name as CFString, 12, nil)
        return (CTFontCopyPostScriptName(f) as String) == name
    }
}
