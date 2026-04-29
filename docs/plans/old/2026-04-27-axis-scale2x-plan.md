# axis_scale2x Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 2× spatial upscaler at the tail of the clk_dsp pipeline (between `axis_gamma_cor` and the output CDC FIFO) so the project can deliver standard VGA 640×480 output from a 320×240 source pipeline. The scaler is **compile-time-selectable** via a new `SCALER` Makefile knob; an internal `SCALE_FILTER` knob picks between nearest-neighbour and bilinear modes. When `SCALER=0` the module is not instantiated and every existing path remains byte-identical to today.

**Architecture:** A new `axis_scale2x` AXIS module with a single line buffer and an FSM that emits each source row twice (NN: each pixel emitted twice; bilinear: arithmetic mean between current and previous source row, plus arithmetic mean between adjacent pixels within a row, all powers-of-two so no multipliers). Sits between `u_gamma_cor.m_axis` and `u_fifo_out.s_axis` in `sparevideo_top`, wrapped in `generate if (SCALER == 1)`. The VGA controller is parameterised separately: `H_ACTIVE_OUT/V_ACTIVE_OUT` and matching porches come from new `*_OUT_2X` `localparam`s in `sparevideo_pkg`, selected by the top's `SCALER` parameter. `OUT_FIFO_DEPTH` grows from 256 to 1024 to absorb the bursty 4× output rate. **The DUT exposes two pixel clocks: `clk_pix_in_i` (input AXIS rate) and `clk_pix_out_i` (VGA controller rate).** With SCALER=1 the caller drives them at 1:4 ratio (e.g. 6.3 MHz : 25.175 MHz); with SCALER=0 the caller ties them together. Rate balance is established by the clock frequencies — no software pacing is required in the TB. The Python reference model gets a new op (`py/models/ops/scale2x.py` with `mode='nn'|'bilinear'`) composed at the tail of every control-flow model when scaling is enabled.

**Tech Stack:** SystemVerilog (Verilator 5 synthesis subset — no SVA, no classes, `axis_if` interfaces, `generate if` for compile-time presence/absence), Python 3 (numpy) in `.venv/`, FuseSoC core files, Makefile parameter propagation.

**Prerequisites:** The pipeline-extensions design doc (`docs/plans/2026-04-23-pipeline-extensions-design.md` §3.5) is the canonical spec for this block; that doc was revised in lockstep with this plan to adopt the two-pix-clk model (§2 + §3.5). Earlier blocks in that design (`axis_window3x3` refactor, `axis_morph3x3_open`, `axis_hflip`, `axis_gamma_cor`) are merged on `main`; this plan is independent of `axis_hud` (step 6) and can land before or after it. Branch from `origin/main` per CLAUDE.md "one branch per plan" — branch name `feat/axis-scale2x`.

## Status of in-flight work

Tasks 1–5 are already merged on `feat/axis-scale2x`. They remain valid under the revised two-pix-clk model with one follow-up step (Task 5b below). The structural top-level port change (split `clk_pix_i` into `clk_pix_in_i` + `clk_pix_out_i`) is deferred to Task 9, where it lands together with the scaler instantiation. Task 10's TB rework is dramatically simpler than the original plan: no input-pacing math, just two clock generators with the right period ratio.

Carry-over cleanup tracked in this revision:
- Task 3 added `lint_off UNUSEDPARAM` around `SCALE_FILTER` in `sparevideo_top.sv`. **Task 9 removes it** when the parameter is wired to `axis_scale2x`.
- Task 4 left an unused `_avg4` helper in `py/models/ops/scale2x.py`. **Task 14 deletes it** during final cleanup (or earlier if Task 8's bilinear RTL doesn't need it).
- Task 5 deferred adding `-GSCALER` / `-GSCALE_FILTER` to `dv/sim` `VLT_FLAGS` because `tb_sparevideo` did not yet expose those parameters. **Task 10 re-adds them** after the TB parameter list is extended.
- Task 5 left `hw/ip/scaler/scaler.core` without a `depend:` on the pkg core. **Task 9 adds it** if/when the IP is built standalone (otherwise it stays unset; `sparevideo_top.core` already pulls in pkg).

---

## File Structure

**New files:**
- `hw/ip/scaler/scaler.core` — FuseSoC CAPI=2 core for the new IP.
- `hw/ip/scaler/rtl/axis_scale2x.sv` — the module (NN + bilinear behind a string parameter).
- `hw/ip/scaler/tb/tb_axis_scale2x.sv` — unit TB (`drv_*` pattern, asymmetric stall, two test variants per filter mode).
- `docs/specs/axis_scale2x-arch.md` — architecture doc.
- `py/models/ops/scale2x.py` — NN + bilinear reference model.
- `py/tests/test_scale2x.py` — Python unit tests against hand-crafted goldens.

**Modified files:**
- `hw/top/sparevideo_pkg.sv` — add `H_ACTIVE_OUT`/`V_ACTIVE_OUT` (and matching porches) `localparam`s gated by a `SCALER_DEFAULT` constant; intentionally lives in the package so both top and TB can reference it.
- `hw/top/sparevideo_top.sv` — add `SCALER` and `SCALE_FILTER` parameters; thread to a `generate if (SCALER == 1)` block that instantiates `u_scale2x` between `u_gamma_cor.m_axis` and `u_fifo_out.s_axis`; bind the VGA controller to the new `*_OUT` parameters; bump `OUT_FIFO_DEPTH` from 256 to 1024 (only when `SCALER=1`).
- `dv/sv/tb_sparevideo.sv` — accept `SCALER` and `SCALE_FILTER` as `-G` parameters; size two separate dimension sets (`cfg_in_*`, `cfg_out_*`); reshape capture loop and watchdog to use output dims; insert per-row + per-frame blanking on the input side scaled to keep `input_pixels_per_frame * 4 ≤ output_pixels_per_frame`.
- `dv/sim/Makefile` — add `SCALER ?= 0`, `SCALE_FILTER ?= bilinear`, `-GSCALER=$(SCALER)`, `-GSCALE_FILTER='"$(SCALE_FILTER)"'`; include both knobs in `CONFIG_STAMP`; add `IP_SCALE2X_RTL`; add `test-ip-scale2x` target; wire into `test-ip` aggregate and `clean`; thread `axis_scale2x.sv` into `RTL_SRCS`.
- `Makefile` (top) — add `SCALER ?= 0`, `SCALE_FILTER ?= bilinear`; include in `SIM_VARS`; persist into `dv/data/config.mk`; thread into `verify` / `render` argument lists; advertise in `help`; add `test-ip-scale2x` Make target.
- `py/harness.py` — add `--scaler` (int 0|1) and `--scale-filter` (`nn|bilinear`) CLI flags to `prepare`/`verify`/`render`; `prepare` writes a `meta.json` containing input dims **and** output dims (or computes output as input × `(2 if scaler else 1)`); `verify`/`render` apply the scaler before comparing.
- `py/models/__init__.py` — accept `scaler` (bool) and `scale_filter` kwargs; if `scaler`, post-process each ctrl_flow's RGB output through `scale2x(mode=scale_filter)` (after the `gamma_en` post-process).
- `py/profiles.py` — no change required (scaler is structural, not a `cfg_t` field; the parity test stays valid).
- `README.md` — add `SCALER` / `SCALE_FILTER` to the build-options list; add the new IP to the block table.
- `CLAUDE.md` — add `SCALER` / `SCALE_FILTER` to "Build Commands"; add `hw/ip/scaler/rtl/` to "Project Structure"; document the pipeline-extension VGA timing change.
- `docs/specs/sparevideo-top-arch.md` — add `axis_scale2x` to the top-level block diagram and the post-mux text; document the input-vs-output dims split.

**No changes required:** `hw/top/sparevideo_if.sv` (existing `axis_if` covers the stage), every existing per-block IP / TB, `py/frames/`, `py/viz/`, every other Python model, `py/tests/test_profiles.py` (scaler is not a profile field).

---

## Task 1: Capture pre-integration regression goldens

**Purpose:** lock in byte-perfect baseline output of every (ctrl_flow × profile) pairing **before** any package or top-level changes. After integration in Task 9, running with `SCALER=0` (the new default) must reproduce every baseline byte-for-byte. `SCALER=1` is verified separately against the new Python reference model in Task 12.

**Files:**
- Create (local, gitignored): `renders/golden/<ctrl_flow>__<profile>__pre-scaler.bin` (8 files: 4 flows × 2 profiles `default`, `default_hflip` — the wider grid is unnecessary; the goal is to prove `SCALER=0` is non-perturbing).

- [ ] **Step 1: Run baseline pipelines, capture output**

```bash
mkdir -p renders/golden
for FLOW in passthrough motion mask ccl_bbox; do
  for PROF in default default_hflip; do
    make run-pipeline CTRL_FLOW=$FLOW CFG=$PROF SOURCE="synthetic:moving_box" \
                      WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
    cp dv/data/output.bin renders/golden/${FLOW}__${PROF}__pre-scaler.bin
  done
done
```

Expected: each `make run-pipeline` invocation exits 0; `verify` reports PASS; 8 binary files exist, each `12 + 320*240*3*8 = 1,843,212` bytes.

- [ ] **Step 2: Sanity-check goldens**

```bash
ls -l renders/golden/*__pre-scaler.bin | wc -l
xxd renders/golden/passthrough__default__pre-scaler.bin | head -1
```

Expected: `8`. First 12 bytes decode as `(0x140, 0xF0, 0x8) = (320, 240, 8)` (little-endian uint32 width/height/frames).

*(Do not commit — `renders/` is gitignored. Goldens are deleted in Task 14.)*

---

## Task 2: Architecture doc

**Files:**
- Create: `docs/specs/axis_scale2x-arch.md`

- [ ] **Step 1: Write the arch doc**

Use the `hardware-arch-doc` skill. Required sections (sized to roughly mirror `docs/specs/axis_gamma_cor-arch.md`):

1. **Purpose** — 2× spatial upscaler at the post-gamma tail of the proc_clk pipeline; compile-time presence (`SCALER=1`); compile-time filter selection (`SCALE_FILTER ∈ {"nn","bilinear"}`); enables the project to drive standard VGA 640×480 from a 320×240 source pipeline.
2. **Module Hierarchy** — leaf module; instantiated as `u_scale2x` in `sparevideo_top` between `u_gamma_cor.m_axis` and `u_fifo_out.s_axis`, wrapped in `generate if (SCALER == 1)`.
3. **Interface Specification**
   - **Parameters:**
     - `H_ACTIVE_IN` (default `sparevideo_pkg::H_ACTIVE = 320`).
     - `V_ACTIVE_IN` (default `sparevideo_pkg::V_ACTIVE = 240`; informational only — module emits 2× rows live without storing the full frame).
     - `SCALE_FILTER` (string; `"nn"` or `"bilinear"`; default `"bilinear"`).
   - **Ports:** `clk_i`, `rst_n_i`, `s_axis` (`axis_if.rx`, DATA_W=24, USER_W=1), `m_axis` (`axis_if.tx`, DATA_W=24, USER_W=1). No `enable_i` — the module's presence is itself a compile-time choice.
4. **Concept Description** — for each input row `S[r]` of width `W`, the module emits two output rows. NN: row 0 = pixel-doubled `S[r]`, row 1 = pixel-doubled `S[r]` (i.e. the same row repeated). Bilinear: row 0 = `(A, (A+B)>>1, B, (B+C)>>1, …, X)` (last sample replicated to keep width even), row 1 = `((A+P)>>1, ((A+B+P+Q)+2)>>2, (B+Q)>>1, …)` where `P,Q,…` are the pixel-doubled samples of `S[r-1]`. For `r=0`, `P=Q=A=B` (top-edge replication). All weights are powers of two, so the datapath is shift-and-add; round-half-up is implemented by adding `1` then shifting (`(a+b+1)>>1` for the 2-tap, `(a+b+c+d+2)>>2` for the 4-tap).
5. **Internal Architecture**
   - 5.1 ASCII diagram: input AXIS → write line buffer (`H_ACTIVE_IN` × 24-bit) → FSM with `cur_pix_q`, `prev_pix_q`, `top_pix_q` registers → output beat formatter → output AXIS. NN mode bypasses the prev-row line buffer.
   - 5.2 FSM states: `S_FILL_FIRST_ROW` (load row 0 into the line buffer, no output), `S_EMIT` (steady state — for each input row, emit two output rows: `OUT_TOP` then `OUT_BOTTOM`, each with two output beats per input pixel — "even" = original, "odd" = horizontal interpolant). `S_FILL_FIRST_ROW` is only entered on SOF; after that the line buffer rolls forward.
   - 5.3 Per-output-beat counters: `out_col` ∈ [0, 2W), `out_phase` ∈ {TOP_ROW, BOT_ROW}. Output AXIS sideband: `m_axis.tuser = (out_phase == TOP_ROW) && (out_col == 0) && first_input_row`; `m_axis.tlast = (out_col == 2W-1)`.
   - 5.4 Backpressure: standard skid pattern. Input is consumed only when the FSM is in `S_EMIT` and has consumed both output rows for the previous input pixel; the output beat is registered with valid/ready handshake. Critical: hold the input AXIS `tready` low while the FSM is busy emitting the two output rows for an already-accepted input pixel (no fresh input until current pixel is fully emitted).
   - 5.5 Resource cost: one 320×24-bit line buffer (~7680 bits); three 24-bit pipeline regs (`cur`, `prev`, `top`); 24-bit shift-and-add adders (3 × 8-bit lanes for R/G/B). No DSPs.
6. **Control Logic** — described inline in 5.2/5.3. No separate FSM diagram needed beyond the two-state main FSM and a small `out_col`/`out_phase` counter.
7. **Timing** — 1 line of latency before the first output beat (the `S_FILL_FIRST_ROW` pass on SOF). Long-term throughput: 4 output pixels per input pixel, so input is back-pressured to 1/4 the output cycle rate.
8. **Shared Types** — uses `pixel_t` and `component_t` from `sparevideo_pkg`.
9. **Known Limitations** — `H_ACTIVE_IN` must be even; bilinear right-edge replicates the last sample (no separate edge policy); top-edge replicates the first source row; `SCALE_FILTER` is fixed at synthesis time (no runtime swap); no support for non-2× factors in this module (a future `axis_scaleNx` would replace it).
10. **References** — `sparevideo-top-arch.md`, `docs/plans/2026-04-23-pipeline-extensions-design.md` §3.5, Risk A1 (output-side CDC FIFO depth) and Risk A4 (gamma-before-scaler).

- [ ] **Step 2: Commit the arch doc**

```bash
git add docs/specs/axis_scale2x-arch.md
git commit -m "docs(scale2x): axis_scale2x architecture spec"
```

---

## Task 3: Output-resolution `localparam`s in `sparevideo_pkg` (no RTL yet)

**Purpose:** introduce `H_ACTIVE_OUT` / `V_ACTIVE_OUT` and matching porches as package-level constants gated on a `SCALER_DEFAULT` flag, plus a thin top-level structural switch on `SCALER`. After this task, every existing `make run-pipeline` invocation must still pass byte-for-byte.

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv` (after the existing `H_ACTIVE`/`V_ACTIVE` block).
- Modify: `hw/top/sparevideo_top.sv:21-31` (parameter list) and the VGA-controller instantiation block at `:489-498`.

- [ ] **Step 1: Add `H_ACTIVE_OUT` / `V_ACTIVE_OUT` to `sparevideo_pkg`**

Edit `hw/top/sparevideo_pkg.sv`. Append below the existing `V_BACK_PORCH` declaration (around line 44):

```systemverilog
    // ---------------------------------------------------------------
    // Output VGA timing — selected by the top-level SCALER parameter.
    //
    // SCALER=0 (default): output dims == input dims (the existing
    // path). SCALER=1: 2x upscale → 640x480, with a wider front/back
    // porch envelope to keep blanking comfortable for the axis_ccl
    // EOF FSM and the verilog-axis FIFO output pipeline.
    //
    // The 2x of every porch is intentional: the design aims for a
    // ~25 MHz pix_clk in both modes, so doubling H_ACTIVE alone would
    // halve the per-line wall-clock time. Doubling the porches keeps
    // the per-line wall-clock identical and the FSM budgets unchanged.
    // ---------------------------------------------------------------
    localparam int H_ACTIVE_OUT_2X      = 2 * H_ACTIVE;
    localparam int H_FRONT_PORCH_OUT_2X = 2 * H_FRONT_PORCH;
    localparam int H_SYNC_PULSE_OUT_2X  = 2 * H_SYNC_PULSE;
    localparam int H_BACK_PORCH_OUT_2X  = 2 * H_BACK_PORCH;

    localparam int V_ACTIVE_OUT_2X      = 2 * V_ACTIVE;
    localparam int V_FRONT_PORCH_OUT_2X = V_FRONT_PORCH;   // vertical porches stay
    localparam int V_SYNC_PULSE_OUT_2X  = V_SYNC_PULSE;    // unchanged: lines, not
    localparam int V_BACK_PORCH_OUT_2X  = V_BACK_PORCH;    // pixels.
```

- [ ] **Step 2: Add `SCALER` parameter to `sparevideo_top` and select VGA-controller dims**

Edit `hw/top/sparevideo_top.sv:21-31`. Append two parameters:

```systemverilog
    parameter int   SCALER        = 0,                            // 0 = no scaler, 1 = 2x scaler instantiated
    parameter sparevideo_pkg::cfg_t CFG = sparevideo_pkg::CFG_DEFAULT,
    parameter string SCALE_FILTER = "bilinear"                    // ignored when SCALER=0
```

(The comma after `CFG` becomes a comma-before-`SCALE_FILTER`; rearrange so the parameter list is syntactically clean.)

Add output-dimension `localparam`s right after the parameter port list (immediately inside the module body, before any signal declarations):

```systemverilog
    // Resolve output VGA dims from SCALER. Used only for the VGA
    // controller and FIFO sizing; the upstream path is unaffected.
    localparam int H_ACTIVE_OUT      = (SCALER == 1) ? sparevideo_pkg::H_ACTIVE_OUT_2X      : H_ACTIVE;
    localparam int V_ACTIVE_OUT      = (SCALER == 1) ? sparevideo_pkg::V_ACTIVE_OUT_2X      : V_ACTIVE;
    localparam int H_FRONT_PORCH_OUT = (SCALER == 1) ? sparevideo_pkg::H_FRONT_PORCH_OUT_2X : H_FRONT_PORCH;
    localparam int H_SYNC_PULSE_OUT  = (SCALER == 1) ? sparevideo_pkg::H_SYNC_PULSE_OUT_2X  : H_SYNC_PULSE;
    localparam int H_BACK_PORCH_OUT  = (SCALER == 1) ? sparevideo_pkg::H_BACK_PORCH_OUT_2X  : H_BACK_PORCH;
    localparam int V_FRONT_PORCH_OUT = (SCALER == 1) ? sparevideo_pkg::V_FRONT_PORCH_OUT_2X : V_FRONT_PORCH;
    localparam int V_SYNC_PULSE_OUT  = (SCALER == 1) ? sparevideo_pkg::V_SYNC_PULSE_OUT_2X  : V_SYNC_PULSE;
    localparam int V_BACK_PORCH_OUT  = (SCALER == 1) ? sparevideo_pkg::V_BACK_PORCH_OUT_2X  : V_BACK_PORCH;
```

- [ ] **Step 3: Re-bind the VGA controller to the `*_OUT` `localparam`s**

Edit `hw/top/sparevideo_top.sv:489-498`. Replace the existing parameter overrides:

```systemverilog
    vga_controller #(
        .H_ACTIVE      (H_ACTIVE_OUT),
        .H_FRONT_PORCH (H_FRONT_PORCH_OUT),
        .H_SYNC_PULSE  (H_SYNC_PULSE_OUT),
        .H_BACK_PORCH  (H_BACK_PORCH_OUT),
        .V_ACTIVE      (V_ACTIVE_OUT),
        .V_FRONT_PORCH (V_FRONT_PORCH_OUT),
        .V_SYNC_PULSE  (V_SYNC_PULSE_OUT),
        .V_BACK_PORCH  (V_BACK_PORCH_OUT)
    ) u_vga (
        // ... existing port bindings unchanged
    );
```

- [ ] **Step 4: Lint + sanity sim (still SCALER=0 everywhere)**

```bash
make lint
make run-pipeline CTRL_FLOW=motion CFG=default SOURCE="synthetic:moving_box" \
                  WIDTH=320 HEIGHT=240 FRAMES=4 MODE=binary
```

Expected: lint clean; pipeline PASS at TOLERANCE=0. (Output is byte-identical to the Task-1 golden because `SCALER` defaults to 0 and no upstream signal has changed.)

- [ ] **Step 5: Confirm against pre-scaler golden**

```bash
cmp dv/data/output.bin renders/golden/motion__default__pre-scaler.bin
```

Expected: identical for the first `12 + 320*240*3*4` bytes. (The golden has 8 frames; reduce FRAMES or rerun with `FRAMES=8` to compare full goldens.)

- [ ] **Step 6: Commit**

```bash
git add hw/top/sparevideo_pkg.sv hw/top/sparevideo_top.sv
git commit -m "feat(scale2x): add output-resolution localparams + SCALER stub (no RTL yet)"
```

---

## Task 4: Python reference model + tests

**Purpose:** define the canonical NN and bilinear behaviour in Python, byte-accurate to the RTL written in Tasks 7–8. The model is the pixel-accurate ground truth — if RTL disagrees with it at TOLERANCE=0, the RTL is wrong (per CLAUDE.md "Pipeline Harness").

**Files:**
- Create: `py/models/ops/scale2x.py`
- Create: `py/tests/test_scale2x.py`

- [ ] **Step 1: Write `py/models/ops/scale2x.py`**

```python
"""2x spatial upscaler reference model. Mirrors axis_scale2x RTL.

NN mode: each pixel emitted twice horizontally; each row emitted twice.
Bilinear mode: arithmetic-mean horizontal and vertical interpolation,
top-edge row replication, right-edge pixel replication. All averages
are integer (a+b+1)>>1 / (a+b+c+d+2)>>2 to match the RTL bit-exactly.
"""
from __future__ import annotations

import numpy as np


def _nn(image: np.ndarray) -> np.ndarray:
    return np.repeat(np.repeat(image, 2, axis=0), 2, axis=1)


def _avg2(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    return ((a.astype(np.uint16) + b.astype(np.uint16) + 1) >> 1).astype(np.uint8)


def _avg4(a: np.ndarray, b: np.ndarray, c: np.ndarray, d: np.ndarray) -> np.ndarray:
    s = (a.astype(np.uint16) + b.astype(np.uint16)
         + c.astype(np.uint16) + d.astype(np.uint16) + 2)
    return (s >> 2).astype(np.uint8)


def _bilinear(image: np.ndarray) -> np.ndarray:
    h, w, c = image.shape
    out = np.zeros((2 * h, 2 * w, c), dtype=np.uint8)

    # Horizontal expansion: each source row -> 2W out: A, (A+B)/2, B, (B+C)/2, …, X
    even = image                               # shape (h, w, c)
    odd  = np.empty_like(image)
    odd[:, :-1, :] = _avg2(image[:, :-1, :], image[:, 1:, :])
    odd[:, -1,  :] = image[:, -1, :]           # right-edge replicate

    horiz = np.empty((h, 2 * w, c), dtype=np.uint8)
    horiz[:, 0::2, :] = even
    horiz[:, 1::2, :] = odd

    # Vertical expansion: top output row of pair == source row;
    # bottom output row == avg of source row and previous source row
    # (top-edge replicate: row 0's "previous" is row 0).
    top = horiz                                # h source rows
    prev = np.concatenate([horiz[:1, :, :], horiz[:-1, :, :]], axis=0)
    bot = _avg2(top, prev)

    out[0::2, :, :] = top
    out[1::2, :, :] = bot
    return out


def scale2x(image: np.ndarray, mode: str = "bilinear") -> np.ndarray:
    """Return a 2x-upscaled copy of `image`.

    Args:
        image: (H, W, 3) uint8 RGB.
        mode: 'nn' or 'bilinear'.

    Returns:
        (2H, 2W, 3) uint8 RGB. Input is not mutated.
    """
    if image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8:
        raise ValueError(f"scale2x expects (H,W,3) uint8; got {image.shape} {image.dtype}")
    if mode == "nn":
        return _nn(image)
    if mode == "bilinear":
        return _bilinear(image)
    raise ValueError(f"unknown scale2x mode {mode!r}")
```

- [ ] **Step 2: Write `py/tests/test_scale2x.py`**

```python
"""Unit tests for the scale2x reference model.

Two hand-crafted goldens per mode keep the tests legible; the pipeline-level
test_models.py composition checks (added in Task 11) cover larger images.
"""
import numpy as np
import pytest

from models.ops.scale2x import scale2x


def _rgb(*triples):
    return np.array(triples, dtype=np.uint8).reshape(-1, 3)


def test_nn_2x2():
    src = np.array([[[10, 20, 30], [40, 50, 60]],
                    [[70, 80, 90], [100, 110, 120]]], dtype=np.uint8)
    out = scale2x(src, mode="nn")
    expected = np.array([
        [[10, 20, 30], [10, 20, 30], [40, 50, 60], [40, 50, 60]],
        [[10, 20, 30], [10, 20, 30], [40, 50, 60], [40, 50, 60]],
        [[70, 80, 90], [70, 80, 90], [100, 110, 120], [100, 110, 120]],
        [[70, 80, 90], [70, 80, 90], [100, 110, 120], [100, 110, 120]],
    ], dtype=np.uint8)
    assert np.array_equal(out, expected)


def test_bilinear_horizontal_only():
    # Single-row check: vertical interp degenerates to identity.
    src = np.array([[[0, 0, 0], [100, 100, 100], [200, 200, 200]]], dtype=np.uint8)
    out = scale2x(src, mode="bilinear")
    # Even cols: 0, 100, 200; odd cols: (0+100+1)/2=50, (100+200+1)/2=150,
    # right-edge replicate: 200.
    expected_row = np.array([[0, 0, 0], [50, 50, 50], [100, 100, 100],
                             [150, 150, 150], [200, 200, 200], [200, 200, 200]],
                            dtype=np.uint8)
    # Top out row == source; bottom out row == avg(top, prev) == top (top-edge replicate).
    assert np.array_equal(out[0], expected_row)
    assert np.array_equal(out[1], expected_row)


def test_bilinear_2x2_round_half_up():
    src = np.array([[[0, 0, 0], [3, 3, 3]],
                    [[7, 7, 7], [11, 11, 11]]], dtype=np.uint8)
    out = scale2x(src, mode="bilinear")
    # Top output rows replicate source row 0 horizontally:
    #   0, (0+3+1)/2=2, 3, 3 (right replicate)
    # Bottom output row 0 (interp between source row 0 and source row 0): same as top
    # Bottom output row 1 (interp between source row 1 and source row 0):
    #   horiz of row 1: 7, (7+11+1)/2=9, 11, 11
    #   vert avg: (0+7+1)/2=4, (2+9+1)/2=6, (3+11+1)/2=7, (3+11+1)/2=7
    assert out[0, 0, 0] == 0 and out[0, 1, 0] == 2 and out[0, 2, 0] == 3 and out[0, 3, 0] == 3
    assert out[1, 0, 0] == 0 and out[1, 1, 0] == 2 and out[1, 2, 0] == 3 and out[1, 3, 0] == 3
    assert out[2, 0, 0] == 7 and out[2, 1, 0] == 9 and out[2, 2, 0] == 11 and out[2, 3, 0] == 11
    assert out[3, 0, 0] == 4 and out[3, 1, 0] == 6 and out[3, 2, 0] == 7 and out[3, 3, 0] == 7


def test_unknown_mode_raises():
    src = np.zeros((2, 2, 3), dtype=np.uint8)
    with pytest.raises(ValueError):
        scale2x(src, mode="lanczos")


def test_dtype_mismatch_raises():
    with pytest.raises(ValueError):
        scale2x(np.zeros((2, 2, 3), dtype=np.float32), mode="nn")
```

- [ ] **Step 3: Run the tests**

```bash
.venv/bin/python -m pytest py/tests/test_scale2x.py -v
```

Expected: 5 cases pass.

- [ ] **Step 4: Commit**

```bash
git add py/models/ops/scale2x.py py/tests/test_scale2x.py
git commit -m "feat(scale2x): python reference model (nn + bilinear) and unit tests"
```

---

## Task 5: Module skeleton + Makefile wiring

**Purpose:** create the FuseSoC core, an empty SV skeleton (TB will fail against it), and wire the IP into both unit-TB and top-level Makefiles. Doing this first means Tasks 6–8 only edit RTL/TB; Make is a no-op churn target.

**Files:**
- Create: `hw/ip/scaler/scaler.core`
- Create: `hw/ip/scaler/rtl/axis_scale2x.sv` (skeleton — body added in Tasks 7–8)
- Modify: `dv/sim/Makefile`
- Modify: `Makefile` (top)

- [ ] **Step 1: Create the FuseSoC core**

Create `hw/ip/scaler/scaler.core`:

```yaml
CAPI=2:
name: "sparevideo:ip:scaler"
description: "2x spatial upscaler (nearest-neighbour or bilinear) AXIS stage"

filesets:
  files_rtl:
    files:
      - rtl/axis_scale2x.sv
    file_type: systemVerilogSource

targets:
  default:
    filesets:
      - files_rtl
```

- [ ] **Step 2: Create the empty module skeleton**

Create `hw/ip/scaler/rtl/axis_scale2x.sv`:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_scale2x -- 2x spatial upscaler on a 24-bit RGB AXIS.
//
// Compile-time SCALE_FILTER selects nearest-neighbour ("nn") or bilinear
// ("bilinear"). Single line buffer, FSM-driven beat formatter; all
// arithmetic is shift-and-add (no DSPs). Latency: 1 source line.
// Long-term throughput: 4 output beats per input beat (back-pressures
// the upstream to 1/4 the output beat rate).
//
// Edge handling: top-edge row replicate; right-edge pixel replicate.
// H_ACTIVE_IN must be even; the design assumes V_ACTIVE_IN >= 1.

module axis_scale2x #(
    parameter int    H_ACTIVE_IN = sparevideo_pkg::H_ACTIVE,
    parameter int    V_ACTIVE_IN = sparevideo_pkg::V_ACTIVE,    // informational
    parameter string SCALE_FILTER = "bilinear"                  // "nn" | "bilinear"
) (
    input  logic clk_i,
    input  logic rst_n_i,
    axis_if.rx   s_axis,                                        // DATA_W=24, USER_W=1
    axis_if.tx   m_axis                                         // DATA_W=24, USER_W=1
);

    // Placeholder tie-offs so the module elaborates cleanly. Body lands in
    // Tasks 7-8; the unit TB (Task 6) is expected to FAIL against this.
    assign s_axis.tready = 1'b0;
    assign m_axis.tdata  = '0;
    assign m_axis.tvalid = 1'b0;
    assign m_axis.tlast  = 1'b0;
    assign m_axis.tuser  = 1'b0;

    // Touch unused inputs so Verilator stays quiet on the skeleton.
    logic _unused;
    assign _unused = &{1'b0, clk_i, rst_n_i, s_axis.tdata, s_axis.tvalid,
                       s_axis.tlast, s_axis.tuser, m_axis.tready};

endmodule
```

- [ ] **Step 3: Wire `axis_scale2x.sv` into `dv/sim/Makefile`**

Edit `dv/sim/Makefile`:

1. Add the file to `RTL_SRCS` (after `axis_gamma_cor.sv` on line 8):

```makefile
           ../../hw/ip/scaler/rtl/axis_scale2x.sv \
```

2. Add `SCALER` and `SCALE_FILTER` defaults under "Simulation defaults" (after `CFG ?= default` on line 34):

```makefile
SCALER       ?= 0
SCALE_FILTER ?= bilinear
```

3. Add to `VLT_FLAGS` after `-GCFG_NAME='"$(CFG)"'` on line 59:

```makefile
            -GSCALER=$(SCALER) -GSCALE_FILTER='"$(SCALE_FILTER)"' \
```

4. Extend `CONFIG_STAMP` (line 70-74) to include `SCALER` and `SCALE_FILTER`:

```makefile
$(CONFIG_STAMP): FORCE
	@mkdir -p $(VOBJ_DIR)
	@echo "$(WIDTH) $(HEIGHT) $(CFG) $(SCALER) $(SCALE_FILTER)" | cmp -s - $@ || \
	  echo "$(WIDTH) $(HEIGHT) $(CFG) $(SCALER) $(SCALE_FILTER)" > $@
```

5. Add `IP_SCALE2X_RTL` to the per-block list (after `IP_GAMMA_COR_RTL` on line 108):

```makefile
IP_SCALE2X_RTL      = ../../hw/ip/scaler/rtl/axis_scale2x.sv
```

6. Add `test-ip-scale2x` to `.PHONY` (line 43-48) and to the `test-ip` aggregate (line 116):

```makefile
.PHONY: ... test-ip-scale2x
test-ip: ... test-ip-gamma-cor test-ip-scale2x
```

7. Add the actual recipe after the `test-ip-gamma-cor` block (line ~193):

```makefile
# --- axis_scale2x ---
test-ip-scale2x:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_scale2x --Mdir obj_tb_axis_scale2x \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  $(IP_SCALE2X_RTL) ../../hw/ip/scaler/tb/tb_axis_scale2x.sv
	obj_tb_axis_scale2x/Vtb_axis_scale2x
```

8. Add `obj_tb_axis_scale2x` to the `clean` recipe (line 213):

```makefile
clean:
	... obj_tb_axis_hflip obj_tb_axis_gamma_cor obj_tb_axis_scale2x
```

- [ ] **Step 4: Wire knobs into the top `Makefile`**

Edit `Makefile`:

1. Add defaults after line 20 (after `CFG ?= default`):

```makefile
SCALER       ?= 0
SCALE_FILTER ?= bilinear
```

2. Extend `SIM_VARS` (line 35-39):

```makefile
SIM_VARS = SIMULATOR=$(SIMULATOR) \
           WIDTH=$(WIDTH) HEIGHT=$(HEIGHT) FRAMES=$(FRAMES) \
           MODE=$(MODE) CTRL_FLOW=$(CTRL_FLOW) CFG=$(CFG) \
           SCALER=$(SCALER) SCALE_FILTER=$(SCALE_FILTER) \
           INFILE=$(CURDIR)/$(PIPE_INFILE) \
           OUTFILE=$(CURDIR)/$(PIPE_OUTFILE)
```

3. Persist into `dv/data/config.mk` in the `prepare` recipe (line 110-112):

```makefile
	@printf 'WIDTH=%s\nHEIGHT=%s\nFRAMES=%s\nMODE=%s\nCTRL_FLOW=%s\nCFG=%s\nSCALER=%s\nSCALE_FILTER=%s\n' \
	  '$(WIDTH)' '$(HEIGHT)' '$(FRAMES)' '$(MODE)' '$(CTRL_FLOW)' '$(CFG)' \
	  '$(SCALER)' '$(SCALE_FILTER)' \
	  > $(DATA_DIR)/config.mk
```

4. Thread into `verify` and `render` (so the harness sees both knobs):

```makefile
verify:
	cd py && $(HARNESS) verify \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) --ctrl-flow $(CTRL_FLOW) --tolerance $(TOLERANCE) \
		--cfg $(CFG) --scaler $(SCALER) --scale-filter $(SCALE_FILTER)
```

(Same for `render`.)

5. Advertise in `help` (line 74+):

```makefile
	@echo "    SCALER=0|1                       2x scaler instantiated (default 0)"
	@echo "    SCALE_FILTER=nn|bilinear         Filter when SCALER=1 (default bilinear)"
```

6. Add `test-ip-scale2x` to the `.PHONY` list and as a Make target after `test-ip-gamma-cor`:

```makefile
test-ip-scale2x:
	$(MAKE) -C dv/sim test-ip-scale2x SIMULATOR=$(SIMULATOR)
```

- [ ] **Step 5: Build sanity check**

```bash
make lint                                    # SCALER=0 default — must still pass
make run-pipeline CTRL_FLOW=motion CFG=default SOURCE="synthetic:moving_box" \
                  WIDTH=320 HEIGHT=240 FRAMES=4 MODE=binary
```

Expected: lint clean; pipeline PASS at TOLERANCE=0. (`SCALER=0` means `axis_scale2x` is not instantiated — the module skeleton compiles but is dead code at the top level.)

- [ ] **Step 6: Commit**

```bash
git add hw/ip/scaler dv/sim/Makefile Makefile
git commit -m "feat(scale2x): IP skeleton + Makefile wiring (no integration yet)"
```

---

## Task 5b: Add Clock Assumptions section to the arch doc

**Purpose:** Task 2 was written before the two-pix-clk model was adopted. The committed arch doc covers the module's internals correctly but does not mention the clock-domain assumptions correctness depends on. Add a "Clock Assumptions" subsection so the next reader knows what real silicon needs.

**Files:**
- Modify: `docs/specs/axis_scale2x-arch.md`

- [ ] **Step 1: Add the section**

Insert a new subsection (numbered to fit the existing arch-doc ordering — likely after "Timing" / before "Shared Types", or as the last bullet under Timing). Content (verbatim from the design doc §2 + §3.5 wording, adapted to module scope):

```markdown
## Clock Assumptions

This module lives in `clk_dsp`. Correctness depends on the surrounding
top-level wiring, where the input AXIS arrives via a CDC FIFO from
`clk_pix_in_i` and the output AXIS leaves via a CDC FIFO into
`clk_pix_out_i`.

- **Long-term rate balance:** for every input pixel the module emits 4
  output pixels, so `clk_pix_in_i × 4 = clk_pix_out_i` on average over a
  frame. Sustained mismatch (≥ a few hundred ppm over thousands of
  frames) drifts the output FIFO and trips the top-level
  `assert_fifo_out_no_overflow` or `assert_no_output_underrun` SVAs.
- **Per-frame startup:** every input SOF triggers `S_FILL_FIRST_ROW` —
  the module emits no output for ~1 input row of `clk_dsp` time. The
  output VGA controller is in `V_BLANK` for the matching real-time
  interval, so under nominal rate balance no underflow occurs at the
  seam between frames. With the TB porches (`H_BLANK=16, V_BLANK=16`),
  `S_FILL_FIRST_ROW` ≈ 50 µs vs output `V_BLANK` ≈ 430 µs ⇒ ~8× headroom.
- **Phase between input SOF and output VGA frame boundary** is **not**
  enforced by this module. The top-level `vga_started` one-shot aligns
  frame 0 to the first SOF; subsequent frames rely on the rate balance
  plus `V_BLANK_OUT` slack to absorb the per-frame startup delay above.
- **Real-silicon deployments** must satisfy the rate-balance constraint
  through one of: (a) genlock — derive `clk_pix_out_i` from
  `clk_pix_in_i` via a PLL; (b) a frame buffer between the pipeline and
  VGA, with explicit drop/duplicate-frame logic; (c) audit headroom for
  the worst-case crystal tolerance on both clocks. Sim is exempt
  because clock periods are exact.

See also `docs/plans/2026-04-23-pipeline-extensions-design.md` §2
("Clock-stability assumptions") and §3.5 ("Per-frame startup",
"Rate-balance precondition") for the cross-block treatment.
```

- [ ] **Step 2: Commit**

```bash
git add docs/specs/axis_scale2x-arch.md
git commit -m "docs(scale2x): add Clock Assumptions section to arch doc"
```

---

## Task 6: Unit testbench

**Purpose:** drive `axis_scale2x` with hand-crafted patterns, capturing every output beat and comparing against an inline golden. The TB is written before either RTL filter is implemented; running it now FAILs (skeleton ties everything to 0). Tasks 7 and 8 then bring up NN and bilinear, respectively, until the TB PASSes for both `SCALE_FILTER` settings.

**Files:**
- Create: `hw/ip/scaler/tb/tb_axis_scale2x.sv`

- [ ] **Step 1: Write the unit TB**

Create `hw/ip/scaler/tb/tb_axis_scale2x.sv`:

```systemverilog
// Unit testbench for axis_scale2x.
//
// Tests both SCALE_FILTER values; relies on the build invoking verilator
// twice (or two separate `make test-ip-scale2x SCALE_FILTER=nn` runs).
//
// Pattern inventory:
//   t1: 2x2 ramp (NN: pixel-doubled; bilinear: top-edge + right-edge replicate)
//   t2: 4x4 ramp + asymmetric stall (downstream tready toggled per beat)
//   t3: 8x4 with mid-frame downstream stall (5-cycle hold low)

`timescale 1ns / 1ps

module tb_axis_scale2x;

    parameter int    H_ACTIVE_IN = 4;
    parameter int    V_ACTIVE_IN = 4;
    parameter string SCALE_FILTER = "bilinear";   // override per recipe

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();
    axis_if #(.DATA_W(24), .USER_W(1)) m_axis ();

    // drv_* pattern: blocking writes in initial; NBA copy on negedge keeps
    // DUT inputs stable at posedge. Mirrors dv/sv/tb_sparevideo.sv.
    logic [23:0] drv_tdata  = '0;
    logic        drv_tvalid = 1'b0;
    logic        drv_tlast  = 1'b0;
    logic        drv_tuser  = 1'b0;
    logic        drv_m_tready = 1'b1;
    always_ff @(negedge clk) begin
        s_axis.tdata  <= drv_tdata;
        s_axis.tvalid <= drv_tvalid;
        s_axis.tlast  <= drv_tlast;
        s_axis.tuser  <= drv_tuser;
        m_axis.tready <= drv_m_tready;
    end

    axis_scale2x #(
        .H_ACTIVE_IN  (H_ACTIVE_IN),
        .V_ACTIVE_IN  (V_ACTIVE_IN),
        .SCALE_FILTER (SCALE_FILTER)
    ) dut (
        .clk_i   (clk),
        .rst_n_i (rst_n),
        .s_axis  (s_axis),
        .m_axis  (m_axis)
    );

    // Output capture: append every accepted output beat to an array.
    logic [23:0] captured [0:1023];
    int          n_captured = 0;
    always_ff @(posedge clk) begin
        if (m_axis.tvalid && m_axis.tready) begin
            captured[n_captured] <= m_axis.tdata;
            n_captured <= n_captured + 1;
        end
    end

    int errors = 0;

    task automatic drive_pixel(input int row, input int col,
                               input logic [23:0] data, input logic last);
        drv_tdata  = data;
        drv_tvalid = 1'b1;
        drv_tuser  = (row == 0) && (col == 0);
        drv_tlast  = last;
        @(posedge clk);
        while (!s_axis.tready) @(posedge clk);
        drv_tvalid = 1'b0;
        drv_tuser  = 1'b0;
        drv_tlast  = 1'b0;
    endtask

    task automatic check_eq(input int idx, input logic [23:0] expected);
        if (captured[idx] !== expected) begin
            $display("FAIL idx=%0d: got 0x%06x expected 0x%06x", idx, captured[idx], expected);
            errors++;
        end
    endtask

    initial begin : main
        int r, c;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Test 1: 2x2 ramp, no stall. Drive pixels {0x000010, 0x000020,
        //                                            0x000030, 0x000040}.
        // For NN: 16 output beats, each source pixel emitted 4 times.
        // For bilinear: 16 output beats with averaging (golden hand-checked
        // in test_scale2x.py).
        for (r = 0; r < 2; r++) begin
            for (c = 0; c < 2; c++) begin
                drive_pixel(r, c, 24'h000010 + 24'h10 * (2*r + c),
                                  /*last=*/(c == 1));
            end
        end

        // Wait for last output beat: 2*H_IN * 2*V_IN = 16 beats.
        repeat (64) @(posedge clk);

        // Validate first output row of NN. Bilinear pattern is the
        // hand-checked golden from test_scale2x.py::test_bilinear_2x2_round_half_up.
        if (SCALE_FILTER == "nn") begin
            check_eq(0, 24'h000010); check_eq(1, 24'h000010);
            check_eq(2, 24'h000020); check_eq(3, 24'h000020);
            check_eq(4, 24'h000010); check_eq(5, 24'h000010);
            check_eq(6, 24'h000020); check_eq(7, 24'h000020);
            // Bottom pair of rows (source row 1).
            check_eq(8,  24'h000030); check_eq(9,  24'h000030);
            check_eq(10, 24'h000040); check_eq(11, 24'h000040);
        end else begin
            // Bilinear top output row: source row 0 horiz expanded.
            // 0x10, (0x10+0x20+1)>>1 = 0x18, 0x20, 0x20 (right replicate).
            check_eq(0, 24'h000010);
            check_eq(1, 24'h000018);
            check_eq(2, 24'h000020);
            check_eq(3, 24'h000020);
            // Bottom output row of pair 0 == avg(top, prev=top) == top
            // (top-edge replicate).
            check_eq(4, 24'h000010);
            check_eq(5, 24'h000018);
            check_eq(6, 24'h000020);
            check_eq(7, 24'h000020);
            // Top output row of pair 1 == source row 1 horiz expanded.
            // 0x30, (0x30+0x40+1)>>1 = 0x38, 0x40, 0x40.
            check_eq(8,  24'h000030);
            check_eq(9,  24'h000038);
            check_eq(10, 24'h000040);
            check_eq(11, 24'h000040);
            // Bottom row of pair 1 == avg(source row 1 horiz, source row 0 horiz):
            // (0x10+0x30+1)>>1 = 0x20, (0x18+0x38+1)>>1 = 0x28,
            // (0x20+0x40+1)>>1 = 0x30, (0x20+0x40+1)>>1 = 0x30.
            check_eq(12, 24'h000020);
            check_eq(13, 24'h000028);
            check_eq(14, 24'h000030);
            check_eq(15, 24'h000030);
        end

        // Test 2: asymmetric stall. Toggle drv_m_tready every output beat
        // and replay test 1's input. This proves the FSM correctly holds the
        // input while emitting the two output rows.
        n_captured = 0;
        fork
            begin : stall_driver
                int t;
                for (t = 0; t < 32; t++) begin
                    drv_m_tready = (t & 1);
                    @(posedge clk);
                end
                drv_m_tready = 1'b1;
            end
            begin : input_driver
                rst_n = 0; @(posedge clk); rst_n = 1; @(posedge clk);
                for (r = 0; r < 2; r++) begin
                    for (c = 0; c < 2; c++) begin
                        drive_pixel(r, c, 24'h000010 + 24'h10 * (2*r + c),
                                          /*last=*/(c == 1));
                    end
                end
            end
        join

        repeat (64) @(posedge clk);

        // Re-check the first 16 captured beats — the stalled run must
        // match the un-stalled run beat-for-beat.
        // (Same expectations as Test 1.)
        if (SCALE_FILTER == "nn") begin
            check_eq(0, 24'h000010);
            check_eq(15, 24'h000040);
        end else begin
            check_eq(0, 24'h000010);
            check_eq(15, 24'h000030);
        end

        if (errors == 0) $display("PASS");
        else             $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Watchdog");
    end

endmodule
```

- [ ] **Step 2: Run the TB against the skeleton — must FAIL**

```bash
make test-ip-scale2x SCALE_FILTER=nn
```

Expected: FAIL ("got 0x000000 expected 0x000010" — the skeleton ties everything to 0).

- [ ] **Step 3: Commit the failing TB**

```bash
git add hw/ip/scaler/tb/tb_axis_scale2x.sv
git commit -m "test(scale2x): unit TB skeleton (currently fails — RTL stub)"
```

---

## Task 7: NN-mode RTL implementation

**Purpose:** bring up the simpler filter mode first. After this task, `make test-ip-scale2x SCALE_FILTER=nn` PASSes; `SCALE_FILTER=bilinear` still FAILs.

**Files:**
- Modify: `hw/ip/scaler/rtl/axis_scale2x.sv`

- [ ] **Step 1: Replace the skeleton with the NN datapath**

Use the `rtl-writing` skill. Implement the FSM and beat formatter as described in the arch doc §5.2-5.3, generated only when `SCALE_FILTER == "nn"`. Key behaviours (verbatim from the skeleton header):
- One 320×24-bit (parameterised by `H_ACTIVE_IN`) line buffer.
- FSM: `S_FILL_FIRST_ROW` (load on SOF, no output) → `S_EMIT` (steady state).
- In `S_EMIT`: for each input pixel `cur_pix_q`, emit 4 output beats: `(top, even)`, `(top, odd)`, `(bot, even)`, `(bot, odd)`. NN means `even == odd == cur_pix_q`, `bot == top` (after the line buffer's row N is the same as the buffered N-1 because we wrote it just-now).
- Hold `s_axis.tready` low while emitting the 4 output beats for the previously-accepted pixel.
- `m_axis.tuser` = (first SOF since reset) && (out_phase == TOP) && (out_col == 0).
- `m_axis.tlast` = (out_col == 2*H_ACTIVE_IN - 1).

Use a `generate if (SCALE_FILTER == "nn") begin ... end else if (SCALE_FILTER == "bilinear") begin ... end` block at the top of the module body to keep the two implementations syntactically separated. The `bilinear` branch in this task is still the skeleton tie-offs.

- [ ] **Step 2: Run the NN unit TB**

```bash
make test-ip-scale2x SCALE_FILTER=nn
```

Expected: PASS.

- [ ] **Step 3: Lint cleanly**

```bash
make lint
```

Expected: lint clean.

- [ ] **Step 4: Commit**

```bash
git add hw/ip/scaler/rtl/axis_scale2x.sv
git commit -m "feat(scale2x): NN-mode datapath — pixel- and row-doubling"
```

---

## Task 8: Bilinear-mode RTL implementation

**Purpose:** implement the second filter mode. After this task, `make test-ip-scale2x SCALE_FILTER=bilinear` PASSes; `nn` still PASSes.

**Files:**
- Modify: `hw/ip/scaler/rtl/axis_scale2x.sv`

- [ ] **Step 1: Replace the bilinear branch's skeleton**

Datapath (referencing the arch doc §4 and 5):
- Three pixel registers: `cur_pix_q` (latest accepted input), `prev_pix_q` (previous-column same-row), `top_pix_q[H_ACTIVE_IN]`-style line buffer holding the previous source row's pixels.
- Per output beat:
  - **Top-row even** = `cur_pix_q` (same source pixel).
  - **Top-row odd** = `(cur_pix_q + next_pix + 1) >> 1` per channel (where `next_pix` is the upcoming `s_axis.tdata` — read combinationally so the FSM can hold the input one extra cycle to compute this; alternative: latch a 2-deep window). Right-edge: replicate `cur_pix_q` (no `next_pix`).
  - **Bot-row even** = `(cur_pix_q + top_pix_q[col] + 1) >> 1`.
  - **Bot-row odd** = `(cur_pix_q + next_pix + top_pix_q[col] + top_pix_q[col+1] + 2) >> 2`. Right-edge: replicate via `(cur_pix_q + top_pix_q[col] + 1) >> 1`.
- Top-edge replicate: on the very first source row, `top_pix_q[col] == cur_pix_q[col]` for all columns (initialise the line buffer from the first row's pixels as they're written).
- Per-channel arithmetic: do R, G, B independently with three `+1`/`+2` rounding constants in 9-bit / 10-bit adder lanes.
- Backpressure: same as NN — hold `s_axis.tready` low while the 4 output beats are emitted. The 2-tap `next_pix` lookup means the FSM must hold the **next** input pixel under stall; track this with a `peeked` flag (input accepted but not yet "consumed" because we need `cur_pix_q` to finish emitting first).

Lint cleanly: no `WIDTHEXPAND` in the rounding adders (cast operands explicitly); no `ALWCOMBORDER` in the per-channel sums.

- [ ] **Step 2: Run both filter modes**

```bash
make test-ip-scale2x SCALE_FILTER=nn
make test-ip-scale2x SCALE_FILTER=bilinear
```

Expected: both PASS.

- [ ] **Step 3: Lint cleanly**

```bash
make lint
```

Expected: lint clean.

- [ ] **Step 4: Commit**

```bash
git add hw/ip/scaler/rtl/axis_scale2x.sv
git commit -m "feat(scale2x): bilinear-mode datapath — 2-tap and 4-tap shift-add"
```

---

## Task 9: Top-level integration — split clk_pix port, instantiate scaler

**Purpose:** Two changes land together because they're tightly coupled:
1. Split `clk_pix_i` / `rst_pix_n_i` into `clk_pix_in_i` / `rst_pix_in_n_i` (input AXIS side) and `clk_pix_out_i` / `rst_pix_out_n_i` (VGA controller side). Re-wire the input async FIFO to use `clk_pix_in`, and the output async FIFO + VGA controller to use `clk_pix_out`. Update SVA clocking.
2. Instantiate `u_scale2x` between `u_gamma_cor.m_axis` and `u_fifo_out.s_axis` when `SCALER=1`. Bump `OUT_FIFO_DEPTH`. Remove the temporary `lint_off UNUSEDPARAM` pragma around `SCALE_FILTER` (added in Task 3).

After this task, the DUT signature has two pix-clk ports. With `SCALER=0`, the caller ties `clk_pix_in_i = clk_pix_out_i` and the output is byte-identical to the Task-1 goldens. With `SCALER=1`, the caller drives them at 1:4 ratio.

**Files:**
- Modify: `hw/top/sparevideo_top.sv`
- Modify: `hw/ip/scaler/scaler.core` (add `depend:` if/when needed for standalone builds; not required for sparevideo_top.core's lint path).

- [ ] **Step 1: Split the pix-clk port and reset**

Edit `hw/top/sparevideo_top.sv` port list:

```systemverilog
    // ---- Clocks & resets -------------------------------------------
    input  logic        clk_pix_in_i,    // input-rate pixel clock (sensor / source)
    input  logic        clk_pix_out_i,   // output-rate pixel clock (VGA / display)
    input  logic        clk_dsp_i,       // 100 MHz processing clock (CDC FIFOs cross to here)
    input  logic        rst_pix_in_n_i,  // active-low sync reset, clk_pix_in domain
    input  logic        rst_pix_out_n_i, // active-low sync reset, clk_pix_out domain
    input  logic        rst_dsp_n_i,     // active-low sync reset, clk_dsp domain
```

Remove the existing `clk_pix_i` and `rst_pix_n_i`.

- [ ] **Step 2: Re-wire the input async FIFO to `clk_pix_in_*`**

In the existing `axis_async_fifo_ifc u_fifo_in (...)` instantiation, change `.s_clk (clk_pix_i)` → `.s_clk (clk_pix_in_i)` and `.s_rst_n (rst_pix_n_i)` → `.s_rst_n (rst_pix_in_n_i)`. The `.m_clk (clk_dsp_i)` / `.m_rst_n (rst_dsp_n_i)` stay unchanged.

- [ ] **Step 3: Re-wire the output async FIFO and VGA controller to `clk_pix_out_*`**

In `axis_async_fifo_ifc u_fifo_out (...)`, change `.m_clk (clk_pix_i)` → `.m_clk (clk_pix_out_i)` and `.m_rst_n (rst_pix_n_i)` → `.m_rst_n (rst_pix_out_n_i)`.

In the VGA reset gating (the `vga_started` always_ff and the `vga_rst_n`/`pix_out_tready` assigns), change every `clk_pix_i` → `clk_pix_out_i` and `rst_pix_n_i` → `rst_pix_out_n_i`. The VGA controller instance also takes `.clk_i (clk_pix_out_i)`.

- [ ] **Step 4: Update the SVAs**

The six SVAs around `assert_no_input_backpressure` / `assert_no_output_underrun` / `assert_fifo_in_*` / `assert_fifo_out_*` need to clock on the right domain:

| SVA | New clock | New disable iff |
|---|---|---|
| `assert_no_input_backpressure` | `clk_pix_in_i` | `!rst_pix_in_n_i` |
| `assert_no_output_underrun` | `clk_pix_out_i` | `!rst_pix_out_n_i || sva_drain_mode` |
| `assert_fifo_in_not_full` | `clk_pix_in_i` | `!rst_pix_in_n_i` |
| `assert_fifo_in_no_overflow` | `clk_pix_in_i` | `!rst_pix_in_n_i` |
| `assert_fifo_out_not_full` | `clk_dsp_i` | unchanged |
| `assert_fifo_out_no_overflow` | `clk_dsp_i` | unchanged |

- [ ] **Step 5: Insert the `generate if` block between gamma and the output FIFO**

Replace the current direct connection `u_gamma_cor.m_axis (gamma_to_pix_out)` → `u_fifo_out.s_axis (gamma_to_pix_out)` with:

```systemverilog
    // gamma_to_pix_out: u_gamma_cor.m_axis -> (scale2x or fifo_out).s_axis.
    axis_if #(.DATA_W(24), .USER_W(1)) gamma_to_pix_out ();

    // scale2x_to_pix_out: drives u_fifo_out.s_axis in both SCALER=0 and SCALER=1 cases.
    axis_if #(.DATA_W(24), .USER_W(1)) scale2x_to_pix_out ();

    axis_gamma_cor u_gamma_cor (
        .clk_i    (clk_dsp_i),
        .rst_n_i  (rst_dsp_n_i),
        .enable_i (CFG.gamma_en),
        .s_axis   (proc_axis),
        .m_axis   (gamma_to_pix_out)
    );

    generate
        if (SCALER == 1) begin : g_scale2x
            axis_scale2x #(
                .H_ACTIVE_IN  (H_ACTIVE),
                .V_ACTIVE_IN  (V_ACTIVE),
                .SCALE_FILTER (SCALE_FILTER)
            ) u_scale2x (
                .clk_i   (clk_dsp_i),
                .rst_n_i (rst_dsp_n_i),
                .s_axis  (gamma_to_pix_out),
                .m_axis  (scale2x_to_pix_out)
            );
        end else begin : g_no_scale2x
            // SCALER=0: gamma feeds the FIFO directly. Bridge the two
            // interface bundles with explicit assigns so the FIFO sees
            // gamma_to_pix_out's signals on the scale2x_to_pix_out
            // handle (keeps the FIFO instantiation single-form).
            assign scale2x_to_pix_out.tdata    = gamma_to_pix_out.tdata;
            assign scale2x_to_pix_out.tvalid   = gamma_to_pix_out.tvalid;
            assign scale2x_to_pix_out.tlast    = gamma_to_pix_out.tlast;
            assign scale2x_to_pix_out.tuser    = gamma_to_pix_out.tuser;
            assign gamma_to_pix_out.tready     = scale2x_to_pix_out.tready;
        end
    endgenerate
```

In `u_fifo_out`, change `.s_axis (gamma_to_pix_out)` → `.s_axis (scale2x_to_pix_out)`.

- [ ] **Step 6: Bump `OUT_FIFO_DEPTH` when `SCALER=1`**

Replace the existing `localparam int OUT_FIFO_DEPTH = 256;` declaration:

```systemverilog
    // SCALER=1: scaler emits 4 output beats per input pixel in bursts at
    // clk_dsp rate, while VGA drains at clk_pix_out (~clk_dsp/4). Per
    // output line of 640 pixels, the FIFO accumulates ~3W ≈ 480 entries
    // at peak. 1024 covers that with the verilog-axis output pipeline
    // (~16 in-flight) plus ~50% headroom.
    localparam int OUT_FIFO_DEPTH = (SCALER == 1) ? 1024 : 256;
```

Also delete the now-stale comment block referring to "future SCALER=1 ... requires revisiting".

- [ ] **Step 7: Remove the lint_off pragma around `SCALE_FILTER`**

Task 3 wrapped the `SCALE_FILTER` parameter in `/* verilator lint_off UNUSEDPARAM */ ... /* verilator lint_on UNUSEDPARAM */`. Now that `SCALE_FILTER` is consumed by the `g_scale2x` generate block, remove both pragma lines.

- [ ] **Step 8: Lint + sanity sim**

The TB still drives `clk_pix_i`/`rst_pix_n_i` until Task 10 — so the SCALER=0 sanity sim won't compile yet. **Skip the sim/cmp gate in this task.** Just run lint to confirm RTL is well-formed:

```bash
make lint
```

Expected: lint clean.

(If lint passes but the TB-driven `make sim` fails because of the renamed ports, that's expected. Task 10 fixes the TB next.)

- [ ] **Step 9: Commit**

```bash
git add hw/top/sparevideo_top.sv
git commit -m "feat(scale2x): split clk_pix into in/out + integrate u_scale2x under SCALER"
```

---

## Task 10: Testbench rework — split clk_pix, output-dim capture

**Purpose:** with the two-pix-clk DUT signature from Task 9, the TB needs two pix-clk generators (running at the right period ratio for `SCALER`), output capture sized to output dims, and the file header reflecting output dims. **No input pacing math is required** — rate balance is established intrinsically by the clock-period ratio. Also re-add the `-GSCALER` / `-GSCALE_FILTER` flags to `dv/sim/Makefile`'s `VLT_FLAGS` (deferred from Task 5) now that `tb_sparevideo` exposes those parameters.

**Files:**
- Modify: `dv/sv/tb_sparevideo.sv`
- Modify: `dv/sim/Makefile` (re-add `-G` flags to `VLT_FLAGS`)

- [ ] **Step 1: Add `SCALER` / `SCALE_FILTER` parameters; resolve output dims**

Edit `dv/sv/tb_sparevideo.sv:23-27`:

```systemverilog
module tb_sparevideo #(
    parameter int    H_ACTIVE     = 320,
    parameter int    V_ACTIVE     = 240,
    parameter string CFG_NAME     = "default",
    parameter int    SCALER       = 0,
    parameter string SCALE_FILTER = "bilinear"
);
```

Add output-dim `localparam`s alongside the existing blanking block (~line 44):

```systemverilog
    localparam int H_ACTIVE_OUT = (SCALER == 1) ? 2 * H_ACTIVE : H_ACTIVE;
    localparam int V_ACTIVE_OUT = (SCALER == 1) ? 2 * V_ACTIVE : V_ACTIVE;
```

- [ ] **Step 2: Replace single pix-clk with two generators**

Today the TB has:
```systemverilog
    localparam int CLK_PIX_PERIOD = 40;   // 25 MHz
    localparam int CLK_DSP_PERIOD = 10;
    logic clk_pix;
    initial clk_pix = 0;
    always #(CLK_PIX_PERIOD/2) clk_pix = ~clk_pix;
```

Replace with two periods and two generators. The output period is fixed at the standard VGA rate (40 ns ≈ 25 MHz — close enough to the standard 25.175 MHz for sim purposes); the input period scales with `SCALER`:

```systemverilog
    localparam int CLK_PIX_OUT_PERIOD = 40;                                     // 25 MHz
    localparam int CLK_PIX_IN_PERIOD  = (SCALER == 1) ? 4 * CLK_PIX_OUT_PERIOD  // 6.25 MHz when SCALER=1
                                                      :     CLK_PIX_OUT_PERIOD; // 25 MHz when SCALER=0
    localparam int CLK_DSP_PERIOD     = 10;                                     // 100 MHz, unchanged

    logic clk_pix_in;
    logic clk_pix_out;
    logic clk_dsp;

    initial clk_pix_in  = 0;
    always #(CLK_PIX_IN_PERIOD/2)  clk_pix_in  = ~clk_pix_in;

    initial clk_pix_out = 0;
    always #(CLK_PIX_OUT_PERIOD/2) clk_pix_out = ~clk_pix_out;

    initial clk_dsp = 0;
    always #(CLK_DSP_PERIOD/2)     clk_dsp = ~clk_dsp;
```

Resets follow the same split:

```systemverilog
    logic rst_pix_in_n;
    logic rst_pix_out_n;
    logic rst_dsp_n;
```

Anywhere the existing TB references `clk_pix` for input drive (`drv_*` always_ff at negedge, the input `@(posedge clk_pix)` waits in the row/col loops, the H_BLANK / V_BLANK `repeat` blocks), use `clk_pix_in`. Anywhere it references `clk_pix` for output capture (the `dut_active_d` register, the `always @(negedge clk_pix)` capture block), use `clk_pix_out`.

- [ ] **Step 3: Pass `SCALER` / `SCALE_FILTER` and the new clocks/resets to the DUT**

Update the `sparevideo_top` instantiation:

```systemverilog
    sparevideo_top #(
        .H_ACTIVE      (H_ACTIVE),
        .H_FRONT_PORCH (H_FRONT_PORCH),
        .H_SYNC_PULSE  (H_SYNC_PULSE),
        .H_BACK_PORCH  (H_BACK_PORCH),
        .V_ACTIVE      (V_ACTIVE),
        .V_FRONT_PORCH (V_FRONT_PORCH),
        .V_SYNC_PULSE  (V_SYNC_PULSE),
        .V_BACK_PORCH  (V_BACK_PORCH),
        .SCALER        (SCALER),
        .CFG           (CFG),
        .SCALE_FILTER  (SCALE_FILTER)
    ) u_dut (
        .clk_pix_in_i    (clk_pix_in),
        .clk_pix_out_i   (clk_pix_out),
        .clk_dsp_i       (clk_dsp),
        .rst_pix_in_n_i  (rst_pix_in_n),
        .rst_pix_out_n_i (rst_pix_out_n),
        .rst_dsp_n_i     (rst_dsp_n),
        // remaining ports unchanged
        ...
    );
```

In the reset-release sequence, replace the single `rst_pix_n <= 0` / `rst_pix_n <= 1` block with two parallel resets, both deasserted on the same `clk_pix_out` edge for determinism:

```systemverilog
            rst_pix_in_n  <= 0;
            rst_pix_out_n <= 0;
            rst_dsp_n     <= 0;
            repeat (10) @(posedge clk_pix_out);
            rst_pix_in_n  <= 1;
            rst_pix_out_n <= 1;
            rst_dsp_n     <= 1;
            @(posedge clk_pix_out);
```

- [ ] **Step 4: Output-file header writes output dims**

In the binary-mode header write block (~line 244):

```systemverilog
        if (cfg_mode != "text") begin
            integer hdr_w, hdr_h;
            hdr_w = (SCALER == 1) ? (2 * cfg_width)  : cfg_width;
            hdr_h = (SCALER == 1) ? (2 * cfg_height) : cfg_height;
            $fwrite(fd_out, "%c%c%c%c",
                hdr_w[7:0], hdr_w[15:8], hdr_w[23:16], hdr_w[31:24]);
            $fwrite(fd_out, "%c%c%c%c",
                hdr_h[7:0], hdr_h[15:8], hdr_h[23:16], hdr_h[31:24]);
            $fwrite(fd_out, "%c%c%c%c",
                cfg_frames[7:0], cfg_frames[15:8],
                cfg_frames[23:16], cfg_frames[31:24]);
        end
```

- [ ] **Step 5: Capture loop uses output dims**

Define helpers near the existing `cfg_width` declaration (~line 53):

```systemverilog
    integer cfg_out_width  = 320;
    integer cfg_out_height = 240;
```

After plusarg parsing (~line 200):

```systemverilog
        cfg_out_width  = (SCALER == 1) ? (2 * cfg_width)  : cfg_width;
        cfg_out_height = (SCALER == 1) ? (2 * cfg_height) : cfg_height;
```

In the capture-loop's column-reset comparison and the expected-pixels comparison after the frame loop, replace `cfg_width` / `cfg_height` with `cfg_out_width` / `cfg_out_height`. Crucially, the always block sampling output should be `always @(negedge clk_pix_out)`, not `clk_pix`.

- [ ] **Step 6: Watchdog uses output dims (and slower input clock)**

The watchdog timeout (~line 475) bounds wall-clock time, but the TB's `#(CLK_PIX_PERIOD * timeout_clocks)` was sized for the single-clock model. With the slower input clock, the input-side row/col `@(posedge clk_pix_in)` waits take longer. Compute the timeout in the slowest of the three clocks:

```systemverilog
    timeout_clocks = (cfg_out_width + H_BLANK) * (cfg_out_height + V_BLANK)
                   * (cfg_frames + 4);
    #(CLK_PIX_IN_PERIOD * timeout_clocks);   // worst case is the slow input clock
```

(`CLK_PIX_IN_PERIOD = 4 × CLK_PIX_OUT_PERIOD` when SCALER=1, so this gives 4× sim wall-clock margin vs the single-clock formula.)

- [ ] **Step 7: Re-add `-GSCALER` / `-GSCALE_FILTER` to `dv/sim/Makefile` `VLT_FLAGS`**

Now that `tb_sparevideo` declares `SCALER` and `SCALE_FILTER` parameters (Step 1), the deferred `-G` flags from Task 5 can land. Edit `dv/sim/Makefile` `VLT_FLAGS` block (around the existing `-GH_ACTIVE` / `-GV_ACTIVE` / `-GCFG_NAME` flags):

```makefile
            -GSCALER=$(SCALER) -GSCALE_FILTER='"$(SCALE_FILTER)"' \
```

Confirm the `CONFIG_STAMP` rule still includes both knobs (it does — Task 5 wired that up).

- [ ] **Step 8: Smoke-test SCALER=0 (must remain byte-identical)**

```bash
make run-pipeline CTRL_FLOW=motion CFG=default SOURCE="synthetic:moving_box" \
                  WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary SCALER=0
cmp dv/data/output.bin renders/golden/motion__default__pre-scaler.bin
```

Expected: PASS at TOLERANCE=0; `cmp` exits 0. (When SCALER=0, the two TB pix-clks tick in lockstep at the same period — equivalent to the old single-clk path.)

- [ ] **Step 9: Smoke-test SCALER=1 NN**

```bash
make compile SCALER=1 SCALE_FILTER=nn WIDTH=320 HEIGHT=240
make sim     SCALER=1 SCALE_FILTER=nn WIDTH=320 HEIGHT=240 \
             CTRL_FLOW=passthrough FRAMES=2 MODE=binary
xxd dv/data/output.bin | head -1
```

Expected: sim runs to completion (no underrun/overflow assertion); first 12 bytes decode as `(0x280, 0x1E0, 0x2) = (640, 480, 2)`. End-to-end verify lands in Task 12.

- [ ] **Step 10: Commit**

```bash
git add dv/sv/tb_sparevideo.sv dv/sim/Makefile
git commit -m "test(scale2x): split TB pix-clk + output-dim capture for SCALER=1"
```

---

## Task 11: Harness + dispatcher

**Purpose:** make the Python verify/render path aware of the scaler so that `make run-pipeline SCALER=1` end-to-ends.

**Files:**
- Modify: `py/harness.py`
- Modify: `py/models/__init__.py`

- [ ] **Step 1: Add `--scaler` and `--scale-filter` flags**

Edit `py/harness.py`. Extend `common` to accept the flags, but `prepare` only writes input dims; the output dims are derived in `verify`/`render`:

```python
    common.add_argument("--scaler", type=int, default=0, choices=[0, 1])
    common.add_argument("--scale-filter", default="bilinear", choices=["nn", "bilinear"])
```

In `cmd_verify` and `cmd_render`, thread `scaler=bool(args.scaler), scale_filter=args.scale_filter` into `run_model(...)`.

- [ ] **Step 2: Update `_load_input_output` to handle asymmetric dims**

The output file (binary) has its own 12-byte header; in binary mode this already works (`_read_binary` reads dims from the header). In text mode, add an `out_width`/`out_height` resolution that doubles the input dims when `args.scaler == 1`:

```python
    if args.mode == "text":
        # input dims from meta.json; output dims = input * (2 if scaler else 1)
        in_w, in_h, n = _resolve_dims(args)
        out_w = 2 * in_w if getattr(args, "scaler", 0) else in_w
        out_h = 2 * in_h if getattr(args, "scaler", 0) else in_h
        input_frames = read_frames(args.input, mode="text", width=in_w, height=in_h, num_frames=n)
        output_frames = read_frames(args.output, mode="text", width=out_w, height=out_h, num_frames=n)
    else:
        input_frames = read_frames(args.input, mode="binary")
        output_frames = read_frames(args.output, mode="binary")
```

- [ ] **Step 3: Compose scaler in the dispatcher**

Edit `py/models/__init__.py`:

```python
from models.ops.scale2x import scale2x as _scale2x
from models.ops.gamma_cor import gamma_cor as _gamma_cor
from models.ops.hflip     import hflip      as _hflip
# ... existing imports ...

def run_model(ctrl_flow: str, frames: list, **kwargs) -> list:
    if ctrl_flow not in _MODELS:
        raise ValueError(...)
    hflip_en     = kwargs.pop("hflip_en", False)
    gamma_en     = kwargs.pop("gamma_en", False)
    scaler       = kwargs.pop("scaler", False)
    scale_filter = kwargs.pop("scale_filter", "bilinear")
    if hflip_en:
        frames = [_hflip(f) for f in frames]
    out = _MODELS[ctrl_flow](frames, **kwargs)
    if gamma_en:
        out = [_gamma_cor(f) for f in out]
    if scaler:
        out = [_scale2x(f, mode=scale_filter) for f in out]
    return out
```

- [ ] **Step 4: Run the harness unit tests**

```bash
.venv/bin/python -m pytest py/tests/test_scale2x.py py/tests/test_models.py -v
```

Expected: all green. (`test_models.py` doesn't yet drive `scaler`; the new kwargs are ignored when omitted.)

- [ ] **Step 5: Commit**

```bash
git add py/harness.py py/models/__init__.py
git commit -m "feat(scale2x): harness + dispatcher accept scaler + scale_filter"
```

---

## Task 12: Integration regression matrix

**Purpose:** prove the new path works end-to-end across every (control flow × profile × filter) pairing the design budgets for. This is the hard quality gate — anything failing here blocks the PR.

**Files:**
- (no source changes — this is a verification-only task)

- [ ] **Step 1: SCALER=0 byte-identity sweep**

For every (FLOW × PROF) in {`passthrough,motion,mask,ccl_bbox`} × {`default,default_hflip`}:

```bash
make run-pipeline CTRL_FLOW=$FLOW CFG=$PROF SCALER=0 SOURCE="synthetic:moving_box" \
                  WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
cmp dv/data/output.bin renders/golden/${FLOW}__${PROF}__pre-scaler.bin
```

Expected: each invocation PASSes verify; each `cmp` exits 0.

- [ ] **Step 2: SCALER=1 NN sweep**

Same 8-cell grid, but `SCALER=1 SCALE_FILTER=nn`. Verify reports PASS at TOLERANCE=0 (the Python model produces the same NN-doubled output as the RTL).

- [ ] **Step 3: SCALER=1 bilinear sweep**

Same grid, `SCALER=1 SCALE_FILTER=bilinear`. Verify reports PASS at TOLERANCE=0.

- [ ] **Step 4: Spot-check on a non-trivial source**

```bash
make run-pipeline SOURCE="synthetic:noisy_moving_box" CTRL_FLOW=motion \
                  CFG=default SCALER=1 SCALE_FILTER=bilinear FRAMES=8 MODE=binary
make run-pipeline SOURCE="synthetic:multi_speed" CTRL_FLOW=ccl_bbox \
                  CFG=default SCALER=1 SCALE_FILTER=bilinear FRAMES=8 MODE=binary
```

Expected: both PASS at TOLERANCE=0; `renders/...png` is a 4-row grid (input/output/expected) where output dims are 640×480.

- [ ] **Step 5: Render comparison PNG for visual review**

```bash
make run-pipeline SCALER=1 SCALE_FILTER=bilinear CTRL_FLOW=motion FRAMES=4 MODE=binary
ls -lh renders/synthetic-moving-box__width=320__height=240__frames=4__ctrl-flow=motion__cfg=default.png
```

Expected: PNG file exists. (Manual visual review — should look like a 2× upscale of the existing motion output, with smoother edges in bilinear vs blocky in nn.)

- [ ] **Step 6: Per-block unit-TB regression**

```bash
make test-ip
```

Expected: all per-block TBs PASS (including `test-ip-scale2x` for both `SCALE_FILTER` defaults — the recipe runs once with the default `bilinear`; the `nn` variant is exercised in Task 7).

---

## Task 13: Documentation updates

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/specs/sparevideo-top-arch.md`

- [ ] **Step 1: Add `axis_scale2x` to README block table + new build options**

Append to the IP block table:

```
| axis_scale2x | hw/ip/scaler/rtl/ | 2× spatial upscaler (NN or bilinear); compile-time |
```

Add `SCALER` and `SCALE_FILTER` to the build-options list:

```
| SCALER       | 0       | 0/1            | 2× upscaler instantiated (compile-time) |
| SCALE_FILTER | bilinear | nn/bilinear   | Filter mode when SCALER=1               |
```

- [ ] **Step 2: Add to CLAUDE.md "Build Commands" and "Project Structure"**

Under "Build Commands":

```bash
make run-pipeline SCALER=0                          # 320x240 output (default, byte-identical to pre-scaler runs)
make run-pipeline SCALER=1 SCALE_FILTER=nn          # 640x480 output, pixel-doubled
make run-pipeline SCALER=1 SCALE_FILTER=bilinear    # 640x480 output, bilinear
```

Under "Project Structure":

```
- `hw/ip/scaler/rtl/` — 2× spatial upscaler (axis_scale2x: NN + bilinear modes; instantiated under SCALER=1 generate gate; OUT_FIFO_DEPTH bumps to 1024)
```

- [ ] **Step 3: Update the top-level architecture doc**

Edit `docs/specs/sparevideo-top-arch.md`. Insert `axis_scale2x` between `axis_gamma_cor` and `axis_async_fifo (out)` in the block diagram and the post-mux text. Add a paragraph noting:

> **Output resolution**: `H_ACTIVE_OUT/V_ACTIVE_OUT` come from `sparevideo_pkg::*_OUT_2X` when `SCALER=1`; otherwise they equal the input dims. The VGA controller uses the OUT dims; the input AXIS, motion pipeline, and gamma stage all stay at the input dims. The TB drives input frames at input dims and captures output at output dims.

- [ ] **Step 4: Lint**

```bash
make lint
```

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md docs/specs/sparevideo-top-arch.md
git commit -m "docs(scale2x): document SCALER/SCALE_FILTER knobs and pipeline integration"
```

---

## Task 14: Cleanup, squash, PR

**Files:**
- Modify: `py/models/ops/scale2x.py` (delete unused `_avg4` helper).
- Delete: `renders/golden/*__pre-scaler.bin` (gitignored; manual cleanup).

- [ ] **Step 1: Trim unused `_avg4` helper from the scale2x model**

Task 4 left an `_avg4` helper that turned out to be unused (the bilinear path decomposes into two `_avg2` calls). Delete the function definition. Re-run the unit tests to confirm nothing else referenced it:

```bash
.venv/bin/python -m pytest py/tests/test_scale2x.py py/tests/test_models.py -v
```

Expected: all green.

- [ ] **Step 2: Remove local goldens**

```bash
rm -f renders/golden/*__pre-scaler.bin
```

- [ ] **Step 3: Move the design+plan into the archive**

Per CLAUDE.md "TODO after each major change":

```bash
git mv docs/plans/2026-04-27-axis-scale2x-plan.md docs/plans/old/
# the design doc 2026-04-23-pipeline-extensions-design.md stays in place;
# it covers six plans, not just this one.
```

- [ ] **Step 4: Verify the branch is clean**

```bash
git status
git log --oneline origin/main..HEAD
```

Expected: working tree clean; commit log shows the per-task commits from Tasks 2–13 plus this Task-14 cleanup. Confirm none of them touch unrelated files (CLAUDE.md notes that small adjacent fixes can ride along, but anything tangential should already be on its own branch).

- [ ] **Step 5: Squash to a single commit**

```bash
git reset --soft origin/main
git commit -m "$(cat <<'EOF'
feat(scale2x): 2x upscaler stage with NN and bilinear modes

Adds axis_scale2x at the post-gamma tail of the proc_clk pipeline,
gated on a new compile-time SCALER knob. SCALE_FILTER selects between
NN (pixel- and row-doubling) and bilinear (shift-and-add 2-tap +
4-tap). VGA controller is parameterised on H/V_ACTIVE_OUT (= 2x input
dims when SCALER=1, else equal to input dims). OUT_FIFO_DEPTH grows
to 1024 in scaled mode to absorb the 4x output burst rate.

Python reference model (py/models/ops/scale2x.py) covers both modes
byte-exactly; integration regression PASSes at TOLERANCE=0 across
every (control flow x profile x filter) pairing. SCALER=0 remains
byte-identical to pre-scaler output.

See docs/plans/2026-04-23-pipeline-extensions-design.md §3.5.
EOF
)"
```

- [ ] **Step 6: Push and open the PR**

```bash
git push -u origin feat/axis-scale2x
gh pr create --title "feat(scale2x): 2x upscaler with NN + bilinear modes" --body "$(cat <<'EOF'
## Summary
- New `axis_scale2x` IP at the post-gamma tail; compile-time `SCALER` (0/1) + `SCALE_FILTER` (nn/bilinear) knobs.
- VGA controller now parameterised on H/V_ACTIVE_OUT; SCALER=1 → 640×480 output from a 320×240 source pipeline.
- Python reference model + dispatcher updates for byte-exact verification at TOLERANCE=0.
- OUT_FIFO_DEPTH bumps to 1024 only when SCALER=1; SCALER=0 output is byte-identical to pre-scaler goldens.

## Test plan
- [x] `make test-ip-scale2x` (both filter modes)
- [x] `make run-pipeline SCALER=0` × {passthrough,motion,mask,ccl_bbox} × {default,default_hflip} — byte-identical to pre-scaler goldens
- [x] `make run-pipeline SCALER=1 SCALE_FILTER=nn`       × full grid — PASS at TOLERANCE=0
- [x] `make run-pipeline SCALER=1 SCALE_FILTER=bilinear` × full grid — PASS at TOLERANCE=0
- [x] `make lint` clean
- [x] `make test-ip` (every per-block TB)

Plan: `docs/plans/old/2026-04-27-axis-scale2x-plan.md`
Design: `docs/plans/2026-04-23-pipeline-extensions-design.md` §3.5
EOF
)"
```

Expected: PR URL printed. Hand off for human review.

---

## Self-review notes

A spec-coverage pass against `docs/plans/2026-04-23-pipeline-extensions-design.md` §2 + §3.5:

- [x] **§3.5 NN mode** — covered by Tasks 4 (model), 6 (TB), 7 (RTL).
- [x] **§3.5 bilinear mode** — covered by Tasks 4 (model), 6 (TB), 8 (RTL).
- [x] **§3.5 single line buffer** — called out explicitly in arch doc Task 2 §5.1, RTL Tasks 7-8.
- [x] **§3.5 no multipliers / shift-and-add** — flagged in Tasks 7 (NN — pixel-double, no math), 8 (bilinear — `(a+b+1)>>1`, `(a+b+c+d+2)>>2`).
- [x] **§3.5 4× input rate in bursts** — Task 9 bumps `OUT_FIFO_DEPTH` to 1024 when SCALER=1; rate balance is established by the TB clock-period ratio in Task 10 (no software pacing needed).
- [x] **§3.5 per-frame startup / rate-balance precondition** — covered by Task 5b's "Clock Assumptions" section in the arch doc.
- [x] **§2 two pix-clk ports** — Task 9 splits `clk_pix_i` into `clk_pix_in_i` / `clk_pix_out_i` (and matching resets). Task 10 wires the TB to drive both at the right period ratio.
- [x] **§2 clock-stability assumptions** — design doc §2 + arch doc Task 5b. Real-silicon mitigations (genlock / frame buffer / tolerance audit) called out.
- [x] **§2 risk A1 (output FIFO ≥ one output line)** — Task 9 OUT_FIFO_DEPTH bump + the existing `assert_fifo_out_not_full` SVA.
- [x] **§2 risk A3 (real-silicon rate-balance drift)** — documented in design doc §2 + arch doc; not gated by sim verification.
- [x] **§2 risk A4 (gamma before scaler is technically incorrect)** — preserved by design (gamma → scaler is the existing topology in this plan; documented in arch doc §9 Known Limitations).
- [x] **§4.1 parameter propagation** — Task 5 threads `SCALER` and `SCALE_FILTER` through three make layers (top, dv/sim, config.mk); Task 10 re-adds the deferred `-G` flags after the TB exposes the parameters.
- [x] **§4.2 config stamp** — Task 5 step 3.4 extends `CONFIG_STAMP` to include both new knobs (Risk G1).
- [x] **§5.1 unit TB** — Task 6 with NN ramp + bilinear hand-checked golden + asymmetric stall.
- [x] **§5.2 reference model** — Task 4.
- [x] **§5.4 integration regression matrix** — Task 12 covers the `SCALE_FILTER=nn vs bilinear × motion at all-on (2 runs)` row directly, plus `SCALER=0` cmp gate against Task-1 goldens.
- [x] **§5.6 documentation** — Task 13 (README/CLAUDE.md/sparevideo-top-arch.md) + Task 2 (arch doc) + Task 5b (Clock Assumptions follow-up).

Gaps deliberately left:
- HUD (`axis_hud`, design step 6) is out of scope for this plan — its presence would change the post-scaler tail. The design doc and this plan note that ordering: gamma → scaler → HUD. When HUD lands, its plan instantiates `u_hud` after `g_scale2x` but before `u_fifo_out`.
- The design's `make fifo-audit` target (§5.5) is not created here; the existing `assert_fifo_out_not_full` plus the manual run in Task 12 are sufficient quality gates for this stage.
- `GAMMA_CURVE` regression (`linear` vs `srgb`) is exercised in the gamma plan; this plan does not add new gamma coverage.
