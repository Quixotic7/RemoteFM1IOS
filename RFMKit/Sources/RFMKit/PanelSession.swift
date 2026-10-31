// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// PanelSession (M4): PLAN.md section 4's rules for one owner of a RemoteLink (an AUv3 instance, or the standalone
// app), over RFMCore's lease (RFMLease.h) and the link's gate (rfmc_set_lease). The mechanics are in C++: the session
// thread checks the epoch before it sends, heartbeats while its link runs, and on a newer epoch drops (no SESSION 0)
// and acks. Here: when to claim.
//
//   tap ("Use this FM-1")  claim: epoch + 1, up to 300 ms for the old owner's ack, then the link starts
//   restored identity      (a) the lease's owner is this UUID: claim at once
//                          duplicate: another live instance in this process has the UUID, or another live process
//                          holds the lease under it with a fresh heartbeat: a new UUID, and no automatic claim
//   created or restored    (b) otherwise, after a settle delay (2 s), claim only if the lease is empty or stale
//                          (re-checked then); (c) else wait for a tap. A running instance never claims by itself.
//   gone                   the heartbeat stops; the owner field stays (pid 0), so a reload reconnects; others see
//                          it stale after 3 s
//   a firmware install     hold(as:): the link stopped, the lease claimed and heartbeaten with no session, no
//                          automatic claim; endHold(restart:) claims again (Install/FirmwareInstaller.swift)
//
// The policy runs on a private serial queue; the claim blocks that queue (up to the ack wait), never the main thread.

import Foundation
import RFMCore

public struct PanelStatus: Sendable, Equatable {
    public var owner = false                // this instance holds the lease (its link may run)
    public var ownerName = ""               // the lease's owner (anyone's), "" none
    public var ownerIsSelf = false          // the owner field is this identity
    public var leaseEmpty = true
    public var ownerStale = true
    public var ownerAgeMs: Int64 = 0
    public var ownerPid: Int32 = 0
    public var epoch: UInt64 = 0
    public var link: LinkState = .stopped("")
    public var linkText = ""
    public var touchText = "–"              // TOUCH: the firmware's cap, what was asked, what PANEL_R confirms
    public var linkRunning = false
    public var drops: UInt32 = 0
    public var gateBlocked: UInt32 = 0
    public var duplicate = false            // the restored UUID was taken: this instance has a new one
    public var autoClaims = 0, claims = 0
    public var lastClaimWaited = false, lastClaimAcked = false
    public var lastClaimWaitMs: UInt32 = 0
    public var leaseWarning: String?        // no App Group: the lease is this process's own
    public var foreignSession = false       // the FM-1 had a session when found, and nobody here held it before
    public var notifications: UInt32 = 0
    public var hello: UnitHello?
    public var hasUnit = true               // (device backend) an FM-1 candidate is in CoreMIDI's list
    public var fake = false                 // the link's unit is a fake (tests, the simulator)

    public init() {}

    /// the panel line for a view
    public var line: String {
        if owner {
            switch link {
            case .connected(let ble): return "Panel: connected over \(ble ? "Bluetooth" : "USB")\(fake ? " (fake)" : "")"
            case .notFound: return "Panel: FM-1 not found"
            case .starting: return "Panel: starting…"
            case .lost: return "Panel: unit lost, searching…"
            case .error(let t): return "Panel: error (\(t))"
            case .stopping: return "Panel: stopping…"
            case .inUse: return "Panel: in use by another instance"
            case .stopped: return linkRunning ? "Panel: searching…" : "Panel: off"
            case .searching: return "Panel: searching for the FM-1…"
            }
        }
        if !leaseEmpty && !ownerStale && !ownerName.isEmpty { return "Panel in use by \(ownerName)" }
        if !leaseEmpty && !ownerStale { return "Panel in use by another instance" }
        return "Panel: not connected"
    }

    /// another instance (fresh) holds the unit
    public var heldElsewhere: Bool { !owner && !leaseEmpty && !ownerStale }
}

public final class PanelSession: @unchecked Sendable {
    public struct Config: Sendable {
        public var leasePath: URL?                  // nil: RFMShared.leaseLocation()
        public var notifyName = RFMShared.leaseNotification
        public var staleMs: UInt32 = 3000
        public var settle: TimeInterval = 2
        public var claimWaitMs: UInt32 = 300
        public var fake = false                     // the link's backend is a fake unit (there is always a "unit")
        public init() {}
    }

    public let link: OpaquePointer                  // rfmc_t (the caller's; it frees it through finish)
    public let config: Config
    public let leaseWarning: String?
    public let leasePath: String
    let lease: OpaquePointer?                       // rfml_t
    private let q = DispatchQueue(label: "com.quixotic7.remotefm1.panel")
    private let lock = NSLock()
    private var identity_: UUID
    private var name_: String
    private var autoAllowed = true
    private var autoGen = 0
    private var duplicate = false
    private var autoClaims = 0, claims = 0
    private var lastClaim = rfml_claim_t()
    private var tookOverLive = false
    private var searchingSince: Date?
    private var hasUnitCache = (Date.distantPast, true)
    private var finished = false
    private var hold: DispatchSourceTimer?          // (a firmware install) the lease held with the link stopped
    private let log = RFMShared.log("panel")

    // the identities of the live sessions in this process (duplicate detection)
    private static let regLock = NSLock()
    nonisolated(unsafe) private static var registry: [UUID: Int] = [:]

    public init(link: OpaquePointer, identity: UUID, name: String, config: Config = Config()) {
        self.link = link
        self.config = config
        identity_ = identity
        name_ = name
        let loc = config.leasePath.map { (url: $0, shared: true) } ?? RFMShared.leaseLocation()
        leasePath = loc.url.path
        leaseWarning = loc.shared ? nil : "No App Group: this panel is not shared with the app or other hosts."
        var err: Int32 = 0
        lease = loc.url.path.withCString { p in config.notifyName.withCString { n in rfml_open(p, n, &err) } }
        if let lease {
            rfml_set_stale_ms(lease, config.staleMs)
            Self.setIdentity(lease, identity, name)
            rfmc_set_lease(link, lease)
        } else {
            log.error("lease: cannot open \(loc.url.path, privacy: .public): errno \(err)")
        }
        Self.register(identity)
    }

    deinit {
        hold?.cancel()
        if !finished, let lease {               // (finish not called: let go of the lease here)
            rfmc_set_lease(link, nil)
            rfml_close(lease)
        }
    }

    /// The owner is going away: the heartbeat stops (its link is freed), the owner field stays with pid 0. Frees the
    /// link (a stop waits up to ~600 ms) and then the lease on a background queue. Call after anything else using
    /// the link (the engine) is gone.
    public func finish() {
        lock.lock()
        let first = !finished
        finished = true
        let id = identity_
        hold?.cancel()                          // (an install's heartbeat: the lease is closed below)
        hold = nil
        lock.unlock()
        guard first else { return }
        Self.unregister(id)
        let ref = Refs(link: link, lease: lease)
        let q = q
        DispatchQueue.global(qos: .utility).async {
            q.sync {}                           // (a heartbeat under way ends first)
            if let l = ref.lease { rfml_detach(l) }
            rfmc_free(ref.link)
            if let l = ref.lease { rfml_close(l) }
        }
    }

    public var identity: UUID { lock.withLock { identity_ } }

    public func setName(_ name: String) {
        lock.withLock { name_ = name }
        if let lease { rfml_set_name(lease, name) }
    }

    // MARK: the rules

    /// A new instance (or the app at launch): one check after the settle delay (rule b). For the app, whose UUID
    /// persists, rule (a) applies first.
    public func appeared() {
        if let v = leaseView(), v.owner_is_me != 0, !v.heldByOtherProcess {
            claim(auto: true, why: "this instance is the lease's owner")
            return
        }
        scheduleAutoCheck()
    }

    /// A restored identity (fullState). Returns the UUID the instance now has: `uuid`, or a new one if it is a
    /// duplicate.
    @discardableResult
    public func restore(_ uuid: UUID) -> UUID {
        let v = leaseView()
        let inProcess = Self.count(uuid) - (identity == uuid ? 1 : 0) > 0
        var elsewhere = false
        if let v, Self.uuid(v) == uuid, v.pid != 0, v.pid != getpid(), v.stale == 0, Self.alive(v.pid) {
            elsewhere = true
        }
        let old = identity
        if inProcess || elsewhere {
            let fresh = UUID()
            lock.withLock {
                identity_ = fresh
                duplicate = true
                autoAllowed = false
                autoGen += 1
            }
            if let lease { Self.setIdentity(lease, fresh, lock.withLock { name_ }) }
            Self.reidentify(old, fresh)
            log.info("restored \(uuid.uuidString.prefix(8), privacy: .public) is a duplicate (\(inProcess ? "in this process" : "held by pid \(v?.pid ?? 0)", privacy: .public)): now \(fresh.uuidString.prefix(8), privacy: .public)")
            return fresh
        }
        lock.withLock {
            identity_ = uuid
            duplicate = false
            autoAllowed = true
        }
        if let lease { Self.setIdentity(lease, uuid, lock.withLock { name_ }) }
        Self.reidentify(old, uuid)
        if let v, Self.uuid(v) == uuid {
            claim(auto: true, why: "restored as the lease's owner")
        } else {
            scheduleAutoCheck()
        }
        return uuid
    }

    /// "Use this FM-1": the claim, then the link (on the private queue). done(true): claimed and started.
    public func claim(done: (@Sendable (Bool) -> Void)? = nil) { claim(auto: false, why: "tap", done: done) }

    /// An explicit disconnect by the owner: the link stopped (SESSION 0), the lease marked stale at once.
    public func release() {
        rfmc_stop(link)
        if let lease { rfml_release(lease) }
    }

    private func claim(auto: Bool, why: String, done: (@Sendable (Bool) -> Void)? = nil) {
        if auto && lock.withLock({ hold != nil }) { done?(false); return }   // (an install holds the FM-1)
        lock.withLock { autoGen += 1 }              // (a claim settles any pending check)
        let ref = Refs(link: link, lease: lease)
        let wait = config.claimWaitMs
        q.async { [weak self] in
            var c = rfml_claim_t()
            let prev = self?.leaseView()
            let ok = rfmc_claim(ref.link, wait, &c) != 0
            guard let self else { done?(ok); return }
            self.lock.withLock {
                self.lastClaim = c
                self.claims += 1
                if auto { self.autoClaims += 1 }
                // (the unit may still hold the previous owner's session for its keepalive)
                self.tookOverLive = prev.map { $0.empty == 0 && $0.heartbeat_ms != 0 && $0.age_ms < 6000 } ?? false
            }
            self.log.info("claim (\(why, privacy: .public)): epoch \(c.epoch), waited \(c.waited) acked \(c.acked) in \(c.wait_ms) ms, started \(ok)")
            done?(ok)
        }
    }

    // MARK: a firmware install (Install/): the FM-1 held with no session

    /// Stops the link (SESSION 0 if it ran) and takes the lease as "Use this FM-1" does (another owner drops and closes
    /// its CoreMIDI links), but starts no session: the lease is heartbeaten here, under `name`, until endHold(), so
    /// other instances see the FM-1 in use and none claims it. Automatic claims wait meanwhile. done: claimed.
    public func hold(as name: String, done: (@Sendable (Bool) -> Void)? = nil) {
        let ref = Refs(link: link, lease: lease)
        let wait = config.claimWaitMs
        lock.withLock { autoGen += 1 }
        q.async { [weak self] in
            rfmc_stop(ref.link)
            guard let self, let l = ref.lease else { done?(false); return }
            var c = rfml_claim_t()
            let ok = rfml_claim(l, wait, &c) != 0
            rfml_set_name(l, name)
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now(), repeating: .milliseconds(500))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.withLock { if self.hold != nil && !self.finished { rfml_heartbeat(l) } }
            }
            self.lock.withLock {
                self.hold?.cancel()
                self.hold = t
            }
            t.resume()
            self.log.info("hold for an install: epoch \(c.epoch), waited \(c.waited) acked \(c.acked) in \(c.wait_ms) ms")
            done?(ok)
        }
    }

    /// The install is over: the heartbeat stops, the name is the instance's again; restart: claim and start the link
    /// (the lease is still this instance's, so nobody is waited for), else release the lease.
    public func endHold(restart: Bool) {
        let t: DispatchSourceTimer? = lock.withLock {
            defer { hold = nil }
            return hold
        }
        t?.cancel()
        if let lease { rfml_set_name(lease, lock.withLock { name_ }) }
        if restart { claim(auto: false, why: "after an install") } else if let lease { rfml_release(lease) }
    }

    public var holding: Bool { lock.withLock { hold != nil } }

    private func scheduleAutoCheck() {
        let gen = lock.withLock { () -> Int in
            autoGen += 1
            return autoGen
        }
        q.asyncAfter(deadline: .now() + config.settle) { [weak self] in
            guard let self else { return }
            let go = self.lock.withLock { self.autoGen == gen && self.autoAllowed && !self.finished }
            guard go, let v = self.leaseView() else { return }
            if v.mine == 0 && (v.empty != 0 || v.stale != 0) {
                self.claim(auto: true, why: v.empty != 0 ? "the lease is empty" : "the owner is stale")
            }
        }
    }

    // MARK: status

    public func status() -> PanelStatus {
        var p = PanelStatus()
        p.leaseWarning = leaseWarning
        p.fake = config.fake
        if let v = leaseView() {
            p.owner = v.mine != 0
            p.ownerName = RemoteController.string(v.name)
            p.ownerIsSelf = v.owner_is_me != 0
            p.leaseEmpty = v.empty != 0
            p.ownerStale = v.stale != 0
            p.ownerAgeMs = v.age_ms
            p.ownerPid = v.pid
            p.epoch = v.epoch
            p.notifications = rfml_notifications(lease!)
        }
        var st = rfmc_status_t()
        rfmc_status(link, &st)
        lock.lock()
        p.link = RemoteController.state(of: st, searchingSince: &searchingSince)
        p.duplicate = duplicate
        p.autoClaims = autoClaims
        p.claims = claims
        p.lastClaimWaited = lastClaim.waited != 0
        p.lastClaimAcked = lastClaim.acked != 0
        p.lastClaimWaitMs = lastClaim.wait_ms
        let took = tookOverLive
        lock.unlock()
        p.linkText = RemoteController.string(st.text)
        p.linkRunning = st.wanted != 0
        p.drops = st.drops
        p.gateBlocked = st.gate_blocked
        p.touchText = LinkStats.touchText(caps: st.have_hello != 0 ? st.caps : nil, wanted: st.touch_wanted,
                                          inForce: st.touch, sent: st.touch_sent)
        if st.have_hello != 0 {
            let h = RemoteController.hello(of: st)
            p.hello = h
            // HELLO_R's session flag when this link found the unit, and nobody here held it in the last 6 s
            p.foreignSession = p.owner && h.session && !took
        }
        if !config.fake { p.hasUnit = hasUnit() }   // (also while owner: an FM-1 that doesn't answer, the AU's card)
        return p
    }

    /// an FM-1 candidate in CoreMIDI's endpoint list (read-only; every 2 s at most)
    private func hasUnit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(hasUnitCache.0) < 2 { return hasUnitCache.1 }
        var c = [rfmp_candidate_t](repeating: rfmp_candidate_t(), count: 8)
        let n = rfmp_midi_candidates(&c, 8)
        hasUnitCache = (Date(), n > 0)
        return n > 0
    }

    func leaseView() -> rfml_view_t? {
        guard let lease else { return nil }
        var v = rfml_view_t()
        rfml_view(lease, &v)
        return v
    }

    // MARK: helpers

    private struct Refs: @unchecked Sendable { let link: OpaquePointer; let lease: OpaquePointer? }

    static func setIdentity(_ l: OpaquePointer, _ u: UUID, _ name: String) {
        withUnsafeBytes(of: u.uuid) { b in
            name.withCString { rfml_set_identity(l, b.bindMemory(to: UInt8.self).baseAddress, $0) }
        }
    }

    static func uuid(_ v: rfml_view_t) -> UUID {
        withUnsafeBytes(of: v.owner) { b in
            UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        }
    }

    /// kill(pid, 0): ESRCH only when the process is gone (EPERM: alive, someone else's)
    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

    private static func register(_ u: UUID) { regLock.withLock { registry[u, default: 0] += 1 } }
    private static func unregister(_ u: UUID) {
        regLock.withLock {
            if let n = registry[u] { registry[u] = n > 1 ? n - 1 : nil }
        }
    }
    private static func reidentify(_ old: UUID, _ new: UUID) {
        guard old != new else { return }
        unregister(old)
        register(new)
    }
    static func count(_ u: UUID) -> Int { regLock.withLock { registry[u] ?? 0 } }
}

private extension rfml_view_t {
    /// (the app's rule a) the owner field is ours but another live process heartbeats under it: not ours to take
    var heldByOtherProcess: Bool {
        pid != 0 && pid != getpid() && stale == 0 && PanelSession.alive(pid)
    }
}
