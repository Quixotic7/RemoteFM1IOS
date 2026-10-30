# Test fixtures

- `amb-1.3.rfm1` (214,629 bytes, SHA-256 ccacdb2801a8ac39aa86128f1650b071775c4fa131446011189f77a34961f053): AMB-1 1.3
  (Charles Vestal, MPL-2.0, source https://github.com/charlesvestal/fm1-amb@188b0a42f20a547864e732ae5ea1339d0fbcf395)
  as an .rfm1 file (docs/RFM1-FORMAT.md), built by FM1VST's `fm1_add_rfm1` on its branch `rfm1-target` at d5f8f64
  (`build-rfm1/rfm1/amb-1.3.rfm1`, emcc 6.0.13), unchanged. Its licence sections carry the texts that apply to it:
  MPL-2.0 and AMB-1's LICENSING.md for the firmware, GPL-3.0-only for FM1VST's core glue, MIT for the Emscripten
  runtime and musl. WasmTests boots, plays and checks it.
- `RemoteFM1/remote-0.2.3.fwsc` (611,496 bytes, SHA-256 211f06f63e8ca09de2812c017db9bb229713ce8e5a102eba887031551b2b403c):
  RemoteFM1 0.2.3's default package (MPL-2.0, https://github.com/Quixotic7/RemoteFM1 tag v0.2.3), downloaded unchanged
  from https://remotefm1.com/installer/firmware/remote-0.2.3.fwsc on 2026-10-29; it installs as `FM-1_52000203`.
  `RemoteFM1/releases.json`: https://remotefm1.com/installer/releases.json as it was that day (0.2.3 the newest).
  FirmwareInstallTests check both and install the package on FM1Kit's SimulatedFM1.
