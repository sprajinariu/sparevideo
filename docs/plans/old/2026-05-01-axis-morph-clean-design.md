# `axis_morph_clean` — Combined Open + Close Mask Cleanup

**Status:** Design (brainstorming output)
**Date:** 2026-05-01

## 1. Goal

Replace the current `axis_morph3x3_open` block in the motion mask path with a single combined cleanup stage `axis_morph_clean` that applies a 3×3 morphological **open** followed by a parametrizable **close** (3×3 or 5×5). The close stage bridges the small intra-object gaps that fragment a single moving object into multiple disjoint blobs in the motion mask, which is the root cause of the bbox issues observed on the real-video demo (smaller bboxes inside larger ones, overlapping bboxes per object, single objects splitting into multiple bboxes).

The combined block has:

- One runtime gate per stage: `morph_open_en` (open), `morph_close_en` (close).
- One compile-time kernel-size knob for the close: `morph_close_kernel ∈ {3, 5}`. Default 3.
- Both stages built only from existing 3×3 erode/dilate primitives (no new `axis_window5x5`).

## 2. Non-goals

- 7×7 close kernel (deferred — eval can revisit later).
- New 5×5 native window primitive (`axis_window5x5`). The 5×5 close is built by Minkowski composition of two 3×3 dilates and two 3×3 erodes.
- Runtime kernel-size selection. `morph_close_kernel` is compile-time per profile.
- Frame-0 ghost suppression. The bbox-quality issues studied in the eval are addressed here; ghost cleanup is a separate workstream.
- Bbox-domain post-processing (NMS / containment suppression / proximity merging). Deferred — masking-domain fix first, downstream cleanup only if it proves insufficient.

## 3. Background

A Python eval (script `/tmp/morph_close_eval.py`, throwaway) ran the existing motion + ccl_bbox reference models on `media/source/pexels-pedestrians-320x240.mp4` with five variants:

| Variant | Pipeline | Frame-0 prime | WebP md5 |
|---|---|---|---|
| `real-baseline` | open3 only | default (frame 0) | `8d3283…` |
| `real_close3x3` | open3 + close3 | default | `4d40c5…` |
| `real_close5x5` | open3 + close5 | default | `b157ec…` |
| `real_clean_baseline` | open3 only | clean (per-pixel temporal median) | `5be0e1…` |
| `real_clean_close3x3` | open3 + close3 | clean | `59db68…` |
| `real_clean_close5x5` | open3 + close5 | clean | `009f38…` |

WebPs in `media/demo-draft/`. Visual inspection — confirmed by the user — shows close3 already substantially reduces the per-object multi-bbox fragmentation; close5 reduces it further but with diminishing returns and a higher risk of merging adjacent distinct objects (3×3 close bridges 1-px gaps, 5×5 close bridges 2-px gaps; greater kernel sizes increase inter-object merging). Default `morph_close_kernel=3` for all profiles is the chosen anchor; `morph_close_kernel=5` remains accessible by changing one cfg field for any future profile.

Empirical confirmation that CCL's union-find is **not** the bottleneck: a side experiment bumping `CCL_MAX_CHAIN_DEPTH` from 8 to 16 produced byte-identical WebP output. The fragmentation lives upstream in the mask, not in CCL.

## 4. Architecture

### 4.1 Block diagram

```
                          morph_open_en              morph_close_en
                                │                           │
                ┌─────┐    ┌────▼────┐    ┌─────────────────▼────────────────┐
   s_axis ────► │ 3×3 │ ─► │  3×3    │ ─► │ [3×3 dilate × N] → [3×3 erode × N] │ ─► m_axis
                │ ero │    │  dil    │    │                                    │
                └─────┘    └─────────┘    └────────────────────────────────────┘
                └────── 3×3 open ──┘      └── close (kernel = 2N+1) ──┘
```

`N = (morph_close_kernel - 1) / 2`:
- `morph_close_kernel = 3` → `N = 1` → 1 dilate + 1 erode = 3×3 close.
- `morph_close_kernel = 5` → `N = 2` → 2 dilates + 2 erodes = 5×5 close (Minkowski sum: 3×3 ⊕ 3×3 = 5×5).

All sub-stages are existing modules (`axis_morph3x3_erode`, `axis_morph3x3_dilate`). No new primitive types. Each sub-stage's `enable_i` is wired to the corresponding gate so a disabled stage becomes a deterministic 1-cycle skid passthrough.

### 4.2 Module interface

```sv
module axis_morph_clean #(
    parameter int H_ACTIVE          = 320,
    parameter int V_ACTIVE          = 240,
    parameter int CLOSE_KERNEL      = 3   // 3 or 5; selects N internally
) (
    input  logic   clk_i,
    input  logic   rst_n_i,
    input  logic   morph_open_en_i,        // gates the 3×3 open
    input  logic   morph_close_en_i,       // gates the close
    axis_if.rx     s_axis,                 // 1-bit mask in
    axis_if.tx     m_axis                  // 1-bit mask out
);
```

`assert (CLOSE_KERNEL == 3 || CLOSE_KERNEL == 5);` at elaboration time. Any other value is an `$error`.

### 4.3 Internal pipeline

A `generate` block expands the close into `N` cascaded dilates followed by `N` cascaded erodes:

```sv
localparam int N = (CLOSE_KERNEL - 1) / 2;
// Open: erode → dilate (always present, gated by morph_open_en_i)
axis_morph3x3_erode  u_open_erode  (.enable_i(morph_open_en_i),  ...);
axis_morph3x3_dilate u_open_dilate (.enable_i(morph_open_en_i),  ...);
generate
  for (genvar i = 0; i < N; i++) begin : g_close_dilate
    axis_morph3x3_dilate u_d (.enable_i(morph_close_en_i), ...);
  end
  for (genvar i = 0; i < N; i++) begin : g_close_erode
    axis_morph3x3_erode  u_e (.enable_i(morph_close_en_i), ...);
  end
endgenerate
```

Internal `axis_if` instances connect the sub-stages.

### 4.4 Resource cost

| `morph_close_kernel` | Sub-stages | Line buffers | Latency (rows) |
|---|---|---|---|
| 3 | erode → dilate → dilate → erode | 4 × 2 = **8** | 4 |
| 5 | erode → dilate → dilate → dilate → erode → erode | 6 × 2 = **12** | 6 |

Each `axis_window3x3` contains 2 line buffers of `H_ACTIVE` × 1-bit (≤ 320 b each). Total worst-case storage at 5×5: 12 × 320 × 1 = 3,840 bits — negligible. Latency stays well inside vblank (~144 kcycles vs ~6 row scans = ~1,920 cycles).

## 5. Configuration knobs

### 5.1 `cfg_t` changes (in `hw/top/sparevideo_pkg.sv`)

- **Rename** `morph_en` → `morph_open_en`. (Mass rename across all 9 named profiles; parity test in `py/tests/test_profiles.py` enforces the corresponding field name in `py/profiles.py`.)
- **Add** `morph_close_en` (`logic`).
- **Add** `morph_close_kernel` (`int`).

### 5.2 Per-profile defaults

| Profile | `morph_open_en` | `morph_close_en` | `morph_close_kernel` |
|---|---|---|---|
| `CFG_DEFAULT` | 1 | 1 | 3 |
| `CFG_DEFAULT_HFLIP` | 1 | 1 | 3 |
| `CFG_NO_EMA` | 1 | 1 | 3 |
| `CFG_NO_MORPH` | **0** | **0** | 3 |
| `CFG_NO_GAUSS` | 1 | 1 | 3 |
| `CFG_NO_GAMMA_COR` | 1 | 1 | 3 |
| `CFG_NO_SCALER` | 1 | 1 | 3 |
| `CFG_DEMO` | 1 | 1 | 3 |
| `CFG_NO_HUD` | 1 | 1 | 3 |

`CFG_NO_MORPH` becomes "neither open nor close" — a full mask-cleanup bypass profile. Other profiles enable both stages by default. `morph_close_kernel=3` is the start point for every profile; `5` remains a one-field switch away if a future evaluation justifies it.

### 5.3 Python mirror

`py/profiles.py` adds matching keys to every profile dict. Parity test in `py/tests/test_profiles.py` (which scans `cfg_t` fields against profile dict keys) catches drift in either direction.

## 6. Top-level integration

In `hw/top/sparevideo_top.sv`:

```sv
axis_morph_clean #(
    .H_ACTIVE     (H_ACTIVE),
    .V_ACTIVE     (V_ACTIVE),
    .CLOSE_KERNEL (CFG.morph_close_kernel)
) u_morph_clean (
    .clk_i             (clk_dsp_i),
    .rst_n_i           (rst_dsp_n_i),
    .morph_open_en_i   (CFG.morph_open_en),
    .morph_close_en_i  (CFG.morph_close_en),
    .s_axis            (motion_to_morph),
    .m_axis            (morph_to_ccl)
);
```

Replaces the current `u_morph_open` instantiation. The two `axis_if` connections (`motion_to_morph`, `morph_to_ccl`) are unchanged — same wires, new module.

## 7. Python reference models

The Python pipeline lives in `py/models/motion.py` and `py/models/ccl_bbox.py`. Both currently import `morph_open` from `py/models/ops/morph_open.py` and call it on the raw mask when `morph_en=True`.

Changes:

- Rename or extend `py/models/ops/morph_open.py` to export `morph_open(mask)` (unchanged) and `morph_close(mask, kernel)` (new). Or merge into a single `py/models/ops/morph_clean.py` exposing `morph_clean(mask, *, open_en, close_en, close_kernel)`. Final shape decided in the implementation plan.
- `motion.py` and `ccl_bbox.py` thread the three new fields through their `run()` kwargs and apply open + close in raster order on `raw_mask` before consuming it for CCL and overlay.
- The EMA still consumes the **raw** (pre-morph) mask, matching the RTL datapath.

## 8. Files

### 8.1 Created

- `hw/ip/filters/rtl/axis_morph_clean.sv` — combined open + close module.
- `hw/ip/filters/tb/tb_axis_morph_clean.sv` — single unit testbench covering the matrix `(open_en, close_en, CLOSE_KERNEL) ∈ {0,1} × {0,1} × {3,5}` plus standard backpressure / SOF / mid-frame stall scenarios.
- `docs/specs/axis_morph_clean-arch.md` — single arch spec for the whole block, written before RTL implementation per the `hardware-arch-doc` skill.

### 8.2 Modified

- `hw/top/sparevideo_pkg.sv` — `cfg_t` field rename + 2 new fields, all 9 profiles updated.
- `py/profiles.py` — mirror the cfg_t changes across every profile dict.
- `hw/ip/filters/filters.core` — register `axis_morph_clean.sv`, deregister `axis_morph3x3_open.sv`.
- `hw/top/sparevideo_top.sv` — replace `u_morph_open` instantiation with `u_morph_clean`.
- `dv/sim/Makefile` — rename `test-ip-morph-open` target → `test-ip-morph-clean`, point it at the new TB.
- `Makefile` (top) — same rename in the help text.
- `py/models/ops/morph_open.py` — extended (or replaced by `morph_clean.py`).
- `py/models/motion.py`, `py/models/ccl_bbox.py` — accept and apply the new knobs.
- `CLAUDE.md` — update the `hw/ip/filters/rtl/` description to reference the new combined block.
- `README.md` — module status table refreshed.
- `docs/specs/sparevideo-top-arch.md` — pipeline diagram updated to show the combined cleanup stage.

### 8.3 Deleted

- `hw/ip/filters/rtl/axis_morph3x3_open.sv` (subsumed by `axis_morph_clean`).
- `hw/ip/filters/tb/tb_axis_morph3x3_open.sv` (replaced by combined TB).
- `docs/specs/axis_morph3x3_open-arch.md` (replaced by `axis_morph_clean-arch.md`).

The `axis_morph3x3_erode.sv` and `axis_morph3x3_dilate.sv` primitives **stay** — they're the building blocks the new module instantiates internally. Their existing unit TBs (if separate) also stay.

## 9. Test strategy

### 9.1 Unit TB (`tb_axis_morph_clean`)

Single SystemVerilog testbench. Each test instantiates a parametrized DUT and a Python-equivalent golden model expressed in SV (or DPI-imported scipy via the existing pattern). Tests must include:

- All 8 combinations of `(open_en, close_en, CLOSE_KERNEL)`. With `close_en=0` the kernel value is irrelevant but should pass-through.
- A "thin-feature destruction" test for `open_en=1`: a 1-px-wide line input must produce empty output.
- A "gap-bridging" test for `close_en=1`:
  - 3×3 close: a single-pixel hole in a foreground region must be filled.
  - 5×5 close: a 1×2 (and 2×2) hole must be filled, but a 3×3 hole must remain.
- A backpressure test with `m_axis.tready` deasserted mid-frame.
- An SOF/EOF correctness test: `tuser` (SOF) marks frame start, `tlast` marks end of every line, and frame counts in equal frame counts out — no missing or duplicated lines/frames across all `(open_en, close_en, CLOSE_KERNEL)` combinations.

### 9.2 Integration verification

- All four `CTRL_FLOW × CFG` combinations from CLAUDE.md remain passing at TOLERANCE=0:
  - `CTRL_FLOW ∈ {passthrough, motion, mask, ccl_bbox}`
  - `CFG ∈ {default, default_hflip, no_ema, no_morph, no_gauss, no_gamma_cor, no_scaler, demo, no_hud}`
- `CFG_NO_MORPH` (with `morph_open_en=0, morph_close_en=0`) is the bypass-correctness benchmark: byte-identical to a hypothetical no-morph reference, verified via Python model.
- `make demo` regenerates `media/demo-draft/{synthetic,real}.webp` cleanly with the new block. Visual confirmation that the bbox issues observed in baseline are alleviated.

### 9.3 Lint

`make lint` clean before commit.

## 10. Open questions for the implementation plan

These are deliberately deferred to the planning step:

1. **Python ops layout**: extend `morph_open.py` with a `morph_close(mask, kernel)` peer, or create a new `morph_clean.py` that wraps both? Choice trades minimal-diff against module cohesion.
2. **TB harness style**: does `tb_axis_morph_clean` use the existing `drv_*` initial-block pattern documented in CLAUDE.md, or the newer pattern used by `tb_axis_scale2x`? Match existing testbenches in `hw/ip/filters/tb/` for consistency unless a stronger reason emerges.
3. **Arch spec scope check**: the new spec should respect the project's "datapath-only overview diagrams; no Python/TB narrative" rule. The implementation plan will sequence the arch spec to be written first (via the `hardware-arch-doc` skill) before any RTL.
4. **Demo regeneration policy**: rebuild and publish the WebPs as part of this branch (the CLAUDE.md "TODO after each major change" rule), or as a follow-up PR? Default: include in the same branch since the demo's bbox behavior is precisely what this change improves.

## 11. References

- `docs/specs/axis_morph3x3_open-arch.md` — current spec, will be replaced.
- `docs/specs/axis_ccl-arch.md` §6.7 — vblank cycle budget, well within the latency added by morph_clean.
- `docs/specs/sparevideo-top-arch.md` — pipeline overview that will need a one-block update.
- Soille, *Morphological Image Analysis: Principles and Applications* (2nd ed., Springer 2003), §8.2 — alternating sequential filters with mismatched SE sizes; theoretical basis for asymmetric open/close.
- Gonzalez & Woods, *Digital Image Processing* (4th ed., 2018), Chapter 9 — open-then-close as the canonical binary-mask cleanup pipeline.
- OpenCV [Background Subtraction tutorial](https://docs.opencv.org/4.x/db/d5c/tutorial_py_bg_subtraction.html) — practitioner-side justification for asymmetric open/close on motion masks.
