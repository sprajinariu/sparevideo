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
- [8. Consumer pattern](#8-consumer-pattern)
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
└── axis_window3x3  (u_window, DATA_WIDTH=8)   ← this module

axis_morph3x3_erode  (u_erode, in axis_morph3x3_open)
└── axis_window3x3  (u_window, DATA_WIDTH=1)

axis_morph3x3_dilate (u_dilate, in axis_morph3x3_open)
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

This module emits the **combinational window at the d1 stage**. Each consumer closes its own pipeline with one output register, so the end-to-end consumer latency is `H_ACTIVE + 3` for `axis_gauss3x3` (kernel `H_ACTIVE + 2` + wrapper register `+1`).

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

`col` and `row` track scan position over the extended range `[0..H_ACTIVE] × [0..V_ACTIVE]`, which includes a phantom column (`col == H_ACTIVE`) and phantom row (`row == V_ACTIVE`). They reset on `sof_i && valid_i` and advance on either a real-pixel acceptance or a phantom step (whenever the scan reaches a phantom position with no upstream stall). When `valid_i` is high but the scan is parked at a phantom position, the module asserts `busy_o` so the parent can deassert upstream `tready`; under standard VGA timing the upstream is naturally idle in blanking and `busy_o` never fires.

### 5.3 Phantom-cycle drain and blanking

The centered window for the last real column (`c = H_ACTIVE − 1`) needs column `c + 1`, which does not exist. The module self-clocks one **phantom column** cycle per row to close that window with no new pixel consumed. After the last real row, `H_ACTIVE + 1` **phantom-row** cycles drain the bottom-row outputs.

These phantom cycles execute during blanking under VGA timing. Without enough blanking, `busy_o` asserts and the parent must back-pressure the upstream until the drain completes.

| Blanking type | Minimum cycles | Absorbs |
|---------------|----------------|---------|
| H-blank | 1 / row | 1 phantom column per row |
| V-blank | `H_ACTIVE + 1` total | `H_ACTIVE + 1` phantom-row cycles |

### 5.4 Line buffers (depth = `H_ACTIVE`, width = `DATA_WIDTH`)

Two line buffers hold the previous two rows. On each real-pixel cycle the buffer is read first, then a cascading pair of writes shifts the middle row's value into the top buffer and the new pixel into the middle buffer, all at the same column index. Phantom cycles gate the writes and the read registers off, so the last real column's value persists — which gives right-edge replication for free (§5.6).

At default 320 px, each buffer is 320 × `DATA_WIDTH` bits — synthesised as distributed RAM at `DATA_WIDTH=8`.

### 5.5 Column shift registers

After the d1 register stage, each of the three row streams feeds a 2-deep shift register, giving the three column taps `c`, `c−1`, `c−2` for that row. The `c` taps are combinational aliases to the d1-stage signals; only the `c−1` and `c−2` taps are registered. Shifts advance on `!stall_i && valid_d1`. During phantom right-edge cycles no new value is shifted in.

### 5.6 Edge replication muxing

The 3×3 window defaults to the shift-register outputs. Combinational muxes override the appropriate row or column at the four borders per the table in §4.2. Right-edge replication is implicit: when the scan parks at the phantom column, the line-buffer read register and the shift chain all hold the last real column's value, so no explicit mux is needed.

### 5.7 Window output and off-frame suppression

`window_o[0..8]` is the row-major flattening of the 3×3 window (see the index map in §3.2). The output pixel coordinate is `(row_d1 − 1, col_d1 − 1)`; `window_valid_o = valid_d1 && row_d1 != 0 && col_d1 != 0` suppresses the pre-fill flush positions where the centered window has not yet completed.

### 5.8 Resource cost summary

| Resource | Count |
|----------|-------|
| Line buffer memory | 2 × H_ACTIVE × DATA_WIDTH bits (~640 B at 320 px, `DATA_WIDTH=8`) |
| Column shift register FFs | 6 × DATA_WIDTH bits |
| d1 pipeline registers | `DATA_WIDTH + COL_W + ROW_W + 1` |
| Counter FFs | `COL_W + ROW_W` |
| Multipliers | 0 |

---

## 6. Control Logic and State Machines

No FSM. Control is combinational gating on `valid_i`, `stall_i`, `sof_i` plus the derived phantom/advance signals. The row/column counters are the only registered control state.

| Condition | Effect |
|-----------|--------|
| `sof_i && valid_i && !stall_i` | Counters reset; any in-flight phantom from the previous frame is cancelled. |
| `stall_i` | All registered state freezes (line buffers, shift regs, d1 stage, counters). |
| Real-pixel advance | Line-buffer write + d1 advance + shift advance. |
| Phantom advance | d1 advances; line-buffer write gated off. |
| `busy_o` | A real pixel is offered while the scan is parked at a phantom position; parent must back-pressure upstream. |

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| `din_i` → registered line-buffer read | 1 cycle |
| Column shift → edge mux → `window_o` | 0 cycles (combinational) |
| **`din_i` → first `window_valid_o`** | **`H_ACTIVE + 2` cycles** |
| Steady-state throughput | 1 pixel / cycle (when `!stall_i`) |
| Phantom cycles per row | 1 (absorbed by ≥ 1 cycle of H-blank) |
| Phantom cycles per frame | `H_ACTIVE + 1` (absorbed by ≥ `H_ACTIVE + 1` cycles of V-blank) |

The output register lives in each consumer wrapper, so the wrapper's end-to-end latency is `H_ACTIVE + 3` cycles.

---

## 8. Consumer pattern

Module that instantiate this block should follow the same pattern as `axis_gauss3x3` and `axis_morph3x3_*`: instantiate `axis_window3x3`, apply a combinational op on `window_o[9]`, register the result with `!stall_i` as the enable.

---

## 9. Risks / Known Limitations

- **Only `EDGE_REPLICATE` is implemented.** Other `EDGE_POLICY` values trigger `$fatal` at elaboration; reserved policies (ZERO, CONSTANT, MIRROR) can be added later without breaking callers.
- **`H_ACTIVE + 2` initial latency.** Negligible in a 60 fps pipeline (3.2 µs at 320 px / 100 MHz). Consumers must account for it in downstream alignment.
- **Distributed RAM at 320 px.** Each line buffer is `H_ACTIVE × DATA_WIDTH` bits and infers as LUT-RAM at 320 px / 8 b. Larger geometries should use BRAM; no synthesis pragmas applied.
- **SOF does not flush line buffers.** Stale data from the previous frame sits in `lb_top_mem`/`lb_mid_mem` until the first two rows refill them via the cascade. Edge replication on rows 0–1 masks the stale contents (top-row replication does not consult the line buffer), so by row 2 the cascade has populated them correctly.

---

## 10. References

- [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) — Gaussian pre-filter architecture; describes the consumer wrapper pattern in detail.
- [`axis_motion_detect-arch.md`](axis_motion_detect-arch.md) — Motion-detection pipeline; shows how `axis_gauss3x3` (and transitively `axis_window3x3`) fits into the broader pipeline.
- **MathWorks Vision HDL Toolbox** — `floor(K_h/2)` lines of latency, edge padding with blanking-based drain. Minimum blanking: 2·K_w cycles horizontal, K_h lines vertical. [visionhdl.ImageFilter](https://www.mathworks.com/help/visionhdl/ref/visionhdl.imagefilter-system-object.html)
- **Xilinx Vitis Vision `Filter2D` / `Window2D`** — line buffer depth K_v−1, window buffer, centered SOP. [2D Convolution Tutorial](https://xilinx.github.io/Vitis-Tutorials/2021-1/build/html/docs/Hardware_Acceleration/Design_Tutorials/01-convolution-tutorial/lab2_conv_filter_kernel_design.html)
