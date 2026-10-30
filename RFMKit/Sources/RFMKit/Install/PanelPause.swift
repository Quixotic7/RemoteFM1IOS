// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// The app's link lets go of the FM-1 for a firmware install. Stopping the link ends its session (SESSION 0) and closes
// its CoreMIDI connections to the FM-1 (RemoteLink's run ends; the MIDI setup watcher only listens). With a lease
// (PanelSession) the FM-1 is also taken from whoever holds it, as "Use this FM-1" does: an AU instance in another app
// drops at once, closes its links and shows "Panel in use by RemoteFM1 app / installing firmware" until it is tapped
// again; while the install runs the lease stays the app's (heartbeaten, no session), so no instance starts one.
// Afterwards the link claims the FM-1 again and starts, if it was running. ControllerInput never connects the FM-1
// (and drops SysEx), the OMX-27's link talks only to the OMX-27.

import Foundation
import RFMCore

extension RemoteController: PanelLinkPausing {
    public var panelHolder: String? {
        guard let p = panel, p.heldElsewhere else { return nil }
        return p.ownerName
    }

    public var unitHello: UnitHello? { hello }

    public func pauseForInstall() async -> Bool {
        let wasRunning = isRunning
        if let session {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                session.hold(as: "RemoteFM1 app / installing firmware") { _ in k.resume() }
            }
        } else if let core {
            rfmc_stop(core)
        }
        refresh()
        return wasRunning
    }

    public func resumeAfterInstall(restart: Bool) {
        if let session {
            session.endHold(restart: restart)
        } else if restart, let core {
            rfmc_start(core)
        }
        refresh()
        rescan()                                // (the FM-1 came back with new CoreMIDI endpoints)
    }
}
