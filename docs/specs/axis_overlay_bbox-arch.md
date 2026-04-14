# `axis_overlay_bbox` Architecture

## 1. Purpose and Scope

`axis_overlay_bbox` draws a 1-pixel-thick rectangle on an RGB888 AXI4-Stream video pipeline using bounding-box coordinates provided as a stable sideband input from `axis_bbox_reduce`. Pixels on the rectangle edge are replaced with `BBOX_COLOR`; all other pixels pass through unchanged. When `bbox_empty_i` is asserted the module is a pure pass-through with zero modification. It does **not** buffer frames, track objects, or generate any sideband output.

---

## 2. Module Hierarchy

`axis_overlay_bbox` is a leaf module — no submodules.

---

## 3. Interface Specification

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line |
| `V_ACTIVE` | 240 | Active lines per frame |
| `BBOX_COLOR` | `24'h00_FF_00` | Rectangle colour (bright green) |

### Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk_i` | input | 1 | DSP clock |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| `s_axis_tdata_i` | input | 24 | RGB888 input pixel |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | AXI4-Stream ready (tied to `m_axis_tready_i`) |
| `s_axis_tlast_i` | input | 1 | End-of-line |
| `s_axis_tuser_i` | input | 1 | Start-of-frame |
| `m_axis_tdata_o` | output | 24 | RGB888 output pixel (overlaid or pass-through) |
| `m_axis_tvalid_o` | output | 1 | AXI4-Stream valid |
| `m_axis_tready_i` | input | 1 | AXI4-Stream ready |
| `m_axis_tlast_o` | output | 1 | End-of-line |
| `m_axis_tuser_o` | output | 1 | Start-of-frame |
| `bbox_min_x_i` | input | `$clog2(H_ACTIVE)` | Left edge of bbox |
| `bbox_max_x_i` | input | `$clog2(H_ACTIVE)` | Right edge of bbox |
| `bbox_min_y_i` | input | `$clog2(V_ACTIVE)` | Top edge of bbox |
| `bbox_max_y_i` | input | `$clog2(V_ACTIVE)` | Bottom edge of bbox |
| `bbox_empty_i` | input | 1 | No motion pixels in last frame — skip overlay |

---

## 4. Datapath Description

### Column/row counters

`col` increments on every accepted pixel (`tvalid && tready`), resets to 0 on `tlast`. `row` increments on `tlast`, resets to 0 on `tuser`.

On `tuser` (SOF), `col` is set to **1** — not 0. The SOF pixel is always at image column 0 and reads the registered `col` before the update fires, so it correctly sees `col=0` from the previous `tlast` or hardware reset. Setting the register to 1 ensures the *next* pixel (image column 1) also sees `col=1`. Without this, every pixel in the first row of each frame would have its column index shifted by 1, causing the `on_rect` predicate to misfire for column-dependent bbox edges.

### Rectangle edge predicate

A pixel at `(col, row)` is on the rectangle edge (`on_rect`) iff:

```
on_rect = !bbox_empty_i && (
    (col == bbox_min_x_i || col == bbox_max_x_i)
        && row >= bbox_min_y_i && row <= bbox_max_y_i
    ||
    (row == bbox_min_y_i || row == bbox_max_y_i)
        && col >= bbox_min_x_i && col <= bbox_max_x_i
)
```

This is purely combinational and evaluates to 1 only on the 4 edges of the bounding rectangle.

### Output pixel selection

```
m_axis_tdata_o = on_rect ? BBOX_COLOR : s_axis_tdata_i
```

All sideband signals (`tvalid`, `tlast`, `tuser`) pass through unchanged. `s_axis_tready_o = m_axis_tready_i` — backpressure propagates directly.

---

## 5. Control Logic

No FSM. The module is fully combinational on the pixel data path; `col` and `row` are the only registered state.

---

## 6. Timing

| Operation | Latency |
|-----------|---------|
| Pixel input → pixel output | 0 cycles (combinational on data, registered counters) |
| Throughput | 1 pixel / cycle |

The bbox sideband signals are stable for the full duration of a frame (latched at EOF by `axis_bbox_reduce`). They never change mid-frame, so the combinational `on_rect` predicate is glitch-free.

---

## 7. Shared Types

None from `sparevideo_pkg`.

---

## 8. Known Limitations

- **1-frame bbox latency**: the bbox inputs reflect the previous frame's motion, so the rectangle drawn on frame N encloses the motion region from frame N−1. The upstream departure-ghost filter in `axis_motion_detect` ensures the bbox tightly wraps the object's position (not the union of old and new positions), so the 1-frame positional lag is the only source of visual offset.
- **1-pixel-thick rectangle only**: no fill, no anti-aliasing, no corner rounding.
- **Single rectangle**: only one bbox can be drawn per frame.
- **No alpha blending**: the overlay is opaque — `BBOX_COLOR` fully replaces the underlying pixel on the edge.
