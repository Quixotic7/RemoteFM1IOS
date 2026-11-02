// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The RemoteFM1 firmware running in the app (its .rfm1) as a cartridge target: what the website's RemoteFM1 "editor"
// is (web/site/js/cart.js through its in-page port). The SysEx goes into the core (CorePlayer.managerSend), its
// replies come back from the core's MIDI out (managerTake, polled while the page is open: open() / close()).

import Foundation

@MainActor
public final class CoreCartTransport: CartTransport, @unchecked Sendable {
    public nonisolated static let port = CartPort(id: "core", name: "RemoteFM1 in this app", bluetooth: false)
    /// the app runs the RemoteFM1 firmware now (set by the app when the firmware changes)
    public nonisolated(unsafe) static var running = false
    public nonisolated static let firmwareID = "remotefm1"
    weak var player: CorePlayer?
    private var handler: (@Sendable ([UInt8]) -> Void)?
    private var poll: Task<Void, Never>?

    public init(player: CorePlayer) { self.player = player }

    public nonisolated func ports() -> [CartPort] { [Self.port] }

    public nonisolated func send(_ bytes: [UInt8], to _: CartPort) async throws {
        let ok = await Task { @MainActor [weak self] in
            self?.open()                                    // (its replies read from the first request on)
            return await self?.player?.managerSend(bytes) ?? false
        }.value
        guard ok else { throw CocoaError(.fileWriteUnknown) }
    }

    public nonisolated func listen(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        Task { @MainActor in self.handler = handler }
    }

    /// the core's replies read while the page is open
    public func open() {
        guard poll == nil, let player else { return }
        player.managerAttach(true)
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                guard let self, let p = self.player else { return }
                for m in p.managerTake() { self.handler?(m) }
            }
        }
    }

    public func close() {
        poll?.cancel()
        poll = nil
        player?.managerAttach(false)
    }
}

/// the app's cartridge targets together: RemoteFM1 running in the app (while it is the running firmware) and the
/// FM-1s the device transport finds. Each send goes to its port's transport; replies come from both
public final class CombinedCartTransport: CartTransport, @unchecked Sendable {
    let core: CoreCartTransport
    let device: any CartTransport
    /// whether the app runs RemoteFM1 now (read on the main thread; the core port is listed only then)
    let coreRunning: @Sendable () -> Bool

    public init(core: CoreCartTransport, device: any CartTransport, coreRunning: @escaping @Sendable () -> Bool) {
        self.core = core
        self.device = device
        self.coreRunning = coreRunning
    }

    public func ports() -> [CartPort] { (coreRunning() ? [CoreCartTransport.port] : []) + device.ports() }

    public func send(_ bytes: [UInt8], to port: CartPort) async throws {
        if port.id == CoreCartTransport.port.id { try await core.send(bytes, to: port) } else { try await device.send(bytes, to: port) }
    }

    public func listen(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        core.listen(handler)
        device.listen(handler)
    }
}
