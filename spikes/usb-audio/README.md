# usb-audio: does RemoteFM1's screen traffic break the FM-1's USB audio output?

The question: RemoteFM1 for iOS plays through the FM-1's USB audio output (firmware 0.2.2, UAC1, 44.1 kHz) and the
owner hears "works, drops, works, drops". Apple Music through the FM-1 is clean, and so is RemoteFM1 through the
iPhone speaker. Hypothesis: the screen's SysEx stream over USB MIDI (default budget 280 KB/s) starves the FM-1's
isochronous audio OUT, so its ring runs dry (`uac_play`: "prime again").

**Answer (measured on a Mac, 2026-10-28, one FM-1 with RemoteFM1 0.2.2 on USB):** no. Across 12 runs of 30 s with
screen traffic up to what the link carries (SysEx 205-212 KB/s of wire bytes, the unit taking 211-311 KB/s), and
over the vendor bulk link (456 KB/s), the audio output lost no samples: 0 discontinuities in about 85 s of
observed output. The same method catches a host-side render overload at once (1006 discontinuities). Two things got
in the way and are worth knowing:

1. **On 0.2.2, the FM-1's USB audio *input* (recording from the FM-1) is broken** whenever RemoteFM1's main loop
   polls USB (always). It sends mostly silence, with 2-15 ms slices of real audio. See "The input path" below. This
   is a separate bug from the owner's report, but it stops the planned loopback test from seeing the whole output.
2. The SysEx link tops out at about 13 fps with full-screen noise at a 280 KB/s budget: the unit's decode and push
   are the limit (ACKs take 145-150 ms), not USB.

## Method

- `fm1loop.c` (CoreAudio AUHAL, no installs): plays a sine to the FM-1's output device and records the FM-1's
  input device at the same time, both picked by name ("FM-1": there was exactly one, out id 220, in id 218, both at
  44.1 kHz). Optional `--buffer` (the output's IO buffer, this process only) and `--busy-us` (spins in each render
  callback). It changes the device sample rate only when it is not 44.1 kHz, and puts it back afterwards.
- `sxload.c`: a RemoteFM1 session through libremotefm1 and its CoreMIDI back end (vendor/, unmodified; `host.c` is
  compiled here with `rfm_session_add_link` / `rfm_session_rx` renamed to taps, so the tool can also ask the unit
  for STATS). It runs **SysEx only** (the libusb back end is not opened) unless `--transport bulk`. The budget is
  set per run (`--bps`, then budget per frame = bps / 20 fps). Modes: `noise` (a new full-screen noise image every
  frame), `gradient` (scrolling), `static` (one image, then only keepalives), `leds` (static screen, an LED chase
  every frame). It logs body/wire bytes per second, frames per second and ACK times, and reads the unit's STATS
  before and after. Every session ends with SESSION 0, acknowledged ("session stopped" in each log).
- `run.sh NAME MODE BPS SECONDS [fm1loop args]` runs one of each together. `matrix.sh` and `matrix2.sh` hold the
  runs below, and `build.sh` builds everything into `build/`.
- `analyze.py`: the detector (below).

The loopback works because `uac_play` adds the computer's audio to the block before `uac_tap` takes the USB input
(fm1-base `device/main_fm1.c` `render_block`). **MASTER does matter for the loopback.** RemoteFM1 never calls
`plat_usb_audio_full`, so `uac_play` runs at gain `master_pos² >> 12`, *before* the tap. The recording is the
output at MASTER, as the speaker plays it. With the unit's MASTER as found, -24 dBFS came back at 62 LSB (about
-54 dBFS, a gain of 0.030). I used -18 dBFS: about -48 dBFS from the speaker.

### The input path (firmware 0.2.2)

With nothing but the loopback running, the recording is 82-85 % zeros. It holds slices of real audio (92, 357 or 621
samples: the remainder of one, two or three 256-frame renders), one every ~29 ms. The waveform inside the slices is
the clean 997 Hz test tone, and the pattern does not depend on the Mac's IO buffer (64 / 256 / 1024 frames: the
same 26 ms gaps). The cause is in felucca-bsp `chip/usb.c` `uac_service`:

    if (uac.wait < 255u && ++uac.wait == 40u && uac.flowing) { uac.flowing = 0; uac.stalls++; }

This counts *polls* and assumes the 2 kHz timer (40 polls = 20 ms). RemoteFM1 also calls `usb_poll` from its main
loop (`rp_service`): the unit reported 100,000-225,000 main-loop polls a second. So 40 polls go by in 0.2-0.4 ms,
well inside the ~1 ms an IN packet waits for the host. `flowing` drops every frame. The next `uac_render_start`
then sees `feed = 0`, sets `go = 0`, and `uac_packet` sends silence. A render is tapped only when it starts within
those few hundred microseconds after the host took a packet.

The measurements fit this. With fewer polls a second the input works more often: the on fraction is 0.16 at 221 k
polls/s with no session, and 0.31 at 100 k polls/s with full SysEx load. The fix belongs in usb.c: count time, not
polls, or use the `FELUCCA_USB_FRAME_DUE`-style hook the patch already has for the 10 ms check. Anyone recording
the FM-1 over USB on 0.2.2 (a DAW) gets this, and the iPhone app does not open the input (`CorePlayer` uses
`.playback`).

No analog path was available to record the output on its own: the Onyx Producer 2-2's inputs carry only noise, with
no 997 Hz tone even at -12 dBFS. So the test uses the valid slices.

### Detecting dropouts

The output's only way to underrun is a sample deficit: OUT packets lost, or short. The ring's rate steering absorbs
up to ±0.6 %, about 6 packets a second. A lost packet removes 44 or 45 frames from the middle of the stream. So the
tone is **1503 Hz**: 44 frames of it is 1.50 cycles and 45 frames 1.53, so a lost packet flips the phase by about π
wherever it lands. `analyze.py` takes each valid slice (a run of nonzero samples), trims its edges and any held
samples, and fits one sinusoid at the measured frequency. A slice whose residual is over 25 % of the amplitude, and
that two fits with a break explain 4x better, is a discontinuity. Self-test: 44-frame skips spliced into 53 real
slices were found 51 times. The rate is reported per minute of *observed* output, the slices' total length. A
loss lands inside a slice with a probability of about the on fraction.

Not visible: the silent gap of an underrun itself, which looks like the input's own zeros. The packet losses that
must come before an underrun are visible.

## Results

30 s each (the first 1 s and last 0.25 s ignored), 1503 Hz at -18 dBFS. Body / wire are what the host sent per
second while active; polls/s is the unit's main-loop USB polls, from STATS after the run. Out buf / busy are the
Mac's output IO buffer in frames and the spin per render callback.

| run | traffic | budget KB/s | fps | body KB/s | wire KB/s | ACK mean / max ms | unit polls/s | out buf / busy µs | on fraction | observed s | discontinuities | per obs. min |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| a1 | none (audio only) | - | - | - | - | - | 221 k (before) | 512 / 0 | 0.157 | 4.39 | 0 | 0 |
| a2 | none (audio only) | - | - | - | - | - | - | 512 / 0 | 0.162 | 4.52 | 0 | 0 |
| b1 | static screen | 280 | 0 | 0.2 | 0.3 | 41 / 41 | 168 k | 512 / 0 | 0.151 | 4.23 | 0 | 0 |
| b2 | static screen | 280 | 0 | 0.2 | 0.3 | 40 / 40 | 157 k | 512 / 0 | 0.154 | 4.30 | 0 | 0 |
| p1 | LEDs every frame (panel only) | 280 | 0 | 0.2 | 1.4 | 39 / 39 | 141 k | 512 / 0 | 0.148 | 4.13 | 0 | 0 |
| c1 | noise, SysEx | 280 | 12.6 | 177 | 205 | 150 / 179 | 100 k | 512 / 0 | 0.309 | 8.74 | 0 | 0 |
| c2 | noise, SysEx | 280 | 13.1 | 184 | 212 | 145 / 177 | 103 k | 512 / 0 | 0.308 | 8.71 | 0 | 0 |
| g280 | gradient, SysEx | 280 | 12.8 | 180 | 208 | 148 / 178 | 106 k | 512 / 0 | 0.303 | 8.56 | 0 | 0 |
| d140 | noise, SysEx | 140 | 20.0 | 135 | 157 | 36 / 44 | 106 k | 512 / 0 | 0.272 | 7.69 | 0 | 0 |
| d140b | noise, SysEx | 140 | 20.0 | 136 | 157 | 36 / 45 | 106 k | 512 / 0 | 0.273 | 7.72 | 0 | 0 |
| d70 | noise, SysEx | 70 | 20.0 | 63 | 72 | 15 / 73 | 155 k | 512 / 0 | 0.209 | 5.88 | 0 | 0 |
| d35 | noise, SysEx | 35 | 20.0 | 31 | 36 | 8 / 21 | 148 k | 512 / 0 | 0.181 | 5.08 | 0 | 0 |
| e1 | noise, vendor bulk | 800 | 11.6 | 456 | 457 | 166 / 196 | 137 k | 512 / 0 | 0.219 | 6.16 | 0 | 0 |
| h64 | none | - | - | - | - | - | - | 64 / 1100 (76 %) | 0.164 | 4.60 | 0 | 0 |
| h128 | none | - | - | - | - | - | - | 128 / 2300 (79 %) | 0.162 | 4.52 | 7 | 93 |
| h64n | noise, SysEx | 280 | 12.8 | 180 | 208 | 147 / 177 | 101 k | 64 / 1100 (76 %) | 0.310 | 8.76 | 0 | 0 |
| x64 | none (positive control) | - | - | - | - | - | - | 64 / 1600 (110 %) | 0.110 | 2.70 | 1006 | 22339 |

- **No correlation with traffic.** With screen traffic: 0 discontinuities in 75 s of observed output (c, d, g, e,
  h64n), 26 s of it at the full SysEx rate. With no traffic: 0 in 18 s. Over the heavy runs, the 95 % bound on lost
  OUT packets is about 3 / (26 s / 0.3) ≈ 0.035/s, a hundred times below what the steering absorbs. So SysEx causes
  no underruns at any rate the link can carry.
- h128's 7 events all fall in one 0.2 s stretch (20.51-20.72 s). Each has a ~31 % residual, with no clear break
  found. The Mac's render thread was 79 % busy there. That was not seen at 64 frames / 76 %, nor with traffic.
- x64 (110 % render load: the Mac's output plays 60 % of the frames) shows that a host that renders late gives exactly
  "works, drops", and the method sees it.
- The unit's STATS stayed clean throughout: SysEx overflows 0, held 0, MIDI in dropped 0, decode errors 0, USB resets
  2 (from before these runs, unchanged), longest main-loop pass 1352 µs, longest push 21 ms.

## Recommendation for iOS

Measured on the Mac: SysEx screen traffic does not disturb the FM-1's audio output at any budget. Choose the budget
for the screen's sake. At 280 KB/s the unit falls behind on busy screens: 12.6-13 fps and 150 ms ACKs, two frames
always in flight. At **140 KB/s** it keeps 20 fps with 36 ms ACKs and takes 157 KB/s on the wire. That is a better
default, with margin.

This does not explain the iPhone's dropouts. What is left points to the iPhone side. iOS's USB host stack was not
tested here. The owner's symptom also matches a render thread that is late (x64): RemoteFM1's core runs on the audio
render (`RFME_CLOCK_AUDIO`) at the route's rate, 44.1 kHz on the FM-1 against 48 kHz on the speaker. Next tests on the
phone:

- the app with the core replaced by a plain sine;
- the core playing with the screen session off;
- the IO buffer duration and render time logged while it drops.

## Files

| path | what |
|---|---|
| `fm1loop.c` | play + record on the FM-1 (CoreAudio), WAV out; `--list`, `--set-rate NAME HZ` |
| `sxload.c` | the RemoteFM1 session with controlled screen traffic, STATS before and after |
| `analyze.py` | the slice-continuity detector |
| `build.sh`, `run.sh`, `matrix.sh`, `matrix2.sh` | build, one run, the run sets above |
| `build/runs/` | each run's WAV, `.json`, `.sx.log`, `.loop.log` (not committed: build/) |
