// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Sends DX7 cartridges to an FM-1 running RemoteFM1 0.3.0, which keeps each as a user bank (docs/CART-UPLOAD.md on
// RemoteFM1's cart-upload branch). The firmware collects a dump only as the instrument, with no host session, so the
// app's panel lets go of the FM-1 first as for a firmware install (PanelPause.swift: the session ended, the lease held
// with no session), then ~400 ms, then each dump as one SysEx to the FM-1's port (never the updater's), 1 s between
// dumps (one still being written to the flash drops the next), then the panel starts again. Over Bluetooth MIDI the
// dump goes in 512-byte parts 100 ms apart (its input holds 256 packets); USB takes it whole. 0.3.0 sends no reply:
// the unit shows the new USER bank. The port is found as the app's link finds the FM-1 (RemoteMidi.c's rule,
// rfme_fm1_candidate, via ControllerInput.isFM1); with several, the page asks which.

import Foundation
import Observation

/// an FM-1 MIDI destination
public struct CartPort: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bluetooth: Bool

    public init(id: String, name: String, bluetooth: Bool) {
        self.id = id
        self.name = name
        self.bluetooth = bluetooth
    }
}

/// where the bytes go (CoreMIDI on an iPhone; a fake in the tests, the simulator and DEBUG's demo)
public protocol CartTransport: AnyObject, Sendable {
    /// the FM-1 candidates now
    func ports() -> [CartPort]
    /// a part of a SysEx (the whole dump, or one of its parts over Bluetooth), in order
    func send(_ bytes: [UInt8], to port: CartPort) async throws
}

/// the waits (a fake one in the tests records them)
public protocol CartClock: Sendable {
    func sleep(ms: Int) async
}

public struct SystemCartClock: CartClock {
    public init() {}
    public func sleep(ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
}

/// what the sender needs from the app's link (RemoteController; a fake in the tests)
@MainActor
public protocol CartPanelPausing: AnyObject {
    /// ends the panel's session and closes its MIDI connections to the FM-1; returns whether it was running
    func pauseForCart() async -> Bool
    func resumeAfterCart(restart: Bool)
}

/// one picked file: its cartridges, or why it can't be sent
public struct CartFile: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var name: String
    public var carts: [DX7Cart]
    public var error: String?

    public init(name: String, data: Data) {
        self.name = name
        do {
            carts = try DX7Cart.parseFile(data)
        } catch {
            carts = []
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    public var fixes: String? {
        var f: [String] = []
        if carts.contains(where: \.checksumFixed) { f.append("checksum corrected") }
        if carts.contains(where: { $0.originalChannel != 0 }) { f.append("channel set to 1") }
        return f.isEmpty ? nil : f.joined(separator: ", ")
    }
}

@MainActor @Observable
public final class CartSender {
    public struct Timing: Sendable {
        public var afterPause = 400                 // the session's end, before the first byte
        public var between = 1000                   // between dumps (the flash write)
        public var bluetoothPart = 512
        public var bluetoothGap = 100
        public init() {}
    }

    public enum State: Equatable {
        case idle
        case sending(done: Int, total: Int)
        case sent(Int)
        case failed(String)
    }

    public private(set) var files: [CartFile] = []
    public private(set) var ports: [CartPort] = []
    public var chosen: String?
    public private(set) var state: State = .idle
    public let simulated: Bool
    @ObservationIgnored let transport: any CartTransport
    @ObservationIgnored weak var panel: (any CartPanelPausing)?
    @ObservationIgnored let clock: any CartClock
    @ObservationIgnored let timing: Timing

    public init(transport: any CartTransport, panel: (any CartPanelPausing)?, clock: any CartClock = SystemCartClock(),
                timing: Timing = .init(), simulated: Bool) {
        self.transport = transport
        self.panel = panel
        self.clock = clock
        self.timing = timing
        self.simulated = simulated
    }

    public var carts: [DX7Cart] { files.flatMap(\.carts) }
    public var busy: Bool { if case .sending = state { true } else { false } }

    public func add(_ file: CartFile) {
        guard !busy else { return }
        files.append(file)
        if case .sent = state { state = .idle }
        if case .failed = state { state = .idle }
    }

    public func add(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            var f = CartFile(name: url.lastPathComponent, data: Data())
            f.error = "The file couldn't be read: \(error.localizedDescription)"
            add(f)
            return
        }
        add(CartFile(name: url.lastPathComponent, data: data))
    }

    public func remove(_ id: CartFile.ID) {
        guard !busy else { return }
        files.removeAll { $0.id == id }
    }

    public func clear() {
        guard !busy else { return }
        files = []
        state = .idle
    }

    public func rescan() {
        ports = transport.ports()
        if let c = chosen, !ports.contains(where: { $0.id == c }) { chosen = nil }
    }

    /// the port to send to: the only one, or the one picked (nil: none, or several and none picked)
    public var target: CartPort? {
        if ports.count == 1 { return ports[0] }
        return ports.first { $0.id == chosen }
    }

    /// sends every cartridge, in order; the panel lets go of the FM-1 first and starts again after
    public func send() async {
        guard !busy else { return }
        rescan()
        let list = carts
        guard !list.isEmpty else { state = .failed("No cartridge to send."); return }
        guard let port = target else {
            state = .failed(ports.isEmpty ? "No FM-1 found. Connect it with USB (or Bluetooth MIDI) and try again."
                            : "Choose which FM-1 to send to.")
            return
        }
        state = .sending(done: 0, total: list.count)
        let restart = await panel?.pauseForCart() ?? false
        await clock.sleep(ms: timing.afterPause)
        var failure: String?
        for (i, c) in list.enumerated() {
            if i > 0 { await clock.sleep(ms: timing.between) }
            do {
                try await write(c.bytes, to: port)
            } catch {
                failure = "Sending cartridge \(i + 1) failed: \(error.localizedDescription)"
                break
            }
            state = .sending(done: i + 1, total: list.count)
        }
        panel?.resumeAfterCart(restart: restart)
        state = failure.map { .failed($0) } ?? .sent(list.count)
    }

    private func write(_ bytes: [UInt8], to port: CartPort) async throws {
        guard port.bluetooth else { return try await transport.send(bytes, to: port) }
        var o = 0
        while o < bytes.count {
            if o > 0 { await clock.sleep(ms: timing.bluetoothGap) }
            let e = min(o + timing.bluetoothPart, bytes.count)
            try await transport.send(Array(bytes[o ..< e]), to: port)
            o = e
        }
    }

    public var resultText: String? {
        switch state {
        case .sent(let n):
            n == 1 ? "Sent: the FM-1 should now show the new USER bank."
                : "Sent \(n) cartridges: the FM-1 should now show the last one's USER bank."
        case .failed(let e): e
        default: nil
        }
    }
}

/// the fake FM-1 port (the simulator, the Mac, DEBUG): keeps what it was sent, sends nothing
public final class FakeCartTransport: CartTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(port: String, bytes: [UInt8])] = []
    private let list: [CartPort]
    public var onSend: (@Sendable ([UInt8]) -> Void)?

    public init(ports: [CartPort] = [CartPort(id: "fake", name: "FM-1 (simulated)", bluetooth: false)]) { list = ports }

    public func ports() -> [CartPort] { list }

    public func send(_ bytes: [UInt8], to port: CartPort) async throws {
        lock.withLock { _sent.append((port.id, bytes)) }
        onSend?(bytes)
    }

    public var sent: [(port: String, bytes: [UInt8])] { lock.withLock { _sent } }
}
