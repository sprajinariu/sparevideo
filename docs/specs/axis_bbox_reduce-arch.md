# `axis_bbox_reduce` Architecture

## 1. Purpose and Scope

`axis_bbox_reduce` consumes the 1-bit motion mask stream from `axis_motion_detect` and reduces it to a bounding rectangle `{min_x, max_x, min_y, max_y}` that encloses all motion pixels in the frame. The result is latched once per frame at end-of-frame and presented as a stable sideband output to `axis_overlay_bbox`. It does **not** generate an AXI4-Stream output; it does not filter isolated pixels; it does not track multiple objects.

---

## 2. Module Hierarchy

`axis_bbox_reduce` is a leaf module — no submodules.

---

## 3. Interface Specification

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line (sets `col` counter width) |
| `V_ACTIVE` | 240 | Active lines per frame (sets `row` counter width) |

### Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk_i` | input | 1 | DSP clock |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| `s_axis_tdata_i` | input | 1 | Mask pixel (1 = motion) |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | Always 1 — this module never back-pressures |
| `s_axis_tlast_i` | input | 1 | End-of-line |
| `s_axis_tuser_i` | input | 1 | Start-of-frame |
| `bbox_min_x_o` | output | `$clog2(H_ACTIVE)` | Minimum X coordinate of motion region |
| `bbox_max_x_o` | output | `$clog2(H_ACTIVE)` | Maximum X coordinate of motion region |
| `bbox_min_y_o` | output | `$clog2(V_ACTIVE)` | Minimum Y coordinate of motion region |
| `bbox_max_y_o` | output | `$clog2(V_ACTIVE)` | Maximum Y coordinate of motion region |
| `bbox_valid_o` | output | 1 | 1-cycle strobe asserted at the latch cycle (EOF) |
| `bbox_empty_o` | output | 1 | 1 = no motion pixels seen in the completed frame |

---

## 4. Datapath Description

Two sets of registers operate in parallel:

**Scratch accumulators** (update every accepted mask pixel):
- `acc_min_x`, `acc_max_x`: track leftmost and rightmost motion column seen so far.
- `acc_min_y`, `acc_max_y`: track topmost and bottommost motion row seen so far.
- `acc_empty`: 1 if no mask=1 pixel has been seen yet this frame.

Reset to sentinel values at SOF: `acc_min_x = H_ACTIVE−1`, `acc_max_x = 0`, `acc_min_y = V_ACTIVE−1`, `acc_max_y = 0`, `acc_empty = 1`.

**Output registers** (latch at EOF):
- `bbox_{min,max}_{x,y}_o` and `bbox_empty_o` snapshot the accumulators on the last accepted pixel of the frame (`s_axis_tlast_i && s_axis_tvalid_i && row == V_ACTIVE−1`).
- `bbox_valid_o` pulses for 1 cycle at the latch.

**Column/row counters**:
- `col` increments on every accepted pixel; resets to 0 on `tlast`.
- `row` increments on `tlast`; resets to 0 on `tuser`.

---

## 5. Control Logic

No FSM. All logic is `always_ff` register updates gated on `s_axis_tvalid_i` (no ready check needed since `tready` is hardwired 1).

| Condition | Action |
|-----------|--------|
| `tvalid && tuser` | Reset col, row, accumulators |
| `tvalid && tdata == 1` | Update `acc_min/max_x/y` if current `col`/`row` is outside current range |
| `tvalid && tlast` | Increment row, reset col |
| `tvalid && tlast && row == V_ACTIVE−1` | Latch accumulators → output registers; pulse `bbox_valid_o`; reset accumulators for next frame |

---

## 6. Timing

| Event | Latency |
|-------|---------|
| Last accepted mask pixel → `bbox_valid_o` | 1 cycle |
| Output registers stable | From `bbox_valid_o` until next `bbox_valid_o` (one full frame) |
| Throughput | 1 mask pixel / cycle (always ready) |

The output bbox is stable for the entire duration of the *next* frame, making it safe for `axis_overlay_bbox` to read combinationally without synchronization.

---

## 7. Shared Types

None from `sparevideo_pkg`.

---

## 8. Known Limitations

- **No hysteresis or minimum-size filter**: a single isolated motion pixel produces a 1×1 bbox. The overlay will draw a 1×1 green dot, which may flicker on noisy inputs.
- **Single-object**: only one bbox is maintained. Multiple disjoint motion regions are merged into their convex hull (actually the axis-aligned bounding box of their union).
- **1-frame bbox latency**: the box drawn on frame N is from frame N−1 motion.
- **`bbox_valid_o` unused at top level**: `sparevideo_top` ties this signal off. It is available for future debug or CDC logic.
