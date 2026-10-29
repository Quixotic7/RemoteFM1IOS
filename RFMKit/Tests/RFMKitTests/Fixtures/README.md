# Test fixtures

- `amb-1.3.rfm1` (214,629 bytes, SHA-256 ccacdb2801a8ac39aa86128f1650b071775c4fa131446011189f77a34961f053): AMB-1 1.3
  (Charles Vestal, MPL-2.0, source https://github.com/charlesvestal/fm1-amb@188b0a42f20a547864e732ae5ea1339d0fbcf395)
  as an .rfm1 file (docs/RFM1-FORMAT.md), built by FM1VST's `fm1_add_rfm1` on its branch `rfm1-target` at d5f8f64
  (`build-rfm1/rfm1/amb-1.3.rfm1`, emcc 6.0.13), unchanged. Its licence sections carry the texts that apply to it:
  MPL-2.0 and AMB-1's LICENSING.md for the firmware, GPL-3.0-only for FM1VST's core glue, MIT for the Emscripten
  runtime and musl. WasmTests boots, plays and checks it.
