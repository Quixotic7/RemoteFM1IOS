// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// M4 on the Mac: the lease (RFMLease.h) on its own, with two clients in this process and with a forked second
// process; the yield path on the process-wide shared fake unit (no SESSION 0, nothing sent after the takeover); and
// PanelSession's rules (settle-delay auto-claim, owner-UUID reclaim, duplicates, staleness). Only fake units: every
// link here is RFMC_FAKE with the shared fake, and the lease files are temporary.

import Foundation
import RFMCore
import XCTest
@testable import RFMKit

final class LeaseTests: XCTestCase {
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("lease.bin").path }
    private var note = ""

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfmkit-m4-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        note = "com.quixotic7.remotefm1.test.\(UUID().uuidString.prefix(8)).lease"
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func client(_ name: String, _ id: UUID = UUID(), stale: UInt32 = 3000) -> OpaquePointer {
        var err: Int32 = 0
        let l = rfml_open(path, note, &err)!
        rfml_set_stale_ms(l, stale)
        PanelSession.setIdentity(l, id, name)
        let ref = LeaseRef(p: l)
        addTeardownBlock { rfml_close(ref.p) }
        return l
    }

    private func view(_ l: OpaquePointer) -> rfml_view_t {
        var v = rfml_view_t()
        rfml_view(l, &v)
        return v
    }

    private func until(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return cond()
    }

    // MARK: the record

    func testClaimEpochAckAndView() {
        let ida = UUID()
        let a = client("host A / ChoralRoot", ida), b = client("host B / Felucca")
        XCTAssertEqual(view(a).empty, 1)
        XCTAssertEqual(view(a).stale, 1)

        var c = rfml_claim_t()
        XCTAssertEqual(rfml_claim(a, 300, &c), 1)
        XCTAssertEqual(c.epoch, 1)
        XCTAssertEqual(c.waited, 0, "nobody to wait for")
        let v = view(b)
        XCTAssertEqual(v.epoch, 1)
        XCTAssertEqual(v.consistent, 1)
        XCTAssertEqual(v.mine, 0)
        XCTAssertEqual(v.stale, 0)
        XCTAssertEqual(PanelSession.uuid(v), ida)
        XCTAssertEqual(v.pid, getpid())
        XCTAssertEqual(RemoteController.string(v.name), "host A / ChoralRoot")
        XCTAssertEqual(rfml_current(a), 1)

        // B takes it: A is fresh, so B waits for A's ack, which nobody gives here: the wait times out
        XCTAssertEqual(rfml_claim(b, 120, &c), 1)
        XCTAssertEqual(c.epoch, 2)
        XCTAssertEqual(c.previous, 1)
        XCTAssertEqual(c.waited, 1)
        XCTAssertEqual(c.acked, 0)
        XCTAssertGreaterThanOrEqual(c.wait_ms, 110)
        XCTAssertEqual(rfml_current(a), 0, "A still current after B's claim")
        XCTAssertEqual(rfml_current(b), 1)
        XCTAssertEqual(view(a).owner_is_me, 0)
        XCTAssertEqual(RemoteController.string(view(a).name), "host B / Felucca")

        // A answers late; then A takes it back and B acks from its notification handler: the claim sees the ack
        rfml_ack(a)
        XCTAssertEqual(view(a).released, 1)
        final class Ctx { let l: OpaquePointer; init(_ l: OpaquePointer) { self.l = l } }
        let ctx = Unmanaged.passRetained(Ctx(b))
        rfml_observe(b, { p in
            let l = Unmanaged<Ctx>.fromOpaque(p!).takeUnretainedValue().l
            if rfml_current(l) == 0 { rfml_ack(l) }
        }, ctx.toOpaque())
        XCTAssertEqual(rfml_claim(a, 300, &c), 1)
        rfml_observe(b, nil, nil)
        ctx.release()
        XCTAssertEqual(c.epoch, 3)
        XCTAssertEqual(c.waited, 1)
        XCTAssertEqual(c.acked, 1, "B's ack (from its notification) did not reach A's claim")
        XCTAssertLessThan(c.wait_ms, 250)
        XCTAssertGreaterThan(rfml_notifications(b), 0)
        print("lease: B's ack reached A's claim in \(c.wait_ms) ms, B saw \(rfml_notifications(b)) notifications")
    }

    func testHeartbeatStaleness() {
        let a = client("A", stale: 3000), b = client("B", stale: 3000)
        var c = rfml_claim_t()
        _ = rfml_claim(a, 0, &c)
        XCTAssertEqual(view(b).stale, 0)
        rfml_test_age(a, 3500)                     // (as if A's heartbeat stopped 3.5 s ago)
        XCTAssertEqual(view(b).stale, 1)
        XCTAssertGreaterThan(view(b).age_ms, 3000)
        // a stale owner is not waited for
        _ = rfml_claim(b, 300, &c)
        XCTAssertEqual(c.waited, 0)
        // A's heartbeat no longer counts (not current); B's does
        rfml_heartbeat(a)
        XCTAssertEqual(rfml_current(a), 0)
        rfml_test_age(b, 3500)
        XCTAssertEqual(view(a).stale, 1)
        rfml_heartbeat(b)
        XCTAssertEqual(view(a).stale, 0)
        // the owner gone: pid 0, the owner field kept; an explicit release: stale at once
        rfml_detach(b)
        XCTAssertEqual(view(a).pid, 0)
        XCTAssertEqual(view(a).empty, 0)
        _ = rfml_claim(b, 0, &c)
        rfml_release(b)
        XCTAssertEqual(view(a).stale, 1)
    }

    /// a second process (fork, the record mapped there itself) holds the lease; this process takes it and the child
    /// acks and exits
    func testSecondProcessHoldsAndYields() throws {
        let a = client("parent")
        let childID = UUID()
        let pid = withUnsafeBytes(of: childID.uuid) { b in
            rfml_test_child(path, b.bindMemory(to: UInt8.self).baseAddress, 5000)
        }
        try XCTSkipIf(pid < 0, "fork failed")
        XCTAssertTrue(until(2) { self.view(a).pid == pid && self.view(a).consistent != 0 }, "the child never claimed")
        var v = view(a)
        XCTAssertEqual(PanelSession.uuid(v), childID)
        XCTAssertEqual(v.stale, 0)
        XCTAssertTrue(PanelSession.alive(pid))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertLessThan(view(a).age_ms, 200, "the child's heartbeat is not moving")
        var c = rfml_claim_t()
        XCTAssertEqual(rfml_claim(a, 300, &c), 1)
        XCTAssertEqual(c.waited, 1)
        XCTAssertEqual(c.acked, 1, "the child did not ack")
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        XCTAssertEqual((status >> 8) & 0xFF, 0, "the child timed out instead of yielding")
        v = view(a)
        XCTAssertEqual(v.mine, 1)
        XCTAssertFalse(PanelSession.alive(pid))
        print("lease: second process \(pid) yielded, ack in \(c.wait_ms) ms")
    }

    // MARK: links on the shared fake unit

    private func link(_ label: String) -> OpaquePointer {
        var cfg = rfmc_cfg_t()
        cfg.backend = Int32(RFMC_FAKE)
        cfg.shared_fake = 1
        cfg.fps = 20
        return "RFMKit test".withCString { hn in label.withCString { lb in
            cfg.host_name = hn
            cfg.label = lb
            cfg.lock_path = nil
            return rfmc_new(&cfg)!
        } }
    }

    private func linkState(_ c: OpaquePointer) -> rfmc_status_t {
        var st = rfmc_status_t()
        rfmc_status(c, &st)
        return st
    }

    private func sender(_ label: String) -> rfmc_sender_t? {
        var r = rfmc_shared_t()
        rfmc_shared_fake(&r)
        for i in 0..<r.nsenders where RemoteController.string(rfmc_shared_sender(&r, i).label) == label {
            return rfmc_shared_sender(&r, i)
        }
        return nil
    }

    private func lastStarter() -> String {
        var r = rfmc_shared_t()
        rfmc_shared_fake(&r)
        return RemoteController.string(r.last_starter)
    }

    /// A owns the shared fake; B takes it: A drops at once, acks, sends nothing more and never SESSION 0; then back
    func testTakeoverOnTheSharedFakeNeverSendsSession0() {
        let tag = UUID().uuidString.prefix(6)
        let la = "A-\(tag)", lb = "B-\(tag)"
        let ka = client(la), kb = client(lb)
        let a = link(la), b = link(lb)
        rfmc_set_lease(a, ka)
        rfmc_set_lease(b, kb)
        defer {
            rfmc_free(a)
            rfmc_free(b)
        }
        var c = rfml_claim_t()
        XCTAssertEqual(rfmc_claim(a, 300, &c), 1)
        XCTAssertTrue(until(5) { Int(self.linkState(a).state) == RFMC_CONNECTED }, "A never connected")
        XCTAssertEqual(lastStarter(), la)
        Thread.sleep(forTimeInterval: 0.3)           // (A sends frames)
        let a0 = sender(la)!
        XCTAssertGreaterThan(a0.tiles, 0)

        XCTAssertEqual(rfmc_claim(b, 300, &c), 1)
        XCTAssertEqual(c.waited, 1)
        XCTAssertEqual(c.acked, 1, "A's session thread did not ack within 300 ms")
        print("takeover A -> B: A acked in \(c.wait_ms) ms")
        XCTAssertTrue(until(5) { Int(self.linkState(b).state) == RFMC_CONNECTED }, "B never connected")
        XCTAssertEqual(lastStarter(), lb)
        Thread.sleep(forTimeInterval: 0.5)
        var sa = linkState(a)
        XCTAssertEqual(sa.drops, 1)
        XCTAssertEqual(Int(sa.state), RFMC_IN_USE)
        XCTAssertEqual(sa.wanted, 0, "A's link still wants the unit")
        let a1 = sender(la)!
        XCTAssertEqual(a1.stops, 0, "A sent SESSION 0")
        XCTAssertEqual(a1.after_other, 0, "A sent \(a1.after_other) messages after B's session started")
        XCTAssertGreaterThan(sender(lb)!.tiles, 0)

        // and back: B yields the same way
        XCTAssertEqual(rfmc_claim(a, 300, &c), 1)
        XCTAssertEqual(c.acked, 1)
        XCTAssertTrue(until(5) { Int(self.linkState(a).state) == RFMC_CONNECTED }, "A never reconnected")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(lastStarter(), la)
        let b1 = sender(lb)!
        XCTAssertEqual(b1.stops, 0, "B sent SESSION 0")
        XCTAssertEqual(b1.after_other, 0)
        XCTAssertEqual(linkState(b).drops, 1)

        // the owner's own stop does send SESSION 0 (the counter works)
        rfmc_stop(a)
        XCTAssertTrue(until(2) { (self.sender(la)?.stops ?? 0) == 1 })
        sa = linkState(a)
        XCTAssertEqual(sa.drops, 1, "a plain stop counted as a drop")
    }

    // MARK: PanelSession's rules

    private func session(_ label: String, _ id: UUID = UUID(), settle: Double = 0.3) -> (PanelSession, OpaquePointer) {
        var cfg = PanelSession.Config()
        cfg.leasePath = dir.appendingPathComponent("lease.bin")
        cfg.notifyName = note
        cfg.staleMs = 1500                         // (the heartbeat comes every second)
        cfg.settle = settle
        cfg.fake = true
        let l = link(label)
        return (PanelSession(link: l, identity: id, name: "\(label) / ChoralRoot", config: cfg), l)
    }

    func testSessionRules() {
        let tag = UUID().uuidString.prefix(6)
        // (b) a new instance with an empty lease claims after the settle delay
        let (p1, _) = session("P1-\(tag)")
        p1.appeared()
        XCTAssertFalse(p1.status().owner, "claimed before the settle delay")
        XCTAssertTrue(until(3) { p1.status().owner && p1.status().link.isConnected }, "P1 did not auto-claim")
        XCTAssertEqual(p1.status().autoClaims, 1)

        // (c) a second new instance waits: the owner is fresh
        let (p2, _) = session("P2-\(tag)")
        p2.appeared()
        Thread.sleep(forTimeInterval: 0.8)
        var s2 = p2.status()
        XCTAssertFalse(s2.owner)
        XCTAssertTrue(s2.heldElsewhere)
        XCTAssertEqual(s2.ownerName, "P1-\(tag) / ChoralRoot")
        XCTAssertEqual(s2.line, "Panel in use by P1-\(tag) / ChoralRoot")

        // the tap: P2 takes it, P1 yields
        p2.claim()
        XCTAssertTrue(until(3) { p2.status().owner && p2.status().link.isConnected })
        s2 = p2.status()
        XCTAssertTrue(s2.lastClaimWaited)
        XCTAssertTrue(s2.lastClaimAcked)
        XCTAssertTrue(until(1) { p1.status().drops == 1 })
        XCTAssertFalse(p1.status().owner)
        XCTAssertTrue(p1.status().heldElsewhere)

        // a duplicated state (P2's UUID, P2 alive in this process): a new UUID, no automatic claim
        let (p3, _) = session("P3-\(tag)")
        let got = p3.restore(p2.identity)
        XCTAssertNotEqual(got, p2.identity)
        XCTAssertEqual(p3.identity, got)
        XCTAssertTrue(p3.status().duplicate)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(p3.status().owner)
        XCTAssertEqual(p3.status().claims, 0)

        // the owner goes away (deallocated): pid 0, owner field kept; restoring its UUID reclaims at once (a)
        let ownerID = p2.identity
        p2.finish()
        XCTAssertTrue(until(2) { p1.leaseView()?.pid == 0 })
        let (p4, _) = session("P4-\(tag)", settle: 5)
        XCTAssertEqual(p4.restore(ownerID), ownerID)
        XCTAssertFalse(p4.status().duplicate)
        XCTAssertTrue(until(2) { p4.status().owner }, "the restored owner UUID did not reclaim at once")
        XCTAssertTrue(until(3) { p4.status().link.isConnected })

        // P4 gone too: stale after staleMs; a running instance (P1, P3) never grabs it; a new one does after settling
        p4.finish()
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(p1.status().ownerStale)
        XCTAssertFalse(p1.status().owner)
        XCTAssertFalse(p3.status().owner)
        XCTAssertEqual(p1.status().claims, 1)
        let (p5, _) = session("P5-\(tag)")
        p5.appeared()
        XCTAssertTrue(until(3) { p5.status().owner }, "a new instance did not take a stale lease")
        XCTAssertEqual(p5.status().autoClaims, 1)
        for p in [p1, p3, p5] { p.finish() }
    }
}

private struct LeaseRef: @unchecked Sendable { let p: OpaquePointer }
