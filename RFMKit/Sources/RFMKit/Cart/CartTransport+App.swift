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
        let s = made ?? CartSender(transport: FakeCartTransport(), panel: controller, simulated: true)
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

    deinit { MIDIClientDispose(client) }

    func ports() -> [CartPort] {
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
