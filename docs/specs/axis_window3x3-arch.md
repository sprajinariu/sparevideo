# `axis_window3x3` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.1 Centered sliding window](#41-centered-sliding-window)
  - [4.2 Edge replication](#42-edge-replication)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Data flow overview](#51-data-flow-overview)
  - [5.2 Row/column counters](#52-rowcolumn-counters)
  - [5.3 Phantom-cycle drain and blanking](#53-phantom-cycle-drain-and-blanking)
  - [5.4 Line buffers](#54-line-buffers-distributed-ram-depth--h_active-width--data_width)
  - [5.5 Column shift registers](#55-column-shift-registers-6-ffs-at-data_width8)
  - [5.6 Edge replication muxing](#56-edge-replication-muxing-combinational)
  - [5.7 Window output and off-frame suppression](#57-window-output-and-off-frame-suppression)
  - [5.8 Resource cost summary](#58-resource-cost-summary)
- [6. Control Logic and State Machines](#6-control-logic-and-state-machines)
- [7. Timing](#7-timing)
- [8. Consumers](#8-consumers)
- [9. Risks / Known Limitations](#9-risks--known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_window3x3` is a reusable 3×3 sliding-window primitive. It owns the shared infrastructure required by any centered 3×3 spatial filter: row/column counters with phantom-cycle drain, two line buffers (raster-scan row history), 3-row × 3-column column shift registers, and edge-replication muxing at all four borders. It emits a combinational **9-tap window** at the `d1` pipeline stage, together with `window_valid_o` (off-frame-suppressed) and `busy_o` for the no-blanking fallback path.

This module does **not** apply any arithmetic operation to the window. Each consumer (e.g., `axis_gauss3x3`) instantiates `axis_window3x3`, adds its own combinational operation on the 9 window taps, and closes the pipeline with a single output register. This separation keeps the shared timing and state logic in one place, verified once, and reused across all 3×3 consumers without duplication.

`axis_window3x3` does not implement its own AXI4-Stream handshake. Control is exerted by the parent via `valid_i`, `sof_i`, and `stall_i`. The module never generates backpressure on its own; `busy_o` is a flag for the parent to use if it needs to hold off the upstream source.

---

## 2. Module Hierarchy

`axis_window3x3` is a leaf module — no submodules. It is instantiated by filter wrappers as `u_window`.

```
axis_gauss3x3    (u_gauss, in axis_motion_detect)
└── axis_window3x3  (u_window)   ← this module

[future]
axis_morph_erode
└── axis_window3x3  (u_window, DATA_WIDTH=1)

axis_morph_dilate
└── axis_window3x3  (u_window, DATA_WIDTH=1)
```

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DATA_WIDTH` | 8 | Width of each pixel word in bits. Set to 1 for binary (mask) consumers. |
| `H_ACTIVE` | 320 | Active pixels per line (line buffer depth, counter range). |
| `V_ACTIVE` | 240 | Active lines per frame (row counter range). |
| `EDGE_POLICY` | 0 (REPLICATE) | Selects how off-frame neighbours are filled when the window overlaps a frame border. See the enum below. |

**EDGE_POLICY enum** — SystemVerilog has no cross-file enums without a package, so callers pass the integer value directly.

| Value | Name | Status | Behaviour |
|-------|------|--------|-----------|
| 0 | `EDGE_REPLICATE` | implemented | Off-frame taps take the value of the nearest in-frame pixel on the same side. |
| 1 | `EDGE_ZERO` | reserved | Would emit `0` for off-frame taps. |
| 2 | `EDGE_CONSTANT` | reserved | Would emit a parameterised constant for off-frame taps. |
| 3 | `EDGE_MIRROR` | reserved | Would mirror in-frame pixels across the border. |

Passing any value other than `0` triggers an elaboration-time `$fatal` — this lets new policies slot in later without silently changing semantics for existing callers. See §9 for the rationale.

### 3.2 Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| **Clock and reset** | | | |
| `clk_i` | input | 1 | Processing clock (`clk_dsp`), rising edge |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| **Control** | | | |
| `valid_i` | input | 1 | Upstream beat valid — real pixel available this cycle |
| `sof_i` | input | 1 | Start-of-frame — resets `row`/`col` counters on the next advance |
| `stall_i` | input | 1 | Pipeline stall — freezes all registered state when asserted |
| `busy_o` | output | 1 | Module is at a phantom position while upstream presents `valid_i=1`. The parent must deassert upstream `tready` for as many cycles as `busy_o` remains asserted. Stays low in standard VGA-timed integration where blanking is always available. |
| **Data** | | | |
| `din_i` | input | `DATA_WIDTH` | Input data word (one pixel per beat) |
| `window_o[9]` | output | `9 × DATA_WIDTH` | Combinational 3×3 window, row-major flat array. See index map below. |
| `window_valid_o` | output | 1 | Combinational — asserts when the `window_o` values correspond to a valid output pixel. Off-frame positions (output coordinate `(row_d1−1, col_d1−1)` with `row_d1==0` or `col_d1==0`) are suppressed. |

**Window index map:**

```
window_o[0]=TL  window_o[1]=TC  window_o[2]=TR
window_o[3]=ML  window_o[4]=CC  window_o[5]=MR
window_o[6]=BL  window_o[7]=BC  window_o[8]=BR
```

No `tready` output — the module never generates backpressure. Stall is external.

---

## 4. Concept Description

### 4.1 Centered sliding window

A centered 3×3 window places the current pixel at the center. For each output pixel at position (r, c), the window simultaneously presents the 3×3 neighborhood `{(r±1, c±1)}`. Because pixels arrive in raster-scan order (one per cycle), the window for position (r, c) cannot be complete until the pixel at (r+1, c+1) — the bottom-right corner — has been received.

This produces an initial fill latency before the first `window_valid_o`: the first real pixel enters at cycle 0, and the first complete window appears at cycle `H_ACTIVE + 2` (one full row for the first line buffer fill, one column for the first column shift fill, plus one pipeline register). After fill, throughput is 1 pixel/cycle.

This module emits the **combinational window at the d1 stage**, one register earlier than `axis_gauss3x3` did before the refactor. Each consumer closes its own pipeline with one output register, so the end-to-end consumer latency remains `H_ACTIVE + 3` for `axis_gauss3x3` (kernel `H_ACTIVE + 2` + wrapper register `+1`).

### 4.2 Edge replication

At image borders, the 3×3 window extends outside the frame. Border pixel replication (the `REPLICATE` policy) clamps out-of-bounds coordinates to the nearest valid pixel. The table below lists the RTL mux conditions and the replication mechanism.

| Scan position (`row_d1` / `col_d1`) | Affected window row/col | Mechanism |
|--------------------------------------|-------------------------|-----------|
| `row_d1 == 1` | Top row of window | Mux: top row ← middle row (`r1_c*`) |
| `row_d1 == V_ACTIVE` | Bottom row of window | Mux: bottom row ← middle row (phantom row) |
| `col_d1 == 1` | Left column of window | Mux: left column ← center column (`*_c1`) |
| `col_d1 == H_ACTIVE` | Right column of window | Implicit: `lb_active_col` suppresses LB/shift updates, so `*_c0` aliases `*_c1` |
| All other positions | Interior | Default (no override) |

Scan positions where `row_d1 == 0` or `col_d1 == 0` never emit output (`window_valid_o` suppressed) and require no mux.

---

## 5. Internal Architecture

### 5.1 Data flow overview

The storage problem for a streaming 3×3 window splits along two spatial axes:

- **Line buffers (row history).** Two RAMs (`lb_top_mem`, `lb_mid_mem`), each `H_ACTIVE` entries deep, store the two most recent rows. When the scan is at row r, `lb_top_mem` holds row r−2 and `lb_mid_mem` holds row r−1. A read at column c delivers one pixel from each stored row, giving three co-aligned pixels (top, middle, bottom of the window column).
- **Column shift registers (column history within each row).** Each of the three row streams feeds a 2-deep shift register, turning the single live tap at column c into three taps: c (current), c−1 (one cycle ago), c−2 (two cycles ago). Three rows × 2 shift registers = 6 FFs per data bit.

The datapath below flows top-to-bottom.

```
                         din_i [DATA_WIDTH-1:0]
           ┌──────────────────────┤
           │                      ▼
           │            lb_mid_mem[cur_col] = din_i        (real_pixel only)
           │               ┌────────────────┐
           │               │    lb_mid      │   Row r−1
           │               │    DPRAM       │
           │               └───────┬────────┘
           │                       ├──cascade──────────────┐
           │                       │                       │  lb_top_mem[cur_col] = lb_mid_mem[cur_col]
           │                       │               ┌───────▼───────┐
           │                       │               │    lb_top     │   Row r−2
           │                       │               │    DPRAM      │
           │                       │               └───────┬───────┘
           ▼                       ▼                       ▼
      ┌──────────┐         ┌──────────────┐       ┌──────────────┐
      │  y_d1 FF │         │ lb_mid_rd FF │       │ lb_top_rd FF │   d1 stage
      └────┬─────┘         └──────┬───────┘       └──────┬───────┘
           │                      │                       │
      row r live             row r−1 middle           row r−2 top
           │                      │                       │
           ▼                      ▼                       ▼
      ┌──────────┐         ┌──────────────┐       ┌──────────────┐
      │ r0_c1 FF │         │  r1_c1 FF   │       │  r2_c1 FF   │
      └────┬─────┘         └──────┬───────┘       └──────┬───────┘   column
           ▼                      ▼                       ▼           shift
      ┌──────────┐         ┌──────────────┐       ┌──────────────┐
      │ r0_c2 FF │         │  r1_c2 FF   │       │  r2_c2 FF   │
      └────┬─────┘         └──────┬───────┘       └──────┬───────┘
           │                      │                       │
      {c2,c1,c0}           {c2,c1,c0}             {c2,c1,c0}
      bottom row            middle row              top row
           └────────────┬─────────┴────────────┬──────────┘
                        ▼                       ▼
              ┌─────────────────────────────────────┐
              │       Edge-replication muxes        │
              └────────────────┬────────────────────┘
                               ▼
                    window_o[9], window_valid_o
```

### 5.2 Row/column counters

Registered counters `col` (`COL_W = $clog2(H_ACTIVE+1)` bits) and `row` (`ROW_W = $clog2(V_ACTIVE+1)` bits) track scan position within the extended range `[0 .. H_ACTIVE] × [0 .. V_ACTIVE]`, which includes the phantom column (`col == H_ACTIVE`) and phantom row (`row == V_ACTIVE`). A combinational `cur_col`/`cur_row` computes the position for the upcoming advance (real or phantom) without a registered intermediate.

On `sof_i && valid_i` both counters reset to 0. On each `advance` pulse (real pixel or phantom cycle, not stalled) the counters step to `cur_col`/`cur_row`.

```
at_phantom_col = (cur_col == H_ACTIVE)
at_phantom_row = (cur_row == V_ACTIVE)
at_phantom     = at_phantom_col || at_phantom_row
real_pixel     = valid_i && !stall_i && !at_phantom
phantom        = !stall_i && at_phantom
advance        = real_pixel || phantom
busy_o         = valid_i && at_phantom
```

### 5.3 Phantom-cycle drain and blanking

After all `H_ACTIVE` real pixels of row r have been consumed, the centered window for the last real column (c = H_ACTIVE−1) needs column c+1 = H_ACTIVE, which does not exist. The module self-clocks one **phantom column** cycle at `cur_col == H_ACTIVE` with no new pixel consumed. This closes the window for the rightmost pixel of the row.

After the last real row (row V_ACTIVE−1), `H_ACTIVE + 1` **phantom row** cycles drain the remaining centered outputs for the bottom row.

In standard VGA-timed integration these phantom cycles execute during H-blank and V-blank respectively (`valid_i = 0`). When blanking is unavailable (back-to-back frames), `busy_o` asserts and the parent deasserts upstream `tready` for the phantom duration.

**Blanking requirements:**

| Blanking type | Minimum cycles | Absorbs |
|---------------|---------------|---------|
| H-blank | 1 cycle per row | 1 phantom column per row |
| V-blank | H_ACTIVE + 1 cycles total | H_ACTIVE + 1 phantom row cycles |

Standard TB parameters (`H_BLANK = 16`, `V_BLANK = 6 lines`) exceed both minimums comfortably.

### 5.4 Line buffers (distributed RAM, depth = `H_ACTIVE`, width = `DATA_WIDTH`)

Two line buffers hold the two previous rows. On each real pixel at column c:

```
lb_top_rd = lb_top_mem[cur_col]      // read before write
lb_mid_rd = lb_mid_mem[cur_col]
lb_top_mem[cur_col] = lb_mid_mem[cur_col]   // cascade: middle → oldest
lb_mid_mem[cur_col] = din_i                  // current pixel → middle
```

During phantom cycles `lb_active_col` is false (`cur_col == H_ACTIVE`), so line buffer writes are gated off. The read registers (`lb_top_rd`, `lb_mid_rd`) are also not updated on phantom cycles — the edge-replication mux uses the last valid read, which is correct because the phantom cycle replicates the rightmost real column.

**Resource cost:** At default 320 px, each buffer is 320 × `DATA_WIDTH` bits. For `DATA_WIDTH=8`: ~640 bytes total, inferred as distributed RAM.

### 5.5 Column shift registers (6 FFs at `DATA_WIDTH=8`)

After the d1 register stage, each row stream feeds a 2-deep shift register. The `_c0` taps are combinational aliases to the d1-stage signals; only `_c1` and `_c2` are registered.

```
r2: lb_top_rd → r2_c1 → r2_c2    (top row:    c, c−1, c−2)
r1: lb_mid_rd → r1_c1 → r1_c2    (middle row: c, c−1, c−2)
r0: y_d1      → r0_c1 → r0_c2    (bottom row: c, c−1, c−2)
```

Shift registers are gated by `!stall_i && valid_d1`. During phantom right-edge cycles, no new input is shifted in; the edge mux supplies the replicated right-border value instead.

### 5.6 Edge replication muxing (combinational)

The window `win[3][3]` defaults to the shift-register outputs. Combinational muxes override the appropriate rows/columns based on `row_d1` and `col_d1`, as described in §4.2. The mux operates on d1-stage signals and is entirely combinational.

The right-edge case is implicit: because `lb_active_col` is false when `cur_col == H_ACTIVE`, the line buffer reads are not updated and `y_d1` retains the last real column's value. The shift register chain therefore presents the same value in all three column taps (`*_c0 == *_c1 == *_c2`), producing right-edge replication without an explicit mux.

### 5.7 Window output and off-frame suppression

The 9-tap flat window maps directly from `win[row][col]`:

```
window_o[0]=win[0][0]  window_o[1]=win[0][1]  window_o[2]=win[0][2]  (top row)
window_o[3]=win[1][0]  window_o[4]=win[1][1]  window_o[5]=win[1][2]  (middle row)
window_o[6]=win[2][0]  window_o[7]=win[2][1]  window_o[8]=win[2][2]  (bottom row)
```

`window_valid_o` suppresses scan positions before the first real output coordinate:

```
window_valid_o = valid_d1 && (row_d1 != 0) && (col_d1 != 0)
```

The output pixel coordinate is `(row_d1 − 1, col_d1 − 1)`. Positions `row_d1 == 0` or `col_d1 == 0` map to the pre-fill pipeline flush and carry no valid output.

### 5.8 Resource cost summary

| Resource | Count |
|----------|-------|
| Line buffer memory | 2 × H_ACTIVE × DATA_WIDTH bits (~640 B at 320px, DATA_WIDTH=8) |
| Column shift register FFs | 6 × DATA_WIDTH bits (48 bits at DATA_WIDTH=8) |
| d1 pipeline registers | DATA_WIDTH (y_d1) + COL_W (col_d1) + ROW_W (row_d1) + 1 (valid_d1) |
| Counter / control FFs | COL_W (col) + ROW_W (row) |
| Edge mux | Combinational only |
| Multipliers | 0 |

---

## 6. Control Logic and State Machines

No FSM. All control is combinational gating on `valid_i`, `stall_i`, `sof_i`, and the derived phantom/advance signals. The row/column counters are the only registered control state.

| Signal | Condition | Effect |
|--------|-----------|--------|
| `sof_i && valid_i` | `!stall_i` | Counters reset to 0; in-flight phantom cycles from previous frame are cancelled |
| `stall_i` | asserted | All FFs frozen (line buffers, shift regs, d1 stage, counters) |
| `real_pixel` | `valid_i && !stall_i && !at_phantom` | Line buffer write, d1 advance, shift register advance |
| `phantom` | `!stall_i && at_phantom` | d1 advance without line buffer write; closes window for phantom position |
| `busy_o` | `valid_i && at_phantom` | Phantom drain needed but real pixel presented; parent should deassert upstream tready |

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| `din_i` → line buffer read (`lb_top_rd`, `lb_mid_rd`, `y_d1`) | 1 clock cycle |
| Column shift → edge mux → `window_o` (combinational) | 0 clock cycles |
| **Total: `din_i` → first `window_valid_o`** | **H_ACTIVE + 2 clock cycles** |
| Consumer output register (`axis_gauss3x3`) | +1 clock cycle (wrapper) |
| **End-to-end `y_i` → `y_o` in `axis_gauss3x3`** | **H_ACTIVE + 3 clock cycles** |
| Steady-state throughput | 1 pixel / cycle (when `!stall_i`) |
| Phantom cycles per row | 1 (absorbed in H-blank ≥ 1 cycle) |
| Phantom cycles per frame (bottom-row drain) | H_ACTIVE + 1 (absorbed in V-blank ≥ H_ACTIVE + 1 cycles) |

This is one cycle shorter than the pre-refactor `axis_gauss3x3` window stage because the output register now lives in each wrapper rather than inside the shared primitive.

---

## 8. Consumers

**`axis_gauss3x3`** (implemented, in `hw/ip/filters/rtl/`) — wraps `axis_window3x3` with `DATA_WIDTH=8`, applies the Gaussian kernel `[1 2 1; 2 4 2; 1 2 1] / 16` as a combinational adder tree (all shifts, no multipliers), and closes with a single output register. The external interface is unchanged from the pre-refactor monolithic implementation.

**`axis_morph_erode`** and **`axis_morph_dilate`** (planned) — will wrap `axis_window3x3` with `DATA_WIDTH=1`. Each will apply a single combinational AND (erosion) or OR (dilation) across the 9 window taps and register the result. The pattern is identical to `axis_gauss3x3`: instantiate the kernel, apply op, register output.

Any future 3×3 consumer should follow the same wrapper pattern: instantiate `axis_window3x3`, apply a combinational operation on `window_o[9]`, and close with one output register gated by `!stall_i`.

---

## 9. Risks / Known Limitations

**Risk C1 (addressed): factored-out primitive — consumer regressions.**
This module was extracted from the former monolithic `axis_gauss3x3`. Any consumer that changes its semantics (e.g., by changing scan timing or edge policy) must re-gate against a saved motion-pipeline golden. The extraction refactor was verified byte-identical via the full `run-pipeline` regression across all control flows and `ALPHA_SHIFT` combinations (see `docs/plans/2026-04-23-pipeline-extensions-design.md` §5.3).

**Only `EDGE_REPLICATE` is implemented.**
The `EDGE_POLICY` parameter and enum are in place (see §3.1), but values other than `0` (`EDGE_REPLICATE`) trigger an elaboration-time `$fatal`. Reserved policies (ZERO, CONSTANT, MIRROR) can be slotted in later without breaking callers: the parameter is already on every instantiation, and new values will fail loud instead of silently falling through to REPLICATE. Each new policy must ship with a dedicated testbench case.

**H_ACTIVE + 2 initial latency.**
The first `window_valid_o` appears `H_ACTIVE + 2` cycles after the first `valid_i`. At 100 MHz this is 3.2 µs at 320px — negligible in a 60 fps pipeline. Consumers must account for this latency in any downstream alignment (e.g., `axis_motion_detect` uses `idx_pipe` to delay the pixel address by the total consumer latency).

**Distributed RAM at 320px.**
Each line buffer is 320 × `DATA_WIDTH` bits. At 8-bit data and 320px, synthesis infers distributed RAM (LUT-RAM). At higher resolutions (e.g., 1920px) BRAM inference would be preferable. No synthesis pragmas are applied; the user is responsible for appropriate resource constraints at non-default geometries.

**SOF does not flush line buffers.**
`sof_i` resets the row/col counters but does not zero `lb_top_mem`/`lb_mid_mem`. The first two rows of a new frame refill the buffers via the cascade. Stale data from a previous frame is visible in the top/middle line buffers for the first two rows but is masked by edge replication (rows 0 and 1 produce top-row replication, so the stale buffer contents are not used as the unmodified top row until row 2, by which point the cascade has populated them correctly).

---

## 10. References

- [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) — Gaussian pre-filter architecture; describes the consumer pattern in detail and the original monolithic design from which `axis_window3x3` was extracted.
- [`axis_motion_detect-arch.md`](axis_motion_detect-arch.md) — Motion-detection pipeline; shows how `axis_gauss3x3` (and transitively `axis_window3x3`) fits into the broader pipeline.
- **MathWorks Vision HDL Toolbox** — `floor(K_h/2)` lines of latency, edge padding with blanking-based drain. Minimum blanking: 2·K_w cycles horizontal, K_h lines vertical. [visionhdl.ImageFilter](https://www.mathworks.com/help/visionhdl/ref/visionhdl.imagefilter-system-object.html)
- **Xilinx Vitis Vision `Filter2D` / `Window2D`** — line buffer depth K_v−1, window buffer, centered SOP. [2D Convolution Tutorial](https://xilinx.github.io/Vitis-Tutorials/2021-1/build/html/docs/Hardware_Acceleration/Design_Tutorials/01-convolution-tutorial/lab2_conv_filter_kernel_design.html)
