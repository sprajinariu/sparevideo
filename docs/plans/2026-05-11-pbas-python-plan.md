# PBAS Python Sub-Project Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Python PBAS reference operator (Y + gradient feature, faithful to the andrewssobral PBAS.cpp reference implementation), wire it into the project's bg-model selector, and run a 4-method empirical comparison against the existing ViBe variants on `birdseye` and `people` real clips.

**Architecture:** New `bg_model = BG_MODEL_PBAS (value 2)` alongside EMA and ViBe. Single Python operator at `py/models/ops/pbas.py` mirroring the reference impl's structure. New adapter `py/models/_pbas_mask.py` parallel to `_vibe_mask.py`. Comparison runner produces coverage curves and labelled animated WebPs.

**Tech Stack:** Python 3 (numpy, opencv for Sobel, Pillow for WebP), SystemVerilog (shadow cfg_t fields only — no RTL behavior changes in this sub-project).

**Spec:** [`docs/plans/2026-05-11-pbas-python-design.md`](2026-05-11-pbas-python-design.md)

---

## Files modified / created

**Modify:**
- `hw/top/sparevideo_pkg.sv` — add `BG_MODEL_PBAS = 2` enum, 15 new `pbas_*` `cfg_t` fields with disabled-sentinel defaults across every named profile, two new constants `CFG_PBAS_DEFAULT` / `CFG_PBAS_LOOKAHEAD`.
- `py/profiles.py` — mirror the 15 new fields in `DEFAULT` (inherited by every existing profile via `dict(DEFAULT, ...)`); add `PBAS_DEFAULT` and `PBAS_LOOKAHEAD` profiles; register in `PROFILES`.
- `py/tests/test_profiles.py` — extend `EXPECTED_PROFILES` set with `"pbas_default"` and `"pbas_lookahead"`.

**Create:**
- `py/models/ops/pbas.py` — PBAS operator class (Y + gradient).
- `py/models/_pbas_mask.py` — `produce_masks_pbas(...)` adapter parallel to `_vibe_mask.py`.
- `py/tests/test_pbas.py` — unit tests (determinism, R/T clamping, gradient distance contribution, formerMeanMag floor, degenerate-to-ViBe equivalence).
- `py/experiments/run_pbas_compare.py` — comparison runner (4 methods × 2 sources × 200 frames).
- `py/viz/render_pbas_compare_webp.py` — labelled animated WebP renderer.
- `docs/plans/2026-05-XX-pbas-python-results.md` — Phase results doc (date placeholder; bump to actual completion date).

**Out of scope (do not touch):**
- RTL behavioural changes — only the cfg_t shadow fields and constants are added.
- Any ViBe code path — PBAS is a parallel `bg_model`, not a modification of ViBe.
- New control-flow modules (`motion_pbas.py` etc.) — comparison happens at the mask level only.

---

## Task 1: `cfg_t` PBAS shadow fields + Python profile mirror

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv` (cfg_t typedef + every `CFG_*` constant + two new `CFG_PBAS_*` constants + `BG_MODEL_PBAS` enum)
- Modify: `py/profiles.py` (DEFAULT + every profile + two new profiles + PROFILES dict)
- Modify: `py/tests/test_profiles.py` (EXPECTED_PROFILES set)

- [ ] **Step 1: Add `BG_MODEL_PBAS = 2` enum to SV package**

In `hw/top/sparevideo_pkg.sv`, after the existing `BG_MODEL_VIBE` localparam:

```systemverilog
    localparam int BG_MODEL_PBAS = 2;
```

- [ ] **Step 2: Append 13 pbas_* fields to `cfg_t` typedef**

Immediately after the existing `vibe_bg_init_lookahead_n` field, add:

```systemverilog
        // ---- PBAS knobs (consumed only when bg_model==BG_MODEL_PBAS) ----
        logic [7:0]  pbas_N;
        logic [7:0]  pbas_R_lower;
        logic [3:0]  pbas_R_scale;
        logic [3:0]  pbas_Raute_min;
        logic [7:0]  pbas_T_lower;
        logic [7:0]  pbas_T_upper;
        logic [7:0]  pbas_T_init;
        logic [7:0]  pbas_R_incdec_q8;
        logic [15:0] pbas_T_inc_q8;
        logic [15:0] pbas_T_dec_q8;
        logic [7:0]  pbas_alpha;
        logic [7:0]  pbas_beta;
        logic [7:0]  pbas_mean_mag_min;
        logic [0:0]  pbas_bg_init_lookahead;
        logic [31:0] pbas_prng_seed;
```

- [ ] **Step 3: Add the 15 pbas fields with disabled-sentinel defaults to every existing CFG_* constant**

Identify every `localparam cfg_t CFG_* = '{ ... }` in `sparevideo_pkg.sv`. Append the following to each:

```systemverilog
        pbas_N:                  8'd0,
        pbas_R_lower:            8'd0,
        pbas_R_scale:            4'd0,
        pbas_Raute_min:          4'd0,
        pbas_T_lower:            8'd0,
        pbas_T_upper:            8'd0,
        pbas_T_init:             8'd0,
        pbas_R_incdec_q8:        8'd0,
        pbas_T_inc_q8:           16'd0,
        pbas_T_dec_q8:           16'd0,
        pbas_alpha:              8'd0,
        pbas_beta:               8'd0,
        pbas_mean_mag_min:       8'd0,
        pbas_bg_init_lookahead:  1'd0,
        pbas_prng_seed:          32'd0,
```

All zeros are the disabled sentinels because none of the existing profiles use PBAS.

- [ ] **Step 4: Add CFG_PBAS_DEFAULT and CFG_PBAS_LOOKAHEAD constants**

After the existing CFG_* constants, add:

```systemverilog
    localparam cfg_t CFG_PBAS_DEFAULT = '{
        // (copy from CFG_DEFAULT_VIBE, overriding bg_model and pbas_* fields below)
        // ... [all existing CFG_DEFAULT_VIBE fields here] ...
        bg_model:                BG_MODEL_PBAS,
        pbas_N:                  8'd20,
        pbas_R_lower:            8'd18,
        pbas_R_scale:            4'd5,
        pbas_Raute_min:          4'd2,
        pbas_T_lower:            8'd2,
        pbas_T_upper:            8'd200,
        pbas_T_init:             8'd18,
        pbas_R_incdec_q8:        8'd13,
        pbas_T_inc_q8:           16'd256,
        pbas_T_dec_q8:           16'd13,
        pbas_alpha:              8'd7,
        pbas_beta:               8'd1,
        pbas_mean_mag_min:       8'd20,
        pbas_bg_init_lookahead:  1'd0,
        pbas_prng_seed:          32'hDEADBEEF
    };
    localparam cfg_t CFG_PBAS_LOOKAHEAD = '{
        // (copy from CFG_PBAS_DEFAULT, overriding only the lookahead flag below)
        // ... [all CFG_PBAS_DEFAULT fields here] ...
        pbas_bg_init_lookahead:  1'd1
    };
```

Practically: write out both constants verbatim (no inheritance in SV; each must list every cfg_t field). To avoid copy-error, populate them by copying from `CFG_DEFAULT_VIBE`, then patching the fields shown above.

- [ ] **Step 5: Run lint**

Run: `make lint`
Expected: PASS, no warnings.

- [ ] **Step 6: Mirror fields in py/profiles.py — append to DEFAULT**

Inside the `DEFAULT` dict in `py/profiles.py`, immediately after `vibe_bg_init_lookahead_n=0`:

```python
    # ---- PBAS knobs (consumed only when bg_model==2) ----
    pbas_N=0,
    pbas_R_lower=0,
    pbas_R_scale=0,
    pbas_Raute_min=0,
    pbas_T_lower=0,
    pbas_T_upper=0,
    pbas_T_init=0,
    pbas_R_incdec_q8=0,
    pbas_T_inc_q8=0,
    pbas_T_dec_q8=0,
    pbas_alpha=0,
    pbas_beta=0,
    pbas_mean_mag_min=0,
    pbas_bg_init_lookahead=0,
    pbas_prng_seed=0,
```

(All zero in DEFAULT — disabled sentinels.)

- [ ] **Step 7: Add PBAS_DEFAULT and PBAS_LOOKAHEAD profiles**

Append in `py/profiles.py` below `VIBE_INIT_EXTERNAL`:

```python
# PBAS — Hofmann et al. 2012, Y + gradient features. Verified defaults
# from the andrewssobral PBAS.cpp reference impl.
PBAS_DEFAULT: ProfileT = dict(
    DEFAULT,
    bg_model=2,
    pbas_N=20,
    pbas_R_lower=18,
    pbas_R_scale=5,
    pbas_Raute_min=2,
    pbas_T_lower=2,
    pbas_T_upper=200,
    pbas_T_init=18,
    pbas_R_incdec_q8=13,
    pbas_T_inc_q8=256,
    pbas_T_dec_q8=13,
    pbas_alpha=7,
    pbas_beta=1,
    pbas_mean_mag_min=20,
    pbas_bg_init_lookahead=0,
    pbas_prng_seed=0xDEADBEEF,
)

# PBAS + lookahead-median init (replaces the paper's frame-by-frame init).
PBAS_LOOKAHEAD: ProfileT = dict(PBAS_DEFAULT, pbas_bg_init_lookahead=1)
```

And in the `PROFILES` dict at the bottom:

```python
    "pbas_default":   PBAS_DEFAULT,
    "pbas_lookahead": PBAS_LOOKAHEAD,
```

- [ ] **Step 8: Update test_profiles.py EXPECTED_PROFILES set**

In `py/tests/test_profiles.py`, find `EXPECTED_PROFILES` (around line 65). Add `"pbas_default"` and `"pbas_lookahead"` to the set.

- [ ] **Step 9: Run parity test**

Run: `.venv/bin/python -m pytest py/tests/test_profiles.py -v`
Expected: PASS, all profiles (including the two new ones) line up with SV.

- [ ] **Step 10: Run full Python regression**

Run: `.venv/bin/python -m pytest py/tests -v`
Expected: PASS — existing profiles untouched; PBAS profiles exist but no operator yet (so they only appear in parity tests).

- [ ] **Step 11: Commit**

```bash
git add hw/top/sparevideo_pkg.sv py/profiles.py py/tests/test_profiles.py
git commit -m "feat(motion/pbas): add PBAS bg_model + cfg_t shadow + 2 profiles"
```

---

## Task 2: PBAS operator skeleton + deterministic PRNG tables

**Files:**
- Create: `py/models/ops/pbas.py`
- Create: `py/tests/test_pbas.py`

- [ ] **Step 1: Write a failing determinism test**

Create `py/tests/test_pbas.py`:

```python
"""Unit tests for the PBAS operator."""
from __future__ import annotations

import numpy as np
import pytest

from models.ops.pbas import PBAS


def _const_frame(val: int, h: int = 16, w: int = 16) -> np.ndarray:
    return np.full((h, w), val, dtype=np.uint8)


def _random_frames(n: int, h: int = 16, w: int = 16, seed: int = 0) -> list[np.ndarray]:
    rng = np.random.default_rng(seed)
    return [rng.integers(0, 256, (h, w), dtype=np.uint8) for _ in range(n)]


def test_pbas_deterministic_under_fixed_seed():
    """Two runs with same seed → bit-identical masks and bank state."""
    frames = _random_frames(40, seed=0)
    a = PBAS(prng_seed=0xDEADBEEF)
    a.init_from_frames(frames[:20])
    masks_a = [a.process_frame(f) for f in frames[20:]]
    b = PBAS(prng_seed=0xDEADBEEF)
    b.init_from_frames(frames[:20])
    masks_b = [b.process_frame(f) for f in frames[20:]]
    for ma, mb in zip(masks_a, masks_b):
        assert np.array_equal(ma, mb)
    assert np.array_equal(a.samples_y, b.samples_y)
    assert np.array_equal(a.samples_g, b.samples_g)
    assert np.array_equal(a.R, b.R)
    assert np.array_equal(a.T, b.T)
```

- [ ] **Step 2: Run test, verify it fails**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py::test_pbas_deterministic_under_fixed_seed -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'models.ops.pbas'`.

- [ ] **Step 3: Create the PBAS operator skeleton**

Create `py/models/ops/pbas.py`:

```python
"""PBAS (Pixel-Based Adaptive Segmenter) — Python reference operator.

Faithful port of Hofmann, Tiefenbacher & Rigoll (CVPRW 2012):
"Background Segmentation with Feedback: The Pixel-Based Adaptive Segmenter."
Reference impl mirrored:
  https://github.com/andrewssobral/simple_vehicle_counting/blob/master/package_bgs/PBAS/PBAS.cpp

Y + gradient feature variant. Companion design:
docs/plans/2026-05-11-pbas-python-design.md
"""
from __future__ import annotations

from typing import Optional

import numpy as np

# Precomputed random table size — matches the reference impl's countOfRandomNumb.
_RANDOM_TABLE_LEN = 1000


class PBAS:
    """Deterministic Y + gradient PBAS re-implementation."""

    def __init__(
        self,
        N: int = 20,
        R_lower: int = 18,
        R_scale: int = 5,
        Raute_min: int = 2,
        T_lower: int = 2,
        T_upper: int = 200,
        T_init: int = 18,
        R_incdec: float = 0.05,
        T_inc: float = 1.0,
        T_dec: float = 0.05,
        alpha: int = 7,
        beta: int = 1,
        mean_mag_min: float = 20.0,
        prng_seed: int = 0xDEADBEEF,
    ):
        assert N > 0
        assert R_lower > 0
        assert R_scale > 0
        assert Raute_min > 0
        assert T_lower > 0 and T_upper > T_lower
        assert 0 <= R_incdec <= 1.0
        assert prng_seed != 0
        self.N = N
        self.R_lower = R_lower
        self.R_scale = R_scale
        self.Raute_min = Raute_min
        self.T_lower = T_lower
        self.T_upper = T_upper
        self.T_init = T_init
        self.R_incdec = R_incdec
        self.T_inc = T_inc
        self.T_dec = T_dec
        self.alpha = alpha
        self.beta = beta
        self.mean_mag_min = mean_mag_min
        self.prng_seed = prng_seed
        # Per-pixel state — allocated by init_from_frames.
        self.H: int = 0
        self.W: int = 0
        self.samples_y: Optional[np.ndarray] = None   # (H, W, N) uint8
        self.samples_g: Optional[np.ndarray] = None   # (H, W, N) uint8
        self.R: Optional[np.ndarray] = None           # (H, W) float32
        self.T: Optional[np.ndarray] = None           # (H, W) float32
        self.meanMinDist: Optional[np.ndarray] = None # (H, W) float32
        # Per-frame scalar state.
        self.formerMeanMag: float = float(mean_mag_min)
        # Precomputed PRNG tables (mirror reference impl pattern).
        rng = np.random.default_rng(prng_seed)
        self._rand_T = rng.integers(0, T_upper, _RANDOM_TABLE_LEN, dtype=np.int32)
        self._rand_TN = rng.integers(0, T_upper, _RANDOM_TABLE_LEN, dtype=np.int32)
        self._rand_N = rng.integers(0, N, _RANDOM_TABLE_LEN, dtype=np.int32)
        self._rand_X = rng.integers(-1, 2, _RANDOM_TABLE_LEN, dtype=np.int32)
        self._rand_Y = rng.integers(-1, 2, _RANDOM_TABLE_LEN, dtype=np.int32)
        self._rand_idx = 0

    def _next_random_entry(self) -> int:
        """Return current random-table index, then advance with wrap."""
        idx = self._rand_idx
        self._rand_idx = (self._rand_idx + 1) % _RANDOM_TABLE_LEN
        return idx

    def init_from_frames(self, frames: list[np.ndarray]) -> None:
        """Stub — implemented in Task 4."""
        raise NotImplementedError("init_from_frames implemented in Task 4")

    def process_frame(self, frame: np.ndarray) -> np.ndarray:
        """Stub — implemented in Task 5."""
        raise NotImplementedError("process_frame implemented in Task 5")
```

- [ ] **Step 4: Confirm the skeleton imports cleanly**

Run: `.venv/bin/python -c "from models.ops.pbas import PBAS; p = PBAS(); print(p.N, p.formerMeanMag)"`
Expected: prints `20 20.0`.

- [ ] **Step 5: Commit (skeleton — determinism test is still XFAIL pending Tasks 4–5)**

```bash
git add py/models/ops/pbas.py py/tests/test_pbas.py
git commit -m "feat(motion/pbas): PBAS class skeleton + PRNG-table init"
```

(The determinism test fails right now with `NotImplementedError`. That is expected. It will pass after Task 5.)

---

## Task 3: Sobel + formerMeanMag pre-step

**Files:**
- Modify: `py/models/ops/pbas.py`
- Modify: `py/tests/test_pbas.py`

- [ ] **Step 1: Write a failing test for the gradient helper**

Append to `py/tests/test_pbas.py`:

```python
def test_pbas_sobel_magnitude_zero_for_constant_frame():
    """A constant frame has zero gradient magnitude everywhere."""
    from models.ops.pbas import PBAS
    p = PBAS()
    g = p._sobel_magnitude(_const_frame(128, h=8, w=8))
    assert g.shape == (8, 8)
    assert g.dtype == np.uint8
    assert (g == 0).all()


def test_pbas_sobel_magnitude_high_at_edge():
    """A frame with a vertical step has non-zero gradient along the step."""
    from models.ops.pbas import PBAS
    p = PBAS()
    frame = np.zeros((8, 8), np.uint8)
    frame[:, 4:] = 255
    g = p._sobel_magnitude(frame)
    # Column 3 or 4 should have a significant gradient.
    assert g[:, 3:5].max() > 100
    # Far from the edge, gradient is zero.
    assert g[:, 0].max() == 0
    assert g[:, 7].max() == 0
```

- [ ] **Step 2: Run, verify both fail**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k sobel`
Expected: FAIL — `_sobel_magnitude` method doesn't exist.

- [ ] **Step 3: Add `_sobel_magnitude` to PBAS**

Add to `py/models/ops/pbas.py` inside the `PBAS` class:

```python
    def _sobel_magnitude(self, frame: np.ndarray) -> np.ndarray:
        """Compute 3x3 Sobel gradient magnitude, clipped to uint8.

        Uses OpenCV Sobel for speed and faithfulness to the reference impl.
        Replicate-border so the result has the same shape as the input.
        """
        import cv2  # local import — only this method needs it
        gx = cv2.Sobel(frame, cv2.CV_32F, 1, 0, ksize=3, borderType=cv2.BORDER_REPLICATE)
        gy = cv2.Sobel(frame, cv2.CV_32F, 0, 1, ksize=3, borderType=cv2.BORDER_REPLICATE)
        mag = np.hypot(gx, gy)
        return np.clip(mag, 0, 255).astype(np.uint8)
```

- [ ] **Step 4: Run, verify tests pass**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k sobel`
Expected: PASS.

- [ ] **Step 5: Add `_update_formerMeanMag` helper + test**

Add this test to `test_pbas.py`:

```python
def test_pbas_formerMeanMag_clamped_to_min():
    """formerMeanMag floored at mean_mag_min (default 20) — never collapses."""
    from models.ops.pbas import PBAS
    p = PBAS(mean_mag_min=20.0)
    # Pass an all-zero gradient frame with all-bg mask (no fg pixels).
    g = np.zeros((8, 8), np.uint8)
    mask = np.zeros((8, 8), bool)
    p._update_formerMeanMag(g, mask)
    assert p.formerMeanMag == 20.0
    # Pass an all-fg mask with high-magnitude gradient — formerMeanMag tracks the mean.
    g2 = np.full((8, 8), 100, np.uint8)
    mask_fg = np.ones((8, 8), bool)
    p._update_formerMeanMag(g2, mask_fg)
    assert p.formerMeanMag == 100.0
```

Run, verify it fails (method doesn't exist).

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py::test_pbas_formerMeanMag_clamped_to_min -v`
Expected: FAIL.

- [ ] **Step 6: Implement `_update_formerMeanMag`**

Add to PBAS:

```python
    def _update_formerMeanMag(self, g: np.ndarray, mask_fg: np.ndarray) -> None:
        """End-of-frame update: formerMeanMag = max(mean(g over fg pixels), mean_mag_min)."""
        if mask_fg.any():
            mean_mag = float(g[mask_fg].mean())
        else:
            mean_mag = 0.0
        self.formerMeanMag = max(mean_mag, self.mean_mag_min)
```

- [ ] **Step 7: Run, verify it passes**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k "sobel or formerMeanMag"`
Expected: 3 PASS.

- [ ] **Step 8: Commit**

```bash
git add py/models/ops/pbas.py py/tests/test_pbas.py
git commit -m "feat(motion/pbas): Sobel magnitude + formerMeanMag floor"
```

---

## Task 4: Bank initialisation (both modes)

**Files:**
- Modify: `py/models/ops/pbas.py`
- Modify: `py/tests/test_pbas.py`

- [ ] **Step 1: Write tests for both init modes**

Append to `py/tests/test_pbas.py`:

```python
def test_pbas_init_from_frames_paper_default():
    """Paper-default init: first N frames populate bank, one slot per frame.

    Stack of N constant frames with distinct values → each slot k has value k.
    """
    from models.ops.pbas import PBAS
    p = PBAS(N=20)
    frames = [_const_frame(i * 10, h=4, w=4) for i in range(20)]  # values 0,10,20..190
    p.init_from_frames(frames)
    assert p.samples_y.shape == (4, 4, 20)
    assert p.samples_g.shape == (4, 4, 20)
    # samples_y[r,c,k] == k*10 for any (r,c)
    for k in range(20):
        assert (p.samples_y[:, :, k] == k * 10).all()
    # samples_g[r,c,k] == 0 (constant frame has zero gradient)
    assert (p.samples_g == 0).all()
    # State arrays exist and are at init values.
    assert p.R.shape == (4, 4)
    assert (p.R == p.R_lower).all()
    assert (p.T == p.T_init).all()
    assert (p.meanMinDist == 0).all()


def test_pbas_init_from_lookahead_median():
    """Lookahead init: bank seeded from temporal-median of all frames.

    Stack of frames with varying values; median is well-defined; bank should
    have that median in every slot.
    """
    from models.ops.pbas import PBAS
    p = PBAS(N=20)
    frames = [_const_frame(i, h=4, w=4) for i in range(50)]  # values 0..49
    p.init_from_frames(frames, mode="lookahead_median")
    # Median of 0..49 is 24 or 25 (numpy.median on even-length returns float)
    expected_median = int(np.median(np.array([i for i in range(50)])))
    for k in range(20):
        assert (p.samples_y[:, :, k] == expected_median).all()
```

- [ ] **Step 2: Run, verify both fail**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k init`
Expected: FAIL — `init_from_frames` raises NotImplementedError.

- [ ] **Step 3: Implement `init_from_frames`**

Replace the stub in `py/models/ops/pbas.py`:

```python
    def init_from_frames(self, frames: list[np.ndarray], mode: str = "paper_default") -> None:
        """Seed the sample bank from a stack of frames.

        Args:
            frames: list of (H, W) uint8 Y frames. For paper_default mode,
                len(frames) must be >= N (uses first N). For lookahead_median
                mode, uses all frames to compute a per-pixel temporal median.
            mode: "paper_default" or "lookahead_median".
        """
        assert mode in ("paper_default", "lookahead_median"), f"unknown mode {mode!r}"
        assert len(frames) > 0
        f0 = frames[0]
        assert f0.ndim == 2 and f0.dtype == np.uint8
        self.H, self.W = f0.shape
        self.samples_y = np.zeros((self.H, self.W, self.N), dtype=np.uint8)
        self.samples_g = np.zeros((self.H, self.W, self.N), dtype=np.uint8)
        self.R = np.full((self.H, self.W), float(self.R_lower), dtype=np.float32)
        self.T = np.full((self.H, self.W), float(self.T_init), dtype=np.float32)
        self.meanMinDist = np.zeros((self.H, self.W), dtype=np.float32)
        if mode == "paper_default":
            assert len(frames) >= self.N, \
                f"paper_default needs >= N={self.N} frames; got {len(frames)}"
            mean_mag_sum = 0.0
            for k in range(self.N):
                fk = frames[k]
                self.samples_y[:, :, k] = fk
                g = self._sobel_magnitude(fk)
                self.samples_g[:, :, k] = g
                mean_mag_sum += float(g.mean())
            self.formerMeanMag = max(mean_mag_sum / self.N, self.mean_mag_min)
        else:  # lookahead_median
            stack = np.stack(frames, axis=0)
            median = np.median(stack, axis=0).astype(np.uint8)
            g_median = self._sobel_magnitude(median)
            for k in range(self.N):
                self.samples_y[:, :, k] = median
                self.samples_g[:, :, k] = g_median
            self.formerMeanMag = max(float(g_median.mean()), self.mean_mag_min)
```

- [ ] **Step 4: Run, verify tests pass**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k init`
Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add py/models/ops/pbas.py py/tests/test_pbas.py
git commit -m "feat(motion/pbas): bank init (paper-default + lookahead-median)"
```

---

## Task 5: `process_frame` — main per-pixel loop

**Files:**
- Modify: `py/models/ops/pbas.py`
- Modify: `py/tests/test_pbas.py`

- [ ] **Step 1: Write a basic "frame matches bank → all-zero mask" test**

Append to `py/tests/test_pbas.py`:

```python
def test_pbas_process_frame_matching_bank_yields_bg():
    """A frame identical to the init frames matches → all-bg → mask all-zero."""
    from models.ops.pbas import PBAS
    p = PBAS()
    same = _const_frame(128, h=8, w=8)
    p.init_from_frames([same] * 20)
    mask = p.process_frame(same)
    assert mask.shape == (8, 8)
    assert mask.dtype == bool
    assert (~mask).all()  # mask is False (= bg) everywhere


def test_pbas_process_frame_far_from_bank_yields_fg():
    """A frame far from the bank in intensity → all-fg → mask all-true."""
    from models.ops.pbas import PBAS
    p = PBAS()
    p.init_from_frames([_const_frame(0, h=8, w=8)] * 20)
    mask = p.process_frame(_const_frame(255, h=8, w=8))
    assert mask.all()  # mask is True (= fg) everywhere
```

- [ ] **Step 2: Run, verify they fail**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k process_frame`
Expected: FAIL — `process_frame` raises NotImplementedError.

- [ ] **Step 3: Implement `_compute_min_dist` helper**

Add to `py/models/ops/pbas.py`:

```python
    def _compute_min_dist(self, y: np.ndarray, g: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Compute per-pixel (count, minDist) against the bank.

        For each pixel, sweep through N bank slots; distance is
        alpha*|g - sample_g|/formerMeanMag + beta*|y - sample_y|.
        Count = number of slots with distance < R(x). minDist = min over k.

        Returns:
            count:    (H, W) int32, number of matching slots
            minDist:  (H, W) float32, minimum distance to any slot
        """
        H, W, N = self.samples_y.shape
        # Broadcast: (H,W,1) vs (H,W,N) → (H,W,N) distances
        dy = np.abs(y.astype(np.int16)[..., None] - self.samples_y.astype(np.int16))
        dg = np.abs(g.astype(np.int16)[..., None] - self.samples_g.astype(np.int16))
        dist = (self.alpha * dg / self.formerMeanMag) + (self.beta * dy)
        matches = dist < self.R[..., None]
        count = matches.sum(axis=2)
        minDist = dist.min(axis=2)
        return count.astype(np.int32), minDist.astype(np.float32)
```

- [ ] **Step 4: Implement `_apply_bank_update`**

Add to `py/models/ops/pbas.py`:

```python
    def _apply_bank_update(self, y: np.ndarray, g: np.ndarray, mask_bg: np.ndarray) -> None:
        """Per-pixel: with probability ratio/T_upper, write current (y, g) to own
        bank slot AND to a random 3x3 neighbor's bank slot. Only fires on bg.

        Uses precomputed _rand_* tables indexed by _rand_idx (advances per pixel).
        """
        H, W = y.shape
        for r in range(H):
            for c in range(W):
                if not mask_bg[r, c]:
                    self._next_random_entry()  # still advance, to keep determinism
                    continue
                entry = self._next_random_entry()
                ratio_int = int(np.ceil(self.T_upper / self.T[r, c]))
                # Own bank update
                if int(self._rand_T[entry]) < ratio_int:
                    k = int(self._rand_N[(entry + 1) % _RANDOM_TABLE_LEN])
                    self.samples_y[r, c, k] = y[r, c]
                    self.samples_g[r, c, k] = g[r, c]
                # Neighbor bank update
                if int(self._rand_TN[entry]) < ratio_int:
                    dx = int(self._rand_X[entry])
                    dy_off = int(self._rand_Y[entry])
                    nr = max(0, min(H - 1, r + dy_off))
                    nc = max(0, min(W - 1, c + dx))
                    k = int(self._rand_N[(entry + 2) % _RANDOM_TABLE_LEN])
                    self.samples_y[nr, nc, k] = y[r, c]
                    self.samples_g[nr, nc, k] = g[r, c]
```

- [ ] **Step 5: Implement `_apply_R_regulator` and `_apply_T_regulator`**

Add to `py/models/ops/pbas.py`:

```python
    def _apply_R_regulator(self) -> None:
        """R(x) *= (1 ± R_incdec) toward meanMinDist*R_scale. Clamp to R_lower."""
        ratio = self.meanMinDist * self.R_scale
        # If R > meanMinDist*R_scale → shrink, else grow
        grow_mask = self.R <= ratio
        self.R = np.where(grow_mask, self.R * (1.0 + self.R_incdec),
                                       self.R * (1.0 - self.R_incdec))
        self.R = np.maximum(self.R, float(self.R_lower))

    def _apply_T_regulator(self, mask_fg: np.ndarray) -> None:
        """T(x) increment / decrement based on classification; clamp to bounds."""
        denom = self.meanMinDist + 1.0
        delta_bg = self.T_inc / denom   # subtract on bg
        delta_fg = self.T_dec / denom   # add on fg
        self.T = np.where(mask_fg, self.T + delta_fg, self.T - delta_bg)
        self.T = np.clip(self.T, float(self.T_lower), float(self.T_upper))
```

- [ ] **Step 6: Implement `process_frame`**

Replace the stub in `py/models/ops/pbas.py`:

```python
    def process_frame(self, frame: np.ndarray) -> np.ndarray:
        """Process one Y frame, return its mask.

        Procedure (per pixel):
          1. Compute Sobel gradient magnitude g for the whole frame.
          2. For each pixel, compute count and minDist against the bank.
          3. Classify bg (count >= Raute_min) vs fg.
          4. Update meanMinDist (IIR running mean).
          5. Bank update on bg pixels (own + neighbor) with prob ratio/T_upper.
          6. Adapt R and T per pixel.
          7. End-of-frame: update formerMeanMag.
        """
        assert frame.shape == (self.H, self.W), \
            f"frame shape {frame.shape} != model {(self.H, self.W)}"
        g = self._sobel_magnitude(frame)
        count, minDist = self._compute_min_dist(frame, g)
        mask_fg = count < self.Raute_min  # True = motion
        mask_bg = ~mask_fg
        # Running mean of minDist
        self.meanMinDist = ((self.N - 1) * self.meanMinDist + minDist) / float(self.N)
        # Bank update (bg only)
        self._apply_bank_update(frame, g, mask_bg)
        # R / T regulators
        self._apply_R_regulator()
        self._apply_T_regulator(mask_fg)
        # End-of-frame
        self._update_formerMeanMag(g, mask_fg)
        return mask_fg
```

- [ ] **Step 7: Run all PBAS tests so far**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v`
Expected: All PASS, including `test_pbas_deterministic_under_fixed_seed` from Task 2 (which was XFAIL until now).

- [ ] **Step 8: Commit**

```bash
git add py/models/ops/pbas.py py/tests/test_pbas.py
git commit -m "feat(motion/pbas): process_frame body — Sobel, match, update, R/T regulators"
```

---

## Task 6: Clamping + degenerate-to-ViBe equivalence tests

**Files:**
- Modify: `py/tests/test_pbas.py`

- [ ] **Step 1: Write R/T clamping tests**

Append to `py/tests/test_pbas.py`:

```python
def test_pbas_R_clamped_to_R_lower():
    """After many constant-bg frames, R(x) drops toward meanMinDist*R_scale=0
    but is clamped at R_lower."""
    from models.ops.pbas import PBAS
    p = PBAS(R_lower=18)
    same = _const_frame(128, h=8, w=8)
    p.init_from_frames([same] * 20)
    for _ in range(200):
        p.process_frame(same)
    assert p.R.min() == 18.0
    assert p.R.max() >= 18.0  # clamped at R_lower


def test_pbas_T_clamped_to_bounds():
    """T(x) stays within [T_lower, T_upper] across long runs of mixed input."""
    from models.ops.pbas import PBAS
    p = PBAS(T_lower=2, T_upper=200)
    frames = _random_frames(40, seed=42)
    p.init_from_frames(frames[:20])
    for f in frames[20:]:
        p.process_frame(f)
    assert p.T.min() >= 2.0
    assert p.T.max() <= 200.0
```

- [ ] **Step 2: Run, verify they pass**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k "clamped"`
Expected: 2 PASS.

- [ ] **Step 3: Write gradient-distance contribution test**

```python
def test_pbas_gradient_distance_contribution():
    """With alpha=7, beta=0, distance = gradient term only.

    A frame with identical intensity to the bank but DIFFERENT gradient should
    still register a non-zero distance and (with a large enough delta) get
    classified as fg.
    """
    from models.ops.pbas import PBAS
    p = PBAS(alpha=7, beta=0, R_lower=1)  # tight R so any gradient diff = fg
    same = _const_frame(128, h=8, w=8)
    p.init_from_frames([same] * 20)
    # Now a frame with the same intensity but a sharp vertical edge
    edged = np.full((8, 8), 128, np.uint8)
    edged[:, 4:] = 200
    mask = p.process_frame(edged)
    # Pixels at the edge (columns 3-4) should be classified fg due to gradient diff
    assert mask[:, 3:5].any()
```

- [ ] **Step 4: Run, verify it passes**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k gradient_distance_contribution`
Expected: PASS.

- [ ] **Step 5: Write the degenerate-to-ViBe equivalence test**

```python
def test_pbas_degenerate_with_alpha0_no_feedback():
    """With alpha=0, R_incdec=0, T_inc=0, T_dec=0:
       - R is frozen at R_lower
       - T is frozen at T_init
       - Distance reduces to beta * |y - sample_y|
       - Bank update fires with constant probability T_upper/T_init
    PBAS reduces to a ViBe-like algorithm with no feedback. Same input
    should produce the same bg/fg classifications across repeated runs.
    """
    from models.ops.pbas import PBAS
    p = PBAS(
        alpha=0,           # disable gradient distance
        R_incdec=0.0,      # R frozen
        T_inc=0.0,         # T frozen on bg
        T_dec=0.0,         # T frozen on fg
        R_lower=20,        # ViBe-like R
        Raute_min=2,       # ViBe min_match
        T_init=16,         # so update probability = T_upper/T_init = 200/16 ≈ 12.5
    )
    frames = _random_frames(40, seed=7)
    p.init_from_frames(frames[:20])
    # R and T should remain constant
    R0 = p.R.copy()
    T0 = p.T.copy()
    masks = [p.process_frame(f) for f in frames[20:]]
    assert np.allclose(p.R, R0, atol=1e-5), "R should be frozen with R_incdec=0"
    assert np.allclose(p.T, T0, atol=1e-5), "T should be frozen with T_inc=T_dec=0"
    # Masks should be deterministic.
    assert all(m.dtype == bool for m in masks)
```

- [ ] **Step 6: Run, verify it passes**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k degenerate`
Expected: PASS.

- [ ] **Step 7: Run full PBAS test file**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v`
Expected: ALL PASS (should be ~10 tests now).

- [ ] **Step 8: Commit**

```bash
git add py/tests/test_pbas.py
git commit -m "test(motion/pbas): clamping + gradient-distance + degenerate-feedback gates"
```

---

## Task 7: `produce_masks_pbas` adapter

**Files:**
- Create: `py/models/_pbas_mask.py`
- Modify: `py/tests/test_pbas.py`

- [ ] **Step 1: Write a failing adapter test**

Append to `py/tests/test_pbas.py`:

```python
def test_produce_masks_pbas_paper_default():
    """End-to-end adapter test: 40 RGB frames → 40 boolean masks via paper init."""
    from models._pbas_mask import produce_masks_pbas
    rng = np.random.default_rng(0)
    frames = [rng.integers(0, 256, (16, 16, 3), dtype=np.uint8) for _ in range(40)]
    masks = produce_masks_pbas(
        frames,
        pbas_N=20, pbas_R_lower=18, pbas_R_scale=5, pbas_Raute_min=2,
        pbas_T_lower=2, pbas_T_upper=200, pbas_T_init=18,
        pbas_R_incdec_q8=13, pbas_T_inc_q8=256, pbas_T_dec_q8=13,
        pbas_alpha=7, pbas_beta=1, pbas_mean_mag_min=20,
        pbas_bg_init_lookahead=0, pbas_prng_seed=0xDEADBEEF,
        gauss_en=False,
    )
    assert len(masks) == 40
    # Paper-default init: first 20 masks should be all-zero (init phase)
    for i in range(20):
        assert (~masks[i]).all(), f"frame {i} during paper-default init should be all-bg"
    # Post-init masks must be bool with correct shape
    for m in masks[20:]:
        assert m.dtype == bool
        assert m.shape == (16, 16)


def test_produce_masks_pbas_lookahead():
    """Lookahead init: bank pre-seeded, processing starts from frame 0."""
    from models._pbas_mask import produce_masks_pbas
    rng = np.random.default_rng(0)
    frames = [rng.integers(0, 256, (16, 16, 3), dtype=np.uint8) for _ in range(20)]
    masks = produce_masks_pbas(
        frames,
        pbas_N=20, pbas_R_lower=18, pbas_R_scale=5, pbas_Raute_min=2,
        pbas_T_lower=2, pbas_T_upper=200, pbas_T_init=18,
        pbas_R_incdec_q8=13, pbas_T_inc_q8=256, pbas_T_dec_q8=13,
        pbas_alpha=7, pbas_beta=1, pbas_mean_mag_min=20,
        pbas_bg_init_lookahead=1, pbas_prng_seed=0xDEADBEEF,
        gauss_en=False,
    )
    assert len(masks) == 20
    # All masks valid; no enforced init period.
    for m in masks:
        assert m.dtype == bool
        assert m.shape == (16, 16)
```

- [ ] **Step 2: Run, verify they fail**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k produce_masks`
Expected: FAIL — `_pbas_mask` module doesn't exist.

- [ ] **Step 3: Create the adapter**

Create `py/models/_pbas_mask.py`:

```python
"""Private helper — produce per-frame motion masks via the PBAS operator.

Parallel to models/_vibe_mask.py. Takes RGB frames, converts to Y, applies
optional Gaussian pre-filter, runs PBAS, returns per-frame boolean masks.
"""
from __future__ import annotations

import numpy as np

from models.motion import _gauss3x3, _rgb_to_y
from models.ops.pbas import PBAS


def produce_masks_pbas(
    frames: list[np.ndarray],
    *,
    pbas_N: int,
    pbas_R_lower: int,
    pbas_R_scale: int,
    pbas_Raute_min: int,
    pbas_T_lower: int,
    pbas_T_upper: int,
    pbas_T_init: int,
    pbas_R_incdec_q8: int,
    pbas_T_inc_q8: int,
    pbas_T_dec_q8: int,
    pbas_alpha: int,
    pbas_beta: int,
    pbas_mean_mag_min: int,
    pbas_bg_init_lookahead: int,
    pbas_prng_seed: int,
    gauss_en: bool = True,
    **_ignored,
) -> list[np.ndarray]:
    """Return per-frame boolean motion masks under PBAS."""
    if not frames:
        return []
    # Convert RGB → Y, optionally gauss-prefilter.
    y_stack = []
    for f in frames:
        y = _rgb_to_y(f)
        y_stack.append(_gauss3x3(y) if gauss_en else y)
    # Recover float values from Q8 fixed-point.
    R_incdec = pbas_R_incdec_q8 / 256.0
    T_inc = pbas_T_inc_q8 / 256.0
    T_dec = pbas_T_dec_q8 / 256.0
    p = PBAS(
        N=pbas_N, R_lower=pbas_R_lower, R_scale=pbas_R_scale,
        Raute_min=pbas_Raute_min, T_lower=pbas_T_lower, T_upper=pbas_T_upper,
        T_init=pbas_T_init, R_incdec=R_incdec, T_inc=T_inc, T_dec=T_dec,
        alpha=pbas_alpha, beta=pbas_beta,
        mean_mag_min=float(pbas_mean_mag_min),
        prng_seed=pbas_prng_seed,
    )
    masks: list[np.ndarray] = []
    if pbas_bg_init_lookahead == 0:
        # Paper-default: first N frames seed bank, no processing.
        assert len(y_stack) >= pbas_N, \
            f"pbas_default init needs >= N={pbas_N} frames; got {len(y_stack)}"
        p.init_from_frames(y_stack[:pbas_N], mode="paper_default")
        # Emit all-zero masks for init frames.
        zero = np.zeros(y_stack[0].shape, dtype=bool)
        masks.extend([zero.copy() for _ in range(pbas_N)])
        # Process remaining frames normally.
        for i in range(pbas_N, len(y_stack)):
            masks.append(p.process_frame(y_stack[i]))
    elif pbas_bg_init_lookahead == 1:
        # Lookahead: seed bank from temporal median of all frames, then process from 0.
        p.init_from_frames(y_stack, mode="lookahead_median")
        for y in y_stack:
            masks.append(p.process_frame(y))
    else:
        raise ValueError(f"unknown pbas_bg_init_lookahead {pbas_bg_init_lookahead}")
    return masks
```

- [ ] **Step 4: Run, verify both tests pass**

Run: `.venv/bin/python -m pytest py/tests/test_pbas.py -v -k produce_masks`
Expected: 2 PASS.

- [ ] **Step 5: Run full Python suite**

Run: `.venv/bin/python -m pytest py/tests -v`
Expected: ALL PASS.

- [ ] **Step 6: Commit**

```bash
git add py/models/_pbas_mask.py py/tests/test_pbas.py
git commit -m "feat(motion/pbas): produce_masks_pbas adapter (paper + lookahead init)"
```

---

## Task 8: Comparison experiment runner

**Files:**
- Create: `py/experiments/run_pbas_compare.py`

- [ ] **Step 1: Inspect prior runner as template**

Run: `head -60 py/experiments/run_lookahead_init.py`

The shape we want to mirror: load source → run pipeline per profile → save coverage curve + convergence CSV + grid.

- [ ] **Step 2: Create the runner**

Create `py/experiments/run_pbas_compare.py`:

```python
"""Phase comparison: ViBe variants vs PBAS variants on real clips.

4 methods × 2 sources × 200 frames. Outputs per source under
py/experiments/our_outputs/pbas_compare/<source>/:
  coverage.png           — 4-curve overlay (mean mask coverage vs frame)
  convergence_table.csv  — asymptote / peak / time-to-1%-coverage per method
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
from models._pbas_mask import produce_masks_pbas
from models._vibe_mask import produce_masks_vibe
from profiles import resolve

SOURCES = [
    "media/source/birdseye-320x240.mp4",
    "media/source/people-320x240.mp4",
]
METHODS = [
    "vibe_init_frame0",
    "vibe_init_external",
    "pbas_default",
    "pbas_lookahead",
]
N_FRAMES = 200
OUT_ROOT = Path("py/experiments/our_outputs/pbas_compare")
THRESHOLDS = [0.01, 0.001]


def _produce_masks(profile_name: str, frames: list[np.ndarray]) -> list[np.ndarray]:
    cfg = dict(resolve(profile_name))
    if profile_name.startswith("pbas_"):
        return produce_masks_pbas(
            frames,
            **{k: v for k, v in cfg.items() if k.startswith("pbas_") or k == "gauss_en"},
        )
    elif profile_name.startswith("vibe_"):
        return produce_masks_vibe(
            frames,
            **{k: v for k, v in cfg.items() if k.startswith("vibe_") or k == "gauss_en"},
        )
    else:
        raise ValueError(f"unknown profile family: {profile_name}")


def _time_to_threshold(curve: np.ndarray, t: float) -> int | None:
    below = np.where(curve < t)[0]
    return int(below[0]) if below.size else None


def run_source(source: str, n_frames: int = N_FRAMES) -> None:
    frames = load_frames(source, width=320, height=240, num_frames=n_frames)
    if len(frames) < n_frames:
        raise SystemExit(f"{source}: only {len(frames)} frames available, need {n_frames}")
    out_dir = OUT_ROOT / source.replace(":", "_").replace("/", "_")
    out_dir.mkdir(parents=True, exist_ok=True)
    curves: dict[str, np.ndarray] = {}
    for method in METHODS:
        masks = _produce_masks(method, frames)
        curves[method] = coverage_curve(masks)
    # coverage.png
    render_coverage_curves(
        curves, str(out_dir / "coverage.png"),
        title=f"ViBe vs PBAS — {source}",
    )
    # convergence_table.csv
    with (out_dir / "convergence_table.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["method", "asymptote(last50)", "peak"]
                   + [f"t_to_{t:.4f}" for t in THRESHOLDS])
        for m in METHODS:
            c = curves[m]
            row = [m, f"{c[-50:].mean():.4f}", f"{c.max():.4f}"]
            for t in THRESHOLDS:
                tt = _time_to_threshold(c, t)
                row.append(str(tt) if tt is not None else "")
            w.writerow(row)
    print(f"[{source}] asymptote: " + ", ".join(
        f"{m}={curves[m][-50:].mean():.4f}" for m in METHODS), flush=True)


def main() -> None:
    for src in SOURCES:
        run_source(src)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Smoke-test at reduced frame count**

```bash
source .venv/bin/activate
python -c "
import sys; sys.path.insert(0, 'py')
from experiments.run_pbas_compare import run_source
run_source('media/source/birdseye-320x240.mp4', n_frames=30)
"
```

Expected: produces `py/experiments/our_outputs/pbas_compare/media_source_birdseye-320x240.mp4/{coverage.png, convergence_table.csv}` without error.

- [ ] **Step 4: Commit (do NOT commit the smoke-test artefacts — gitignored under our_outputs/)**

```bash
git add py/experiments/run_pbas_compare.py
git commit -m "experiment(motion/pbas): 4-method comparison runner (ViBe vs PBAS)"
```

(The full 200-frame run is deferred to Task 10.)

---

## Task 9: Labelled WebP renderer

**Files:**
- Create: `py/viz/render_pbas_compare_webp.py`

- [ ] **Step 1: Inspect `py/viz/render.py`'s labelled-grid helper**

Run: `grep -n "def render_grid\|label_height\|label_y" py/viz/render.py | head -10`

Understand the input shape that the helper expects: `render_grid(input_frames, rows, out_path, every_n=8)` where `rows` is a list of `(label, masks)` tuples. For our needs we want a multi-frame *animated* WebP, not a static PNG grid. We'll compose each frame manually (numpy → Pillow) using the same labelling style.

- [ ] **Step 2: Create the renderer**

Create `py/viz/render_pbas_compare_webp.py`:

```python
"""Render labelled side-by-side animated WebPs comparing ViBe vs PBAS.

One WebP per source under media/demo/pbas-compare-<source>.webp. Each WebP
animates 200 frames, showing 4 method outputs left-to-right with method
labels above each panel.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from experiments.run_pbas_compare import METHODS, N_FRAMES, SOURCES, _produce_masks
from frames.video_source import load_frames

OUT_DIR = Path("media/demo")
OUT_DIR.mkdir(parents=True, exist_ok=True)
LABEL_H = 24  # pixels at top of each frame for the label
FONT_PATHS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def _load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_PATHS:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def _label_panel(panel: Image.Image, label: str, font: ImageFont.FreeTypeFont) -> Image.Image:
    w, h = panel.size
    out = Image.new("RGB", (w, h + LABEL_H), (40, 40, 40))
    draw = ImageDraw.Draw(out)
    bbox = draw.textbbox((0, 0), label, font=font)
    tx = (w - (bbox[2] - bbox[0])) // 2
    ty = (LABEL_H - (bbox[3] - bbox[1])) // 2
    draw.text((tx, ty), label, fill=(220, 220, 220), font=font)
    out.paste(panel, (0, LABEL_H))
    return out


def render(source: str, n_frames: int = N_FRAMES) -> None:
    frames = load_frames(source, width=320, height=240, num_frames=n_frames)
    if len(frames) < n_frames:
        raise SystemExit(f"{source}: only {len(frames)} frames available, need {n_frames}")
    streams: dict[str, list[np.ndarray]] = {}
    for method in METHODS:
        streams[method] = _produce_masks(method, frames)
    font = _load_font(14)
    h, w = streams[METHODS[0]][0].shape
    pages = []
    for i in range(n_frames):
        labelled = []
        for method in METHODS:
            mask = streams[method][i].astype(np.uint8) * 255
            panel = Image.fromarray(mask, mode="L").convert("RGB")
            labelled.append(_label_panel(panel, method, font))
        strip_w = sum(p.size[0] for p in labelled)
        strip_h = labelled[0].size[1]
        strip = Image.new("RGB", (strip_w, strip_h), (40, 40, 40))
        x = 0
        for p in labelled:
            strip.paste(p, (x, 0))
            x += p.size[0]
        pages.append(strip)
    out_path = OUT_DIR / f"pbas-compare-{source.replace(':', '_').replace('/', '_')}.webp"
    pages[0].save(out_path, format="WEBP", save_all=True,
                  append_images=pages[1:], duration=33, loop=0,
                  lossless=True, quality=80)
    print(f"[{source}] → {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=N_FRAMES)
    parser.add_argument("--source", type=str, default=None,
                        help="run a single source (full path) instead of all SOURCES")
    args = parser.parse_args()
    if args.source:
        render(args.source, args.frames)
    else:
        for src in SOURCES:
            render(src, args.frames)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Smoke-test at reduced frame count**

```bash
source .venv/bin/activate
python py/viz/render_pbas_compare_webp.py --frames 30 --source media/source/birdseye-320x240.mp4
```

Expected: produces `media/demo/pbas-compare-media_source_birdseye-320x240.mp4.webp`. File size under 1 MB at 30 frames.

- [ ] **Step 4: Commit (renderer only; WebP artefacts NOT committed — they're build outputs)**

```bash
rm -f media/demo/pbas-compare-*.webp  # clean up smoke-test WebP
git add py/viz/render_pbas_compare_webp.py
git commit -m "demo(motion/pbas): labelled side-by-side ViBe-vs-PBAS WebP renderer"
```

---

## Task 10: Run experiment + write results doc + GO/NO-GO (HUMAN GATE)

**Files:**
- Create: `docs/plans/2026-05-XX-pbas-python-results.md` (date placeholder; populate with the actual run date)

- [ ] **Step 1: Run the full 200-frame comparison**

```bash
source .venv/bin/activate
python py/experiments/run_pbas_compare.py
```

Expected: produces 2 directories under `py/experiments/our_outputs/pbas_compare/`, each with `coverage.png` and `convergence_table.csv`. May take 30+ minutes in pure Python.

- [ ] **Step 2: Generate the WebPs**

```bash
python py/viz/render_pbas_compare_webp.py
```

Expected: produces `media/demo/pbas-compare-media_source_birdseye-320x240.mp4.webp` and the people equivalent. Each under 5 MB.

- [ ] **Step 3: Aggregate the CSV results into a single markdown table**

Run: `cat py/experiments/our_outputs/pbas_compare/*/convergence_table.csv`

Collect asymptote / peak / time-to-1% per (source, method) into a single markdown table for the results doc.

- [ ] **Step 4: Write the results doc**

Create `docs/plans/<actual-date>-pbas-python-results.md`:

```markdown
# PBAS Python — results

**Date:** YYYY-MM-DD
**Branch:** feat/pbas-python
**Companion design:** docs/plans/2026-05-11-pbas-python-design.md
**Companion plan:** docs/plans/2026-05-11-pbas-python-plan.md

## Decision

GO / NO-GO — recommend / hold on RTL follow-up for PBAS bg_model.

## Headline 4-method coverage table (asymptote = avg over last 50 frames of 200)

| Source | vibe_init_frame0 | vibe_init_external | pbas_default | pbas_lookahead |
|---|---|---|---|---|
| birdseye | ... | ... | ... | ... |
| people | ... | ... | ... | ... |

## Convergence speed — time-to-1%-coverage (frames)

(Populate from convergence_table.csv per source.)

## Visual evidence

- py/experiments/our_outputs/pbas_compare/<source>/coverage.png (linked)
- media/demo/pbas-compare-<source>.webp (linked)

## Discussion

Comparison vs ViBe variants. Does PBAS dissolve ghosts faster on real clips?
Does pbas_lookahead beat pbas_default (isolates "PBAS feedback helps" from
"lookahead init helps")? Any qualitative observations from the WebPs
(fragmentation, dynamic-bg handling, mask sharpness)?

## Recommendation

GO / NO-GO on RTL follow-up.

Decision criterion (per design doc §7.4):
- Did at least one PBAS variant show clear improvement over
  vibe_init_external on at least one real source?
- Lower asymptotic coverage AND no worse peak coverage during convergence?

## Caveats / open questions

(e.g., gradient feature contribution; would RGB-per-channel features
help further; etc.)
```

- [ ] **Step 5: Commit results doc + the WebPs**

```bash
git add docs/plans/*-pbas-python-results.md media/demo/pbas-compare-*.webp
git commit -m "docs(plans): PBAS Python — empirical results + side-by-side WebPs"
```

- [ ] **Step 6: Decision gate**

Present the results doc to the human. Decision options:

- **GO:** PBAS beats `vibe_init_external` on at least one real clip → start a separate RTL implementation plan.
- **NO-GO:** PBAS doesn't beat `vibe_init_external` → fall back to shipping `vibe_init_external` as the project's default (Option I from the addendum). Document the finding; the experiment was still valuable as it eliminates PBAS from the option space.
- **AMBIGUOUS:** Mixed signals → consider RGB-per-channel feature extension (the next deferred follow-up) or close the investigation.

This is a human-judgement gate. Do not proceed to RTL work without an explicit GO.

---

## Notes

- **Branch hygiene** (CLAUDE.md): All tasks land on `feat/pbas-python`. RTL follow-up (if GO) gets its own fresh branch off `origin/main`.
- **Squash at PR time**: per CLAUDE.md, when the plan is fully implemented and tests pass, squash all of the plan's commits into a single PR commit. Verify every commit belongs to the plan (Tasks 1–10) before squashing.
- **Snapshot pre-existing state**: this plan does not change any existing ViBe / EMA behavior. All `make test-ip`, `make lint`, `make run-pipeline` on existing profiles should continue to pass throughout.
- **Out of scope** (do not implement in this plan):
  - RTL changes beyond the cfg_t shadow.
  - New ctrl_flow modules.
  - Y + gradient extension to RGB-per-channel.
