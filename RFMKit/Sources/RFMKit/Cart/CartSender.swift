// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Sends DX7 cartridges to an FM-1 running RemoteFM1 0.3.0 or later, which keeps each as a user bank (docs/CART-UPLOAD.md on
// RemoteFM1's cart-upload branch). The firmware collects a dump only as the instrument, with no host session, so the
// app's panel lets go of the FM-1 first as for a firmware install (PanelPause.swift: the session ended, the lease held
// with no session), then ~400 ms, then each dump as one SysEx to the FM-1's port (never the updater's), 1 s between
// dumps (one still being written to the flash drops the next), then the panel starts again. Over Bluetooth MIDI the
// dump goes in 512-byte parts 100 ms apart (its input holds 256 packets); USB takes it whole. 0.3.0 sends no reply:
// the unit shows the new USER bank. The port is found as the app's link finds the FM-1 (RemoteMidi.c's rule,
// rfme_fm1_candidate, via ControllerInput.isFM1); with several, the page asks which. 0.3.1 (CartBanks.swift) lists
// its 16 slots (BANKS, asked raw on the FM-1's port, in a session too), takes a dump into a chosen slot (TARGET),
// deletes one (DELETE), names one (NAME) and confirms every dump (STORED, waited for instead of the 1 s); TARGET,
// DELETE and the dumps go while the panel is paused, and the list is read again before it starts. No reply to BANKS
// within 1 s: 0.3.0, the plain send as before.

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
    /// every whole SysEx message heard from the FM-1 (its replies), on any thread
    func listen(_ handler: @escaping @Sendable ([UInt8]) -> Void)
}

extension CartTransport {
    public func listen(_ handler: @escaping @Sendable ([UInt8]) -> Void) {}
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

/// replies heard on the FM-1's source (CoreMIDI's thread, or the fake's, at once)
final class CartInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[UInt8]] = []

    func heard(_ m: [UInt8]) {
        guard let (cmd, b) = SAInfo.decode(m), cmd == SAInfo.reply, !b.isEmpty else { return }
        lock.withLock { bodies.append(b) }
    }

    func drop(op: UInt8) { lock.withLock { bodies.removeAll { $0[0] == op } } }

    func take(op: UInt8) -> [UInt8]? {
        lock.withLock {
            guard let i = bodies.firstIndex(where: { $0[0] == op }) else { return nil }
            return bodies.remove(at: i)
        }
    }
}

@MainActor @Observable
public final class CartSender {
    public struct Timing: Sendable {
        public var afterPause = 400                 // the session's end, before the first byte
        public var between = 1000                   // between dumps (0.3.0: the flash write)
        public var bluetoothPart = 512
        public var bluetoothGap = 100
        public var reply = 1000                     // BANKS, NAME, TARGET; none at all: 0.3.0
        public var delete = 1500                    // DELETE's reply (the directory written; up to ~0.5 s behind a save)
        public var stored = 2000                    // STORED after a dump
        public var poll = 20
        public init() {}
    }

    public enum State: Equatable {
        case idle
        case sending(done: Int, total: Int)
        case working(String)                        // a replace, a remove, a rename, the list
        case sent(Int)
        case done(String)
        case failed(String)
    }

    /// what the FM-1 answers to SA_INFO
    public enum Firmware: Equatable, Sendable {
        case unknown
        case v030                                   // no reply: up to 3 banks, sending only
        case v031
    }

    public private(set) var files: [CartFile] = []
    public private(set) var ports: [CartPort] = []
    public var chosen: String?
    public private(set) var state: State = .idle
    public private(set) var firmware: Firmware = .unknown
    public private(set) var banks: BankList?
    /// the slots the last send's dumps went to (STORED)
    public private(set) var storedSlots: [Int] = []
    public let simulated: Bool
    @ObservationIgnored let transport: any CartTransport
    @ObservationIgnored weak var panel: (any CartPanelPausing)?
    @ObservationIgnored let clock: any CartClock
    @ObservationIgnored let timing: Timing
    @ObservationIgnored let inbox = CartInbox()

    public init(transport: any CartTransport, panel: (any CartPanelPausing)?, clock: any CartClock = SystemCartClock(),
                timing: Timing = .init(), simulated: Bool) {
        self.transport = transport
        self.panel = panel
        self.clock = clock
        self.timing = timing
        self.simulated = simulated
        let box = inbox
        transport.listen { box.heard($0) }
    }

    public var carts: [DX7Cart] { files.flatMap(\.carts) }
    public var busy: Bool {
        switch state {
        case .sending, .working: true
        default: false
        }
    }

    public func add(_ file: CartFile) {
        guard !busy else { return }
        files.append(file)
        settle()
    }

    private func settle() {
        switch state {
        case .sent, .failed, .done: state = .idle
        default: break
        }
    }

    public func add(url: URL) { add(Self.read(url)) }

    static func read(_ url: URL) -> CartFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return CartFile(name: url.lastPathComponent, data: try Data(contentsOf: url))
        } catch {
            var f = CartFile(name: url.lastPathComponent, data: Data())
            f.error = "The file couldn't be read: \(error.localizedDescription)"
            return f
        }
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

    private var noPort: String {
        ports.isEmpty ? "No FM-1 found. Connect it with USB (or Bluetooth MIDI) and try again." : "Choose which FM-1 to send to."
    }

    // MARK: requests

    /// a request, then its reply's body (nil after the timeout)
    private func ask(_ body: [UInt8], to port: CartPort, timeout: Int) async -> [UInt8]? {
        inbox.drop(op: body[0])
        do { try await transport.send(SAInfo.encode(cmd: SAInfo.request, body), to: port) } catch { return nil }
        return await wait(op: body[0], timeout: timeout)
    }

    private func wait(op: UInt8, timeout: Int) async -> [UInt8]? {
        var t = 0
        while true {
            if let b = inbox.take(op: op) { return b }
            if t >= timeout { return nil }
            await clock.sleep(ms: timing.poll)
            t += timing.poll
        }
    }

    /// BANKS: the list, and so which firmware answers (no reply: 0.3.0). Works in a session too (no pause)
    @discardableResult
    func list(_ port: CartPort) async -> Bool {
        guard let b = await ask([SAInfo.Op.banks.rawValue], to: port, timeout: timing.reply), let l = BankList(body: b) else {
            if firmware != .v031 { firmware = .v030; banks = nil }
            return false
        }
        firmware = .v031
        banks = l
        return true
    }

    /// asks the FM-1 for its banks (the page's appearance, Refresh)
    public func refresh() async {
        guard !busy else { return }
        rescan()
        guard let port = target else { return }
        state = .working("Asking the FM-1 for its banks…")
        await list(port)
        state = .idle
    }

    /// the panel let go of the FM-1 for `work`, then started again; the list read again while still paused
    private func paused(_ port: CartPort, _ work: () async -> String?) async -> String? {
        let restart = await panel?.pauseForCart() ?? false
        await clock.sleep(ms: timing.afterPause)
        let failure = await work()
        if firmware == .v031 { await list(port) }
        panel?.resumeAfterCart(restart: restart)
        return failure
    }

    /// sends every cartridge, in order, each to the next free slot (0.3.1: each confirmed by STORED)
    public func send() async {
        guard !busy else { return }
        rescan()
        let list = carts
        guard !list.isEmpty else { state = .failed("No cartridge to send."); return }
        guard let port = target else { state = .failed(noPort); return }
        if firmware == .unknown { await self.list(port) }
        state = .sending(done: 0, total: list.count)
        storedSlots = []
        let failure = await paused(port) {
            for (i, c) in list.enumerated() {
                if i > 0 && firmware != .v031 { await clock.sleep(ms: timing.between) }
                if let e = await dump(c, to: port) { return "Cartridge \(i + 1): \(e)" }
                state = .sending(done: i + 1, total: list.count)
            }
            return nil
        }
        state = failure.map { .failed($0) } ?? .sent(list.count)
    }

    /// one dump; on 0.3.1 the STORED that follows (nil: stored, or 0.3.0, which says nothing)
    private func dump(_ c: DX7Cart, to port: CartPort) async -> String? {
        inbox.drop(op: SAInfo.Op.stored.rawValue)
        do { try await write(c.bytes, to: port) } catch { return "sending failed: \(error.localizedDescription)" }
        guard firmware == .v031 else { return nil }
        guard let r = await wait(op: SAInfo.Op.stored.rawValue, timeout: timing.stored), r.count >= 3 else {
            return "the FM-1 didn't confirm it. Check its screen."
        }
        if let e = SAInfo.words(r[2]) { return e }
        storedSlots.append(Int(r[1]))
        return nil
    }

    /// replaces the bank in `slot` with the file's cartridge (it must hold exactly one): TARGET, the dump, STORED
    public func replace(slot: Int, with file: CartFile) async {
        guard !busy else { return }
        if let e = file.error { state = .failed(e); return }
        guard file.carts.count == 1, let c = file.carts.first else {
            state = .failed("\(file.name) holds \(file.carts.count) cartridges. Choose a file with one to replace a bank.")
            return
        }
        rescan()
        guard let port = target else { state = .failed(noPort); return }
        guard firmware == .v031 else { state = .failed("This FM-1's firmware can't replace a bank. Update RemoteFM1."); return }
        state = .working("Replacing USER\(slot + 1)…")
        let failure = await paused(port) {
            guard let r = await ask([SAInfo.Op.target.rawValue, UInt8(slot)], to: port, timeout: timing.reply), r.count >= 3
            else { return "The FM-1 didn't answer." }
            if let e = SAInfo.words(r[2]) { return e }
            storedSlots = []
            return await dump(c, to: port)
        }
        state = failure.map { .failed($0) } ?? .done("USER\(slot + 1) replaced with \(file.name).")
    }

    /// removes the bank in `slot` (DELETE: the reply once it is gone for good)
    public func delete(slot: Int) async {
        guard !busy else { return }
        rescan()
        guard let port = target else { state = .failed(noPort); return }
        state = .working("Removing USER\(slot + 1)…")
        let failure = await paused(port) {
            guard let r = await ask([SAInfo.Op.delete.rawValue, UInt8(slot)], to: port, timeout: timing.delete), r.count >= 3
            else { return "The FM-1 didn't answer." }
            return SAInfo.words(r[2])
        }
        state = failure.map { .failed($0) } ?? .done("USER\(slot + 1) removed.")
    }

    /// names the bank in `slot` (NAME, 1..10 printable characters; works in a session, no pause)
    public func rename(slot: Int, to name: String) async {
        guard !busy else { return }
        let n = Array(name.utf8.map { (0x20 ... 0x7E).contains($0) ? $0 : 0x20 }.prefix(10))
        guard !n.isEmpty, n.contains(where: { $0 != 0x20 }) else { state = .failed("Type a name."); return }
        rescan()
        guard let port = target else { state = .failed(noPort); return }
        state = .working("Renaming USER\(slot + 1)…")
        let r = await ask([SAInfo.Op.name.rawValue, UInt8(slot)] + n, to: port, timeout: timing.reply)
        var failure: String?
        if let r, r.count >= 3 { failure = SAInfo.words(r[2]) } else { failure = "The FM-1 didn't answer." }
        if failure == nil {
            await clock.sleep(ms: 200)                  // (written a moment after the reply)
            await list(port)
        }
        state = failure.map { .failed($0) } ?? .done("USER\(slot + 1) renamed.")
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
            if !storedSlots.isEmpty {
                n == 1 ? "Stored as USER\(storedSlots[0] + 1)."
                    : "Stored as " + storedSlots.map { "USER\($0 + 1)" }.joined(separator: ", ") + "."
            } else {
                n == 1 ? "Sent: the FM-1 should now show the new USER bank."
                    : "Sent \(n) cartridges: the FM-1 should now show the last one's USER bank."
            }
        case .done(let s): s
        case .failed(let e): e
        default: nil
        }
    }
}

/// the fake FM-1 port (the simulator, the Mac, DEBUG): keeps what it was sent; with a FakeFM1, which answers as 0.3.1,
/// else silent as 0.3.0
public final class FakeCartTransport: CartTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(port: String, bytes: [UInt8])] = []
    private let list: [CartPort]
    public var onSend: (@Sendable ([UInt8]) -> Void)?

    public let fm1: FakeFM1?
    private var heard: (@Sendable ([UInt8]) -> Void)?

    public init(ports: [CartPort] = [CartPort(id: "fake", name: "FM-1 (simulated)", bluetooth: false)], fm1: FakeFM1? = nil) {
        list = ports
        self.fm1 = fm1
    }

    public func listen(_ handler: @escaping @Sendable ([UInt8]) -> Void) { lock.withLock { heard = handler } }

    public func ports() -> [CartPort] { list }

    public func send(_ bytes: [UInt8], to port: CartPort) async throws {
        lock.withLock { _sent.append((port.id, bytes)) }
        onSend?(bytes)
        if let fm1, let h = lock.withLock({ heard }) { for m in fm1.receive(bytes) { h(m) } }
    }

    public var sent: [(port: String, bytes: [UInt8])] { lock.withLock { _sent } }
}
