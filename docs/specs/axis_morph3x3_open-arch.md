# `axis_morph3x3_open` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports — `axis_morph3x3_erode` and `axis_morph3x3_dilate`](#32-ports--axis_morph3x3_erode-and-axis_morph3x3_dilate)
  - [3.3 Ports — `axis_morph3x3_open`](#33-ports--axis_morph3x3_open)
- [4. Concept Description](#4-concept-description)
  - [4.1 Morphological erosion and dilation](#41-morphological-erosion-and-dilation)
  - [4.2 Morphological opening](#42-morphological-opening)
  - [4.3 Edge replication](#43-edge-replication)
  - [4.4 Risk D1 — thin-feature deletion](#44-risk-d1--thin-feature-deletion)
    - [4.4.1 Interaction with `axis_motion_detect`'s Gaussian pre-filter](#441-interaction-with-axis_motion_detects-gaussian-pre-filter)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Block diagram](#51-block-diagram)
  - [5.2 `axis_morph3x3_erode` datapath](#52-axis_morph3x3_erode-datapath)
  - [5.3 `axis_morph3x3_dilate` datapath](#53-axis_morph3x3_dilate-datapath)
  - [5.4 `axis_morph3x3_open` composite](#54-axis_morph3x3_open-composite)
  - [5.5 `enable_i` bypass semantics](#55-enable_i-bypass-semantics)
  - [5.6 Resource cost summary](#56-resource-cost-summary)
- [6. Control Logic and State Machines](#6-control-logic-and-state-machines)
- [7. Timing](#7-timing)
  - [7.1 Latency](#71-latency)
  - [7.2 Blanking requirements](#72-blanking-requirements)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

This document covers three modules — `axis_morph3x3_erode`, `axis_morph3x3_dilate`, and `axis_morph3x3_open` — as one logical mask-cleanup stage.

`axis_morph3x3_open` applies a **3×3 square morphological opening** to a 1-bit motion mask stream. Opening is the composition of erosion followed by dilation with the same structuring element. The effect on the mask is:

- **Removes** isolated foreground pixels (single-pixel salt noise) — a pixel surrounded by background is erased by erosion and not restored by dilation.
- **Removes** thin foreground stripes narrower than 3 pixels — a stripe thinner than the structuring element collapses to nothing under erosion.
- **Restores** blobs that survive erosion to approximately their original size — the subsequent dilation re-expands survivors to near their pre-erosion shape.

The stage operates in the `clk_dsp` (100 MHz) clock domain. It accepts a 1-bit mask on an AXI4-Stream bus, processes one pixel per clock cycle at steady state, and emits a cleaned 1-bit mask on an identical AXI4-Stream bus. The `enable_i` sideband bypasses both sub-modules with zero additional latency when deasserted.

`axis_morph3x3_open` is a pure 1-to-1 AXIS pipeline stage. Downstream fan-out of the mask (to `axis_ccl`, the mask-display path, etc.) happens *after* the composite — no multi-consumer handshake is required inside this module.

This stage does **not** perform multi-channel processing, adaptive threshold selection, or any operation on luma / RGB data. It does not modify the AXI4-Stream framing signals beyond regenerating them with the correct latency when `enable_i=1`.

For the role of this stage in the larger pipeline (where it sits relative to `axis_motion_detect`, `axis_ccl`, and the mask-display path), see [`sparevideo-top-arch.md`](sparevideo-top-arch.md) §5.

---

## 2. Module Hierarchy

```
axis_morph3x3_open          (u_morph_open in sparevideo_top)
├── axis_morph3x3_erode     (u_erode)
│   └── axis_window3x3  (u_window, DATA_WIDTH=1, EDGE_POLICY=REPLICATE)
└── axis_morph3x3_dilate    (u_dilate)
    └── axis_window3x3  (u_window, DATA_WIDTH=1, EDGE_POLICY=REPLICATE)
```

`axis_morph3x3_erode` and `axis_morph3x3_dilate` are also available as standalone modules for use in other contexts.

---

## 3. Interface Specification

### 3.1 Parameters

All three modules share the same two parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line. Passed through to `axis_window3x3` as the line buffer depth and counter range. |
| `V_ACTIVE` | 240 | Active lines per frame. Passed through to `axis_window3x3` as the row counter range. |

### 3.2 Ports — `axis_morph3x3_erode` and `axis_morph3x3_dilate`

Both modules expose identical ports. The table below applies to each of them individually.

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| **Clock and reset** | | | |
| `clk_i` | input | 1 | DSP clock (`clk_dsp`), rising edge active |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| **Sideband** | | | |
| `enable_i` | input | 1 | When 1: window-based filtering is active. When 0: `s_axis_*` is forwarded directly to `m_axis_*` with no line-buffer latency. Must be held stable across an entire frame; toggling mid-frame is undefined. |
| **AXI4-Stream input (1-bit mask)** | | | |
| `s_axis_tdata_i` | input | 1 | Mask pixel: 1 = foreground, 0 = background |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | AXI4-Stream ready. When `enable_i=1` and the window primitive is executing a phantom cycle (`busy_o` asserted), this deasserts. When `enable_i=0`, combinatorially mirrors `m_axis_tready_i`. |
| `s_axis_tlast_i` | input | 1 | End-of-line (asserted on the last pixel of each active row) |
| `s_axis_tuser_i` | input | 1 | Start-of-frame (asserted on the first pixel of each active frame) |
| **AXI4-Stream output (1-bit mask)** | | | |
| `m_axis_tdata_o` | output | 1 | Filtered mask pixel |
| `m_axis_tvalid_o` | output | 1 | AXI4-Stream valid |
| `m_axis_tready_i` | input | 1 | Downstream ready |
| `m_axis_tlast_o` | output | 1 | End-of-line, regenerated from internal column counter (enable_i=1) or forwarded from `s_axis_tlast_i` (enable_i=0) |
| `m_axis_tuser_o` | output | 1 | Start-of-frame, regenerated or forwarded (same rule as `tlast`) |
| **Status** | | | |
| `busy_o` | output | 1 | Asserts when the internal `axis_window3x3` is executing a phantom cycle while the upstream presents valid data. The parent should deassert upstream `tready` for as many cycles as `busy_o` remains asserted. Stays low in standard VGA-timed integration. Driven low when `enable_i=0`. |

### 3.3 Ports — `axis_morph3x3_open`

`axis_morph3x3_open` exposes the same AXI4-Stream and sideband ports as the sub-modules, minus `busy_o` (the composite does not expose internal phantom-cycle status; standard VGA-timed integration guarantees `busy_o` of both sub-modules stays low).

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk_i` | input | 1 | DSP clock |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| `enable_i` | input | 1 | Forwarded to both `u_erode` and `u_dilate`. When 0, both sub-modules bypass and the composite has zero additional latency. |
| `s_axis_tdata_i` | input | 1 | Input mask pixel |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | AXI4-Stream ready (driven by `u_erode`) |
| `s_axis_tlast_i` | input | 1 | End-of-line |
| `s_axis_tuser_i` | input | 1 | Start-of-frame |
| `m_axis_tdata_o` | output | 1 | Filtered mask pixel |
| `m_axis_tvalid_o` | output | 1 | AXI4-Stream valid |
| `m_axis_tready_i` | input | 1 | Downstream ready |
| `m_axis_tlast_o` | output | 1 | End-of-line |
| `m_axis_tuser_o` | output | 1 | Start-of-frame |

---

## 4. Concept Description

### 4.1 Morphological erosion and dilation

**Erosion** replaces each pixel with the minimum over its neighborhood:

```
erode[r, c] = AND { mask[r+dr, c+dc]  for dr, dc ∈ {−1, 0, +1} }
```

For a 1-bit mask and a 3×3 square structuring element, erosion is a 9-input AND: the output is 1 (foreground) only when all 9 neighbors (including the pixel itself) are 1. Any background pixel in the neighborhood pulls the output to 0.

**Dilation** replaces each pixel with the maximum over its neighborhood:

```
dilate[r, c] = OR { mask[r+dr, c+dc]  for dr, dc ∈ {−1, 0, +1} }
```

For a 1-bit mask and a 3×3 square structuring element, dilation is a 9-input OR: the output is 1 when at least one neighbor is 1. A foreground pixel expands into all 8 of its neighbors.

Both operations are purely combinational 9-way reductions over the 3×3 window taps. The actual storage and alignment infrastructure (line buffers, column shift registers, edge muxing) is owned by `axis_window3x3`.

### 4.2 Morphological opening

Opening = erosion followed by dilation with the same structuring element:

```
open[r, c] = dilate( erode( mask ) )[r, c]
```

Properties of 3×3 square opening:

- **Idempotent:** opening an already-opened mask produces the same result — `open(open(M)) = open(M)`.
- **Anti-extensive:** the output is a subset of the input — `open(M) ⊆ M`.
- **Removes features smaller than the structuring element:** any connected foreground region that cannot fit a 3×3 square is erased. For a convex blob of width W and height H, the blob survives iff `W ≥ 3` and `H ≥ 3`.
- **Approximates original size for survivors:** after dilation, surviving regions return to approximately their pre-erosion area. The approximation is exact for blobs that fit the structuring element with no boundary contact; blobs touching the frame border may be slightly asymmetric due to edge replication.

### 4.3 Edge replication

At all four frame borders, off-frame window taps are filled by replicating the nearest in-frame pixel (`EDGE_REPLICATE` policy, inherited from `axis_window3x3`). This means:

- **Top border** (row 0): the virtual row above replicates row 0.
- **Bottom border** (row V−1): the virtual row below replicates row V−1.
- **Left border** (col 0): the virtual column to the left replicates col 0.
- **Right border** (col H−1): the virtual column to the right replicates col H−1.

For erosion, a foreground pixel at a corner (e.g., row 0, col 0) has its three off-frame neighbors replicated from itself. If the pixel is 1, the replicated neighbors are also 1, and the AND over the 9-tap window depends only on the 2×2 in-frame region. This means that a 2×2 foreground block at a corner survives erosion (and is then partially restored by dilation), because the corner pixel's out-of-frame neighbors are 1 (replicated from itself).

### 4.4 Risk D1 — thin-feature deletion

A 3×3 square opening deletes **any foreground feature narrower than 3 pixels in the mask**. Examples (on the mask, not on the input image):

- A single isolated foreground pixel: eroded to nothing, not restored.
- A 1-pixel-wide horizontal stripe (all columns, one row): every pixel has a background neighbor above or below, AND → 0, entire stripe erased.
- A 2-pixel-wide vertical bar: border-adjacent columns can survive due to replication, but interior columns with only 2-high support do not.

This is the intended behavior for salt-noise removal, but the effective minimum feature size on the **input image** depends on the upstream pipeline.

#### 4.4.1 Interaction with `axis_motion_detect`'s Gaussian pre-filter

When `axis_motion_detect` is configured with `GAUSS_EN=1` (the default), a 3×3 Gaussian `[1 2 1; 2 4 2; 1 2 1]/16` is applied to the luma Y **before** frame-difference thresholding. This spatial blur widens every bright feature by one pixel on each side in the above-threshold diff, so a 1-pixel-wide line in the input RGB becomes a 3-row-thick mask — which is precisely the minimum size that a 3×3 opening preserves.

Consequence for the full pipeline (`axis_motion_detect` → `axis_morph3x3_open` → consumers):

| Input feature width/height | `GAUSS_EN=0` mask thickness | `GAUSS_EN=1` mask thickness | Opening result |
|----------------------------|-----------------------------|-----------------------------|----------------|
| 1 px                       | 1 px                        | 3 px (after blur)           | `GAUSS_EN=0`: **erased**; `GAUSS_EN=1`: **preserved** |
| 2 px                       | 2 px                        | 4 px                        | `GAUSS_EN=0`: erased; `GAUSS_EN=1`: preserved |
| ≥ 3 px                     | ≥ 3 px                      | ≥ 5 px                      | preserved in both cases |

So the input-image minimum-feature-size deletion threshold is:
- `GAUSS_EN=0`: features < 3 px wide/tall are deleted by opening.
- `GAUSS_EN=1`: features < 1 px (i.e., only single isolated pixels) are deleted by opening; 1- and 2-px-wide features survive because the Gauss blurs them above the morphological threshold.

To exercise Risk D1 end-to-end, use `GAUSS_EN=0` in combination with the `thin_moving_line` synthetic source. With `GAUSS_EN=1` the difference between `MORPH=0` and `MORPH=1` on a 1-px feature is dominated by the Gauss widening upstream and is not visible.

For salt-noise suppression (the primary design intent), `GAUSS_EN=1` is fully compatible: isolated-pixel noise in the input still produces isolated-pixel diffs above threshold (the Gauss averages the noise down in amplitude, and whatever single-pixel speckles remain in the mask are still erased by opening).

---

## 5. Internal Architecture

### 5.1 Block diagram

```
s_axis_*  ──►  ┌─────────────────────┐  mid_*  ┌──────────────────────┐  ──►  m_axis_*
               │   axis_morph3x3_erode  │ ──────► │  axis_morph3x3_dilate   │
               │                     │         │                      │
               │  axis_window3x3<1>  │         │  axis_window3x3<1>   │
               │  (DATA_WIDTH=1)     │         │  (DATA_WIDTH=1)      │
               │                     │         │                      │
               │  9-way AND (comb)   │         │  9-way OR (comb)     │
               │  output register    │         │  output register     │
               └─────────────────────┘         └──────────────────────┘
```

The internal AXIS link (`mid_tdata`, `mid_tvalid`, `mid_tready`, `mid_tlast`, `mid_tuser`) connects the erode output to the dilate input. `mid_tready` is driven by `u_dilate.s_axis_tready_o` back to `u_erode.m_axis_tready_i`.

### 5.2 `axis_morph3x3_erode` datapath

```
s_axis_tdata_i ──► axis_window3x3 ──► window_o[9]
                   (DATA_WIDTH=1)        │
                                         ▼
                               erode_bit = window[0] & window[1] & ... & window[8]
                               (always_comb, 9-input AND)
                                         │
                                         ▼
                               ┌──────────────────┐
                               │  output register  │  (always_ff, gated by !stall)
                               │  m_axis_tdata_o   │
                               │  m_axis_tvalid_o  │
                               │  m_axis_tlast_o   │  ← regenerated from out_col/out_row
                               │  m_axis_tuser_o   │  ← regenerated from out_col/out_row
                               └──────────────────┘
```

`tlast` and `tuser` on the output are regenerated by a local `(out_col, out_row)` counter that advances on each `window_valid && !stall` beat:
- `m_axis_tuser_o` asserts when `out_col == 0 && out_row == 0` (first pixel of the frame, SOF).
- `m_axis_tlast_o` asserts when `out_col == H_ACTIVE-1` (last pixel of each row, EOL).

The `stall` signal is derived directly from the downstream ready: `stall = !m_axis_tready_i`.

`s_axis_tready_o` is deasserted only during a phantom cycle (`busy_o` from `axis_window3x3`); otherwise it follows `!stall`.

### 5.3 `axis_morph3x3_dilate` datapath

Structurally identical to `axis_morph3x3_erode` with the combinational reduction changed from AND to OR:

```
dilate_bit = window[0] | window[1] | ... | window[8]
```

All other elements — `axis_window3x3` instantiation, output register, `tlast`/`tuser` regeneration, stall and ready handling — are identical.

### 5.4 `axis_morph3x3_open` composite

`axis_morph3x3_open` is a thin wrapper. It instantiates `u_erode` and `u_dilate`, wires the internal AXIS link between them, and routes `enable_i` to both. No combinational logic or state is added at this level beyond the wiring.

The internal AXIS link (`mid_tdata`, `mid_tvalid`, `mid_tready`, `mid_tlast`, `mid_tuser`) connects `u_erode`'s output ports to `u_dilate`'s input ports. `u_erode` sources the composite's `s_axis_tready_o`; `u_dilate` drives the composite's `m_axis_*` outputs. All port connections follow the names in §3.2 and §3.3 exactly.

### 5.5 `enable_i` bypass semantics

When `enable_i = 0`, the combinational reduction is bypassed in both sub-modules. Each sub-module forwards `s_axis_*` directly to `m_axis_*`:

- `m_axis_tdata_o  = s_axis_tdata_i`
- `m_axis_tvalid_o = s_axis_tvalid_i`
- `m_axis_tlast_o  = s_axis_tlast_i`
- `m_axis_tuser_o  = s_axis_tuser_i`
- `s_axis_tready_o = m_axis_tready_i`

The line buffers inside `axis_window3x3` are still present (no generate block), but their output is muxed out. The bypass is purely combinational: zero additional latency is added to the pipeline when `enable_i = 0`.

`enable_i` must be held stable across a complete frame. Toggling `enable_i` mid-frame is undefined behavior — the line buffers and output counter will be in an inconsistent state.

### 5.6 Resource cost summary

Per sub-module (`axis_morph3x3_erode` or `axis_morph3x3_dilate`), at `H_ACTIVE=320`, `V_ACTIVE=240`:

| Resource | Count |
|----------|-------|
| Line buffer memory | 2 × H_ACTIVE × 1 bit = 640 bits (80 bytes) per sub-module |
| Column shift register FFs | 6 × 1 = 6 bits per sub-module |
| d1 pipeline registers (inherited from `axis_window3x3`) | 1 (data_d1) + COL_W (col_d1) + ROW_W (row_d1) + 1 (valid_d1) |
| Output counter FFs | COL_W (out_col) + ROW_W (out_row) |
| Output register | 1 (tdata) + 1 (tvalid) + 1 (tlast) + 1 (tuser) = 4 bits |
| Combinational reduction | 9-input AND or OR gate tree |
| Multipliers | 0 |

For `axis_morph3x3_open` (two sub-modules combined):

| Resource | Count |
|----------|-------|
| Total line buffer | 4 × H_ACTIVE × 1 bit = 1,280 bits (160 bytes) |
| Total FFs (excluding line buffer) | ~2 × (6 + COL_W + ROW_W + 4 + COL_W + ROW_W) |

---

## 6. Control Logic and State Machines

No FSM in any of the three modules. All control is combinational gating based on `window_valid`, `stall_i`, and `sof_i`. The only registered control state is the `(out_col, out_row)` output pixel counter (per sub-module) and the counters inside `axis_window3x3`.

| Signal | Condition | Effect |
|--------|-----------|--------|
| `sof_i` | `valid_i && !stall_i` on the window input | `axis_window3x3` counters reset; output counter resets at the next SOF-aligned output beat |
| `stall_i` | `!m_axis_tready_i` | All FFs frozen: line buffers, shift registers, d1 stage, output register, output counter |
| `window_valid` | combinational from `axis_window3x3` | Output register enabled; output counter advances |
| `busy_o` | `valid_i && at_phantom` inside `axis_window3x3` | Parent deasserts upstream `tready` for the phantom cycle; not propagated by `axis_morph3x3_open` |

---

## 7. Timing

### 7.1 Latency

| Stage | Latency |
|-------|---------|
| `axis_window3x3` (shared primitive) | H_ACTIVE + 2 cycles from first `valid_i` to first `window_valid_o` |
| Sub-module output register | +1 cycle |
| **Per sub-module (`axis_morph3x3_erode` or `axis_morph3x3_dilate`) end-to-end** | **H_ACTIVE + 3 cycles** |
| **`axis_morph3x3_open` end-to-end (both sub-modules)** | **2 × (H_ACTIVE + 3) cycles** |
| Steady-state throughput | 1 pixel / cycle (after fill, when `!stall_i`) |

At `H_ACTIVE = 320` and a 100 MHz DSP clock, the end-to-end opening latency is `2 × 323 = 646` cycles = 6.46 µs. This is a one-time fill cost at the start of each frame and is invisible in a 60 fps pipeline.

**`enable_i = 0` latency:** 0 additional cycles. Both sub-modules forward their input directly to output.

### 7.2 Blanking requirements

The blanking requirements for a single `axis_window3x3` instance are:

| Blanking type | Minimum | Absorbs |
|---------------|---------|---------|
| H-blank | 1 cycle per row | 1 phantom column per row |
| V-blank | H_ACTIVE + 1 cycles total | H_ACTIVE + 1 phantom row cycles |

For `axis_morph3x3_open` (erode → dilate in series), the blanking budget the upstream source must provide is the same as a single `axis_window3x3` instance. Each stage drains its own phantom cycles independently; the two drains do not run concurrently on the same clock edge because dilate's drain starts only after erode's drain has completed (erode's phantom outputs are dilate's inputs). Standard VGA-timed integration (`H_BLANK ≥ H_ACTIVE/20`, `V_BLANK ≥ 1 line`) satisfies this with large margin.

---

## 8. Shared Types

None from `sparevideo_pkg`. Frame geometry parameters (`H_ACTIVE`, `V_ACTIVE`) match the package values when instantiated from `sparevideo_top`.

---

## 9. Known Limitations

- **3×3 fixed kernel only.** The structuring element is a 3×3 square and cannot be parameterized at runtime. A larger kernel (5×5, disk) would require additional line buffers and is a separate module.
- **Thin-feature deletion (Risk D1).** Any foreground feature narrower than 3 pixels in either dimension is removed. This is the intended noise-suppression effect but also deletes thin real objects. See §4.4.
- **`enable_i` must be frame-stable.** Toggling `enable_i` mid-frame produces undefined output because the line buffers and output counter hold state from the partially processed frame.
- **SOF does not flush line buffers.** As with `axis_window3x3`, a `sof_i` resets the row/col counters but does not zero the line buffer contents. The first two rows refill the buffers via the cascade, identical to `axis_gauss3x3` behavior. See [`axis_window3x3-arch.md`](axis_window3x3-arch.md) §9 for details.
- **Distributed RAM at 320 px.** At wider resolutions, synthesis should infer BRAM for the line buffers. No synthesis pragmas are applied.
- **`busy_o` not exposed by `axis_morph3x3_open`.** In standard VGA-timed integration `busy_o` never asserts; the composite module does not re-expose the internal status. A future high-throughput integration without blanking would need to unwrap the composite and connect `busy_o` from each sub-module.

---

## 10. References

- [`axis_window3x3-arch.md`](axis_window3x3-arch.md) — Sliding-window primitive: line buffers, phantom-cycle drain, blanking requirements, edge-replication muxing. The definitive reference for shared infrastructure.
- [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) — Gaussian wrapper pattern; `axis_morph3x3_erode` and `axis_morph3x3_dilate` follow the same wrapper structure.
- [`sparevideo-top-arch.md`](sparevideo-top-arch.md) — Top-level pipeline; shows where `axis_morph3x3_open` sits in relation to `axis_motion_detect`, `axis_ccl`, and the downstream mask consumers.
- **Serra, J. (1982). Image Analysis and Mathematical Morphology.** Academic Press. Foundational text on erosion, dilation, and opening with structuring elements.
- **Haralick, R. M., Sternberg, S. R., & Zhuang, X. (1987). Image Analysis Using Mathematical Morphology.** IEEE TPAMI 9(4), 532–550. Binary morphological operations and their properties.
- **MathWorks Vision HDL Toolbox — `visionhdl.Opening`** — [https://www.mathworks.com/help/visionhdl/ref/visionhdl.opening-system-object.html](https://www.mathworks.com/help/visionhdl/ref/visionhdl.opening-system-object.html) — Reference for streaming morphological opening with pixel-stream interfaces and blanking requirements.
