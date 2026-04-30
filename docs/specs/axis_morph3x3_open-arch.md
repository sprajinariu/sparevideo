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
  - [4.4 Thin-feature deletion](#44-thin-feature-deletion)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Block diagram](#51-block-diagram)
  - [5.2 Sub-module datapath](#52-sub-module-datapath)
  - [5.3 `axis_morph3x3_open` composite](#53-axis_morph3x3_open-composite)
  - [5.4 `enable_i` bypass semantics](#54-enable_i-bypass-semantics)
  - [5.5 Resource cost summary](#55-resource-cost-summary)
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

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| `clk_i`    | input  | `logic`      | DSP clock (`clk_dsp`), rising edge active |
| `rst_n_i`  | input  | `logic`      | Active-low synchronous reset |
| `enable_i` | input  | `logic`      | When 1: window-based filtering is active. When 0: `s_axis` is forwarded directly to `m_axis` with no line-buffer latency. Must be held stable across an entire frame; toggling mid-frame is undefined. |
| `s_axis`   | input  | `axis_if.rx` | 1-bit mask input stream (DATA_W=1, USER_W=1; tdata[0]=mask pixel, tuser=SOF, tlast=EOL). tready deasserts during phantom cycles when `enable_i=1`; combinationally mirrors `m_axis.tready` when `enable_i=0`. |
| `m_axis`   | output | `axis_if.tx` | 1-bit filtered mask output stream (DATA_W=1, USER_W=1). tlast/tuser regenerated from internal column counter when `enable_i=1`, forwarded when `enable_i=0`. |
| `busy_o`   | output | `logic`      | Asserts when the internal `axis_window3x3` is executing a phantom cycle while upstream presents valid data. Parent should deassert upstream tready for as many cycles as `busy_o` asserts. Stays low in standard VGA-timed integration. Driven low when `enable_i=0`. |

### 3.3 Ports — `axis_morph3x3_open`

`axis_morph3x3_open` exposes the same AXI4-Stream and sideband ports as the sub-modules, minus `busy_o` (the composite does not expose internal phantom-cycle status; standard VGA-timed integration guarantees `busy_o` of both sub-modules stays low).

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| `clk_i`    | input  | `logic`      | DSP clock |
| `rst_n_i`  | input  | `logic`      | Active-low synchronous reset |
| `enable_i` | input  | `logic`      | Forwarded to both `u_erode` and `u_dilate`. When 0, both sub-modules bypass and the composite has zero additional latency. |
| `s_axis`   | input  | `axis_if.rx` | 1-bit mask input stream (DATA_W=1, USER_W=1). tready driven by `u_erode`. |
| `m_axis`   | output | `axis_if.tx` | 1-bit filtered mask output stream (DATA_W=1, USER_W=1). Driven by `u_dilate`. |

---

## 4. Concept Description

### 4.1 Morphological erosion and dilation

For a 1-bit mask with a 3×3 square structuring element:

- **Erosion** = 9-input AND over the window: output is 1 only when all 9 taps (including the centre) are 1. Any background pixel pulls the output to 0.
- **Dilation** = 9-input OR over the window: output is 1 when at least one tap is 1. A foreground pixel expands into all 8 neighbours.

Both are combinational reductions over the window taps; storage and alignment (line buffers, shift registers, edge muxing) are owned by `axis_window3x3`.

### 4.2 Morphological opening

Opening is `dilate(erode(mask))`. Key properties of a 3×3 square opening:

- **Idempotent:** `open(open(M)) = open(M)`.
- **Anti-extensive:** `open(M) ⊆ M`.
- **Removes sub-3×3 features:** a convex blob of width W, height H survives only if W ≥ 3 and H ≥ 3.
- **Preserves survivor size:** the dilation restores survivors to approximately their pre-erosion area; blobs touching the frame edge may be slightly asymmetric due to edge replication.

### 4.3 Edge replication

Off-frame window taps replicate the nearest in-frame pixel (`EDGE_REPLICATE`, inherited from `axis_window3x3`). One consequence for erosion: a foreground pixel at a corner has its three off-frame neighbours replicated from itself, so the AND over the 9-tap window only depends on the in-frame 2×2 region. A 2×2 corner block therefore survives erosion (and is partially restored by dilation).

### 4.4 Thin-feature deletion

A 3×3 square opening deletes any foreground feature narrower than 3 pixels in the **mask** — single pixels, 1-pixel stripes, and 2-pixel-wide bars are all erased. The effective minimum *input-image* feature size depends on the upstream pipeline.

When `axis_motion_detect.GAUSS_EN=1` (default), the 3×3 Gaussian on luma widens every above-threshold feature by one pixel on each side, so a 1-px line in the input RGB becomes a 3-px mask — exactly the minimum that opening preserves.

| Input feature width | Mask width (`GAUSS_EN=0`) | Mask width (`GAUSS_EN=1`) | After opening |
|---------------------|---------------------------|---------------------------|---------------|
| 1 px | 1 px | 3 px | `GAUSS=0`: erased / `GAUSS=1`: preserved |
| 2 px | 2 px | 4 px | `GAUSS=0`: erased / `GAUSS=1`: preserved |
| ≥ 3 px | ≥ 3 px | ≥ 5 px | preserved in both |

Salt-noise suppression (the primary design intent) is unaffected: an isolated-pixel speckle produces a single-pixel mask hit even after the Gaussian, so it is still erased.

---

## 5. Internal Architecture

### 5.1 Block diagram

```
s_axis_*  ──►  ┌─────────────────────┐  mid_*  ┌──────────────────────┐  ──►  m_axis_*
               │ axis_morph3x3_erode │ ──────► │ axis_morph3x3_dilate │
               │                     │         │                      │
               │  axis_window3x3<1>  │         │  axis_window3x3<1>   │
               │  (DATA_WIDTH=1)     │         │  (DATA_WIDTH=1)      │
               │                     │         │                      │
               │  9-way AND (comb)   │         │  9-way OR (comb)     │
               │  output register    │         │  output register     │
               └─────────────────────┘         └──────────────────────┘
```

The internal AXIS link `mid_*` between erode and dilate uses the standard `tdata/tvalid/tready/tlast/tuser` set; `tready` propagates from dilate back to erode.

### 5.2 Sub-module datapath

Each sub-module wraps one `axis_window3x3<DATA_WIDTH=1, EDGE_REPLICATE>`, applies a combinational 9-input reduction over the window taps (AND for erode, OR for dilate), and registers the result. `tlast`/`tuser` are regenerated from a local `(out_col, out_row)` counter advancing on each output beat. Downstream stall (`!m_axis_tready_i`) freezes every register including the inner window primitive; upstream `tready` deasserts only during phantom cycles.

### 5.3 `axis_morph3x3_open` composite

A thin wrapper: instantiates `u_erode` and `u_dilate`, wires the internal AXIS link, and routes `enable_i` to both. No additional logic at this level.

### 5.4 `enable_i` bypass

With `enable_i = 0` each sub-module's reduction is muxed out and the input forwards combinationally to the output. The line buffers stay instantiated but their output is unused. `enable_i` must be frame-stable; toggling mid-frame leaves the line buffers and output counter inconsistent.

### 5.5 Resource cost summary

Per sub-module at `H_ACTIVE=320`:

| Resource | Count |
|----------|-------|
| Line buffer | 2 × `H_ACTIVE` × 1 bit (640 bits) |
| Column shift FFs | 6 |
| d1 pipeline + output counter FFs | `1 + COL_W + ROW_W + 1` + `COL_W + ROW_W` |
| Output register | 4 bits (tdata + tvalid + tlast + tuser) |

The composite uses two such instances, so totals double.

---

## 6. Control Logic and State Machines

No FSM in any of the three modules. Control is combinational gating on `window_valid`, `stall_i`, `sof_i`. The only registered state local to these modules is the `(out_col, out_row)` output counter; the `axis_window3x3` instance owns its own counters. Downstream stall freezes everything; the composite swallows the inner `busy_o` since standard VGA timing keeps it low.

---

## 7. Timing

### 7.1 Latency

| Stage | Latency |
|-------|---------|
| Per sub-module (`axis_window3x3` + output register) | `H_ACTIVE + 3` cycles |
| `axis_morph3x3_open` end-to-end | `2 × (H_ACTIVE + 3)` cycles |
| `enable_i = 0` | 0 cycles (combinational) |
| Steady-state throughput | 1 pixel / cycle |

At `H_ACTIVE=320`/100 MHz this is ~6.5 µs — a one-time fill cost, invisible in a 60 fps pipeline.

### 7.2 Blanking requirements

Same as a single `axis_window3x3` instance: H-blank ≥ 1 cycle per row, V-blank ≥ `H_ACTIVE + 1` cycles. Each stage drains its phantom cycles sequentially (dilate's drain starts only after erode's), so the two do not compound. Standard VGA timing has large margin.

---

## 8. Shared Types

None from `sparevideo_pkg`. Frame geometry parameters (`H_ACTIVE`, `V_ACTIVE`) match the package values when instantiated from `sparevideo_top`.

---

## 9. Known Limitations

- **3×3 fixed kernel only.** The structuring element is a 3×3 square and cannot be parameterized at runtime. A larger kernel (5×5, disk) would require additional line buffers and is a separate module.
- **Thin-feature deletion.** Any foreground feature narrower than 3 pixels in either dimension is removed. Intended for noise suppression, but also deletes thin real objects. See §4.4.
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
