# The .rfm1state file (RemoteFM1 for iOS, PLAN.md section 18 step 3)

One named firmware state in one file: UTI `com.quixotic7.remotefm1.state`, extension `.rfm1state`
(`RFMKit/Sources/RFMKit/StateFile.swift`).

| offset | size | contents |
|---|---|---|
| 0 | 8 | ASCII `RFM1STAT` |
| 8 | 4 | N, the manifest's length, UInt32 little-endian (1 … 1 MiB) |
| 12 | N | the manifest, UTF-8 JSON |
| 12+N | `flashBytes` | the flash, as `flashEncoding` says |

The manifest: `format` (1; a larger number is refused: "made by a newer RemoteFM1"), `flashEncoding` (`lzfse`, Apple's
LZFSE as `NSData.compressed(using: .lzfse)`, or `none`), `flashBytes` (as stored), and `state`, the library's
SavedState: `id`, `name`, `note`, `firmwareID`, `firmwareName`, `kind` (native | wasm), `version`, `sha256` (the
.rfm1's, "" for a built-in core), `date` (seconds since 1970), `flashSize` and `flashSHA256` (the uncompressed flash),
`master` (0…1023), `transpose`, `keyTouch`, `origin` (app | au | backup | safety copy). Unknown keys are ignored.

A reader refuses, in plain words: no magic ("isn't a RemoteFM1 state file"), a file shorter than its lengths say
("cut short"), an unreadable manifest, or a flash whose decompressed size or SHA-256 isn't the manifest's ("damaged").

Importing never overwrites: a state whose flash (by SHA-256) is already in the library for that firmware is skipped;
an id already taken gets a new one.

A backup (Settings › Back up everything) is a folder `Documents/Backups/RemoteFM1 backup <yyyy-MM-dd HHmm>/`:
`States/<Firmware>/<name>.rfm1state`, `Current/<Firmware> current.rfm1state` (each firmware's memory at the backup),
`Safety copies/<Firmware>/…` (the newest 3 per firmware), `manifest.json` (format, date, app version, each file with
its name, firmware id, version, date, flash SHA-256) and `README.txt`. Restore imports `States` and `Current`.
