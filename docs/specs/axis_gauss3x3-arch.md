# `axis_gauss3x3` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.1 Centered streaming Gaussian](#41-centered-streaming-gaussian)
  - [4.2 Edge replication](#42-edge-replication)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Data flow overview](#51-data-flow-overview)
  - [5.2 Row/column counters](#52-rowcolumn-counters)
  - [5.3 Phantom-cycle drain and blanking](#53-phantom-cycle-drain-and-blanking)
  - [5.4 Line buffers](#54-line-buffers-distributed-ram-depth--h_active-width--8)
  - [5.5 Column shift registers](#55-column-shift-registers-6-ffs)
  - [5.6 Edge replication muxing](#56-edge-replication-muxing-combinational)
  - [5.7 Convolution](#57-convolution-combinational-adder-tree)
  - [5.8 Output register](#58-output-register)
  - [5.9 SOF handling](#59-sof-handling)
  - [5.10 Resource cost summary](#510-resource-cost-summary)
- [6. Control Logic and State Machines](#6-control-logic-and-state-machines)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_gauss3x3` applies a 3x3 Gaussian blur to an 8-bit luma (Y) stream using the kernel `[1 2 1; 2 4 2; 1 2 1] / 16`. It is a synchronous pipeline element controlled by the parent module ([`axis_motion_detect`](axis_motion_detect-arch.md)) via `valid_i`, `sof_i`, and `stall_i` signals. It does **not** implement its own AXI4-Stream handshake, process multi-channel data, or support parameterized kernel sizes. All kernel multiplications are bit-shifts (wiring only); no DSP multipliers are used.

For the role of this pre-filter in the motion-detection pipeline (why spatial smoothing, why pre-threshold, why Y-only), see [`axis_motion_detect-arch.md`](axis_motion_detect-arch.md) §4.

---

## 2. Module Hierarchy

`axis_gauss3x3` is a leaf module — no submodules. It is instantiated inside `axis_motion_detect` as `u_gauss` (gated by `GAUSS_EN`).

```
axis_motion_detect (u_motion)
├── rgb2ycrcb      (u_rgb2y)
├── axis_gauss3x3  (u_gauss)   ← this module (generate-gated by GAUSS_EN)
└── motion_core    (u_core)
```

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line (line buffer depth) |
| `V_ACTIVE` | 240 | Active lines per frame (row counter range) |

### 3.2 Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| **Clock and reset** | | | |
| `clk_i` | input | 1 | DSP clock (`clk_dsp`), rising edge |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| **Control** | | | |
| `valid_i` | input | 1 | Pixel valid — 1-cycle delayed acceptance from `axis_motion_detect` (aligned with `y_cur` from `rgb2ycrcb`) |
| `sof_i` | input | 1 | Start-of-frame — resets row/col counters (1-cycle delayed, aligned with `valid_i`) |
| `stall_i` | input | 1 | Pipeline stall from `axis_motion_detect` — freezes all internal state when asserted |
| `busy_o` | output | 1 | Module is executing a phantom cycle and cannot accept a real pixel this cycle. Asserted for 1 cycle per row when no H-blank is available; asserted for up to `H_ACTIVE + 1` cycles after the last row when no V-blank is available. Stays low in standard VGA-timed integration where blanking is always present. |
| **Data** | | | |
| `y_i` | input | 8 | Raw luma from `rgb2ycrcb` |
| `y_o` | output | 8 | Smoothed luma (registered) |
| `valid_o` | output | 1 | Output valid — follows `valid_i` with `H_ACTIVE + 3` cycle latency during initial fill; 1 pixel/cycle steady-state throughput thereafter |

No `tready` output — the module never back-pressures; stall control is external.

---

## 4. Concept Description

A 2D convolution slides a small weight matrix (the "kernel") over every pixel in the image. For each pixel, it multiplies the pixel and its neighbors by the corresponding kernel weights, sums the products, and produces a weighted average. The Gaussian kernel approximates a 2D Gaussian bell curve (sigma ~ 0.85):

```
Kernel (integer):        Normalized (/ 16):

  [1  2  1]               [1/16  2/16  1/16]
  [2  4  2]               [2/16  4/16  2/16]
  [1  2  1]               [1/16  2/16  1/16]
```

For a pixel at position (r, c), the centered convolution is:

```
Y_out[r,c] = (1*Y[r-1,c-1] + 2*Y[r-1,c] + 1*Y[r-1,c+1]
            + 2*Y[r  ,c-1] + 4*Y[r  ,c] + 2*Y[r  ,c+1]
            + 1*Y[r+1,c-1] + 2*Y[r+1,c] + 1*Y[r+1,c+1]) >> 4
```

All weights are powers of 2: `*1` = identity (wiring), `*2` = `<<1` (wiring), `*4` = `<<2` (wiring). The final `>>4` is also wiring (bit-select `sum[11:4]`). The entire convolution is 9 additions with no multiplier hardware.

### 4.1 Centered streaming Gaussian

This module implements **true centered convolution**. The output `y_o` for the n-th pixel in scan order is the Gaussian smoothed value at the same spatial position as the n-th input pixel — no diagonal shift. This is the standard convention adopted by MathWorks Vision HDL Toolbox (`floor(K_h/2)` lines of latency) and Xilinx Vitis Vision `Filter2D`/`Window2D`.

The cost of centering is latency: pixel (r, c) cannot be output until row r+1 column c+1 has been received (the bottom-right corner of its 3x3 window). For H_ACTIVE pixels per row, this adds one full row + one column = H_ACTIVE + 1 valid input cycles before the first centered output, plus 2 pipeline stages. Total initial latency = **H_ACTIVE + 3 clock cycles**.

This latency is absorbed in the existing pipeline via `idx_pipe` in `axis_motion_detect`, which delays the pixel address by the same H_ACTIVE + 3 cycles so `y_smooth` and `bg[P]` meet at the comparator for the same pixel P.

### 4.2 Edge replication

At image borders, the 3x3 window extends outside the image. Border pixel replication clamps out-of-bounds coordinates to the nearest valid pixel. The table below lists the actual RTL mux conditions (by scan position `row_d1`/`col_d1`), the output pixel they emit, and how replication is achieved. Scan positions `row_d1 == 0` and `col_d1 == 0` never emit output (suppressed at the `valid_o` stage) and therefore need no mux.

| Scan position         | Output pixel | Mechanism                                                     |
|-----------------------|--------------|---------------------------------------------------------------|
| `row_d1 == 1`         | row 0        | Explicit mux: middle row → top row                            |
| `row_d1 == V_ACTIVE`  | row V-1      | Explicit mux: middle row → bottom row (phantom row)           |
| `col_d1 == 1`         | col 0        | Explicit mux: middle column → left column                     |
| `col_d1 == H_ACTIVE`  | col H-1      | Implicit: `lb_active_col` holds LB reads and `y_d1`, so `r*_c0` aliases `r*_c1` |
| Other positions       | interior     | No override (default window)                                  |

---

## 5. Internal Architecture

### 5.1 Data flow overview

**Why both line buffers and column shift registers?** The input arrives in raster-scan order: one pixel per cycle, left-to-right within a row, top-to-bottom within a frame. At the cycle the window is centered on pixel (r, c), the adder tree needs all 9 pixels of the 3x3 window **simultaneously**. The storage problem splits naturally along the two spatial axes:

- **Line buffers (row history).** Two small RAMs (`lb_top`, `lb_mid`) each store one full row's worth of past pixels. When the scan reaches row r, `lb_top` holds row r-2 (top of the window), `lb_mid` holds row r-1 (middle), and the live input carries row r (bottom). At column c, one read from each buffer delivers the three co-columned pixels — one per row of the window.
- **Column shift registers (column history within each row).** The line buffers give only the *single* pixel at column c. The window also needs columns c-1 and c-2 for each row. A 2-deep register chain per row records the previous two cycles' values, providing the c-1 and c-2 taps. Three rows × 2 registers = 6 FFs total.

Put another way: the line buffers turn a 1-D raster stream into three parallel row streams co-aligned in time; the column shift registers then widen each of those streams from 1 tap to 3 taps, completing the 3×3 window. Neither mechanism alone is sufficient — line buffers without shift registers give only one column; shift registers without line buffers give only one row.

The datapath below flows top-to-bottom. Three parallel columns represent the three rows of the 3x3 window; each column advances through an identical FF → c1 shift → c2 shift sequence. At the bottom, the three rows converge into an edge-mux / adder-tree / output-register stage.

```
                              y_i (8-bit luma)
              ┌─────────────────────┤
              │                     ▼
              │           lb_mid_mem[cur_col] = y_i
              │              ┌─────────────┐
              │              │   lb_mid    │  Holds middle row (row r-1)
              │              │   LUT-RAM   │
              │              └──────┬──────┘
              │                     ├──────cascade────────┐
              │                     │                     │ (write: lb_top_mem[cur_col] = lb_mid_mem[cur_col])
              │                     │              ┌──────▼──────┐
              │                     │              │   lb_top    │ Holds top row (row r)
              │                     │              │   LUT-RAM   │
              │                     │              └──────┬──────┘
              ▼                     ▼                     ▼
         ┌─────────┐          ┌────────────┐        ┌────────────┐
         │ y_d1 FF │          │lb_mid_rd FF│        │lb_top_rd FF│   ← d1
         └────┬────┘          │   FF       │        │   FF       │     align
              │               └─────┬──────┘        └─────┬──────┘
         row r live            row r-1 middle         row r-2 top
              │                     │                     │
              ▼                     ▼                     ▼
         ┌─────────┐           ┌─────────┐           ┌─────────┐
         │r0_c1 FF │           │r1_c1 FF │           │r2_c1 FF │
         └────┬────┘           └────┬────┘           └────┬────┘   column
              ▼                     ▼                     ▼        shift
         ┌─────────┐           ┌─────────┐           ┌─────────┐   (6 FFs)
         │r0_c2 FF │           │r1_c2 FF │           │r2_c2 FF │
         └────┬────┘           └────┬────┘           └────┬────┘
              │                     │                     │
         {c2,c1,c0}            {c2,c1,c0}            {c2,c1,c0}
          bottom row            middle row             top row
              └──────────┬──────────┴──────────┬──────────┘
                         ▼                     ▼
                      ┌──────────────────────────┐
                      │  Edge-replication MUXes  │         (see §4.2, §5.6)
                      └────────────┬─────────────┘
                                   ▼
                        3x3 window  win[row][col]
                                   │
                                   ▼
                      ┌──────────────────────────┐
                      │  Adder tree (9 terms)    │         (see §5.7)
                      └────────────┬─────────────┘
                                   ▼
                              conv_sum[11:4]   (>> 4)
                                   │
                                   ▼
                            ┌──────────────┐
                            │   y_o FF     │               ← d2 output
                            └──────┬───────┘
                                   ▼
                             y_o,  valid_o
```

Notes on the diagram:
- **Line buffers** (`lb_top`, `lb_mid`) — details in §5.4.
- **d1 align stage** registers the LB reads and a matching `y_d1` delay so all three rows of the window are co-temporal before entering the column shift chain.
- **Column shift** turns each row's single live tap into three taps `{c2, c1, c0}` — details in §5.5.
- **Edge muxes** — details in §4.2 and §5.6.
- **Adder tree** — details in §5.7.
- **d2 output register** closes the pipeline with `>> 4` (= divide by 16).

### 5.2 Row/column counters

Registered counters `col` and `row` track position within the active region, extended to `[0 .. H_ACTIVE]` × `[0 .. V_ACTIVE]` so phantom positions can be represented. On `sof_i` the counters reset to 0. On `!stall_i && valid_i` they advance. On a phantom cycle they advance without consuming a real pixel.

A combinational `cur_col`/`cur_row` computes the actual position of the pixel (real or phantom) being processed in the current cycle.

### 5.3 Phantom-cycle drain and blanking

After all real pixels of a row are consumed, the 3x3 window centered at the **last real column** (c = H_ACTIVE − 1) still needs column c+1 = H_ACTIVE, which does not exist. The module self-clocks one **phantom cycle** at col = H_ACTIVE, using the edge-replicated right-border value. This phantom cycle produces the centered output for the rightmost pixel of that row.

Similarly, after the last real row, the window centered at any pixel in the bottom row needs row V_ACTIVE (which does not exist). The module self-clocks H_ACTIVE + 1 phantom cycles at row = V_ACTIVE, using the edge-replicated bottom-border values, to drain the remaining centered outputs.

Phantom cycles execute **during upstream blanking** (when `valid_i = 0`):

- **Per row**: 1 phantom cycle per row → absorbed in H-blank. Minimum blanking: 1 cycle per row (2 · K_w = 6 cycles per MathWorks spec is conservative but safe).
- **Per frame**: H_ACTIVE + 1 phantom cycles after the last row → absorbed in V-blank. Minimum: H_ACTIVE + 1 cycles of V-blank.
- **No blanking available**: `busy_o` is asserted for the phantom cycle. The parent module (`axis_motion_detect`) uses this to deassert `s_axis_tready_o` for one cycle, creating the required blanking window. In standard VGA-timed integration (`H_BLANK = 16`, `V_BLANK = 6 lines`), blanking is always available and `busy_o` stays low.

#### When does `busy_o` assert?

The module has no awareness of upstream timing. It reacts locally to `valid_i` at phantom scan positions:

```
busy_o = valid_i && at_phantom
```

where `at_phantom` is true when the scan counter is at `row_d1 == V_ACTIVE` or `col_d1 == H_ACTIVE` — the extra row/column appended past the active region so the centered output for the last real row / last real column can be emitted.

Two cases arise:

- **Blanking available (standard VGA).** When the scan reaches a phantom slot, upstream is in H_BLANK or V_BLANK, so `valid_i = 0`. `busy_o` stays low; the phantom cycle self-clocks via `phantom = !valid_i && at_phantom`. The upstream source can keep `tready` high — it simply has no beat to deliver this cycle.
- **Blanking unavailable (back-to-back frames).** Upstream presents `valid_i = 1` at the exact cycle the phantom drain must fire. `busy_o` goes high, the parent deasserts `s_axis_tready_o`, the upstream beat is held, and the module fires its phantom drain this cycle. On the next cycle `at_phantom` clears and the held real pixel is accepted.

### 5.4 Line buffers (distributed RAM, depth = `H_ACTIVE`, width = 8)

Two line buffers store previous rows. When the scan position is at row r:

| Buffer | Contents | Role in 3x3 window |
|--------|----------|---------------------|
| `lb_top_mem` | Row r-2 (top of window)    | Top row of window centered at (r-1, c) |
| `lb_mid_mem` | Row r-1 (middle of window) | Middle row of window centered at (r-1, c) |
| Live input | Row r (current) | Bottom row of window centered at (r-1, c) |

On each real pixel at column c:

```
lb_top_rd = lb_top_mem[cur_col]
lb_mid_rd = lb_mid_mem[cur_col]
lb_top_mem[cur_col] = lb_mid_mem[cur_col]   // cascade: middle → oldest
lb_mid_mem[cur_col] = y_i                // current → middle
```

During phantom cycles, line buffer writes are gated off (no real pixel to store). The cascade reads `lb_mid_mem[cur_col]` directly from memory (not from the registered `lb_mid_rd` output) to avoid a column-shifted copy.

**Resource cost:** At 320px, each buffer is 320 × 8 = 2,560 bits. Synthesis infers distributed RAM (LUT-RAM). Total: ~640 bytes.

### 5.5 Column shift registers (6 FFs)

After the line buffer read stage (d1), each row's output feeds a 2-deep shift register providing `c`, `c-1`, `c-2` taps:

```
r2: lb_top_rd → r2_c1 → r2_c2    (top row: c, c-1, c-2)
r1: lb_mid_rd → r1_c1 → r1_c2    (center row: c, c-1, c-2)
r0: y_d1   → r0_c1 → r0_c2    (bottom row: c, c-1, c-2)
```

The `_c0` taps are combinational aliases. Shift registers are gated by `!stall_i && valid_d1`. During phantom right-edge cycles the shift register is not advanced by new input; the replicated right-border value is injected via the edge mux.

### 5.6 Edge replication muxing (combinational)

The 3x3 window `win[row][col]` defaults to shift register outputs. Muxes override based on `col_d1` and `row_d1` according to the table in §4.2. The mux operates on the d1-stage signals and is purely combinational.

### 5.7 Convolution (combinational adder tree)

```
conv_sum[11:0] = {4'b0, win[0][0]}       + {3'b0, win[0][1], 1'b0} + {4'b0, win[0][2]}
               + {3'b0, win[1][0], 1'b0} + {2'b0, win[1][1], 2'b0} + {3'b0, win[1][2], 1'b0}
               + {4'b0, win[2][0]}       + {3'b0, win[2][1], 1'b0} + {4'b0, win[2][2]};
```

Maximum shifted value: 10 bits. Sum of 9 terms: 12 bits. Output: `conv_sum[11:4]` (= `>> 4`).

### 5.8 Output register

`y_o` and `valid_d2` are registered on each non-stall cycle (real or phantom), giving the module its base 2-cycle internal latency. The first valid `valid_o` pulse appears H_ACTIVE + 3 cycles after the first input pixel.

### 5.9 SOF handling

On `sof_i`, internal `col`/`row` counters reset to 0. Any in-flight phantom cycles for the previous frame are cancelled (they complete within V-blank before the next SOF arrives in normal operation).

### 5.10 Resource cost summary

| Resource | Count |
|----------|-------|
| Line buffer memory | 2 × H_ACTIVE × 8 bits (~640 bytes at 320px) |
| Column shift register FFs | 6 × 8 = 48 bits |
| Pipeline registers (d1) | 8 (y) + log2(H_ACTIVE) (col) + log2(V_ACTIVE) (row) + 1 (valid) |
| Output register | 8 (y_o) + 1 (valid_d2) = 9 bits |
| Phantom counter + edge mux | ~20 FFs + combinational mux |
| Adder tree | 8 adders (combinational) |
| Multipliers | 0 (all shifts are wiring) |

---

## 6. Control Logic and State Machines

No FSM. All control is combinational gating based on `valid_i`, `stall_i`, `sof_i`, and the phantom-cycle trigger logic. Row/column counters are the only registered control state.

| Signal | Condition | Effect |
|--------|-----------|--------|
| `sof_i` | `valid_i && !stall_i` | Row/col counters reset to 0; in-flight phantom cycles cancelled |
| `stall_i` | asserted | All registers frozen (line buffers, shift regs, output) |
| `valid_i` | `!stall_i` | Real pixel consumed; pipeline advances |
| phantom trigger | `valid_i=0 && phantom_needed` | Phantom cycle fires; pipeline advances without consuming real pixel |
| `busy_o` | `phantom_needed && valid_i=1` | No blanking available; signal parent to deassert ready |

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| `y_i` → line buffer read (`lb_top_rd`, `lb_mid_rd`, `y_d1`) | 1 clock cycle |
| Shift register + edge mux + adder tree (combinational) | 0 clock cycles |
| Adder tree output → `y_o` (output register) | 1 clock cycle |
| **Total: `y_i` → `y_o` (first output, initial fill)** | **H_ACTIVE + 3 clock cycles** |
| Steady-state throughput | 1 pixel / cycle (when `!stall_i`) |
| Phantom cycles per row | 1 (absorbed in H-blank ≥ 1 cycle) |
| Phantom cycles per frame (bottom row) | H_ACTIVE + 1 (absorbed in V-blank ≥ H_ACTIVE + 1 cycles) |

Minimum blanking requirements (MathWorks Vision HDL Toolbox spec for 3×3 filter):
- H-blank: ≥ 2 × K_w = 6 cycles (conservative; 1 cycle is the true minimum)
- V-blank: ≥ K_h = 3 lines (conservative; H_ACTIVE + 1 cycles is the true minimum)

Standard VGA-timed TB provides H_BLANK = 16 cycles and V_BLANK = 6 lines — both well above minimum.

---

## 8. Shared Types

None from `sparevideo_pkg`. Frame geometry parameters (`H_ACTIVE`, `V_ACTIVE`) match the package values when instantiated from `axis_motion_detect`.

---

## 9. Known Limitations

- **H_ACTIVE + 3 initial latency**: first output pixel appears H_ACTIVE + 3 cycles after first input. At 100 MHz this is 3.2 µs at 320px — invisible in a 60 fps pipeline. Steady-state throughput is 1 pixel/cycle.
- **3x3 only**: no parameterized kernel size. A 5x5 would require 4 line buffers and a 25-element adder tree — a separate module if needed.
- **Distributed RAM at 320px**: at higher resolutions (e.g., 1920px), BRAM inference would be preferable. No synthesis pragmas are applied.
- **No bypass mode**: when `GAUSS_EN=0` in `axis_motion_detect`, the entire module is not instantiated (generate block). There is no runtime bypass.
- **Truncation, not rounding**: the `>>4` division truncates toward zero. Maximum error vs. ideal Gaussian is −1 LSB.
- **Stale line buffer data on first frame**: after reset, `lb_top_mem`/`lb_mid_mem` contain arbitrary data. Edge replication for rows 0–1 hides this; by row 2 the cascade propagates correct data.
- **SOF does not clear line buffers**: `sof_i` resets the row/col counters but does not zero the line buffer contents. The first two rows re-fill the buffers naturally via the cascade.

---

## 10. References

- **MathWorks Vision HDL Toolbox** — `floor(K_h/2)` lines of latency, edge padding with blanking-based drain. Minimum blanking: 2·K_w cycles horizontal, K_h lines vertical. [visionhdl.ImageFilter](https://www.mathworks.com/help/visionhdl/ref/visionhdl.imagefilter-system-object.html), [Edge Padding](https://www.mathworks.com/help/visionhdl/ug/edge-padding.html), [Configure Blanking Intervals](https://www.mathworks.com/help/visionhdl/ug/configure-blanking-intervals.html)
- **Xilinx Vitis Vision `Filter2D` / `Window2D`** — line buffer depth K_v−1, window buffer, centered SOP. [2D Convolution Tutorial](https://xilinx.github.io/Vitis-Tutorials/2021-1/build/html/docs/Hardware_Acceleration/Design_Tutorials/01-convolution-tutorial/lab2_conv_filter_kernel_design.html)
- **georgeyhere/FPGA-Video-Processing** — fills three line buffers before streaming; output FIFO is CDC, not alignment. [GitHub](https://github.com/georgeyhere/FPGA-Video-Processing)
- **AMD/Xilinx UG949 — Coding Shift Registers and Delay Lines** — SRL inference guidance for deep shift registers without reset. [UG949](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Coding-Shift-Registers-and-Delay-Lines)
