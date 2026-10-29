# RemoteFM1 for iOS (plan)

Status (2026-10-28): on the owner's iPhone: M1 passed (Bluetooth, FM-1 7938); the store build (FIZZ, Saadet, Boardwalk,
LOOM-8) on TestFlight (build 4); USB audio through the FM-1 clean with render ahead (section 9). Earlier: M0 done; M1 built; M2's and M3's simulator parts done (README.md says how to build and test).
On the simulator, with the fake unit: the app sends the test pattern and shows panel events; ChoralRoot, Felucca
and Melodee run in the standalone app and in the AUv3, and make sound; AU instances keep their core and flash in
`fullState`, and share one FM-1 through the lease (section 4: takeover both ways, reconnect after a reload, between
the app and the extension). Nothing yet on the iPhone, the real "FM-1 7938" or a real host (AUM, GarageBand): the
device parts of M1–M4. Owner's decisions in section 7.

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
  Native cores built in; imported firmware is section 9 (measured on the iPhone, 2026-10-28).

## 3. One firmware image per instance: slots

A core is the firmware compiled as one unit: all of its state is C globals. On macOS FM1VST gets one copy per
instance by copying the dylib to a temp file and loading the copy. On iOS, loading code from outside the signed
bundle is not allowed in App Store/TestFlight builds, and may not work in dev-signed builds either (to test).

Plan: each core is built once, then placed in the bundle as N separate signed frameworks (`FM1Core_choralroot_1` ..
`_4`, the same binary with a different install name). A new instance takes the first free slot of its core in its
process. Slots that are never loaded cost nothing at run time. A fifth ChoralRoot in one host shows "at most 4
ChoralRoot per host". Every instance of our AUv3 in one host app runs in the same extension process (seen in M2 on
the simulator: two instances, one pid; to confirm in AUM and GarageBand), so slots are per host app.

Measured in M3 (iOS simulator): a slot is 1.0–1.2 MB on disk, so 4 slots of the 3 cores add 13 MB to the app (about
120 MB if all ~30 cores shipped this way). A booted slot adds 2.5 MB (ChoralRoot, Felucca) to 3.2 MB (Melodee) of
memory; FIZZ (added 2026-10-28) 4.7 MB, and its renders average 0.66 ms per 512 frames (6 % of the buffer: it draws
with plutovg) against 0.1–0.26 ms for the others. Saadet (added 2026-10-28): a slot is 0.55 MB on disk, a booted slot
2.4 MB, renders 0.08 ms per 512 frames (0.7 %). Boardwalk: 0.6 MB on disk, 2.5 MB booted, 0.14 ms (1.3 %). LOOM-8 0.9.3: 0.95 MB on disk, 2.6 MB
booted, 0.10 ms (0.9 %). `dlclose` really unloads a slot on macOS and the simulator, so a slot
is reusable after a firmware reboot (the loader retires a slot whose image stays mapped). The extension's memory limit
can only be measured on a device.

How the cores are built: `cores/CMakeLists.txt` uses FM1VST's `FM1Cores.cmake` and the cores' glue as they are, and
links each core's objects into a framework exporting only `fm1core_get`. The cores' generate steps write into the
firmware tree, so `scripts/build_cores.sh` builds from a copy under `build/cores/src`, never in vendor/. The only
iOS change a core needed: ChoralRoot's debug profiler includes `<libproc.h>`, which iOS lacks; `cores/ios/libproc.h`
stands in for it (the profiler then reads 0, as on any non-Apple host). FM1VST's conformance test passes on our
macOS builds of the three cores.

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
- **As built (M4).** The record is 4 KiB, `lease.bin` in the App Group (`RFMCore/RFMLease.cpp`); the rules are in
  `RFMKit/PanelSession.swift`. RemoteLink's session thread checks the epoch before each run, pump, frame and poll;
  on a newer epoch it drops the run (no SESSION 0), closes its CoreMIDI links, then acks. A deallocated owner sets
  the pid to 0 and keeps its UUID, so a reload reconnects. Instances that come back together wait 2 s before
  claiming a free or stale unit. A restored UUID that is already live (a duplicated track) gets a new UUID and never
  claims by itself. "The FM-1 has a session from elsewhere" is a guess: HELLO_R's session flag with no owner here
  in the last 6 s. Limit: between the epoch check and a write already under way, a stale owner can still finish
  that one write (microseconds); the new owner starts only after the old one's ack. On the simulator an ack took
  2 ms, within one process and between the app and the extension.
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
| Render thread | no allocation, no locks: Device and the queues already are. The core's `frame()` (screen drawing) ran there too, as in FM1VST (M7: the core now renders ahead on its own thread, section 9). 44.1 kHz resampled to the session rate | C++ kernel renders silence, takes host MIDI; a std::thread in the extension keeps running while it renders | timing under load |
| Memory | measured with 1, 4 and 8 instances | `os_proc_available_memory` is 0 (no limit on the simulator); footprint ~23 MB | the real limit: device only |
| State (`fullState`) | core id, version, instance UUID, settings, and the 1 MiB flash image compressed (`flash_sync` first). A core whose version changed boots from the saved flash as FM1VST does | M4: core id and version, settings and the flash (LZFSE: 1 MiB → ~1.3 KB for a near-empty image) survive a restore into a new instance; ChoralRoot's saved tempo comes back | real hosts' project save and reload |
| Background audio (standalone) | `UIBackgroundModes: audio`, an active audio session, so the unit keeps its panel while the app is in the background | key added; the session activates | behaviour in the background; the save-on-background path (not run headless) |
| Cores on the render thread (M3) | the core runs in the AVAudioSourceNode's callback; with sound off, on a timer thread | 48 kHz, 512-frame renders: average 90–190 µs (1–2 % of the buffer), one early peak of 3.3 ms on the iPhone simulator; sound after the fake unit's key presses on all three cores | timing on the iPhone 13 Pro Max; Melodee's `swapcontext` (deprecated API) on a device; a team-signed build loading the slot frameworks |
| Cores in the AU's render kernel (M4) | `rfme_render_midi`: host MIDI applied at its frame, the core's MIDI out to the AU's MIDI output | two instances (ChoralRoot, Felucca) in one extension: average 50–120 µs, max under 0.7 ms per ~470 frames at 44.1 kHz; host notes sound | timing in AUM/GarageBand; many instances; the MIDI output (built, not tested); host SysEx to the core (not passed yet) |

## 6. Milestones

Each one ends in something tested: on the Mac (`swift test`, ctest for the C), on the simulator headless (the fake
unit), and on the owner's device when it involves the FM-1.

| | What | Done when |
| --- | --- | --- |
| M0 | Skeleton: Xcode project (app, AUv3 extension, `RFMKit`), FM1VST submodule, libremotefm1 + CoreMIDI back end built for iOS | headless simulator build passes; libremotefm1's own tests pass on the Mac |
| M1 | Standalone: Bluetooth sheet, find the FM-1 by HELLO, session, test pattern; HELLO_R fields and link stats on screen. The fake unit for the simulator | on the owner's iPhone: the pattern moves on the FM-1, its keys light their LEDs on the pattern screen |
| M2 | AUv3 test run (no core yet): the extension loads in AUM; CoreMIDI from the extension; Bluetooth sheet inside it; App Group with the team; memory limit; the Bluetooth link after the app closes | each row of section 5 answered and written here; fallback chosen if needed. Simulator part done; device part waits for the iPhone |
| M3 | Cores on iOS: ChoralRoot, Felucca, Melodee cross-compiled, slots, Device on AVAudioEngine; FM-1 as the panel, sound from the phone; flash saved in Documents | play ChoralRoot on the FM-1, hear it on the phone; reboot keeps its settings. Simulator part done (fake unit, all three cores); device part waits for the iPhone |
| M4 | AUv3 instrument: render kernel, host MIDI in/out, `fullState`, the lease, "Use this FM-1", headless instances | two instances in AUM: one tap moves the panel; suspend and project reload reconnect. Simulator part done (`scripts/sim_aucoretest.sh`, a shared fake unit); device part waits for the iPhone |
| M5 | More cores (not gated), Tier 2 parameters as AU parameters, an on-screen LCD mirror and touch keys for use without an FM-1 | per core: its conformance test passes on iOS |
| M6 | The App Store build (section 7): the core flag, the permitted cores, App Review | when there are cores to ship. The flag is built (`RFM_STORE_BUILD`); the store build carries FIZZ |
| M7 | Imported firmware (section 9): the firmware folder, .rfm1 (Wasm) cores, `frame()` off the audio thread | a Felucca .rfm1 imported from Files plays on the iPhone next to the built-in FIZZ. Part 1 done (2026-10-28): the core backend interface (`RFMCoreBackend.h`, native cores behind it) and the render-ahead core thread (section 9); next: the wasm3 backend, the firmware folder |

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
| **App Store** | FIZZ (MPL-2.0, the owner's: `vendor/FIZZ`), Saadet (MPL-2.0, Kerem Kilic's permission; its store variant), Boardwalk and LOOM-8 (MPL-2.0, Charles Vestal), amb, plus each core whose authors all give written permission for App Store distribution | App Store / TestFlight |

- One build flag picks the cores (as FM1VST's `FM1_PUBLIC_BUILD` does). As built: every core is built; the Xcode
  setting `RFM_STORE_BUILD` (default NO) decides what `scripts/embed_cores.sh` puts in the app. YES embeds only the
  cores in `cores/store-cores.txt` (now `fizz`), removes other cores' slots left in the app, and fails the build if a
  core outside the list would be embedded or the list names one that wasn't built. `scripts/testflight.sh` archives
  with YES and checks the archive's cores. Xcode builds on the owner's devices keep all four cores (the owner,
  2026-10-28: TestFlight / App Store builds carry only FIZZ; later that day: and Saadet, Boardwalk and LOOM-8).
- **LOOM-8** (`vendor/loom`, 0.9.3, MPL-2.0 since 0.8): its factory closed hat (`app/samples/909_hat.wav`) is GPL-3.0
  and not in LOOM-8's firmware image; it is in none of our builds either. `build_cores.sh` does not copy the file and
  `cores/loom/gen_samples_rfm.py` makes the samples header with the hat's row empty (n 0), as the FM-1's image has it;
  the rest of the factory set is built in, as in LOOM-8's host build. FM1VST's own LOOM-8 core (0.6.1, GPL) is not
  built here.
- **Saadet** (`vendor/saadet`, Kerem Kilic, MPL-2.0 in its fm1-base build; he gave the owner permission to include it)
  bundles Roland's Juno-106, Sequential's Prophet-5/10 and Casio's CZ-1 factory sounds with no licence granted. Full
  builds carry them; store builds carry a store variant of the same core (id `saadet`, version `0.1.1-store`) built
  without them: `cores/saadet/store/` replaces the three generated bank headers with empty ones (Saadet has no switch
  of its own), and `scripts/embed_cores.sh` takes it from `build/cores/<plat>/frameworks-store`. The app falls back to the first core it has when a
  saved choice or a restored AU state names one this build lacks.
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
- Cross-compiling ~30 cores: their generate steps need Python with Pillow and fontTools on the build Mac, and some
  glue may assume macOS (so far only ChoralRoot's `<libproc.h>`). Each core gets its conformance test before it
  ships.
- App size: 4 identical slots per core cost 4× on disk.
- The App Store build depends on other authors' permission; without it, only amb can ship there.

## 9. Imported firmware: .rfm1 and .fwsc

The owner's aim: users drop firmware files into the app's folder (Files) and switch between them. iOS loads no
unsigned native code and allows no JIT, so an imported firmware runs in an interpreter. Two kinds were measured on the
owner's iPhone 13 Pro Max (A15, iOS 26.3) on 2026-10-28. Details and raw numbers: `spikes/wasm-speed/README.md`,
`spikes/emu-speed/README.md`.

**.rfm1: a firmware's host build (the fm1core ABI, FM1VST's glue) compiled to WebAssembly**, run by wasm3 (MIT).
Audio is bit-identical to the native core. % of a 128-frame buffer at 48 kHz, chord held, mean / p99:

| | 1 instance | 2 | 4 | 8 |
| --- | --- | --- | --- | --- |
| Felucca | 6 / 13 | 13 / 27 | 26 / 54 | 51 / 110 |
| ChoralRoot (its screen redrawing) | 11 / 15, max 77 | 22 / 135 | | |

(Native: under 1%. WAMR's fast interpreter: the same within ~10%.)
- Sound costs 15–25× native. A screen redraw costs a few ms interpreted and ran inside the audio callback:
  ChoralRoot's redraws are what drop out. Running `frame()` off the audio thread is the key change.
- **Render ahead (built, M7 part 1).** Every core, native or Wasm, now runs on its engine's own core thread
  (`RFMEngine.cpp`), never in the audio callback. In audio mode the thread renders into a lock-free ring kept a host
  buffer + 6 ms ahead (`rfme_set_latency`), in 64-frame chunks; the callback only copies from the ring, queues the
  host's MIDI stamped with its frame and wakes the thread (a Mach semaphore). Latency = target + one chunk: 512 frames
  (10.7 ms) at 128-frame buffers and 48 kHz, 896 (18.7 ms) with the simulator's 512-frame renders; the AU reports it
  as `latency`. Host MIDI sounds exactly that much later than its frame, and the core's MIDI out keeps its place.
  Missing frames are silence, counted (underruns). The thread is a Mach real-time thread with the host buffer as its
  period and joins the audio workgroup (the AU's `renderContextObserver`; the app's output unit's
  `kAudioOutputUnitProperty_OSWorkgroup`). Without audio it runs the timer clock. Measured on the simulator (7 cores,
  48 kHz, 512-frame renders): the callback went from 71–962 µs average (FIZZ; max 3.2 ms) to 3–4 µs (max 12 µs),
  0 underruns; on the Mac, a frame() made 3 ms slower every 15 ms gives 0 underruns in 10 s of 128-frame callbacks,
  12 ms slower gives counted underruns. A host's offline render (`renderingOffline`) waits for the core thread.
  On the owner's iPhone 13 Pro Max (2026-10-28) it ended the dropouts heard through the FM-1 as a USB sound card
  ("works, drops, works" before; clean after). Measured on the Mac first (`spikes/usb-audio`): the FM-1's USB audio
  out doesn't drop with screen traffic at any rate; a late render reproduces the dropouts.
- Each Wasm instance has its own memory, so .rfm1 cores need no slots and have no 4-instance cap.
- Porting was small: Felucca built unchanged, ChoralRoot with one stand-in header (`<os/lock.h>`).
- The format must fix: flat exported entry points (a host can't call wasm32 function-table pointers), wasm32 struct
  offsets (`fm1panel_t` matches; the descriptor doesn't), a fixed import list (a few WASI stubs), fixed memory, Wasm
  MVP + sign-ext, sat-float-to-int and bulk memory, no clock or entropy that changes the output.
- Licensing: the app ships only the interpreter; a user's .rfm1 comes from its author's release (GPL source there).
  FM1VST's glue could build .rfm1 files for the cores it already has, published with their source.

**.fwsc: the FM-1's own package, run by fm1-emu's interpreter** (MIT). x real time at 240 MHz (the FM-1's clock),
idle / chord:

| | Mac (M5 Max) interpreter | Mac JIT | iPhone interpreter |
| --- | --- | --- | --- |
| Felucca 1.6.1 | 1.30 / 1.28 | 5.05 / 4.95 | 0.79 / 0.74 |
| stock M-VAVE V15 | 5.35 / 2.85 | 7.50 / 4.55 | 2.99 / 1.42 |
| ChoralRoot 0.27, one-core build | 1.36 / 1.26 | 5.02 / 5.09 | 0.73 / 0.69 |

- On the iPhone heavy firmware runs below real time: not even one instance of Felucca or ChoralRoot.
- fm1-emu already pre-decodes and caches blocks; no cheap 2× is left. A ~40-line fork gains ~6%.
- The biggest lever is the emulated clock: Felucca and ChoralRoot spend spare cycles in a key-scan busy wait. At
  120 MHz the Mac runs them ~1.8× faster with the same sound on the test input (iPhone estimate ~1.3×, not run), but
  firmware may depend on its real clock.
- ChoralRoot's dual-core builds don't boot on fm1-emu (it doesn't model the P33 power interface they use).

**Decision (proposed):** .rfm1 first (M7): the firmware folder, file types, a wasm3 host behind the same engine as
the native cores, `frame()` off the audio thread, and a build target in FM1VST that makes .rfm1 files. .fwsc
emulation stays a later option for light or closed firmware (stock V15 already runs at 1.4×), and on newer iPhones.
App Review may still object to running imported code (guidelines 2.5.2, 4.7).
