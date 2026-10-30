# RemoteFM1 for iOS

An iPhone and iPad host for FM-1 firmware cores, with a real M-VAVE FM-1 running RemoteFM1 firmware 0.2.2 as the
panel. See [PLAN.md](PLAN.md) for the design and the milestones.

Status: M1, and M2, M3 and M4 on the simulator. The app finds the FM-1 over CoreMIDI (Bluetooth MIDI or USB,
SysEx only) and runs a session. In Pattern mode it sends M1's test pattern. In Core mode it runs a real firmware
(ChoralRoot 0.26.1, Felucca 1.6.1, Melodee 1.4.5, FIZZ 0.12.0-beta.12, Saadet 0.1.1, Boardwalk 0.9 or LOOM-8 0.9.3) with the FM-1 as its panel and the sound on the iOS device; the
firmware's flash is kept in `Library/Application Support/cores/<id>.bin`. M2 adds the AUv3 instrument as a skeleton (renders silence)
and probes for PLAN.md section 5. M4: the AUv3 instrument plays a core (host MIDI in, the core's MIDI out, the flash
in `fullState`), and its instances and the app share one FM-1 through the lease of PLAN.md section 4 ("Use this
FM-1"). M7: imported `.rfm1` firmware (WebAssembly, run by wasm3) next to the built-in cores, in the app and the
AUv3 (below). Not yet tried on a real FM-1, iPhone or third-party host.

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
  firmware and About, Diagnostics, MIDI: keys from MIDI, the octave, the host's clock, Knobs from MIDI).
- `RemoteFM1.xcodeproj`: the app and extension targets; both use `RFMKit` as a local package and share the App Group
  `group.com.quixotic7.remotefm1`. The app's "Embed core slots" phase (`scripts/embed_cores.sh`) builds the cores if
  needed and puts their slot frameworks in `RemoteFM1.app/Frameworks`, signed.
- `cores/`: the CMake project for the cores (FM1VST's `fm1_add_core` and the cores' glue, without JUCE),
  `cores/fizz/` (FIZZ's build file and descriptor), `cores/saadet/` (Saadet's: its unit on FM1VST's fm1-base glue,
  the instrument unit, descriptors, the conformance script, and `store/`: the empty factory banks of its store
  variant), `cores/boardwalk/` (Boardwalk's unit on the same glue, its sound engine's unit, descriptor and
  conformance script), `cores/loom/` (LOOM-8's: its unit, the o2 units, `loom_plat.c` for `app/plat_loom.c`, and
  `gen_samples_rfm.py`, the factory samples without the GPL 909 hat), `cores/store-cores.txt` (the cores of an App Store / TestFlight
  build: `RFM_STORE_BUILD=YES`), and `cores/ios/libproc.h`, a stand-in for a header the iOS SDK lacks (ChoralRoot's
  profiler).
- `RFMKit/`: a Swift package.
  - `CRemoteFM1`: libremotefm1 (`vendor/RemoteFM1`: RemoteFM1's `standalone` branch at fa97a90, with MIDI_IN, the TRS jack's MIDI), its macOS glue `host.c` and FM1VST's CoreMIDI back end
    `RemoteMidi.c`, compiled in place from `vendor/` through the `RFMKit/vendor` symlink. Built with `RFM_NO_LIBUSB`.
  - `CWasm3`: wasm3 v0.5.0 (MIT, unchanged; its README says from where), the interpreter for imported firmware.
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
    Diagnostics view; `Install/`: installing RemoteFM1 on the FM-1 with FM1Kit (the releases, the package checks,
    `FirmwareInstaller`, its page; tested by `FirmwareInstallTests` on FM1Kit's SimulatedFM1).
- `vendor/RemoteFM1`: RemoteFM1 (host library MPL-2.0) at fa97a90 (`standalone`: MIDI_IN) as a git submodule, for
  libremotefm1 and fm1remote's patterns. Read-only.
- `vendor/FM1VST`: FM1VST v0.6.2 as a git submodule (`plugin/RemoteMidi.c` and `cores/ChoralRootFM1`, `cores/Felucca`
  with its `firmware/engines`, `cores/melodee`). Read-only.
- `vendor/FIZZ`: FIZZ v0.12.0-beta.12 (MPL-2.0) as a git submodule (its own submodule, fm1-base, is not needed).
  Read-only.
- `vendor/saadet`: Saadet v0.1.1 (Kerem Kilic; MPL-2.0 in its fm1-base build) and `vendor/fm1-base`: fm1-base at
  Saadet's pin (6c0b47e, which Saadet's build fetches; its `bsp/` is not needed). Read-only.
- `vendor/boardwalk`: Boardwalk v0.9 (Charles Vestal, MPL-2.0) with its `base/` (fm1-base at 4587fda; `base/bsp` is
  not needed). Read-only.
- `vendor/loom`: LOOM-8 v0.9.3 (Charles Vestal, MPL-2.0) with its `base/` (fm1-base at d0133c2; `base/bsp` is not
  needed). Read-only.

## Build

    git submodule update --init vendor/RemoteFM1 vendor/FM1VST vendor/FIZZ vendor/saadet vendor/fm1-base vendor/boardwalk
    git -C vendor/boardwalk submodule update --init base
    git submodule update --init vendor/loom && git -C vendor/loom submodule update --init base
    git -C vendor/FM1VST submodule update --init cores/ChoralRootFM1 cores/melodee
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
sounds), Boardwalk's descriptor, attract tune and cabinets, LOOM-8's descriptor, its kicks and no 909 hat in its binary, and the default core when the
preferred one is missing. M4 adds `LeaseTests` (the lease with two clients and with
a forked second process, a takeover on the shared fake that never sends SESSION 0, and `PanelSession`'s rules) and
`AUCoreTests` (the AU playing ChoralRoot from host MIDI, `fullState` with the flash, a fifth instance's silence, a missing core's fallback).
`HostClockTests` (the host's clock as MIDI, buffer by buffer) and `AUMidiTests` (the AU's MIDI switches, the clock and
the MIDI out through the render block, with a test core that echoes its MIDI; no core builds needed).
`AUParamTests` (the parameter tree: host values to the core as panel events and map writes, render events, Tier 2
binding and relabelling, the firmware's changes back to the host, writes after a boot dropped; with the echo core's
small map, and ChoralRoot's, Felucca's and Melodee's real maps when the core builds are there).

FM1VST's own conformance test against the macOS builds of our libraries:

    (cd build/cores/macos && cmake --build . --target core_conformance && ctest -R core_conformance)

The cores on a simulator, headless, through the app's real path (fake unit, demo input, audio tapped for 3 s, the
flash saved, a power cycle):

    scripts/sim_coretest.sh [UDID] [choralroot felucca melodee fizz saadet boardwalk loom]   # default: RFM iPhone 17 (CEB2B846-...)

It prints each core's summary and saves `coretest-<id>.json`, a screenshot and the log under `$OUT` (default
`$TMPDIR/remotefm1-coretest`).

The AU test on a simulator, headless (Simulator.app stays closed):

    scripts/sim_autest.sh [UDID]                  # default: RFM iPhone 17

It builds, boots the simulator if needed, installs, launches with `-autest`, prints the summary, saves `autest.json`,
the log and two screenshots under `$OUT` (default `$TMPDIR/remotefm1-autest`), and shuts down a simulator it booted.
Its steps include the AU's parameter tree as the host sees it (129 parameters) and a write to P01 reaching the
firmware.

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

    cmake -S vendor/RemoteFM1/host -B /tmp/rfm-host -DRFM_SANITIZE=ON -DCMAKE_BUILD_TYPE=Debug
    cmake --build /tmp/rfm-host -j 8 && (cd /tmp/rfm-host && ASAN_OPTIONS=detect_leaks=0 ctest --output-on-failure)

## Imported firmware (.rfm1)

Besides the built-in cores, the app plays `.rfm1` files: FM-1 firmware built as WebAssembly (docs/RFM1-FORMAT.md;
FM1VST's `fm1_add_rfm1` makes them), run by wasm3 in the app and in the AUv3. To add one:

- Firmware › Get firmware in the pull-down sheet: the firmware you can download (see below); or
- open the file on the iPhone (Files, Safari's downloads, AirDrop): RemoteFM1 opens, copies it in and plays it; or
- Firmware › Add firmware… in the pull-down sheet; or
- Files › On My iPhone › RemoteFM1 › Firmware: drop files there, then open the app.

The Firmware page lists them under Imported (Edit, then the red minus and "Delete?", deletes one; firmware built into
the app can't be deleted; About shows the authors, source link, credits and licence texts). Deleting the one playing
moves to its other version, its built-in core, or the first core; an AU instance playing it keeps playing until its
project is opened again. Get firmware's page of an installed firmware has Delete too. A file that isn't a valid .rfm1 stays listed with its error. The AUv3 sees the files the app has
seen (the app copies them into the App Group, `Firmware/<sha256>.rfm1` and `index.json`). Imported firmware works in
store builds too. A firmware too heavy for the device shows a note instead of crackling silently.

**Get firmware** lists the .rfm1 files on remotefm1.com (`catalog.json`) and in the
[RemoteFM1FW releases](https://github.com/Quixotic7/RemoteFM1FW/releases) on GitHub, one entry per firmware at its
newest version; firmware built into the app isn't listed. Install downloads the file, checks its size and SHA-256
against the list, and adds it as Add firmware… does. When a newer version of a firmware you have is listed, its row
says Update, and the Firmware row shows a badge with the count; updating removes the older file (saved sounds and
projects open with the new one). The app checks at launch at most once a day and when the page opens, never in the
background; the last list is kept, so the page works offline. A firmware author can publish their own feed (a
`catalog.json` like remotefm1.com's, or GitHub releases with `<id>-<version>.rfm1` assets): `FirmwareFeed.defaults` in
`RFMKit/Sources/RFMKit/FirmwareFeeds.swift` lists the feeds. Tests: `FirmwareStoreTests` (saved copies of both lists).

Tests: `WasmTests` and `ImportTests` (the loader, AMB-1 from `RFMKit/Tests/RFMKitTests/Fixtures`, Felucca and
ChoralRoot .rfm1 from `$RFM1_DIR`, default FM1VST's rfm1 worktree, skipped without them). On the simulator:

    RFM1="felucca choralroot" scripts/sim_coretest.sh "" rfm1:felucca rfm1:choralroot
    RFM1=felucca WASMONLY=1 scripts/sim_aucoretest.sh

## MIDI controllers, MIDI learn and the OMX-27

- **A MIDI keyboard or controller** (USB or Bluetooth): Controls › MIDI & audio › MIDI input (All by default, None,
  or one device). Its notes play the keys (Keys from MIDI: any channel, one, or Off; Transpose: octaves); "...and
  reach the firmware's MIDI in" also sends them to the firmware. In the AUv3, the host's MIDI does the same (route
  your controller to the instrument).
- **MIDI learn**: Knobs from MIDI › Learn (in the app and the AUv3), then tap a knob, MASTER or a button on the panel,
  then move a control on your device. Done ends it; Forget drops the tapped control's bindings. The list shows each
  mapping (an encoder's mode can be changed; × removes it); Knob speed sets detents per CC step. One set of mappings
  for the app and every AU instance; Use learned knobs (on) turns them off for the app or one instance without
  forgetting them (their messages then go on to the keys and the firmware).
- **OMX-27** (the app): MIDI & audio › Connect my OMX-27, with the OMX-27 on USB and its firmware with REMOTE mode.
  Its keys, encoder and pots play the FM-1; K1 picks the view, K2 the colours, K5 is MASTER. It connects by itself
  next time. To leave remote mode, hold AUX and the encoder on the OMX-27.

## The AUv3's MIDI in a host (AUM and others)

The instrument's sheet › MIDI (each instance its own, saved with the host's project):

- **Keys from MIDI** (Any; the row opens a page: Any, Channel 1–16, Off, as menus can't open inside a host's view):
  notes 53 and up on any channel, or on the one picked, play the FM-1's 27 keys (MIDI
  octave shifts them); notes on other channels go to the firmware's MIDI in. Off: every note goes there, for firmware
  with MIDI of its own (FIZZ: notes for its tracks, CCs for parameters). The other messages (CCs, pitch bend, notes
  outside the keys) always go there, unless a learned knob takes them.
- **Use learned knobs** (on): MIDI learn's mappings play the panel. Off: they are kept but do nothing, and their
  messages go on to the keys and the firmware.
- **...and reach the firmware's MIDI in** (off): the notes that play keys also go to the firmware.
- **Send the host's clock and transport** (on): the host's tempo and transport as MIDI clock (24 per beat), Start,
  Stop, Continue and Song Position, so a firmware's sequencer follows the host. Only hosts that give their tempo and
  transport to plug-ins (AUM, Logic, ...) get it. While on, clock and transport in the MIDI the host routes to the
  instrument are dropped (one clock, not two).
- **MIDI out**: what the firmware sends is the instrument's MIDI output ("RemoteFM1"); route it in the host. It keeps
  its place against the firmware's sound (both a latency, `latency`, behind the host).

## The AUv3's parameters (MIDI control and automation in a host)

The instrument has 129 parameters a host can map MIDI to (AUM's MIDI control) or automate (Logic, Cubasis), with
FM1VST's identifiers (PLAN.md section 12):

- **Knob Master** (0..1023) and **Knob Select, Presets, Algo, Knob 1–4**: when the firmware's screen puts a value on
  a knob, the parameter is that value (its text says which: "Voicing: +3"); otherwise it turns the knob (centred,
  24 steps per full travel, back to the centre after 0.4 s).
- **Button FX .. OCT+** and **Key F3 .. G5**: held while on.
- **P01 .. P80**: the firmware's own parameters in its map's order (ChoralRoot, Felucca and Melodee have them; the
  text says which: "Strum Rate: 40 ms"; "–" unused).

The names stay the same whatever the firmware shows, so mappings and automation keep working. The firmware's own
changes (a knob turned on the FM-1 or on screen, a sound loaded) move the parameters in the host. For a second after
a project loads, the host's parameter values are ignored (the firmware's saved state wins). MIDI learn works next to
them. Diagnostics shows how many slots the firmware uses.

## Installing RemoteFM1 on the FM-1

Controls › Settings › Install RemoteFM1 on the FM-1 puts RemoteFM1 firmware on the FM-1 from the app, without the
website (PLAN.md section 13). Connect the FM-1 with a USB cable (Bluetooth can't install firmware; only one FM-1
connected), pick the release (the newest by default; its USB-only package and older releases can be picked), then
Check the FM-1: the app downloads the package from remotefm1.com, checks its SHA-256 and identity, lets go of the FM-1
(the panel pauses; an AU in another app gives it up) and shows what is on the FM-1 and what will be installed.
Confirm, then Install: keep the app open until it finishes (the screen stays on). If it is cut off, the FM-1 waits in
its update loader and "Finish the install" completes it. The panel reconnects afterwards. Diagnostics shows the
RemoteFM1 version on the FM-1 and "Update available". It uses FM1Kit (MIT); in the simulator the FM-1 is FM1Kit's
SimulatedFM1.

When the app sees an FM-1 that isn't running RemoteFM1 (an FM-1 in the MIDI list that doesn't answer the link within
a few seconds, or one with another firmware's USB IDs), it asks over the faceplate: Install (opens the page) or Not
now (remembered until a newer release). Over Bluetooth it says to connect a USB cable. A RemoteFM1 older than the
newest release gets a small notice instead. Never during an install or while an AU instance holds the FM-1; the AU's
FM-1 card only says to install from the app.

## Sending a DX7 cartridge

Controls › Settings › Send a DX7 cartridge sends DX7 32-voice cartridges (.syx, picked in Files or opened from Files
or AirDrop) to an FM-1 running RemoteFM1 0.3.0 or later, which keeps each as a user bank (USER1..USER3; a fourth
replaces the oldest). The page shows the voice names and fixes a wrong checksum or channel; the panel lets go of the
FM-1 while it sends. USB is preferred; Bluetooth MIDI is paced. Screenshot: `MATCH=cart scripts/sim_shots.sh`
(`-sheetpage cart -cartdemo`). PLAN.md section 14.
With RemoteFM1 0.3.1 the page lists the FM-1's user banks (up to 16) and replaces, removes or renames each; 0.3.0
(no reply) gets the plain send.

## Launch arguments

- `-fake`: the fake unit inside the app (it also presses keys by itself, so the panel path shows).
- `-fakeble`: the fake unit over Bluetooth (paced, lossy tiles, HOLD).
- `-aucoretest`: only M4's AU core test (above). It writes `au-backend.txt` ("fake") to the App Group before it
  instantiates, so the extension uses its shared fake unit and not CoreMIDI, and removes it at the end. In the
  simulator the extension uses the shared fake anyway unless that file says "device".
- `-autest`: only the AU test, run at launch (the FM-1 link is never created). Its summary goes to `autest.json` in the
  app's Documents and the App Group container. On a device, the "AU test" button runs the same thing.
- `-coretest`: the core test (above) on the normal screen; `-core <id>` picks the firmware (also without `-coretest`);
  `-core rfm1:<id>` an imported one.
- `-wasmonly` (with `-aucoretest`): only the imported-firmware part of the AU core test.
- The UI (any combination; nothing is needed for normal use):
  - `-view full|controls|screen`, `-deck buttons|keys`, `-knobs main|kn`: the view, the Controls deck, the knob set.
  - `-source phone|fm1`: the sound source (phone: the emulator, the link stopped; fm1: the link, the fake unit on the
    simulator).
  - `-sheet`, `-sheetpage firmware|getfirmware|midi|midiinput|keychannel|midimode|settings`: the pull-down sheet open
    (on a page);
    `-sheetscroll knobs|omx|footer`: the MIDI page (Get firmware) scrolled there; `-themeeditor`: the editor.
  - Debug builds: `-catalogitem <id>`: Get firmware's page of that firmware; `-catalogget <id>`: download and
    install it at launch (the live list; `MATCH=getfw scripts/sim_shots.sh`); `-firmwareedit [ask]`: the Firmware
    page in Edit (ask: its first row asks "Delete?"; `MATCH=fwedit`); `-fm1prompt install|unanswered|bluetooth|update`:
    the install prompt or the update notice (`MATCH=prompt`).
  - `-learn`: MIDI learn on at launch; `-learnpick KN1` (any target: SELECT, MASTER, PLAY, OCT-...) with it picked;
    `-demomap`: replaces the global mappings with a few examples (screenshots only).
  - `-theme Tangerine|Midnight|Mint|Lilac|Cream`: a theme for this launch (not stored).
  - `-orientation portrait|landscape`: asks the scene for it (`requestGeometryUpdate`).
  - `-steps`: the step numbers 1–16 on the lower keys.
- `-device`: in the simulator, use CoreMIDI (the simulator uses the fake otherwise, as its CoreMIDI may see the
  Mac's MIDI devices); without it the MIDI input starts with no source connected. On a device CoreMIDI is the default.
- `-autest -aupage midi|keychannel|midimode|learn|learn:KN1|sheet:midi`: the AU test, then that page of the AU's view (`AUPAGE=...
  scripts/sim_autest.sh`; `sheet:midi`: the sheet at its MIDI section).
- `-sheetpage install`: the installer's page; `-installdemo check|writing|finished|cutoff` (DEBUG builds): it runs by
  itself on FM1Kit's SimulatedFM1 (stops at the confirmation; installs; installs; is cut off at 45 %), for
  `MATCH=install scripts/sim_shots.sh`.

## Licence

GPL-3.0-only (`LICENSE`), except these files, which are MPL-2.0 (`LICENSES/MPL-2.0.txt`; the author's decision,
2026-10-30, so FIZZ for iOS can reuse them, as FM1VST did with its own): the MIDI map and learn
(`RFMKit/Sources/RFMKit/MIDI/MidiMap.swift`, `MidiLearn.swift`, `RFMKit/Sources/RFMCore/RFMMidiMap.{h,cpp}`), the
OMX-27 (`RFMKit/Sources/RFMKit/OMX27/OmxWire.swift`, `OmxViews.swift`, `OmxScreen.swift`, `OmxTransport.swift`,
`OmxLink.swift`) and their tests (`MidiMapTests.swift`, `MidiEngineTests.swift`, `OmxTests.swift`). Each file's SPDX
line says which.

Other people's code in the app: wasm3 v0.5.0 (MIT, `RFMKit/Sources/CWasm3`), FM1Kit 0.4.x
(Drew Robinson, MIT, https://github.com/ocean/FM1Kit, a Swift package dependency of RFMKit; its licence is shown on the
install page), the four UI fonts (OFL, `RFMKit/Sources/RFMKit/Resources/Fonts`), and the cores with their own
licences (PLAN.md section 7).
