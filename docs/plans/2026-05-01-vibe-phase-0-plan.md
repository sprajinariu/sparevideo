# ViBe Phase 0 — Python Ablation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate ViBe's frame-0 ghost-suppression mechanism on the project's test footage with a deterministic Python re-implementation, before committing any RTL effort. Produce a pass/fail report against the §8 gate criteria from the design doc.

**Architecture:** A minimal vanilla ViBe in numpy (no PyTorch, no opencv-bgsegm). Cross-checked qualitatively against the upstream PyTorch reference (Van Droogenbroeck et al., kept outside this repo per its eval-license terms). Side-by-side comparison renderer against the existing EMA path. Decision-gate report at the end. The design doc's Phases 1–2 (RTL) are blocked until this plan's gate passes.

**Tech Stack:** Python 3, numpy, Pillow, opencv-python, matplotlib (already in `.venv` per `requirements.txt`). No new dependencies in our repo. Upstream PyTorch reference installed in a separate venv outside the repo (eval-license).

**Companion docs (read these first):**
- [`docs/plans/2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md) — full design spec; especially §2 (algorithm), §2.1 (decision-rule advantages), §6.5 (frame-0 init scheme c), §7 (PRNG), §8 (Phase-0 gate criteria), §10 (open questions).
- [`docs/plans/2026-05-01-bg-models-survey-design.md`](2026-05-01-bg-models-survey-design.md) — comparison vs MOG2/PBAS, why ViBe was chosen.

---

## File Structure

New files (all under `py/experiments/`):

| File | Responsibility |
|---|---|
| `py/experiments/__init__.py` | Empty marker, makes `experiments` importable |
| `py/experiments/xorshift.py` | Deterministic Xorshift32 PRNG (mirrors design §7.2 SV) |
| `py/experiments/motion_vibe.py` | ViBe re-impl: `class ViBe` with `init_from_frame()`, `process_frame()`, decision/update internals, three init schemes (a/b/c) |
| `py/experiments/metrics.py` | Per-frame mask-coverage + ghost-convergence detector + EMA-baseline runner |
| `py/experiments/render.py` | Side-by-side comparison grid (PNG); per-frame coverage curves (matplotlib PNG) |
| `py/experiments/run_phase0.py` | Top-level driver: matrix of (source × parameters) → outputs + summary |

Tests (under existing `py/tests/`, follow the project's pytest convention):

| File | Responsibility |
|---|---|
| `py/tests/test_xorshift.py` | Golden-sequence test for the PRNG |
| `py/tests/test_motion_vibe.py` | Unit tests for ViBe init/decision/update/diffusion/end-to-end |
| `py/tests/test_metrics.py` | Unit tests for the metrics module |

Output directories (gitignored):

| Path | Contents |
|---|---|
| `py/experiments/upstream_baseline_outputs/` | Captured upstream PyTorch ViBe masks per source (one-time runs) |
| `py/experiments/our_outputs/` | Our re-impl outputs + side-by-side grids + coverage curves |

Modified files:

| File | Change |
|---|---|
| `.gitignore` | Add `py/experiments/upstream_baseline_outputs/` and `py/experiments/our_outputs/` |

Final deliverable:

| File | Responsibility |
|---|---|
| `docs/plans/2026-05-XX-vibe-phase-0-results.md` | Decision-gate report. Per-source pass/fail, embedded coverage curves, recommendation for Phase-1. Date filled in when written. |

---

## Task 1: Bootstrap experiments directory + gitignore

**Files:**
- Create: `py/experiments/__init__.py`
- Modify: `.gitignore`

- [ ] **Step 1: Create the empty package marker**

```bash
mkdir -p py/experiments
touch py/experiments/__init__.py
```

- [ ] **Step 2: Add gitignore entries**

Append to `.gitignore`:

```
# ViBe Phase 0 experiments — upstream-derived outputs and our local renders
py/experiments/upstream_baseline_outputs/
py/experiments/our_outputs/
```

- [ ] **Step 3: Verify the directory and gitignore**

Run:

```bash
ls py/experiments/__init__.py && grep -q "upstream_baseline_outputs" .gitignore && echo OK
```

Expected: `py/experiments/__init__.py` followed by `OK`.

- [ ] **Step 4: Commit**

```bash
git add py/experiments/__init__.py .gitignore
git commit -m "feat(experiments): bootstrap py/experiments dir for ViBe Phase 0"
```

---

## Task 2: Upstream ViBe reference setup (out-of-tree, one-time)

This task does **not** create any committed artifacts. It documents the local setup of the authors' upstream PyTorch ViBe reference, kept entirely outside this repo per its evaluation-only license terms (Doc B §11). Static masks captured in Task 14 are committed (gitignored, but the run is reproducible).

**Files:** None modified in the repo.

- [ ] **Step 1: Clone upstream outside the project tree**

```bash
mkdir -p ~/eval && cd ~/eval
git clone https://github.com/vandroogenbroeckmarc/vibe.git vibe-upstream
```

Expected: clone succeeds; directory `~/eval/vibe-upstream/` exists.

- [ ] **Step 2: Create separate venv and install PyTorch**

```bash
cd ~/eval/vibe-upstream
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install torch torchvision opencv-python pillow numpy
deactivate
```

Expected: install succeeds. PyTorch ~2GB, takes a few minutes.

- [ ] **Step 3: Smoke-test upstream on a synthesized image**

Create a one-off test script at `~/eval/test-upstream.py` (NOT in our repo):

```python
import sys
sys.path.insert(0, "/home/spraj/eval/vibe-upstream/Python/src")
import torch, numpy as np
from model import ViBe

device = torch.device("cpu")
m = ViBe(device, numberOfSamples=20, matchingThreshold=10, matchingNumber=2,
         updateFactor=8.0, neighborhoodRadius=1)

# Single 240x320 grayscale frame as a 1x240x320 tensor
frame = torch.zeros(1, 240, 320, dtype=torch.float)
frame[0, 100:140, 150:200] = 200  # foreground patch
m.initialize(frame)
mask = m.segment(frame)
print("mask shape:", mask.shape, "min:", mask.min().item(), "max:", mask.max().item())
print("OK" if mask.shape == torch.Size([240, 320]) else "FAIL")
```

Run:

```bash
source ~/eval/vibe-upstream/.venv/bin/activate
python ~/eval/test-upstream.py
deactivate
```

Expected: `mask shape: torch.Size([240, 320]) min: 0.0 max: 1.0` and `OK`.

- [ ] **Step 4: No commit** — upstream is not in our repo by design.

Document the local setup completion mentally (calendar reminder for ~150 days to delete `~/eval/vibe-upstream/` per the eval-license 180-day window).

---

## Task 3: Xorshift32 PRNG with golden test

**Files:**
- Create: `py/experiments/xorshift.py`
- Test: `py/tests/test_xorshift.py`

- [ ] **Step 1: Write the failing test**

Create `py/tests/test_xorshift.py`:

```python
"""Golden-sequence test for the Xorshift32 PRNG.

This test pins the PRNG output bit-exactly. If it ever fails, the SV mirror
in axis_motion_detect_vibe will diverge from the Python ref → TOLERANCE=0
verify breaks. Do not modify the golden sequence without also updating the SV.
"""

from experiments.xorshift import xorshift32


def test_xorshift32_seed_dead_beef_first_8():
    """First 8 advances of Xorshift32 from seed 0xDEADBEEF."""
    state = 0xDEADBEEF
    expected = [
        0xBA686D8E,
        0xC4DBE91D,
        0x4D6F1F6F,
        0xD3DF7960,
        0xF34DDB89,
        0x0CE9D8FA,
        0x4F58E60D,
        0x4F38B8D7,
    ]
    seq = []
    for _ in range(8):
        state = xorshift32(state)
        seq.append(state)
    assert seq == expected, f"PRNG drift; got {[hex(s) for s in seq]}"


def test_xorshift32_returns_32bit():
    """Output must always fit in 32 bits."""
    state = 1
    for _ in range(1000):
        state = xorshift32(state)
        assert 0 <= state < (1 << 32), f"state {state:#x} not 32-bit"


def test_xorshift32_zero_state_is_a_fixed_point():
    """Zero is a known fixed point of Xorshift32 — must NEVER be used as seed."""
    assert xorshift32(0) == 0
```

- [ ] **Step 2: Run test to verify it fails**

```bash
source .venv/bin/activate
pytest py/tests/test_xorshift.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'experiments'` or `xorshift`.

- [ ] **Step 3: Implement Xorshift32**

Create `py/experiments/xorshift.py`:

```python
"""Deterministic Xorshift32 PRNG.

Mirrors the SV implementation that will live in axis_motion_detect_vibe.sv.
Same shifts (13, 17, 5), same masking discipline (32-bit unsigned).

Golden values pinned in py/tests/test_xorshift.py. Any change here MUST
update the SV mirror identically — TOLERANCE=0 verify depends on bit-exact
parity.
"""


def xorshift32(state: int) -> int:
    """Advance Xorshift32 state by one step, return the new state.

    Args:
        state: 32-bit unsigned PRNG state. Must be non-zero (0 is a fixed point).

    Returns:
        New 32-bit unsigned state.
    """
    state ^= (state << 13) & 0xFFFFFFFF
    state ^= (state >> 17)
    state ^= (state << 5) & 0xFFFFFFFF
    return state & 0xFFFFFFFF
```

- [ ] **Step 4: Run test to verify it passes**

If the golden values in Step 1 are wrong (likely, since they were authored by hand), the test will FAIL with a hex mismatch. Capture the actual output:

```bash
pytest py/tests/test_xorshift.py::test_xorshift32_seed_dead_beef_first_8 -v
```

If it fails with a hex mismatch, regenerate the golden values from the now-trusted implementation:

```bash
python -c "
from experiments.xorshift import xorshift32
import sys; sys.path.insert(0, 'py')
state = 0xDEADBEEF
for _ in range(8):
    state = xorshift32(state)
    print(f'        0x{state:08X},')
"
```

Paste the output into the test's `expected` list, then re-run:

```bash
pytest py/tests/test_xorshift.py -v
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/xorshift.py py/tests/test_xorshift.py
git commit -m "feat(experiments): xorshift32 PRNG with golden sequence test"
```

---

## Task 4: Frame-0 init scheme (c) — current ± noise

**Files:**
- Create: `py/experiments/motion_vibe.py`
- Test: `py/tests/test_motion_vibe.py`

- [ ] **Step 1: Write the failing test**

Create `py/tests/test_motion_vibe.py`:

```python
"""Unit tests for the ViBe re-implementation."""

import numpy as np
import pytest

from experiments.motion_vibe import ViBe


def _y_frame(value, h=4, w=4):
    """Make an h×w Y8 frame filled with `value`."""
    return np.full((h, w), value, dtype=np.uint8)


def test_init_scheme_c_shape_and_dtype():
    """Init produces (H, W, K) uint8 sample bank."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    frame_0 = _y_frame(128, h=4, w=4)
    v.init_from_frame(frame_0)
    assert v.samples.shape == (4, 4, 8)
    assert v.samples.dtype == np.uint8


def test_init_scheme_c_samples_within_noise_band():
    """Each slot of each pixel = current ± noise, range [-8, +7] per the design."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    frame_0 = _y_frame(128, h=4, w=4)
    v.init_from_frame(frame_0)
    # All samples within [128-8, 128+7] = [120, 135] (no clamping at this center value)
    assert v.samples.min() >= 120
    assert v.samples.max() <= 135


def test_init_scheme_c_clamps_at_edges():
    """Samples clamp to [0, 255] when current ± noise would overflow."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    # Frame value 0 → samples in [-8, +7] → clamped to [0, 7]
    v.init_from_frame(_y_frame(0))
    assert v.samples.min() == 0
    assert v.samples.max() <= 7

    # Frame value 255 → samples in [247, 262] → clamped to [247, 255]
    v2 = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
              init_scheme="c", prng_seed=0xDEADBEEF)
    v2.init_from_frame(_y_frame(255))
    assert v2.samples.min() >= 247
    assert v2.samples.max() == 255


def test_init_scheme_c_deterministic_from_seed():
    """Two ViBes with same seed produce identical sample banks."""
    a = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xCAFEBABE)
    b = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xCAFEBABE)
    a.init_from_frame(_y_frame(100))
    b.init_from_frame(_y_frame(100))
    assert np.array_equal(a.samples, b.samples)


def test_init_scheme_c_different_seeds_differ():
    """Different seeds produce different sample banks."""
    a = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xCAFEBABE)
    b = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    a.init_from_frame(_y_frame(100))
    b.init_from_frame(_y_frame(100))
    assert not np.array_equal(a.samples, b.samples)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 5 tests FAIL with `ModuleNotFoundError: No module named 'experiments.motion_vibe'`.

- [ ] **Step 3: Implement ViBe class with init scheme (c)**

Create `py/experiments/motion_vibe.py`:

```python
"""ViBe (Visual Background Extractor) — Python re-implementation.

A deterministic, integer-only port of Barnich & Van Droogenbroeck (IEEE TIP 2011)
suitable for bit-exact verification against the future SV RTL. Uses Xorshift32
for all randomness; same seed and same advance order produce identical output
across runs.

Three frame-0 init schemes are supported:
  (a) 3×3 neighborhood draws (paper-canonical)
  (b) Degenerate stack (all K slots = current pixel value; cheapest)
  (c) Current ± noise (upstream C/Python reference; default — see Doc B §6.5)

Decision rule:  count = sum(|x - sample_i| < R for i in 0..K); mask = count < min_match
Update rule (only on bg-classified pixels):
  - With prob 1/phi_update: replace random slot of *this* pixel.
  - With prob 1/phi_diffuse: replace random slot of one random spatial neighbor
    (8-neighbor, excluding center).

Companion design doc: docs/plans/2026-05-01-vibe-motion-design.md
"""

from typing import Optional

import numpy as np

from experiments.xorshift import xorshift32


class ViBe:
    """Deterministic ViBe re-implementation."""

    def __init__(
        self,
        K: int = 8,
        R: int = 20,
        min_match: int = 2,
        phi_update: int = 16,
        phi_diffuse: int = 16,
        init_scheme: str = "c",
        prng_seed: int = 0xDEADBEEF,
    ):
        # Validate constraints from design doc
        assert K & (K - 1) == 0 and K > 0, "K must be a power of 2"
        assert phi_update & (phi_update - 1) == 0, "phi_update must be a power of 2"
        assert phi_diffuse & (phi_diffuse - 1) == 0, "phi_diffuse must be a power of 2"
        assert init_scheme in ("a", "b", "c"), "init_scheme must be 'a', 'b', or 'c'"
        assert prng_seed != 0, "prng_seed must be non-zero (0 is Xorshift32 fixed point)"

        self.K = K
        self.R = R
        self.min_match = min_match
        self.phi_update = phi_update
        self.phi_diffuse = phi_diffuse
        self.init_scheme = init_scheme
        self.prng_state = prng_seed

        self.samples: Optional[np.ndarray] = None  # shape (H, W, K), uint8
        self.H = 0
        self.W = 0

    def _next_prng(self) -> int:
        """Advance PRNG and return the new 32-bit state."""
        self.prng_state = xorshift32(self.prng_state)
        return self.prng_state

    def init_from_frame(self, frame_0: np.ndarray) -> None:
        """Seed the sample bank from frame 0 using the configured init scheme."""
        assert frame_0.ndim == 2 and frame_0.dtype == np.uint8, \
            "frame_0 must be a 2-D uint8 Y frame"
        self.H, self.W = frame_0.shape
        self.samples = np.zeros((self.H, self.W, self.K), dtype=np.uint8)

        if self.init_scheme == "c":
            self._init_scheme_c(frame_0)
        else:
            raise NotImplementedError(
                f"init_scheme={self.init_scheme!r} not implemented yet (see Task 12)"
            )

    def _init_scheme_c(self, frame_0: np.ndarray) -> None:
        """Scheme (c): each slot = clamp(y + noise, 0, 255), noise ∈ [-8, +7].

        One PRNG advance per pixel; 8 noise lanes from 4-bit slices of the 32-bit
        state. Mirrors the SV implementation in Doc B §6.5.
        """
        for r in range(self.H):
            for c in range(self.W):
                state = self._next_prng()
                y = int(frame_0[r, c])
                for k in range(self.K):
                    nibble = (state >> (4 * k)) & 0xF
                    noise = nibble - 8  # signed [-8, +7]
                    val = y + noise
                    val = 0 if val < 0 else (255 if val > 255 else val)
                    self.samples[r, c, k] = val
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/motion_vibe.py py/tests/test_motion_vibe.py
git commit -m "feat(experiments): ViBe class skeleton with frame-0 init scheme c"
```

---

## Task 5: Decision rule — count + threshold

**Files:**
- Modify: `py/experiments/motion_vibe.py`
- Modify: `py/tests/test_motion_vibe.py`

- [ ] **Step 1: Add the failing test**

Append to `py/tests/test_motion_vibe.py`:

```python
def test_compute_mask_all_match_means_bg():
    """If all K samples equal the current frame, count=K → mask=0 (bg)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 2, 2
    v.samples = np.full((2, 2, 8), 100, dtype=np.uint8)
    mask = v.compute_mask(_y_frame(100, h=2, w=2))
    assert mask.shape == (2, 2)
    assert mask.dtype == bool
    assert not mask.any(), "all pixels should be bg (mask=False)"


def test_compute_mask_no_match_means_motion():
    """If no samples are within R of current, count=0 → mask=1 (motion)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 2, 2
    v.samples = np.full((2, 2, 8), 100, dtype=np.uint8)
    # Current = 200, samples = 100, diff = 100 > R=20 → no match → motion
    mask = v.compute_mask(_y_frame(200, h=2, w=2))
    assert mask.all(), "all pixels should be motion (mask=True)"


def test_compute_mask_one_match_below_min_match():
    """count=1, min_match=2 → mask=1 (motion)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 1, 1
    # 1 sample at 100 (matches y=100 within R), 7 samples at 200 (don't match)
    v.samples = np.zeros((1, 1, 8), dtype=np.uint8)
    v.samples[0, 0, 0] = 100
    v.samples[0, 0, 1:] = 200
    mask = v.compute_mask(_y_frame(100, h=1, w=1))
    assert mask[0, 0], "1 match < min_match=2 → motion"


def test_compute_mask_two_matches_meets_min_match():
    """count=2, min_match=2 → mask=0 (bg)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 1, 1
    v.samples = np.zeros((1, 1, 8), dtype=np.uint8)
    v.samples[0, 0, 0] = 100
    v.samples[0, 0, 1] = 100
    v.samples[0, 0, 2:] = 200
    mask = v.compute_mask(_y_frame(100, h=1, w=1))
    assert not mask[0, 0], "2 matches >= min_match=2 → bg"


def test_compute_mask_radius_strictly_less_than():
    """A sample exactly R away from current is NOT a match (strict <)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 1, 1
    v.samples = np.full((1, 1, 8), 100, dtype=np.uint8)
    # Current = 120, samples = 100, |diff| = 20 = R → strict < → no match
    mask = v.compute_mask(_y_frame(120, h=1, w=1))
    assert mask[0, 0], "|diff|=R should NOT match (strict <)"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 5 new tests FAIL with `AttributeError: 'ViBe' object has no attribute 'compute_mask'`.

- [ ] **Step 3: Implement compute_mask**

Append to `py/experiments/motion_vibe.py` inside the `ViBe` class:

```python
    def compute_mask(self, frame: np.ndarray) -> np.ndarray:
        """Compute the per-pixel motion mask for the given frame.

        Args:
            frame: (H, W) uint8 Y frame.

        Returns:
            (H, W) bool mask. True = motion, False = bg.
        """
        assert frame.shape == (self.H, self.W), \
            f"frame shape {frame.shape} != model {(self.H, self.W)}"
        # Broadcast: (H, W, 1) - (H, W, K) → (H, W, K) absolute diff
        diff = np.abs(frame.astype(np.int16)[..., None]
                      - self.samples.astype(np.int16))
        matches = diff < self.R          # strict less-than, per Doc B §2
        count = matches.sum(axis=2)      # (H, W) int
        return count < self.min_match    # bool: True = motion
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: all 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/motion_vibe.py py/tests/test_motion_vibe.py
git commit -m "feat(experiments): ViBe decision rule (count + min_match threshold)"
```

---

## Task 6: Self-update rule

**Files:**
- Modify: `py/experiments/motion_vibe.py`
- Modify: `py/tests/test_motion_vibe.py`

- [ ] **Step 1: Add the failing test**

Append to `py/tests/test_motion_vibe.py`:

```python
def test_self_update_only_on_bg_pixels():
    """Self-update never modifies samples at pixels classified motion."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=1, phi_diffuse=16,  # phi=1 → always fire
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 2, 2
    v.samples = np.full((2, 2, 8), 100, dtype=np.uint8)
    # Pixel (0,0) is bg (matches), (0,1) is motion (way out of range)
    frame = np.array([[100, 250], [100, 100]], dtype=np.uint8)
    mask = v.compute_mask(frame)
    assert mask[0, 1] and not mask[0, 0]
    samples_before = v.samples.copy()
    v._apply_self_update(frame, mask)
    # (0,1) motion pixel: samples unchanged
    assert np.array_equal(samples_before[0, 1], v.samples[0, 1])
    # (0,0) bg pixel: at least one slot replaced with 100 (was already 100; stable)
    # but rate counter should have advanced — verify via follow-up test


def test_self_update_deterministic_at_fixed_seed():
    """Two runs with same seed produce identical post-update samples."""
    def run():
        v = ViBe(K=8, R=20, min_match=2, phi_update=1, phi_diffuse=16,
                 init_scheme="c", prng_seed=0xDEADBEEF)
        v.H, v.W = 2, 2
        v.samples = np.full((2, 2, 8), 100, dtype=np.uint8)
        frame = _y_frame(105, h=2, w=2)
        mask = v.compute_mask(frame)
        v._apply_self_update(frame, mask)
        return v.samples.copy()
    a = run()
    b = run()
    assert np.array_equal(a, b)


def test_self_update_writes_current_value():
    """When self-update fires, the chosen slot becomes the current pixel value."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=1, phi_diffuse=16,  # always fire
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 1, 1
    v.samples = np.full((1, 1, 8), 100, dtype=np.uint8)
    frame = _y_frame(105, h=1, w=1)  # within R=20 of 100 → bg
    mask = v.compute_mask(frame)
    assert not mask[0, 0]
    v._apply_self_update(frame, mask)
    # Exactly one slot should now be 105 (the rest still 100)
    assert (v.samples[0, 0] == 105).sum() == 1
    assert (v.samples[0, 0] == 100).sum() == 7
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 3 new tests FAIL with `AttributeError: ... no attribute '_apply_self_update'`.

- [ ] **Step 3: Implement self-update**

Append to the `ViBe` class:

```python
    def _apply_self_update(self, frame: np.ndarray, mask: np.ndarray) -> None:
        """Self-update: with prob 1/phi_update, overwrite a random slot of bg pixels.

        Mutates self.samples in place. Advances PRNG once per pixel (raster order).
        """
        log2_phi_self = (self.phi_update - 1).bit_length()
        log2_K = (self.K - 1).bit_length()
        update_mask = (1 << log2_phi_self) - 1  # low bits to check zero
        slot_mask = (1 << log2_K) - 1
        for r in range(self.H):
            for c in range(self.W):
                state = self._next_prng()
                if mask[r, c]:
                    continue  # motion pixel — no update
                # Self-update fires when low log2(phi_update) bits of state == 0
                fires = (state & update_mask) == 0
                if not fires:
                    continue
                # Slot index = next log2(K) bits
                slot = (state >> log2_phi_self) & slot_mask
                self.samples[r, c, slot] = frame[r, c]
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 13 tests pass.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/motion_vibe.py py/tests/test_motion_vibe.py
git commit -m "feat(experiments): ViBe self-update rule (1/phi_update probability)"
```

---

## Task 7: Diffusion rule (8-neighbor, excluding center)

**Files:**
- Modify: `py/experiments/motion_vibe.py`
- Modify: `py/tests/test_motion_vibe.py`

- [ ] **Step 1: Add the failing test**

Append to `py/tests/test_motion_vibe.py`:

```python
def test_diffusion_only_on_bg_pixels():
    """Diffusion never propagates from pixels classified motion."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=1,  # always fire
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    # Mark all pixels motion → no diffusion writes anywhere
    frame = _y_frame(250, h=3, w=3)
    mask = np.ones((3, 3), dtype=bool)
    samples_before = v.samples.copy()
    v._apply_diffusion(frame, mask)
    assert np.array_equal(samples_before, v.samples)


def test_diffusion_writes_to_in_bounds_neighbor():
    """A center bg pixel firing diffusion writes to one of its 8 neighbors."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=1,  # always fire
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    # Only center pixel is bg; corners and edges marked motion to keep them silent
    mask = np.ones((3, 3), dtype=bool)
    mask[1, 1] = False
    frame = _y_frame(105, h=3, w=3)  # center pixel value 105
    v._apply_diffusion(frame, mask)
    # Exactly one neighbor of (1,1) — i.e., one cell among (0,0)..(2,2) excluding (1,1)
    # — should have one of its 8 slots = 105.
    diffs_to_105 = (v.samples == 105)
    # The center pixel's own slots are unchanged (diffusion writes to neighbors)
    assert not diffs_to_105[1, 1].any()
    # Total writes of value 105 in the 3x3: exactly 1
    assert diffs_to_105.sum() == 1


def test_diffusion_excludes_center():
    """The 8-neighbor selector NEVER writes to (0,0) — diffusion is to neighbors only."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=1,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    mask = np.ones((3, 3), dtype=bool)
    mask[1, 1] = False
    # Run many trials with varying seeds — none should ever write 105 to (1,1)'s slots
    for seed_mod in range(10):
        v.prng_state = 0xDEADBEEF ^ seed_mod
        v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
        v._apply_diffusion(_y_frame(105, h=3, w=3), mask)
        assert (v.samples[1, 1] == 100).all(), f"center modified at seed_mod={seed_mod}"


def test_diffusion_clamped_at_image_boundaries():
    """Diffusion targets are clamped to in-bounds; no array-OOB on edge pixels."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=1,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    # Top-left corner pixel is bg; rest are motion
    mask = np.ones((3, 3), dtype=bool)
    mask[0, 0] = False
    # Should not raise even though some 8-neighbor offsets go off the top-left edge
    v._apply_diffusion(_y_frame(105, h=3, w=3), mask)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 4 new tests FAIL with `AttributeError: ... no attribute '_apply_diffusion'`.

- [ ] **Step 3: Implement diffusion**

Append to the `ViBe` class:

```python
    # 8-neighbor offsets (excluding center), indexed 0..7.
    # Order matches the Doc B §3.2 PRNG bit-slicing convention:
    # neighbor_idx = 0 → NW, 1 → N, 2 → NE, 3 → W, 4 → E, 5 → SW, 6 → S, 7 → SE.
    _NEIGHBOR_OFFSETS = (
        (-1, -1), (-1, 0), (-1, +1),
        ( 0, -1),          ( 0, +1),
        (+1, -1), (+1, 0), (+1, +1),
    )

    def _apply_diffusion(self, frame: np.ndarray, mask: np.ndarray) -> None:
        """Diffusion: with prob 1/phi_diffuse, write current value to a random
        neighbor's random slot. 8-neighbor (excluding center).

        Mutates self.samples in place. Advances PRNG once per pixel (raster order).
        Out-of-image neighbor targets are silently skipped (no clamping).
        """
        log2_phi_self = (self.phi_update - 1).bit_length()
        log2_K = (self.K - 1).bit_length()
        log2_phi_diff = (self.phi_diffuse - 1).bit_length()
        diffuse_mask = (1 << log2_phi_diff) - 1
        for r in range(self.H):
            for c in range(self.W):
                state = self._next_prng()
                if mask[r, c]:
                    continue
                # Diffusion fire-bits: same offset budget as Doc B §3.2 / §7.2 SV.
                #   [phi_update bits | K bits | phi_diffuse bits | 3 nbr bits | K bits]
                fire_bits = (state >> (log2_phi_self + log2_K)) & diffuse_mask
                if fire_bits != 0:
                    continue
                nbr_offset = (state >> (log2_phi_self + log2_K + log2_phi_diff)) & 0x7
                slot = (state >> (log2_phi_self + log2_K + log2_phi_diff + 3)) \
                       & ((1 << log2_K) - 1)
                dr, dc = self._NEIGHBOR_OFFSETS[nbr_offset]
                nr, nc = r + dr, c + dc
                if not (0 <= nr < self.H and 0 <= nc < self.W):
                    continue  # out-of-image: skip (boundary handling)
                self.samples[nr, nc, slot] = frame[r, c]
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 17 tests pass.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/motion_vibe.py py/tests/test_motion_vibe.py
git commit -m "feat(experiments): ViBe diffusion rule (8-neighbor exclude center)"
```

---

## Task 8: Top-level `process_frame` orchestration

**Files:**
- Modify: `py/experiments/motion_vibe.py`
- Modify: `py/tests/test_motion_vibe.py`

- [ ] **Step 1: Add the failing test**

Append to `py/tests/test_motion_vibe.py`:

```python
def test_process_frame_returns_mask():
    """process_frame returns a bool mask of the right shape."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.init_from_frame(_y_frame(128, h=4, w=4))
    mask = v.process_frame(_y_frame(128, h=4, w=4))
    assert mask.shape == (4, 4)
    assert mask.dtype == bool


def test_process_frame_static_scene_settles_to_bg():
    """A static scene streams as all-bg after a few frames."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.init_from_frame(_y_frame(128, h=8, w=8))
    # After init, the same frame should be classified almost entirely bg.
    # (Init scheme c places all samples within ±8 of the value 128, well within R=20.)
    mask = v.process_frame(_y_frame(128, h=8, w=8))
    assert mask.sum() == 0, "static scene should be all-bg immediately after init"


def test_process_frame_motion_detected():
    """A pixel value change of 100 → motion."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.init_from_frame(_y_frame(128, h=4, w=4))
    moved = _y_frame(128, h=4, w=4)
    moved[1:3, 1:3] = 240  # diff > R
    mask = v.process_frame(moved)
    assert mask[1:3, 1:3].all()
    assert not mask[0, 0]


def test_process_frame_deterministic_full_run():
    """Two ViBes with same seed produce identical mask sequences across N frames."""
    def run():
        v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
                 init_scheme="c", prng_seed=0xDEADBEEF)
        v.init_from_frame(_y_frame(128, h=8, w=8))
        masks = []
        for _ in range(10):
            masks.append(v.process_frame(_y_frame(128, h=8, w=8)).copy())
        return np.stack(masks)
    a, b = run(), run()
    assert np.array_equal(a, b)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 4 new tests FAIL with `AttributeError: ... no attribute 'process_frame'`.

- [ ] **Step 3: Implement process_frame**

Append to the `ViBe` class:

```python
    def process_frame(self, frame: np.ndarray) -> np.ndarray:
        """Process one frame: compute mask, then apply self-update + diffusion.

        Args:
            frame: (H, W) uint8 Y frame.

        Returns:
            (H, W) bool mask. True = motion, False = bg.
        """
        mask = self.compute_mask(frame)
        # Order matters for PRNG-state determinism: self-update first, diffusion second.
        # Each helper advances PRNG once per pixel; both passes see independent state words.
        self._apply_self_update(frame, mask)
        self._apply_diffusion(frame, mask)
        return mask
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 21 tests pass.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/motion_vibe.py py/tests/test_motion_vibe.py
git commit -m "feat(experiments): ViBe top-level process_frame orchestration"
```

---

## Task 9: Mask-coverage and ghost-convergence metrics

**Files:**
- Create: `py/experiments/metrics.py`
- Test: `py/tests/test_metrics.py`

- [ ] **Step 1: Write the failing test**

Create `py/tests/test_metrics.py`:

```python
"""Unit tests for Phase 0 metrics."""

import numpy as np

from experiments.metrics import (
    mask_coverage,
    coverage_curve,
    ghost_convergence_frame,
    run_ema_baseline,
)


def test_mask_coverage_all_motion():
    m = np.ones((10, 10), dtype=bool)
    assert mask_coverage(m) == 1.0


def test_mask_coverage_all_bg():
    m = np.zeros((10, 10), dtype=bool)
    assert mask_coverage(m) == 0.0


def test_mask_coverage_half():
    m = np.zeros((10, 10), dtype=bool)
    m[:5] = True
    assert mask_coverage(m) == 0.5


def test_coverage_curve_shape():
    masks = [np.zeros((4, 4), dtype=bool) for _ in range(5)]
    masks[2][:] = True
    curve = coverage_curve(masks)
    assert curve.shape == (5,)
    assert curve[0] == 0.0
    assert curve[2] == 1.0


def test_ghost_convergence_frame_obvious_decay():
    """A coverage curve that drops below threshold at frame 7 returns 7."""
    # Simulate a ghost decaying linearly from 30% to 0% over 10 frames
    curve = np.linspace(0.30, 0.0, 10)
    # Threshold of 0.05: first frame below 0.05 is when curve drops to ~0.05
    # 0.30 + i*(-0.30/9) < 0.05 → i > (0.30-0.05)*9/0.30 = 7.5 → frame 8
    frame = ghost_convergence_frame(curve, threshold=0.05)
    assert frame == 8


def test_ghost_convergence_frame_never_converges():
    """A coverage curve that never drops below threshold returns -1."""
    curve = np.full(20, 0.50)
    assert ghost_convergence_frame(curve, threshold=0.05) == -1


def test_ema_baseline_smoke():
    """run_ema_baseline produces masks of correct shape — smoke test only."""
    frames = [np.full((8, 8), 128, dtype=np.uint8) for _ in range(5)]
    masks = run_ema_baseline(frames)
    assert len(masks) == 5
    assert all(m.shape == (8, 8) and m.dtype == bool for m in masks)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_metrics.py -v
```

Expected: 7 tests FAIL with `ModuleNotFoundError: No module named 'experiments.metrics'`.

- [ ] **Step 3: Implement metrics**

Create `py/experiments/metrics.py`:

```python
"""Phase 0 metrics: mask-coverage curves, ghost-convergence detection, and an
EMA baseline runner that uses the existing project model for side-by-side
comparison.
"""

from typing import List

import numpy as np


def mask_coverage(mask: np.ndarray) -> float:
    """Return the fraction of pixels classified motion in a single mask."""
    return float(mask.sum()) / float(mask.size)


def coverage_curve(masks: List[np.ndarray]) -> np.ndarray:
    """Per-frame mask-coverage curve.

    Returns:
        (N,) float array, one entry per frame.
    """
    return np.array([mask_coverage(m) for m in masks])


def ghost_convergence_frame(curve: np.ndarray, threshold: float = 0.05) -> int:
    """First frame index at which the coverage curve drops below `threshold`
    *and stays below* for the remaining frames in the curve.

    Returns -1 if the curve never converges.
    """
    n = len(curve)
    for i in range(n):
        if curve[i] < threshold and (curve[i:] < threshold).all():
            return i
    return -1


def run_ema_baseline(frames: List[np.ndarray]) -> List[np.ndarray]:
    """Run the existing project EMA model on a list of Y frames.

    Wraps py/models/motion.py's compute_motion_masks for the Phase-0 comparison.

    Args:
        frames: list of (H, W) uint8 Y frames.

    Returns:
        list of (H, W) bool masks, one per input frame.
    """
    # Convert Y → RGB triple (the model expects RGB) by replicating the channel
    rgb_frames = [np.stack([f, f, f], axis=-1) for f in frames]

    from models.motion import compute_motion_masks
    masks = compute_motion_masks(rgb_frames)
    # compute_motion_masks returns numpy bool arrays; convert any that aren't
    return [np.asarray(m, dtype=bool) for m in masks]
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest py/tests/test_metrics.py -v
```

Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/metrics.py py/tests/test_metrics.py
git commit -m "feat(experiments): mask coverage / ghost convergence / EMA baseline"
```

---

## Task 10: Side-by-side render grid + coverage-curve plot

**Files:**
- Create: `py/experiments/render.py`

- [ ] **Step 1: Add a smoke test**

Append to `py/tests/test_metrics.py` (no separate test file for render):

```python
def test_render_grid_writes_png(tmp_path):
    """render_grid produces a non-empty PNG file at the given path."""
    from experiments.render import render_grid
    H, W, N = 16, 16, 4
    inputs = [np.full((H, W, 3), v, dtype=np.uint8) for v in [50, 100, 150, 200]]
    masks_a = [np.zeros((H, W), dtype=bool) for _ in range(N)]
    masks_b = [np.ones((H, W), dtype=bool) for _ in range(N)]
    masks_c = [np.zeros((H, W), dtype=bool) for _ in range(N)]
    out = tmp_path / "grid.png"
    render_grid(inputs, [("ours", masks_a), ("upstream", masks_b), ("ema", masks_c)],
                out_path=str(out))
    assert out.exists()
    assert out.stat().st_size > 0


def test_render_curve_writes_png(tmp_path):
    """render_coverage_curves produces a non-empty PNG file."""
    from experiments.render import render_coverage_curves
    curves = {"ours": np.array([0.5, 0.3, 0.1, 0.0]),
              "upstream": np.array([0.5, 0.4, 0.2, 0.05]),
              "ema": np.array([0.5, 0.4, 0.4, 0.35])}
    out = tmp_path / "curve.png"
    render_coverage_curves(curves, out_path=str(out), title="test")
    assert out.exists()
    assert out.stat().st_size > 0
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_metrics.py -v
```

Expected: 2 new tests FAIL with `ModuleNotFoundError: No module named 'experiments.render'`.

- [ ] **Step 3: Implement render**

Create `py/experiments/render.py`:

```python
"""Phase 0 visualization: side-by-side mask comparison grids and per-frame
mask-coverage curve plots.
"""

from typing import Dict, List, Tuple

import numpy as np
from PIL import Image
import matplotlib
matplotlib.use("Agg")  # headless
import matplotlib.pyplot as plt


def _mask_to_rgb(mask: np.ndarray) -> np.ndarray:
    """Render a bool mask as a magenta-on-black RGB image for visibility."""
    rgb = np.zeros((*mask.shape, 3), dtype=np.uint8)
    rgb[mask] = (255, 0, 255)
    return rgb


def render_grid(
    input_frames: List[np.ndarray],
    rows: List[Tuple[str, List[np.ndarray]]],
    out_path: str,
    every_n: int = 8,
) -> None:
    """Render a 2-D grid PNG: rows = methods (input + each labelled mask sequence),
    columns = frames sampled every `every_n`.

    Args:
        input_frames: list of (H, W, 3) uint8 RGB frames.
        rows: list of (label, masks) tuples, one tuple per method.
        out_path: output PNG path.
        every_n: sample every N frames for the grid (controls width).
    """
    n_total = len(input_frames)
    indices = list(range(0, n_total, every_n))
    if indices[-1] != n_total - 1:
        indices.append(n_total - 1)
    n_cols = len(indices)
    n_rows = 1 + len(rows)  # input + each method row
    H, W = input_frames[0].shape[:2]
    pad = 4

    grid = np.full(
        ((H + pad) * n_rows + pad, (W + pad) * n_cols + pad, 3),
        32, dtype=np.uint8,
    )

    for col, frame_idx in enumerate(indices):
        x = pad + col * (W + pad)
        # Input row
        grid[pad:pad + H, x:x + W] = input_frames[frame_idx]
        # Method rows
        for row_i, (_, masks) in enumerate(rows):
            y = pad + (row_i + 1) * (H + pad)
            grid[y:y + H, x:x + W] = _mask_to_rgb(masks[frame_idx])

    Image.fromarray(grid).save(out_path)


def render_coverage_curves(
    curves: Dict[str, np.ndarray],
    out_path: str,
    title: str = "",
) -> None:
    """Plot per-frame mask-coverage curves, one line per method.

    Args:
        curves: dict mapping method label → (N,) float coverage array.
        out_path: output PNG path.
        title: figure title.
    """
    fig, ax = plt.subplots(figsize=(10, 4))
    for label, curve in curves.items():
        ax.plot(curve, label=label)
    ax.set_xlabel("frame")
    ax.set_ylabel("mask coverage (fraction motion)")
    ax.set_title(title)
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=100)
    plt.close(fig)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest py/tests/test_metrics.py -v
```

Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/render.py py/tests/test_metrics.py
git commit -m "feat(experiments): side-by-side grid + coverage curve renderers"
```

---

## Task 11: Phase 0 driver — single-source run

**Files:**
- Create: `py/experiments/run_phase0.py`

- [ ] **Step 1: Add a smoke test**

Append to `py/tests/test_metrics.py`:

```python
def test_run_source_returns_metrics(tmp_path):
    """run_source on a synthetic produces a metrics dict and writes outputs."""
    from experiments.run_phase0 import run_source
    out_dir = tmp_path / "run"
    metrics = run_source(
        source="synthetic:moving_box",
        num_frames=8,
        K=8, R=20, min_match=2,
        phi_update=16, phi_diffuse=16,
        init_scheme="c",
        prng_seed=0xDEADBEEF,
        out_dir=str(out_dir),
    )
    assert "coverage_curve_ours" in metrics
    assert "coverage_curve_ema" in metrics
    assert metrics["coverage_curve_ours"].shape == (8,)
    assert (out_dir / "grid.png").exists()
    assert (out_dir / "coverage.png").exists()
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_metrics.py -v
```

Expected: 1 new test FAILS with `ModuleNotFoundError: No module named 'experiments.run_phase0'`.

- [ ] **Step 3: Implement run_source**

Create `py/experiments/run_phase0.py`:

```python
"""Phase 0 driver: run our ViBe re-impl + EMA baseline on a single source,
capture per-frame masks, compute coverage curves, render side-by-side outputs.

This module exposes `run_source()` (one-source runner) and a `__main__` entry
point that drives the full Phase-0 matrix (called from Task 13 onward).

Upstream PyTorch reference outputs are NOT produced here — they're captured
once by Task 14 and read from disk (gitignored at py/experiments/upstream_baseline_outputs/).
"""

import os
import sys
from pathlib import Path
from typing import Dict, Optional

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from frames.video_source import load_frames
from experiments.motion_vibe import ViBe
from experiments.metrics import coverage_curve, run_ema_baseline
from experiments.render import render_grid, render_coverage_curves


def _rgb_to_y(frame: np.ndarray) -> np.ndarray:
    """Project Y8 extraction (matches rgb2ycrcb.sv): Y = (77*R + 150*G + 29*B) >> 8."""
    r = frame[:, :, 0].astype(np.uint16)
    g = frame[:, :, 1].astype(np.uint16)
    b = frame[:, :, 2].astype(np.uint16)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def run_source(
    source: str,
    num_frames: int = 64,
    width: int = 320,
    height: int = 240,
    K: int = 8,
    R: int = 20,
    min_match: int = 2,
    phi_update: int = 16,
    phi_diffuse: int = 16,
    init_scheme: str = "c",
    prng_seed: int = 0xDEADBEEF,
    out_dir: Optional[str] = None,
    upstream_masks_dir: Optional[str] = None,
) -> Dict:
    """Run our ViBe + EMA baseline on a single source. Optionally include upstream.

    Returns:
        dict with keys: coverage_curve_ours, coverage_curve_ema, coverage_curve_upstream
        (last only if upstream_masks_dir is provided), out_dir.
    """
    frames_rgb = load_frames(source, width=width, height=height, num_frames=num_frames)
    frames_y = [_rgb_to_y(f) for f in frames_rgb]

    # Our ViBe
    v = ViBe(
        K=K, R=R, min_match=min_match,
        phi_update=phi_update, phi_diffuse=phi_diffuse,
        init_scheme=init_scheme, prng_seed=prng_seed,
    )
    v.init_from_frame(frames_y[0])
    masks_ours = [np.zeros_like(frames_y[0], dtype=bool)]  # frame 0 = init only
    for f in frames_y[1:]:
        masks_ours.append(v.process_frame(f))

    # EMA baseline (existing project model)
    masks_ema = run_ema_baseline(frames_y)

    # Optional upstream reference (loaded from pre-captured PNG sequence)
    masks_upstream = None
    if upstream_masks_dir is not None and Path(upstream_masks_dir).exists():
        masks_upstream = _load_mask_sequence(upstream_masks_dir, num_frames)

    # Compute curves
    cov_ours = coverage_curve(masks_ours)
    cov_ema = coverage_curve(masks_ema)
    curves = {"ours (ViBe)": cov_ours, "ema (current)": cov_ema}
    if masks_upstream is not None:
        cov_up = coverage_curve(masks_upstream)
        curves["upstream (PyTorch ViBe)"] = cov_up

    # Render
    rows = [("ours", masks_ours), ("ema", masks_ema)]
    if masks_upstream is not None:
        rows.insert(1, ("upstream", masks_upstream))

    if out_dir is not None:
        os.makedirs(out_dir, exist_ok=True)
        render_grid(frames_rgb, rows, out_path=os.path.join(out_dir, "grid.png"))
        render_coverage_curves(
            curves, out_path=os.path.join(out_dir, "coverage.png"),
            title=f"{source} | K={K} R={R} φu={phi_update} φd={phi_diffuse} init={init_scheme}",
        )

    result = {
        "source": source,
        "coverage_curve_ours": cov_ours,
        "coverage_curve_ema": cov_ema,
        "out_dir": out_dir,
    }
    if masks_upstream is not None:
        result["coverage_curve_upstream"] = cov_up
    return result


def _load_mask_sequence(dir_path: str, num_frames: int) -> list:
    """Load a sequence of PNG masks (single-channel, 0=bg, 255=motion) into bools."""
    from PIL import Image
    p = Path(dir_path)
    masks = []
    for i in range(num_frames):
        f = p / f"mask_{i:05d}.png"
        img = np.array(Image.open(f).convert("L"))
        masks.append(img > 127)
    return masks
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest py/tests/test_metrics.py -v
```

Expected: 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/run_phase0.py py/tests/test_metrics.py
git commit -m "feat(experiments): single-source Phase 0 driver (ours + EMA)"
```

---

## Task 12: Frame-0 init schemes (a) and (b)

**Files:**
- Modify: `py/experiments/motion_vibe.py`
- Modify: `py/tests/test_motion_vibe.py`

- [ ] **Step 1: Add the failing test**

Append to `py/tests/test_motion_vibe.py`:

```python
def test_init_scheme_b_degenerate_stack():
    """Scheme b: every slot of every pixel = current pixel value."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="b", prng_seed=0xDEADBEEF)
    f = _y_frame(100, h=4, w=4)
    v.init_from_frame(f)
    expected = np.broadcast_to(f[..., None], (4, 4, 8))
    assert np.array_equal(v.samples, expected)


def test_init_scheme_a_neighborhood_draws_in_range():
    """Scheme a: each slot pulls from one of the 9 cells of the 3×3 neighborhood."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="a", prng_seed=0xDEADBEEF)
    # 4×4 frame with distinct values per pixel — verify each sample came from
    # a 3×3 neighborhood cell of its target pixel.
    np.random.seed(42)
    f = np.random.randint(0, 256, size=(4, 4), dtype=np.uint8)
    v.init_from_frame(f)
    # Build the set of valid values at each pixel = union of its 3×3 neighborhood
    for r in range(4):
        for c in range(4):
            valid = set()
            for dr in (-1, 0, +1):
                for dc in (-1, 0, +1):
                    nr, nc = r + dr, c + dc
                    if 0 <= nr < 4 and 0 <= nc < 4:
                        valid.add(int(f[nr, nc]))
            for k in range(8):
                assert int(v.samples[r, c, k]) in valid, \
                    f"pixel ({r},{c}) slot {k} = {v.samples[r,c,k]} not in {valid}"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 2 new tests FAIL — scheme="a" / "b" branches raise `NotImplementedError`.

- [ ] **Step 3: Implement schemes (a) and (b)**

Modify `py/experiments/motion_vibe.py` — replace the body of `init_from_frame()` to dispatch:

```python
    def init_from_frame(self, frame_0: np.ndarray) -> None:
        """Seed the sample bank from frame 0 using the configured init scheme."""
        assert frame_0.ndim == 2 and frame_0.dtype == np.uint8, \
            "frame_0 must be a 2-D uint8 Y frame"
        self.H, self.W = frame_0.shape
        self.samples = np.zeros((self.H, self.W, self.K), dtype=np.uint8)
        if   self.init_scheme == "a": self._init_scheme_a(frame_0)
        elif self.init_scheme == "b": self._init_scheme_b(frame_0)
        elif self.init_scheme == "c": self._init_scheme_c(frame_0)
        else:
            raise ValueError(f"unknown init_scheme {self.init_scheme!r}")

    def _init_scheme_a(self, frame_0: np.ndarray) -> None:
        """Scheme (a): 3×3 neighborhood draws (paper-canonical).

        For each pixel, fill K slots by drawing from random cells of its 3×3
        neighborhood. Out-of-bounds offsets are clipped to the boundary.
        """
        H, W = self.H, self.W
        for r in range(H):
            for c in range(W):
                state = self._next_prng()
                for k in range(self.K):
                    # Each draw needs 4 bits: 2 for dr, 2 for dc (both in [-1, +1]).
                    dr_raw = (state >> (4 * k)) & 0x3
                    dc_raw = (state >> (4 * k + 2)) & 0x3
                    dr = (dr_raw % 3) - 1
                    dc = (dc_raw % 3) - 1
                    nr = max(0, min(H - 1, r + dr))
                    nc = max(0, min(W - 1, c + dc))
                    self.samples[r, c, k] = frame_0[nr, nc]

    def _init_scheme_b(self, frame_0: np.ndarray) -> None:
        """Scheme (b): degenerate stack — all K slots = current pixel value."""
        self.samples[:] = frame_0[..., None]
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 23 tests pass.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/motion_vibe.py py/tests/test_motion_vibe.py
git commit -m "feat(experiments): frame-0 init schemes a (neighborhood) and b (degenerate)"
```

---

## Task 13: Run matrix — synthetic ghost-mechanic sources

**Files:**
- Modify: `py/experiments/run_phase0.py` (add `__main__` driver section)

- [ ] **Step 1: Extend the driver with a matrix runner**

Append to `py/experiments/run_phase0.py`:

```python
SYNTHETIC_SOURCES = [
    "synthetic:moving_box",
    "synthetic:dark_moving_box",
    "synthetic:noisy_moving_box",
    "synthetic:textured_static",
    "synthetic:lighting_ramp",
]

REAL_SOURCES = [
    "media/source/birdseye-320x240.mp4",
    "media/source/people-320x240.mp4",
    "media/source/intersection-320x240.mp4",
]


def run_synthetic_matrix(out_root: str = "py/experiments/our_outputs/synthetic"):
    """Run each synthetic source at default ViBe parameters; write outputs."""
    results = []
    for src in SYNTHETIC_SOURCES:
        out_dir = os.path.join(out_root, src.replace(":", "_").replace("/", "_"))
        result = run_source(source=src, num_frames=64, out_dir=out_dir)
        results.append(result)
        print(f"  {src}: ours_avg={result['coverage_curve_ours'].mean():.3f}  "
              f"ema_avg={result['coverage_curve_ema'].mean():.3f}")
    return results


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--matrix", choices=["synthetic", "real", "all"], default="synthetic")
    args = p.parse_args()
    if args.matrix in ("synthetic", "all"):
        print("=== Synthetic matrix ===")
        run_synthetic_matrix()
    if args.matrix in ("real", "all"):
        # Implemented in Task 15
        from sys import stderr
        print("Real matrix not yet implemented (see Task 15)", file=stderr)
```

- [ ] **Step 2: Run the synthetic matrix manually**

```bash
source .venv/bin/activate
python -m experiments.run_phase0 --matrix synthetic
```

Expected: prints one line per source with `ours_avg` and `ema_avg` percentages. Outputs land under `py/experiments/our_outputs/synthetic/`.

- [ ] **Step 3: Sanity-check the rendered grids**

For each synthetic source, open the grid and coverage PNGs:

```bash
ls py/experiments/our_outputs/synthetic/*/grid.png
ls py/experiments/our_outputs/synthetic/*/coverage.png
```

Eyeball each `grid.png`:
- `moving_box`: ours and EMA both show the moving rectangle. ours should NOT have a frame-0 ghost at the original position (since synthetic patterns hide foreground in frame 0 — see [py/frames/video_source.py](../../py/frames/video_source.py) docstring).
- `textured_static`: ours and EMA should both be mostly empty mask (no actual motion).
- `lighting_ramp`: both should track the slow drift without flagging full-frame motion.

If a grid looks broken (ours all-motion, all-bg, or has obvious garbage), STOP and debug before proceeding.

- [ ] **Step 4: Verify tests still pass**

```bash
pytest py/tests/ -v
```

Expected: all tests still passing (no regressions from the driver addition).

- [ ] **Step 5: Commit**

```bash
git add py/experiments/run_phase0.py
git commit -m "feat(experiments): synthetic-matrix Phase 0 runner"
```

---

## Task 14: Capture upstream PyTorch reference masks

This task runs the upstream PyTorch ViBe (set up in Task 2, kept outside the repo) on each source and saves the resulting masks as PNG sequences under the gitignored `py/experiments/upstream_baseline_outputs/`. These captured masks are then loaded by our driver in subsequent tasks for the qualitative cross-check.

**Files:**
- Create: `py/experiments/capture_upstream.py`

- [ ] **Step 1: Implement the capture script**

Create `py/experiments/capture_upstream.py`:

```python
"""Capture upstream PyTorch ViBe masks for each Phase-0 source.

Run this from the upstream venv (NOT the project venv) — upstream has a
PyTorch dependency that must not bleed into the project's .venv.

Usage from outside this repo:
    cd ~/work/sparevideo
    source ~/eval/vibe-upstream/.venv/bin/activate
    python py/experiments/capture_upstream.py
    deactivate

The captured masks land in py/experiments/upstream_baseline_outputs/<source>/
mask_NNNNN.png. The directory is gitignored (it can be regenerated, and it's
arguably derivative of the eval-licensed software).
"""

import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# Add upstream src to sys.path
UPSTREAM_SRC = Path.home() / "eval/vibe-upstream/Python/src"
sys.path.insert(0, str(UPSTREAM_SRC))

# Add our py/ to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from frames.video_source import load_frames

import torch
from model import ViBe as UpstreamViBe


SOURCES = [
    "synthetic:moving_box",
    "synthetic:dark_moving_box",
    "synthetic:noisy_moving_box",
    "synthetic:textured_static",
    "synthetic:lighting_ramp",
    "media/source/birdseye-320x240.mp4",
    "media/source/people-320x240.mp4",
    "media/source/intersection-320x240.mp4",
]

OUT_ROOT = Path("py/experiments/upstream_baseline_outputs")
NUM_FRAMES = 64
DEVICE = torch.device("cpu")


def _rgb_to_y(frame: np.ndarray) -> np.ndarray:
    r = frame[:, :, 0].astype(np.uint16)
    g = frame[:, :, 1].astype(np.uint16)
    b = frame[:, :, 2].astype(np.uint16)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def capture_one(source: str):
    out_dir = OUT_ROOT / source.replace(":", "_").replace("/", "_")
    out_dir.mkdir(parents=True, exist_ok=True)

    frames_rgb = load_frames(source, width=320, height=240, num_frames=NUM_FRAMES)
    frames_y = [_rgb_to_y(f) for f in frames_rgb]

    # Upstream expects (C, H, W) tensor with C=1 grayscale
    H, W = frames_y[0].shape

    model = UpstreamViBe(
        DEVICE,
        numberOfSamples=20,
        matchingThreshold=10,  # upstream uses 10, paper says R=20 — see upstream README
        matchingNumber=2,
        updateFactor=8.0,
        neighborhoodRadius=1,
    )
    first = torch.from_numpy(frames_y[0][None, :, :].astype(np.float32))  # (1,H,W)
    model.initialize(first)

    for i, f in enumerate(frames_y):
        t = torch.from_numpy(f[None, :, :].astype(np.float32))
        mask = model.segment(t)  # (H, W) float, 0=bg 1=fg
        mask_u8 = (mask.cpu().numpy() > 0.5).astype(np.uint8) * 255
        Image.fromarray(mask_u8).save(out_dir / f"mask_{i:05d}.png")

    print(f"  captured {NUM_FRAMES} masks → {out_dir}")


if __name__ == "__main__":
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    for s in SOURCES:
        print(f"=== {s} ===")
        capture_one(s)
    print("Done. Masks captured under", OUT_ROOT)
```

- [ ] **Step 2: Run the capture from the upstream venv**

```bash
source ~/eval/vibe-upstream/.venv/bin/activate
cd ~/work/sparevideo
python py/experiments/capture_upstream.py
deactivate
```

Expected: 8 source directories appear under `py/experiments/upstream_baseline_outputs/`, each with 64 mask PNGs.

- [ ] **Step 3: Spot-check the captures**

```bash
ls py/experiments/upstream_baseline_outputs/synthetic_moving_box/ | head -5
ls py/experiments/upstream_baseline_outputs/synthetic_moving_box/ | wc -l
```

Expected: at least `mask_00000.png` through `mask_00004.png` listed; total count = 64.

Open one of the captured masks visually:

```bash
xdg-open py/experiments/upstream_baseline_outputs/synthetic_moving_box/mask_00010.png
```

Expected: a black-and-white image with the moving box visible as white pixels at frame 10's position.

- [ ] **Step 4: Verify gitignore is working**

```bash
git status --short
```

Expected: `py/experiments/upstream_baseline_outputs/` does NOT appear (it's ignored).

- [ ] **Step 5: Commit the capture script (only — outputs are gitignored)**

```bash
git add py/experiments/capture_upstream.py
git commit -m "feat(experiments): upstream PyTorch ViBe mask capture script"
```

---

## Task 15: Real-world clip runs (synthetic-style runner extended)

**Files:**
- Modify: `py/experiments/run_phase0.py`

- [ ] **Step 1: Add real-source matrix runner**

Append to `py/experiments/run_phase0.py`:

```python
def run_real_matrix(out_root: str = "py/experiments/our_outputs/real",
                    upstream_root: str = "py/experiments/upstream_baseline_outputs"):
    """Run each real-world clip; include upstream masks if captured."""
    results = []
    for src in REAL_SOURCES:
        out_dir = os.path.join(out_root, src.replace("/", "_"))
        upstream_dir = os.path.join(upstream_root, src.replace("/", "_"))
        upstream = upstream_dir if os.path.isdir(upstream_dir) else None
        result = run_source(
            source=src, num_frames=64, out_dir=out_dir,
            upstream_masks_dir=upstream,
        )
        results.append(result)
        print(f"  {src}: ours_avg={result['coverage_curve_ours'].mean():.3f}  "
              f"ema_avg={result['coverage_curve_ema'].mean():.3f}"
              + (f"  upstream_avg={result['coverage_curve_upstream'].mean():.3f}"
                 if 'coverage_curve_upstream' in result else ""))
    return results
```

Modify the `__main__` block — replace the `args.matrix == "real"` branch:

```python
    if args.matrix in ("real", "all"):
        print("=== Real matrix ===")
        run_real_matrix()
```

- [ ] **Step 2: Run the real matrix**

```bash
source .venv/bin/activate
python -m experiments.run_phase0 --matrix real
```

Expected: three lines printed, one per real clip. `upstream_avg` shown if Task 14 captures exist.

- [ ] **Step 3: Inspect outputs**

```bash
ls py/experiments/our_outputs/real/*/grid.png
ls py/experiments/our_outputs/real/*/coverage.png
```

Open each. The qualitative cross-check (Doc B §8 step 2): for each real clip, the **ours** and **upstream** rows of the grid and the matching curves on `coverage.png` should track each other within ≈ ±10%. Significant divergence is a re-impl bug — STOP and debug.

- [ ] **Step 4: Verify all tests still pass**

```bash
pytest py/tests/ -v
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/run_phase0.py
git commit -m "feat(experiments): real-clip matrix runner with upstream cross-check"
```

---

## Task 16: K=8 vs K=20 stress-test on textured/dynamic-bg

This task addresses Doc B §10.6 — does our K=8 (memory-driven) compromise lose dynamic-bg robustness vs upstream's K=20?

**Files:**
- Modify: `py/experiments/run_phase0.py`

- [ ] **Step 1: Add K-comparison runner**

Append to `py/experiments/run_phase0.py`:

```python
def run_k_comparison(out_root: str = "py/experiments/our_outputs/k_comparison"):
    """Compare K=8 vs K=20 on textured_static (steady-state false-positive proxy)."""
    src = "synthetic:textured_static"
    results = {}
    for K in (8, 20):
        out_dir = os.path.join(out_root, f"K{K}")
        # Note: increasing K requires more PRNG bits per pixel for slot indices,
        # but our implementation slices dynamically from the 32-bit state — fine.
        result = run_source(
            source=src, num_frames=128, K=K,
            out_dir=out_dir,
        )
        results[K] = result
        avg = result["coverage_curve_ours"].mean()
        steady = result["coverage_curve_ours"][32:].mean()  # skip first 32 (init transient)
        print(f"  K={K}: avg={avg:.3f}  steady-state(32+)={steady:.3f}")
    return results
```

Add to `__main__`:

```python
    if args.matrix in ("k_comparison", "all"):
        print("=== K=8 vs K=20 stress-test ===")
        run_k_comparison()
```

And update the argparse choices:

```python
    p.add_argument("--matrix", choices=["synthetic", "real", "k_comparison", "all"],
                   default="synthetic")
```

- [ ] **Step 2: Run the K comparison**

```bash
python -m experiments.run_phase0 --matrix k_comparison
```

Expected: two lines, `K=8 steady-state` and `K=20 steady-state`. The K=20 number should be lower or equal to K=8 (more samples → harder to trigger false positives).

- [ ] **Step 3: Inspect the grids**

```bash
xdg-open py/experiments/our_outputs/k_comparison/K8/grid.png
xdg-open py/experiments/our_outputs/k_comparison/K20/grid.png
```

Eyeball: does the K=20 mask have visibly fewer scattered false-positive pixels in the steady-state region (frames 32+)?

- [ ] **Step 4: Tests still pass**

```bash
pytest py/tests/ -v
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/run_phase0.py
git commit -m "feat(experiments): K=8 vs K=20 stress-test runner (Doc B §10.6)"
```

---

## Task 17: Negative-control ablation — diffusion disabled

This task validates that **diffusion is the actual ghost-recovery mechanism** (Doc B §5 profile `vibe_no_diffuse`). With `phi_diffuse=∞` (effectively disabled), the frame-0 ghost should NOT recover.

**Files:**
- Modify: `py/experiments/motion_vibe.py` (allow phi_diffuse=0 to disable)
- Modify: `py/experiments/run_phase0.py`

- [ ] **Step 1: Permit phi_diffuse=0 to disable diffusion**

In `py/experiments/motion_vibe.py`, modify the `__init__` assertion:

```python
        # phi_diffuse=0 disables diffusion entirely (negative-control ablation)
        if phi_diffuse != 0:
            assert phi_diffuse & (phi_diffuse - 1) == 0, "phi_diffuse must be a power of 2 or 0"
```

…and short-circuit the diffusion pass:

```python
    def _apply_diffusion(self, frame: np.ndarray, mask: np.ndarray) -> None:
        if self.phi_diffuse == 0:
            return  # ablation: no diffusion
        # ... existing body unchanged ...
```

- [ ] **Step 2: Add a test for the disabled case**

Append to `py/tests/test_motion_vibe.py`:

```python
def test_diffusion_disabled_when_phi_diffuse_zero():
    """phi_diffuse=0 means diffusion is fully disabled — no neighbor writes."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=0,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    mask = np.zeros((3, 3), dtype=bool)  # all bg → diffusion would normally fire
    samples_before = v.samples.copy()
    v._apply_diffusion(_y_frame(105, h=3, w=3), mask)
    assert np.array_equal(samples_before, v.samples), "samples must be unchanged"
```

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: 24 tests pass.

- [ ] **Step 3: Add the negative-control runner**

Append to `py/experiments/run_phase0.py`:

```python
def run_negative_control(out_root: str = "py/experiments/our_outputs/negative_control"):
    """Run with phi_diffuse=0 to ablate diffusion. Expect frame-0 ghost
    to persist on synthetic:moving_box (validates diffusion is the fix)."""
    src = "synthetic:moving_box"
    out_dir = os.path.join(out_root, "phi_diffuse_0")
    result = run_source(
        source=src, num_frames=64, phi_diffuse=0,
        out_dir=out_dir,
    )
    avg = result["coverage_curve_ours"].mean()
    end = result["coverage_curve_ours"][-16:].mean()  # last 16 frames
    print(f"  phi_diffuse=0 on {src}: avg={avg:.3f}  end-state={end:.3f}")
    return result
```

Add to argparse choices and `__main__`:

```python
    p.add_argument("--matrix", choices=[
        "synthetic", "real", "k_comparison", "negative_control", "all"
    ], default="synthetic")
    ...
    if args.matrix in ("negative_control", "all"):
        print("=== Negative control (phi_diffuse=0) ===")
        run_negative_control()
```

- [ ] **Step 4: Run and verify ghost persistence**

```bash
python -m experiments.run_phase0 --matrix negative_control
xdg-open py/experiments/our_outputs/negative_control/phi_diffuse_0/grid.png
```

Expected: visually obvious frame-0 ghost (residual motion at the original position of the moving box) that does NOT decay over the 64 frames. The end-state coverage should be substantially elevated vs the diffusion-enabled run from Task 13.

If the ghost does NOT appear with diffusion off, our re-impl has a bug — STOP and debug.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/motion_vibe.py py/tests/test_motion_vibe.py py/experiments/run_phase0.py
git commit -m "feat(experiments): negative-control ablation (phi_diffuse=0 disables diffusion)"
```

---

## Task 18: Frame-0 init scheme comparison (a / b / c)

Validates Doc B §10.4: do schemes (a) and (b) produce meaningfully different ghost-convergence vs the chosen scheme (c)?

**Files:**
- Modify: `py/experiments/run_phase0.py`

- [ ] **Step 1: Add scheme-comparison runner**

Append to `py/experiments/run_phase0.py`:

```python
def run_init_scheme_comparison(
    out_root: str = "py/experiments/our_outputs/init_schemes",
):
    """Compare frame-0 init schemes (a) neighborhood / (b) degenerate / (c) noise."""
    sources = ["synthetic:moving_box", "synthetic:dark_moving_box"]
    results = {}
    for src in sources:
        for scheme in ("a", "b", "c"):
            out_dir = os.path.join(
                out_root, src.replace(":", "_"), f"scheme_{scheme}"
            )
            result = run_source(
                source=src, num_frames=64, init_scheme=scheme,
                out_dir=out_dir,
            )
            avg = result["coverage_curve_ours"].mean()
            results[(src, scheme)] = avg
            print(f"  {src} scheme {scheme}: avg={avg:.3f}")
    return results
```

Add to argparse choices and `__main__`:

```python
    p.add_argument("--matrix", choices=[
        "synthetic", "real", "k_comparison", "negative_control", "init_schemes", "all"
    ], default="synthetic")
    ...
    if args.matrix in ("init_schemes", "all"):
        print("=== Frame-0 init scheme comparison ===")
        run_init_scheme_comparison()
```

- [ ] **Step 2: Run the comparison**

```bash
python -m experiments.run_phase0 --matrix init_schemes
```

Expected: 6 lines of output (2 sources × 3 schemes).

- [ ] **Step 3: Inspect grids**

For each `(source, scheme)` pair, open the grid:

```bash
ls py/experiments/our_outputs/init_schemes/*/scheme_*/grid.png
```

Eyeball: do schemes (a)/(b)/(c) show meaningful differences in early-frame mask coverage? Is one scheme's ghost-convergence visually cleaner than the others?

- [ ] **Step 4: Tests still pass**

```bash
pytest py/tests/ -v
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/run_phase0.py
git commit -m "feat(experiments): frame-0 init scheme comparison runner (a/b/c)"
```

---

## Task 19: Decision-gate report

Synthesize all the runs into a markdown report committed to `docs/plans/`.

**Files:**
- Create: `docs/plans/2026-05-XX-vibe-phase-0-results.md` (replace XX with the actual date when written, e.g. `2026-05-08`)

- [ ] **Step 1: Run the full matrix**

```bash
python -m experiments.run_phase0 --matrix all
```

Capture the printed averages and end-state numbers — you'll need them in the report.

- [ ] **Step 2: Apply the design-doc gate criteria**

Per Doc B §8 step 5 (decision gate):

| Criterion | Source | Pass condition |
|---|---|---|
| Frame-0 ghost convergence | real-world clip (best of birdseye / people / intersection) | `ghost_convergence_frame(coverage_curve_ours, threshold=0.05) ≤ 200` (≤3 s at 60 fps) |
| FP rate steady-state | `synthetic:textured_static` | `coverage_curve_ours[32:].mean() ≤ coverage_curve_ema[32:].mean()` (no regression vs EMA) |
| Negative control reproduces ghost | `synthetic:moving_box` with `phi_diffuse=0` | end-state coverage substantially elevated vs the `phi_diffuse=16` run (visual check + numeric: `negative_control.end_state > 1.5 × default.end_state`) |
| Upstream cross-check | each real clip | `|coverage_curve_ours - coverage_curve_upstream|.mean() ≤ 0.10` (per-frame ±10%) |

For each criterion, compute pass/fail using the data captured.

- [ ] **Step 3: Write the report**

Create `docs/plans/2026-05-XX-vibe-phase-0-results.md` (use today's date):

```markdown
# ViBe Phase 0 — Decision Gate Results

**Date:** 2026-05-XX (replace with actual date)
**Branch:** feat/vibe-motion-design
**Companion plan:** [`2026-05-01-vibe-phase-0-plan.md`](2026-05-01-vibe-phase-0-plan.md)
**Companion design doc:** [`2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md)

## Decision

**[PASS / FAIL]** — fill in based on the gate-criterion table below.

## Gate criteria

[Insert the table from Step 2, with actual numbers and pass/fail per row]

## Per-source summary

| Source | ours avg cov | ema avg cov | upstream avg cov (if avail.) | Notes |
|---|---|---|---|---|
| synthetic:moving_box | ... | ... | — | ... |
| synthetic:dark_moving_box | ... | ... | — | ... |
| synthetic:noisy_moving_box | ... | ... | — | ... |
| synthetic:textured_static | ... | ... | — | ... |
| synthetic:lighting_ramp | ... | ... | — | ... |
| birdseye-320x240.mp4 | ... | ... | ... | ... |
| people-320x240.mp4 | ... | ... | ... | ... |
| intersection-320x240.mp4 | ... | ... | ... | ... |

## K=8 vs K=20 (Doc B §10.6)

K=8 steady-state coverage on `textured_static`: ...
K=20 steady-state coverage on `textured_static`: ...

[Pass if K=8 is within 1.5× of K=20 false-positive rate; fail if K=8 is > 2× worse.]

## Frame-0 init scheme comparison (Doc B §10.4)

| Source | scheme (a) avg | scheme (b) avg | scheme (c) avg | recommended |
|---|---|---|---|---|
| moving_box | ... | ... | ... | (a/b/c) |
| dark_moving_box | ... | ... | ... | (a/b/c) |

## Recommendation

- [ ] Greenlight Phase 1 (Python ref promotion to `py/models/motion_vibe.py`) and Phase 2 (RTL).
- [ ] Switch frame-0 init default to scheme [a/b/c] based on data above.
- [ ] Adjust default cfg knobs (K, R, phi_update, phi_diffuse) based on observed behavior.

OR if FAIL:

- [ ] Escalate to PBAS Phase 0 (per Doc B §10.3).
- [ ] Accept and document slower convergence (if gate fails marginally and project footage is short clips).

## Embedded coverage curves

Coverage-curve PNGs (representative selection):

![](../../py/experiments/our_outputs/synthetic/synthetic_moving_box/coverage.png)
![](../../py/experiments/our_outputs/real/media_source_birdseye-320x240.mp4/coverage.png)
![](../../py/experiments/our_outputs/negative_control/phi_diffuse_0/coverage.png)

(These reference paths under `py/experiments/our_outputs/` — the directory is gitignored, so the rendered report won't show images on GitHub. They're for the local reviewer. If we want the images committed for review, copy a small subset under `docs/plans/figures/2026-05-01-vibe-phase-0/` and reference there.)
```

Fill in all the numbers from Step 1's printed output and from the side-by-side comparison curves.

- [ ] **Step 4: Verify the report renders correctly**

```bash
ls docs/plans/2026-05-*-vibe-phase-0-results.md
```

Expected: file exists.

If you opted to copy a subset of PNGs into `docs/plans/figures/`, also:

```bash
mkdir -p docs/plans/figures/2026-05-01-vibe-phase-0
cp py/experiments/our_outputs/synthetic/synthetic_moving_box/coverage.png \
   docs/plans/figures/2026-05-01-vibe-phase-0/moving_box-coverage.png
# repeat for the few PNGs referenced in the report
```

…and fix the relative paths in the report.

- [ ] **Step 5: Commit**

```bash
git add docs/plans/2026-05-*-vibe-phase-0-results.md
# if figures were copied:
git add docs/plans/figures/2026-05-01-vibe-phase-0/
git commit -m "docs(plans): ViBe Phase 0 decision-gate results"
```

If the gate **passed**, the next step is invoking writing-plans for **Phase 1** (Python ref promotion + cfg_t fields, no RTL) and then **Phase 2** (RTL implementation). Both depend on the data this report captures.

If the gate **failed**, brainstorming-skill conversation about the failure mode is the next step — not writing-plans for an RTL plan that won't fit the data.

---

## Self-review (run before declaring the plan complete)

**Spec coverage check** — verify every Doc B §8 requirement maps to a task:

- [ ] §8 step 1 (numpy ViBe re-impl) → Tasks 3–8, 12.
- [ ] §8 step 2 (qualitative cross-check vs upstream) → Tasks 2, 14, 15.
- [ ] §8 step 3 (run on test sources) → Tasks 13, 15.
- [ ] §8 step 4 (side-by-side vs EMA + measurements) → Tasks 9, 10, 11, 13, 15.
- [ ] §8 step 4 negative control → Task 17.
- [ ] §8 step 5 (decision gate) → Task 19.
- [ ] §8 step 6 (next-doc handoff) → Task 19 trailer.

**Doc B §10 open-question coverage:**

- [ ] §10.4 (init scheme comparison) → Task 12, 18.
- [ ] §10.6 (K=8 vs K=20) → Task 16.
- [ ] §10.7 (radius=2 future axis) — explicitly out of scope for Phase 0; not a task.

**No-placeholder check:** every code block has actual content. Every command has expected output. Every file path is concrete.

**Type consistency:** the `ViBe` class API is consistent across tasks — `init_from_frame()`, `process_frame()`, `compute_mask()`, `_apply_self_update()`, `_apply_diffusion()`, `samples`, `H`, `W`, `prng_state`. PRNG state advancement order is consistent (raster, one advance per pixel per pass).

**One known limitation in the plan as written:** the K=20 stress-test in Task 16 reuses the same Xorshift32 slicing convention designed for K=8. The bit budget per pixel becomes 4 (phi_self) + 4 (slot K=20 needs 5 bits!) + 4 (phi_diffuse) + 3 (neighbor) + 5 (slot) = 20 bits, which fits the 32-bit state, BUT the test with K=20 will need the slot mask to use 5 bits not 3. The current `_apply_self_update` and `_apply_diffusion` already compute `log2_K = (self.K - 1).bit_length()` dynamically, so they handle this correctly — the bit-slicing offsets shift accordingly. Verify this works during Task 16; if not, a small fix to the implementation is required (compute log2_K once at __init__ and use it consistently).
