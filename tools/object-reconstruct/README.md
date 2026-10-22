# object-reconstruct

Builds a full-detail model on the Mac from an object captured with the House Capture app (shared as a zip or copied as a folder).

```sh
npm run object -- <zip-or-folder> [--detail full|medium|reduced|raw] [--no-masks]
```

- Zips are unpacked with `ditto`; the tool uses the shallowest folder containing `object.json`.
- `kind: "guided"` (or missing): reconstructs from `Images/`, reusing the phone's `Checkpoint/` when present.
- `kind: "turntable"`: feeds `Turntable/NNNN.jpg` with `NNNN-mask.png` as the object mask (`--no-masks` drops them), unordered samples, high feature sensitivity.
- Default detail is `full`. Needs macOS 14+ on Apple silicon.

Outputs (both gitignored):

- `data/objects/<id>/model-full.usdz`: AirDrop it back to the phone to replace the on-device model.
- `data/web-assets/objects/<id>/`: `model/` (OBJ + MTL + textures), `model.usdz`, and `manifest.json` (paths relative to this folder). `data/web-assets/objects/index.json` lists every built object, newest first.
