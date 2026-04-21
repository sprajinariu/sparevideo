# Motion Mask Quality — Adaptive Background Model

**Date:** 2026-04-21
**Status:** Approved — ready for planning
**Scope:** `hw/ip/motion/rtl/motion_core.sv`, `hw/ip/motion/rtl/axis_motion_detect.sv`, `py/models/motion.py`, Makefile parameter propagation

## Problem Statement

The motion detector's mask output has five observed quality issues, all traceable to the unconditional-EMA background model:

1. EMA priming takes 6–7 frames (bg RAM starts at 0, converges at α=1/8).
2. Priming happens even on fully static inputs.
3. Moving objects leave trails that CCL identifies as separate components.
4. Trail intensity depends on foreground colour (blue/green worse than red — larger Y delta).
5. Dark-on-white exhibits the worst priming ramp and the longest trails (maximum Y delta).

A sixth, related issue from `docs/plans/improve-mask-quality.md` line 9: during the priming ramp, `noisy_moving_box` produces multiple overlapping bboxes — an artifact of CCL operating on a noisy all-false-positive mask.

## Root Cause

All six symptoms share one cause: the background model update is unconditional.

- Starting bg at 0 forces a multi-frame convergence ramp (issues 1, 2, 5a, 6).
- Continuing to update bg with the foreground luma while an object occupies a pixel contaminates the model; after the object leaves, bg takes `~1/α` frames to recover, showing as a trail (issues 3, 4, 5b).

## Design

Two independent changes to the background update rule, implemented together because they share state and cost:

### 1. Per-pixel hard initialization (one-frame priming)

The first frame seeds the background RAM directly instead of participating in EMA convergence. A global 1-bit `primed` flag:

```
primed <= 0                                   on reset
primed <= 1                                   on end_of_frame && beat_done  (last pixel of frame 0)
primed    held                                otherwise
```

While `primed == 0`: every accepted pixel writes its `y_smooth` value directly into `bg[addr]`, and `mask_bit` is forced to 0. By end-of-frame-0, the bg RAM is fully initialized. `primed` latches on the final beat of frame 0, so frame 1's very first pixel sees `primed == 1` — no lost pixels, no edge cases.

`end_of_frame` already exists in `axis_motion_detect.sv:230` (`end_of_row && out_row == V_ACTIVE-1`); no new counters are introduced.

### 2. Selective EMA (two-rate adaptive background)

The background update rate differs based on whether the current pixel is flagged as motion:

- **Non-motion pixel** — update at the fast rate (`α = 1 / (1<<ALPHA_SHIFT)`, default 1/8). This keeps tracking slow scene changes (illumination, auto-exposure).
- **Motion pixel** — update at a slow rate (`α = 1 / (1<<ALPHA_SHIFT_SLOW)`, default 1/64). This nearly freezes the bg under a moving object, preventing contamination, while still absorbing stopped objects on a ~2-second timescale at 30 fps.

The two rates share one subtraction:

```
ema_delta       = signed(y_smooth) - signed(y_bg)    // one 9-bit signed subtract

ema_step_fast   = ema_delta >>> ALPHA_SHIFT          // wire shift
ema_step_slow   = ema_delta >>> ALPHA_SHIFT_SLOW     // wire shift

ema_update      = y_bg + ema_step_fast[7:0]
ema_update_slow = y_bg + ema_step_slow[7:0]
```

Both shifts are constant fan-outs of the same signed delta; synthesis collapses trivially. Only the subtract is non-trivial arithmetic, and it runs once.

### 3. Background-write mux

The `axis_motion_detect` wrapper selects the write-back source per pixel:

```
bg_next = !primed    ? y_smooth
        :  raw_motion ? ema_update_slow
        :               ema_update
```

`raw_motion` is the unchanged threshold comparison `(|y_smooth - y_bg| > THRESH)`. `motion_core` exposes `mask_bit_o` already gated by `primed_i` so the wrapper does not re-implement the gate for the output stream.

## Architecture Surface

All changes are contained in two RTL files plus one Python model. No top-level plumbing changes. No new modules. No change to memory-port widths or counts — `bg[]` stays 8 bits wide.

### `hw/ip/motion/rtl/motion_core.sv`

- Add input `primed_i`.
- Add parameter `ALPHA_SHIFT_SLOW` (default 6).
- Compute `ema_delta` once, shift twice, emit `ema_update_o` and `ema_update_slow_o`.
- `mask_bit_o` gated by `primed_i` internally.

### `hw/ip/motion/rtl/axis_motion_detect.sv`

- Add `primed` 1-bit register, latched on `end_of_frame && beat_done`.
- Add parameter `ALPHA_SHIFT_SLOW` (default 6), passed through to `motion_core`.
- Implement the 3:1 `bg_next` mux feeding `mem_wr_data_o`.
- All existing stall-safety machinery (`held_tdata`, `pix_addr_hold`, gated `mem_wr_en`) is untouched.

### `py/models/motion.py`

- Mirror the same 3-way bg-update rule so `make verify` stays bit-exact at `TOLERANCE=0`.
- Read `ALPHA_SHIFT_SLOW` from `dv/data/config.mk`.

## Parameter Propagation

Following CLAUDE.md "Motion pipeline — lessons learned §2" (compile-time `-G` parameters must traverse the full chain). The new parameter `ALPHA_SHIFT_SLOW`:

1. `hw/top/sparevideo_pkg.sv` — `parameter int ALPHA_SHIFT_SLOW = 6;`
2. Top `Makefile` — `ALPHA_SHIFT_SLOW ?= 6`, appended to `SIM_VARS`.
3. `dv/sim/Makefile` — `ALPHA_SHIFT_SLOW ?= 6`, `-GALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW)` in `VLT_FLAGS`, added to the config stamp so parameter changes trigger recompilation.
4. `dv/sv/tb_sparevideo.sv` — `parameter int ALPHA_SHIFT_SLOW = 6;`, plumbed into the DUT instance.
5. `hw/top/sparevideo_top.sv` — new module parameter, plumbed to `axis_motion_detect`.
6. `hw/ip/motion/rtl/axis_motion_detect.sv` and `motion_core.sv` — new parameter, default `= 6`.
7. `py/harness.py` prepare step — include `ALPHA_SHIFT_SLOW` in `dv/data/config.mk` alongside `ALPHA_SHIFT`.

## Verification Plan

### Python model unit tests (`py/tests/test_models.py`)

- **Frame-0 priming:** assert mask is all-zero for frame 0 across several synthetic sources; assert `bg[i]` at end-of-frame-0 equals `Y(frame_0[i])` for every pixel.
- **Selective-EMA rates:** construct a 3-frame sequence with a high-contrast motion region; assert bg drift at motion pixels matches `α = 1/(1<<ALPHA_SHIFT_SLOW)` and at static pixels matches `α = 1/(1<<ALPHA_SHIFT)`. Bit-exact against the RTL rule.
- Existing tests continue to pass unchanged for frame ≥ 2 non-motion regions.

### RTL unit tests (`hw/ip/motion/tb/`)

- **Priming correctness (`tb_axis_motion_detect`):** drive two frames of constant luma; assert `m_axis_msk_tdata == 0` for all of frame 0 and all of frame 1 (since `y_cur == y_bg` everywhere after priming).
- **Selective-EMA bg trajectory:** drive a synthetic high-contrast motion sequence; dump bg RAM at end-of-frame N; compare against the Python model's bg trajectory bit-exact.

### Integration (`make run-pipeline`)

- Primary gate: `make run-pipeline CTRL_FLOW=mask` on `noisy_moving_box`, `dark_moving_box`, `moving_box` must pass `TOLERANCE=0` (model-vs-RTL bit-exact).
- Sweep matrix: 4 control flows × `ALPHA_SHIFT ∈ {0,1,2,3}` × several sources × `ALPHA_SHIFT_SLOW ∈ {5,6,7}` at `TOLERANCE=0`.
- Visual (human-in-loop): `CTRL_FLOW=motion` on `dark_moving_box` and `noisy_moving_box`; confirm (a) no multi-frame priming ramp, (b) no trail, (c) ≤1 bbox per object during early frames.

### Lint & regression

- `make lint` clean, no new waivers (new signed shifts reuse the pattern at `motion_core.sv:33-35`).
- `make test-ip` (all unit TBs) and `make sim` (passthrough) remain green.

## Non-Goals

- Colour-aware detection (using Cb/Cr alongside Y) — YAGNI until selective EMA is shown to miss realistic cases.
- Per-pixel "stale" counters to force-reset bg after N motion frames — YAGNI; slow EMA rate provides graceful absorption.
- Changes to CCL, bbox overlay, or Gaussian pre-filter.

## Follow-Ups (outside this spec)

- The bbox-overlap concern on `noisy_moving_box` during priming is expected to resolve automatically (priming is now 1 frame with mask forced to 0). If artifacts persist in post-priming frames, file a separate spec for CCL/morphology improvements.
