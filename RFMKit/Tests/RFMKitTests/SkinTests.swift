// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Skins (Skin.swift, docs/RFM1-FORMAT.md section 8): an .rfm1's rfm1.skin sections, read back; the file still loads
// and plays with them; the user's background in SkinStore; which skin shows.

import CoreGraphics
import Foundation
import ImageIO
import RFMCore
import UniformTypeIdentifiers
import XCTest
@testable import RFMKit

final class SkinTests: XCTestCase {
    private var cart: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ain_cart.rfm1") }

    private func leb(_ v: Int) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F); v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    /// a custom section as rfm1_skin.py writes it
    private func custom(_ name: String, _ payload: Data) -> Data {
        let body = leb(name.utf8.count) + Array(name.utf8) + [UInt8](payload)
        return Data([0] + leb(body.count) + body)
    }

    private func png(_ w: Int, _ h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        return out as Data
    }

    private func skinned(_ json: String, portrait: Data? = nil, landscape: Data? = nil) throws -> URL {
        var d = try Data(contentsOf: cart)
        d += custom(SkinFile.section, Data(json.utf8))
        if let portrait { d += custom(SkinFile.background, portrait) }
        if let landscape { d += custom(SkinFile.backgroundLandscape, landscape) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skinned-\(UUID().uuidString).rfm1")
        try d.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testNoSkin() {
        XCTAssertNil(SkinFile.read(path: cart.path, id: "x"))
        XCTAssertTrue(SkinFile.sections(try! Data(contentsOf: cart)).isEmpty)
    }

    func testASkinIsReadBack() throws {
        let url = try skinned(##"{"skin":1,"dim":0.3,"theme":{"body":"#102030","key":"#405060","knob":"#111111","led":"#FFEE00","bezel":"#000000"}}"##,
                              portrait: png(300, 600), landscape: png(600, 300))
        let s = try XCTUnwrap(SkinFile.read(path: url.path, id: "rfm1:abc"))
        XCTAssertEqual(s.id, "rfm1:abc")
        XCTAssertEqual(s.dim, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.portrait?.width, 300)
        XCTAssertEqual(s.image(wide: true)?.width, 600)
        XCTAssertEqual(s.image(wide: false)?.width, 300)
        XCTAssertEqual(s.theme?.body.hex, "#102030")
        XCTAssertEqual(s.theme?.led.hex, "#FFEE00")
    }

    func testTheSkinnedFileStillLoadsAndPlays() throws {
        let url = try skinned(##"{"skin":1}"##, portrait: png(64, 64))
        var info = rfmw_info_t()
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(rfmw_check(url.path, &info, &err, 512), 1, String(cString: err))
        let c = try WasmTestCore(url.path)
        c.boot()
        c.run(50)
    }

    func testOnlyAnImageOrColoursMakeASkin() throws {
        XCTAssertNil(SkinFile.read(path: try skinned(##"{"skin":1,"dim":0.5}"##).path, id: "x"), "nothing to show")
        XCTAssertNil(SkinFile.read(path: try skinned(##"{"skin":2}"##, portrait: png(8, 8)).path, id: "x"), "another version")
        let only = try XCTUnwrap(SkinFile.read(path: try skinned(##"{"skin":1,"theme":{"body":"#FF0000","key":"#00FF00","knob":"#0000FF","led":"#FFFFFF","bezel":"#000000"}}"##).path, id: "x"))
        XCTAssertNil(only.portrait)
        XCTAssertEqual(only.theme?.body.hex, "#FF0000")
    }

    func testBigImagesAreScaledAndOversizedOnesRefused() {
        XCTAssertEqual(SkinFile.decode(png(3000, 1500)).map { max($0.width, $0.height) }, SkinFile.maxPixels)
        XCTAssertNil(SkinFile.decode(Data(count: SkinFile.maxImageBytes + 1)))
        XCTAssertNil(SkinFile.decode(Data("not an image".utf8)))
    }

    @MainActor func testTheUsersBackground() throws {
        let suite = "skin-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let store = SkinStore(defaults: defaults, dir: dir)
        XCTAssertNil(store.skin(for: nil))
        XCTAssertFalse(store.setImage(Data("nope".utf8)))
        XCTAssertTrue(store.setImage(png(400, 800)))
        let s = try XCTUnwrap(store.skin(for: "felucca"), "a built-in core: the user's image")
        XCTAssertEqual(s.portrait?.height, 800)
        XCTAssertEqual(s.dim, 0.25, accuracy: 1e-9)
        store.dim = 0.5

        let again = SkinStore(defaults: defaults, dir: dir)       // the other process (the AU)
        XCTAssertTrue(again.hasImage)
        XCTAssertEqual(again.dim, 0.5, accuracy: 1e-9)

        let fw = try skinned(##"{"skin":1,"dim":0.1}"##, portrait: png(32, 32))
        store.fileFor = { $0 == "abc" ? fw.path : nil }
        XCTAssertEqual(store.skin(for: "rfm1:abc")?.id, "rfm1:abc", "the firmware's own skin wins")
        XCTAssertEqual(store.skin(for: "rfm1:other")?.id, s.id, "a firmware without one: the user's")
        store.firmwareSkins = false
        XCTAssertEqual(store.skin(for: "rfm1:abc")?.id, s.id, "Firmware skins off")
        store.firmwareSkins = true

        store.removeImage()
        XCTAssertEqual(store.skin(for: "rfm1:abc")?.id, "rfm1:abc")
        XCTAssertNil(store.skin(for: nil))
        again.load()
        XCTAssertFalse(again.hasImage)
    }
}
