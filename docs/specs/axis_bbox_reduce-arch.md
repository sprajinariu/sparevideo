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
| **AXI4-Stream input — mask (1 bit)** | | | |
| `s_axis_tdata_i` | input | 1 | Mask pixel (1 = motion) |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | Always 1 — this module never back-pressures |
| `s_axis_tlast_i` | input | 1 | End-of-line |
| `s_axis_tuser_i` | input | 1 | Start-of-frame |
| **Sideband output — latched bbox** | | | |
| `bbox_min_x_o` | output | `$clog2(H_ACTIVE)` | Minimum X coordinate of motion region |
| `bbox_max_x_o` | output | `$clog2(H_ACTIVE)` | Maximum X coordinate of motion region |
| `bbox_min_y_o` | output | `$clog2(V_ACTIVE)` | Minimum Y coordinate of motion region |
| `bbox_max_y_o` | output | `$clog2(V_ACTIVE)` | Maximum Y coordinate of motion region |
| `bbox_valid_o` | output | 1 | 1-cycle strobe asserted at the latch cycle (EOF) |
| `bbox_empty_o` | output | 1 | 1 = no motion pixels seen in the completed frame |

---

## 4. Concept Description

Bounding box reduction is a streaming min/max aggregation algorithm. Given a binary mask where each pixel is either 0 (background) or 1 (foreground), the algorithm computes the axis-aligned bounding box (AABB) of all foreground pixels by tracking four extremes: the minimum and maximum column (x) and row (y) indices where a foreground pixel appears.

This is an online algorithm — each pixel is processed exactly once as it arrives in raster order, requiring no frame buffer or random access to the image. The min/max accumulators are initialized to sentinel values at the start of each frame (`min` to the maximum possible value, `max` to 0), and updated whenever a foreground pixel is accepted. At end-of-frame, the accumulators are latched into output registers where they remain stable for the entire subsequent frame.

Mathematically, the algorithm computes: `min(x)`, `max(x)`, `min(y)`, `max(y)` over the set `{(x,y) : mask(x,y) = 1}`. Since the stream arrives in raster order (left-to-right, top-to-bottom), `min_y` is always the row of the first foreground pixel and `max_y` is the row of the last. The column extremes require running comparisons across all rows.

The result is a single bounding rectangle per frame. Multiple disjoint foreground regions are merged into the AABB of their union — for example, two separate moving objects produce one large bbox encompassing both.

---

## 5. Internal Architecture

Two sets of registers operate in parallel:

**Scratch accumulators** (update every accepted mask pixel):
- `sc_min_x`, `sc_max_x`: track leftmost and rightmost motion column seen so far.
- `sc_min_y`, `sc_max_y`: track topmost and bottommost motion row seen so far.
- `sc_any`: 1 if at least one mask=1 pixel has been seen this frame.

On SOF (`tuser=1`) the scratch is initialised in one of two ways (see §6).

**Output registers** (latch one cycle after EOF):
- `bbox_{min,max}_{x,y}_o` and `bbox_empty_o` snapshot the scratch accumulators one cycle after EOF (i.e. one cycle after `s_axis_tlast_i && s_axis_tvalid_i && row == V_ACTIVE−1`). The one-cycle delay is necessary because the EOF pixel's scratch update is an NBA assignment that commits at end-of-cycle; reading the scratch in the *same* cycle would capture stale values.
- `bbox_valid_o` pulses for 1 cycle at the latch (2 cycles after the last accepted mask pixel).

**Column/row counters**:
- `col` increments on every accepted pixel; resets to 0 on `tlast`.
- On `tuser` (SOF), `col` is set to **1** — not 0. The SOF pixel itself is always at image column 0 and reads `col` before the register update, so it correctly sees `col=0`. Setting the register to 1 ensures that the *next* pixel (image column 1) also sees `col=1`. Without this correction the entire first row would have its column indices shifted by 1.
- `row` increments on `tlast`; resets to 0 on `tuser`.

### Resource cost

The module uses four min/max accumulator registers (each `$clog2(H_ACTIVE)` or `$clog2(V_ACTIVE)` bits wide), two position counters, and a set of comparators for the per-pixel min/max updates. No RAM or DSP resources are used.

---

## 6. Control Logic and State Machines

No FSM. All logic is `always_ff` register updates gated on `s_axis_tvalid_i` (no ready check needed since `tready` is hardwired 1).

### Scratch accumulator update (priority order, evaluated each accepted pixel)

| Condition | Action |
|-----------|--------|
| `tvalid && tuser && tdata == 1` | SOF pixel has motion: initialise `sc_min/max_x/y` directly to `(0,0)` and set `sc_any=1`. Direct initialisation avoids a comparison race — the SOF reset and the min/max update cannot be separated into independent branches when the pixel is at (0,0). |
| `tvalid && tuser && tdata == 0` | SOF pixel, no motion: reset scratch to sentinels (`sc_min_x='1`, `sc_max_x='0`, …) and clear `sc_any`. |
| `tvalid && !tuser && tdata == 1` | Non-SOF motion pixel: `sc_any=1`; update `sc_min/max_x/y` by comparison with `col`/`row`. |

### Column/row counter update

| Condition | Action |
|-----------|--------|
| `tvalid && tuser` | `col <= 1`, `row <= 0` (see §5 for why col is set to 1, not 0) |
| `tvalid && tlast` | `col <= 0`, `row <= row + 1` |
| `tvalid && !tuser && !tlast` | `col <= col + 1` |

### Output latch

| Condition | Action |
|-----------|--------|
| `is_eof_r` (one cycle after EOF) | Snapshot `sc_*` → `bbox_*_o`; pulse `bbox_valid_o` for 1 cycle |

`is_eof` is a combinational flag (`tvalid && tlast && row == V_ACTIVE−1`). It is registered into `is_eof_r` so the latch fires one cycle later, after the EOF pixel's NBA scratch updates have committed.

---

## 7. Timing

| Event | Latency |
|-------|---------|
| Last accepted mask pixel (EOF) → `bbox_valid_o` | 2 cycles (1 for `is_eof` → `is_eof_r`, 1 for latch → output) |
| Output registers stable | From `bbox_valid_o` until next `bbox_valid_o` (one full frame) |
| Throughput | 1 mask pixel / cycle (always ready) |

The output bbox is stable for the entire duration of the *next* frame, making it safe for `axis_overlay_bbox` to read combinationally without synchronization. The 2-cycle latch delay does not affect overlay correctness because both the mask stream and the overlay input are in the same clock domain and the bbox is consumed by the *following* frame.

---

## 8. Shared Types

None from `sparevideo_pkg`.

---

## 9. Known Limitations

- **No hysteresis or minimum-size filter**: a single isolated motion pixel produces a 1×1 bbox. The overlay will draw a 1×1 green dot, which may flicker on noisy inputs.
- **Single-object**: only one bbox is maintained. Multiple disjoint motion regions are merged into the axis-aligned bounding box of their union (e.g. `synthetic:two_boxes` produces one large bbox encompassing both objects).
- **1-frame bbox latency**: the box drawn on frame N is from frame N−1 motion.
- **Bbox oversizing**: the upstream mask is polarity-agnostic (`diff > THRESH` only), flagging both arrival and departure pixels. The bbox is slightly larger than the object by approximately the per-frame displacement. This is a deliberate trade-off for scene-type independence.
- **RAM priming**: the first 2 frames after reset are suppressed (`bbox_empty` forced high) via an internal `PrimeFrames` counter, preventing false full-frame bboxes caused by the zeroed Y-prev RAM.
- **`bbox_valid_o` unused at top level**: `sparevideo_top` ties this signal off. It is available for future debug or CDC logic.

---

## 10. References

- [Bounding box — Wikipedia](https://en.wikipedia.org/wiki/Minimum_bounding_box)
