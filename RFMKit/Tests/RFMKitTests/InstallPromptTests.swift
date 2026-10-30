// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The owner's iPhone test fixes: the prompt to install RemoteFM1 (InstallPromptState: an FM-1 seen, HELLO not
// answered in time, an answer, another firmware's USB IDs, Bluetooth only, never while installing or while an AU holds
// the unit, Not now per release, the update notice by version; FM1Ports' rule; the prompter's DEBUG prompt and Not
// now in UserDefaults), the Keys from MIDI page's choices, and where the selection goes when its file is deleted.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class InstallPromptTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    private let usbFM1 = FM1Port(name: "FM-1", bluetooth: false, candidate: true)
    private let bleFM1 = FM1Port(name: "FM-1 7938", bluetooth: true, candidate: true)
    private let stock = FM1Port(name: "FM-1", bluetooth: false, candidate: false)

    private func input(_ ports: [FM1Port] = [], searching: Bool = true, newest: RemoteFM1Version? = .init(0, 2, 3))
        -> InstallPromptState.Input {
        var i = InstallPromptState.Input()
        i.ports = ports
        i.searching = searching
        i.newest = newest
        return i
    }

    func testCandidateThatNeverAnswers() {
        var m = InstallPromptState()
        let i = input([usbFM1])
        XCTAssertEqual(m.update(i, now: t0), .none)
        XCTAssertEqual(m.update(i, now: t0 + 3), .none)
        XCTAssertEqual(m.update(i, now: t0 + InstallPromptState.answerWait),
                       .install(unanswered: true, bluetoothOnly: false))
        // the unit answers at last: gone, and the wait starts again after it is lost
        var a = i
        a.answered = true
        a.unitVersion = .init(0, 2, 3)
        XCTAssertEqual(m.update(a, now: t0 + 7), .none)
        XCTAssertEqual(m.update(i, now: t0 + 8), .none)
        XCTAssertEqual(m.update(i, now: t0 + 8 + InstallPromptState.answerWait),
                       .install(unanswered: true, bluetoothOnly: false))
        // unplugged: gone, and the wait starts again
        XCTAssertEqual(m.update(input([]), now: t0 + 20), .none)
        XCTAssertEqual(m.update(i, now: t0 + 21), .none)
    }

    func testOnlyWhileTheLinkAsks() {
        var m = InstallPromptState()
        // the link isn't running (This iPhone): a candidate was never asked, so no prompt
        let off = input([usbFM1], searching: false)
        XCTAssertEqual(m.update(off, now: t0), .none)
        XCTAssertEqual(m.update(off, now: t0 + 60), .none)
        // the search starts: the wait starts then
        XCTAssertEqual(m.update(input([usbFM1]), now: t0 + 61), .none)
        XCTAssertEqual(m.update(input([usbFM1]), now: t0 + 61 + InstallPromptState.answerWait),
                       .install(unanswered: true, bluetoothOnly: false))
    }

    func testAnotherFirmwaresUSBIDs() {
        var m = InstallPromptState()
        let i = input([stock], searching: false)        // (the link never talks to it: no search needed)
        XCTAssertEqual(m.update(i, now: t0), .none)
        XCTAssertEqual(m.update(i, now: t0 + InstallPromptState.otherWait),
                       .install(unanswered: false, bluetoothOnly: false))
        XCTAssertEqual(m.prompt.title, "This FM-1 isn't running RemoteFM1. Install it?")
    }

    func testBluetoothOnly() {
        var m = InstallPromptState()
        let i = input([bleFM1])
        _ = m.update(i, now: t0)
        let p = m.update(i, now: t0 + InstallPromptState.answerWait)
        XCTAssertEqual(p, .install(unanswered: true, bluetoothOnly: true))
        XCTAssertEqual(p.title, "This FM-1 isn't answering as RemoteFM1. Install it?")
        XCTAssertTrue(p.detail.contains("USB cable"))
        // a USB one too: it can be installed
        var m2 = InstallPromptState()
        let both = input([bleFM1, usbFM1])
        _ = m2.update(both, now: t0)
        XCTAssertEqual(m2.update(both, now: t0 + 10), .install(unanswered: true, bluetoothOnly: false))
    }

    func testNeverWhileInstallingOrHeldOrFake() {
        for k in 0..<3 {
            var m = InstallPromptState()
            var i = input([usbFM1, stock])
            switch k {
            case 0: i.installing = true
            case 1: i.heldElsewhere = true
            default: i.enabled = false
            }
            XCTAssertEqual(m.update(i, now: t0), .none)
            XCTAssertEqual(m.update(i, now: t0 + 30), .none, "case \(k)")
            // over: the waits start from then, not from before
            let free = input([usbFM1])
            XCTAssertEqual(m.update(free, now: t0 + 31), .none)
            XCTAssertEqual(m.update(free, now: t0 + 31 + InstallPromptState.answerWait), .install(unanswered: true, bluetoothOnly: false))
        }
    }

    func testNotNowPerRelease() {
        var m = InstallPromptState()
        var i = input([stock])
        i.notNowInstall = "0.2.3"
        _ = m.update(i, now: t0)
        XCTAssertEqual(m.update(i, now: t0 + 30), .none)
        i.newest = .init(0, 2, 4)                       // a newer release asks again
        XCTAssertEqual(m.update(i, now: t0 + 31), .install(unanswered: false, bluetoothOnly: false))
        // Not now said with no list (""): quiet while there is none
        var j = input([stock], newest: nil)
        j.notNowInstall = ""
        _ = m.update(j, now: t0 + 40)
        XCTAssertEqual(m.update(j, now: t0 + 50), .none)
    }

    func testUpdateNotice() {
        var m = InstallPromptState()
        var i = input([usbFM1])
        i.answered = true
        i.unitVersion = .init(0, 2, 2)
        XCTAssertEqual(m.update(i, now: t0), .update(version: "0.2.3", bluetooth: false))
        XCTAssertEqual(m.prompt.title, "RemoteFM1 0.2.3 is available for this FM-1")
        i.unitOverBluetooth = true
        XCTAssertEqual(m.update(i, now: t0 + 1), .update(version: "0.2.3", bluetooth: true))
        i.notNowUpdate = "0.2.3"
        XCTAssertEqual(m.update(i, now: t0 + 2), .none)
        i.newest = .init(0, 2, 4)
        XCTAssertEqual(m.update(i, now: t0 + 3), .update(version: "0.2.4", bluetooth: true))
        i.unitVersion = .init(0, 2, 4)                  // up to date
        XCTAssertEqual(m.update(i, now: t0 + 4), .none)
        i.unitVersion = nil                             // a version it can't read: nothing
        XCTAssertEqual(m.update(i, now: t0 + 5), .none)
        i.unitVersion = .init(0, 2, 2)
        i.heldElsewhere = true
        XCTAssertEqual(m.update(i, now: t0 + 6), .none)
    }

    func testPortRule() {
        let rfm = Int32(bitPattern: 0x1209_0001)
        XCTAssertEqual(FM1Ports.classify(bluetooth: false, usbID: rfm, deviceName: "ChoralRoot FM-1", endpointName: "ChoralRoot FM-1"),
                       FM1Port(name: "ChoralRoot FM-1", bluetooth: false, candidate: true))
        XCTAssertEqual(FM1Ports.classify(bluetooth: false, usbID: rfm, deviceName: "Felucca", endpointName: "Felucca")?.candidate, true)
        // another USB ID, an FM-1's name: another firmware; any other device: nothing
        XCTAssertEqual(FM1Ports.classify(bluetooth: false, usbID: 0x1234_5678, deviceName: "FM-1", endpointName: "FM-1 Midi"),
                       FM1Port(name: "FM-1 Midi", bluetooth: false, candidate: false))
        XCTAssertNil(FM1Ports.classify(bluetooth: false, usbID: 0x1234_5678, deviceName: "Launchkey", endpointName: "Launchkey MIDI"))
        XCTAssertNil(FM1Ports.classify(bluetooth: false, usbID: 0x1234_5678, deviceName: "FM-1", endpointName: "FM-1 Update"))
        XCTAssertNil(FM1Ports.classify(bluetooth: false, usbID: rfm, deviceName: "Felucca", endpointName: "Felucca Update"))
        // Bluetooth: the name only
        XCTAssertEqual(FM1Ports.classify(bluetooth: true, usbID: nil, deviceName: "FM-1 7938", endpointName: "Bluetooth"),
                       FM1Port(name: "Bluetooth", bluetooth: true, candidate: true))
        XCTAssertNil(FM1Ports.classify(bluetooth: true, usbID: nil, deviceName: "KeyStep", endpointName: "KeyStep"))
    }

    // MARK: the prompter

    #if DEBUG
    @MainActor
    func testPrompterDebugPromptAndNotNow() async throws {
        let suite = "rfm1.test.prompt.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfm1-prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = RemoteController(backend: .fake(bluetooth: false), patternOn: false)
        defer { c.shutdown() }
        let inst = FirmwareInstaller(releases: RemoteFM1Releases(cacheDirectory: dir), packages: FirmwarePackages(directory: dir),
                                     panel: c, transport: { _ in throw CancellationError() }, simulated: true)
        // the fake unit: never by itself
        let quiet = InstallPrompter(controller: c, installer: inst, defaults: d, arguments: [])
        quiet.tick()
        XCTAssertEqual(quiet.prompt, .none)
        // DEBUG's -fm1prompt: shown, hidden while the install page is open, Not now remembered for the release
        let p = InstallPrompter(controller: c, installer: inst, defaults: d, arguments: ["-fm1prompt", "bluetooth"])
        p.tick()
        XCTAssertEqual(p.prompt, .install(unanswered: true, bluetoothOnly: true))
        p.installPageOpen = true
        XCTAssertEqual(p.prompt, .none)
        p.installPageOpen = false
        XCTAssertEqual(p.prompt, .install(unanswered: true, bluetoothOnly: true))
        p.notNow()
        XCTAssertEqual(p.prompt, .none)
        XCTAssertEqual(d.string(forKey: InstallPrompter.notNowInstallKey), "")    // (no list here)
        let u = InstallPrompter(controller: c, installer: inst, defaults: d, arguments: ["-fm1prompt", "update"])
        u.tick()
        XCTAssertEqual(u.prompt, .update(version: "0.2.3", bluetooth: false))
        u.notNow()
        XCTAssertEqual(d.string(forKey: InstallPrompter.notNowUpdateKey), "0.2.3")
    }
    #endif

    // MARK: Keys from MIDI's page

    func testKeyChannelChoicesRoundTrip() {
        let groups = AUSettings.KeyChannel.groups
        XCTAssertEqual(groups.flatMap { $0 }, AUSettings.KeyChannel.all)
        XCTAssertEqual(groups.map(\.count), [1, 16, 1])
        XCTAssertEqual(groups.flatMap { $0 }.map(\.longLabel).first, "Any")
        XCTAssertEqual(AUSettings.KeyChannel.channel(10).longLabel, "Channel 10")
        XCTAssertEqual(AUSettings.KeyChannel.channel(10).label, "Ch 10")
        XCTAssertEqual(AUSettings.KeyChannel.off.longLabel, "Off")
        for k in AUSettings.KeyChannel.all {
            var s = AUSettings()
            s.keyChannel = k                            // (a pick on the page)
            let back = AUSettings(s.dict)
            XCTAssertEqual(back.keyChannel, k)
            XCTAssertEqual(AUSettings.KeyChannel(engineValue: Int(k.engineValue)), k)
            XCTAssertEqual(back.notesPlayKeys, k != .off)
        }
    }

    // MARK: deleting the selected firmware

    func testReplacementWhenDeleting() {
        func c(_ key: String, _ id: String, _ v: String, wasm: Bool) -> CoreInfo {
            var i = CoreInfo(id: key)
            i.coreID = id
            i.version = v
            if wasm {
                i.kind = "wasm"
                i.sha256 = String(key.dropFirst(5))
            }
            return i
        }
        let cat = [c("choralroot", "choralroot", "0.26.1", wasm: false), c("felucca", "felucca", "1.6.1", wasm: false),
                   c("rfm1:aaa", "felucca", "1.6.2", wasm: true), c("rfm1:bbb", "felucca", "1.6.10", wasm: true),
                   c("rfm1:ccc", "amb", "1.3", wasm: true)]
        // not the selection: nothing moves
        XCTAssertNil(CorePlayer.replacement(deleting: "rfm1:aaa", selected: "choralroot", in: cat))
        // the same firmware's other file (the newest), else its built-in core, else the first core
        XCTAssertEqual(CorePlayer.replacement(deleting: "rfm1:aaa", selected: "rfm1:aaa", in: cat), "rfm1:bbb")
        XCTAssertEqual(CorePlayer.replacement(deleting: "rfm1:bbb", selected: "rfm1:bbb", in: cat), "rfm1:aaa")
        XCTAssertEqual(CorePlayer.replacement(deleting: "rfm1:bbb", selected: "rfm1:bbb",
                                              in: cat.filter { $0.id != "rfm1:aaa" }), "felucca")
        XCTAssertEqual(CorePlayer.replacement(deleting: "rfm1:ccc", selected: "rfm1:ccc", in: cat), "choralroot")
    }
}
