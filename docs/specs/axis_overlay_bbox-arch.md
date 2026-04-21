# `axis_overlay_bbox` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Column/row counters](#51-columnrow-counters)
  - [5.2 Rectangle edge predicate](#52-rectangle-edge-predicate)
  - [5.3 Output pixel selection](#53-output-pixel-selection)
  - [5.4 Resource cost](#54-resource-cost)
- [6. Control Logic and State Machines](#6-control-logic-and-state-machines)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_overlay_bbox` draws up to `N_OUT` 1-pixel-thick rectangles on an RGB888 AXI4-Stream video pipeline using per-slot bounding-box coordinates provided as a stable sideband input from `axis_ccl`. A pixel is replaced with `BBOX_COLOR` whenever any valid slot's rectangle hits it; otherwise it passes through unchanged. When every `bbox_valid_i[k]` bit is 0 the module is a pure pass-through with zero modification. It does **not** buffer frames, track objects, or generate any sideband output.

---

## 2. Module Hierarchy

`axis_overlay_bbox` is a leaf module — no submodules.

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line |
| `V_ACTIVE` | 240 | Active lines per frame |
| `BBOX_COLOR` | `24'h00_FF_00` | Rectangle colour (bright green) |

### 3.2 Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk_i` | input | 1 | DSP clock |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| **AXI4-Stream input — video (RGB888)** | | | |
| `s_axis_tdata_i` | input | 24 | RGB888 input pixel |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | AXI4-Stream ready (tied to `m_axis_tready_i`) |
| `s_axis_tlast_i` | input | 1 | End-of-line |
| `s_axis_tuser_i` | input | 1 | Start-of-frame |
| **AXI4-Stream output — video (RGB888)** | | | |
| `m_axis_tdata_o` | output | 24 | RGB888 output pixel (overlaid or pass-through) |
| `m_axis_tvalid_o` | output | 1 | AXI4-Stream valid |
| `m_axis_tready_i` | input | 1 | AXI4-Stream ready |
| `m_axis_tlast_o` | output | 1 | End-of-line |
| `m_axis_tuser_o` | output | 1 | Start-of-frame |
| **Sideband input — `N_OUT` bbox slots from axis_ccl** | | | |
| `bbox_valid_i` | input | `N_OUT` | Per-slot valid bit — slot contributes to the overlay when 1. |
| `bbox_min_x_i` | input | `N_OUT × $clog2(H_ACTIVE)` | Per-slot left edge |
| `bbox_max_x_i` | input | `N_OUT × $clog2(H_ACTIVE)` | Per-slot right edge |
| `bbox_min_y_i` | input | `N_OUT × $clog2(V_ACTIVE)` | Per-slot top edge |
| `bbox_max_y_i` | input | `N_OUT × $clog2(V_ACTIVE)` | Per-slot bottom edge |

---

## 4. Concept Description

Video overlay is the process of compositing graphical elements onto a live video stream in real time. In the simplest form — conditional pixel substitution — each pixel passes through unchanged unless a spatial predicate is satisfied, in which case the pixel value is replaced with a fixed overlay colour.

This module implements multi-rectangle edge overlay: for each pixel in the raster-order stream, a combinational `N_OUT`-wide predicate determines whether the pixel lies on one of the four edges of any valid bounding rectangle `{min_x[k], max_x[k], min_y[k], max_y[k]}`. The edge predicate per slot is the union of four line segments (left, right, top, bottom); the final `on_rect` is the OR across all valid slots. Pixels matching the predicate are replaced with `BBOX_COLOR`; all others pass through unmodified.

The approach requires zero frame buffering — the overlay is applied in a single pass through the streaming pixel data with purely combinational logic on the data path. This makes it suitable for real-time video pipelines with strict latency and resource requirements. The bbox coordinates are provided as stable sideband inputs (committed once per frame by `axis_ccl`'s `PHASE_SWAP` into its front register bank), so there is no synchronization hazard.

---

## 5. Internal Architecture

### 5.1 Column/row counters

`col` increments on every accepted pixel (`tvalid && tready`), resets to 0 on `tlast`. `row` increments on `tlast`, resets to 0 on `tuser`.

On `tuser` (SOF), `col` is set to **1** — not 0. The SOF pixel is always at image column 0 and reads the registered `col` before the update fires, so it correctly sees `col=0` from the previous `tlast` or hardware reset. Setting the register to 1 ensures the *next* pixel (image column 1) also sees `col=1`. Without this, every pixel in the first row of each frame would have its column index shifted by 1, causing the `on_rect` predicate to misfire for column-dependent bbox edges.

### 5.2 Rectangle edge predicate

A pixel at `(col, row)` hits slot `k`'s rectangle edge (`bbox_hit[k]`) iff:

```
bbox_hit[k] = bbox_valid_i[k] && (
    (col == bbox_min_x_i[k] || col == bbox_max_x_i[k])
        && row >= bbox_min_y_i[k] && row <= bbox_max_y_i[k]
    ||
    (row == bbox_min_y_i[k] || row == bbox_max_y_i[k])
        && col >= bbox_min_x_i[k] && col <= bbox_max_x_i[k]
)

on_rect = |bbox_hit      // OR across all N_OUT slots
```

Implemented with a `generate for` loop that fans out one hit-test per slot; the OR-reduction closes the logic. Purely combinational; glitch-free while bbox inputs are stable.

### 5.3 Output pixel selection

```
m_axis_tdata_o = on_rect ? BBOX_COLOR : s_axis_tdata_i
```

All sideband signals (`tvalid`, `tlast`, `tuser`) pass through unchanged. `s_axis_tready_o = m_axis_tready_i` — backpressure propagates directly.

### 5.4 Resource cost

The module uses two counters (`$clog2(H_ACTIVE)` + `$clog2(V_ACTIVE)` bits), `N_OUT × 6` comparators for the per-slot edge predicates, an `N_OUT`-wide OR-reduction, and one 24-bit 2:1 MUX for the output pixel selection. No RAM, DSP, or pipeline registers on the data path — the overlay is purely combinational with zero added latency.

---

## 6. Control Logic and State Machines

No FSM. The module is fully combinational on the pixel data path; `col` and `row` are the only registered state.

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| Pixel input → pixel output | 0 cycles (combinational on data, registered counters) |
| Throughput | 1 pixel / cycle |

The bbox sideband signals are stable for the full duration of a frame (committed at EOF by `axis_ccl`'s `PHASE_SWAP` into its front register bank). They never change mid-frame, so the combinational per-slot `bbox_hit[k]` predicates — and the final OR-reduced `on_rect` — are glitch-free.

---

## 8. Shared Types

None from `sparevideo_pkg`.

---

## 9. Known Limitations

- **1-frame bbox latency**: the bbox inputs reflect the previous frame's motion, so the rectangle drawn on frame N encloses the motion region from frame N−1. The upstream mask is polarity-agnostic (flags both arrival and departure pixels), so the bbox is slightly larger than the object by approximately the per-frame displacement, plus the 1-frame positional lag.
- **1-pixel-thick rectangle only**: no fill, no anti-aliasing, no corner rounding.
- **Up to `N_OUT` rectangles**: the number of rectangles drawn per frame is capped by `N_OUT` (default 8). Overlapping rectangles OR together (no layered drawing); all use the same `BBOX_COLOR`.
- **No alpha blending**: the overlay is opaque — `BBOX_COLOR` fully replaces the underlying pixel on the edge.

---

## 10. References

- [AMBA AXI4-Stream Protocol Specification — Arm](https://developer.arm.com/documentation/ihi0051/latest/)
