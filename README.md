# RemoteFM1 for iOS

An iPhone and iPad host for FM-1 firmware cores, with a real M-VAVE FM-1 running RemoteFM1 firmware 0.2.2 as the
panel. See [PLAN.md](PLAN.md) for the design and the milestones.

Status: M1, and M2, M3 and M4 on the simulator. The app finds the FM-1 over CoreMIDI (Bluetooth MIDI or USB,
SysEx only) and runs a session. In Pattern mode it sends M1's test pattern. In Core mode it runs a real firmware
(ChoralRoot 0.26.1, Felucca 1.6.1, Melodee 1.4.5, FIZZ 0.12.0-beta.12 or Saadet 0.1.1) with the FM-1 as its panel and the sound on the iOS device; the
firmware's flash is kept in `Documents/cores/<id>.bin`. M2 adds the AUv3 instrument as a skeleton (renders silence)
and probes for PLAN.md section 5. M4: the AUv3 instrument plays a core (host MIDI in, the core's MIDI out, the flash
in `fullState`), and its instances and the app share one FM-1 through the lease of PLAN.md section 4 ("Use this
FM-1"). Not yet tried on a real FM-1, iPhone or third-party host.

The UI is the owner's design (`design/README.md`, `design/canvas`): the screen is an on-screen FM-1 (M5's "LCD mirror and
touch keys"), the same in the app and the AUv3. Three views, swiped sideways: **Full** (the hardware's arrangement:
iPhone portrait with a scrolling keybed, iPhone landscape, iPad landscape and portrait, picked from the view's size),
**Controls** (a big display, a knob row MAIN | KN 1–4, a BUTTONS | KEYS deck) and **Screen**. Touches go into the core
the way the FM-1's events do; the core's screen, LEDs and knob turns come back through a lock-free snapshot
(`rfme_panel`). The grabber opens the pull-down sheet: Sound source (This iPhone: the emulator, no link; FM-1: the link
and the lease, "Use this FM-1", Bluetooth), View, Theme (five presets from `design/tokens.json`, an editor, a custom
theme shared with the AU through the App Group), Firmware, MIDI & audio, Settings (Diagnostics: the former debug
screen, the test pattern and the AU test).

## Layout

- `App/`: the SwiftUI app (`MainScreen`: the faceplate and its sheet; `DiagnosticsScreen`), and the AU tests (`AUTestHost`, `AUTestView`; M4's `AUCoreTest`): the app as
  a small AUv3 host for its own extension.
- `AU/`: the AUv3 extension `RemoteFM1AU` (aumu `Rfm1` `Qx7u`, "Quixotic7: RemoteFM1"): its view controller, which is
  also the AU factory, and its SwiftUI view (the faceplate; its sheet: Use this FM-1, Bluetooth, view, theme,
  firmware and About, MIDI octave, Diagnostics).
- `RemoteFM1.xcodeproj`: the app and extension targets; both use `RFMKit` as a local package and share the App Group
  `group.com.quixotic7.remotefm1`. The app's "Embed core slots" phase (`scripts/embed_cores.sh`) builds the cores if
  needed and puts their slot frameworks in `RemoteFM1.app/Frameworks`, signed.
- `cores/`: the CMake project for the cores (FM1VST's `fm1_add_core` and the cores' glue, without JUCE),
  `cores/fizz/` (FIZZ's build file and descriptor), `cores/saadet/` (Saadet's: its unit on FM1VST's fm1-base glue,
  the instrument unit, descriptors, the conformance script, and `store/`: the empty factory banks of its store
  variant), `cores/store-cores.txt` (the cores of an App Store / TestFlight
  build: `RFM_STORE_BUILD=YES`), and `cores/ios/libproc.h`, a stand-in for a header the iOS SDK lacks (ChoralRoot's
  profiler).
- `RFMKit/`: a Swift package.
  - `CRemoteFM1`: libremotefm1 (RemoteFM1 v0.2.2), its macOS glue `host.c` and FM1VST's CoreMIDI back end
    `RemoteMidi.c`, compiled in place from `vendor/` through the `RFMKit/vendor` symlink. Built with `RFM_NO_LIBUSB`.
  - `RFMCore`: a copy of FM1VST's `RemoteLink` (its header says what changed), fm1remote's test patterns, and a C API
    for Swift; the AU's render kernel (`RFMKernel`, an Objective-C++ render block over plain C++) and the probes' C
    parts (`RFMProbe`: CoreMIDI candidates, an mmap'd shared file, Darwin notifications, notify state, memory).
    M3: the slot loader (`RFMSlots`, `rfms_*`) and the core engine (`RFMEngine`, `rfme_*`: FM1VST's Device on one
    clock thread, fm1remote's design), its AVAudioSourceNode, and FM1VST's `engine/device.cpp` compiled in place.
    M4: the lease (`RFMLease`, `rfml_*`), RemoteLink's gate and drop path (`rfmc_set_lease`, `rfmc_claim`), and the
    process-wide shared fake unit (`SharedFake`, tests).
  - `RFMKit`: `RemoteController`, the Swift API the app uses; `CorePlayer` (the core, its audio and its flash);
    `PanelSession` (M4: when to claim the FM-1); `Faceplate/`: the on-screen FM-1 (the theme and its tokens, the
    fonts, the layouts, the keybed's geometry, `PanelFeed`: touches in, LEDs and the screen out; the parts, the views,
    the sheet, the theme editor); `Resources/`: the four OFL fonts and a copy of `design/tokens.json`; `AUv3/`: the audio unit (`RFMAudioUnit`), its state (`InstanceState`,
    `CoreState`) and the probes (`Probe`, `ProbeReport`); `UI/`: the Bluetooth panel, About this firmware and the
    Diagnostics view.
- `vendor/FM1VST`: FM1VST v0.6.2 as a git submodule (`remote/RemoteFM1` and `cores/ChoralRootFM1`, `cores/Felucca`
  with its `firmware/engines`, `cores/melodee`). Read-only.
- `vendor/FIZZ`: FIZZ v0.12.0-beta.12 (MPL-2.0) as a git submodule (its own submodule, fm1-base, is not needed).
  Read-only.
- `vendor/saadet`: Saadet v0.1.1 (Kerem Kilic; MPL-2.0 in its fm1-base build) and `vendor/fm1-base`: fm1-base at
  Saadet's pin (6c0b47e, which Saadet's build fetches; its `bsp/` is not needed). Read-only.

## Build

    git submodule update --init vendor/FM1VST vendor/FIZZ vendor/saadet vendor/fm1-base
    git -C vendor/FM1VST submodule update --init remote/RemoteFM1 cores/ChoralRootFM1 cores/melodee
    git -C vendor/FM1VST submodule update --init --recursive cores/Felucca

The cores need CMake and a python3 with Pillow and fontTools (`CR_PYTHON=...`; the default is python.org's 3.11):

    scripts/build_cores.sh [ios] [sim] [macos]      # default: all three, into build/cores/<platform>

Each core becomes `FM1Core_<id>_1..4.framework` (PLAN.md section 3). The build runs on a copy of the needed parts of
`vendor/FM1VST` in `build/cores/src`, because the cores' generators write into their own tree. The app build runs it
for its platform by itself; `macos` is for the Mac tests.

    xcodebuild -project RemoteFM1.xcodeproj -scheme RemoteFM1 -destination 'generic/platform=iOS Simulator' build
    xcodebuild -project RemoteFM1.xcodeproj -scheme RemoteFM1 -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

To install on a device, set the team in the target's Signing settings. `RFM_STORE_BUILD=YES` (on the xcodebuild line,
as `scripts/testflight.sh` does) embeds only the cores in `cores/store-cores.txt`; the default embeds all of them.

## Test

    cd RFMKit && swift test

The tests run on the Mac against libremotefm1's fake unit only; nothing touches CoreMIDI or a real FM-1. They also
cover the AU's state and render block and the probes' shared file and notifications within one process. The core
tests (`CoreTests`) use the macOS builds of `scripts/build_cores.sh macos` and skip without them: each core boots and
plays, two slots of one core don't share state, a fifth slot is refused, a released slot comes back fresh, the flash
round trip, a firmware reboot, a core on the fake unit, FIZZ's descriptor and demo, Saadet's descriptor and its store variant (no vendor bank data in the binary, boots,
sounds), and the default core when the
preferred one is missing. M4 adds `LeaseTests` (the lease with two clients and with
a forked second process, a takeover on the shared fake that never sends SESSION 0, and `PanelSession`'s rules) and
`AUCoreTests` (the AU playing ChoralRoot from host MIDI, `fullState` with the flash, a fifth instance's silence, a missing core's fallback).

FM1VST's own conformance test against the macOS builds of our libraries:

    (cd build/cores/macos && cmake --build . --target core_conformance && ctest -R core_conformance)

The cores on a simulator, headless, through the app's real path (fake unit, demo input, audio tapped for 3 s, the
flash saved, a power cycle):

    scripts/sim_coretest.sh [UDID] [choralroot felucca melodee fizz saadet]   # default: RFM iPhone 17 (CEB2B846-...)

It prints each core's summary and saves `coretest-<id>.json`, a screenshot and the log under `$OUT` (default
`$TMPDIR/remotefm1-coretest`).

The AU test on a simulator, headless (Simulator.app stays closed):

    scripts/sim_autest.sh [UDID]                  # default: RFM iPhone 17

It builds, boots the simulator if needed, installs, launches with `-autest`, prints the summary, saves `autest.json`,
the log and two screenshots under `$OUT` (default `$TMPDIR/remotefm1-autest`), and shuts down a simulator it booted.

M4's AU core test on a simulator, headless, the same way:

    scripts/sim_aucoretest.sh [UDID]              # default: RFM iPhone 17

Two instances out of process (ChoralRoot and Felucca) play host MIDI notes for 3 s (RMS per instance, render times);
the panel moves A -> B -> A on the extension's shared fake unit (who started its session, what the old owner sent
after, its SESSION 0s); A's `fullState` (a tempo saved on the fake panel) restores into C, which reconnects under A's
UUID; a duplicate D gets a new UUID; the app's own link and C take the lease from each other. It saves
`aucoretest.json`, the log and screenshots of both instances' views (owner and "in use") under `$OUT` (default
`$TMPDIR/remotefm1-aucoretest`).

Screenshots of the UI for comparing with `design/canvas`, headless, on this project's simulators RFM iPhone 17
(CEB2B846-457C-4A33-AA1A-A287D30CDE2F) and RFM iPad Pro 11 (807A585A-7B1D-4850-8FF3-D8C4871A2F30) (`PHONE=`, `PAD=`
for others, `ONLY=phone|pad`, `NOBUILD=1`), with the core running:

    scripts/sim_shots.sh [OUT]                    # default $TMPDIR/remotefm1-shots

An iPad simulator refuses a programmatic rotation; the app then draws the faceplate turned and the script turns the
PNG back.

libremotefm1's own tests, built outside the source tree:

    cmake -S vendor/FM1VST/remote/RemoteFM1/host -B /tmp/rfm-host -DRFM_SANITIZE=ON -DCMAKE_BUILD_TYPE=Debug
    cmake --build /tmp/rfm-host -j 8 && (cd /tmp/rfm-host && ASAN_OPTIONS=detect_leaks=0 ctest --output-on-failure)

## Launch arguments

- `-fake`: the fake unit inside the app (it also presses keys by itself, so the panel path shows).
- `-fakeble`: the fake unit over Bluetooth (paced, lossy tiles, HOLD).
- `-aucoretest`: only M4's AU core test (above). It writes `au-backend.txt` ("fake") to the App Group before it
  instantiates, so the extension uses its shared fake unit and not CoreMIDI, and removes it at the end. In the
  simulator the extension uses the shared fake anyway unless that file says "device".
- `-autest`: only the AU test, run at launch (the FM-1 link is never created). Its summary goes to `autest.json` in the
  app's Documents and the App Group container. On a device, the "AU test" button runs the same thing.
- `-coretest`: the core test (above) on the normal screen; `-core <id>` picks the firmware (also without `-coretest`).
- The UI (any combination; nothing is needed for normal use):
  - `-view full|controls|screen`, `-deck buttons|keys`, `-knobs main|kn`: the view, the Controls deck, the knob set.
  - `-source phone|fm1`: the sound source (phone: the emulator, the link stopped; fm1: the link, the fake unit on the
    simulator).
  - `-sheet`, `-sheetpage firmware|midi|settings`: the pull-down sheet open (on a page); `-themeeditor`: the editor.
  - `-theme Tangerine|Midnight|Mint|Lilac|Cream`: a theme for this launch (not stored).
  - `-orientation portrait|landscape`: asks the scene for it (`requestGeometryUpdate`).
  - `-steps`: the step numbers 1–16 on the lower keys.
- `-device`: in the simulator, use CoreMIDI (the simulator uses the fake otherwise, as its CoreMIDI may see the
  Mac's MIDI devices). On a device CoreMIDI is the default.

## Licence

GPL-3.0-only (`LICENSE`).
