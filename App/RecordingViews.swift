// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Recording's page (the quick menu's Recording settings…: the top-left chip), the badge on the faceplate while it records (the time, Stop)
// and the camera's preview in the corner.

import AVFoundation
import UIKit
import RFMKit
import SwiftUI

struct RecordingPage: View {
    @Bindable var recorder: Recorder
    let back: () -> Void
    /// the sheet closed, then this done (recording starts, or the screenshot is taken without the sheet in it)
    let closeThen: (@escaping @MainActor () async -> Void) -> Void

    var body: some View {
        let s = $recorder.settings
        SheetPage("Recording", back: back) {
            SheetList {
                SheetToggle("Audio", on: s.audio)
                SheetToggle("Screen", on: s.screen)
                SheetToggle("Camera", on: s.camera, divider: recorder.settings.camera)
                if recorder.settings.camera {
                    SheetSegmented("Camera side", options: ["Rear", "Front"],
                                   selected: recorder.settings.cameraSide == .rear ? 0 : 1) {
                        recorder.settings.cameraSide = $0 == 0 ? .rear : .front
                    }
                    SheetSegmented("Zoom", options: RecordingSettings.zooms.map(Self.zoomText),
                                   selected: RecordingSettings.zooms.firstIndex(of: recorder.settings.zoom) ?? 1, divider: false) {
                        recorder.settings.zoom = RecordingSettings.zooms[$0]
                    }
                }
            }
            .padding(.top, 12)
            SheetNote("Audio is the app's own sound, never the microphone. With Screen or Camera on, the sound goes into "
                      + "the video; both on make two videos of the same take. The camera asks for permission the first "
                      + "time it records. While the screen records nothing extra shows on it: stop from the top-left menu.")
            SheetButton(recorder.isRecording ? "Stop recording" : "Start recording", accent: !recorder.isRecording) {
                if recorder.isRecording { Task { await recorder.stop() } } else { closeThen { await recorder.start() } }
            }
            .disabled(!recorder.settings.canRecord || recorder.busy)
            .padding(.top, 10)
            if !recorder.settings.canRecord { SheetNote("Turn on Audio, Screen or Camera to record.") }

            SheetSectionTitle("Screenshot")
            SheetList {
                SheetSegmented("Take", options: ["Whole screen", "FM-1 screen"],
                               selected: recorder.settings.screenshot == .screen ? 0 : 1, divider: false) {
                    recorder.settings.screenshot = $0 == 0 ? .screen : .raw
                }
            }
            SheetNote("FM-1 screen: the firmware's own 240 × 240 pixels, as it draws them (for firmware work).")
            SheetButton("Take screenshot") { closeThen { await recorder.screenshot() } }
                .padding(.top, 10)

            SheetSectionTitle("Saving")
            SheetList {
                SheetToggle("Copy to Photos", on: s.copyToPhotos, divider: false)
            }
            SheetNote(recorder.settings.copyToPhotos
                      ? "Videos and screenshots go to Photos (it asks the first time). Sound alone stays in RemoteFM1 › "
                        + "audio › recordings, where firmwares can load it as a sample."
                      : "In the Files app: videos in RemoteFM1 › recordings, screenshots in RemoteFM1 › screenshots, and "
                        + "sound alone in RemoteFM1 › audio › recordings, where firmwares can load it as a sample.")
            if !recorder.note.isEmpty { SheetNote(recorder.note) }
        }
    }

    static func zoomText(_ z: Double) -> String { z == 0.5 ? "0.5×" : "\(Int(z))×" }
}

/// the time and Stop while it records, where the status bar was (hidden meanwhile), so the firmware's name stays free
/// to tap; with no status bar space (landscape) under the status row; the camera's picture under it
struct RecordingBadge: View {
    let recorder: Recorder

    var body: some View {
        GeometryReader { g in
            let top = g.safeAreaInsets.top
            badge
                .padding(.top, top > 30 ? max(4, (top - 34) / 2) : 52)
                .padding(.trailing, top > 30 ? 22 : 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .ignoresSafeArea()
        }
    }

    private var badge: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button { Task { await recorder.stop() } } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    TimelineView(.periodic(from: .now, by: 1)) { c in
                        Text(Self.time(c.date.timeIntervalSince(recorder.started ?? c.date)))
                            .font(RFMFonts.ui(14, 600)).monospacedDigit()
                    }
                    Text("Stop").font(RFMFonts.ui(14, 700))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.72)))
            }
            .buttonStyle(.plain)
            .disabled(recorder.busy)
            .accessibilityLabel("Stop recording")
            if let s = recorder.cameraSession {
                CameraPreview(session: s)
                    .frame(width: 96, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.5), lineWidth: 1))
            }
        }
    }

    static func time(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var coordinator: AVCaptureDevice.RotationCoordinator?
        var observation: NSKeyValueObservation?
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        if let d = (session.inputs.first as? AVCaptureDeviceInput)?.device {
            let c = AVCaptureDevice.RotationCoordinator(device: d, previewLayer: v.preview)
            v.coordinator = c
            v.preview.connection?.videoRotationAngle = c.videoRotationAngleForHorizonLevelPreview
            let layer = v.preview
            v.observation = Self.follow(c) { a in layer.connection?.videoRotationAngle = a }
        }
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {}

    /// the preview turned with the phone (made outside the main actor: the change may come on another thread)
    nonisolated static func follow(_ c: AVCaptureDevice.RotationCoordinator,
                                   _ apply: @escaping @MainActor (CGFloat) -> Void) -> NSKeyValueObservation {
        c.observe(\.videoRotationAngleForHorizonLevelPreview) { c, _ in
            let a = c.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { MainActor.assumeIsolated { apply(a) } }
        }
    }
}

/// what was just saved, with ways to look at it: Open (Quick Look), Show in Files (Finder on a Mac), Photos
struct SavedCard: View {
    let recorder: Recorder
    @Binding var preview: URL?

    var body: some View {
        if let s = recorder.saved {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(s.text).font(RFMFonts.ui(13, 500)).foregroundStyle(Palette.sheetText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { recorder.saved = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.sheetMuted)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                HStack(spacing: 8) {
                    if let f = s.files.first {
                        pill("Open") { preview = f; recorder.saved = nil }
                        pill(ProcessInfo.processInfo.isiOSAppOnMac ? "Show in Finder" : "Show in Files") { Self.showInFiles(f) }
                    }
                    if s.inPhotos { pill("Photos") { Self.open("photos-redirect://") } }
                }
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.sheetBackground.opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.linkedDot.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
            .frame(maxWidth: 440)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .environment(\.colorScheme, .dark)
            .transition(.opacity.combined(with: .offset(y: 12)))
            .id(s.id)
        }
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(RFMFonts.ui(13, 700)).foregroundStyle(Palette.sheetText)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Palette.sheetSurface))
        }
        .buttonStyle(.plain)
    }

    /// the file's folder in the Files app (a Mac: Finder)
    static func showInFiles(_ f: URL) {
        let dir = f.deletingLastPathComponent()
        if ProcessInfo.processInfo.isiOSAppOnMac {
            UIApplication.shared.open(dir)
        } else if let p = dir.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            open("shareddocuments://" + p)
        }
    }

    static func open(_ s: String) {
        if let u = URL(string: s) { UIApplication.shared.open(u) }
    }
}
