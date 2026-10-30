// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// Where the installer finds the FM-1. On an iPhone or iPad: FM1Kit's CoreMIDITransport without Bluetooth MIDI ports
// (an install over Bluetooth is not offered: too slow, and a dropped link mid-write leaves the FM-1 in its loader; a
// unit on both would also answer twice, which FM1Kit refuses). Everywhere else (the simulator, whose CoreMIDI can see
// the Mac's devices; the Mac tests; DEBUG's demo mode): FM1Kit's SimulatedFM1, prepared for each package. Nothing on
// the simulator or the Mac ever creates a CoreMIDI client here.

import FM1Kit
import Foundation
#if canImport(CoreMIDI)
import CoreMIDI
#endif

/// makes (or reuses) the transport for one package; called on the main actor before each check, install or resume
public typealias InstallTransportFactory = @MainActor (FwscPackage) throws -> any MIDITransport

public enum InstallTransport {
    /// a SimulatedFM1, made once and prepared for each package (so a cut-off install can be resumed on it)
    @MainActor public static func simulated(_ options: SimulatedFM1.Options = .init()) -> InstallTransportFactory {
        var device: SimulatedFM1?
        return { pkg in
            let d = device ?? SimulatedFM1(options: options)
            device = d
            d.prepare(for: pkg)
            return d
        }
    }

    #if os(iOS) && !targetEnvironment(simulator)
    /// CoreMIDI, USB ports only; one client for the installer's life
    @MainActor public static func usb(clientName: String = "RemoteFM1 installer") -> InstallTransportFactory {
        var transport: USBOnlyTransport?
        return { _ in
            if let t = transport { return t }
            let t = try USBOnlyTransport(clientName: clientName)
            transport = t
            return t
        }
    }
    #endif
}

#if canImport(CoreMIDI)
/// FM1Kit's CoreMIDITransport, less the ports whose device is Bluetooth MIDI's (its driver owner names Bluetooth, as
/// ControllerInput.isFM1 tells them)
final class USBOnlyTransport: MIDITransport, @unchecked Sendable {
    // Sendable: `base` never changes and is Sendable itself
    let base: CoreMIDITransport

    init(clientName: String) throws { base = try CoreMIDITransport(clientName: clientName) }

    func ports() async -> [MIDIPortDescriptor] { await base.ports().filter { !Self.isBluetooth($0) } }
    func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection { try await base.open(port) }
    func changes() -> AsyncStream<Void> { base.changes() }

    /// the pair's source (CoreMIDITransport's id: "<source unique ID>:<destination unique ID>") is on Bluetooth MIDI
    static func isBluetooth(_ port: MIDIPortDescriptor) -> Bool {
        guard let first = port.id.split(separator: ":").first, let uid = MIDIUniqueID(first) else { return false }
        var obj = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(uid, &obj, &type) == noErr else { return false }
        var ent = MIDIEntityRef(), dev = MIDIDeviceRef()
        guard MIDIEndpointGetEntity(obj, &ent) == noErr, ent != 0, MIDIEntityGetDevice(ent, &dev) == noErr, dev != 0
        else { return false }
        var drv: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(dev, kMIDIPropertyDriverOwner, &drv) == noErr, let drv else { return false }
        return (drv.takeRetainedValue() as String).localizedCaseInsensitiveContains("Bluetooth")
    }
}
#endif
