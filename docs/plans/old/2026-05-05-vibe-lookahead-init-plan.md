# ViBe Look-Ahead Median Init — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Python-only experiment that seeds the ViBe sample bank using a temporal-median over a look-ahead window, and measure whether this kills the canonical frame-0 ghost on synthetic + real demo clips.

**Architecture:** A new `init_from_frames` method on `ViBe` computes a per-pixel temporal median over the first N frames and routes it through the existing init-scheme noise routine. A standalone experiment script (`run_lookahead_init.py`) sweeps three init modes (`init_frame0`, `init_lookahead_n20`, `init_lookahead_full`) on five sources and emits coverage curves + comparison grids. A second, conditional follow-up script validates the winning mode through the production motion pipeline (gauss → ViBe → morph_open → morph_close) on three real clips.

**Tech Stack:** Python 3.12 in `.venv/`, NumPy, SciPy (already in use via `py/models/ops/morph_*.py`), matplotlib (existing `py/experiments/render.py`), Pillow. No SystemVerilog changes. No cross-language interaction.

**Spec:** [`2026-05-05-vibe-lookahead-init-design.md`](2026-05-05-vibe-lookahead-init-design.md)

**Branch:** `feat/vibe-lookahead-init` (already created, based on `feat/vibe-motion-design` per the spec's branch-dependency note).

---

## File Structure

**New files:**

- `py/experiments/run_lookahead_init.py` — Headline experiment driver. Loads frames, runs three init modes per source on raw ViBe, emits per-source coverage curves + grids.
- `py/experiments/run_lookahead_init_pipeline.py` — *(conditional, Task 5)* Follow-up validation driver. Runs the winning mode through gauss + morph_open + morph_close on the three real clips.
- `docs/plans/2026-05-05-vibe-lookahead-init-results.md` — *(Task 6)* Hand-written results doc, mirrors the format of [`2026-05-04-vibe-phase-0-results.md`](2026-05-04-vibe-phase-0-results.md).

**Modified files:**

- `py/experiments/motion_vibe.py` — Add `init_from_frames(frames, lookahead_n)` method. No other changes.
- `py/tests/test_motion_vibe.py` — Append two new tests at end of file. No edits to existing tests.
- *(Conditional, Task 7)* `docs/plans/2026-05-01-vibe-motion-design.md` — Add `bg_init_mode` / `bg_init_lookahead_n` to the Phase-1+ control-knob list, OR add a brief note explaining why the knob is not adopted, depending on results.

**Generated (gitignored):**

- `py/experiments/our_outputs/lookahead_init/<source>/{coverage.png, grid.png}` — five sources × three init modes from headline run.
- `py/experiments/our_outputs/lookahead_init_pipeline/<source>/{coverage.png, grid.png}` — *(conditional)* three real-clip sources × two init modes from follow-up run.

---

## Task 1: Add `init_from_frames` method to ViBe (TDD)

**Files:**
- Modify: `py/experiments/motion_vibe.py` (append new method to `ViBe` class)
- Modify: `py/tests/test_motion_vibe.py` (append two new tests at end of file)

- [ ] **Step 1: Write the first failing test** — single-frame equivalence

Append to the end of `py/tests/test_motion_vibe.py`:

```python
def test_init_from_frames_single_frame_matches_init_from_frame():
    """N=1 stack → median is the single frame → result must match init_from_frame."""
    frame = _y_frame(120, h=4, w=4)
    stack = frame[None, ...]  # (1, 4, 4) uint8

    a = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    a.init_from_frame(frame)

    b = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    b.init_from_frames(stack, lookahead_n=1)

    assert np.array_equal(a.samples, b.samples), \
        "init_from_frames(N=1) must produce identical bank to init_from_frame"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest py/tests/test_motion_vibe.py::test_init_from_frames_single_frame_matches_init_from_frame -v`

Expected: FAIL with `AttributeError: 'ViBe' object has no attribute 'init_from_frames'`.

- [ ] **Step 3: Implement `init_from_frames`**

In `py/experiments/motion_vibe.py`, append the following method to the `ViBe` class, immediately after `init_from_frame` (around line 84):

```python
    def init_from_frames(
        self,
        frames: np.ndarray,
        lookahead_n: Optional[int] = None,
    ) -> None:
        """Seed the sample bank from a temporal median over the first
        `lookahead_n` frames of `frames`. When `lookahead_n` is None, use
        all frames in the stack.

        Equivalent to `init_from_frame(median(frames[:lookahead_n], axis=0))`
        but routes through the configured init_scheme so noise structure
        and PRNG advance count match the canonical frame-0 path.

        Args:
            frames: (N, H, W) uint8 stack of Y frames, N >= 1.
            lookahead_n: number of leading frames to median over. None ⇒ all.
        """
        assert frames.ndim == 3 and frames.dtype == np.uint8, \
            "frames must be a (N, H, W) uint8 stack"
        n_total = frames.shape[0]
        assert n_total >= 1, "frames must have at least 1 frame"
        n = n_total if lookahead_n is None else int(lookahead_n)
        assert 1 <= n <= n_total, \
            f"lookahead_n={lookahead_n} out of range [1, {n_total}]"
        bg_est = np.median(frames[:n], axis=0).astype(np.uint8)
        # Reuse the configured init scheme to seed the bank around bg_est.
        self.init_from_frame(bg_est)
```

- [ ] **Step 4: Run the first test to verify it passes**

Run: `.venv/bin/python -m pytest py/tests/test_motion_vibe.py::test_init_from_frames_single_frame_matches_init_from_frame -v`

Expected: PASS.

- [ ] **Step 5: Add the second test** — median equivalence

Append to the end of `py/tests/test_motion_vibe.py` (after the test from Step 1):

```python
def test_init_from_frames_median_equivalence():
    """N>1 stack → init_from_frames must equal init_from_frame applied to
    the per-pixel median of the stack (with same seed/scheme)."""
    rng = np.random.default_rng(seed=42)
    stack = rng.integers(0, 256, size=(7, 6, 8), dtype=np.uint8)
    median = np.median(stack, axis=0).astype(np.uint8)

    a = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    a.init_from_frame(median)

    b = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    b.init_from_frames(stack, lookahead_n=None)  # use all 7 frames

    assert np.array_equal(a.samples, b.samples), \
        "init_from_frames(N=all) must match init_from_frame on the median"


def test_init_from_frames_partial_window():
    """lookahead_n < N uses only the first lookahead_n frames for the median."""
    # Frame 0..2 are filled with 100, frames 3..5 are filled with 200.
    # median over first 3 frames = 100, median over all 6 = ~150.
    f_lo = _y_frame(100, h=4, w=4)
    f_hi = _y_frame(200, h=4, w=4)
    stack = np.stack([f_lo, f_lo, f_lo, f_hi, f_hi, f_hi], axis=0)

    a = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    a.init_from_frame(_y_frame(100, h=4, w=4))

    b = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    b.init_from_frames(stack, lookahead_n=3)

    assert np.array_equal(a.samples, b.samples), \
        "init_from_frames(lookahead_n=3) must median over only frames[:3]"
```

(One extra test beyond the two named in the spec — `test_init_from_frames_partial_window` — locks the slicing contract so a future bug like `frames[:n_total]` instead of `frames[:n]` is caught.)

- [ ] **Step 6: Run the new tests to verify they pass**

Run: `.venv/bin/python -m pytest py/tests/test_motion_vibe.py -v -k "init_from_frames"`

Expected: 3 tests pass (`test_init_from_frames_single_frame_matches_init_from_frame`, `test_init_from_frames_median_equivalence`, `test_init_from_frames_partial_window`).

- [ ] **Step 7: Run the full motion_vibe test file to verify no regression**

Run: `.venv/bin/python -m pytest py/tests/test_motion_vibe.py -v`

Expected: 36 tests pass (33 existing + 3 new).

- [ ] **Step 8: Commit**

```bash
git add py/experiments/motion_vibe.py py/tests/test_motion_vibe.py
git commit -m "feat(experiments/vibe): add init_from_frames look-ahead median init

Adds a new ViBe init entry point that seeds the sample bank from the
per-pixel temporal median over the first lookahead_n frames, routed
through the configured init_scheme. Used by the upcoming look-ahead
init experiment; existing init_from_frame is unchanged.

Three new unit tests lock the dispatch contract:
- single-frame equivalence (N=1 must match init_from_frame)
- full-stack median equivalence
- partial-window slicing (lookahead_n < N uses only frames[:n])"
```

---

## Task 2: Headline experiment script

**Files:**
- Create: `py/experiments/run_lookahead_init.py`

- [ ] **Step 1: Create the script**

Write `py/experiments/run_lookahead_init.py`:

```python
"""Headline driver for the ViBe look-ahead-median-init experiment.

For each of five sources, runs three init modes — canonical frame-0 init
(baseline), look-ahead median over N=20 frames, and look-ahead median over
all frames — on raw ViBe (no pre/post pipeline). Emits per-source coverage
curves and a side-by-side mask grid under
py/experiments/our_outputs/lookahead_init/<source>/.

Companion design doc: docs/plans/2026-05-05-vibe-lookahead-init-design.md
"""

import os
import sys
from pathlib import Path
from typing import Dict, List, Optional

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from frames.video_source import load_frames
from experiments.motion_vibe import ViBe
from experiments.metrics import coverage_curve
from experiments.render import render_grid, render_coverage_curves


# Phase-0-validated default ViBe params — see 2026-05-04-vibe-phase-0-results.md.
VIBE_PARAMS = dict(
    K=20, R=20, min_match=2,
    phi_update=16, phi_diffuse=16,
    init_scheme="c", coupled_rolls=True,
    prng_seed=0xDEADBEEF,
)

# Headline sources (Question 5 of brainstorm: 2 ghost stress + 3 real clips).
SOURCES = [
    "synthetic:ghost_box_disappear",
    "synthetic:ghost_box_moving",
    "birdseye-320x240.mp4",
    "people-320x240.mp4",
    "intersection-320x240.mp4",
]

OUT_ROOT = Path("py/experiments/our_outputs/lookahead_init")


def _rgb_to_y(frame: np.ndarray) -> np.ndarray:
    """Project Y8 extraction (matches rgb2ycrcb.sv): Y = (77*R + 150*G + 29*B) >> 8."""
    r = frame[:, :, 0].astype(np.uint16)
    g = frame[:, :, 1].astype(np.uint16)
    b = frame[:, :, 2].astype(np.uint16)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def _run_one_init_mode(
    frames_y_stack: np.ndarray,
    init_mode: str,
) -> List[np.ndarray]:
    """Construct a fresh ViBe, init it according to `init_mode`, then run all
    frames through process_frame. Returns the list of per-frame bool masks.

    init_mode is one of:
      'init_frame0'         — vibe.init_from_frame(frames_y_stack[0])
      'init_lookahead_n20'  — vibe.init_from_frames(stack, lookahead_n=20)
      'init_lookahead_full' — vibe.init_from_frames(stack, lookahead_n=None)
    """
    v = ViBe(**VIBE_PARAMS)
    if init_mode == "init_frame0":
        v.init_from_frame(frames_y_stack[0])
    elif init_mode == "init_lookahead_n20":
        n = min(20, frames_y_stack.shape[0])
        v.init_from_frames(frames_y_stack, lookahead_n=n)
    elif init_mode == "init_lookahead_full":
        v.init_from_frames(frames_y_stack, lookahead_n=None)
    else:
        raise ValueError(f"unknown init_mode {init_mode!r}")
    masks = [v.process_frame(f) for f in frames_y_stack]
    return masks


def run_source(source: str, num_frames: int = 200,
               width: int = 320, height: int = 240) -> Dict:
    """Run all three init modes on a single source; render + return curves."""
    frames_rgb = load_frames(source, width=width, height=height,
                             num_frames=num_frames)
    frames_y_list = [_rgb_to_y(f) for f in frames_rgb]
    frames_y = np.stack(frames_y_list, axis=0)  # (N, H, W) uint8

    modes = ["init_frame0", "init_lookahead_n20", "init_lookahead_full"]
    masks_per_mode = {m: _run_one_init_mode(frames_y, m) for m in modes}

    # Output directory: replace ':' and '/' for filesystem safety.
    safe = source.replace(":", "_").replace("/", "_")
    out_dir = OUT_ROOT / safe
    out_dir.mkdir(parents=True, exist_ok=True)

    # Coverage curves
    curves = {m: coverage_curve(masks_per_mode[m]) for m in modes}
    render_coverage_curves(
        curves, out_path=str(out_dir / "coverage.png"),
        title=f"{source}  |  K={VIBE_PARAMS['K']}  φu={VIBE_PARAMS['phi_update']}  "
              f"φd={VIBE_PARAMS['phi_diffuse']}  init=lookahead-median experiment",
    )

    # Grid
    rows = [(m, masks_per_mode[m]) for m in modes]
    render_grid(frames_rgb, rows, out_path=str(out_dir / "grid.png"))

    return {
        "source": source,
        "out_dir": str(out_dir),
        "curves": {m: c.tolist() for m, c in curves.items()},
    }


def main() -> int:
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    summary: List[Dict] = []
    for src in SOURCES:
        print(f"=== {src} ===", flush=True)
        result = run_source(src)
        summary.append(result)
        # Brief per-source stat: avg coverage per mode.
        for mode, c in result["curves"].items():
            arr = np.asarray(c)
            print(f"  {mode}: avg={arr.mean():.4f}  max={arr.max():.4f}",
                  flush=True)
    print(f"\nDone. Outputs under {OUT_ROOT}/.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Smoke-test on one source with a tiny frame count**

Run a quick interactive sanity check (do NOT use the full 200 frames yet):

```bash
source .venv/bin/activate
python -c "
import sys
sys.path.insert(0, 'py')
from experiments.run_lookahead_init import run_source
r = run_source('synthetic:ghost_box_disappear', num_frames=5)
print('OK:', r['out_dir'])
print({m: round(sum(c)/len(c), 4) for m, c in r['curves'].items()})
"
```

Expected: prints `OK:` followed by the output directory and a small dict of avg-coverages. No exceptions. The coverage values themselves are not validated here — this just confirms the script runs end-to-end.

- [ ] **Step 3: Confirm output artifacts exist**

```bash
ls py/experiments/our_outputs/lookahead_init/synthetic_ghost_box_disappear/
```

Expected: `coverage.png` and `grid.png` are present.

- [ ] **Step 4: Commit**

```bash
git add py/experiments/run_lookahead_init.py
git commit -m "feat(experiments/vibe): headline look-ahead-init driver

Runs three init modes (frame0 / lookahead_n20 / lookahead_full) on five
sources with raw ViBe at Phase-0-validated params. Emits per-source
coverage curves + side-by-side mask grids. Smoke-tested on one source
with num_frames=5; full headline run is Task 3."
```

---

## Task 3: Run the full headline experiment

**Files:** none modified. Generates artifacts under `py/experiments/our_outputs/lookahead_init/` (gitignored).

- [ ] **Step 1: Run the full headline experiment**

```bash
source .venv/bin/activate
python py/experiments/run_lookahead_init.py
```

Expected: prints one `=== <source> ===` block per source, each followed by three lines (one per init mode) showing `avg=...  max=...`. Total runtime: ~30–45 minutes. No exceptions.

- [ ] **Step 2: Inspect all five `coverage.png` files**

```bash
ls py/experiments/our_outputs/lookahead_init/*/coverage.png
```

Expected: 5 PNGs. Open each (locally — `xdg-open` or via VS Code) and check:
- Three curves are visible per plot (one per init mode).
- For the two `synthetic:ghost_*` sources: `init_frame0` should show a non-zero plateau (the persistent ghost from Phase-0); the look-ahead modes should show much lower coverage on the same frames.
- For the three real clips: all three curves should be in the same ballpark; differences (if any) reveal the init effect.

- [ ] **Step 3: Inspect all five `grid.png` files**

```bash
ls py/experiments/our_outputs/lookahead_init/*/grid.png
```

Expected: 5 PNGs. Each shows the input row plus three mask rows (one per init mode), columns sampled every 8 frames.

- [ ] **Step 4: Decide whether the look-ahead modes are a clear win**

This is a judgment call by the human reviewer based on Steps 2–3. Record the decision in the results doc (Task 6). The decision gates whether Tasks 4–5 (pipeline follow-up) and Task 7 (parent doc update) execute.

**No commit** — outputs are gitignored and the gate decision is captured in Task 6.

---

## Task 4: Pipeline follow-up script — *gated on positive headline results*

**Skip this task entirely** if Task 3 Step 4 concluded that neither look-ahead mode is a clear win. Skip directly to Task 6.

**Files:**
- Create: `py/experiments/run_lookahead_init_pipeline.py`

- [ ] **Step 1: Create the follow-up script**

The winning init mode (`init_lookahead_n20` *or* `init_lookahead_full`) is determined by Task 3 Step 4. Replace `WINNING_MODE` below with the chosen string before running.

Write `py/experiments/run_lookahead_init_pipeline.py`:

```python
"""Follow-up validation for the ViBe look-ahead-median-init experiment.

Runs the canonical baseline (frame-0 init) and the winning look-ahead
mode through the production motion pipeline (gauss3x3 → ViBe →
morph_open → morph_close) on the three real demo clips. Confirms that
the headline-experiment win survives pre/post-processing.

This script runs only after run_lookahead_init.py has identified a
clear winner. Edit WINNING_MODE below if the Task-3 review picks a
different mode.

Companion design doc: docs/plans/2026-05-05-vibe-lookahead-init-design.md
"""

import os
import sys
from pathlib import Path
from typing import Dict, List

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from frames.video_source import load_frames
from experiments.motion_vibe import ViBe
from experiments.metrics import coverage_curve
from experiments.render import render_grid, render_coverage_curves
from models.motion import _gauss3x3
from models.ops.morph_open import morph_open
from models.ops.morph_close import morph_close


# === EDIT BEFORE RUNNING: pick the winner from the headline experiment. ===
WINNING_MODE = "init_lookahead_n20"  # or "init_lookahead_full"
# ==========================================================================

VIBE_PARAMS = dict(
    K=20, R=20, min_match=2,
    phi_update=16, phi_diffuse=16,
    init_scheme="c", coupled_rolls=True,
    prng_seed=0xDEADBEEF,
)

SOURCES = [
    "birdseye-320x240.mp4",
    "people-320x240.mp4",
    "intersection-320x240.mp4",
]

OUT_ROOT = Path("py/experiments/our_outputs/lookahead_init_pipeline")

# Production-pipeline morph_close kernel (CFG_DEFAULT in sparevideo_pkg.sv).
MORPH_CLOSE_KERNEL = 3


def _rgb_to_y(frame: np.ndarray) -> np.ndarray:
    r = frame[:, :, 0].astype(np.uint16)
    g = frame[:, :, 1].astype(np.uint16)
    b = frame[:, :, 2].astype(np.uint16)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def _init_vibe(frames_y_stack: np.ndarray, init_mode: str) -> ViBe:
    v = ViBe(**VIBE_PARAMS)
    if init_mode == "init_frame0":
        v.init_from_frame(frames_y_stack[0])
    elif init_mode == "init_lookahead_n20":
        n = min(20, frames_y_stack.shape[0])
        v.init_from_frames(frames_y_stack, lookahead_n=n)
    elif init_mode == "init_lookahead_full":
        v.init_from_frames(frames_y_stack, lookahead_n=None)
    else:
        raise ValueError(f"unknown init_mode {init_mode!r}")
    return v


def _run_pipeline(frames_y_stack: np.ndarray, init_mode: str) -> List[np.ndarray]:
    """Run gauss → ViBe → morph_open → morph_close end-to-end. Return cleaned masks."""
    v = _init_vibe(frames_y_stack, init_mode)
    cleaned: List[np.ndarray] = []
    for f in frames_y_stack:
        f_blur = _gauss3x3(f)
        raw_mask = v.process_frame(f_blur)            # bool (H, W)
        opened = morph_open(raw_mask)                 # bool (H, W)
        closed = morph_close(opened, kernel=MORPH_CLOSE_KERNEL)  # bool (H, W)
        cleaned.append(closed)
    return cleaned


def run_source(source: str, num_frames: int = 200,
               width: int = 320, height: int = 240) -> Dict:
    frames_rgb = load_frames(source, width=width, height=height,
                             num_frames=num_frames)
    frames_y_list = [_rgb_to_y(f) for f in frames_rgb]
    frames_y = np.stack(frames_y_list, axis=0)

    modes = ["init_frame0", WINNING_MODE]
    masks_per_mode = {m: _run_pipeline(frames_y, m) for m in modes}

    safe = source.replace(":", "_").replace("/", "_")
    out_dir = OUT_ROOT / safe
    out_dir.mkdir(parents=True, exist_ok=True)

    curves = {m: coverage_curve(masks_per_mode[m]) for m in modes}
    render_coverage_curves(
        curves, out_path=str(out_dir / "coverage.png"),
        title=f"{source}  |  pipeline (gauss + morph_open + morph_close)  "
              f"|  baseline vs {WINNING_MODE}",
    )

    rows = [(m, masks_per_mode[m]) for m in modes]
    render_grid(frames_rgb, rows, out_path=str(out_dir / "grid.png"))

    return {
        "source": source,
        "out_dir": str(out_dir),
        "curves": {m: c.tolist() for m, c in curves.items()},
    }


def main() -> int:
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    for src in SOURCES:
        print(f"=== {src} ===", flush=True)
        result = run_source(src)
        for mode, c in result["curves"].items():
            arr = np.asarray(c)
            print(f"  {mode}: avg={arr.mean():.4f}  max={arr.max():.4f}",
                  flush=True)
    print(f"\nDone. Outputs under {OUT_ROOT}/.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Confirm `WINNING_MODE` matches the Task-3 decision**

Open `py/experiments/run_lookahead_init_pipeline.py` and verify the value of `WINNING_MODE` (top of file) matches the winner identified in Task 3 Step 4. If it doesn't, edit it.

- [ ] **Step 3: Smoke-test on one source with a tiny frame count**

```bash
source .venv/bin/activate
python -c "
import sys
sys.path.insert(0, 'py')
from experiments.run_lookahead_init_pipeline import run_source
r = run_source('birdseye-320x240.mp4', num_frames=5)
print('OK:', r['out_dir'])
print({m: round(sum(c)/len(c), 4) for m, c in r['curves'].items()})
"
```

Expected: prints `OK:` and a small dict with two entries. No exceptions.

- [ ] **Step 4: Commit**

```bash
git add py/experiments/run_lookahead_init_pipeline.py
git commit -m "feat(experiments/vibe): pipeline follow-up validator

Runs gauss → ViBe → morph_open → morph_close on the three real demo
clips for two init modes (canonical frame-0 + the winning look-ahead
mode from the headline experiment). Confirms that the headline win
survives the production pipeline's pre/post-processing."
```

---

## Task 5: Run the pipeline follow-up — *gated on Task 4*

**Skip if Task 4 was skipped.**

**Files:** none modified. Generates artifacts under `py/experiments/our_outputs/lookahead_init_pipeline/` (gitignored).

- [ ] **Step 1: Run the full follow-up experiment**

```bash
source .venv/bin/activate
python py/experiments/run_lookahead_init_pipeline.py
```

Expected: three `=== <source> ===` blocks, each with two lines (canonical + winning mode). Total runtime: ~15–25 minutes. No exceptions.

- [ ] **Step 2: Inspect all three `coverage.png` files**

```bash
ls py/experiments/our_outputs/lookahead_init_pipeline/*/coverage.png
```

Expected: 3 PNGs. Open each and confirm the look-ahead mode's coverage curve is at least as good (lower mean and/or no spurious early-frame spike) as the canonical baseline.

- [ ] **Step 3: Inspect all three `grid.png` files**

```bash
ls py/experiments/our_outputs/lookahead_init_pipeline/*/grid.png
```

Expected: 3 PNGs. Confirm the post-pipeline mask quality is preserved or improved by the look-ahead init mode.

**No commit** — outputs are gitignored.

---

## Task 6: Write the results doc

**Files:**
- Create: `docs/plans/2026-05-05-vibe-lookahead-init-results.md`

- [ ] **Step 1: Write the results doc**

Open the per-source `coverage.png` and `grid.png` files from Task 3 (and Task 5 if applicable). Hand-write the results doc. Use this skeleton — fill the bracketed sections from observed data:

```markdown
# ViBe Look-Ahead Median Init — Results

**Date:** 2026-05-05
**Branch:** feat/vibe-lookahead-init
**Companion plan:** [`2026-05-05-vibe-lookahead-init-plan.md`](2026-05-05-vibe-lookahead-init-plan.md)
**Companion design doc:** [`2026-05-05-vibe-lookahead-init-design.md`](2026-05-05-vibe-lookahead-init-design.md)

## Decision

**[PASS / FAIL / INCONCLUSIVE]** — [one-sentence summary of whether look-ahead init is worth promoting].

## Headline experiment (raw ViBe, three init modes)

ViBe params: K=20, R=20, min_match=2, φ_update=16, φ_diffuse=16, init_scheme=c, coupled_rolls=True, prng_seed=0xDEADBEEF. 200 frames per source.

| Source | init_frame0 avg | init_lookahead_n20 avg | init_lookahead_full avg |
|---|---|---|---|
| synthetic:ghost_box_disappear | [x.xxxx] | [x.xxxx] | [x.xxxx] |
| synthetic:ghost_box_moving    | [x.xxxx] | [x.xxxx] | [x.xxxx] |
| birdseye-320x240.mp4          | [x.xxxx] | [x.xxxx] | [x.xxxx] |
| people-320x240.mp4            | [x.xxxx] | [x.xxxx] | [x.xxxx] |
| intersection-320x240.mp4      | [x.xxxx] | [x.xxxx] | [x.xxxx] |

**Visual evidence.** [link to / describe the relevant grid.png panels showing the canonical-baseline ghost vs the look-ahead-init clean output. Note any inverse-ghost artifacts on real clips (§2 of the design doc).]

**Takeaway.** [2–4 sentences on what the data shows: did the synthetic ghosts clear, did real-clip behaviour change for better or worse, was there an inverse-ghost cost.]

## Pipeline follow-up (gauss + ViBe + morph_open + morph_close)
[Include this section only if Task 4–5 ran.]

| Source | init_frame0 avg | [winning_mode] avg |
|---|---|---|
| birdseye-320x240.mp4     | [x.xxxx] | [x.xxxx] |
| people-320x240.mp4       | [x.xxxx] | [x.xxxx] |
| intersection-320x240.mp4 | [x.xxxx] | [x.xxxx] |

**Takeaway.** [2 sentences on whether the headline win survives morph_clean, and whether morph_clean alone closes the gap.]

## Recommendation

[Pick one:]
- **Promote** — add `bg_init_mode` / `bg_init_lookahead_n` as Phase-1+ control knobs in [`2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md). Default value: [chosen mode] / [chosen N].
- **Do not promote** — [reason]. The knob remains an experimental option in `py/experiments/motion_vibe.py` only.

## Embedded artifacts (gitignored, regenerable)

- `py/experiments/our_outputs/lookahead_init/<source>/{grid,coverage}.png`
- `py/experiments/our_outputs/lookahead_init_pipeline/<source>/{grid,coverage}.png` *(if pipeline follow-up ran)*

Regenerate:

\`\`\`bash
source .venv/bin/activate
python py/experiments/run_lookahead_init.py
# If headline wins, then also:
python py/experiments/run_lookahead_init_pipeline.py
\`\`\`
```

(Replace the literal backticks-around-bash block above with real triple-backtick fences when filling the doc — the example uses escaped fences only because they're nested inside this plan's own block.)

- [ ] **Step 2: Commit**

```bash
git add docs/plans/2026-05-05-vibe-lookahead-init-results.md
git commit -m "docs(plans): ViBe look-ahead-init experiment results

Per-source coverage table for the three init modes on five sources
(headline run) and, where applicable, the two-mode pipeline follow-up
on the three real clips. Recommends [promote / do-not-promote] based
on observed mask quality."
```

---

## Task 7: Update the parent ViBe design doc — *gated on positive results*

**Files:**
- Modify: `docs/plans/2026-05-01-vibe-motion-design.md`

This task has two variants depending on the Task-6 recommendation. **Execute exactly one.**

### Variant 7A: Recommendation was "Promote"

- [ ] **Step 1: Locate the control-knob list in the parent doc**

```bash
grep -n "alpha_shift\|grace_frames\|cfg_t\|control knob" docs/plans/2026-05-01-vibe-motion-design.md | head -20
```

Identify the section that enumerates the Phase-1+ `cfg_t` fields (likely §4 or §5 of the parent doc). Open the file in an editor at that section.

- [ ] **Step 2: Add the new knobs**

Insert the following into the Phase-1+ control-knob list (place it after the existing init-related knobs, or after the existing K/R/φ knobs, whichever is more thematically appropriate in the parent doc's structure):

```markdown
- `bg_init_mode: "frame0" | "lookahead_median"` — selects the sample-bank seeding strategy. `"frame0"` (default) is the canonical Barnich–Van Droogenbroeck init using only frame 0; `"lookahead_median"` computes a per-pixel temporal median over the first `bg_init_lookahead_n` frames of the clip and uses that as the center value for the configured `init_scheme`. Validated by [`2026-05-05-vibe-lookahead-init-results.md`](2026-05-05-vibe-lookahead-init-results.md). For RTL implementation, `"lookahead_median"` requires a startup buffer of `bg_init_lookahead_n` frames worth of frame storage and a median compute, before normal `process_frame` operation can begin.
- `bg_init_lookahead_n: int` — number of leading frames used when `bg_init_mode = "lookahead_median"`. Validated values: [N from results doc]. Ignored when `bg_init_mode = "frame0"`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/plans/2026-05-01-vibe-motion-design.md
git commit -m "docs(plans): add bg_init_mode / bg_init_lookahead_n to ViBe design

Promotes the look-ahead median init from py/experiments to a Phase-1+
cfg_t control knob, citing 2026-05-05-vibe-lookahead-init-results.md."
```

### Variant 7B: Recommendation was "Do not promote"

- [ ] **Step 1: Add a brief deferral note to the parent doc**

Append the following paragraph to the end of the parent doc's "Open issues" / "Phase-1 deferred" section (or, if none exists, to the end of the doc as a new "Deferred experiments" section):

```markdown
### Look-ahead median init — investigated, not adopted

A Python-only experiment ([`2026-05-05-vibe-lookahead-init-design.md`](2026-05-05-vibe-lookahead-init-design.md)) explored seeding the sample bank from a temporal median over a look-ahead window (N=20 and full-clip) instead of canonical frame-0 init. Results in [`2026-05-05-vibe-lookahead-init-results.md`](2026-05-05-vibe-lookahead-init-results.md) showed [one-sentence summary of why it didn't pay off]. The knob remains available as `init_from_frames` on the experimental `ViBe` class in `py/experiments/motion_vibe.py` but is not promoted to the Phase-1+ `cfg_t`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/plans/2026-05-01-vibe-motion-design.md
git commit -m "docs(plans): note look-ahead init investigation in ViBe design

Adds a brief deferral note pointing to the look-ahead-init experiment
results; the knob is not promoted to the Phase-1+ cfg_t."
```

---

## Final verification

- [ ] **Step 1: Confirm all tests still pass**

```bash
.venv/bin/python -m pytest py/tests/ -v
```

Expected: 36 motion_vibe tests + all other project tests pass with no regressions.

- [ ] **Step 2: Confirm git log on the branch is clean**

```bash
git log --oneline feat/vibe-motion-design..HEAD
```

Expected: a chain of well-described commits, in this order:
1. `docs(plans): ViBe look-ahead median init experiment design` (the spec, already on branch)
2. `feat(experiments/vibe): add init_from_frames look-ahead median init` (Task 1)
3. `feat(experiments/vibe): headline look-ahead-init driver` (Task 2)
4. `feat(experiments/vibe): pipeline follow-up validator` *(only if Task 4 ran)*
5. `docs(plans): ViBe look-ahead-init experiment results` (Task 6)
6. `docs(plans): [promote OR note] … in ViBe design` (Task 7)

Per CLAUDE.md, before opening a PR these should be **squashed into a single plan-scoped commit**. That squash is performed at PR-opening time, not as part of plan execution.

- [ ] **Step 3: Move the plan to `docs/plans/old/` per CLAUDE.md "TODO after each major change"**

Once all Tasks above are complete and committed:

```bash
git mv docs/plans/2026-05-05-vibe-lookahead-init-plan.md docs/plans/old/
git mv docs/plans/2026-05-05-vibe-lookahead-init-design.md docs/plans/old/
# Note: the results doc stays at docs/plans/2026-05-05-vibe-lookahead-init-results.md as
# living reference for the parent ViBe design doc, which links to it.
git commit -m "chore(plans): retire vibe-lookahead-init design + plan to old/"
```
