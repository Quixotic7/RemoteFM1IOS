# RemoteFM1 for iOS

An iPhone and iPad host for FM-1 firmware cores, with a real M-VAVE FM-1 running RemoteFM1 firmware 0.2.2 as the
panel. See [PLAN.md](PLAN.md) for the design and the milestones.

Status: M1, and M2 on the simulator. The app finds the FM-1 over CoreMIDI (Bluetooth MIDI or USB, SysEx only), runs a
session and sends a test pattern. Keys and buttons held on the FM-1 light their LEDs and show in a strip at the bottom
of its screen. M2 adds the AUv3 instrument as a skeleton (renders silence) and probes for PLAN.md section 5. No cores
and no sound yet.

## Layout

- `App/`: the SwiftUI app (one screen), and the AU test (`AUTestHost`, `AUTestView`): the app as a small AUv3 host for
  its own extension.
- `AU/`: the AUv3 extension `RemoteFM1AU` (aumu `Rfm1` `Qx7u`, "Quixotic7: RemoteFM1"): its view controller, which is
  also the AU factory, and its SwiftUI view (instance, Bluetooth button, Diagnostics).
- `RemoteFM1.xcodeproj`: the app and extension targets; both use `RFMKit` as a local package and share the App Group
  `group.com.quixotic7.remotefm1`.
- `RFMKit/`: a Swift package.
  - `CRemoteFM1`: libremotefm1 (RemoteFM1 v0.2.2), its macOS glue `host.c` and FM1VST's CoreMIDI back end
    `RemoteMidi.c`, compiled in place from `vendor/` through the `RFMKit/vendor` symlink. Built with `RFM_NO_LIBUSB`.
  - `RFMCore`: a copy of FM1VST's `RemoteLink` (its header says what changed), fm1remote's test patterns, and a C API
    for Swift; the AU's render kernel (`RFMKernel`, an Objective-C++ render block over plain C++) and the probes' C
    parts (`RFMProbe`: CoreMIDI candidates, an mmap'd shared file, Darwin notifications, notify state, memory).
  - `RFMKit`: `RemoteController`, the Swift API the app uses; `AUv3/`: the audio unit (`RFMAudioUnit`), its state
    (`InstanceState`) and the probes (`Probe`, `ProbeReport`); `UI/`: the Bluetooth panel and the Diagnostics view.
- `vendor/FM1VST`: FM1VST v0.6.2 as a git submodule (only `remote/RemoteFM1` is needed so far). Read-only.

## Build

    git submodule update --init vendor/FM1VST
    git -C vendor/FM1VST submodule update --init remote/RemoteFM1

    xcodebuild -project RemoteFM1.xcodeproj -scheme RemoteFM1 -destination 'generic/platform=iOS Simulator' build
    xcodebuild -project RemoteFM1.xcodeproj -scheme RemoteFM1 -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

To install on a device, set the team in the target's Signing settings.

## Test

    cd RFMKit && swift test

The tests run on the Mac against libremotefm1's fake unit only; nothing touches CoreMIDI or a real FM-1. They also
cover the AU's state and render block and the probes' shared file and notifications within one process.

The AU test on a simulator, headless (Simulator.app stays closed):

    scripts/sim_autest.sh [UDID]

It builds, boots the simulator if needed, installs, launches with `-autest`, prints the summary, saves `autest.json`,
the log and two screenshots under `$OUT` (default `$TMPDIR/remotefm1-autest`), and shuts down a simulator it booted.

libremotefm1's own tests, built outside the source tree:

    cmake -S vendor/FM1VST/remote/RemoteFM1/host -B /tmp/rfm-host -DRFM_SANITIZE=ON -DCMAKE_BUILD_TYPE=Debug
    cmake --build /tmp/rfm-host -j 8 && (cd /tmp/rfm-host && ASAN_OPTIONS=detect_leaks=0 ctest --output-on-failure)

## Launch arguments

- `-fake`: the fake unit inside the app (it also presses keys by itself, so the panel path shows).
- `-fakeble`: the fake unit over Bluetooth (paced, lossy tiles, HOLD).
- `-autest`: only the AU test, run at launch (the FM-1 link is never created). Its summary goes to `autest.json` in the
  app's Documents and the App Group container. On a device, the "AU test" button runs the same thing.
- `-device`: in the simulator, use CoreMIDI (the simulator uses the fake otherwise, as its CoreMIDI may see the
  Mac's MIDI devices). On a device CoreMIDI is the default.

## Licence

GPL-3.0-only (`LICENSE`).
