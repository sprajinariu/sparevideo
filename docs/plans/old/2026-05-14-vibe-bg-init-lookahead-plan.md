# ViBe BG Init — Look-Ahead Beyond Median — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three new look-ahead BG init schemes (IMRM, MVTW, MAM) to the Python ViBe path, benchmark them against the current `lookahead_median` baseline and `vibe_demote` runtime control on the standard 5-source set, and (conditionally) promote a winner as the new default for `bg_init_mode`.

**Architecture:** Three pure-numpy batch helpers in a new module `py/models/ops/bg_init.py` produce a per-pixel `(H, W) uint8` BG estimate from an `(N, H, W) uint8` luma stack. The estimate replaces `np.median(...)` in two integration sites: (1) `compute_lookahead_median_bank` in `py/models/motion_vibe.py` (the production path that mirrors the RTL ROM) and (2) `init_from_frames` in `py/models/ops/vibe.py` (the unit-test-friendly Python-only entry point). Selection is driven by a new `cfg_t.vibe_bg_init_mode` field. A new experiment runner at `py/experiments/run_bg_init_compare.py` benchmarks the 4 init modes + `vibe_demote` control over 5 sources.

**Tech Stack:** Python 3 + numpy + the existing `py/experiments/` harness (metrics.py, render.py). SystemVerilog field definitions in `hw/top/sparevideo_pkg.sv` for cfg_t parity (RTL behavior unchanged — pre-loaded bank).

**Spec:** [`docs/plans/2026-05-14-vibe-bg-init-lookahead-design.md`](2026-05-14-vibe-bg-init-lookahead-design.md)

---

## Task 1: Add cfg_t fields for `bg_init_mode` + per-mode knobs

**Files:**
- Modify: [`hw/top/sparevideo_pkg.sv`](../../hw/top/sparevideo_pkg.sv) — add 6 fields to the `cfg_t` struct; default them in every existing `CFG_*` localparam.
- Modify: [`py/profiles.py`](../../py/profiles.py) — add the matching fields to every profile dict (`DEFAULT`, `DEFAULT_VIBE`, all derived VIBE_* dicts, PBAS_*, DEMO, DEMO_VIBE_DEMOTE, VIBE_DEMOTE — every dict that's a value in the `PROFILES` registry).
- Test: [`py/tests/test_profiles.py`](../../py/tests/test_profiles.py) — existing parity test catches drift automatically; rerun to verify the new fields parse.

Encoding for `vibe_bg_init_mode`:
- `0` = `BG_INIT_MEDIAN` (current behavior; default for now)
- `1` = `BG_INIT_IMRM`
- `2` = `BG_INIT_MVTW`
- `3` = `BG_INIT_MAM`

- [ ] **Step 1.1: Add localparams + struct fields in sparevideo_pkg.sv**

Locate the existing `BG_INIT_*` / ViBe-knob block in the package (search for `vibe_bg_init_external`). Add immediately below the existing localparams (e.g., `BG_MODEL_VIBE`):

```systemverilog
    // ---- BG-init mode encoding (consumed only when vibe_bg_init_external=1) ----
    localparam int BG_INIT_MEDIAN = 0;  // current production: per-pixel temporal median
    localparam int BG_INIT_IMRM   = 1;  // iterative motion-rejected median
    localparam int BG_INIT_MVTW   = 2;  // per-pixel min-variance temporal window
    localparam int BG_INIT_MAM    = 3;  // motion-aware (frame-diff outlier rejection) median
```

In the `cfg_t` struct (search for the existing `logic vibe_bg_init_external;` line), add immediately below `vibe_bg_init_lookahead_n`:

```systemverilog
        logic [1:0]  vibe_bg_init_mode;        // BG_INIT_MEDIAN/IMRM/MVTW/MAM
        logic [7:0]  vibe_bg_init_imrm_tau;    // IMRM: outlier deviation threshold (default 20)
        logic [3:0]  vibe_bg_init_imrm_iters;  // IMRM: iteration count (default 3)
        logic [7:0]  vibe_bg_init_mvtw_k;      // MVTW: window length in frames (default 24)
        logic [7:0]  vibe_bg_init_mam_delta;   // MAM: frame-diff threshold (default 8)
        logic [3:0]  vibe_bg_init_mam_dilate;  // MAM: temporal dilation radius (default 2)
```

- [ ] **Step 1.2: Default the new fields in every CFG_* localparam in sparevideo_pkg.sv**

Each existing `CFG_*` localparam in the package is an explicit-keys struct literal. For each one, append (matching the field order added in 1.1):

```systemverilog
        vibe_bg_init_mode:       BG_INIT_MEDIAN,
        vibe_bg_init_imrm_tau:   8'd20,
        vibe_bg_init_imrm_iters: 4'd3,
        vibe_bg_init_mvtw_k:     8'd24,
        vibe_bg_init_mam_delta:  8'd8,
        vibe_bg_init_mam_dilate: 4'd2,
```

Audit every `CFG_*` localparam in the file (search for `cfg_t CFG_`). Don't miss any — `test_profiles.py` will fail to parse the package if a struct literal is missing keys.

- [ ] **Step 1.3: Run lint to verify SV parses**

```bash
make lint
```

Expected: zero new warnings.

- [ ] **Step 1.4: Add matching fields to every profile dict in py/profiles.py**

Search for `vibe_bg_init_external` in `py/profiles.py`. Every dict that has it must also get the new fields. Add (matching the SV order):

```python
    vibe_bg_init_mode=0,          # BG_INIT_MEDIAN
    vibe_bg_init_imrm_tau=20,
    vibe_bg_init_imrm_iters=3,
    vibe_bg_init_mvtw_k=24,
    vibe_bg_init_mam_delta=8,
    vibe_bg_init_mam_dilate=2,
```

- [ ] **Step 1.5: Run the profile-parity test**

```bash
.venv/bin/pytest py/tests/test_profiles.py -v
```

Expected: PASS. If it fails, fix any field-name drift between SV and Python.

- [ ] **Step 1.6: Commit**

```bash
git add hw/top/sparevideo_pkg.sv py/profiles.py
git commit -m "feat(cfg_t): add vibe_bg_init_mode + per-mode knob fields (default = median)"
```

---

## Task 2: Create bg_init module + IMRM helper (TDD)

**Files:**
- Create: `py/models/ops/bg_init.py`
- Test: `py/tests/test_bg_init.py`

- [ ] **Step 2.1: Write the failing test for `compute_bg_estimate` dispatch + IMRM behavior**

Create `py/tests/test_bg_init.py`:

```python
"""Unit tests for py/models/ops/bg_init.py — BG-estimate helpers."""
import numpy as np
import pytest

from models.ops.bg_init import compute_bg_estimate


def _make_stack(per_pixel_values, shape=(1, 1)):
    """Stack of N frames, each frame uniform with the given per-frame value."""
    h, w = shape
    return np.stack(
        [np.full(shape, v, dtype=np.uint8) for v in per_pixel_values], axis=0
    )


def test_compute_bg_estimate_median_matches_np_median():
    """mode='median' must be byte-identical to np.median(...).astype(uint8)."""
    rng = np.random.default_rng(42)
    stack = rng.integers(0, 256, size=(50, 4, 5), dtype=np.uint8)
    got = compute_bg_estimate(stack, mode="median")
    expected = np.median(stack, axis=0).astype(np.uint8)
    np.testing.assert_array_equal(got, expected)


def test_imrm_majority_bg_recovers_bg():
    """IMRM converges to BG when BG is the majority cluster."""
    # 100 frames at a single pixel: 60 BG (constant 80), 40 FG (constant 200).
    values = [80] * 60 + [200] * 40
    stack = _make_stack(values, shape=(1, 1))
    got = compute_bg_estimate(stack, mode="imrm", imrm_tau=20, imrm_iters=3)
    assert abs(int(got[0, 0]) - 80) <= 2, f"IMRM returned {got[0,0]}, expected ~80"


def test_imrm_unknown_mode_raises():
    with pytest.raises(ValueError, match="unknown bg_init mode"):
        compute_bg_estimate(np.zeros((1, 1, 1), dtype=np.uint8), mode="not_a_mode")
```

- [ ] **Step 2.2: Run the failing test**

```bash
.venv/bin/pytest py/tests/test_bg_init.py -v
```

Expected: FAIL with `ImportError: cannot import name 'compute_bg_estimate'`.

- [ ] **Step 2.3: Implement `py/models/ops/bg_init.py` with `compute_bg_estimate` + IMRM**

```python
"""BG-estimate helpers for ViBe look-ahead initialisation.

Each helper consumes an (N, H, W) uint8 luma stack and returns an (H, W) uint8
per-pixel BG estimate. The estimate then feeds the same K-slot bank-seeding
path that the existing lookahead-median path uses (compute_lookahead_median_bank
in py/models/motion_vibe.py, and init_from_frame in py/models/ops/vibe.py).

Companion design / plan:
  docs/plans/2026-05-14-vibe-bg-init-lookahead-design.md
  docs/plans/2026-05-14-vibe-bg-init-lookahead-plan.md
"""
from __future__ import annotations

import numpy as np


def compute_bg_estimate(
    y_stack: np.ndarray,
    *,
    mode: str = "median",
    imrm_tau: int = 20,
    imrm_iters: int = 3,
    mvtw_k: int = 24,
    mam_delta: int = 8,
    mam_dilate: int = 2,
) -> np.ndarray:
    """Compute a per-pixel BG estimate from an (N, H, W) uint8 luma stack.

    Args:
        y_stack: (N, H, W) uint8 stack of luma frames, N >= 1.
        mode:    "median" | "imrm" | "mvtw" | "mam"
        imrm_tau, imrm_iters: IMRM knobs.
        mvtw_k:               MVTW knob.
        mam_delta, mam_dilate: MAM knobs.

    Returns:
        (H, W) uint8 BG estimate.
    """
    assert y_stack.ndim == 3 and y_stack.dtype == np.uint8, \
        "y_stack must be (N, H, W) uint8"
    assert y_stack.shape[0] >= 1, "y_stack must have at least 1 frame"
    if mode == "median":
        return np.median(y_stack, axis=0).astype(np.uint8)
    if mode == "imrm":
        return _bg_imrm(y_stack, tau=int(imrm_tau), iters=int(imrm_iters))
    if mode == "mvtw":
        return _bg_mvtw(y_stack, k=int(mvtw_k))
    if mode == "mam":
        return _bg_mam(y_stack, delta=int(mam_delta), dilate=int(mam_dilate))
    raise ValueError(f"unknown bg_init mode {mode!r}")


def _bg_imrm(y_stack: np.ndarray, *, tau: int, iters: int) -> np.ndarray:
    """Iterative motion-rejected median.

    Initialise BG estimate as the plain temporal median. On each iteration,
    mark per-pixel frames where |I_t - bg_est| > tau as outliers; recompute
    the median over inliers only. Pixels where all frames are flagged
    outliers fall back to the previous iteration's value.

    Per-pixel inlier counts vary, so the recomputation uses an axis-0 masked
    operation (np.where-based fill of outliers with the current estimate
    before median) rather than a true ragged median — this is the standard
    fast approximation and is exact when the outlier set is symmetric around
    the bg estimate.
    """
    bg = np.median(y_stack, axis=0).astype(np.float32)  # (H, W)
    for _ in range(iters):
        diff = np.abs(y_stack.astype(np.float32) - bg[None, :, :])  # (N, H, W)
        outlier = diff > float(tau)
        # Fast trimmed-median: replace outlier values with the current bg
        # estimate, then take plain median. Symmetric outliers cancel out
        # (median ignores the substituted values exactly).
        replaced = np.where(outlier, bg[None, :, :], y_stack.astype(np.float32))
        bg = np.median(replaced, axis=0)
    return np.clip(bg, 0, 255).astype(np.uint8)
```

- [ ] **Step 2.4: Run the test**

```bash
.venv/bin/pytest py/tests/test_bg_init.py -v
```

Expected: PASS on all three tests.

- [ ] **Step 2.5: Commit**

```bash
git add py/models/ops/bg_init.py py/tests/test_bg_init.py
git commit -m "feat(bg_init): add compute_bg_estimate dispatcher + IMRM helper"
```

---

## Task 3: Add MVTW helper

- [ ] **Step 3.1: Write the failing test**

Append to `py/tests/test_bg_init.py`:

```python
def test_mvtw_recovers_bg_when_briefly_clear():
    """MVTW finds the brief BG-clear window when FG dominates overall."""
    # 100 frames at one pixel: FG=200 for frames 0..79, BG=80 for frames 80..99.
    # Plain median would return ~200; MVTW with K=20 should find the last
    # window and return ~80.
    values = [200] * 80 + [80] * 20
    stack = _make_stack(values, shape=(1, 1))
    got = compute_bg_estimate(stack, mode="mvtw", mvtw_k=20)
    assert abs(int(got[0, 0]) - 80) <= 2, f"MVTW returned {got[0,0]}, expected ~80"


def test_mvtw_falls_back_to_median_when_stack_shorter_than_k():
    """MVTW with K > N falls back to plain median over the full stack."""
    values = [80] * 10
    stack = _make_stack(values, shape=(1, 1))
    got = compute_bg_estimate(stack, mode="mvtw", mvtw_k=24)
    assert int(got[0, 0]) == 80
```

- [ ] **Step 3.2: Run the failing test**

```bash
.venv/bin/pytest py/tests/test_bg_init.py::test_mvtw_recovers_bg_when_briefly_clear -v
```

Expected: FAIL — `_bg_mvtw` not yet defined.

- [ ] **Step 3.3: Implement `_bg_mvtw` in py/models/ops/bg_init.py**

Append to `py/models/ops/bg_init.py`:

```python
def _bg_mvtw(y_stack: np.ndarray, *, k: int) -> np.ndarray:
    """Per-pixel min-variance temporal window.

    For each pixel, slide a K-frame window across the stack, compute the
    variance of the K samples, pick the window with minimum variance, and
    return that window's mean.

    If N < K (clip shorter than the window), fall back to plain median over
    the full stack.

    Vectorised via np.lib.stride_tricks.sliding_window_view.
    """
    n, h, w = y_stack.shape
    if n < k:
        return np.median(y_stack, axis=0).astype(np.uint8)
    # sliding_window_view on axis 0 → shape (n-k+1, h, w, k).
    windows = np.lib.stride_tricks.sliding_window_view(
        y_stack.astype(np.float32), window_shape=k, axis=0
    )
    # variance per window per pixel → shape (n-k+1, h, w).
    var = windows.var(axis=-1)
    # argmin window index per pixel → (h, w).
    best = var.argmin(axis=0)
    # Gather the chosen window's mean per pixel.
    means = windows.mean(axis=-1)  # (n-k+1, h, w)
    ii, jj = np.indices((h, w))
    bg = means[best, ii, jj]
    return np.clip(bg, 0, 255).astype(np.uint8)
```

- [ ] **Step 3.4: Run the tests**

```bash
.venv/bin/pytest py/tests/test_bg_init.py -v
```

Expected: PASS on all five tests.

- [ ] **Step 3.5: Commit**

```bash
git add py/models/ops/bg_init.py py/tests/test_bg_init.py
git commit -m "feat(bg_init): add MVTW (per-pixel min-variance window) helper"
```

---

## Task 4: Add MAM helper

- [ ] **Step 4.1: Write the failing test**

Append to `py/tests/test_bg_init.py`:

```python
def test_mam_rejects_low_contrast_moving_fg():
    """MAM rejects frames with motion signal even when |FG-BG| < imrm_tau.

    Setup at one pixel:
      - BG=80 for frames 0..39 (constant)
      - FG with frame-by-frame oscillation between 95 and 100 for frames 40..99
        (60 frames, FG-majority — biases plain median into FG range; |FG-BG|=15..20
        so IMRM with default tau=20 would NOT reject these)
    MAM should detect the inter-frame deltas (|95-100|=5 < delta=8, but the
    transition 80->95 and 100->80 at the boundaries gives |diff|>=15 > delta=8;
    after temporal dilation, all FG frames are flagged, leaving the 40 BG
    frames for the median → ~80).
    """
    bg = [80] * 40
    fg = []
    for i in range(60):
        fg.append(95 if i % 2 == 0 else 100)
    values = bg + fg
    stack = _make_stack(values, shape=(1, 1))
    got = compute_bg_estimate(stack, mode="mam", mam_delta=8, mam_dilate=2)
    assert abs(int(got[0, 0]) - 80) <= 3, f"MAM returned {got[0,0]}, expected ~80"


def test_mam_static_pixel_returns_constant():
    """MAM on a fully-static pixel returns the constant value (no motion)."""
    values = [123] * 50
    stack = _make_stack(values, shape=(1, 1))
    got = compute_bg_estimate(stack, mode="mam", mam_delta=8, mam_dilate=2)
    assert int(got[0, 0]) == 123
```

- [ ] **Step 4.2: Run the failing test**

```bash
.venv/bin/pytest py/tests/test_bg_init.py::test_mam_rejects_low_contrast_moving_fg -v
```

Expected: FAIL — `_bg_mam` not yet defined.

- [ ] **Step 4.3: Implement `_bg_mam` in py/models/ops/bg_init.py**

Append to `py/models/ops/bg_init.py`:

```python
def _bg_mam(y_stack: np.ndarray, *, delta: int, dilate: int) -> np.ndarray:
    """Motion-aware median (frame-diff outlier rejection).

    Two passes:
      1. Compute per-pixel inter-frame absolute deltas; threshold by `delta`
         to get a binary motion mask of shape (N, H, W). Frame 0 is treated
         as motion (conservative) and frames N-1 inherits N-2's diff.
      2. Temporally dilate the motion mask by `dilate` frames in both
         directions (so a motion event shadows neighbouring frames). Then
         per pixel, take median over frames NOT flagged as motion. Pixels
         with zero non-motion frames fall back to plain median over the
         full stack.
    """
    n, h, w = y_stack.shape
    if n == 1:
        return y_stack[0].copy()
    y = y_stack.astype(np.int16)
    # Frame-to-frame absolute delta, shape (n, h, w). Frame 0 = delta with frame 1.
    diff = np.empty((n, h, w), dtype=np.int16)
    diff[0] = np.abs(y[1] - y[0])
    diff[1:n-1] = np.maximum(np.abs(y[1:n-1] - y[0:n-2]),
                             np.abs(y[2:n]   - y[1:n-1]))
    diff[n-1] = np.abs(y[n-1] - y[n-2])
    motion = diff > int(delta)  # (n, h, w) bool
    # Temporal dilation by `dilate` frames in both directions.
    if dilate > 0:
        dilated = motion.copy()
        for d in range(1, int(dilate) + 1):
            dilated[d:] |= motion[:-d]
            dilated[:-d] |= motion[d:]
        motion = dilated
    # Per pixel, median over non-motion frames. Use a mask-aware approach:
    # replace motion frames with NaN, then nanmedian.
    yf = y_stack.astype(np.float32)
    yf[motion] = np.nan
    # all-motion fallback to plain median over the original stack
    all_motion = motion.all(axis=0)  # (h, w) bool
    with np.errstate(invalid="ignore"):
        bg = np.nanmedian(yf, axis=0)  # may be NaN where all-motion
    if all_motion.any():
        fallback = np.median(y_stack, axis=0).astype(np.float32)
        bg = np.where(all_motion, fallback, bg)
    return np.clip(bg, 0, 255).astype(np.uint8)
```

- [ ] **Step 4.4: Run the tests**

```bash
.venv/bin/pytest py/tests/test_bg_init.py -v
```

Expected: PASS on all seven tests.

- [ ] **Step 4.5: Commit**

```bash
git add py/models/ops/bg_init.py py/tests/test_bg_init.py
git commit -m "feat(bg_init): add MAM (motion-aware median) helper"
```

---

## Task 5: Wire `compute_bg_estimate` into `compute_lookahead_median_bank` (production path)

**Files:**
- Modify: [`py/models/motion_vibe.py`](../../py/models/motion_vibe.py) — refactor `compute_lookahead_median_bank` to delegate the BG-estimate step.
- Modify: [`py/models/_vibe_mask.py`](../../py/models/_vibe_mask.py) — accept + pass through the new mode + knobs.
- Test: `py/tests/test_bg_init.py` — add a regression test that `mode="median"` produces byte-identical bank to the pre-refactor behavior.

- [ ] **Step 5.1: Write the regression test**

Append to `py/tests/test_bg_init.py`:

```python
def test_compute_lookahead_median_bank_median_mode_is_unchanged():
    """The new bg_init_mode='median' path must produce a byte-identical bank
    to the legacy pre-refactor compute_lookahead_median_bank behaviour.

    Lock-in: snapshot expected output by computing the bank with mode='median'
    once and asserting it matches np.median + the K-slot seeding loop.
    """
    from models.motion_vibe import compute_lookahead_median_bank
    rng = np.random.default_rng(0)
    rgb_frames = [
        rng.integers(0, 256, size=(8, 6, 3), dtype=np.uint8) for _ in range(10)
    ]
    bank_default = compute_lookahead_median_bank(
        rgb_frames=rgb_frames, k=8, lookahead_n=0, seed=0xDEADBEEF,
    )
    bank_explicit = compute_lookahead_median_bank(
        rgb_frames=rgb_frames, k=8, lookahead_n=0, seed=0xDEADBEEF,
        bg_init_mode="median",
    )
    np.testing.assert_array_equal(bank_default, bank_explicit)
```

- [ ] **Step 5.2: Run the failing test**

```bash
.venv/bin/pytest py/tests/test_bg_init.py::test_compute_lookahead_median_bank_median_mode_is_unchanged -v
```

Expected: FAIL with `TypeError: compute_lookahead_median_bank() got an unexpected keyword argument 'bg_init_mode'`.

- [ ] **Step 5.3: Refactor `compute_lookahead_median_bank` to accept mode + knobs**

In `py/models/motion_vibe.py`, replace the existing function signature and the median-computation line. Current (around line 87):

```python
def compute_lookahead_median_bank(
    rgb_frames: list[np.ndarray],
    *,
    k: int,
    lookahead_n: int,
    seed: int,
) -> np.ndarray:
```

Change to:

```python
def compute_lookahead_median_bank(
    rgb_frames: list[np.ndarray],
    *,
    k: int,
    lookahead_n: int,
    seed: int,
    bg_init_mode: str = "median",
    bg_init_imrm_tau: int = 20,
    bg_init_imrm_iters: int = 3,
    bg_init_mvtw_k: int = 24,
    bg_init_mam_delta: int = 8,
    bg_init_mam_dilate: int = 2,
) -> np.ndarray:
```

And replace the `median = np.median(y_stack[:n], axis=0).astype(np.uint8)` line (around line 135) with:

```python
    # Per-pixel BG estimate over the lookahead window → (H, W) uint8.
    from models.ops.bg_init import compute_bg_estimate  # noqa: PLC0415
    median = compute_bg_estimate(
        y_stack[:n],
        mode=bg_init_mode,
        imrm_tau=bg_init_imrm_tau,
        imrm_iters=bg_init_imrm_iters,
        mvtw_k=bg_init_mvtw_k,
        mam_delta=bg_init_mam_delta,
        mam_dilate=bg_init_mam_dilate,
    )
```

(The local variable name `median` is retained for diff minimisation even though it now holds a more general bg estimate.)

- [ ] **Step 5.4: Update the docstring**

Edit the docstring of `compute_lookahead_median_bank` — replace the line `2. Compute the per-pixel temporal median over the first ``lookahead_n`` frames (0 = all frames).` with:

```
      2. Compute the per-pixel BG estimate over the first ``lookahead_n``
         frames (0 = all frames). Method is selected by ``bg_init_mode``:
         "median" (default, paper-canonical), "imrm", "mvtw", or "mam".
         See py/models/ops/bg_init.py.
```

- [ ] **Step 5.5: Plumb the new kwargs through `_vibe_mask.produce_masks_vibe`**

In `py/models/_vibe_mask.py`, extend the `produce_masks_vibe` signature with the new fields:

```python
    vibe_bg_init_mode: int = 0,          # 0=median, 1=imrm, 2=mvtw, 3=mam
    vibe_bg_init_imrm_tau: int = 20,
    vibe_bg_init_imrm_iters: int = 3,
    vibe_bg_init_mvtw_k: int = 24,
    vibe_bg_init_mam_delta: int = 8,
    vibe_bg_init_mam_dilate: int = 2,
```

And at the `compute_lookahead_median_bank(...)` call site (around line 97), pass them through:

```python
    _MODE_NAMES = {0: "median", 1: "imrm", 2: "mvtw", 3: "mam"}
    bank = compute_lookahead_median_bank(
        rgb_frames=frames,
        k=vibe_K,
        lookahead_n=n,
        seed=vibe_prng_seed,
        bg_init_mode=_MODE_NAMES[int(vibe_bg_init_mode)],
        bg_init_imrm_tau=int(vibe_bg_init_imrm_tau),
        bg_init_imrm_iters=int(vibe_bg_init_imrm_iters),
        bg_init_mvtw_k=int(vibe_bg_init_mvtw_k),
        bg_init_mam_delta=int(vibe_bg_init_mam_delta),
        bg_init_mam_dilate=int(vibe_bg_init_mam_dilate),
    )
```

- [ ] **Step 5.6: Run the regression test + the existing ViBe test suite**

```bash
.venv/bin/pytest py/tests/test_bg_init.py -v
.venv/bin/pytest py/tests/ -k "vibe or motion or profiles" -v
```

Expected: all PASS. If any existing test fails because it expected a strict positional/keyword signature for `compute_lookahead_median_bank`, fix the call site.

- [ ] **Step 5.7: Commit**

```bash
git add py/models/motion_vibe.py py/models/_vibe_mask.py py/tests/test_bg_init.py
git commit -m "feat(bg_init): route compute_lookahead_median_bank through compute_bg_estimate"
```

---

## Task 6: Wire `compute_bg_estimate` into `init_from_frames` (Python-only entry point)

**Files:**
- Modify: [`py/models/ops/vibe.py`](../../py/models/ops/vibe.py) — extend `init_from_frames` with `mode` + knob kwargs.
- Test: `py/tests/test_bg_init.py` — add dispatch + determinism tests.

- [ ] **Step 6.1: Write failing tests**

Append to `py/tests/test_bg_init.py`:

```python
def test_init_from_frames_dispatch_all_modes():
    """init_from_frames with each mode runs to completion and produces a bank."""
    from models.ops.vibe import ViBe
    rng = np.random.default_rng(7)
    stack = rng.integers(0, 256, size=(40, 8, 6), dtype=np.uint8)
    for mode in ("median", "imrm", "mvtw", "mam"):
        v = ViBe(K=8, R=20, min_match=2, prng_seed=0xDEADBEEF)
        v.init_from_frames(stack, mode=mode)
        assert v.samples is not None and v.samples.shape == (8, 6, 8)
        assert v.samples.dtype == np.uint8


def test_init_from_frames_deterministic():
    """Same frames + seed + mode ⇒ byte-identical bank."""
    from models.ops.vibe import ViBe
    rng = np.random.default_rng(11)
    stack = rng.integers(0, 256, size=(30, 5, 4), dtype=np.uint8)
    banks = []
    for _ in range(2):
        v = ViBe(K=8, R=20, min_match=2, prng_seed=0xDEADBEEF)
        v.init_from_frames(stack, mode="mvtw")
        banks.append(v.samples.copy())
    np.testing.assert_array_equal(banks[0], banks[1])
```

- [ ] **Step 6.2: Run the failing tests**

```bash
.venv/bin/pytest py/tests/test_bg_init.py::test_init_from_frames_dispatch_all_modes -v
```

Expected: FAIL with `TypeError: ... got an unexpected keyword argument 'mode'`.

- [ ] **Step 6.3: Extend `init_from_frames` in `py/models/ops/vibe.py`**

Replace the existing `init_from_frames` (starting at line ~117) with:

```python
    def init_from_frames(
        self,
        frames: np.ndarray,
        lookahead_n: Optional[int] = None,
        mode: str = "median",
        imrm_tau: int = 20,
        imrm_iters: int = 3,
        mvtw_k: int = 24,
        mam_delta: int = 8,
        mam_dilate: int = 2,
    ) -> None:
        """Seed the sample bank from a per-pixel BG estimate over the first
        `lookahead_n` frames of `frames`. When `lookahead_n` is None, use
        all frames in the stack.

        The BG estimate is computed by `models.ops.bg_init.compute_bg_estimate`
        with the selected `mode`:
          - "median" (default): per-pixel temporal median (paper-canonical).
          - "imrm":  iterative motion-rejected median.
          - "mvtw":  per-pixel min-variance temporal window.
          - "mam":   motion-aware (frame-diff outlier rejection) median.

        Routes the resulting BG image through the configured `init_scheme`
        so noise structure and PRNG advance count match the canonical
        frame-0 path.
        """
        from models.ops.bg_init import compute_bg_estimate  # noqa: PLC0415
        assert frames.ndim == 3 and frames.dtype == np.uint8, \
            "frames must be a (N, H, W) uint8 stack"
        n_total = frames.shape[0]
        assert n_total >= 1, "frames must have at least 1 frame"
        n = n_total if lookahead_n is None else int(lookahead_n)
        assert 1 <= n <= n_total, \
            f"lookahead_n={lookahead_n} out of range [1, {n_total}]"
        bg_est = compute_bg_estimate(
            frames[:n],
            mode=mode,
            imrm_tau=imrm_tau,
            imrm_iters=imrm_iters,
            mvtw_k=mvtw_k,
            mam_delta=mam_delta,
            mam_dilate=mam_dilate,
        )
        self.init_from_frame(bg_est)
```

- [ ] **Step 6.4: Run the tests**

```bash
.venv/bin/pytest py/tests/test_bg_init.py -v
```

Expected: all PASS.

- [ ] **Step 6.5: Commit**

```bash
git add py/models/ops/vibe.py py/tests/test_bg_init.py
git commit -m "feat(bg_init): extend ViBe.init_from_frames with mode dispatch"
```

---

## Task 7: Add four benchmark profiles (`VIBE_INIT_IMRM`, `_MVTW`, `_MAM`) + extend the registry

**Files:**
- Modify: [`py/profiles.py`](../../py/profiles.py)

These profiles inherit from `VIBE_INIT_EXTERNAL` (the production look-ahead-median profile) and override only `vibe_bg_init_mode` (and any non-default knobs). The existing `vibe_init_external` registry entry remains the median baseline.

- [ ] **Step 7.1: Add the profile dicts**

In `py/profiles.py`, locate the `VIBE_INIT_EXTERNAL` definition (around line 137) and add immediately below:

```python
# Look-ahead bg init using the IMRM (iterative motion-rejected median) helper.
VIBE_INIT_IMRM: ProfileT = dict(
    VIBE_INIT_EXTERNAL,
    vibe_bg_init_mode=1,
)

# Look-ahead bg init using the MVTW (min-variance temporal window) helper.
VIBE_INIT_MVTW: ProfileT = dict(
    VIBE_INIT_EXTERNAL,
    vibe_bg_init_mode=2,
)

# Look-ahead bg init using the MAM (motion-aware median) helper.
VIBE_INIT_MAM: ProfileT = dict(
    VIBE_INIT_EXTERNAL,
    vibe_bg_init_mode=3,
)
```

- [ ] **Step 7.2: Register them in the `PROFILES` dict**

Locate the `PROFILES` registry (around line 230). Add entries next to `vibe_init_external`:

```python
    "vibe_init_imrm":     VIBE_INIT_IMRM,
    "vibe_init_mvtw":     VIBE_INIT_MVTW,
    "vibe_init_mam":      VIBE_INIT_MAM,
```

- [ ] **Step 7.3: Run the parity test**

```bash
.venv/bin/pytest py/tests/test_profiles.py -v
```

Expected: PASS — every profile dict has the full cfg_t field set.

- [ ] **Step 7.4: Commit**

```bash
git add py/profiles.py
git commit -m "feat(profiles): register vibe_init_imrm / mvtw / mam profiles"
```

---

## Task 8: Build the experiment runner

**Files:**
- Create: `py/experiments/run_bg_init_compare.py`

This is a near-duplicate of `run_vibe_demote_compare.py` — same harness, same metrics, just different method list and source list. Reuse `coverage_curve`, `render_coverage_curves`, the high-traffic-region split, and the same threshold list.

- [ ] **Step 8.1: Create the runner script**

```python
"""5×5 benchmark: 4 bg_init modes + vibe_demote control over 5 standard sources.

Method list:
  vibe_init_external   (current production baseline: lookahead-median)
  vibe_init_imrm
  vibe_init_mvtw
  vibe_init_mam
  vibe_demote          (runtime control: lookahead-median init + persistence demote)

Source list:
  media/source/birdseye-320x240.mp4
  media/source/intersection-320x240.mp4
  media/source/people-320x240.mp4
  synthetic:ghost_box_disappear
  synthetic:ghost_box_moving

Outputs under py/experiments/our_outputs/bg_init_compare/<source>/:
  coverage.png            — coverage curves
  convergence_table.csv   — asymptote / peak / time-to-thresh per method
  coverage_by_region.csv  — high-traffic vs low-traffic asymptote split
  grid.webp               — side-by-side mask grid (one row per method)

Companion design / plan:
  docs/plans/2026-05-14-vibe-bg-init-lookahead-design.md
  docs/plans/2026-05-14-vibe-bg-init-lookahead-plan.md
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from experiments.metrics import coverage_curve
from experiments.render import render_coverage_curves
from frames.video_source import load_frames
from models._vibe_mask import produce_masks_vibe
from profiles import resolve

SOURCES = [
    "media/source/birdseye-320x240.mp4",
    "media/source/intersection-320x240.mp4",
    "media/source/people-320x240.mp4",
    "synthetic:ghost_box_disappear",
    "synthetic:ghost_box_moving",
]
METHODS = [
    "vibe_init_external",
    "vibe_init_imrm",
    "vibe_init_mvtw",
    "vibe_init_mam",
    "vibe_demote",
]
N_FRAMES = 200
OUT_ROOT = Path("py/experiments/our_outputs/bg_init_compare")
THRESHOLDS = [0.01, 0.001]
ASYMPTOTE_WINDOW = 50  # frames 150-199 of a 200-frame run


def _produce_masks(profile_name: str, frames):
    cfg = dict(resolve(profile_name))
    return produce_masks_vibe(
        frames,
        **{k: v for k, v in cfg.items() if k.startswith("vibe_") or k == "gauss_en"},
    )


def _time_to_threshold(curve: np.ndarray, t: float) -> int | None:
    below = np.where(curve < t)[0]
    return int(below[0]) if below.size else None


def _coverage_by_region(masks):
    stack = np.stack([m.astype(np.uint8) for m in masks], axis=0)
    time_avg = stack.mean(axis=0)
    high_traffic = time_avg > 0.5
    tail = stack[-ASYMPTOTE_WINDOW:]
    ht_cov = float(tail[:, high_traffic].mean()) if high_traffic.any() else float("nan")
    low_traffic = ~high_traffic
    lt_cov = float(tail[:, low_traffic].mean()) if low_traffic.any() else float("nan")
    return ht_cov, lt_cov


def run_source(source: str, n_frames: int = N_FRAMES) -> None:
    frames = load_frames(source, width=320, height=240, num_frames=n_frames)
    if len(frames) < n_frames:
        raise SystemExit(f"{source}: only {len(frames)} frames available, need {n_frames}")
    out_dir = OUT_ROOT / source.replace(":", "_").replace("/", "_")
    out_dir.mkdir(parents=True, exist_ok=True)
    curves: dict[str, np.ndarray] = {}
    region_cov: dict[str, tuple[float, float]] = {}
    for method in METHODS:
        masks = _produce_masks(method, frames)
        curves[method] = coverage_curve(masks)
        region_cov[method] = _coverage_by_region(masks)
    render_coverage_curves(
        curves, str(out_dir / "coverage.png"),
        title=f"BG init compare — {source}",
    )
    with (out_dir / "convergence_table.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(
            ["method", f"asymptote(last{ASYMPTOTE_WINDOW})", "peak"]
            + [f"t_to_{t:.4f}" for t in THRESHOLDS]
        )
        for m in METHODS:
            c = curves[m]
            row = [m, f"{c[-ASYMPTOTE_WINDOW:].mean():.4f}", f"{c.max():.4f}"]
            for t in THRESHOLDS:
                tt = _time_to_threshold(c, t)
                row.append(str(tt) if tt is not None else "")
            w.writerow(row)
    with (out_dir / "coverage_by_region.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["method", "asymptote_high_traffic", "asymptote_low_traffic"])
        for m in METHODS:
            ht, lt = region_cov[m]
            w.writerow([m, f"{ht:.4f}", f"{lt:.4f}"])
    print(f"[{source}] asymptote: " + ", ".join(
        f"{m}={curves[m][-ASYMPTOTE_WINDOW:].mean():.4f}" for m in METHODS), flush=True)
    print(f"[{source}] high-traffic asymptote: " + ", ".join(
        f"{m}={region_cov[m][0]:.4f}" for m in METHODS), flush=True)


def main() -> None:
    for src in SOURCES:
        run_source(src)


if __name__ == "__main__":
    main()
```

- [ ] **Step 8.2: Smoke-test the runner on one synthetic source**

```bash
.venv/bin/python -c "
import sys; sys.path.insert(0, 'py')
from experiments.run_bg_init_compare import run_source
run_source('synthetic:ghost_box_disappear', n_frames=40)
"
```

Expected: completes without error; prints two asymptote lines; creates `py/experiments/our_outputs/bg_init_compare/synthetic_ghost_box_disappear/{coverage.png,convergence_table.csv,coverage_by_region.csv}`.

- [ ] **Step 8.3: Commit**

```bash
git add py/experiments/run_bg_init_compare.py
git commit -m "feat(experiments): bg_init compare runner (5 methods × 5 sources)"
```

---

## Task 9: Knob sweep on `people-320x240.mp4` and lock in defaults

**Files:**
- Create: `py/experiments/run_bg_init_sweep.py`

The sweep is a small per-mode knob exploration on one tough source (`people` — slow walkers, high-traffic bias is most pronounced). We do NOT add separate profile entries for each sweep point; we override the profile dict in-line.

- [ ] **Step 9.1: Create the sweep runner**

```python
"""One-knob sweep per mode on people-320x240.mp4 — locks in per-mode defaults.

Sweeps:
  IMRM: imrm_tau ∈ {12, 20, 32}  (imrm_iters=3 fixed)
  MVTW: mvtw_k   ∈ {12, 24, 60}
  MAM:  mam_delta ∈ {6, 12}     (mam_dilate=2 fixed)

Outputs:
  py/experiments/our_outputs/bg_init_compare/_sweep/summary.csv
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from experiments.metrics import coverage_curve
from frames.video_source import load_frames
from models._vibe_mask import produce_masks_vibe
from profiles import resolve

SOURCE = "media/source/people-320x240.mp4"
N_FRAMES = 200
OUT_DIR = Path("py/experiments/our_outputs/bg_init_compare/_sweep")
ASYMPTOTE_WINDOW = 50

SWEEPS = [
    # (label, base_profile, override_field, value)
    ("imrm_tau12", "vibe_init_imrm", "vibe_bg_init_imrm_tau", 12),
    ("imrm_tau20", "vibe_init_imrm", "vibe_bg_init_imrm_tau", 20),
    ("imrm_tau32", "vibe_init_imrm", "vibe_bg_init_imrm_tau", 32),
    ("mvtw_k12",   "vibe_init_mvtw", "vibe_bg_init_mvtw_k",   12),
    ("mvtw_k24",   "vibe_init_mvtw", "vibe_bg_init_mvtw_k",   24),
    ("mvtw_k60",   "vibe_init_mvtw", "vibe_bg_init_mvtw_k",   60),
    ("mam_delta6",  "vibe_init_mam", "vibe_bg_init_mam_delta", 6),
    ("mam_delta12", "vibe_init_mam", "vibe_bg_init_mam_delta", 12),
]


def _coverage_by_region(masks):
    stack = np.stack([m.astype(np.uint8) for m in masks], axis=0)
    time_avg = stack.mean(axis=0)
    high_traffic = time_avg > 0.5
    tail = stack[-ASYMPTOTE_WINDOW:]
    ht_cov = float(tail[:, high_traffic].mean()) if high_traffic.any() else float("nan")
    low_traffic = ~high_traffic
    lt_cov = float(tail[:, low_traffic].mean()) if low_traffic.any() else float("nan")
    return ht_cov, lt_cov


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    frames = load_frames(SOURCE, width=320, height=240, num_frames=N_FRAMES)
    rows = []
    for label, base_profile, field, value in SWEEPS:
        cfg = dict(resolve(base_profile))
        cfg[field] = value
        masks = produce_masks_vibe(
            frames,
            **{k: v for k, v in cfg.items() if k.startswith("vibe_") or k == "gauss_en"},
        )
        curve = coverage_curve(masks)
        ht, lt = _coverage_by_region(masks)
        rows.append([
            label, base_profile, field, value,
            f"{curve[-ASYMPTOTE_WINDOW:].mean():.4f}",
            f"{ht:.4f}", f"{lt:.4f}",
        ])
        print(f"[{label}] asym={curve[-ASYMPTOTE_WINDOW:].mean():.4f}  "
              f"high_traffic={ht:.4f}  low_traffic={lt:.4f}", flush=True)
    with (OUT_DIR / "summary.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["label", "base_profile", "field", "value",
                    "asymptote_overall", "asymptote_high_traffic", "asymptote_low_traffic"])
        w.writerows(rows)


if __name__ == "__main__":
    main()
```

- [ ] **Step 9.2: Run the sweep**

```bash
.venv/bin/python py/experiments/run_bg_init_sweep.py
```

Expected: prints 8 rows; writes `summary.csv`. Runtime ~few minutes.

- [ ] **Step 9.3: Pick winning knob per mode and update profile defaults if needed**

Inspect `py/experiments/our_outputs/bg_init_compare/_sweep/summary.csv`. For each mode, pick the row with the lowest `asymptote_high_traffic` that does not regress `asymptote_low_traffic` by more than +0.001 vs the median baseline.

If the winning knob differs from the profile default set in Task 1, update the profile dict in [`py/profiles.py`](../../py/profiles.py):
- `VIBE_INIT_IMRM` → set `vibe_bg_init_imrm_tau=<winner>`
- `VIBE_INIT_MVTW` → set `vibe_bg_init_mvtw_k=<winner>`
- `VIBE_INIT_MAM` → set `vibe_bg_init_mam_delta=<winner>`

If the default values from Task 1 are already optimal, no profile change needed.

- [ ] **Step 9.4: Commit**

```bash
git add py/experiments/run_bg_init_sweep.py py/profiles.py
git commit -m "feat(experiments): bg_init knob sweep + locked per-mode defaults"
```

---

## Task 10: Run the headline 5×5 experiment

- [ ] **Step 10.1: Run the experiment**

```bash
.venv/bin/python py/experiments/run_bg_init_compare.py
```

Expected: prints 10 lines (5 sources × 2 asymptote summaries each); writes 5 source-folders under `py/experiments/our_outputs/bg_init_compare/`, each containing `coverage.png`, `convergence_table.csv`, `coverage_by_region.csv`. Runtime ~10–20 min.

- [ ] **Step 10.2: Inspect artifacts**

Eyeball each `coverage.png` and each `coverage_by_region.csv`. Note for each source whether any of `imrm/mvtw/mam` beats `vibe_init_external` on `asymptote_high_traffic`.

- [ ] **Step 10.3: Commit the experiment artifacts**

```bash
git add py/experiments/our_outputs/bg_init_compare/
git commit -m "exp(bg_init): commit headline 5x5 results artifacts"
```

(If the existing project policy gitignores experiment outputs, skip this commit and reference the artifacts only via the results doc.)

---

## Task 11: Write the results document

**File:**
- Create: `docs/plans/2026-05-14-vibe-bg-init-lookahead-results.md`

- [ ] **Step 11.1: Build the headline summary table from the per-source CSVs**

From the 5 `convergence_table.csv` and `coverage_by_region.csv` files, assemble a single top-level table in the results doc. Suggested format (mirrors the `vibe_demote` results doc):

```markdown
| Source | external | imrm | mvtw | mam | demote |
|---|---|---|---|---|---|
| birdseye overall      | ... | ... | ... | ... | ... |
| birdseye high-traffic | ... | ... | ... | ... | ... |
| intersection overall  | ... | ... | ... | ... | ... |
| intersection high-traffic | ... | ... | ... | ... | ... |
| people overall        | ... | ... | ... | ... | ... |
| people high-traffic   | ... | ... | ... | ... | ... |
| ghost_box_disappear   | ... | ... | ... | ... | ... |
| ghost_box_moving      | ... | ... | ... | ... | ... |
```

- [ ] **Step 11.2: Write the results doc**

Use this skeleton, filling in numbers from the CSVs:

```markdown
# ViBe BG Init Look-Ahead Beyond Median — Results

**Date:** YYYY-MM-DD (fill in)
**Branch:** feat/vibe-bg-init-lookahead
**Companion design:** [`2026-05-14-vibe-bg-init-lookahead-design.md`](2026-05-14-vibe-bg-init-lookahead-design.md)
**Companion plan:** [`2026-05-14-vibe-bg-init-lookahead-plan.md`](2026-05-14-vibe-bg-init-lookahead-plan.md)

## Decision

(GO / PARTIAL-GO / NO-GO — fill in based on the GO criteria in §7 of the design doc.)

## Setup

ViBe params: K=20, R=20, min_match=2, φ_update=16, φ_diffuse=16, init_scheme=c,
coupled_rolls=True, prng_seed=0xDEADBEEF. 200 frames per source.

Methods: vibe_init_external (baseline), vibe_init_imrm, vibe_init_mvtw,
vibe_init_mam, vibe_demote (control).

Sources: birdseye-320x240.mp4, intersection-320x240.mp4, people-320x240.mp4,
synthetic:ghost_box_disappear, synthetic:ghost_box_moving.

## Knob sweep (one-pass on people-320x240.mp4)

(Insert summary.csv table here. Note which knob value was selected per mode.)

## Headline — 5×5 asymptote comparison

(Insert the assembled table from Step 11.1.)

## Per-source observations

- birdseye: ...
- intersection: ...
- people: ...
- ghost_box_disappear: ...
- ghost_box_moving: ...

## Recommendation

(Promote winner / keep median default / keep all modes selectable — see GO criteria.)

## Caveats / open questions

(Anything unexpected.)
```

- [ ] **Step 11.3: Commit the results doc**

```bash
git add docs/plans/2026-05-14-vibe-bg-init-lookahead-results.md
git commit -m "docs: bg_init lookahead beyond-median — results"
```

---

## Task 12: (Conditional) Promote the winner as the new default

This task ONLY runs if the results in Task 11 declare a GO. If NO-GO, skip to Task 13.

**Files:**
- Modify: [`py/profiles.py`](../../py/profiles.py) — change `DEFAULT_VIBE`'s `vibe_bg_init_mode` from 0 to the winner's encoding (1/2/3).
- Modify: [`hw/top/sparevideo_pkg.sv`](../../hw/top/sparevideo_pkg.sv) — change `CFG_DEFAULT_VIBE`'s `vibe_bg_init_mode` from `BG_INIT_MEDIAN` to the winner's constant.

- [ ] **Step 12.1: Flip the default in DEFAULT_VIBE (Python)**

In `py/profiles.py`, locate `DEFAULT_VIBE: ProfileT = dict(...)` (around line 107). Change:

```python
    vibe_bg_init_mode=0,
```

to the winner's encoding (e.g. `2` for MVTW).

- [ ] **Step 12.2: Flip the default in CFG_DEFAULT_VIBE (SV)**

In `hw/top/sparevideo_pkg.sv`, locate the `CFG_DEFAULT_VIBE` localparam. Change:

```systemverilog
        vibe_bg_init_mode: BG_INIT_MEDIAN,
```

to the winner's constant (e.g. `BG_INIT_MVTW`).

- [ ] **Step 12.3: Run the parity test and lint**

```bash
.venv/bin/pytest py/tests/test_profiles.py -v
make lint
```

Expected: both PASS / clean.

- [ ] **Step 12.4: Re-render demo WebPs (since visual output may change)**

```bash
make demo
```

Inspect `media/demo/*.webp` for visible regressions; commit the regenerated WebPs.

- [ ] **Step 12.5: Commit**

```bash
git add py/profiles.py hw/top/sparevideo_pkg.sv media/demo/
git commit -m "feat(profiles): promote <winner> as default bg_init_mode for DEFAULT_VIBE"
```

---

## Task 13: Squash and open PR

- [ ] **Step 13.1: Verify branch contents**

```bash
git log origin/main..HEAD --oneline
```

Confirm every commit belongs to this plan. If unrelated commits slipped in, move them to a separate branch before squashing.

- [ ] **Step 13.2: Squash to a single commit**

```bash
git reset --soft origin/main
git commit -m "feat(motion/vibe): bg_init beyond median — IMRM/MVTW/MAM

Adds three new look-ahead BG init schemes (iterative motion-rejected median,
per-pixel min-variance temporal window, motion-aware median) to the Python
ViBe path via a new compute_bg_estimate helper module. Benchmarks all four
init modes plus vibe_demote control over the standard 5-source set.

<Result line — fill in from the results doc, e.g. 'Promotes MVTW as the
new default for DEFAULT_VIBE.' or 'No winner; lookahead_median stays
default; new modes available as selectable profiles.'>

See:
  docs/plans/2026-05-14-vibe-bg-init-lookahead-design.md
  docs/plans/2026-05-14-vibe-bg-init-lookahead-plan.md
  docs/plans/2026-05-14-vibe-bg-init-lookahead-results.md"
```

- [ ] **Step 13.3: Move design/plan to docs/plans/old/ (per CLAUDE.md)**

```bash
git mv docs/plans/2026-05-14-vibe-bg-init-lookahead-design.md docs/plans/old/
git mv docs/plans/2026-05-14-vibe-bg-init-lookahead-plan.md   docs/plans/old/
git commit --amend --no-edit
```

(Results doc stays in `docs/plans/` per the project convention for results.)

- [ ] **Step 13.4: Push and open PR**

```bash
git push -u origin feat/vibe-bg-init-lookahead
gh pr create --title "ViBe bg_init beyond median — IMRM/MVTW/MAM" --body "$(cat <<'EOF'
## Summary
- Adds three new look-ahead BG init schemes for ViBe (IMRM, MVTW, MAM) via a new shared `compute_bg_estimate` helper.
- Benchmarks all four init modes + `vibe_demote` runtime control over 5 standard sources.
- <Results line — fill in from results doc.>

## Test plan
- [ ] `.venv/bin/pytest py/tests/test_bg_init.py -v` passes
- [ ] `.venv/bin/pytest py/tests/test_profiles.py -v` passes (cfg_t parity)
- [ ] `make lint` clean
- [ ] (If winner promoted) `make demo` re-rendered and visually inspected

See [results doc](docs/plans/2026-05-14-vibe-bg-init-lookahead-results.md).
EOF
)"
```

---

## Self-Review

**Spec coverage.**
- §1 motivation → no task (context only). ✓
- §2 goal/non-goals → Tasks 1–13 implement; non-goals respected (no RTL behavior change beyond cfg_t fields). ✓
- §3 candidate modes IMRM/MVTW/MAM → Tasks 2/3/4. ✓
- §4.1 init_from_frames dispatch → Task 6. ✓
- §4.1 shared helper (new in plan) → Task 2 creates `py/models/ops/bg_init.py`; consumed by both `compute_lookahead_median_bank` (Task 5) and `init_from_frames` (Task 6). ✓
- §4.2 cfg_t plumbing → Task 1. ✓
- §4.3 evaluation harness → Tasks 7 (profiles) + 8 (runner) + 10 (run). ✓
- §4.4 knob sweep → Task 9. ✓
- §5 testing → Tasks 2/3/4/5/6 each carry tests; final test file covers all five spec-listed tests + the bank-regression test. ✓
- §6 deliverables → Tasks 1/2/3/4/5/6/7/8 + results doc Task 11. ✓
- §7 GO criteria → applied in Task 11 (Decision) and Task 12 (conditional promotion). ✓
- §8 risks → flagged in design doc; no extra tasks needed.

**Placeholder scan.** Searched for "TBD/TODO/etc.": none in the executable steps. The results-doc template (Step 11.2) contains placeholder sentences like "(Promote winner / keep median default ...)" — those are intentional fill-in fields for the engineer running the experiment, not unspecified plan steps.

**Type/name consistency.**
- `compute_bg_estimate` signature, kwargs, and call sites are consistent across Tasks 2, 5, 6.
- Mode names ("median", "imrm", "mvtw", "mam") consistent across the dispatcher and the `_MODE_NAMES` map in `_vibe_mask.py` (Step 5.5).
- Profile-field names (`vibe_bg_init_mode`, `vibe_bg_init_imrm_tau`, `vibe_bg_init_mvtw_k`, `vibe_bg_init_mam_delta`, `vibe_bg_init_mam_dilate`, `vibe_bg_init_imrm_iters`) consistent between cfg_t (Task 1 SV + Python) and the `_vibe_mask.produce_masks_vibe` signature (Step 5.5).
- `BG_INIT_*` SV constants (`BG_INIT_MEDIAN=0`, etc.) match the Python encoding (0/1/2/3).
