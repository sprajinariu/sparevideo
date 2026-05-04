# Source clips

Stabilized 320×240 / 15 fps masters consumed by `make demo-real-<name>`.
Pre-trimmed and stabilized so the existing OpenCV loader can ingest them
directly — the motion-detection RTL assumes a fixed camera, and raw clips
almost always have sub-pixel tripod sway / autofocus jitter that would
otherwise produce global motion masks.

Raw downloads are kept locally in `media/source_raw/` (gitignored). They are
re-derivable from the source URLs below.

## Naming convention

`<scenario>-<W>x<H>.mp4`. Scenario is a short name (`intersection`, `birdseye`,
`people`, …) that also forms the published WebP filename in
`media/demo/<scenario>.webp`. The list of currently-built clips is
`REAL_SOURCES` in the root `Makefile`.

## Adding or replacing a clip

1. Drop the raw download into `media/source_raw/`.
2. Pick a window with interesting motion. Preview by running
   `python -m demo.stabilize` directly with different `--start` values into
   `/tmp/preview.mp4`.
3. Once happy, run:
   ```bash
   make demo-prepare SRC=media/source_raw/<raw>.mp4 NAME=<scenario> \
                     START=<sec> DURATION=<sec>
   ```
   Output: `media/source/<scenario>-320x240.mp4`.
4. If the scenario is new, append it to `REAL_SOURCES` in the root `Makefile`.
   If the master is shorter than `DEMO_EXP_FRAMES` (default 150 = 10 s), also
   set a `DEMO_EXP_FRAMES_<scenario>` override in the Makefile so EXP-mode
   demos use the actual frame count.
5. Record the prep command in this README under "Clips" below.
6. Regenerate WebPs: `make demo-real-<scenario>` then `make demo-publish`.
7. Commit the new master MP4, the README update, the regenerated WebP, and
   any `Makefile` change in one logical commit.

## Stabilization

`py/demo/stabilize.py` runs in two passes:
- **Pass 1** — KLT feature tracking against frame 0 (anchor) + 4-DOF similarity
  warp (`cv2.estimateAffinePartial2D` — translation + rotation + uniform scale).
- **Safe-rect crop** — intersect each frame's valid-pixel region (where the
  warp draws from real source pixels) and find the largest axis-aligned
  rectangle inside the intersection. Eliminates edge artifacts on clips with
  significant rotation (drone footage, etc.).
- **Pass 2** — re-warp each frame with `BORDER_CONSTANT(0)`, crop to the safe
  rect, resize to 320×240. Final output has clean edges.

## Clips

### `intersection-320x240.mp4`

- **Description:** Intersection fixed camera (cars + pedestrians).
- **Source:** https://www.pexels.com/video/traffic-flow-in-an-intersection-4791734/
- **License:** Pexels License — free for commercial and non-commercial use,
  modification and redistribution permitted, no attribution required.
  See https://www.pexels.com/license/.
- **Prep command:**
  ```bash
  make demo-prepare SRC=media/source_raw/intersection.mp4 NAME=intersection \
                    START=0 DURATION=10
  ```

### `birdseye-320x240.mp4`

- **Description:** Aerial drone view of Lagos roads and a footbridge
  (cars, motorbikes, pedestrians at street scale).
- **Source:** https://www.pexels.com/video/aerial-view-of-lagos-busy-roads-and-footbridge-31661063/
- **License:** Pexels License (see above).
- **Prep command:**
  ```bash
  make demo-prepare SRC=media/source_raw/birdseye.mp4 NAME=birdseye \
                    START=0 DURATION=10
  ```

### `people-320x240.mp4`

- **Description:** Black-and-white footage of pedestrians walking.
  The 5-second window covers the first continuous shot before a scene cut
  in the source clip.
- **Source:** https://www.pexels.com/video/black-and-white-video-of-people-853889/
- **License:** Pexels License (see above).
- **Prep command:**
  ```bash
  make demo-prepare SRC=media/source_raw/people.mp4 NAME=people \
                    START=0 DURATION=5
  ```
