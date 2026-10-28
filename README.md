# RemoteFM1 for iOS

An iPhone and iPad host for FM-1 firmware cores, with a real M-VAVE FM-1 running RemoteFM1 firmware 0.2.2 as the
panel. See [PLAN.md](PLAN.md) for the design and the milestones.

Status: M1. The app finds the FM-1 over CoreMIDI (Bluetooth MIDI or USB, SysEx only), runs a session and sends a test
pattern. Keys and buttons held on the FM-1 light their LEDs and show in a strip at the bottom of its screen. No cores
and no sound yet.

## Layout

- `App/`: the SwiftUI app (one screen).
- `RemoteFM1.xcodeproj`: the app target; it uses `RFMKit` as a local package.
- `RFMKit/`: a Swift package.
  - `CRemoteFM1`: libremotefm1 (RemoteFM1 v0.2.2), its macOS glue `host.c` and FM1VST's CoreMIDI back end
    `RemoteMidi.c`, compiled in place from `vendor/` through the `RFMKit/vendor` symlink. Built with `RFM_NO_LIBUSB`.
  - `RFMCore`: a copy of FM1VST's `RemoteLink` (its header says what changed), fm1remote's test patterns, and a C API
    for Swift.
  - `RFMKit`: `RemoteController`, the Swift API the app uses.
- `vendor/FM1VST`: FM1VST v0.6.2 as a git submodule (only `remote/RemoteFM1` is needed so far). Read-only.

## Build

    git submodule update --init vendor/FM1VST
    git -C vendor/FM1VST submodule update --init remote/RemoteFM1

    xcodebuild -project RemoteFM1.xcodeproj -scheme RemoteFM1 -destination 'generic/platform=iOS Simulator' build
    xcodebuild -project RemoteFM1.xcodeproj -scheme RemoteFM1 -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

To install on a device, set the team in the target's Signing settings.

## Test

    cd RFMKit && swift test

The tests run on the Mac against libremotefm1's fake unit only; nothing touches CoreMIDI or a real FM-1.

libremotefm1's own tests, built outside the source tree:

    cmake -S vendor/FM1VST/remote/RemoteFM1/host -B /tmp/rfm-host -DRFM_SANITIZE=ON -DCMAKE_BUILD_TYPE=Debug
    cmake --build /tmp/rfm-host -j 8 && (cd /tmp/rfm-host && ASAN_OPTIONS=detect_leaks=0 ctest --output-on-failure)

## Launch arguments

- `-fake`: the fake unit inside the app (it also presses keys by itself, so the panel path shows).
- `-fakeble`: the fake unit over Bluetooth (paced, lossy tiles, HOLD).
- `-device`: in the simulator, use CoreMIDI (the simulator uses the fake otherwise, as its CoreMIDI may see the
  Mac's MIDI devices). On a device CoreMIDI is the default.

## Licence

GPL-3.0-only (`LICENSE`).
