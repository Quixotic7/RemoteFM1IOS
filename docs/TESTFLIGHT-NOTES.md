# TestFlight "What to Test" notes

How the owner writes the notes testers see with each build (from the owner's own edit of build 15's notes,
2026-10-31). Use this for every new build.

## Style

- **One developer, first person singular.** "Let me know", "Tell me", "I review it". Never "we", "us", "our team".
- **Open with thanks and the build's headline** in one or two plain sentences ("Thank you Testers for submitting
  Feedback! In this build ...").
- **Say feedback is anonymous**: the owner reads it but can't reply to anyone directly.
- **"New in build N"**: what changed for testers, each item starting with a bold-free short name, then how to reach it
  (the menu path: Settings › Firmware › ...) and what it does for them. Plain words, no internal names.
- **"Please try"**: a short numbered list of the things worth testing, each asking for the detail that helps
  ("Let me know which firmware you tried").
- **End** with one line asking for reports of anything that doesn't work as expected.
- Only what testers can see in the TestFlight (store) build: its four built-in firmwares are FIZZ, Saadet, Boardwalk
  and LOOM-8; others come from Get firmware.

## Example (build 15, as the owner sent it)

```
Thank you Testers for submitting Feedback! In this build we can now manage save states and use the Firmware's own
device managers through the app.

The feedback you submit is very helpful, I review it but be aware your feedback is anonymous so I cannot respond
directly to you.

New in build 14:
- Firmware managers inside the app: Felucca, JIANT, GHOULBOX, ChoralRoot and Melodee have their own web managers for
  presets and backups. Download one of them from Settings › Firmware › Get firmware, play it, then choose Firmware ›
  Open its manager. The manager opens inside RemoteFM1 and talks to the firmware running in the app; no computer
  needed.
- Safer updates:
  - Updating a firmware from Get firmware keeps the previous version, so you can switch back if the new one doesn't
    read your saves.
  - If a firmware starts with an empty memory after an update, RemoteFM1 offers to put your old memory back.
  - Loading a saved state made with a different version now warns you first.
- Melodee 1.5.1 is in Get firmware: Kerem Kilic's latest release, with all of its engines and presets.

Please try

1. Open a firmware's manager and back up or load presets. Tell me if it says "not connected" or a transfer stalls.
   Let me know which firmware you tried
2. Update a firmware, then load a state you saved with the old version.

Please report anything that doesn't save, load or connect as expected.
```
