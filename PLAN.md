# RemoteFM1 for iOS (plan)

Status (2026-10-27): M0 done; M1 built; M2's simulator part done (README.md says how to build and test). On the
simulator, with the fake unit, the app connects, sends the test pattern and shows panel events; the AUv3 extension
loads, renders silence and answers section 5's checks that the simulator can. Not yet tried on the iPhone with the
real "FM-1 7938" (M1's test and M2's device part). Owner's decisions in section 7.

An iPhone/iPad host for FM-1 firmware cores, with a real FM-1 running RemoteFM1 firmware 0.2.2 as the panel: keys,
buttons, encoders and MASTER come in; the firmware's 240×240 screen and LEDs go out; sound plays on the iOS device.
One app, two forms: a standalone app and an AUv3 instrument (AUM, Logic for iPad, GarageBand, ...).

## 1. What it reuses

| Piece | From | On iOS |
| --- | --- | --- |
| libremotefm1: codec, screen encoder, panel, session, fake unit (`host/src/*.c`, `host/include/rfm`, `proto/rfm1.h`) | RemoteFM1 v0.2.2 | as is: portable C99, no OS calls. Bluetooth pacing, lossy tiles and HOLD (whole screen changes) are already in it |
| CoreMIDI back end (`plugin/RemoteMidi.c` + `RemoteCandidates.h`, RemoteFM1's `host/src/macos/host.c` glue) | FM1VST 0.6.2 | CoreMIDI's API is the same on iOS; built with `RFM_NO_LIBUSB` (no vendor bulk on iOS: SysEx only, over Bluetooth or USB) |
| `RemoteLink` (session thread, event queue, triple buffer) | FM1VST `plugin/RemoteLink.*` (no JUCE) | as is, except its unit lock (flock), which is replaced by the lease in section 4 |
| Device (clock, resampler), core descriptor ABI 6 (`engine/`, `core-api/fm1core.h`) | FM1VST | as is |
| Core loader (`engine/cores.cpp`) | FM1VST | replaced: slots instead of copies (section 3) |
| The cores (`core-glue/`, `cores/` submodules, `cmake/FM1Cores.cmake`) | FM1VST | cross-compiled for iOS (arm64 device, arm64 simulator) |
| Test pattern (`host/tools/fm1remote/patterns.cpp`) | RemoteFM1 | M1's screen, before any core |
| Bluetooth sheet (`CABTMIDICentralViewController`), Xcode setup | FIZZ iOS (`FMToneSeq` branch `ios-app`) | same approach |

FM1VST goes in as a git submodule at `v0.6.2` (it pins RemoteFM1 at exactly v0.2.2, `59a5b52`, and the cores).
Nothing in either repo is edited from here; a change they need is reported to them.

## 2. Engine choice: a native Swift/AUv3 shell, not JUCE

- **Native.** SwiftUI app + AUv3 extension (Apple's Audio Unit extension template: Swift UI, a C++ render kernel)
  around a shared framework, `RFMKit`, holding libremotefm1, the CoreMIDI back end, `RemoteLink`, the Device and the
  cores. The render kernel is fm1remote's engine: the core runs on the render thread; panel events come in through a
  lock-free queue; the LCD and LEDs go out through a triple buffer.
- **Why not JUCE.** FM1VST's JUCE plugin is mostly a desktop UI (Editor, PanelComponent, Sheet: about 6,000 lines)
  that the FM-1 itself replaces here. Its macOS-only parts (dylib copies, libusb, video recording) need rewriting for
  iOS anyway. The AUv3-specific work (state, the shared session, the Bluetooth sheet) is simpler in native code.
  JUCE 8 is AGPLv3 or commercial: one more licence to settle. Native drops all of that. The cost: the AUv3 boilerplate
  and, later, the parameter tree, which we write ourselves.
- **No emulator engine.** fm1emu (Rust) runs real firmware binaries, but iOS forbids JIT, and its interpreter runs
  Felucca at about 0.9× real time natively on an M5 Max (emulator evaluation, 2026-10-27). Too slow on a phone.
  Native cores only.

## 3. One firmware image per instance: slots

A core is the firmware compiled as one unit: all of its state is C globals. On macOS FM1VST gets one copy per
instance by copying the dylib to a temp file and loading the copy. On iOS, loading code from outside the signed
bundle is not allowed in App Store/TestFlight builds, and may not work in dev-signed builds either (to test).

Plan: each core is built once, then placed in the bundle as N separate signed frameworks (`FM1Core_choralroot_1` ..
`_4`, the same binary with a different install name). A new instance takes the first free slot of its core in its
process. Slots that are never loaded cost nothing at run time. A fifth ChoralRoot in one host shows "at most 4
ChoralRoot per host". Every instance of our AUv3 in one host app runs in the same extension process (seen in M2 on
the simulator: two instances, one pid; to confirm in AUM and GarageBand), so slots are per host app.

Size measured on macOS: `choralroot.fm1core` is 0.8 MB on disk, 2.6 MB of data (mostly zero-filled) when loaded,
plus the 1 MiB flash image. The extension's memory limit is lower than the app's: measure it on the device in M2.

## 4. AUv3: sharing one FM-1 between instances

### What the firmware does with a second host (PROTOCOL.md section 2)

- HELLO is answered at any time. HELLO_R byte 58 (`session8`) says whether a session is running, not whose.
- A SESSION start always wins. On the same transport it restarts the session; on another transport it moves the
  session there. There is no owner check.
- Panel events and SysEx replies go to the session's MIDI port, so CoreMIDI delivers them to **every** client
  connected to the FM-1's source.
- libremotefm1 restarts a session it thinks it lost (no PANEL_R for 1.6 s, or one without the session flag). Two
  hosts both running libremotefm1 therefore take the unit back from each other, again and again.

So the device can't share. The instances must agree among themselves, and only one runs a session at a time.

### The design

- **Instance ID.** Each instance has a UUID, saved in its AU state, so it survives the host reloading the
  extension or the project.
- **The lease.** A small shared record in the App Group container (mmap'd, no file lock): owner UUID, an epoch
  (bumped on every takeover), the owner's heartbeat time, its host and core names (for the "in use" text). File locks
  are not used: iOS kills a suspended app that holds a lock in a shared container (0xdead10cc), and a suspended owner
  would hold the unit forever.
- **"Use this FM-1"** (one tap): write self as owner with epoch + 1, post a Darwin notification, wait up to 300 ms for
  the old owner to confirm it let go (a suspended owner can't send anyway), then start the session. The SESSION start
  resets the unit (black screen, LEDs off), and the new owner sends its full screen.
- **The old owner** checks the epoch before every send burst on its session thread, and on the notification. On a
  newer epoch it stops sending at once, closes its CoreMIDI links and does **not** send SESSION 0 (that could end the
  new owner's session). It keeps running headless: sound and host MIDI work, and its UI shows "Panel in use by
  <host> / <core>" with the same button.
- **Non-owners** keep no CoreMIDI connection to the FM-1, so they never see its panel events.
- **Suspend and reload.** When the host is suspended, the unit ends the session by itself after its keepalive (3 s).
  When the owner wakes, libremotefm1 finds the unit and starts again, unless the epoch moved. A reloaded instance whose
  UUID is still the lease's owner reconnects without a tap. A new instance takes the unit only if nobody holds it
  (heartbeat older than 3 s). Otherwise it waits for a tap.
- **Across devices.** A Mac running FM1VST and an iPhone running this app will fight over the unit as above. The app
  can only say so ("the FM-1 has a session from elsewhere": HELLO_R `session8` = 1 with no lease owner). The fix
  belongs in the protocol (e.g. an owner token in SESSION, or a "taken" notice): proposed to RemoteFM1, not done here.
- **Fallback without an App Group** (if one turns out not to work for an extension): Darwin notify state
  (`notify_set_state`, 64 bits: a short owner ID + epoch) carries the same lease, without the host/core names. M2 on
  the simulator: the App Group container, an mmap'd file in it, Darwin notifications and notify state all work between
  the app and the extension, so the fallback is likely unneeded (to confirm on a team-signed device build).

## 5. iOS and AUv3 constraints

The M2 column is what the iOS 27.0 simulator showed (`scripts/sim_autest.sh`: the app loads the extension twice out
of process, renders, restores state, and collects the probes). Simulator results can differ on a device; the same
probes run on the iPhone from the app's "AU test" button.

| Constraint | Plan | M2 on the simulator | Still needs the device |
| --- | --- | --- | --- |
| CoreMIDI from inside an extension: not confirmed by Apple's documentation | Fallback A: the standalone app as a bridge (shared-memory ring in the App Group); it must be running. Fallback B: the host's MIDI routing (AU MIDI out → FM-1, FM-1 → AU MIDI in); works in AUM, not in GarageBand | client and ports created (status 0) inside the extension; the simulator lists no MIDI endpoints at all, in the app or the extension | whether the extension sees the FM-1 and can run a session |
| Bluetooth pairing UI | in the app (`CABTMIDICentralViewController`) and inside the extension's view. Hosts have their own (AUM's Bluetooth MIDI button) | presents inside the extension and scans. On iOS 27.0 the panel crashed in the app and the extension (`UIScreen.main.applicationFrame` is NaN there); `RFMKit/UI/BluetoothSheet.swift` builds its table itself only in that case. SwiftUI `.sheet` crashed in the extension too: it presents with UIKit | real pairing; whether iOS 27 devices have the same bug |
| The Bluetooth link belongs to the app that made it: FIZZ saw it drop when its app was relaunched | if a link made in the app doesn't survive the app closing, pair from the host or from the extension | not testable | device only |
| USB on the owner's iPhone 13 Pro Max: with FIZZ, the FM-1 did not appear over the Lightning camera adapter | Bluetooth first. USB is tested on a USB-C iPad when there is one | not testable | device only |
| Render thread | no allocation, no locks: Device and the queues already are. The core's `frame()` (screen drawing) runs there too, as in FM1VST. 44.1 kHz resampled to the session rate | C++ kernel renders silence, takes host MIDI; a std::thread in the extension keeps running while it renders | timing under load |
| Memory | measured with 1, 4 and 8 instances | `os_proc_available_memory` is 0 (no limit on the simulator); footprint ~23 MB | the real limit: device only |
| State (`fullState`) | core id, version, instance UUID, settings, and the 1 MiB flash image compressed (`flash_sync` first). A core whose version changed boots from the saved flash as FM1VST does | instance UUID and format version survive save and restore into a new instance (keys `rfm1.instance`, `rfm1.format`) | (the rest comes with M3/M4) |
| Background audio (standalone) | `UIBackgroundModes: audio`, an active audio session, so the unit keeps its panel while the app is in the background | key added; the session activates | behaviour in the background |

## 6. Milestones

Each one ends in something tested: on the Mac (`swift test`, ctest for the C), on the simulator headless (the fake
unit), and on the owner's device when it involves the FM-1.

| | What | Done when |
| --- | --- | --- |
| M0 | Skeleton: Xcode project (app, AUv3 extension, `RFMKit`), FM1VST submodule, libremotefm1 + CoreMIDI back end built for iOS | headless simulator build passes; libremotefm1's own tests pass on the Mac |
| M1 | Standalone: Bluetooth sheet, find the FM-1 by HELLO, session, test pattern; HELLO_R fields and link stats on screen. The fake unit for the simulator | on the owner's iPhone: the pattern moves on the FM-1, its keys light their LEDs on the pattern screen |
| M2 | AUv3 test run (no core yet): the extension loads in AUM; CoreMIDI from the extension; Bluetooth sheet inside it; App Group with the team; memory limit; the Bluetooth link after the app closes | each row of section 5 answered and written here; fallback chosen if needed. Simulator part done; device part waits for the iPhone |
| M3 | Cores on iOS: ChoralRoot, Felucca, Melodee cross-compiled, slots, Device on AVAudioEngine; FM-1 as the panel, sound from the phone; flash saved in Documents | play ChoralRoot on the FM-1, hear it on the phone; reboot keeps its settings |
| M4 | AUv3 instrument: render kernel, host MIDI in/out, `fullState`, the lease, "Use this FM-1", headless instances | two instances in AUM: one tap moves the panel; suspend and project reload reconnect |
| M5 | More cores (not gated), Tier 2 parameters as AU parameters, an on-screen LCD mirror and touch keys for use without an FM-1 | per core: its conformance test passes on iOS |
| M6 | The App Store build (section 7): the core flag, the permitted cores, App Review | when there are cores to ship |

Code is written by Opus subagents, one milestone at a time; Claude designs, reviews and tests.

## 7. Decisions

Decided by the owner (2026-10-27):

- **Firmwares:** ChoralRoot, Felucca, Melodee first (M3), then the cores that aren't gated; never the gated ones
  (fm106, rainbow, fartmachine, x0x, nomansky, orbit, sloop, sloopdx).
- **Devices:** one universal app, iPhone and iPad. Developed and tested on the iPhone 13 Pro Max over Bluetooth;
  USB-MIDI when a USB-C iPad is available.
- **Test unit:** the RemoteFM1 unit that advertises "FM-1 7938".
- **Distribution:** this repo is GPL, and the owner also wants an App Store app. The owner has a paid Apple Developer
  account (this Mac's Xcode only lists the free Personal Team so far: sign in with the paid team before M1's device
  install).

### GPL and the App Store: two builds from one repo

GPLv3's terms conflict with the App Store's only for code by **other** people. The owner holds the copyright to their
own code (this app; libremotefm1; FM1VST's `engine/`, `core-api/`, `RemoteLink` and `RemoteMidi.c`: every commit
there is the owner's), so the owner may also publish it on the App Store. A core's glue goes with its core: some glue
files are copies of firmware code (e.g. `core-glue/fm1base/loom_*.c`, `core-glue/plat/x0x_*.c`). The cores are the
problem:

- Every core except amb is GPL-3.0-only, and none is the owner's alone. ChoralRoot (and PurpleMonkey, built on it) is
  a Felucca fork: it carries Leo Kuroshita's Felucca, Kerem Kilic's Melodee engines, Charles Vestal's Velo/MONK-1
  key sensing, SLOOP's resampler, Dexed (GPL-3.0-or-later), and a contributor's commits (genkigenki). It also compiles
  in Casio's CZ-1 preset tones and Sequential's Prophet-5 programs, for which no licence was granted.
- amb (Charles Vestal, on fm1-base) is MPL-2.0, which the App Store allows.

So:

| Build | Cores | How it ships |
| --- | --- | --- |
| **Full** (GPL) | every core that isn't gated | Xcode installs and ad-hoc builds on the owner's devices; the source is public |
| **App Store** | amb, plus each core whose authors all give written permission for App Store distribution | App Store / TestFlight |

- One build flag picks the cores (as FM1VST's `FM1_PUBLIC_BUILD` does).
- To get a core into the App Store build, the owner asks its authors for an extra permission (GPLv3 section 7).
  There is a precedent: Leo Kuroshita let fm1-base take his Felucca code under MPL-2.0 (felucca-bsp#4). ChoralRoot in
  the App Store would also need the Casio and Sequential sound data left out or cleared.
- **Contributions:** for the owner to keep shipping this repo on the App Store after others contribute, the repo
  needs either a section 7 permission for app stores in its licence, or a contributor agreement. Recommended: the
  permission, in `LICENSE`, before the first outside contribution. The owner decides.
- The App Store edition needs something to play from the first day: amb alone is thin. Until there is permission for
  more, the App Store app may not be worth shipping. Work on it waits until the Full build works (M4).

## 8. Risks

- CoreMIDI may not work inside an AUv3 extension (section 5): the fallbacks are clumsier for the user.
- Bluetooth only on the iPhone: about 35 KB/s with 0.2.2, so a page change takes a moment, shown whole (HOLD).
- The lease relies on every instance behaving; a crashed owner is only detected through its stale heartbeat (3 s).
- Slots cap instances per core per host (4 proposed).
- Cross-compiling ~30 cores: their generate steps need Python with Pillow on the build Mac, and some glue may assume
  macOS. Each core gets its conformance test on iOS before it ships.
- The App Store build depends on other authors' permission; without it, only amb can ship there.
