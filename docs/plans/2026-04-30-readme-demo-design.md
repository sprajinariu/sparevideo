# README Demo — Animated WebP Triptych

**Status:** Design (brainstorming output)
**Date:** 2026-04-30

## 1. Goal

Show motion-detection results on the project's GitHub README so a visitor immediately sees what the hardware does without reading the spec table. Two looping animated clips, both rendered as 960×240 triptychs (Input | ccl_bbox | motion) at 320×240 per panel, ~3 s at 15 fps:

- **Synthetic** — colored multi-object pattern, fully reproducible.
- **Real** — short Pexels pedestrian clip, committed to the repo.

Both WebPs are committed under `media/demo/` and embedded in the README via standard markdown image syntax so they autoplay on github.com.

## 2. Non-goals

- GitHub Pages site (deferred — README embed first).
- MP4 fallback alongside WebP.
- Multi-control-flow grid (passthrough / mask shown together).
- Automated CI regeneration of demos on every merge.
- Truetype-font HUD overlays beyond the existing 8×8 bitmap font.

## 3. Repo layout

```
media/
├── source/
│   ├── README.md                          # source URL, license, ffmpeg trim/resize command
│   └── pexels-pedestrians-320x240.mp4     # pre-trimmed to ~3 s, pre-resized to 320x240, ~2-5 MB
└── demo/
    ├── synthetic.webp                     # 960x240, ~45 frames @ 15 fps
    └── real.webp                          # 960x240, ~45 frames @ 15 fps

py/demo/
├── __init__.py                            # exposes main() for `python -m py.demo`
├── compose.py                             # compose_triptych(input, ccl, motion) -> [PIL.Image]
└── encode.py                              # write_webp(frames, path, fps=15)

py/tests/
├── test_demo_compose.py                   # unit tests for compose_triptych
└── test_demo_encode.py                    # round-trip encode/decode test

py/frames/video_source.py                  # add _gen_multi_speed_color
py/profiles.py                             # add `demo` profile
hw/top/sparevideo_pkg.sv                   # add CFG_DEMO matching `demo` profile
dv/sim/Makefile                            # add demo, demo-synthetic, demo-real targets
README.md                                  # add Demo section + Regenerating subsection
CLAUDE.md                                  # add demo refresh to "TODO after each major change"
```

## 4. New synthetic source — `multi_speed_color`

Located in `py/frames/video_source.py`. Same three-box layout as the existing `multi_speed`:

- Box A — fast L→R along the top band, **red** (255, 80, 80).
- Box B — medium T→B along the vertical centreline, **green** (80, 220, 80).
- Box C — slow diagonal BL→TR, **cyan** (80, 220, 220).

Background: a tinted RGB textured field (low-amplitude per-channel sinusoid plus seeded per-frame noise). Frame 0 is background only; objects appear from frame 1 onward (matches the convention of every other moving-object synthetic source — frame 0 primes the EMA bg cleanly).

**Helper extensions required.** The existing `_place_object` only supports greyscale foreground (single `luma` int → R=G=B); `_make_bg_texture` only emits greyscale. Two minimal extensions:

- `_place_object` gains an optional `rgb=(R,G,B)` parameter that, when provided, overrides the greyscale `luma` path. Existing call sites (greyscale `multi_speed`, `two_boxes` proxies, etc.) keep working unchanged.
- `_make_bg_texture` gains an optional `tint=(R,G,B)` parameter that produces an RGB output by per-channel scaling of the existing sinusoid. When `tint` is `None`, the function returns a 2-D greyscale array as today (callers that `np.stack` it into RGB still work).

The existing greyscale `multi_speed` is left untouched so existing tests/profiles continue to compare against the same vectors.

Registered in the dispatch dict at line ~117 of `video_source.py` and listed in the README's synthetic-sources table.

## 5. New `demo` algorithm profile

Added to both `hw/top/sparevideo_pkg.sv` (as `CFG_DEMO`) and `py/profiles.py` (as `demo`). Identical to `default` except:

- `scaler_en = 0` — keeps each panel at native 320×240 so the triptych composes cleanly (no interpolation artifacts at panel boundaries).
- `hud_en = 1` — same as default; HUD remains visible on ccl_bbox/motion panels.

The existing parity test (`py/tests/test_profiles.py`) catches drift between SV and Python.

Rationale for a dedicated profile (rather than reusing `no_scaler`): self-documenting intent, decouples demo behavior from any future tweak to `no_scaler`'s purpose.

**Resolution stays at 320×240 end-to-end.** The synthetic generator emits 320×240, the OpenCV loader resizes the Pexels clip to 320×240, the RTL runs at 320×240 (scaler off), and the triptych composes at 320×240 per panel. No mid-pipeline resolution switch. Other make targets that use `CFG=default` keep running at 640×480 output; the demo profile is fully decoupled.

## 6. Triptych composer — `py/demo/compose.py`

```python
def compose_triptych(
    input_frames: list[np.ndarray],
    ccl_frames:   list[np.ndarray],
    motion_frames: list[np.ndarray],
) -> list[PIL.Image.Image]:
    """Build per-frame 960x240 triptychs.

    All three input streams must be 320x240 RGB888 with identical frame counts.
    Output frames are PIL Images; panels abut directly (no separator column).
    A panel label ("INPUT" / "CCL_BBOX" / "MOTION") is rendered in the top-right
    corner of each panel using the existing 8x8 bitmap font
    (py/models/ops/hud_font.py) so the label style matches the on-output HUD
    without pulling in PIL truetype.
    """
```

**Layout per output frame (960×240, panels abut directly):**

```
+---------+---------+---------+
| INPUT   |CCL_BBOX | MOTION  |   <- panel labels in top-right of each panel
| (320x   |(320x    |(320x    |
|  240)   | 240)    | 240)    |
|         |         |         |
+---------+---------+---------+
   x=0..319  320..639 640..959
```

The HUD on the ccl_bbox/motion outputs is already at top-left coord (8, 8) from the RTL. Panel labels go in the top-right (right-edge minus label width minus 8 px, top + 8 px) so they don't overlap. Panels abut cleanly with no separator — labels and HUD positioning provide enough visual segmentation.

**Frame-count contract:** all three input streams must have exactly 45 frames. The composer asserts this at entry; mismatch is a programming error, not user input.

## 7. WebP encoder — `py/demo/encode.py`

```python
def write_webp(frames: list[PIL.Image.Image], path: Path, fps: int = 15) -> None:
    frames[0].save(
        path, save_all=True, append_images=frames[1:],
        duration=int(1000 / fps), loop=0,           # loop=0 → infinite loop
        lossless=False, quality=80, method=6,       # quality/speed balance
    )
```

Pillow ≥ 9 supports animated WebP natively. Pillow is already in `requirements.txt`. Expected file sizes for 45 frames @ 960×240, quality 80: 1–4 MB depending on motion complexity.

## 8. CLI entry point — `python -m py.demo`

```
python -m py.demo \
    --input  dv/data/input.bin \
    --ccl    dv/data/output_ccl_bbox.bin \
    --motion dv/data/output_motion.bin \
    --out    media/demo/<name>.webp \
    --fps    15
```

Reads three binary frame files (12-byte header + raw RGB), composes triptychs, encodes WebP. Pure I/O wrapper; logic lives in `compose.py` / `encode.py`.

## 9. Make targets

Added to `dv/sim/Makefile`:

```make
demo: demo-synthetic demo-real

demo-synthetic:
    $(MAKE) prepare SOURCE=synthetic:multi_speed_color WIDTH=320 HEIGHT=240 FRAMES=45 MODE=binary CFG=demo
    $(MAKE) compile CTRL_FLOW=ccl_bbox CFG=demo
    $(MAKE) sim     CTRL_FLOW=ccl_bbox CFG=demo
    cp dv/data/output.bin dv/data/output_ccl_bbox.bin
    $(MAKE) compile CTRL_FLOW=motion CFG=demo
    $(MAKE) sim     CTRL_FLOW=motion CFG=demo
    cp dv/data/output.bin dv/data/output_motion.bin
    python -m py.demo --input dv/data/input.bin \
                      --ccl   dv/data/output_ccl_bbox.bin \
                      --motion dv/data/output_motion.bin \
                      --out   media/demo/synthetic.webp

demo-real:
    $(MAKE) prepare SOURCE=media/source/pexels-pedestrians-320x240.mp4 \
                    WIDTH=320 HEIGHT=240 FRAMES=45 MODE=binary CFG=demo
    # ... same compile/sim/compose pattern with --out media/demo/real.webp
```

Wall-clock estimate: each demo runs sim twice on 45 frames at 320×240, ~2 min total. Compose + encode is ~1 s.

## 10. Real-clip preprocessing

The committed `media/source/pexels-pedestrians-320x240.mp4` is produced once by hand:

```bash
# Pick a clip with a fixed-camera top-down or wide pedestrian view, ~5-10 s long
ffmpeg -ss <start> -t 3 -i pexels-original.mp4 \
       -vf "crop=...,scale=320:240" -r 15 -c:v libx264 -an \
       media/source/pexels-pedestrians-320x240.mp4
```

The exact ffmpeg command and the source URL / license go into `media/source/README.md`. No prep code lives in the repo — the existing OpenCV loader (`py/frames/video_source.py`) handles the committed MP4 unchanged.

If the source is later swapped, the workflow is `git rm` the old file, drop the new one in, regenerate `real.webp`, commit. Old git history retains the old MP4 indefinitely; for a personal project with infrequent swaps the bloat is negligible.

## 11. README integration

New **Demo** section inserted near the top, just after the project description (line ~7, before the architecture-spec table):

```markdown
## Demo

### Synthetic input (`multi_speed_color`)

![Synthetic demo](media/demo/synthetic.webp)

Three colored objects with distinct speeds and trajectories. Left to right:
input frames, `ccl_bbox` (mask-as-grey + CCL bboxes), `motion` (full overlay).

### Real video (Pexels pedestrians)

![Real demo](media/demo/real.webp)

Top-down pedestrian crossing, 3 s clip from Pexels (CC0).
Same triptych layout. Source: `media/source/pexels-pedestrians-320x240.mp4`.
```

A new **Regenerating the demo** subsection under the existing "Usage":

```markdown
### Regenerating the demo

After RTL changes that affect visual output, rebuild the demos:

\`\`\`bash
make demo                           # regenerates both WebPs
wslview media/demo/synthetic.webp   # preview in default browser (WSL via WSLg)
grip README.md                      # preview README at GitHub fidelity
\`\`\`

`grip` is an optional dev tool (`pip install grip`) that renders local
markdown using GitHub's API — useful for confirming the README looks right
before pushing.
```

## 12. CLAUDE.md addition

To the existing **TODO after each major change** list:

> - Regenerate demo WebPs (`make demo`) if RTL changes affected the visual output, and commit them with the change.

Putting it on the checklist ensures future plans don't ship with stale README demos.

## 13. Tests

- **`py/tests/test_demo_compose.py`** — unit tests for `compose_triptych`. Construct three 8×8 RGB streams with deterministic content; assert (a) output dims = `3*W + 2 × H`, (b) each panel's RGB content matches the corresponding source stream, (c) panel labels render at expected pixel coords in the top-right of each panel.
- **`py/tests/test_demo_encode.py`** — round-trip test. Encode 3 small dummy frames to a tmp WebP, decode with PIL, assert frame count and per-frame dimensions match.

`make test-py` picks these up automatically (it globs `py/tests/test_*.py`).

## 14. Preview workflow

Before committing regenerated WebPs:

- `wslview media/demo/<name>.webp` opens the WebP in the default Windows browser via WSLg. Animation plays at intended fps.
- Alternatively `firefox media/demo/<name>.webp` if Firefox is installed in WSL.
- `grip README.md` renders the README locally at GitHub fidelity.
- `du -h media/demo/*.webp` confirms each file is under ~5 MB.
- `webpinfo media/demo/<name>.webp` (from the `webp` system package, optional) reports frame count, dimensions, animation-loop flag for sanity checks.

VS Code's image preview is unreliable for animated WebP; prefer the browser path.

## 15. File-size budget

| File | Expected size | Hard ceiling |
|---|---|---|
| `media/source/pexels-pedestrians-320x240.mp4` | 2–5 MB | 50 MB (GitHub warning) |
| `media/demo/synthetic.webp` | 1–3 MB | 5 MB |
| `media/demo/real.webp` | 1–4 MB | 5 MB |

If a demo WebP exceeds ~5 MB, drop encoder `quality` (default 80) to 70 or 60 before considering layout changes.

## 16. Human-review checkpoints

The implementation plan turns each of these into an explicit "STOP, show user, wait for sign-off" gate. Six checkpoints, ordered by build sequence:

**CP-1. New synthetic source — visual sanity.** After `multi_speed_color` is implemented and `_place_object` / `_make_bg_texture` extended:
```bash
make prepare SOURCE=synthetic:multi_speed_color WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary CFG=default
make render
```
User opens the resulting comparison-grid PNG in `renders/` and confirms: three colored boxes visible against a tinted textured background, distinct trajectories, frame 0 is bg-only. *Catches: wrong colors, palette clash with bg tint, off-screen boxes, broken alpha falloff.*

**CP-2. `demo` profile end-to-end on existing render.** After `CFG_DEMO` / `demo` profile added:
```bash
make run-pipeline CFG=demo CTRL_FLOW=motion SOURCE=synthetic:multi_speed_color FRAMES=8
```
Standard `make render` PNG; user confirms HUD is visible at 320×240 native, no scaler artifacts, no profile-parity test failures. *Catches: profile field mismatch between SV and Python, HUD positioning broken at native res.*

**CP-3. First composed triptych frame — static PNG.** After `compose.py` is implemented but before WebP encoding is wired up: a temporary debug path saves frame 22 (mid-clip) of the composed triptych as a PNG. User opens it locally and confirms layout, panel labels, no overlap with HUD, no off-by-one cropping. *Catches: column-stride math errors, label/HUD collision, wrong panel ordering.*

**CP-4. First synthetic WebP.** After `encode.py` and the `make demo-synthetic` chain are working:
```bash
make demo-synthetic
wslview media/demo/synthetic.webp
du -h media/demo/synthetic.webp
```
User confirms: animation plays smoothly at 15 fps, three colored objects tracked, file size <5 MB. *Catches: WebP not actually animating, wrong fps, file too large, frame-order bug.*

**CP-5. Pexels source clip prepared.** After the source MP4 is trimmed/resized via ffmpeg and committed:
```bash
wslview media/source/pexels-pedestrians-320x240.mp4
```
User plays the raw committed source clip and confirms: ~3 s, 320×240, fixed camera, multiple visible moving objects, motion is appropriate-scale for the resolution. *Catches: bad clip selection (camera pan, not enough motion, too-small subjects at 320×240), wrong trim window, audio still attached.*

**CP-6. First real WebP + README integration.** After `make demo-real` works and the README is updated:
```bash
make demo-real
wslview media/demo/real.webp
grip README.md          # opens localhost:6419
```
User confirms in browser: real demo plays correctly, both demos are embedded in the README at expected positions, page reads well as a top-of-README hero. *Catches: README markdown wrong, image paths wrong, layout regressions, real-clip motion detection visibly broken (e.g., walkers not getting bboxes).*

Sign-off at each checkpoint is required before the implementation plan proceeds to the next step.

## 17. Out of scope / future extensions

- **4th panel for a new control flow** — would extend `compose_triptych` to take an arbitrary number of streams and produce an N-wide grid. Trivial extension when needed.
- **GitHub Pages gallery** — separate plan; reuses `compose.py` + `encode.py` as building blocks.
- **CI auto-regeneration** — would require Verilator + Pillow + ffmpeg in CI, ~2 min per merge. Manual refresh on relevant changes is sufficient at this project's pace.
- **MP4 fallback** — if browser support for animated WebP regresses or rendered files balloon, encode an MP4 alongside the WebP and embed via `<video>`. Costs autoplay-on-scroll behavior on github.com.
