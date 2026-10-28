# RemoteFM1 iOS: UI design handoff

The visual design for the app's on-screen FM-1 (PLAN.md M5: "an on-screen LCD mirror and touch keys for use without an
FM-1") and for the reduced views used while a real FM-1 is the panel. Made in a Claude design canvas, 2026-10-28.

- Live canvas (owner only until shared): https://claude.ai/code/artifact/95ed9bcd-64b3-4d07-b8b4-644cd2fe1ce2
- `tokens.json`: the five color themes, fixed colors, fonts, radii.
- `canvas/*.dc.html`: the design source of every screen and part. HTML for the canvas's own runtime: read them for
  exact numbers and structure; they don't run on their own. `canvas/canvas.json` lists them.
- `reference/fm1-hardware.png`: photo of the real unit the layout follows.

Everything below is the design intent. Where it says "suggested", the canvas doesn't show it and it's a recommendation.

## 1. The idea

The phone becomes the FM-1's faceplate: the whole screen is the body color, with the hardware's controls drawn in the
same arrangement as the real unit. Two ways to use it, one UI:

- **Emulator** (standalone, no FM-1): touch plays the on-screen keys, buttons and knobs; the core's framebuffer and
  LEDs show on screen.
- **FM-1 linked** (RemoteFM1 firmware as the panel, PLAN.md section 4): the real unit's keys, buttons and encoders
  drive the core; the app mirrors the screen and LEDs. The on-screen controls still work and send the same events.
  Because the user has real hardware in hand, they can cut the view down (section 3).

A status chip, top left, always says which: `Emulator` (dot in `label` color) or `FM-1 linked` (green dot `#3BD47A`).

## 2. The hardware layout to match (reference photo)

- **Left cluster**: four knobs in a 2×2 grid, MASTER, SELECT (top), PRESETS, ALGORITHM (bottom). Under them,
  OCT− and OCT+ in a recessed well.
- **Display**: square, in a dark bezel, center. The firmware's screen is 240×240 (PLAN.md).
- **Right cluster**: a small red indicator LED, then KN1–KN4 in a row; under them a 6×2 button grid:
  `FX SEL ENV LFO EDIT GLO` / `HOME SAVE ARP SEQ PLAY REC`. PLAY has a green ▶ glyph, REC a red ● glyph (the glyph
  carries the color; the legend stays `keyText` for contrast).
- **Keybed**: 27 keys, F to G over two octaves (F3–G5 in the canvas; OCT shifts it). Two rows of rounded pills, not
  overlapping piano keys: 16 naturals in the lower row, 11 sharps in the upper row, each sharp centered on the gap
  between its two naturals. Every key has a vertical LED slot in its center. The 16 lower keys double as the
  16 sequencer steps.

## 3. Views and navigation

| View | What's on screen | Canvas file |
| --- | --- | --- |
| **Full** | everything, in the hardware arrangement | `Main` (iPhone), `PhoneWide`, `PadWide`, `PadTall` |
| **Controls** | big display + one knob row + a lower deck that is either **Buttons** (6×2 + OCT) or **Keys** | `PhonePanel`, `PhoneKeys` |
| **Screen** | the display alone, as big as fits | `PhoneScreen` |

- **Swipe sideways on the background** to move between Full, Controls and Screen. Page dots at the bottom (Full and
  Controls only; the Screen view has none, deliberately: the owner wanted nothing but the display there).
- **Inside Controls**:
  - The knob row swipes sideways between two sets: **MAIN** (Master, Select, Presets, Algorithm) and **KN 1–4**.
    A small `MAIN | KN 1–4` switch under the row shows the live set and can be tapped. Both sets are reachable in
    both decks: the owner wants knobs available whatever the lower deck shows.
  - The lower deck swipes sideways between **BUTTONS** and **KEYS**, with a `BUTTONS | KEYS` segmented switch above
    it. Suggested: a horizontal swipe inside the deck changes the deck; outside it, the view.
- **Pull-down controls**: a grabber handle under the status bar (top center, 88×44 hit area). Swiping down from it
  opens a sheet from the top (`PhoneSheet`), swiping up or Done closes it. Contents, top to bottom:
  1. **Sound source**: two cards, *This iPhone* (emulator, play by touch) / *FM-1* (RemoteFM1 · Bluetooth).
  2. **View**: four tiles with mini wireframes: Full, Panel (= Controls/Buttons), Keys (= Controls/Keys), Screen.
  3. **Theme**: the five preset swatches and *Edit* (opens the theme editor).
  4. A list: **Firmware** (current core, e.g. ChoralRoot, opens the core picker), **MIDI & audio**, **Settings**.
- Full view is the default in Emulator mode; suggested: remember the last view per mode.

## 4. Layouts (reference frames, in points)

The numbers are the canvas's frames. Build them with size classes and proportional geometry, not fixed points;
these are the targets at each reference size.

### iPhone portrait, 390×844
- Status row at y 50: chip left, grabber center, `REMOTE FM1` wordmark right (Chakra Petch 12, tracking 0.14em).
- **Full** (`Main`): MAIN knobs 2×2 (knob 46) at (16, 96), cluster 148 wide; OCT well (16, 246) 148×52;
  display 202 at (172, 96); red LED + KN1–KN4 (knob 46) across at y 316; buttons 6×2 at (21, 400), 48×42, gap 8;
  keybed (16, 530) 358×272, **scrolling** (section 5.3).
- **Controls**: display 340 at (25, 92); knob row (knob 50) at y 444; set switch at y 523 (160×32); deck switch
  (95, 565) 200×36; then
  - Buttons deck: grid at (15, 611), 50×48, gap 8; OCT well (95, 747) 200×48.
  - Keys deck: scrolling keybed (16, 611) 358×186.
- **Screen**: display 358 at (16, 243).
- The keybed is never split into two stacked octaves. The owner rejected that. On a phone in portrait it scrolls.

### iPhone landscape, 844×390 (closest to the hardware)
- MAIN knobs 2×2 (knob 38) at (54, 20), 132 wide; OCT well (54, 144) 132×48.
- Display 172 at (198, 20).
- Red LED + KN1–KN4 (knob 38) across (386, 20), 408 wide; buttons 6×2 at (386, 88), 58×38, gap 8.
- Keybed, all 27 keys in one row, at (50, 206) 744×170.
- Grabber at top center, no status row (it would collide with the knob labels).

### iPad landscape, 1194×834
- Status row at y 26 (48 side margins).
- MAIN knobs 2×2 (knob 64) at (48, 88), 192 wide, row gap 24; OCT well (48, 334) 192×54.
- Display 300 at (272, 88).
- Red LED + KN1–KN4 (knob 64) across (604, 88), 542 wide; buttons at (606, 234), 78×60, gap 10.
- Keybed row at (48, 424) 1098×362.

### iPad portrait, 834×1194
- MAIN knobs 2×2 (knob 84) at (40, 88), 224 wide, row gap 8.
- Display 290 at (272, 88).
- KN1–KN4 as a 2×2 (knob 84) at (570, 88), 224 wide; red LED under them at (677, 344).
- Buttons 6×2 at (77, 404), 100×64, gap 12.
- OCT well on its own row **under the buttons, left-aligned with the keybed**: (40, 590) 220×54.
- Keybed row at (40, 660) 754×476.

### AUv3 extension view
Not drawn. Suggested: pick the layout from the view's own size (the host decides it): wide and short → the
landscape layout; tall → the Controls view; very small → Screen. The pull-down sheet can't rely on the status bar
area there; put the grabber inside the view's top edge.

## 5. Parts

### 5.1 Display (`Screen.dc.html`)
- Bezel: `bezel` color, padding 4.5% of the size, corner radius 9%; a 4pt drop shadow `rgba(0,0,0,.25)`.
- Inside: **the core's 240×240 framebuffer**, scaled to fit with nearest-neighbor sampling (no smoothing), inner
  radius 3.5%. The text in the canvas (`001 PIANO 1`, battery, OP 1–6, K1 RATIO…, `‹ OSC ›`, the SEQ page) is
  placeholder for firmware pixels, drawn so the design reads; the app draws only the framebuffer. The theme's
  `lcd`/`ink` colors therefore apply only to the mock.
- Suggested: when the size allows, snap to whole-pixel multiples (240, 480) for crispness; otherwise fill.

### 5.2 Knob (`Knob.dc.html`)
- Label above in Chakra Petch 700, uppercase, tracking 0.08em, `label` color; size max(9, 17% of the knob).
- Body: a `knob` circle; a knurled ring (white at 16%, dashed) at 90% radius; a cap at 72% radius with white at 7%;
  the pointer a rounded line in `mark` color from 10% to 30% of the diameter, rotated; a hard drop shadow 6% of the
  size, `rgba(0,0,0,.28)`. Hit area: the knob plus its label, at least 44pt.
- Behavior (suggested): vertical drag (or circular drag around the center). MASTER is a pot: its angle shows the
  absolute value over a 270° sweep. The others are encoders (PLAN.md: "keys, buttons, encoders and MASTER"): the
  pointer turns with each step, no end stops, a light selection haptic per detent.
- When linked, the real unit's encoder turns rotate the on-screen pointer too.

### 5.3 Keybed (`Keys.dc.html`)
- Keys: `key` face, `hi` 2pt inset top edge, `lo` 4pt drop shadow, radius min(42% of width, 18).
  Sharps are 86% of a natural's width; the sharp row is 40% of the row height; the gap between keys is about 0.8% of
  the keybed width (3–10pt). The keybed is a `bed` well with an inset top shadow.
- LED slot: centered vertical bar, max(3, 8% of key width) wide, 42% of the key's height, `ledOff` when off. Lit:
  `led` with a glow (`0 0 10pt led, 0 0 3pt led`).
- **LEDs mirror the firmware's LED frame** (PLAN.md: the LEDs go out through the triple buffer). The canvas shows
  two illustrative states:
  - Play: held notes lit (C4, E4, G4).
  - Sequencer: the 16 naturals show steps; on-steps lit at 60%, the playhead step at 100% with its key face in `hi`,
    plus small step numbers 1–16 under the LED. Suggested: the numbers are an overlay the app shows when it knows
    the core is in a step mode (or a Settings toggle), since the app can't know every core's mode.
- Layouts:
  - **row**: all 27 keys across the width (iPhone landscape, both iPads).
  - **scroll** (iPhone portrait): naturals at a fixed width (40pt plus the gap), about 8 visible. Above the keys, a
    **range strip** of 16 mini cells, one per natural, each with a tiny LED that mirrors that key, and a frame
    showing the visible part. Tap a cell to center the keys there; suggested: drag the frame or the strip to scroll.
    The keys animate horizontally (0.2s). The keys themselves never scroll on touch, since that touch plays notes.
- Touch (suggested): true multitouch, one note per finger; sliding a finger onto another key plays it (glissando);
  key-down velocity fixed or from a setting.

### 5.4 Buttons (`Buttons.dc.html`)
- A `bed` well with 10pt padding, radius 34% of button height + 6; buttons in a grid (6×2; the code supports 4×3
  and 3×4 if a layout ever needs it).
- Button: `key` face, `hi` 2pt inset, `lo` 4pt drop shadow, radius 24% of height; legend Chakra Petch 700, size
  max(10, 26% of height), tracking 0.06em, `keyText`.
- Active (lit) state: face `hi`, legend `led` with a glow. Suggested: driven by the firmware's button LEDs if it
  reports them, otherwise by press.
- Order: `FX SEL ENV LFO EDIT GLO HOME SAVE ARP SEQ PLAY REC` (PLAY's VoiceOver label: "Play / Stop").

### 5.5 OCT− / OCT+
Two buttons in a `bed` well (padding 4–5pt, radius 12–15), same style as 5.4. Their place follows the hardware
(under the MAIN knobs), except iPad portrait (under the buttons, above the keybed's left end) and the phone
Controls/Buttons deck (under the grid).

### 5.6 Indicator LED
A 9–12pt rounded square, `#FF3B2F` with a glow, left of KN1. Mirrors the firmware's LED if there is one.

## 6. Themes

- Five presets (`tokens.json`): **Tangerine** (matches the orange unit, default), Midnight, Mint, Lilac, Cream.
- Theme editor (`Theme.dc.html`): a live preview, which is the iPad-landscape faceplate scaled down so it always
  matches the real arrangement; the preset tiles; then five customizable colors: **Faceplate** (`body`),
  **Keys and buttons** (`key`), **Knobs** (`knob`), **LEDs** (`led`), **Display** (`lcd`, mock only, so suggested:
  hide this row or make it the bezel). *Save as my theme* stores a custom theme.
- Deriving the rest for a custom theme (suggested): `hi` = key lightened ~8% (L*), `lo` = key darkened ~18%,
  `bed` = key darkened ~6%, `keyText` and `label` = whichever of near-white or near-black passes 4.5:1 on `key` and
  `body`, `mark` = near-white on dark knobs and near-black on light ones, `ledOff` = a grey 20% lighter than `bed`.
- Store themes in the App Group so the app and the AUv3 share them.

## 7. Type

Chakra Petch (hardware legends), DM Sans (app UI), Unbounded (sheet titles), DM Mono (hex values). See
`tokens.json` → fonts. All OFL; bundle them.

## 8. Accessibility

- Every control is a real button with a VoiceOver label (the canvas's `aria-label`s: "Master knob", "Octave down",
  "C sharp 4", "Step 5, on, playing", "Open controls, or swipe down", …). Swipe gestures need button equivalents
  (the page dots, the two segmented switches, the sheet's View tiles).
- Text contrast is 4.5:1 or more in all five themes (that's why legends stay light and PLAY/REC carry color in
  glyphs).
- Touch targets: 44pt minimum. Close to the limit: OCT buttons in iPhone landscape (~42pt) and the MAIN | KN 1–4
  switch (32pt tall): give them a larger invisible hit area.

## 9. Not designed yet

- The "panel in use by another instance" state (PLAN.md section 4) and the "Use this FM-1" action. Suggested:
  the status chip turns into `FM-1 in use` with a button in the sheet's Sound source card.
- The Bluetooth pairing flow (`RFMKit/UI/BluetoothSheet.swift`); suggested: from the FM-1 card in the sheet.
- The core picker behind *Firmware*, and MIDI & audio / Settings screens.
- iPad Split View and Stage Manager sizes, and the AUv3 view (see 4).
