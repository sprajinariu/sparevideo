# Multi-source real demos + experimental backend — Design

**Date:** 2026-05-04
**Status:** Design — pending implementation plan.

## Problem

Today the README demo has one real-video source (`pexels-pedestrians-320x240.mp4`,
3 s) wired into a hardcoded `make demo-real` recipe. We want to:

1. Curate a small set of **real demo clips** (~3–5 over time), starting with three
   (intersection + birdseye + people, matching the three raws already staged in
   `media/source_raw/`), with low friction to add more.
2. Be able to **prototype new clips quickly** without paying the Verilator
   compile + simulate cost on every iteration. The Python reference models in
   `py/models/` are bit-accurate to the RTL, so they make a perfect fast
   backend for clip-vetting.
3. **Standardize the prep step** for new clips (download → trim → stabilize →
   resize) into a single Make target so it doesn't drift across `media/source/README.md`
   recipes.
4. Allow **longer clips during experimentation** while keeping the published
   WebPs short enough that the README renders smoothly on github.com.

## Out of scope

- Adding more synthetic patterns. Only real-source demos change here.
- Changing the WebP triptych layout, fps, or panel ordering.
- Changing the algorithm profile used for demos (`CFG=demo` stays).
- Repo size beyond the ~1.5 MB this design adds. If we ever curate ≥10 clips,
  Git LFS becomes a separate conversation.

## Directory layout

```
media/
  source_raw/                 # NEW. Gitignored. Raw downloads (1080p,
                              # untrimmed) staged here before stabilization.
  source/                     # Committed. Stabilized 320x240 masters, 10 s.
    intersection-320x240.mp4  # RENAMED from pexels-pedestrians-320x240.mp4
    birdseye-320x240.mp4      # NEW (from media/source_raw/birdseye.mp4)
    people-320x240.mp4        # NEW (from media/source_raw/people.mp4)
    README.md                 # Updated with new clips + new naming convention
  demo-draft/                 # Gitignored. RTL-backend output. Publishable.
  demo-draft-exp/             # NEW. Gitignored. Model-backend output.
                              # NOT publishable (demo-publish never reads here).
  demo/                       # Committed. README-referenced final WebPs.
    synthetic.webp
    intersection.webp         # was real.webp
    birdseye.webp             # NEW
    people.webp               # NEW
```

`media/source_raw/` is added to `.gitignore`. Raw downloads (the three
already staged — `intersection.mp4`, `birdseye.mp4`, `people.mp4` — plus any
future ones) live there. Any `*-Zone.Identifier` WSL artifacts get deleted.

## Make interface

### Variables

```
REAL_SOURCES         ?= intersection birdseye people
DEMO_PUBLISH_FRAMES  ?= 45        # 3 s @ 15 fps  → README WebPs
DEMO_EXP_FRAMES      ?= 150       # 10 s @ 15 fps → full master, EXP runs
DEMO_FPS             ?= 15
DEMO_WIDTH           ?= 320
DEMO_HEIGHT          ?= 240
EXP                  ?= 0
```

`EXP=1` resolves three derived variables once at the top of the demo block:

| EXP=0 (default)               | EXP=1                               |
|-------------------------------|-------------------------------------|
| `DEMO_BACKEND := rtl`         | `DEMO_BACKEND := model`             |
| `DEMO_FRAMES := $(PUBLISH_…)` | `DEMO_FRAMES := $(EXP_…)`           |
| `DEMO_DRAFT_DIR := demo-draft`| `DEMO_DRAFT_DIR := demo-draft-exp`  |

Because every demo recipe consumes those three variables, `EXP=1` applies
uniformly to `demo`, `demo-synthetic`, `demo-real`, and any `demo-real-<name>`.

### Targets

| Target                     | What it does                                                        |
|----------------------------|---------------------------------------------------------------------|
| `demo`                     | `demo-synthetic` + `demo-real` (unchanged aggregator)               |
| `demo-synthetic`           | Existing recipe; respects `EXP=1` via `DEMO_BACKEND`                |
| `demo-real`                | `$(REAL_SOURCES:%=demo-real-%)` — loops over the list               |
| `demo-real-%`              | Pattern rule. Source = `media/source/$*-320x240.mp4`                |
| `demo-publish`             | Unchanged. Reads `media/demo-draft/` only — EXP runs are unpublishable by construction |
| `demo-prepare` (NEW)       | Wraps `python -m demo.stabilize` (see below)                        |

### `demo-prepare`

Generic thin wrapper. Required `SRC` and `NAME`; defaults for the rest:

```
make demo-prepare SRC=media/source_raw/birdseye.mp4 NAME=birdseye
make demo-prepare SRC=media/source_raw/intersection.mp4 NAME=intersection START=0 DURATION=10
```

| Var      | Default | Notes                                                  |
|----------|---------|--------------------------------------------------------|
| `SRC`    | (req'd) | Path to raw download                                   |
| `NAME`   | (req'd) | Short scenario name; output is `<NAME>-<W>x<H>.mp4`    |
| `START`  | `0`     | Seconds into the source                                |
| `DURATION` | `10`  | Seconds to keep                                        |
| `WIDTH`  | `320`   | Inherited from `DEMO_WIDTH`                            |
| `HEIGHT` | `240`   | Inherited from `DEMO_HEIGHT`                           |
| `FPS`    | `15`    | Inherited from `DEMO_FPS`                              |

Errors out with a usage hint if `SRC` or `NAME` is missing. Per-clip invocation
is recorded under `media/source/README.md` — same convention as today.

## Backend dispatch

When `DEMO_BACKEND=rtl`, the recipe is unchanged: `make compile` + `make sim`
for each of the two ctrl-flows (`ccl_bbox`, `motion`), copying
`dv/data/output.bin` to `dv/data/output_<flow>.bin` between runs.

When `DEMO_BACKEND=model`, the `compile`+`sim` pair is replaced with a Python
invocation that runs the existing reference model and writes its output to
`dv/data/output.bin` in the same binary format the RTL produces:

```
$(VENV_PY) -m harness model --input dv/data/input.bin \
    --output dv/data/output.bin \
    --width $(DEMO_WIDTH) --height $(DEMO_HEIGHT) --frames $(DEMO_FRAMES) \
    --ctrl-flow <flow> --cfg demo
```

This requires a small extension to `py/harness.py`: a new `model` subcommand
that wraps `run_model(ctrl_flow, frames)` and serializes the result with the
existing binary writer in `py/frames/frame_io.py`. Implementation cost: ~30
lines, no new logic — the model and the binary writer both exist today; the
subcommand is plumbing.

The downstream `python -m demo …` step that builds the WebP triptych is
backend-agnostic — it just consumes `dv/data/input.bin`,
`dv/data/output_ccl_bbox.bin`, and `dv/data/output_motion.bin` regardless of
which backend produced them.

## Length policy

A single stabilized master per source, **always 10 s** (`DEMO_EXP_FRAMES`).

- `make demo-real-<name>` (default, RTL) consumes the first 45 frames (3 s).
  This is what ships in `media/demo/<name>.webp` and is referenced from the
  README. Short enough that github.com renders it smoothly.
- `make demo-real-<name> EXP=1` (model) consumes all 150 frames (10 s). Stays
  in `media/demo-draft-exp/`, useful for vetting whether a clip's motion is
  interesting throughout its full window.

If a clip needs a different "interesting window," the answer is to re-run
`make demo-prepare` with a different `START` (cheap, seconds), not to add
per-clip frame budgets. The master *is* the interesting window.

## Stabilization model — already adequate

`py/demo/stabilize.py` uses `cv2.estimateAffinePartial2D`, a 4-DOF similarity
transform: rotation + uniform scale + translation. This already absorbs the
small rotations and breathing zoom typical of fixed-camera Pexels footage. No
change needed in this design.

## Rollout / migration

One-time work this design implies, in order:

1. Add `media/source_raw/` to `.gitignore`. Raw downloads
   (`intersection.mp4`, `birdseye.mp4`, `people.mp4`) are already staged
   there; any `*:Zone.Identifier` WSL artifacts get deleted (Windows
   zone-of-origin metadata, not videos).
2. `git mv media/source/pexels-pedestrians-320x240.mp4
   media/source/intersection-320x240.mp4`.
3. Re-stabilize `intersection` from `media/source_raw/intersection.mp4` at
   10 s (currently 3 s).
4. Stabilize `birdseye` from `media/source_raw/birdseye.mp4` and `people`
   from `media/source_raw/people.mp4`.
5. Add the `model` subcommand to `py/harness.py`.
6. Rewrite the demo block in the root `Makefile` per §"Make interface".
7. Update `media/source/README.md`: rename section, document all three
   real clips (intersection, birdseye, people), and replace the inline
   stabilize invocations with a "use `make demo-prepare`" pointer
   (keeping per-clip args in a recipe table).
8. Update root `README.md`: rename the `real.webp` reference to
   `intersection.webp`, add `birdseye.webp` and `people.webp` rows.
9. Regenerate WebPs: `make demo` then `make demo-publish`. Commit the four
   regenerated `media/demo/*.webp` files.

## Tradeoffs accepted

- **Repo grows by ~2.5 MB** — `intersection-320x240.mp4` goes 240 KB →
  ~700 KB (3 s → 10 s); `birdseye-320x240.mp4` and `people-320x240.mp4`
  add ~700 KB each. Fine for a project this size; revisit if curated set
  hits ≥10 clips.
- **Publish vs experimental are length-coupled by default.** A clip cannot be
  published at 10 s without bumping `DEMO_PUBLISH_FRAMES`. Acceptable: the
  README readability constraint is the governing requirement.
- **`demo-publish` cannot publish EXP runs** — by directory isolation, not
  flag-checking. Robust by construction; impossible to ship a model-backed
  WebP by accident.
- **`make demo` total RTL runtime grows** roughly with `len(REAL_SOURCES)`.
  At 3 real sources + 1 synthetic × 2 ctrl-flows × ~2 min/sim that's ~15–25
  min wall-clock. Adding source #5+ is a deliberate act, so the cost is
  visible.
- **Python `model` subcommand is a small new public CLI surface** in
  `harness.py`. Acceptable: it's symmetric with the existing `verify` /
  `prepare` / `render` subcommands and the implementation is plumbing.
