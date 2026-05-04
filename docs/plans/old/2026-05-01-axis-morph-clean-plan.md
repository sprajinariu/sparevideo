# `axis_morph_clean` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `axis_morph3x3_open` in the motion-mask path with a single `axis_morph_clean` block that applies 3×3 morphological **open** followed by a parametrizable **close** (3×3 or 5×5). Two runtime gates (`morph_open_en`, `morph_close_en`) and one compile-time kernel-size knob (`morph_close_kernel`) drive the block.

**Architecture:** New module `axis_morph_clean` instantiates the existing `axis_morph3x3_erode` / `axis_morph3x3_dilate` primitives via a `generate` block. 3×3 close = 1 dilate + 1 erode; 5×5 close = 2 dilates + 2 erodes (Minkowski composition). No new line-buffer / window primitives. The block sits between `axis_motion_detect` and `axis_ccl` (same point in the pipeline as the current `axis_morph3x3_open`). Default profiles enable both stages with `morph_close_kernel=3`. The Python reference model gets a peer `morph_close` op alongside the existing `morph_open`, threaded through `models.motion.run` and `models.ccl_bbox.run`.

**Tech Stack:**
- **RTL:** SystemVerilog. New file `hw/ip/filters/rtl/axis_morph_clean.sv`. Existing 3×3 primitives unchanged.
- **Verification:** Single Verilator unit TB at `hw/ip/filters/tb/tb_axis_morph_clean.sv` covering the `(open_en, close_en, kernel) ∈ {0,1} × {0,1} × {3,5}` matrix plus backpressure / SOF tests. Top-level integration via `dv/sv/tb_sparevideo.sv` + `py/harness.py verify` matrix at TOLERANCE=0.
- **Python:** `py/models/ops/morph_close.py` (new). `py/models/motion.py` and `py/models/ccl_bbox.py` updated to thread the new fields. Profile parity test in `py/tests/test_profiles.py`.
- **Build:** `make lint`, `make test-ip-morph-clean` (new target replacing `test-ip-morph-open`), `make test-ip`, `make test-py`, `make run-pipeline`.

**Reference:** [Design doc](2026-05-01-axis-morph-clean-design.md). Read its §4 (Architecture), §5 (Configuration knobs), §7 (Python reference models), and §8 (Files) before starting. The plan below operationalizes that design.

---

## File Structure

| File | Role | Change |
|---|---|---|
| `docs/specs/axis_morph_clean-arch.md` | Arch spec for the whole block | **Create** |
| `docs/specs/axis_morph3x3_open-arch.md` | Old per-block arch spec | **Delete** (subsumed) |
| `hw/ip/filters/rtl/axis_morph_clean.sv` | RTL — combined open + close | **Create** (~150 LOC) |
| `hw/ip/filters/rtl/axis_morph3x3_open.sv` | Old combined open | **Delete** (subsumed) |
| `hw/ip/filters/tb/tb_axis_morph_clean.sv` | Unit TB | **Create** (~250 LOC) |
| `hw/ip/filters/tb/tb_axis_morph3x3_open.sv` | Old TB | **Delete** |
| `hw/ip/filters/filters.core` | FuseSoC | Register the new file, deregister the old |
| `hw/top/sparevideo_pkg.sv` | `cfg_t` + 9 profiles | Rename `morph_en` → `morph_open_en`; add `morph_close_en`, `morph_close_kernel` |
| `hw/top/sparevideo_top.sv` | Top wiring | Replace `u_morph_open` with `u_morph_clean`; rename `CFG.morph_en` references |
| `py/profiles.py` | Python mirror | Mirror cfg_t changes across all 9 profiles |
| `py/models/ops/morph_open.py` | Existing 3×3 open op | No change |
| `py/models/ops/morph_close.py` | New 3×3/5×5 close op | **Create** |
| `py/models/motion.py` | Motion ref model | Thread `morph_open_en`, `morph_close_en`, `morph_close_kernel` through `run()` |
| `py/models/ccl_bbox.py` | ccl_bbox ref model | Same as motion |
| `py/tests/test_morph_close.py` | Unit test for new op | **Create** |
| `py/tests/test_profiles.py` | Parity test | No code change — exercised when cfg_t changes |
| `dv/sim/Makefile` | Sim Makefile | Rename `test-ip-morph-open` → `test-ip-morph-clean` |
| `Makefile` (top) | Help text | Update `test-ip-morph-clean` line |
| `docs/specs/sparevideo-top-arch.md` | Top arch | Update §5 pipeline block name + line-buffer count |
| `CLAUDE.md` | Project memo | Update `hw/ip/filters/rtl/` description + the block list |
| `README.md` | Module status table | Replace `axis_morph3x3_open-arch.md` link with `axis_morph_clean-arch.md` |

---

## Task 1: Architecture spec

**Files:**
- Create: `docs/specs/axis_morph_clean-arch.md`

The spec is the design contract for the new block — write it before any RTL. Apply the `hardware-arch-doc` skill rules: §1 Purpose, §2 Module Hierarchy, §3 Interface, §4 Concept, §5 Internal Architecture, §6 Control Logic (none — pure structural), §7 Timing, §8 Shared Types, §9 Known Limitations, §10 References.

- [ ] **Step 1: Invoke the `hardware-arch-doc` skill.**

The skill enforces project-specific rules (datapath-only diagrams, no Python/TB narrative, term-before-use, etc.).

- [ ] **Step 2: Write the spec.**

Use [`docs/specs/axis_morph3x3_open-arch.md`](../specs/axis_morph3x3_open-arch.md) as the structural template. Key facts to encode:

- **§1 Purpose:** combined 3×3 open + parametrizable 3×3/5×5 close on a 1-bit motion mask AXIS stream; structural composition only.
- **§3 Parameters:** `H_ACTIVE`, `V_ACTIVE`, `CLOSE_KERNEL ∈ {3, 5}` (elaboration-time `assert`).
- **§3 Ports:** `clk_i`, `rst_n_i`, `morph_open_en_i`, `morph_close_en_i`, `s_axis (axis_if.rx)`, `m_axis (axis_if.tx)`. 1-bit mask data; `tuser`=SOF, `tlast`=EOL.
- **§4 Concept:** opening (γ) removes salt and thin features; closing (φ) bridges small holes; γφ is the canonical denoise+reconnect sequence (Soille §8.2). Minkowski algebra: `3×3 ⊕ 3×3 = 5×5`, so 5×5 close = two cascaded 3×3 dilates + two cascaded 3×3 erodes. State the `enable_i=0` deterministic-skid bypass on each sub-stage.
- **§5 Internal architecture:** datapath block diagram showing `erode → dilate → [dilate × N] → [erode × N]` where `N = (CLOSE_KERNEL - 1) / 2`. Resource cost table: 3×3 close = 4 sub-stages × 2 line buffers = 8; 5×5 close = 6 sub-stages × 2 line buffers = 12. Latency: 3×3 close = 4 row scans; 5×5 close = 6 row scans (each `axis_window3x3` adds ≈ `H_ACTIVE+3` cycles per the existing erode/dilate doc).
- **§7 Timing:** total latency `≈ N_stages × (H_ACTIVE + 3)` cycles. Well inside vblank (~144 kcycles for VGA).
- **§8 Shared types:** `cfg_t.morph_open_en`, `cfg_t.morph_close_en`, `cfg_t.morph_close_kernel`.
- **§9 Known limitations:** restricted to odd kernel sizes 3 and 5; 7×7 deferred. Bridges 1-px gaps at kernel=3, 2-px gaps at kernel=5; larger gaps fragment the mask.
- **§10 References:** [Soille (2003)] §8.2 alternating sequential filters; [Gonzalez & Woods (2018)] Ch. 9 binary mask cleanup; OpenCV background subtraction tutorial.

- [ ] **Step 3: Commit.**

```bash
git add docs/specs/axis_morph_clean-arch.md
git commit -m "docs(specs): add axis_morph_clean architecture spec"
```

---

## Task 2: cfg_t struct + profile updates (SV side)

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv` — `cfg_t` struct, all 9 named profiles
- Modify: `hw/top/sparevideo_top.sv` — rename `CFG.morph_en` → `CFG.morph_open_en`

This task does the SV-side rename and field additions. The Python parity test will fail until Task 3 mirrors the change.

- [ ] **Step 1: Update the `cfg_t` struct.**

In `hw/top/sparevideo_pkg.sv`, replace:

```sv
        logic       morph_en;            // 3x3 opening on mask
```

with:

```sv
        logic       morph_open_en;       // 3x3 opening on mask
        logic       morph_close_en;      // 3x3 or 5x5 closing on mask
        int         morph_close_kernel;  // 3 or 5; selects close kernel size
```

- [ ] **Step 2: Update each of the 9 named profiles to use the new field names + values.**

For every profile, change `morph_en: 1'b...` → `morph_open_en: 1'b...` (same value), then add two lines: `morph_close_en` and `morph_close_kernel`.

Default per the design doc §5.2:

| Profile | `morph_open_en` | `morph_close_en` | `morph_close_kernel` |
|---|---|---|---|
| `CFG_DEFAULT` | `1'b1` | `1'b1` | `3` |
| `CFG_DEFAULT_HFLIP` | `1'b1` | `1'b1` | `3` |
| `CFG_NO_EMA` | `1'b1` | `1'b1` | `3` |
| `CFG_NO_MORPH` | `1'b0` | `1'b0` | `3` |
| `CFG_NO_GAUSS` | `1'b1` | `1'b1` | `3` |
| `CFG_NO_GAMMA_COR` | `1'b1` | `1'b1` | `3` |
| `CFG_NO_SCALER` | `1'b1` | `1'b1` | `3` |
| `CFG_NO_HUD` | `1'b1` | `1'b1` | `3` |

Concrete example for `CFG_DEFAULT`:

```sv
    localparam cfg_t CFG_DEFAULT = '{
        motion_thresh:      8'd16,
        alpha_shift:        3,
        alpha_shift_slow:   6,
        grace_frames:       0,
        grace_alpha_shift:  1,
        gauss_en:           1'b1,
        morph_open_en:      1'b1,
        morph_close_en:     1'b1,
        morph_close_kernel: 3,
        hflip_en:           1'b0,
        gamma_en:           1'b1,
        scaler_en:          1'b1,
        hud_en:             1'b1,
        bbox_color:         24'h00_FF_00
    };
```

`CFG_NO_MORPH` is the only profile where both stages are off — keep `morph_close_kernel: 3` for consistency (the value is irrelevant when close is gated off).

- [ ] **Step 3: Update the existing comment block above each profile** that says "3x3 opening on mask"-style notes. Make them mention close where appropriate.

For `CFG_NO_MORPH`'s docblock specifically, update to: `"3x3 mask opening AND closing bypassed."`

- [ ] **Step 4: Rename `CFG.morph_en` references in `hw/top/sparevideo_top.sv`.**

Search for `CFG.morph_en` (currently passed as `enable_i` to `u_morph_open`):

```sv
        .enable_i (CFG.morph_en),
```

Change to:

```sv
        .enable_i (CFG.morph_open_en),
```

This is a pure rename — Task 8 will replace the `axis_morph3x3_open` instantiation with `axis_morph_clean`.

- [ ] **Step 5: Run lint to verify SV self-consistency.**

```bash
make lint
```

Expected: clean. Any reference to `morph_en` would error here.

- [ ] **Step 6: Run the Python parity test — expect FAIL.**

```bash
source .venv/bin/activate && PYTHONPATH=py python -m pytest py/tests/test_profiles.py -q
```

Expected: FAIL on field-name mismatch (`morph_en` is gone from cfg_t but still in py profile dicts). This proves the parity test catches drift.

- [ ] **Step 7: Commit.**

```bash
git add hw/top/sparevideo_pkg.sv hw/top/sparevideo_top.sv
git commit -m "pkg: rename morph_en -> morph_open_en, add morph_close_en + kernel

Renames the existing morph gate to morph_open_en for symmetry with the
upcoming morph_close_en. Adds two new cfg_t fields:
- morph_close_en (logic): runtime gate for the close stage
- morph_close_kernel (int): 3 or 5; compile-time kernel size

All 9 named profiles updated. CFG_NO_MORPH gates off both stages.
sparevideo_top updated to use the new field name; the actual close-stage
instantiation comes in a later commit. Python parity test will fail
until py/profiles.py is updated."
```

---

## Task 3: Python profile mirror

**Files:**
- Modify: `py/profiles.py` — every profile dict gets the new keys

- [ ] **Step 1: Update the `DEFAULT` profile dict.**

In `py/profiles.py`, find:

```python
DEFAULT: ProfileT = dict(
    motion_thresh=16,
    alpha_shift=3,
    alpha_shift_slow=6,
    grace_frames=0,
    grace_alpha_shift=1,
    gauss_en=True,
    morph_en=True,
    hflip_en=False,
    gamma_en=True,
    scaler_en=True,
    hud_en=True,
    bbox_color=(0x00, 0xFF, 0x00),
)
```

Replace `morph_en=True,` with:

```python
    morph_open_en=True,
    morph_close_en=True,
    morph_close_kernel=3,
```

- [ ] **Step 2: Update `NO_MORPH` to gate off both stages.**

Find:

```python
NO_MORPH: ProfileT = dict(DEFAULT, morph_en=False)
```

Replace with:

```python
NO_MORPH: ProfileT = dict(DEFAULT, morph_open_en=False, morph_close_en=False)
```

- [ ] **Step 3: Re-run the parity test — expect PASS.**

```bash
source .venv/bin/activate && PYTHONPATH=py python -m pytest py/tests/test_profiles.py -q
```

Expected: 10 passed.

- [ ] **Step 4: Re-run the rest of the Python test suite — expect PASS.**

```bash
PYTHONPATH=py python -m pytest py/tests/ -q --ignore=py/tests/test_vga.py
```

Expected: all green. The new fields are not yet consumed by `motion.py` / `ccl_bbox.py`, so they're effectively no-ops at this point — existing tests still pass.

- [ ] **Step 5: Commit.**

```bash
git add py/profiles.py
git commit -m "py(profiles): mirror morph_open_en + morph_close_en + kernel

Mirrors the cfg_t rename from sparevideo_pkg. NO_MORPH gates off both
stages. Parity test passes; Python motion / ccl_bbox models still ignore
the new fields (consumption added in a later commit)."
```

---

## Task 4: Python `morph_close` op + unit tests

**Files:**
- Create: `py/models/ops/morph_close.py`
- Create: `py/tests/test_morph_close.py`

The new op mirrors `py/models/ops/morph_open.py` in style (scipy `grey_dilation`/`grey_erosion`, `mode='nearest'` to match RTL EDGE_REPLICATE), but with the order flipped (dilate then erode) and a kernel-size argument.

- [ ] **Step 1: Write the failing test.**

Create `py/tests/test_morph_close.py`:

```python
"""Unit tests for py/models/ops/morph_close.py.

morph_close mirrors the future axis_morph_clean RTL close stage. The
contract: input is a (H, W) bool mask, output is a (H, W) bool mask
after dilate-then-erode with the requested kernel. Kernel ∈ {3, 5}.
EDGE_REPLICATE policy at all four borders (scipy mode='nearest').
"""
from __future__ import annotations
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np
import pytest

from models.ops.morph_close import morph_close


def _put(mask: np.ndarray, ys, xs) -> None:
    for y, x in zip(ys, xs):
        mask[y, x] = True


def test_3x3_close_fills_single_pixel_hole():
    """A 1-px hole in the centre of a 3x3 foreground patch is filled by
    a 3x3 close (dilate fills the hole; subsequent erode preserves it)."""
    m = np.zeros((5, 5), dtype=bool)
    m[1:4, 1:4] = True
    m[2, 2] = False  # 1-px hole at center
    out = morph_close(m, kernel=3)
    assert out[2, 2], "3x3 close should fill a 1-px hole"
    # Outer foreground unchanged.
    assert out[1:4, 1:4].all()


def test_3x3_close_does_not_fill_3x3_hole():
    """A 3x3 hole inside a 5x5 foreground is NOT filled by a 3x3 close
    (the dilate can only grow blobs by one pixel; the hole is too big)."""
    m = np.ones((7, 7), dtype=bool)
    m[2:5, 2:5] = False  # 3x3 hole at center
    out = morph_close(m, kernel=3)
    assert not out[3, 3], "3x3 close should NOT fill a 3x3 hole"


def test_5x5_close_fills_2x2_hole():
    """A 2x2 hole inside a larger foreground is filled by a 5x5 close."""
    m = np.ones((8, 8), dtype=bool)
    m[3:5, 3:5] = False  # 2x2 hole
    out = morph_close(m, kernel=5)
    assert out[3:5, 3:5].all(), "5x5 close should fill a 2x2 hole"


def test_5x5_close_does_not_fill_5x5_hole():
    """A 5x5 hole is too big for a 5x5 close to fill."""
    m = np.ones((9, 9), dtype=bool)
    m[2:7, 2:7] = False  # 5x5 hole
    out = morph_close(m, kernel=5)
    assert not out[4, 4]


def test_close_does_not_grow_isolated_blob():
    """Idempotency-style: closing a single 3x3 isolated blob leaves it
    at the same outer extent (close = dilate then erode, both with same SE).
    """
    m = np.zeros((7, 7), dtype=bool)
    m[2:5, 2:5] = True
    out = morph_close(m, kernel=3)
    expected = m.copy()
    np.testing.assert_array_equal(out, expected)


def test_close_idempotent():
    """Applying close twice yields the same result as applying it once."""
    rng = np.random.default_rng(seed=42)
    m = rng.random((20, 20)) > 0.3  # ~70% foreground
    once  = morph_close(m, kernel=3)
    twice = morph_close(once, kernel=3)
    np.testing.assert_array_equal(once, twice)


def test_close_kernel_value_validation():
    m = np.zeros((4, 4), dtype=bool)
    with pytest.raises(ValueError, match="kernel must be 3 or 5"):
        morph_close(m, kernel=4)
    with pytest.raises(ValueError, match="kernel must be 3 or 5"):
        morph_close(m, kernel=7)


def test_close_dtype_check():
    m = np.zeros((4, 4), dtype=np.uint8)
    with pytest.raises(TypeError):
        morph_close(m, kernel=3)
```

- [ ] **Step 2: Run the test to verify it fails.**

```bash
source .venv/bin/activate && PYTHONPATH=py python -m pytest py/tests/test_morph_close.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'models.ops.morph_close'`.

- [ ] **Step 3: Implement `morph_close`.**

Create `py/models/ops/morph_close.py`:

```python
"""3x3 / 5x5 morphological closing (dilate then erode) with edge replication.

Mirrors the future axis_morph_clean RTL close stage: dilation by a square
structuring element followed by erosion by the same SE, EDGE_REPLICATE
border policy at all four borders (scipy mode='nearest').
"""

import numpy as np
from scipy.ndimage import grey_dilation, grey_erosion


def morph_close(mask: np.ndarray, *, kernel: int) -> np.ndarray:
    """Apply a square morphological closing to a 2D boolean mask.

    Args:
        mask: (H, W) boolean array. True = foreground.
        kernel: 3 or 5. The structuring element is a kernel x kernel square.

    Returns:
        (H, W) boolean array — mask after dilation then erosion.
    """
    if kernel not in (3, 5):
        raise ValueError(f"kernel must be 3 or 5, got {kernel}")
    if mask.dtype != bool:
        raise TypeError(f"morph_close expects bool mask, got {mask.dtype}")
    u8 = mask.astype(np.uint8)
    dilated = grey_dilation(u8,      size=(kernel, kernel), mode='nearest')
    eroded  = grey_erosion (dilated, size=(kernel, kernel), mode='nearest')
    return eroded.astype(bool)
```

- [ ] **Step 4: Run the test to verify it passes.**

```bash
PYTHONPATH=py python -m pytest py/tests/test_morph_close.py -v
```

Expected: 8 passed.

- [ ] **Step 5: Commit.**

```bash
git add py/models/ops/morph_close.py py/tests/test_morph_close.py
git commit -m "py(models): add morph_close op (3x3 / 5x5)

scipy grey_dilation -> grey_erosion with mode='nearest' to match the
future axis_morph_clean RTL EDGE_REPLICATE policy. kernel ∈ {3, 5}
(7+ rejected with ValueError). Tests cover hole-filling thresholds,
no-grow on isolated blobs, idempotency, and input validation."
```

---

## Task 5: Wire `morph_close` through motion + ccl_bbox models

**Files:**
- Modify: `py/models/motion.py` — `run()` accepts `morph_open_en`, `morph_close_en`, `morph_close_kernel`
- Modify: `py/models/ccl_bbox.py` — same

The motion + ccl_bbox models currently call `morph_open(raw_mask)` if `morph_en=True`. After this task they apply open then close based on the two independent gates.

- [ ] **Step 1: Update `motion.py` imports.**

In `py/models/motion.py`, find:

```python
from models.ops.morph_open import morph_open
```

Replace with:

```python
from models.ops.morph_open  import morph_open
from models.ops.morph_close import morph_close
```

- [ ] **Step 2: Update the `run()` signature in `motion.py`.**

Replace:

```python
def run(frames, motion_thresh=16, alpha_shift=3, alpha_shift_slow=6, grace_frames=0,
        grace_alpha_shift=1, gauss_en=True, morph_en=True, **kwargs):
```

with:

```python
def run(frames, motion_thresh=16, alpha_shift=3, alpha_shift_slow=6, grace_frames=0,
        grace_alpha_shift=1, gauss_en=True,
        morph_open_en=True, morph_close_en=True, morph_close_kernel=3,
        **kwargs):
```

- [ ] **Step 3: Update the docstring** to describe the new fields.

In the same docstring, replace the `morph_en` line with:

```
    morph_open_en (default True): apply 3x3 morphological opening to the mask
    before CCL.
    morph_close_en (default True): apply morphological closing (dilate then
    erode) after the open, with kernel size controlled by morph_close_kernel.
    morph_close_kernel (default 3): 3 or 5. Kernel side length for the close.
    Both operations run on the post-mask path; the EMA still consumes the
    raw (pre-morph) mask to match the RTL datapath (axis_motion_detect drives
    EMA; axis_morph_clean runs downstream on its way to CCL).
```

- [ ] **Step 4: Update the morph application site in `motion.py`.**

Find:

```python
            clean_mask = morph_open(raw_mask) if morph_en else raw_mask
```

Replace with:

```python
            clean_mask = raw_mask
            if morph_open_en:
                clean_mask = morph_open(clean_mask)
            if morph_close_en:
                clean_mask = morph_close(clean_mask, kernel=morph_close_kernel)
```

- [ ] **Step 5: Apply the same four edits to `py/models/ccl_bbox.py`.**

Same imports, same signature change, same docstring update, same morph application change. The structure is identical.

- [ ] **Step 6: Run the full Python suite.**

```bash
PYTHONPATH=py python -m pytest py/tests/ -q --ignore=py/tests/test_vga.py
```

Expected: all green. Existing tests (which pass `morph_en=True` as a kwarg) still work because `**kwargs` swallows the unused field; new defaults match the previous behaviour for the open path and add the close.

- [ ] **Step 7: Commit.**

```bash
git add py/models/motion.py py/models/ccl_bbox.py
git commit -m "py(models): thread morph_open_en + morph_close_en/kernel through

motion.run() and ccl_bbox.run() now accept three independent fields
controlling the mask cleanup: morph_open_en, morph_close_en, and
morph_close_kernel. Open is applied if open_en=True; close is applied
after the open if close_en=True, using the requested kernel size.
The EMA still consumes the raw (pre-morph) mask. Existing tests pass
unchanged."
```

---

## Task 6: RTL — `axis_morph_clean.sv`

**Files:**
- Create: `hw/ip/filters/rtl/axis_morph_clean.sv`
- Modify: `hw/ip/filters/filters.core` — register the new file

This is the new module. It instantiates the existing `axis_morph3x3_erode` / `axis_morph3x3_dilate` primitives in a `generate` block.

- [ ] **Step 1: Invoke the `rtl-writing` skill.** It enforces project SV conventions.

- [ ] **Step 2: Write `axis_morph_clean.sv`.**

Create `hw/ip/filters/rtl/axis_morph_clean.sv`:

```sv
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_morph_clean — combined 3x3 open + parametrizable 3x3/5x5 close.
//
// Pipeline: erode -> dilate -> [dilate * N] -> [erode * N]
//                   ^^^ open ^^^   ^^^^^^^ close (kernel = 2N+1) ^^^^^^^
//
// N = (CLOSE_KERNEL - 1) / 2:
//   CLOSE_KERNEL=3 -> N=1 -> 1 dilate + 1 erode = 3x3 close
//   CLOSE_KERNEL=5 -> N=2 -> 2 dilates + 2 erodes = 5x5 close
// (Minkowski composition: 3x3 ⊕ 3x3 = 5x5.)
//
// Each sub-stage's enable_i:
//   morph_open_en_i  -> u_open_erode, u_open_dilate
//   morph_close_en_i -> all close-stage erodes and dilates
//
// When a stage's enable_i = 0, the existing axis_morph3x3_{erode,dilate}
// primitive forwards its input combinatorially with zero added latency
// and the line buffers are ignored (deterministic skid passthrough).
//
// Latency: (2 + 2*N) * (H_ACTIVE + 3) cycles when both gates are enabled.

module axis_morph_clean #(
    parameter int H_ACTIVE     = 320,
    parameter int V_ACTIVE     = 240,
    parameter int CLOSE_KERNEL = 3
) (
    input  logic clk_i,
    input  logic rst_n_i,

    input  logic morph_open_en_i,
    input  logic morph_close_en_i,

    axis_if.rx s_axis,
    axis_if.tx m_axis
);

    initial begin
        assert (CLOSE_KERNEL == 3 || CLOSE_KERNEL == 5)
            else $error("axis_morph_clean: CLOSE_KERNEL must be 3 or 5, got %0d",
                        CLOSE_KERNEL);
    end

    localparam int N = (CLOSE_KERNEL - 1) / 2;
    // Total sub-stages: 2 (open: erode + dilate) + 2*N (close: N dilates + N erodes)
    localparam int N_STAGES = 2 + 2 * N;

    // Internal interfaces between sub-stages. Index 0 = output of stage 0,
    // index N_STAGES-1 = output of last stage = m_axis.
    axis_if #(.DATA_W(1), .USER_W(1)) inter [N_STAGES] ();

    // ---- Open stage 1: erode ----------------------------------------
    axis_morph3x3_erode #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_open_erode (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .enable_i (morph_open_en_i),
        .s_axis   (s_axis),
        .m_axis   (inter[0])
    );

    // ---- Open stage 2: dilate ---------------------------------------
    axis_morph3x3_dilate #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_open_dilate (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .enable_i (morph_open_en_i),
        .s_axis   (inter[0]),
        .m_axis   (inter[1])
    );

    // ---- Close stages: N dilates then N erodes ----------------------
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_close_dilate
            axis_morph3x3_dilate #(
                .H_ACTIVE (H_ACTIVE),
                .V_ACTIVE (V_ACTIVE)
            ) u_d (
                .clk_i    (clk_i),
                .rst_n_i  (rst_n_i),
                .enable_i (morph_close_en_i),
                .s_axis   (inter[1 + i]),
                .m_axis   (inter[2 + i])
            );
        end
        for (i = 0; i < N; i++) begin : g_close_erode
            axis_morph3x3_erode #(
                .H_ACTIVE (H_ACTIVE),
                .V_ACTIVE (V_ACTIVE)
            ) u_e (
                .clk_i    (clk_i),
                .rst_n_i  (rst_n_i),
                .enable_i (morph_close_en_i),
                .s_axis   (inter[1 + N + i]),
                .m_axis   (inter[2 + N + i])
            );
        end
    endgenerate

    // ---- Tail: connect last interface to m_axis ---------------------
    assign m_axis.tdata  = inter[N_STAGES - 1].tdata;
    assign m_axis.tvalid = inter[N_STAGES - 1].tvalid;
    assign m_axis.tlast  = inter[N_STAGES - 1].tlast;
    assign m_axis.tuser  = inter[N_STAGES - 1].tuser;
    assign inter[N_STAGES - 1].tready = m_axis.tready;

endmodule
```

- [ ] **Step 3: Register the file in `hw/ip/filters/filters.core`.**

Open `hw/ip/filters/filters.core` and find the `files:` list under the active target. Add `hw/ip/filters/rtl/axis_morph_clean.sv` to that list (alongside `axis_morph3x3_open.sv` etc.) — keep the old file registered for now; Task 9 deletes it.

- [ ] **Step 4: Lint.**

```bash
make lint
```

Expected: clean. Verilator should accept the `generate` block and the assertion.

- [ ] **Step 5: Commit.**

```bash
git add hw/ip/filters/rtl/axis_morph_clean.sv hw/ip/filters/filters.core
git commit -m "rtl: add axis_morph_clean (open + parametrizable close)

Combined 3x3 open + 3x3/5x5 close on a 1-bit motion mask AXIS stream.
Two runtime enables (morph_open_en_i, morph_close_en_i) and one compile-time kernel
size knob (CLOSE_KERNEL ∈ {3, 5}). Pure structural composition of the
existing axis_morph3x3_erode and axis_morph3x3_dilate primitives. 5x5
close is two cascaded 3x3 dilates + two cascaded 3x3 erodes (Minkowski
composition: 3x3 ⊕ 3x3 = 5x5). Each sub-stage's enable_i forwards from
its corresponding gate, so disabled stages are deterministic 1-cycle
skid passthrough.

Lint clean. Module is not yet instantiated at top level — that comes
in a later commit."
```

---

## Task 7: Unit testbench `tb_axis_morph_clean`

**Files:**
- Create: `hw/ip/filters/tb/tb_axis_morph_clean.sv`
- Modify: `dv/sim/Makefile` — add `test-ip-morph-clean` target

This single TB covers the `(open_en, close_en, CLOSE_KERNEL) ∈ {0,1} × {0,1} × {3,5}` matrix plus a backpressure scenario and a frame-counting SOF/EOF scenario.

- [ ] **Step 1: Invoke the `hardware-testing` skill.**

The skill enforces project TB conventions (drv_* pattern, Layer 2 rules, Makefile wiring).

- [ ] **Step 2: Read the existing `tb_axis_morph3x3_open.sv` for structural reference.**

The new TB follows the same skeleton: `H_ACTIVE`/`V_ACTIVE` localparams, drv_* signals, golden-frame array, beat-by-beat compare. Differences:

- Two enables instead of one.
- A second `localparam int CLOSE_KERNEL` per test variant — instantiate two DUTs (one per kernel) and run the same stimulus through both.
- Each test case must specify `(open_en, close_en)` and the expected golden output produced by the python-equivalent open/close composition.

- [ ] **Step 3: Write `tb_axis_morph_clean.sv`.**

The TB structure:

```sv
// Copyright 2026 Sebastian Prajinariu
// SPDX-License-Identifier: Apache-2.0

// Unit TB for axis_morph_clean — sweeps (open_en, close_en, CLOSE_KERNEL)
// across a curated set of input masks. Goldens are precomputed offline
// (see py/scripts/gen_morph_clean_goldens.py — emits SV constant arrays
// printed below).

module tb_axis_morph_clean;
    localparam int H_ACTIVE = 8;
    localparam int V_ACTIVE = 8;
    localparam int CLK_PERIOD_NS = 10;

    logic clk = 0;
    logic rst_n = 0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // Drive signals (set in initial blocks; wired into the AXIS interfaces
    // below via always_ff @(negedge clk) so DUT inputs are stable at posedge.)
    logic        drv_tvalid = 0;
    logic        drv_tdata  = 0;
    logic        drv_tlast  = 0;
    logic        drv_tuser  = 0;
    logic        drv_morph_open_en  = 0;
    logic        drv_morph_close_en = 0;

    // Two DUTs — one for each CLOSE_KERNEL value.
    axis_if #(.DATA_W(1), .USER_W(1)) s3 (), m3 ();
    axis_if #(.DATA_W(1), .USER_W(1)) s5 (), m5 ();

    always_ff @(negedge clk) begin
        s3.tvalid <= drv_tvalid;
        s3.tdata  <= drv_tdata;
        s3.tlast  <= drv_tlast;
        s3.tuser  <= drv_tuser;
        s5.tvalid <= drv_tvalid;
        s5.tdata  <= drv_tdata;
        s5.tlast  <= drv_tlast;
        s5.tuser  <= drv_tuser;
    end

    axis_morph_clean #(.H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .CLOSE_KERNEL(3))
        u_dut_3 (
            .clk_i(clk), .rst_n_i(rst_n),
            .morph_open_en_i(drv_morph_open_en), .morph_close_en_i(drv_morph_close_en),
            .s_axis(s3), .m_axis(m3)
        );

    axis_morph_clean #(.H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .CLOSE_KERNEL(5))
        u_dut_5 (
            .clk_i(clk), .rst_n_i(rst_n),
            .morph_open_en_i(drv_morph_open_en), .morph_close_en_i(drv_morph_close_en),
            .s_axis(s5), .m_axis(m5)
        );

    // Both DUTs always ready downstream (no backpressure for the basic tests).
    assign m3.tready = 1'b1;
    assign m5.tready = 1'b1;

    // ---- Test stimuli (input masks) and per-(open_en, close_en, kernel)
    // golden outputs go here. See py/scripts/gen_morph_clean_goldens.py
    // for the script that emits these arrays.

    initial begin
        // Reset
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        run_test_passthrough(); // open_en=0, close_en=0
        run_test_open_only();   // open_en=1, close_en=0
        run_test_close_only();  // open_en=0, close_en=1
        run_test_open_close();  // open_en=1, close_en=1
        run_test_backpressure();
        run_test_sof_eof_framing();

        $display("ALL MORPH_CLEAN TESTS PASSED");
        $finish;
    end

    // task definitions for run_test_* go here; each drives a frame, captures
    // both DUT outputs, and compares against precomputed goldens.
endmodule
```

The goldens must be precomputed by a small offline Python helper. **Add this helper as part of the same task** (it is verification-only support — committed under `py/scripts/`):

Create `py/scripts/gen_morph_clean_goldens.py` that takes test input masks, applies `morph_open` then `morph_close` for each `(open_en, close_en, kernel)` combination, and prints the golden output as SV constant-array literals copy-pasted into the TB. (Reuse `py/models/ops/morph_open.py` and `py/models/ops/morph_close.py`.)

- [ ] **Step 4: Generate goldens.**

```bash
PYTHONPATH=py python py/scripts/gen_morph_clean_goldens.py > /tmp/goldens.sv
```

Paste the emitted constants into `tb_axis_morph_clean.sv` per the comments in Step 3.

- [ ] **Step 5: Add the Makefile target in `dv/sim/Makefile`.**

Find the existing `test-ip-morph-open` target and **add** (do not yet remove — Task 9 removes the old one):

```make
test-ip-morph-clean:
	$(MAKE) -C $(CURDIR) compile-tb TB=tb_axis_morph_clean \
	   RTL_SRCS="$(SHARED_RTL) hw/ip/filters/rtl/axis_morph_clean.sv \
	            hw/ip/filters/rtl/axis_morph3x3_erode.sv \
	            hw/ip/filters/rtl/axis_morph3x3_dilate.sv \
	            hw/ip/window/rtl/axis_window3x3.sv"
	$(VOBJ_DIR_BASE)_tb_axis_morph_clean/Vtb_axis_morph_clean
```

(Mirror the `test-ip-morph-open` target's exact structure — copy + rename.)

Update the parent `Makefile`'s `test-ip` aggregate to include the new target (it should run alongside the existing per-block tests).

- [ ] **Step 6: Run the new TB.**

```bash
make test-ip-morph-clean
```

Expected: `ALL MORPH_CLEAN TESTS PASSED`.

- [ ] **Step 7: Commit.**

```bash
git add hw/ip/filters/tb/tb_axis_morph_clean.sv \
        py/scripts/gen_morph_clean_goldens.py \
        dv/sim/Makefile Makefile
git commit -m "tb: add tb_axis_morph_clean unit testbench

Sweeps (open_en, close_en, CLOSE_KERNEL) ∈ {0,1} × {0,1} × {3,5} on a
curated set of small mask frames. Goldens are precomputed offline via
py/scripts/gen_morph_clean_goldens.py (uses py/models/ops/morph_open
and morph_close for byte-equivalent reference).

Includes backpressure (m_axis.tready stalls mid-frame) and SOF/EOF
framing (n frames in -> n frames out) scenarios.

New 'make test-ip-morph-clean' target. The legacy
'make test-ip-morph-open' target is still present and is removed in
a later commit."
```

---

## Task 8: Top-level integration

**Files:**
- Modify: `hw/top/sparevideo_top.sv` — replace `u_morph_open` with `u_morph_clean`

After this task, the top references the new module. The old `axis_morph3x3_open.sv` is still on disk (still registered in the core file) but no longer instantiated.

- [ ] **Step 1: Invoke the `rtl-writing` skill.**

- [ ] **Step 2: Replace the `axis_morph3x3_open` instantiation.**

In `hw/top/sparevideo_top.sv`, find the `u_morph_open` instantiation (look for `axis_morph3x3_open #(`):

```sv
    axis_morph3x3_open #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_morph_open (
        .clk_i    (clk_dsp_i),
        .rst_n_i  (rst_dsp_n_i),
        .enable_i (CFG.morph_open_en),
        .s_axis   (motion_to_morph),
        .m_axis   (morph_to_ccl)
    );
```

Replace with:

```sv
    axis_morph_clean #(
        .H_ACTIVE     (H_ACTIVE),
        .V_ACTIVE     (V_ACTIVE),
        .CLOSE_KERNEL (CFG.morph_close_kernel)
    ) u_morph_clean (
        .clk_i      (clk_dsp_i),
        .rst_n_i    (rst_dsp_n_i),
        .morph_open_en_i  (CFG.morph_open_en),
        .morph_close_en_i (CFG.morph_close_en),
        .s_axis     (motion_to_morph),
        .m_axis     (morph_to_ccl)
    );
```

- [ ] **Step 3: Lint.**

```bash
make lint
```

Expected: clean.

- [ ] **Step 4: Run the integration verification matrix at TOLERANCE=0.**

Run the four CTRL_FLOW × all CFG combinations on the synthetic `multi_speed` source. The expected outcome is **PASS at TOLERANCE=0** for every combination — model and RTL agree because `py/models/{motion,ccl_bbox}.py` were already updated to apply the close in Task 5.

```bash
for cfg in default no_morph no_gauss no_ema no_gamma_cor no_scaler no_hud default_hflip; do
  for cflow in passthrough motion mask ccl_bbox; do
    echo "=== $cflow / $cfg ==="
    make run-pipeline SOURCE=synthetic:multi_speed CTRL_FLOW=$cflow CFG=$cfg \
        WIDTH=320 HEIGHT=240 FRAMES=4 MODE=binary 2>&1 \
        | grep -E "PASS|FAIL|Error" | tail -5
  done
done
```

Expected: every combination ends in `PASS: 4 frames verified`.

- [ ] **Step 5: Run the per-block IP TBs.**

```bash
make test-ip
```

Expected: all green, including the new `test-ip-morph-clean` and the still-present `test-ip-morph-open` (which is exercising the old module, soon to be deleted).

- [ ] **Step 6: Commit.**

```bash
git add hw/top/sparevideo_top.sv
git commit -m "top: switch motion mask path to axis_morph_clean

Replaces u_morph_open (axis_morph3x3_open) with u_morph_clean
(axis_morph_clean). The new module exposes two independent runtime
enables (morph_open_en_i, morph_close_en_i) and a compile-time CLOSE_KERNEL knob
driven from CFG.morph_close_kernel.

Default profiles enable both stages with kernel=3. CFG_NO_MORPH gates
both off. All CTRL_FLOW × CFG combinations pass at TOLERANCE=0 against
the updated Python reference model."
```

---

## Task 9: Delete old `axis_morph3x3_open` files

**Files:**
- Delete: `hw/ip/filters/rtl/axis_morph3x3_open.sv`
- Delete: `hw/ip/filters/tb/tb_axis_morph3x3_open.sv`
- Delete: `docs/specs/axis_morph3x3_open-arch.md`
- Modify: `hw/ip/filters/filters.core` — deregister the old RTL file
- Modify: `dv/sim/Makefile` — remove `test-ip-morph-open` target
- Modify: `Makefile` (top) — remove `test-ip-morph-open` help line

The old module is now unused. Remove it.

- [ ] **Step 1: Delete the source files.**

```bash
git rm hw/ip/filters/rtl/axis_morph3x3_open.sv \
       hw/ip/filters/tb/tb_axis_morph3x3_open.sv \
       docs/specs/axis_morph3x3_open-arch.md
```

- [ ] **Step 2: Deregister from `hw/ip/filters/filters.core`.**

Open `hw/ip/filters/filters.core` and remove the line referencing `axis_morph3x3_open.sv`. Leave `axis_morph3x3_erode.sv` and `axis_morph3x3_dilate.sv` registered — they're still building blocks.

- [ ] **Step 3: Remove the old `test-ip-morph-open` target from `dv/sim/Makefile`.**

Delete the make target block. (The new `test-ip-morph-clean` target stays.)

- [ ] **Step 4: Remove the help line from the top `Makefile`.**

Find:

```
	@echo "    test-ip-morph-open         axis_morph3x3_open: ..."
```

Replace with:

```
	@echo "    test-ip-morph-clean        axis_morph_clean: open + parametrizable close, full enable matrix"
```

- [ ] **Step 5: Lint + tests.**

```bash
make lint && make test-ip
```

Expected: clean lint, all per-block tests still pass (the old TB target no longer exists; the new one runs in its place).

- [ ] **Step 6: Commit.**

```bash
git add hw/ip/filters/filters.core dv/sim/Makefile Makefile
git commit -m "rtl: delete axis_morph3x3_open (subsumed by axis_morph_clean)

The combined open+close logic now lives in axis_morph_clean. The old
single-stage module, its unit TB, and its arch spec are no longer
referenced by any consumer. test-ip-morph-open target replaced by
test-ip-morph-clean."
```

---

## Task 10: Documentation updates

**Files:**
- Modify: `docs/specs/sparevideo-top-arch.md` — pipeline block name + line-buffer count
- Modify: `CLAUDE.md` — `hw/ip/filters/rtl/` description
- Modify: `README.md` — module status table

- [ ] **Step 1: Invoke the `hardware-arch-doc` skill.** It enforces top-spec scope rules.

- [ ] **Step 2: Update `docs/specs/sparevideo-top-arch.md`.**

In §5 (Internal architecture), replace any references to `axis_morph3x3_open` / `u_morph_open` with `axis_morph_clean` / `u_morph_clean`. Update the line-buffer summary if it appears anywhere — total line buffers in the mask cleanup stage went from 4 (open only) to 8 (open + 3×3 close).

Update §10 v-blank budget if it referenced morph stages by name.

- [ ] **Step 3: Update `CLAUDE.md`.**

Find the line describing `hw/ip/filters/rtl/`:

```
- `hw/ip/filters/rtl/` — Spatial filters over axis_window3x3 (axis_gauss3x3, axis_morph3x3_erode, axis_morph3x3_dilate, axis_morph3x3_open; future: axis_sobel — all land here as peer `.sv` files under one `filters.core`)
```

Replace with:

```
- `hw/ip/filters/rtl/` — Spatial filters over axis_window3x3 (axis_gauss3x3, axis_morph3x3_erode, axis_morph3x3_dilate, axis_morph_clean; future: axis_sobel — all land here as peer `.sv` files under one `filters.core`). axis_morph_clean is the combined open + parametrizable close mask cleanup block; see docs/specs/axis_morph_clean-arch.md.
```

Also update the "tuning knob" guidance section if it lists individual cfg fields (e.g., add `morph_close_en` and `morph_close_kernel` to the example list).

- [ ] **Step 4: Update `README.md`.**

In the module status table, replace:

```
| [`axis_morph3x3_open-arch.md`](docs/specs/axis_morph3x3_open-arch.md) | 3x3 morphological opening on mask (erode → dilate) |
```

with:

```
| [`axis_morph_clean-arch.md`](docs/specs/axis_morph_clean-arch.md) | 3x3 morphological opening + parametrizable 3x3/5x5 closing on mask; runtime gates `morph_open_en` / `morph_close_en`; compile-time `morph_close_kernel` |
```

Also update the `CFG=` profile examples in the Usage section: the `no_morph` profile description should now read "3x3 mask opening AND closing bypassed."

- [ ] **Step 5: Run lint + tests once more.**

```bash
make lint && make test-py && make test-ip
```

Expected: all green.

- [ ] **Step 6: Commit.**

```bash
git add docs/specs/sparevideo-top-arch.md CLAUDE.md README.md
git commit -m "docs: update top spec, CLAUDE.md, README for axis_morph_clean

Replaces references to axis_morph3x3_open with axis_morph_clean.
sparevideo-top-arch.md updated for the new line-buffer count in the
mask cleanup stage. CLAUDE.md filters block list now mentions the
combined module. README module table links the new arch spec."
```

---

## Task 11: Squash + final verification

**Files:** None (purely git operations).

Per [CLAUDE.md](../../CLAUDE.md): "Once a plan is fully implemented and its tests pass, squash all of the plan's commits into a single commit before opening the PR."

- [ ] **Step 1: Verify commit history is plan-scoped.**

```bash
git log --oneline origin/main..HEAD
```

Expected: 9-10 commits (one per task above), all clearly part of this plan. If you see drive-by changes (typos, unrelated fixes), `git rebase -i` to move them out — see CLAUDE.md "Squash at plan completion" rules. README/CLAUDE.md updates are exempt; small typo fixes are exempt.

- [ ] **Step 2: Squash to one commit.**

Use the project's standard squash flow:

```bash
git reset --soft origin/main
git commit -m "feat(filters): replace axis_morph3x3_open with axis_morph_clean

Combined open + parametrizable 3x3/5x5 close mask cleanup block.
Two runtime gates (morph_open_en, morph_close_en) and one compile-time
kernel-size knob (morph_close_kernel) drive the block. 5x5 close is
built from existing 3x3 primitives via Minkowski composition; no new
window/erode/dilate primitives are added.

Motivation: bbox fragmentation observed on the README real-video demo.
Single moving objects split into multiple bboxes because of small
intra-object gaps in the motion mask. A 3x3 close after the existing
3x3 open is the textbook recipe (Soille §8.2, Gonzalez & Woods Ch. 9)
and substantially reduces fragmentation; 5x5 close reduces it further
at the cost of higher inter-object merge risk (kernel=5 bridges 2-px
gaps), so default morph_close_kernel=3.

cfg_t fields:
- morph_en renamed to morph_open_en (gates the open stage)
- morph_close_en added (gates the close stage)
- morph_close_kernel added (3 or 5; compile-time per profile)

Default profiles enable both stages with kernel=3; CFG_NO_MORPH gates
both off. All CTRL_FLOW × CFG combinations pass at TOLERANCE=0.

Replaces:
- hw/ip/filters/rtl/axis_morph3x3_open.sv
- hw/ip/filters/tb/tb_axis_morph3x3_open.sv
- docs/specs/axis_morph3x3_open-arch.md

Adds:
- hw/ip/filters/rtl/axis_morph_clean.sv
- hw/ip/filters/tb/tb_axis_morph_clean.sv
- docs/specs/axis_morph_clean-arch.md
- py/models/ops/morph_close.py
- py/tests/test_morph_close.py
- py/scripts/gen_morph_clean_goldens.py"
```

- [ ] **Step 3: Push + open PR.**

```bash
git push -u origin feat/axis-morph-clean
gh pr create --base main --head feat/axis-morph-clean \
    --title "feat(filters): axis_morph_clean (open + parametrizable close)" \
    --body "$(cat <<'EOF'
## Summary

Replaces `axis_morph3x3_open` with a single combined `axis_morph_clean` block in the motion mask path. Adds a parametrizable close stage (3×3 or 5×5) after the existing 3×3 open. Two runtime gates (`morph_open_en`, `morph_close_en`) and one compile-time kernel-size knob (`morph_close_kernel`) drive the block.

The 5×5 close is built from cascaded 3×3 primitives via Minkowski composition — no new `axis_window5x5` primitive is introduced.

## Test plan

- [x] `make lint` clean
- [x] `make test-py` — 8 new morph_close tests + all existing tests pass
- [x] `make test-ip` — all per-block IP testbenches pass, including new `test-ip-morph-clean`
- [x] Full CTRL_FLOW × CFG matrix at TOLERANCE=0
- [x] Demo regen confirms reduced bbox fragmentation on the real-video clip

## Notes

- Default profile values: `morph_open_en=1`, `morph_close_en=1`, `morph_close_kernel=3`. `CFG_NO_MORPH` gates both stages off.
- Reference: `docs/plans/2026-05-01-axis-morph-clean-design.md` (design doc, brainstorming output).
EOF
)"
```

- [ ] **Step 4: Move the design + plan docs to `docs/plans/old/`.**

Per CLAUDE.md "TODO after each major change":

```bash
mkdir -p docs/plans/old
git mv docs/plans/2026-05-01-axis-morph-clean-design.md \
       docs/plans/old/2026-05-01-axis-morph-clean-design.md
git mv docs/plans/2026-05-01-axis-morph-clean-plan.md \
       docs/plans/old/2026-05-01-axis-morph-clean-plan.md
```

This step is performed after the plan is fully implemented. If the plan reaches PR review and is requested to be revised, leave the docs in place; only archive after merge.

- [ ] **Step 5: Optional — regenerate the demo.**

If [feat/demo-refinement (PR #30)](https://github.com/sprajinariu/sparevideo/pull/30) has merged before this branch lands, regenerate `media/demo/{synthetic,real}.webp` to reflect the visual improvement on the real-video clip:

```bash
make demo
# Inspect media/demo-draft/{synthetic,real}.webp.
make demo-publish
git add media/demo/
git commit -m "demo: regenerate WebPs with axis_morph_clean enabled"
```

This is *optional* and *follow-up*; don't block the morph_clean PR on it. The first time the published WebPs reflect the morph_close behaviour can be a separate small PR or a follow-up commit on `feat/demo-refinement`.

---

## Open Decisions Resolved (from design §10)

The design doc deferred four decisions to the plan. Resolutions:

1. **Python ops layout:** **New file** `py/models/ops/morph_close.py` peer to `morph_open.py`. Cleaner one-op-per-file convention, minimal churn to existing imports.
2. **TB harness style:** Match `tb_axis_morph3x3_open.sv`'s structure (drv_* pattern, negedge-clocked DUT input drive, posedge-clocked output capture). Goldens precomputed offline by `py/scripts/gen_morph_clean_goldens.py`. The `tb_axis_scale2x.sv` newer pattern is not used here — consistency with the filters/tb/ neighbours wins.
3. **Arch spec scope:** Single `docs/specs/axis_morph_clean-arch.md`. Old `axis_morph3x3_open-arch.md` deleted in Task 9.
4. **Demo regeneration:** Done as a *follow-up* commit (Task 11 Step 5), not part of this PR. The morph_clean PR stands on its own.

---

## Self-Review Checklist

- ✅ Spec coverage: every section of the design doc maps to a task — §4 architecture → Tasks 6–8; §5 knobs → Task 2/3; §6 top integration → Task 8; §7 Python models → Tasks 4/5; §8 files → Tasks 1, 6–10; §9 test strategy → Tasks 4/7/8.
- ✅ No placeholders: every code block above is the actual content to paste; no "TBD" / "TODO" / "implement later".
- ✅ Type consistency: `morph_open_en` / `morph_close_en` / `morph_close_kernel` used consistently across SV, Python, and tests. The `CLOSE_KERNEL` parameter on the SV module matches the cfg field `morph_close_kernel` (project convention: cfg fields are snake_case, RTL parameters are SCREAMING_SNAKE_CASE).
- ✅ Test plan: each new piece of code is exercised — `morph_close` op has its own pytest file (Task 4); the SV module has its own unit TB (Task 7); the Python integration is covered by the existing motion / ccl_bbox model tests + the integration matrix in Task 8.
- ✅ Reversibility: Task 9 (deletion of old files) happens *after* Task 8 (which proves the new module works in the integration matrix). If the new module fails integration, Task 9 doesn't run — the old module is still on disk.
