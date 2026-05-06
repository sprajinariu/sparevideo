# ViBe Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the validated ViBe Python reference out of `py/experiments/` into `py/models/`, add a `bg_model` selector + the ViBe knobs (including the look-ahead-median init promoted from the Phase-0-adjacent experiment) to `cfg_t`, and wire `run_model()` dispatch so any control flow can be run with `bg_model=BG_MODEL_VIBE`. RTL stays EMA-only this phase (the new fields are recognised by the SV package and exposed to runtime, but `axis_motion_detect` ignores them); ViBe profiles are characterised end-to-end via the Python reference under `make sw-dry-run`.

**Architecture:** Move the `Xorshift32` PRNG and the `ViBe` class to `py/models/ops/{xorshift,vibe}.py`. Add three thin per-control-flow ViBe wrappers (`motion_vibe.py`, `mask_vibe.py`, `ccl_bbox_vibe.py`) that share a single `_produce_masks_vibe(...)` helper, leaving the existing EMA models untouched. `run_model()` reads `bg_model` from kwargs and routes to the EMA or ViBe model registry. `cfg_t` grows by 11 fields (one selector + 10 ViBe knobs); the parity test enforces SV/Python lockstep. Existing EMA profiles set `bg_model = BG_MODEL_EMA = 0` with default ViBe field values that are never consumed — they exist solely so the struct size and parity tests are stable.

**Tech Stack:** Python 3.12 (NumPy, pytest in `.venv`); SystemVerilog package edits only — no new RTL behavior. Verilator lint must stay clean because every CFG_DEFAULT_* localparam grows.

**Branch:** `feat/vibe-phase-1`, branched fresh from `origin/main` (per CLAUDE.md "one branch per plan"). The Phase-0 + look-ahead-init work is already on `origin/main` (commits `e185104`, `2428c42`); this branch has no unmerged predecessors.

**Companion design doc:** [`2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md) §9 Phase 1 row.
**Companion results docs:** [`2026-05-04-vibe-phase-0-results.md`](2026-05-04-vibe-phase-0-results.md), [`2026-05-05-vibe-lookahead-init-results.md`](2026-05-05-vibe-lookahead-init-results.md).

---

## File Structure

**Created:**
- `py/models/ops/xorshift.py` — Xorshift32 PRNG (moved from `py/experiments/xorshift.py`)
- `py/models/ops/vibe.py` — `ViBe` class (moved from `py/experiments/motion_vibe.py`)
- `py/models/_vibe_mask.py` — private helper: `produce_masks_vibe(frames_rgb, cfg) -> list[bool array]`. Single source of truth for ViBe mask production used by all three vibe ctrl-flow models.
- `py/models/motion_vibe.py` — `run()` for `ctrl_flow=motion` with ViBe bg subtraction
- `py/models/mask_vibe.py` — `run()` for `ctrl_flow=mask` with ViBe bg subtraction
- `py/models/ccl_bbox_vibe.py` — `run()` for `ctrl_flow=ccl_bbox` with ViBe bg subtraction
- `py/tests/test_motion_vibe_model.py` — smoke test that `motion_vibe.run` produces the right output shape and a non-trivial bbox on a synthetic moving-box source

**Modified:**
- `hw/top/sparevideo_pkg.sv` — add `bg_model` + 10 ViBe fields to `cfg_t`; add `BG_MODEL_*`, `VIBE_INIT_*`, `BG_INIT_*` localparam constants; extend every existing `CFG_*` block with default ViBe values; add 5 new `CFG_VIBE_*` localparams.
- `py/profiles.py` — mirror the 11 new fields in `DEFAULT`; add 5 new `VIBE_*` dicts; extend `PROFILES` registry.
- `py/models/__init__.py` — `run_model()` reads `bg_model` and dispatches to the EMA or ViBe model registry. New `_MODELS_VIBE` table.
- `py/models/bbox_counts.py` — branch on `bg_model` to call ViBe mask production (so the HUD bbox count is correct under ViBe profiles).
- `py/tests/test_profiles.py` — extend `EXPECTED_PROFILES` with the 5 new entries.
- `py/tests/test_xorshift.py` — update import path: `experiments.xorshift` → `models.ops.xorshift`.
- `py/tests/test_motion_vibe.py` — update import path: `experiments.motion_vibe` → `models.ops.vibe`.
- `py/experiments/xorshift.py` — replace body with `from models.ops.xorshift import *` shim so `run_phase0.py` etc. keep working.
- `py/experiments/motion_vibe.py` — replace body with `from models.ops.vibe import *` shim.
- `CLAUDE.md` — Build Commands section gains the new `CFG=default_vibe` examples; "Pipeline Harness" gains a one-line note that `bg_model` is a profile-level switch and the ViBe profiles are Python-only at Phase 1.
- `README.md` — Profiles table gains the 5 new entries (or a short bg_model-selector note).

**Not touched:**
- Any `hw/ip/**/rtl/` file. RTL behavior is unchanged.
- `py/models/{passthrough,motion,mask,ccl_bbox,ccl,bbox_counts}.py` algorithm bodies — only `bbox_counts.py` gains a dispatch branch; the EMA path is byte-identical.
- `py/models/ops/{gamma_cor,hflip,scale2x,hud,morph_open,morph_close}.py`.
- `dv/`, `Makefile`, `dv/sim/Makefile`. The plusarg surface is unchanged because `bg_model` rides on `CFG_NAME`.

---

### Task 1: Branch off origin/main

**Files:** none yet.

- [ ] **Step 1: Fetch and branch**

```bash
git fetch origin
git checkout -b feat/vibe-phase-1 origin/main
git status
```

Expected: clean tree on a new branch tracking nothing yet, HEAD == `origin/main`.

- [ ] **Step 2: Verify Phase 0 + look-ahead-init are present on this base**

```bash
git log --oneline -5
ls py/experiments/motion_vibe.py py/experiments/xorshift.py py/tests/test_motion_vibe.py py/tests/test_xorshift.py
```

Expected: top of log shows `2428c42 feat(experiments/vibe): look-ahead median init experiment (#35)` and `e185104 feat(motion): ViBe Phase 0 ... (#34)`. All four files exist. If any are missing, STOP — the base branch is wrong.

- [ ] **Step 3: Sanity baseline — full test suite green on the fresh branch**

```bash
source .venv/bin/activate && pytest py/tests
```

Expected: all tests pass (≥184 from Phase 0 redo). Capture the pre-change pass count for comparison in Task 14.

---

### Task 2: Move `xorshift32` to `py/models/ops/xorshift.py`

**Files:**
- Create: `py/models/ops/xorshift.py`
- Modify: `py/experiments/xorshift.py` (becomes shim)
- Modify: `py/tests/test_xorshift.py:8` (import path)

- [ ] **Step 1: Create the new module**

Write `py/models/ops/xorshift.py` with body identical to the current `py/experiments/xorshift.py`:

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

- [ ] **Step 2: Replace `py/experiments/xorshift.py` with a shim**

Overwrite the file:

```python
"""Compatibility shim — Xorshift32 lives in py/models/ops/xorshift.py.

Kept so existing scripts under py/experiments/ (capture_upstream.py,
run_phase0.py, run_lookahead_init.py, motion_vibe.py legacy callers)
keep working without import-path churn. New code must import from
`models.ops.xorshift`.
"""
from models.ops.xorshift import xorshift32  # noqa: F401
```

- [ ] **Step 3: Update the test import**

In `py/tests/test_xorshift.py`, change line 8:

```python
from models.ops.xorshift import xorshift32
```

- [ ] **Step 4: Run the xorshift test**

```bash
source .venv/bin/activate && pytest py/tests/test_xorshift.py -v
```

Expected: PASS — golden 8-value sequence still matches because the function body is byte-identical.

- [ ] **Step 5: Run the full test suite to confirm no transitive breaks**

```bash
pytest py/tests
```

Expected: same pass count as Task 1 Step 3.

- [ ] **Step 6: Commit**

```bash
git add py/models/ops/xorshift.py py/experiments/xorshift.py py/tests/test_xorshift.py
git commit -m "refactor(models): promote xorshift32 to py/models/ops/

Phase 1 prep: PRNG now lives alongside the other reference-model
operators. py/experiments/xorshift.py is a shim for legacy callers."
```

---

### Task 3: Move the `ViBe` class to `py/models/ops/vibe.py`

**Files:**
- Create: `py/models/ops/vibe.py`
- Modify: `py/experiments/motion_vibe.py` (becomes shim)
- Modify: `py/tests/test_motion_vibe.py:6` (import path)

- [ ] **Step 1: Copy the class to its new home**

Copy the full body of `py/experiments/motion_vibe.py` (the `ViBe` class plus its docstring, imports, and helpers — currently lines 1–304) into `py/models/ops/vibe.py`. **One change:** the import on line 26 must read

```python
from models.ops.xorshift import xorshift32
```

instead of `from experiments.xorshift import xorshift32`. Update the module docstring's first line to:

```python
"""ViBe (Visual Background Extractor) — Python reference operator.
```

(rest of the docstring unchanged).

- [ ] **Step 2: Replace `py/experiments/motion_vibe.py` with a shim**

Overwrite the file:

```python
"""Compatibility shim — the ViBe class now lives in py/models/ops/vibe.py.

Kept so existing experiment scripts (run_phase0.py, run_lookahead_init.py,
run_lookahead_init_pipeline.py, capture_upstream.py) keep working. New code
must import `from models.ops.vibe import ViBe`.
"""
from models.ops.vibe import ViBe  # noqa: F401
```

- [ ] **Step 3: Update the test import**

In `py/tests/test_motion_vibe.py`, change line 6:

```python
from models.ops.vibe import ViBe
```

- [ ] **Step 4: Run the ViBe unit tests**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: ALL tests PASS (33 from the Phase-0 redo; class behavior unchanged).

- [ ] **Step 5: Smoke-run one experiment script to prove the shims work**

```bash
python -c "from experiments.motion_vibe import ViBe; from experiments.xorshift import xorshift32; v = ViBe(); print('shim OK')"
```

Expected: prints `shim OK` and exits 0.

- [ ] **Step 6: Run the full test suite**

```bash
pytest py/tests
```

Expected: same pass count as before.

- [ ] **Step 7: Commit**

```bash
git add py/models/ops/vibe.py py/experiments/motion_vibe.py py/tests/test_motion_vibe.py
git commit -m "refactor(models): promote ViBe class to py/models/ops/vibe.py

Phase 1 prep: ViBe is now a first-class reference operator.
py/experiments/motion_vibe.py is a shim for the experiment scripts."
```

---

### Task 4: Extend `cfg_t` with `bg_model` + 10 ViBe fields (SV side)

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv:85-100` (struct), `:106-...` (every CFG_* block)

We add the fields to the struct first, then to every existing `CFG_*` localparam with EMA defaults. The five new `CFG_VIBE_*` localparams come in Task 6. After this task, `make lint` should still pass (the struct grew; existing RTL doesn't care because `axis_motion_detect` ignores the new fields).

- [ ] **Step 1: Add localparam constants above the struct**

In `hw/top/sparevideo_pkg.sv`, immediately above the `typedef struct packed { ... } cfg_t;` block (around line 85), insert:

```systemverilog
    // ---------------------------------------------------------------
    // bg_model selector + ViBe enums.
    //
    // These are plain `int` values inside cfg_t (not enums) so the
    // py/profiles.py parity test (which parses literal SV decimals)
    // can compare bit-for-bit. Use the localparam names everywhere
    // EXCEPT inside the CFG_* assignments — there the literal must
    // appear so test_profiles.py can read it.
    // ---------------------------------------------------------------
    localparam int BG_MODEL_EMA  = 0;
    localparam int BG_MODEL_VIBE = 1;

    localparam int VIBE_INIT_NEIGHBOURHOOD = 0;  // scheme (a)
    localparam int VIBE_INIT_DEGENERATE    = 1;  // scheme (b)
    localparam int VIBE_INIT_NOISE         = 2;  // scheme (c) — upstream-canonical

    localparam int BG_INIT_FRAME0           = 0;
    localparam int BG_INIT_LOOKAHEAD_MEDIAN = 1;
```

- [ ] **Step 2: Add the 11 new fields to the `cfg_t` struct**

In the struct body (currently lines 86–99), append after `pixel_t bbox_color`:

```systemverilog
        // ---- bg_model selector (Phase 1: Python-only; RTL still EMA) ----
        int         bg_model;            // 0=EMA, 1=ViBe — see BG_MODEL_*
        // ---- ViBe knobs (consumed only when bg_model==BG_MODEL_VIBE) ----
        int         vibe_K;              // sample-bank depth per pixel
        int         vibe_R;              // match radius |x - sample_i| < R
        int         vibe_min_match;      // count<min_match ⇒ motion
        int         vibe_phi_update;     // self-update period (power of 2)
        int         vibe_phi_diffuse;    // diffusion period (power of 2; 0=off)
        int         vibe_init_scheme;    // 0/1/2 — see VIBE_INIT_*
        int         vibe_prng_seed;      // 32-bit non-zero Xorshift seed
        logic       vibe_coupled_rolls;  // 1=upstream-coupled rolls
        int         vibe_bg_init_mode;   // 0/1 — see BG_INIT_*
        int         vibe_bg_init_lookahead_n;  // N frames; 0 = sentinel "all"
```

- [ ] **Step 3: Extend every existing CFG_* localparam with EMA defaults**

For EACH of the existing 9 `CFG_*` blocks (`CFG_DEFAULT`, `CFG_DEFAULT_HFLIP`, `CFG_NO_EMA`, `CFG_NO_MORPH`, `CFG_NO_GAUSS`, `CFG_NO_GAMMA_COR`, `CFG_NO_SCALER`, `CFG_DEMO`, `CFG_NO_HUD`), append the same 11-line block before the closing `};`. Use literal numeric forms (no localparam-name substitution) so the parity-test parser works:

```systemverilog
        bg_model:                  0,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_init_scheme:          2,
        vibe_prng_seed:            32'hDEADBEEF,
        vibe_coupled_rolls:        1'b1,
        vibe_bg_init_mode:         1,
        vibe_bg_init_lookahead_n:  0
```

Make sure to put a comma at the end of the previous last line (`bbox_color: 24'h00_FF_00,` etc.) and no trailing comma after the new last line.

- [ ] **Step 4: Lint pass on the package**

```bash
make lint
```

Expected: clean. If a width warning trips on `vibe_prng_seed`, widen its declaration to `bit [31:0] vibe_prng_seed;` and re-lint.

- [ ] **Step 5: A no-op simulation pass to confirm RTL still elaborates**

```bash
make run-pipeline CTRL_FLOW=passthrough TOLERANCE=0
```

Expected: passes — the new struct fields don't affect any consumer because `axis_motion_detect` only reads the EMA fields.

- [ ] **Step 6: Commit**

```bash
git add hw/top/sparevideo_pkg.sv
git commit -m "feat(pkg): add bg_model + ViBe knobs to cfg_t (Phase 1, EMA defaults)

11 new fields (1 selector + 10 ViBe) on every existing CFG_* profile.
RTL ignores them this phase — bg_model=BG_MODEL_EMA on every existing
profile keeps RTL behavior byte-identical. Companion plan:
docs/plans/2026-05-06-vibe-phase-1-plan.md"
```

---

### Task 5: Mirror the new fields in `py/profiles.py`

**Files:**
- Modify: `py/profiles.py` (DEFAULT dict + every derived dict)

- [ ] **Step 1: Extend `DEFAULT` with the 11 new keys**

In `py/profiles.py`, add to the `DEFAULT` dict (after `bbox_color=...`):

```python
    # ---- bg_model selector (Phase 1: Python-only; RTL still EMA) ----
    bg_model=0,                       # BG_MODEL_EMA
    # ---- ViBe knobs (consumed only when bg_model==1) ----
    vibe_K=8,
    vibe_R=20,
    vibe_min_match=2,
    vibe_phi_update=16,
    vibe_phi_diffuse=16,
    vibe_init_scheme=2,               # VIBE_INIT_NOISE — upstream-canonical
    vibe_prng_seed=0xDEADBEEF,
    vibe_coupled_rolls=True,
    vibe_bg_init_mode=1,              # BG_INIT_LOOKAHEAD_MEDIAN
    vibe_bg_init_lookahead_n=0,       # 0 = sentinel "all available frames"
```

(The other 8 profiles inherit via `dict(DEFAULT, ...)`, so they automatically pick up these fields with the EMA-default values.)

- [ ] **Step 2: Run the profile parity test**

```bash
source .venv/bin/activate && pytest py/tests/test_profiles.py -v
```

Expected: ALL existing parametrized cases PASS (the 11 new fields show identical SV/Python values on every profile). `test_profile_set_is_complete` still passes — we haven't added new profile names yet.

If anything fails: re-check that every CFG_* block in sparevideo_pkg.sv from Task 4 Step 3 has all 11 fields with the SAME values in the SAME order.

- [ ] **Step 3: Run the full test suite**

```bash
pytest py/tests
```

Expected: same pass count as Task 1 baseline.

- [ ] **Step 4: Commit**

```bash
git add py/profiles.py
git commit -m "feat(profiles): mirror bg_model + ViBe fields in DEFAULT

Inheritance via dict(DEFAULT, ...) propagates EMA defaults to every
existing profile. Parity test green."
```

---

### Task 6: Add the 5 new VIBE profiles (SV + Python)

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv` (5 new `CFG_VIBE_*` blocks)
- Modify: `py/profiles.py` (5 new dicts + PROFILES registry)

- [ ] **Step 1: Add the 5 SV localparams**

In `hw/top/sparevideo_pkg.sv`, after `CFG_NO_HUD`, append:

```systemverilog
    // ===== ViBe profiles (Phase 1 — Python-only; RTL still EMA) =====
    // Same DEFAULT cleanup pipeline (gauss + morph_open + morph_close);
    // bg block is ViBe (8-sample bank, R=20) with look-ahead median init.
    localparam cfg_t CFG_DEFAULT_VIBE = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_init_scheme:         2,
        vibe_prng_seed:           32'hDEADBEEF,
        vibe_coupled_rolls:       1'b1,
        vibe_bg_init_mode:        1,
        vibe_bg_init_lookahead_n: 0
    };

    // ViBe at K=20 (literature-default sample diversity; ~2.5x the on-chip
    // RAM cost of K=8). Stress-tests the upper end of the memory budget
    // discussion in §10.1 of the design doc.
    localparam cfg_t CFG_VIBE_K20 = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   20,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_init_scheme:         2,
        vibe_prng_seed:           32'hDEADBEEF,
        vibe_coupled_rolls:       1'b1,
        vibe_bg_init_mode:        1,
        vibe_bg_init_lookahead_n: 0
    };

    // ViBe with diffusion disabled — negative-control ablation. Validates
    // that diffusion is the mechanism behind frame-0 ghost dissolution
    // (see design doc §8 step 4). Mask should retain the ghost.
    localparam cfg_t CFG_VIBE_NO_DIFFUSE = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         0,
        vibe_init_scheme:         2,
        vibe_prng_seed:           32'hDEADBEEF,
        vibe_coupled_rolls:       1'b0,
        vibe_bg_init_mode:        1,
        vibe_bg_init_lookahead_n: 0
    };

    // ViBe with the 3x3 Gaussian pre-filter bypassed — same role as
    // CFG_NO_GAUSS but for the ViBe pipeline. Useful for isolating the
    // pre-filter's contribution to mask quality under ViBe.
    localparam cfg_t CFG_VIBE_NO_GAUSS = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b0,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_init_scheme:         2,
        vibe_prng_seed:           32'hDEADBEEF,
        vibe_coupled_rolls:       1'b1,
        vibe_bg_init_mode:        1,
        vibe_bg_init_lookahead_n: 0
    };

    // ViBe with the legacy frame-0 init (no look-ahead median). Required
    // for A/B comparison against CFG_DEFAULT_VIBE so the look-ahead-init
    // contribution stays measurable after the new mode becomes default.
    localparam cfg_t CFG_VIBE_INIT_FRAME0 = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_init_scheme:         2,
        vibe_prng_seed:           32'hDEADBEEF,
        vibe_coupled_rolls:       1'b1,
        vibe_bg_init_mode:        0,
        vibe_bg_init_lookahead_n: 0
    };
```

- [ ] **Step 2: Add the 5 Python profile dicts**

In `py/profiles.py`, after the `NO_HUD` definition (around line 64), append:

```python
# === ViBe profiles (Phase 1: Python-only; RTL still EMA) ===

# Recommended ViBe default. Matches CFG_DEFAULT cleanup pipeline; bg block
# swaps EMA for ViBe (K=8, R=20) with look-ahead median init.
DEFAULT_VIBE: ProfileT = dict(
    DEFAULT,
    bg_model=1,
    vibe_K=8,
    vibe_R=20,
    vibe_min_match=2,
    vibe_phi_update=16,
    vibe_phi_diffuse=16,
    vibe_init_scheme=2,
    vibe_prng_seed=0xDEADBEEF,
    vibe_coupled_rolls=True,
    vibe_bg_init_mode=1,
    vibe_bg_init_lookahead_n=0,
)

# K=20 (literature-default; ~2.5x sample-bank RAM vs DEFAULT_VIBE).
VIBE_K20: ProfileT = dict(DEFAULT_VIBE, vibe_K=20)

# Negative-control: diffusion disabled. Validates diffusion is the frame-0
# ghost dissolution mechanism (design-doc §8 step 4).
VIBE_NO_DIFFUSE: ProfileT = dict(DEFAULT_VIBE, vibe_phi_diffuse=0,
                                  vibe_coupled_rolls=False)

# 3x3 Gaussian pre-filter bypassed under ViBe (peer of NO_GAUSS).
VIBE_NO_GAUSS: ProfileT = dict(DEFAULT_VIBE, gauss_en=False)

# Legacy frame-0 init (no look-ahead). A/B vs DEFAULT_VIBE.
VIBE_INIT_FRAME0: ProfileT = dict(DEFAULT_VIBE, vibe_bg_init_mode=0)
```

Then extend the `PROFILES` registry (around line 66):

```python
PROFILES: dict[str, ProfileT] = {
    "default":           DEFAULT,
    "default_hflip":     DEFAULT_HFLIP,
    "no_ema":            NO_EMA,
    "no_morph":          NO_MORPH,
    "no_gauss":          NO_GAUSS,
    "no_gamma_cor":      NO_GAMMA_COR,
    "no_scaler":         NO_SCALER,
    "demo":              DEMO,
    "no_hud":            NO_HUD,
    "default_vibe":      DEFAULT_VIBE,
    "vibe_k20":          VIBE_K20,
    "vibe_no_diffuse":   VIBE_NO_DIFFUSE,
    "vibe_no_gauss":     VIBE_NO_GAUSS,
    "vibe_init_frame0":  VIBE_INIT_FRAME0,
}
```

- [ ] **Step 3: Extend `EXPECTED_PROFILES` in the parity test**

In `py/tests/test_profiles.py:39`, replace the set literal:

```python
EXPECTED_PROFILES = {
    "default", "default_hflip", "no_ema", "no_morph", "no_gauss",
    "no_gamma_cor", "no_scaler", "demo", "no_hud",
    "default_vibe", "vibe_k20", "vibe_no_diffuse", "vibe_no_gauss",
    "vibe_init_frame0",
}
```

- [ ] **Step 4: Lint and run the parity test**

```bash
make lint
pytest py/tests/test_profiles.py -v
```

Expected: lint clean; parametrized parity passes for all 14 profiles (9 EMA + 5 ViBe).

If any new profile fails parity: diff the SV block vs the Python dict field-by-field. Most likely cause is a typo in one of the 11 new field values.

- [ ] **Step 5: Commit**

```bash
git add hw/top/sparevideo_pkg.sv py/profiles.py py/tests/test_profiles.py
git commit -m "feat(profiles): add 5 ViBe profiles (default_vibe + 4 ablations)

Profiles: default_vibe (recommended), vibe_k20 (sample diversity),
vibe_no_diffuse (negative control), vibe_no_gauss (peer of no_gauss),
vibe_init_frame0 (A/B vs look-ahead init). RTL still EMA-only — these
are characterised end-to-end via the Python reference at this phase."
```

---

### Task 7: Build `_vibe_mask.py` — shared ViBe mask producer

**Files:**
- Create: `py/models/_vibe_mask.py`

This is the single source of truth for "given a list of RGB frames + a cfg dict, produce per-frame motion masks via ViBe." All three vibe ctrl-flow models (Tasks 8–10) call it.

- [ ] **Step 1: Write the helper**

Create `py/models/_vibe_mask.py`:

```python
"""Private helper — produce per-frame motion masks via the ViBe operator.

Single source of truth used by motion_vibe / mask_vibe / ccl_bbox_vibe.
Mirrors the structure of motion.compute_motion_masks (which uses EMA),
swapping the bg block for a `models.ops.vibe.ViBe` instance.

Frame-0 priming convention matches the EMA path: the first output mask is
all-zero (the ViBe bank is being initialised, no motion can be reported).
For lookahead-median init, the bank is seeded from the median of N frames
of the input clip (or all frames when N=0), so frame 0 already has a
realistic bg estimate — the all-zero priming convention is a deliberate
match-the-EMA-path choice, NOT a ViBe limitation.
"""
from __future__ import annotations

import numpy as np

from models.motion import _gauss3x3, _rgb_to_y
from models.ops.vibe import ViBe


def produce_masks_vibe(
    frames: list[np.ndarray],
    *,
    vibe_K: int,
    vibe_R: int,
    vibe_min_match: int,
    vibe_phi_update: int,
    vibe_phi_diffuse: int,
    vibe_init_scheme: int,
    vibe_prng_seed: int,
    vibe_coupled_rolls: bool,
    vibe_bg_init_mode: int,
    vibe_bg_init_lookahead_n: int,
    gauss_en: bool = True,
    **_ignored,
) -> list[np.ndarray]:
    """Return per-frame uint8 motion masks (True/False as 0/1) under ViBe."""
    if not frames:
        return []

    # Pre-compute the Y stack (gaussian-filtered if enabled).
    y_stack = []
    for f in frames:
        y = _rgb_to_y(f)
        y_stack.append(_gauss3x3(y) if gauss_en else y)
    y_arr = np.stack(y_stack, axis=0)  # (N, H, W) uint8

    init_scheme = {0: "a", 1: "b", 2: "c"}[vibe_init_scheme]
    v = ViBe(
        K=vibe_K,
        R=vibe_R,
        min_match=vibe_min_match,
        phi_update=vibe_phi_update,
        phi_diffuse=vibe_phi_diffuse,
        init_scheme=init_scheme,
        prng_seed=vibe_prng_seed,
        coupled_rolls=vibe_coupled_rolls,
    )

    # Init.
    if vibe_bg_init_mode == 0:           # frame0
        v.init_from_frame(y_arr[0])
    elif vibe_bg_init_mode == 1:         # lookahead median
        n = None if vibe_bg_init_lookahead_n == 0 else int(vibe_bg_init_lookahead_n)
        v.init_from_frames(y_arr, lookahead_n=n)
    else:
        raise ValueError(f"unknown vibe_bg_init_mode {vibe_bg_init_mode}")

    # Per-frame mask production. Frame 0 is priming → all-zero (matches EMA path).
    h, w = y_arr.shape[1:]
    masks: list[np.ndarray] = [np.zeros((h, w), dtype=bool)]
    for i in range(1, y_arr.shape[0]):
        masks.append(v.process_frame(y_arr[i]))
    return masks
```

- [ ] **Step 2: Quick sanity import**

```bash
python -c "from models._vibe_mask import produce_masks_vibe; print('OK')"
```

Expected: prints `OK`. (No tests yet — those land in Task 11.)

- [ ] **Step 3: Commit**

```bash
git add py/models/_vibe_mask.py
git commit -m "feat(models): add _vibe_mask.produce_masks_vibe shared helper

Single source of truth for ViBe-driven mask production. Mirrors
motion.compute_motion_masks (EMA path) so the three vibe ctrl-flow
wrappers can share one implementation."
```

---

### Task 8: Implement `motion_vibe.run` (motion ctrl_flow)

**Files:**
- Create: `py/models/motion_vibe.py`

- [ ] **Step 1: Write the model**

Create `py/models/motion_vibe.py`:

```python
"""Motion control-flow reference model — ViBe bg variant.

Same head/tail as models/motion.py (RGB→Y, gauss, morph_clean, CCL,
overlay) but the bg-subtraction block is ViBe instead of EMA. Wired in
when the active profile sets `bg_model = BG_MODEL_VIBE = 1`.

Frame-0 priming convention matches the EMA path: mask is all-zero on
frame 0, no bboxes drawn. From frame 1 onward the ViBe bank produces
masks normally. See models/_vibe_mask.py for the shared producer.
"""
from __future__ import annotations

import numpy as np

from models._vibe_mask import produce_masks_vibe
from models.ccl import run_ccl
from models.motion import (
    N_OUT, N_LABELS_INT, MIN_COMPONENT_PIXELS, MAX_CHAIN_DEPTH,
    PRIME_FRAMES, _draw_bboxes,
)
from models.ops.morph_open import morph_open
from models.ops.morph_close import morph_close


def run(
    frames: list[np.ndarray],
    *,
    morph_open_en: bool = True,
    morph_close_en: bool = True,
    morph_close_kernel: int = 3,
    **vibe_kwargs,
) -> list[np.ndarray]:
    """Motion ctrl_flow under ViBe bg.

    Reuses motion.py constants and _draw_bboxes for parity with the EMA
    output convention. Per-frame steps:
      1. produce_masks_vibe → raw mask
      2. morph_open  (if enabled)
      3. morph_close (if enabled)
      4. run_ccl on the cleaned mask → bboxes (1-frame delay vs EMA path)
      5. _draw_bboxes(prev frame's bboxes, current rgb frame)
    """
    if not frames:
        return []

    # ViBe needs the unfiltered RGB stack; the helper handles gauss internally.
    raw_masks = produce_masks_vibe(frames, **vibe_kwargs)

    cleaned: list[np.ndarray] = []
    for m in raw_masks:
        c = m
        if morph_open_en:
            c = morph_open(c)
        if morph_close_en:
            c = morph_close(c, kernel=morph_close_kernel)
        cleaned.append(c)

    bboxes_state = [None] * N_OUT
    outputs: list[np.ndarray] = []
    for i, frame in enumerate(frames):
        out = _draw_bboxes(frame, bboxes_state)
        new_bboxes = run_ccl(
            [cleaned[i]],
            n_out=N_OUT,
            n_labels_int=N_LABELS_INT,
            min_component_pixels=MIN_COMPONENT_PIXELS,
            max_chain_depth=MAX_CHAIN_DEPTH,
        )[0]
        primed_for_bbox = (i >= PRIME_FRAMES)
        bboxes_state = new_bboxes if primed_for_bbox else [None] * N_OUT
        outputs.append(out)

    return outputs
```

- [ ] **Step 2: Smoke-import**

```bash
python -c "from models.motion_vibe import run; print('OK')"
```

Expected: prints `OK`.

- [ ] **Step 3: Commit**

```bash
git add py/models/motion_vibe.py
git commit -m "feat(models): add motion_vibe.run for the motion ctrl_flow"
```

---

### Task 9: Implement `mask_vibe.run` (mask ctrl_flow)

**Files:**
- Create: `py/models/mask_vibe.py`

- [ ] **Step 1: Read the EMA mask reference for shape parity**

```bash
sed -n '1,80p' py/models/mask.py
```

Note the output convention: each pixel becomes black or full white based on the post-cleanup mask. We mirror it.

- [ ] **Step 2: Write the model**

Create `py/models/mask_vibe.py`:

```python
"""Mask control-flow reference model — ViBe bg variant.

Same B/W expansion as models/mask.py, with ViBe replacing EMA for
mask production. Mask cleanup (morph_open/close) is applied identically.
"""
from __future__ import annotations

import numpy as np

from models._vibe_mask import produce_masks_vibe
from models.ops.morph_open import morph_open
from models.ops.morph_close import morph_close


def run(
    frames: list[np.ndarray],
    *,
    morph_open_en: bool = True,
    morph_close_en: bool = True,
    morph_close_kernel: int = 3,
    **vibe_kwargs,
) -> list[np.ndarray]:
    """Mask ctrl_flow under ViBe bg. Returns per-frame B/W RGB frames."""
    if not frames:
        return []
    raw_masks = produce_masks_vibe(frames, **vibe_kwargs)
    h, w = raw_masks[0].shape
    outputs: list[np.ndarray] = []
    for m in raw_masks:
        c = m
        if morph_open_en:
            c = morph_open(c)
        if morph_close_en:
            c = morph_close(c, kernel=morph_close_kernel)
        # Expand boolean mask to white-on-black RGB (matches mask.py:96-97).
        out = np.zeros((h, w, 3), dtype=np.uint8)
        out[c] = 255
        outputs.append(out)
    return outputs
```

- [ ] **Step 3: Smoke-import**

```bash
python -c "from models.mask_vibe import run; print('OK')"
```

Expected: prints `OK`.

- [ ] **Step 4: Commit**

```bash
git add py/models/mask_vibe.py
git commit -m "feat(models): add mask_vibe.run for the mask ctrl_flow"
```

---

### Task 10: Implement `ccl_bbox_vibe.run` (ccl_bbox ctrl_flow)

**Files:**
- Create: `py/models/ccl_bbox_vibe.py`

- [ ] **Step 1: Read the EMA ccl_bbox reference for shape parity**

```bash
sed -n '1,120p' py/models/ccl_bbox.py
```

Note the output convention: mask rendered as a grey canvas (e.g. 128) under green CCL bboxes. We mirror it.

- [ ] **Step 2: Write the model**

Create `py/models/ccl_bbox_vibe.py`. Reuse the existing `_mask_to_grey_canvas` helper and `BG_GREY`/`FG_GREY` constants from `ccl_bbox.py` so the canvas values stay in lockstep:

```python
"""ccl_bbox control-flow reference model — ViBe bg variant.

Same grey-canvas-with-bboxes render as models/ccl_bbox.py, with ViBe
replacing EMA for mask production. Reuses the EMA module's
_mask_to_grey_canvas helper and BG_GREY/FG_GREY constants so canvas
values stay in lockstep across the two variants.
"""
from __future__ import annotations

import numpy as np

from models._vibe_mask import produce_masks_vibe
from models.ccl import run_ccl
from models.ccl_bbox import _mask_to_grey_canvas, BG_GREY, FG_GREY  # noqa: F401
from models.motion import (
    N_OUT, N_LABELS_INT, MIN_COMPONENT_PIXELS, MAX_CHAIN_DEPTH,
    PRIME_FRAMES, _draw_bboxes,
)
from models.ops.morph_open import morph_open
from models.ops.morph_close import morph_close


def run(
    frames: list[np.ndarray],
    *,
    morph_open_en: bool = True,
    morph_close_en: bool = True,
    morph_close_kernel: int = 3,
    **vibe_kwargs,
) -> list[np.ndarray]:
    if not frames:
        return []
    raw_masks = produce_masks_vibe(frames, **vibe_kwargs)
    cleaned: list[np.ndarray] = []
    for m in raw_masks:
        c = m
        if morph_open_en:
            c = morph_open(c)
        if morph_close_en:
            c = morph_close(c, kernel=morph_close_kernel)
        cleaned.append(c)

    bboxes_state = [None] * N_OUT
    outputs: list[np.ndarray] = []
    for i in range(len(frames)):
        canvas = _mask_to_grey_canvas(cleaned[i])
        out = _draw_bboxes(canvas, bboxes_state)
        new_bboxes = run_ccl(
            [cleaned[i]],
            n_out=N_OUT,
            n_labels_int=N_LABELS_INT,
            min_component_pixels=MIN_COMPONENT_PIXELS,
            max_chain_depth=MAX_CHAIN_DEPTH,
        )[0]
        primed_for_bbox = (i >= PRIME_FRAMES)
        bboxes_state = new_bboxes if primed_for_bbox else [None] * N_OUT
        outputs.append(out)
    return outputs
```

Note `_mask_to_grey_canvas` is currently defined as a private helper inside `ccl_bbox.py`. The leading underscore notwithstanding, importing it across two ctrl-flow models is the clean way to share the convention; do not duplicate the function. (If the user prefers, the helper can be lifted to a public name in `ccl_bbox.py` in the same commit — that's a one-line rename.)

- [ ] **Step 3: Smoke-import**

```bash
python -c "from models.ccl_bbox_vibe import run; print('OK')"
```

Expected: prints `OK`.

- [ ] **Step 4: Commit**

```bash
git add py/models/ccl_bbox_vibe.py
git commit -m "feat(models): add ccl_bbox_vibe.run for the ccl_bbox ctrl_flow"
```

---

### Task 11: Smoke test for `motion_vibe.run`

**Files:**
- Create: `py/tests/test_motion_vibe_model.py`

Pinned-output bit-exact tests against ViBe runs would be brittle (any cfg-default tweak invalidates them). Instead we sanity-check that the model: (a) returns the right shape/dtype, (b) produces a non-empty bbox on a synthetic moving box, (c) accepts every field in `DEFAULT_VIBE` as a kwarg without TypeError.

- [ ] **Step 1: Write the test**

Create `py/tests/test_motion_vibe_model.py`:

```python
"""Smoke tests for motion_vibe / mask_vibe / ccl_bbox_vibe reference models.

Bit-exact pinning is intentionally avoided — the cfg defaults might tune
in Phase 1.x. We assert structural and qualitative properties only.
"""
from __future__ import annotations

import numpy as np
import pytest

from frames.video_source import load_frames
from profiles import DEFAULT_VIBE


def _vibe_kwargs():
    """All ViBe kwargs from DEFAULT_VIBE, minus the wrapping/tail flags
    that run_model() pops off. Caller passes these to model run()."""
    keep = {k: v for k, v in DEFAULT_VIBE.items()
            if not k.endswith("_en") or k == "gauss_en"}
    # Drop fields the vibe models don't consume directly:
    for f in ("motion_thresh", "alpha_shift", "alpha_shift_slow",
              "grace_frames", "grace_alpha_shift", "morph_close_kernel",
              "bbox_color", "bg_model"):
        keep.pop(f, None)
    return keep


def _frames_moving_box(num=12, w=64, h=48):
    return load_frames("synthetic:moving_box", width=w, height=h, num_frames=num)


def test_motion_vibe_run_shape_and_dtype():
    from models.motion_vibe import run
    frames = _frames_moving_box(num=8)
    out = run(frames, morph_open_en=True, morph_close_en=True,
              morph_close_kernel=3, **_vibe_kwargs())
    assert len(out) == len(frames)
    for f in out:
        assert f.dtype == np.uint8
        assert f.shape == frames[0].shape


def test_motion_vibe_run_frame0_is_priming():
    """Frame 0 returns the input untouched (no bboxes yet)."""
    from models.motion_vibe import run
    frames = _frames_moving_box(num=4)
    out = run(frames, morph_open_en=True, morph_close_en=True,
              morph_close_kernel=3, **_vibe_kwargs())
    assert np.array_equal(out[0], frames[0])


def test_mask_vibe_run_outputs_are_bw():
    from models.mask_vibe import run
    frames = _frames_moving_box(num=6)
    out = run(frames, morph_open_en=True, morph_close_en=True,
              morph_close_kernel=3, **_vibe_kwargs())
    assert len(out) == len(frames)
    # Every pixel must be either (0,0,0) or (255,255,255).
    for f in out:
        flat = f.reshape(-1, 3)
        unique = {tuple(p) for p in np.unique(flat, axis=0)}
        assert unique.issubset({(0, 0, 0), (255, 255, 255)}), \
            f"non-binary pixel in mask_vibe output: {unique}"


def test_ccl_bbox_vibe_run_uses_grey_canvas():
    from models.ccl_bbox import BG_GREY  # canonical canvas-bg value (0x20)
    from models.ccl_bbox_vibe import run
    frames = _frames_moving_box(num=6)
    out = run(frames, morph_open_en=True, morph_close_en=True,
              morph_close_kernel=3, **_vibe_kwargs())
    assert len(out) == len(frames)
    # At least one frame's "background" pixel must be the canonical BG_GREY.
    grey_seen = any((f == BG_GREY).all(axis=-1).any() for f in out)
    assert grey_seen, f"expected BG_GREY={tuple(BG_GREY)} pixels in ccl_bbox_vibe output"


def test_motion_vibe_accepts_all_default_vibe_keys():
    """Regression guard: every key in DEFAULT_VIBE must be acceptable as
    a kwarg to motion_vibe.run, even if the model ignores it. Otherwise
    the dispatcher in run_model() will explode at runtime."""
    from models.motion_vibe import run
    frames = _frames_moving_box(num=3)
    # Pass EVERY field in DEFAULT_VIBE as kwargs (mirrors what run_model does).
    cfg = dict(DEFAULT_VIBE)
    cfg.pop("hflip_en", None)  # head op, popped by run_model before dispatch
    cfg.pop("gamma_en", None)
    cfg.pop("scaler_en", None)
    cfg.pop("hud_en", None)
    cfg.pop("bg_model", None)
    out = run(frames, **cfg)
    assert len(out) == len(frames)
```

- [ ] **Step 2: Run the test**

```bash
pytest py/tests/test_motion_vibe_model.py -v
```

Expected: all 5 tests PASS. If `test_motion_vibe_accepts_all_default_vibe_keys` fails with `TypeError: unexpected keyword argument 'X'`, your `run()` signature is too strict — accept `**kwargs` and ignore the unknown keys, OR pop them inside the helper.

- [ ] **Step 3: Commit**

```bash
git add py/tests/test_motion_vibe_model.py
git commit -m "test(models): smoke tests for motion/mask/ccl_bbox vibe variants"
```

---

### Task 12: Wire `bg_model` dispatch in `run_model()`

**Files:**
- Modify: `py/models/__init__.py`

- [ ] **Step 1: Add the ViBe model registry and dispatch branch**

Replace the body of `py/models/__init__.py` with:

```python
"""Control-flow reference models for pixel-accurate pipeline verification.

Each control flow has its own module with a run() entry point.
Dispatch via run_model() which maps (ctrl_flow, bg_model) to the correct model.

Pipeline-stage flags are applied in this dispatcher so each control-flow model
only needs to know about its own algorithm:
  - hflip_en:  applied at the head (frames mirrored before dispatch).
  - gamma_en:  applied at the tail (sRGB encode on each output frame).
  - scaler_en: applied at the very tail (2x bilinear spatial upscale).
  - hud_en:    applied at the very, very tail (HUD bitmap overlay).

Background model selector:
  - bg_model=0 (BG_MODEL_EMA, default): existing EMA-based motion/mask/ccl_bbox.
  - bg_model=1 (BG_MODEL_VIBE):         ViBe variant from models/*_vibe.py.
  passthrough does not consume bg, so bg_model is ignored for it.
"""

from models.ops.gamma_cor import gamma_cor as _gamma_cor
from models.ops.hflip     import hflip      as _hflip
from models.ops.scale2x   import scale2x    as _scale2x
from models.ops.hud       import hud        as _hud, CTRL_TAG_MAP
from models.ops._hud_metadata import load_latencies as _load_latencies
from models.bbox_counts   import bbox_counts_per_frame as _bbox_counts
from models.passthrough   import run as _run_passthrough
from models.motion        import run as _run_motion
from models.mask          import run as _run_mask
from models.ccl_bbox      import run as _run_ccl_bbox
from models.motion_vibe   import run as _run_motion_vibe
from models.mask_vibe     import run as _run_mask_vibe
from models.ccl_bbox_vibe import run as _run_ccl_bbox_vibe

BG_MODEL_EMA  = 0
BG_MODEL_VIBE = 1

_MODELS_EMA = {
    "passthrough": _run_passthrough,
    "motion":      _run_motion,
    "mask":        _run_mask,
    "ccl_bbox":    _run_ccl_bbox,
}

_MODELS_VIBE = {
    "motion":   _run_motion_vibe,
    "mask":     _run_mask_vibe,
    "ccl_bbox": _run_ccl_bbox_vibe,
}


def _select_model(ctrl_flow: str, bg_model: int):
    if ctrl_flow == "passthrough":
        return _run_passthrough
    if bg_model == BG_MODEL_VIBE and ctrl_flow in _MODELS_VIBE:
        return _MODELS_VIBE[ctrl_flow]
    if ctrl_flow in _MODELS_EMA:
        return _MODELS_EMA[ctrl_flow]
    raise ValueError(
        f"Unknown control flow '{ctrl_flow}'. "
        f"Available: {', '.join(sorted(_MODELS_EMA))}"
    )


def run_model(ctrl_flow: str, frames: list, **kwargs) -> list:
    bg_model  = kwargs.pop("bg_model", BG_MODEL_EMA)
    hflip_en  = kwargs.pop("hflip_en",  False)
    gamma_en  = kwargs.pop("gamma_en",  False)
    scaler_en = kwargs.pop("scaler_en", False)
    hud_en    = kwargs.pop("hud_en",    False)

    model_fn = _select_model(ctrl_flow, bg_model)
    in_frames = [_hflip(f) for f in frames] if hflip_en else frames
    out = model_fn(in_frames, **kwargs)
    if gamma_en:
        out = [_gamma_cor(f) for f in out]
    if scaler_en:
        out = [_scale2x(f) for f in out]
    if hud_en:
        n = len(out)
        latencies = _load_latencies(n)
        bbox_counts = _bbox_counts(ctrl_flow, in_frames,
                                    bg_model=bg_model, **kwargs)
        bbox_counts = [0] + bbox_counts[:-1] if bbox_counts else bbox_counts
        tag = CTRL_TAG_MAP.get(ctrl_flow, "???")
        out = [_hud(f, frame_num=i, ctrl_flow_tag=tag,
                    bbox_count=bbox_counts[i], latency_us=latencies[i])
               for i, f in enumerate(out)]
    return out
```

Note we drop the `bbox_kwargs` filtering trick from the original implementation in favor of passing `**kwargs` through (`bbox_counts.py` will be tolerant). This keeps the dispatcher symmetric for EMA and ViBe.

- [ ] **Step 2: Run the existing model tests to confirm no EMA regression**

```bash
pytest py/tests/test_models.py -v
```

Expected: all existing tests still PASS.

- [ ] **Step 3: Run the new smoke tests through run_model**

```bash
python -c "
from models import run_model, BG_MODEL_VIBE
from profiles import DEFAULT_VIBE
from frames.video_source import load_frames
frames = load_frames('synthetic:moving_box', width=64, height=48, num_frames=8)
out = run_model('motion', frames, **DEFAULT_VIBE)
print('vibe motion run_model OK; len(out)=', len(out))
"
```

Expected: prints `vibe motion run_model OK; len(out)= 8`. If TypeError on an unexpected kwarg, fix the receiving model's signature to accept `**_ignored`.

- [ ] **Step 4: Commit**

```bash
git add py/models/__init__.py
git commit -m "feat(models): bg_model dispatch in run_model() for ViBe ctrl flows

passthrough is bg-agnostic (always EMA registry).
motion/mask/ccl_bbox under bg_model=BG_MODEL_VIBE route to the
corresponding _vibe.py model. EMA path byte-identical."
```

---

### Task 13: Extend `bbox_counts.py` to handle ViBe profiles

**Files:**
- Modify: `py/models/bbox_counts.py`

- [ ] **Step 1: Branch on bg_model**

Replace the body of `py/models/bbox_counts.py` with:

```python
"""Per-frame bbox-count helper for the HUD model. Mirrors the count the SV
emits via popcount over u_ccl_bboxes.valid[].

Branches on bg_model so the HUD count is correct under ViBe profiles too."""
from __future__ import annotations

from models.ccl import run_ccl
from models.motion import (
    N_OUT, N_LABELS_INT, MIN_COMPONENT_PIXELS, MAX_CHAIN_DEPTH,
    compute_motion_masks,
)
from models.ops.morph_open import morph_open

_BG_MODEL_EMA = 0
_BG_MODEL_VIBE = 1


def bbox_counts_per_frame(ctrl_flow: str, frames, *, bg_model=_BG_MODEL_EMA,
                           motion_thresh=16, alpha_shift=3, alpha_shift_slow=6,
                           grace_frames=0, grace_alpha_shift=1, gauss_en=True,
                           morph_open_en=True, morph_close_en=False,
                           morph_close_kernel=3, **vibe_kwargs) -> list[int]:
    """Number of valid bboxes per frame matching SV's u_ccl_bboxes.valid popcount.
    Returns zeros for non-bbox-producing flows (passthrough)."""
    if ctrl_flow == "passthrough":
        return [0] * len(frames)

    if bg_model == _BG_MODEL_VIBE:
        from models._vibe_mask import produce_masks_vibe
        # Drop EMA-only kwargs and tail-stage flags before forwarding.
        for k in ("motion_thresh", "alpha_shift", "alpha_shift_slow",
                  "grace_frames", "grace_alpha_shift",
                  "morph_open_en", "morph_close_en", "morph_close_kernel",
                  "hflip_en", "gamma_en", "scaler_en", "hud_en", "bbox_color"):
            vibe_kwargs.pop(k, None)
        masks = produce_masks_vibe(frames, gauss_en=gauss_en, **vibe_kwargs)
    else:
        masks = compute_motion_masks(
            frames,
            motion_thresh=motion_thresh, alpha_shift=alpha_shift,
            alpha_shift_slow=alpha_shift_slow, grace_frames=grace_frames,
            grace_alpha_shift=grace_alpha_shift, gauss_en=gauss_en,
        )

    if morph_open_en:
        masks = [morph_open(m) for m in masks]
    bboxes_per_frame = run_ccl(masks, n_out=N_OUT,
                               n_labels_int=N_LABELS_INT,
                               min_component_pixels=MIN_COMPONENT_PIXELS,
                               max_chain_depth=MAX_CHAIN_DEPTH)
    return [sum(1 for b in bb if b is not None) for bb in bboxes_per_frame]
```

- [ ] **Step 2: Smoke-test with the HUD path**

```bash
python -c "
from models import run_model
from profiles import DEFAULT_VIBE
from frames.video_source import load_frames
frames = load_frames('synthetic:moving_box', width=64, height=48, num_frames=6)
out = run_model('motion', frames, **DEFAULT_VIBE)
print('vibe motion+HUD OK; len(out)=', len(out))
"
```

Expected: prints `vibe motion+HUD OK; len(out)= 6`. The HUD overlay is enabled in `DEFAULT_VIBE` (inherits from `DEFAULT`), so this exercises the bbox_counts branch.

- [ ] **Step 3: Run the full test suite**

```bash
pytest py/tests
```

Expected: ALL tests PASS. Pass count = Task 1 baseline + 5 new tests.

- [ ] **Step 4: Commit**

```bash
git add py/models/bbox_counts.py
git commit -m "feat(bbox_counts): branch on bg_model for ViBe HUD count"
```

---

### Task 14: End-to-end smoke run via `make sw-dry-run`

**Files:** none (validation only).

`sw-dry-run` bypasses RTL — it is the canonical way to characterise Python-only changes at this phase.

- [ ] **Step 1: Run the default profile (regression baseline)**

```bash
make run-pipeline CTRL_FLOW=motion CFG=default SOURCE="synthetic:moving_box" FRAMES=8 TOLERANCE=0
```

Expected: `make verify` passes — RTL still matches the EMA Python model.

- [ ] **Step 2: Run `default_vibe` via sw-dry-run**

The Python model produces the comparison file directly; `sw-dry-run` short-circuits the RTL sim.

```bash
make prepare CTRL_FLOW=motion CFG=default_vibe SOURCE="synthetic:moving_box" WIDTH=64 HEIGHT=48 FRAMES=8 MODE=binary
make sw-dry-run
make verify TOLERANCE=0
```

Expected: `make verify` passes — both the "RTL output" (which is just the input frames, since sw-dry-run is file loopback) and the model output go through whichever leg `make verify` uses. If `make verify` only compares input vs reference, this validates the Python harness end-to-end.

If `make verify` returns failure with a non-zero diff, that is expected and acceptable — it means the model output (ViBe) differs from the input frames (which is what sw-dry-run echoes back). Document this in the PR description as the known Phase-1 limitation: ViBe profiles cannot be RTL-verified at TOLERANCE=0 because RTL is still EMA. RTL parity for ViBe profiles arrives in Phase 2.

- [ ] **Step 3: Run the four other vibe profiles**

```bash
for prof in vibe_k20 vibe_no_diffuse vibe_no_gauss vibe_init_frame0; do
  make prepare CTRL_FLOW=motion CFG=$prof SOURCE="synthetic:moving_box" WIDTH=64 HEIGHT=48 FRAMES=8 MODE=binary || exit 1
  make sw-dry-run || exit 1
done
echo "all 4 vibe profiles ran end-to-end"
```

Expected: prints `all 4 vibe profiles ran end-to-end`. We are NOT asserting verify — just that the harness drives them without crashing.

- [ ] **Step 4: Render a comparison grid for the headline profile**

```bash
make prepare CTRL_FLOW=motion CFG=default_vibe SOURCE="synthetic:moving_box" WIDTH=320 HEIGHT=240 FRAMES=20 MODE=binary
make sw-dry-run
make render
ls -la renders/ | tail -5
```

Expected: a fresh PNG grid exists under `renders/`. Open it locally to eyeball that the ViBe pipeline produced sensible motion bboxes around the moving box. (Render cannot fail silently — if `make render` exits non-zero, fix before continuing.)

---

### Task 15: Update CLAUDE.md and README.md

**Files:**
- Modify: `CLAUDE.md` (Build Commands section + Pipeline Harness section)
- Modify: `README.md` (Profiles table)

- [ ] **Step 1: Add ViBe examples to the Build Commands section in CLAUDE.md**

Find the `# Algorithm profile selection` block (around line 53). After the existing examples and before `# Upscaler profile selection`, insert:

```bash
make run-pipeline CFG=default_vibe       # ViBe bg + look-ahead median init (Python-only)
make run-pipeline CFG=vibe_k20           # ViBe with literature-default K=20
make run-pipeline CFG=vibe_no_diffuse    # negative control: diffusion off
make run-pipeline CFG=vibe_no_gauss      # ViBe with Gaussian pre-filter bypassed
make run-pipeline CFG=vibe_init_frame0   # ViBe with legacy frame-0 init (A/B)
```

- [ ] **Step 2: Add a Pipeline Harness note in CLAUDE.md**

Find the `## Pipeline Harness` section. After the existing bullets, append a new bullet:

```markdown
- **bg_model selector** is a `cfg_t` field. `bg_model=BG_MODEL_EMA` (the default for every existing profile) keeps the EMA bg block; `bg_model=BG_MODEL_VIBE` swaps in the ViBe reference (Python-only at Phase 1 — the RTL still runs EMA, so ViBe profiles characterise via `make sw-dry-run`, not `make verify`). RTL parity for ViBe arrives in Phase 2.
```

- [ ] **Step 3: Update README.md profiles table**

Find the profiles table in `README.md` (search for `default_hflip` to locate it). Append the 5 new rows with one-line descriptions matching the docstrings in `py/profiles.py`. If the README has no profiles table, add a short paragraph linking to `py/profiles.py` and listing the new profile names.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document Phase 1 ViBe profiles and bg_model selector"
```

---

### Task 16: Final verification before squash

**Files:** none.

- [ ] **Step 1: Full project test suite**

```bash
source .venv/bin/activate && pytest py/tests
```

Expected: ALL tests PASS. Pass count = Task 1 baseline + 5 (the new motion_vibe_model smoke tests).

- [ ] **Step 2: Lint clean**

```bash
make lint
```

Expected: clean.

- [ ] **Step 3: Existing EMA regression — every existing profile still verifies**

```bash
for prof in default default_hflip no_ema no_morph no_gauss no_gamma_cor no_scaler demo no_hud; do
  make run-pipeline CTRL_FLOW=motion CFG=$prof SOURCE="synthetic:moving_box" FRAMES=8 TOLERANCE=0 || { echo "REGRESSION on $prof"; exit 1; }
done
echo "all EMA profiles still pass make verify"
```

Expected: prints `all EMA profiles still pass make verify`. If anything regresses, the most likely cause is an accidental change in a shared helper (`bbox_counts.py`, `__init__.py` dispatcher) — diff vs origin/main.

- [ ] **Step 4: Branch hygiene check**

```bash
git log --oneline origin/main..HEAD
```

Expected: 13 commits matching Tasks 2–6, 7–10, 11, 12, 13, 15 (Task 14 had no commit). Confirm every commit is on-topic for Phase 1; if any unrelated fix slipped in (e.g. fixing an unrelated typo from a different PR), per CLAUDE.md split it to its own branch BEFORE squashing.

- [ ] **Step 5: Squash all commits into one**

```bash
git reset --soft origin/main
git commit -m "feat(motion/vibe): Phase 1 — promote ViBe to py/models/, add bg_model selector

Phase 1 of the ViBe motion-pipeline migration (design doc:
docs/plans/2026-05-01-vibe-motion-design.md §9).

- xorshift32 + ViBe class promoted out of py/experiments/ into
  py/models/ops/ (shims left behind for experiment scripts).
- cfg_t gains bg_model + 10 ViBe knobs (vibe_K, vibe_R,
  vibe_min_match, vibe_phi_update, vibe_phi_diffuse,
  vibe_init_scheme, vibe_prng_seed, vibe_coupled_rolls,
  vibe_bg_init_mode, vibe_bg_init_lookahead_n). Existing CFG_*
  profiles all set bg_model=BG_MODEL_EMA so RTL behavior is
  byte-identical.
- New profiles: default_vibe, vibe_k20, vibe_no_diffuse,
  vibe_no_gauss, vibe_init_frame0. RTL stays EMA-only this phase
  (RTL parity arrives in Phase 2); ViBe profiles characterise
  via make sw-dry-run.
- run_model() dispatches on bg_model. New _vibe_mask.py shared
  helper drives motion_vibe / mask_vibe / ccl_bbox_vibe.
- bbox_counts.py branches on bg_model so HUD count is correct
  under ViBe profiles.
- Smoke tests for the new models; existing 184+ tests untouched."
```

- [ ] **Step 6: Final commit log + status**

```bash
git log --oneline origin/main..HEAD
git status
```

Expected: exactly ONE new commit on top of origin/main; clean tree.

- [ ] **Step 7: Push and open PR**

```bash
git push -u origin feat/vibe-phase-1
gh pr create --title "feat(motion/vibe): Phase 1 — promote ViBe to py/models/" --body "$(cat <<'EOF'
## Summary
- Promote ViBe Python reference from `py/experiments/` to `py/models/ops/vibe.py` + 3 ctrl-flow wrappers.
- Add `cfg_t.bg_model` selector + 10 ViBe knobs (mirrored in `py/profiles.py`).
- Ship 5 new profiles: `default_vibe`, `vibe_k20`, `vibe_no_diffuse`, `vibe_no_gauss`, `vibe_init_frame0`.
- RTL stays EMA-only this phase. ViBe profiles characterise via `make sw-dry-run`. RTL parity arrives in Phase 2.

## Test plan
- [x] `pytest py/tests` — all tests pass (baseline + 5 new smoke tests)
- [x] `make lint` clean
- [x] All 9 existing EMA profiles still pass `make run-pipeline ... TOLERANCE=0`
- [x] All 5 new ViBe profiles run end-to-end via `make sw-dry-run`
- [x] `make render` produces a sensible grid for `default_vibe` on `synthetic:moving_box`
EOF
)"
```

- [ ] **Step 8: Move plan to docs/plans/old/ in a follow-up commit**

After the PR is opened (so the link in the body still resolves cleanly during review), per the CLAUDE.md "TODO after each major change" convention:

```bash
git checkout -b chore/retire-vibe-phase-1-plan origin/main
git mv docs/plans/2026-05-06-vibe-phase-1-plan.md docs/plans/old/2026-05-06-vibe-phase-1-plan.md
git commit -m "chore(plans): retire Phase 1 plan into docs/plans/old/"
git push -u origin chore/retire-vibe-phase-1-plan
gh pr create --title "chore(plans): retire ViBe Phase 1 plan" --body "Plan implemented in feat/vibe-phase-1. Moving to docs/plans/old/ per CLAUDE.md retirement convention."
```

(This is a separate, trivial PR; merging it after the Phase-1 PR keeps the implemented-plans index clean.)

---

## Out of scope (Phase 1 explicitly does NOT touch)

- Any RTL behavior change. `axis_motion_detect.sv` continues to read only the EMA fields; the new `bg_model`/`vibe_*` fields are dead loads at this phase.
- The `xorshift32` SV mirror. It will land in Phase 2 alongside `axis_motion_detect_vibe.sv`.
- The 64-bit BRAM sample bank, byte-enable semantics, and BRAM IP choice (design doc §10.1, §10.2). These are Phase 2 concerns.
- `axis_ccl` per-pixel label output port (LBSP plan), `axis_lbsp`, `axis_thresh_adapt`, `axis_hist_accum`. These belong to the parked LBSP fallback plan (`docs/plans/2026-04-22-lbsp-vibe-motion-pipeline-plan.md`).
- Re-running the existing experiment matrices (Phase 0 redo + look-ahead init) under the promoted code paths. The promoted ViBe class is byte-identical to `py/experiments/motion_vibe.py`'s — re-run only if a bisect on a future regression points here.

## Open questions / risks

1. **`make verify` semantics under sw-dry-run for ViBe profiles.** sw-dry-run does file loopback; the Python model produces the reference; `make verify` compares the two. For EMA profiles this works because RTL == model. For ViBe profiles it cannot match (RTL still EMA). Task 14 documents this; the workflow is "sw-dry-run + render only" for ViBe profiles in Phase 1. Confirm with the user before opening the PR if this is acceptable, or if the harness should grow a `--no-verify` mode for sw-dry-run with ViBe.

2. **Memory/perf characterization deferred.** This plan does NOT run the full ViBe profile matrix on the three real demo clips. That's an evaluation step that should happen before Phase 2 RTL kickoff; track separately.

3. **Renaming `py/experiments/motion_vibe.py` → shim.** All experiment scripts should keep working unchanged (verified by Task 3 Step 5). If the shim ever breaks a downstream tool we missed (e.g. a notebook, an external CI hook), drop the shim and fix the import — but per CLAUDE.md this should be a separate small commit.

4. **Phase 2 RTL parity discipline.** Phase 1 leaves `vibe_prng_seed` at `0xDEADBEEF`. The Phase 2 SV mirror MUST initialise its xorshift state to the same constant or all TOLERANCE=0 verifies will diverge from frame 0. Note in the Phase 2 plan when it gets written.
