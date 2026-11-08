// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// What a screen video takes, and what it leaves out (the owner, 2026-11-07: ReplayKit's videos had the Stop badge and
// the camera's picture in them, a secure layer didn't hide them from it):
//   ScreenCapture     the app's own window drawn into the video ~30 times a second (drawHierarchy), so only that
//                     window is in it; no ReplayKit and no permission to ask
//   RecordingOverlay  the badge (the time, Stop) and the camera's picture, each in a small window of its own above the
//                     app: you see them and can tap them, the video never has them. The picture can be dragged

import AVFoundation
import CoreMedia
import CoreVideo
import RFMKit
import SwiftUI
import UIKit

// MARK: - the screen into a video

@MainActor
final class ScreenCapture {
    private let window: UIWindow
    private let deliver: (CMSampleBuffer) -> Void
    private var link: CADisplayLink?
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private let scale: CGFloat
    private let size: CGSize                         // in pixels
    private var last: CFTimeInterval = 0
    /// the time between frames: 1/30 s, longer when drawing one is slow (at most half the main thread)
    private var interval: CFTimeInterval = 1.0 / 30
    private var reported = false

    /// the window drawn at `scale` (2: sharp enough, not too much work), each frame to `deliver` on the host clock
    init(window: UIWindow, scale: CGFloat = 2, deliver: @escaping (CMSampleBuffer) -> Void) {
        self.window = window
        self.deliver = deliver
        self.scale = scale
        let b = window.bounds.size
        size = CGSize(width: (b.width * scale / 2).rounded() * 2, height: (b.height * scale / 2).rounded() * 2)
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                    kCVPixelBufferWidthKey as String: Int(size.width),
                                    kCVPixelBufferHeightKey as String: Int(size.height),
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    func start() {
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard now - last >= interval - 0.002 else { return }
        last = now
        guard let pool else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        if let ctx {
            ctx.translateBy(x: 0, y: size.height)       // (UIKit draws top down)
            ctx.scaleBy(x: size.width / window.bounds.width, y: -size.height / window.bounds.height)
            UIGraphicsPushContext(ctx)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let took = CACurrentMediaTime() - now
        interval = 0.9 * interval + 0.1 * max(1.0 / 30, took * 2)
        if !reported, took > 0.02 {
            reported = true
            RFMShared.log("recording").info("screen: a frame takes \(Int(took * 1000)) ms; fewer frames a second")
        }
        if format == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format) }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb { deliver(sb) }
    }
}

// MARK: - the badge and the camera's picture, outside the app's window

@MainActor
final class RecordingOverlay {
    private var badge: UIWindow?
    private var preview: UIWindow?
    /// where the picture was dragged to (kept for the next take)
    private static var previewCenter: CGPoint?

    func show(recorder: Recorder, over main: UIWindow) {
        hide()
        guard let scene = main.windowScene else { return }
        let top = main.safeAreaInsets.top, bounds = main.bounds
        let host = UIHostingController(rootView: RecordingPill(recorder: recorder))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        let fit = host.sizeThatFits(in: CGSize(width: 300, height: 60))
        let w = OverlayWindow(windowScene: scene)
        w.frame = CGRect(x: bounds.width - fit.width - (top > 30 ? 22 : 14),
                         y: top > 30 ? max(4, (top - fit.height) / 2 + 2) : 52, width: fit.width, height: fit.height)
        w.rootViewController = host
        w.isHidden = false
        badge = w
    }

    func showPreview(_ session: AVCaptureSession, over main: UIWindow) {
        guard preview == nil, let scene = main.windowScene, let b = badge else { return }
        let host = UIHostingController(rootView: CameraPreview(session: session)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.5), lineWidth: 1)))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        let w = OverlayWindow(windowScene: scene)
        let size = CGSize(width: 96, height: 128)
        let start = Self.previewCenter ?? CGPoint(x: b.frame.maxX - size.width / 2, y: b.frame.maxY + 8 + size.height / 2)
        w.frame = CGRect(origin: .zero, size: size)
        w.center = Self.clamp(start, size, main.bounds)
        w.rootViewController = host
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        host.view.addGestureRecognizer(pan)
        w.isHidden = false
        preview = w
    }

    func hidePreview() {
        preview?.isHidden = true
        preview = nil
    }

    func hide() {
        for w in [badge, preview] { w?.isHidden = true }
        badge = nil
        preview = nil
    }

    @objc private func drag(_ g: UIPanGestureRecognizer) {
        guard let w = preview, let bounds = w.windowScene?.screen.bounds else { return }
        let d = g.translation(in: nil)
        g.setTranslation(.zero, in: nil)
        w.center = Self.clamp(CGPoint(x: w.center.x + d.x, y: w.center.y + d.y), w.bounds.size, bounds)
        if g.state == .ended { Self.previewCenter = w.center }
    }

    static func clamp(_ p: CGPoint, _ s: CGSize, _ b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX + s.width / 2 + 4), b.maxX - s.width / 2 - 4),
                y: min(max(p.y, b.minY + s.height / 2 + 4), b.maxY - s.height / 2 - 4))
    }
}

/// a window above the app that never becomes the key one (the app's keyboard and focus stay where they are)
final class OverlayWindow: UIWindow {
    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert + 1
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { false }
}
