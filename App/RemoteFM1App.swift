// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RemoteFM1 for iPhone and iPad (M1): an FM-1 running RemoteFM1 firmware as a panel, with a test pattern and no core.
// Launch arguments: -fake runs against libremotefm1's fake unit in the app, -fakeble the fake over Bluetooth.
// The simulator uses the fake unless launched with -device (its CoreMIDI may see the Mac's MIDI devices).

import RFMKit
import SwiftUI

@main
struct RemoteFM1App: App {
    @State private var controller: RemoteController

    init() {
        let backend = Self.backend(ProcessInfo.processInfo.arguments)
        _controller = State(initialValue: RemoteController(backend: backend, demoInput: backend.isFake))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .preferredColorScheme(.dark)
        }
    }

    static func backend(_ args: [String]) -> Backend {
        if args.contains("-fakeble") { return .fake(bluetooth: true) }
        if args.contains("-fake") { return .fake(bluetooth: false) }
        #if targetEnvironment(simulator)
        if !args.contains("-device") { return .fake(bluetooth: false) }
        #endif
        return .device
    }
}
