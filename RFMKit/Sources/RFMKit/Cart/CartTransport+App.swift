// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The app's cartridge sender: on an iPhone or iPad with the device backend, CoreMIDI to the FM-1's destinations (the
// candidates by RemoteMidi.c's rule, ControllerInput.isFM1: never the updater's port, never another device); each
// part goes out with MIDISendSysex, the next only after CoreMIDI says the last one is gone. Everywhere else (the
// simulator, the Mac, the fake link, DEBUG's -cartdemo): FakeCartTransport, which sends nothing. RemoteController lets
// go of the FM-1 for it as for an install (PanelPause.swift).

import Foundation
#if canImport(CoreMIDI)
import CoreMIDI
#endif

extension RemoteController: CartPanelPausing {
    public func pauseForCart() async -> Bool { await pause(as: "RemoteFM1 app / sending a cartridge") }
    public func resumeAfterCart(restart: Bool) { resumeAfterInstall(restart: restart) }
}

extension CartSender {
    private static var appSender: CartSender?

    /// the app's sender, made on first use for the app's link
    public static func shared(for controller: RemoteController) -> CartSender {
        if let s = appSender { return s }
        var made: CartSender?
        #if os(iOS) && !targetEnvironment(simulator)
        var demo = false
        #if DEBUG
        demo = ProcessInfo.processInfo.arguments.contains("-cartdemo")
        #endif
        if controller.backend == .device && !demo, let t = try? CoreMIDICartTransport() {
            made = CartSender(transport: t, panel: controller, simulated: false)
        }
        #endif
        var banks: [UserBank] = []
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-cartdemo") {
            banks = ["BRASS 1", "E.PIANO 2", "STRINGS", "BELLS"].enumerated().map {
                UserBank(slot: [0, 1, 4, 6][$0.offset], arrival: UInt32($0.offset + 1), crc: 0, name: $0.element)
            }
        }
        #endif
        // (a pretend 0.3.1 FM-1: answers the bank requests, sends nothing anywhere)
        let s = made ?? CartSender(transport: FakeCartTransport(fm1: FakeFM1(banks: banks)), panel: controller, simulated: true)
        appSender = s
        return s
    }
}

#if os(iOS) && !targetEnvironment(simulator)
/// CoreMIDI to the FM-1's destinations; one client for the app's life (MIDISendSysex needs no port)
final class CoreMIDICartTransport: CartTransport, @unchecked Sendable {
    // Sendable: client and port never change after init
    private var client = MIDIClientRef()

    struct Failed: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "CoreMIDI error \(status)" }
    }

    init() throws {
        let st = MIDIClientCreateWithBlock("RemoteFM1 cartridge" as CFString, &client) { _ in }
        guard st == noErr else { throw Failed(status: st) }
    }

    deinit {
        if inPort != 0 { MIDIPortDispose(inPort) }
        MIDIClientDispose(client)
    }

    // the replies (0.3.1's SA_INFO_R): an input port on the FM-1's sources, SysEx7 UMP put back together per source
    private var inPort = MIDIPortRef()
    private let lock = NSLock()
    private var connected: Set<MIDIEndpointRef> = []

    final class Assembler: @unchecked Sendable {
        private let lock = NSLock()
        private var bufs: [UInt: [UInt8]] = [:]
        let out: @Sendable ([UInt8]) -> Void
        init(_ out: @escaping @Sendable ([UInt8]) -> Void) { self.out = out }

        /// one MIDI 1.0 UMP packet's words; SysEx7 (type 3) collected, F0 .. F7 handed on whole
        func feed(_ words: [UInt32], from src: UInt) {
            var i = 0
            while i < words.count {
                let w0 = words[i]
                let type = w0 >> 28
                let size = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][Int(type)]
                if type == 3, i + 1 < words.count {
                    let st = (w0 >> 20) & 0xF, n = Int((w0 >> 16) & 0xF), w1 = words[i + 1]
                    let all: [UInt8] = [UInt8((w0 >> 8) & 0xFF), UInt8(w0 & 0xFF), UInt8(w1 >> 24), UInt8((w1 >> 16) & 0xFF),
                                        UInt8((w1 >> 8) & 0xFF), UInt8(w1 & 0xFF)]
                    let data = Array(all.prefix(min(n, 6)))
                    let done: [UInt8]? = lock.withLock {
                        if st == 0 || st == 1 { bufs[src] = [0xF0] }
                        bufs[src, default: [0xF0]] += data
                        guard st == 0 || st == 3 else { return nil }
                        defer { bufs[src] = nil }
                        return bufs[src]! + [0xF7]
                    }
                    if let done { out(done) }
                }
                i += size
            }
        }
    }

    func listen(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        let a = Assembler(handler)
        let st = MIDIInputPortCreateWithProtocol(client, "RemoteFM1 cartridge in" as CFString, ._1_0, &inPort) { @Sendable list, ref in
            let src = UInt(bitPattern: ref)
            for p in list.unsafeSequence() { a.feed(Array(p.words()), from: src) }
        }
        if st != noErr { inPort = 0 }
        connectSources()
    }

    /// the FM-1's sources (RemoteMidi.c's rule), connected to the input port
    private func connectSources() {
        guard inPort != 0 else { return }
        var want: Set<MIDIEndpointRef> = []
        for i in 0 ..< MIDIGetNumberOfSources() {
            let s = MIDIGetSource(i)
            if s != 0, !ControllerInput.offline(s), ControllerInput.isFM1(s) { want.insert(s) }
        }
        lock.withLock {
            for s in connected.subtracting(want) { MIDIPortDisconnectSource(inPort, s) }
            for s in want.subtracting(connected) {
                MIDIPortConnectSource(inPort, s, UnsafeMutableRawPointer(bitPattern: UInt(s) + 1))
            }
            connected = want
        }
    }

    func ports() -> [CartPort] {
        connectSources()
        return portList()
    }

    private func portList() -> [CartPort] {
        (0 ..< MIDIGetNumberOfDestinations()).compactMap { i -> CartPort? in
            let d = MIDIGetDestination(i)
            guard d != 0, !ControllerInput.offline(d), ControllerInput.isFM1(d) else { return nil }
            var uid: Int32 = 0
            MIDIObjectGetIntegerProperty(d, kMIDIPropertyUniqueID, &uid)
            return CartPort(id: "\(uid)", name: ControllerInput.name(d), bluetooth: Self.isBluetooth(d))
        }
    }

    static func isBluetooth(_ e: MIDIEndpointRef) -> Bool {
        var ent = MIDIEntityRef(), dev = MIDIDeviceRef()
        guard MIDIEndpointGetEntity(e, &ent) == noErr, ent != 0, MIDIEntityGetDevice(ent, &dev) == noErr, dev != 0
        else { return false }
        var drv: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(dev, kMIDIPropertyDriverOwner, &drv) == noErr, let drv else { return false }
        return (drv.takeRetainedValue() as String).localizedCaseInsensitiveContains("Bluetooth")
    }

    /// one request alive until CoreMIDI's completion
    private final class Request {
        let buf: UnsafeMutablePointer<UInt8>
        let req = UnsafeMutablePointer<MIDISysexSendRequest>.allocate(capacity: 1)
        var done: CheckedContinuation<Void, Never>?

        init(_ bytes: [UInt8], to dest: MIDIEndpointRef) {
            buf = .allocate(capacity: bytes.count)
            buf.initialize(from: bytes, count: bytes.count)
            req.initialize(to: MIDISysexSendRequest(destination: dest, data: UnsafePointer(buf), bytesToSend: UInt32(bytes.count),
                                       complete: false, reserved: (0, 0, 0), completionProc: { p in
                                           let r = Unmanaged<Request>.fromOpaque(p.pointee.completionRefCon!)
                                           r.takeUnretainedValue().done?.resume()
                                           r.release()
                                       }, completionRefCon: nil))
        }

        deinit {
            req.deallocate()
            buf.deallocate()
        }
    }

    func send(_ bytes: [UInt8], to port: CartPort) async throws {
        guard let uid = Int32(port.id) else { throw Failed(status: -50) }
        var obj = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(uid, &obj, &type) == noErr, type == .destination else { throw Failed(status: -50) }
        let r = Request(bytes, to: MIDIEndpointRef(obj))
        let ref = Unmanaged.passRetained(r)                     // (released by the completion)
        r.req.pointee.completionRefCon = ref.toOpaque()
        var st: OSStatus = noErr
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            r.done = k
            st = MIDISendSysex(r.req)
            if st != noErr {
                ref.release()
                k.resume()
            }
        }
        guard st == noErr else { throw Failed(status: st) }
    }
}
#endif
