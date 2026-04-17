# `axis_gauss3x3` Architecture

## 1. Purpose and Scope

`axis_gauss3x3` applies a 3x3 Gaussian blur to an 8-bit luma (Y) stream using the kernel `[1 2 1; 2 4 2; 1 2 1] / 16`. It is a synchronous pipeline element controlled by the parent module (`axis_motion_detect`) via `valid_i`, `sof_i`, and `stall_i` signals. It does **not** implement its own AXI4-Stream handshake, process multi-channel data, or support parameterized kernel sizes. All kernel multiplications are bit-shifts (wiring only); no DSP multipliers are used.

---

## 2. Module Hierarchy

`axis_gauss3x3` is a leaf module — no submodules. It is instantiated inside `axis_motion_detect` as `u_gauss` (gated by `GAUSS_EN`).

```
axis_motion_detect (u_motion)
├── axis_fork_pipe (u_fork)
├── rgb2ycrcb      (u_rgb2y)
├── axis_gauss3x3  (u_gauss)   ← this module (generate-gated by GAUSS_EN)
└── motion_core    (u_core)
```

---

## 3. Interface Specification

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line (line buffer depth) |
| `V_ACTIVE` | 240 | Active lines per frame (row counter range) |

### Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| **Clock and reset** | | | |
| `clk_i` | input | 1 | DSP clock (`clk_dsp`), rising edge |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| **Control** | | | |
| `valid_i` | input | 1 | Pixel valid — 1-cycle delayed acceptance from `axis_motion_detect` (aligned with `y_cur` from `rgb2ycrcb`) |
| `sof_i` | input | 1 | Start-of-frame — resets row/col counters (1-cycle delayed, aligned with `valid_i`) |
| `stall_i` | input | 1 | Pipeline stall from `axis_fork_pipe` — freezes all internal state when asserted |
| **Data** | | | |
| `y_i` | input | 8 | Raw luma from `rgb2ycrcb` |
| `y_o` | output | 8 | Smoothed luma (registered) |
| `valid_o` | output | 1 | Output valid — follows `valid_i` with 2-cycle delay |

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

For a pixel at position (r, c):

```
Y_out = (1*Y[r-1,c-1] + 2*Y[r-1,c] + 1*Y[r-1,c+1]
       + 2*Y[r  ,c-1] + 4*Y[r  ,c] + 2*Y[r  ,c+1]
       + 1*Y[r+1,c-1] + 2*Y[r+1,c] + 1*Y[r+1,c+1]) >> 4
```

All weights are powers of 2: `*1` = identity (wiring), `*2` = `<<1` (wiring), `*4` = `<<2` (wiring). The final `>>4` is also wiring (bit-select `sum[11:4]`). The entire convolution is 9 additions with no multiplier hardware.

This pre-filtering reduces per-pixel sensor noise before the motion threshold comparison in `motion_core`, directly reducing salt-and-pepper speckle in the motion mask. A 3x3 kernel is sufficient for 320x240; a 5x5 would blur away small-object motion at this resolution.

### Centered vs. causal Gaussian

The convolution above is defined as *centered* — the kernel is applied around pixel (r, c) using rows {r-1, r, r+1} and columns {c-1, c, c+1}. In a frame buffer architecture where the entire image is available, this is trivial. In a **streaming** architecture, pixels arrive in raster order and row r+1 has not arrived when (r, c) is being processed. A truly centered Gaussian would require buffering one full row of input before the first output can be produced, adding **H_ACTIVE + 1 clock cycles** of latency.

This module instead computes a **backward-looking** (causal) Gaussian: for each input pixel at scan position (r, c), the 3x3 window is formed from rows {r-2, r-1, r} and columns {c-2, c-1, c} — all of which are already available from the line buffers and shift registers. The kernel center (weight 4) lands on position **(r-1, c-1)**, not (r, c). The output is a valid Gaussian blur of the image, but **spatially shifted by 1 pixel diagonally** (up and left) relative to the input stream.

This means `y_o[n]` (the output for the n-th pixel in scan order) is the Gaussian smoothed value centered at position (r-1, c-1), while the motion pipeline's pixel address counter associates it with position (r, c). The comparison `|y_smooth - bg[pix_addr]|` therefore compares spatially mismatched positions. For motion detection with `THRESH=16`, this 1-pixel shift is negligible — adjacent pixels in a natural image differ by far less than the threshold. The trade-off is 2-cycle latency instead of H_ACTIVE + 1.

### Edge handling

At image borders (first/last row, first/last column), the backward-looking window extends outside the image. Border pixel replication clamps window coordinates at image edges — out-of-bounds positions are replaced with the nearest valid pixel. This is a simple mux on the window inputs controlled by the row/column counters.

---

## 5. Internal Architecture

### Data flow overview

```
y_i ──► [line buffers LB0, LB1] ──► [column shift regs] ──► [edge mux] ──► [adder tree] ──► y_o
         (registered read,          (2 FFs per row,         (comb)         (comb + reg)
          1-cycle latency)           6 FFs total)
```

### 1. Row/column counters

Registered counters `col` and `row` track position within the frame. Reset on `sof_i`. Frozen during `stall_i`. A combinational `cur_col`/`cur_row` computes the actual position of the pixel being accepted in the current cycle (the registered counter reflects the previous pixel's position).

### 2. Line buffers (distributed RAM, depth = `H_ACTIVE`, width = 8)

Two line buffers store previous rows. When the input scan position is at row `r`, the three rows available form a window whose *center* is row `r-1` (not `r`):

| Buffer | Contents | Role in 3x3 window |
|--------|----------|---------------------|
| `lb0_mem` | Row r-2 (oldest) | Top neighbor of center pixel at r-1 |
| `lb1_mem` | Row r-1 (middle) | **Center row** (the pixel being filtered) |
| Live input | Row r (current) | Bottom neighbor of center pixel at r-1 |

On each valid pixel at column `c`:

```
lb0_rd = lb0_mem[cur_col]      // read oldest row
lb1_rd = lb1_mem[cur_col]      // read middle row
lb0_mem[cur_col] = lb1_mem[cur_col]  // cascade: middle → oldest
lb1_mem[cur_col] = y_i              // current → middle
```

The cascade reads `lb1_mem[cur_col]` directly from memory (not from the registered `lb1_rd` output) to avoid a column-shifted copy. All reads and writes are registered (1-cycle latency), gated by `!stall_i && valid_i`.

A parallel pipeline register captures `y_i`, `cur_col`, and `cur_row` as `y_d1`, `col_d1`, `row_d1` (with `valid_d1`) to stay aligned with the line buffer read outputs.

**Resource cost:** At 320px, each buffer is 320 x 8 = 2,560 bits. Synthesis tools typically infer these as distributed RAM (LUT-RAM) at this depth. Total: ~640 bytes.

### 3. Column shift registers (6 FFs)

After the line buffer read stage (d1), each row's output feeds a 2-deep shift register. The same spatial offset applies horizontally: when the input is at column `c`, the shift register taps hold columns `c`, `c-1`, `c-2`, making column `c-1` the center:

```
r2: lb0_rd → r2_c1 → r2_c2    (top row: c, c-1, c-2)
r1: lb1_rd → r1_c1 → r1_c2    (center row: c, c-1, c-2)
r0: y_d1   → r0_c1 → r0_c2    (bottom row: c, c-1, c-2)
```

The `_c0` taps are combinational aliases of the current-column values (`lb0_rd`, `lb1_rd`, `y_d1`). So `win[1][1]` = `r1_c1` = row r-1 at column c-1 — the center pixel of the kernel. Shift registers are gated by `!stall_i && valid_d1`.

### 4. Edge replication muxing (combinational)

The 3x3 window `win[row][col]` defaults to the shift register outputs (the interior case). Muxes override based on `col_d1` (`COL_W` bits = `$clog2(H_ACTIVE)`, 9 bits at 320px) and `row_d1` (`ROW_W` bits = `$clog2(V_ACTIVE)`, 8 bits at 240px):

| Condition | Override |
|-----------|----------|
| `row_d1 == 0` (first row) | Top and middle rows replicated from bottom row |
| `row_d1 == 1` (second row) | Top row replicated from middle row |
| `row_d1 >= 2` (interior/last rows) | No override — shift register outputs used directly |
| `col_d1 == 0` (first column) | `c-2` and `c-1` replicated from `c` |
| `col_d1 == 1` (second column) | `c-2` replicated from `c-1` |
| `col_d1 >= 2` (interior/last columns) | No override — shift register outputs used directly |

Last row / last column need no special handling: the bottom row is always the live input, and previous-column taps naturally hold valid data.

### 5. Convolution (combinational adder tree)

```
conv_sum[11:0] = {4'b0, win[0][0]}       + {3'b0, win[0][1], 1'b0} + {4'b0, win[0][2]}
               + {3'b0, win[1][0], 1'b0} + {2'b0, win[1][1], 2'b0} + {3'b0, win[1][2], 1'b0}
               + {4'b0, win[2][0]}       + {3'b0, win[2][1], 1'b0} + {4'b0, win[2][2]};
```

Each input is 8 bits. Maximum shifted value is 10 bits (`<<2`). Sum of 9 terms fits in 12 bits. Output: `conv_sum[11:4]` (bit-select = `>>4`).

### 6. Output register

`y_o` and `valid_d2` are registered on the next non-stall cycle, giving the module its total 2-cycle latency.

### Spatial offset

As explained in §4, this is a **causal (backward-looking) Gaussian**, not a centered one. When the input scan position is at (r, c), the 3x3 window uses rows {r-2, r-1, r} and columns {c-2, c-1, c}. The kernel center (weight 4) is at `win[1][1]` = (r-1, c-1). The output produced 2 cycles after pixel (r, c) is input is the Gaussian smoothed value for position (r-1, c-1).

This 1-pixel diagonal shift is inherent to the causal architecture and applies to all pixels, not just borders. Edge replication at rows 0–1 and cols 0–1 handles the additional boundary case where the backward-looking window extends outside the image.

### Resource cost summary

| Resource | Count |
|----------|-------|
| Line buffer memory | 2 x 320 x 8 = 5,120 bits (~640 bytes) |
| Column shift register FFs | 6 x 8 = 48 bits |
| Pipeline registers (d1) | 8 (y) + 9 (col) + 8 (row) + 1 (valid) = 26 bits |
| Output register | 8 (y_o) + 1 (valid_d2) = 9 bits |
| Adder tree | 8 adders (combinational) |
| Multipliers | 0 (all shifts are wiring) |

---

## 6. Control Logic and State Machines

No FSM. All control is combinational gating based on `valid_i`, `stall_i`, and `sof_i`. The row/column counters are the only registered control state, advanced on `!stall_i && valid_i` and reset on `sof_i`.

| Signal | Condition | Effect |
|--------|-----------|--------|
| `sof_i` | `valid_i && !stall_i` | Row/col counters reset to 0 |
| `stall_i` | asserted | All registers frozen (line buffers, shift regs, output) |
| `valid_i` | `!stall_i` | Pipeline advances: line buffer read/write, shift register shift, output register update |

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| `y_i` → line buffer read (`lb0_rd`, `lb1_rd`, `y_d1`) | 1 clock cycle |
| Shift register + edge mux + adder tree (combinational) | 0 clock cycles |
| Adder tree output → `y_o` (output register) | 1 clock cycle |
| **Total: `y_i` → `y_o`** | **2 clock cycles** |
| `valid_i` → `valid_o` | 2 clock cycles |
| Throughput | 1 pixel / cycle (when `!stall_i`) |

First pixel of each frame produces valid output immediately (edge-replicated borders), so there is no multi-row fill delay.

---

## 8. Shared Types

None from `sparevideo_pkg`. Frame geometry parameters (`H_ACTIVE`, `V_ACTIVE`) match the package values when instantiated from `axis_motion_detect`.

---

## 9. Known Limitations

- **Causal (backward-looking), not centered**: the output for input pixel at (r, c) is the Gaussian centered at (r-1, c-1) — a 1-pixel diagonal spatial shift. A centered Gaussian would require H_ACTIVE + 1 cycles of latency (buffering a full row before producing output). The 1-pixel shift is negligible for motion detection with `THRESH=16`, but means the RTL does not produce bit-identical output to a standard centered Gaussian (e.g., `scipy.ndimage.gaussian_filter` or `np.pad(mode='edge')` + centered convolution). The Python reference model must replicate the causal window, not the centered one.
- **3x3 only**: no parameterized kernel size. A 5x5 would require 4 line buffers and a 25-element adder tree — a separate module if needed.
- **Distributed RAM at 320px**: the line buffers infer as distributed RAM (LUT-RAM) at 320 depth. At higher resolutions (e.g., 1920px), BRAM inference would be preferable. No synthesis pragmas are applied.
- **No bypass mode**: when `GAUSS_EN=0` in `axis_motion_detect`, the entire module is not instantiated (generate block). There is no runtime bypass.
- **Truncation, not rounding**: the `>>4` division truncates toward zero. Maximum error vs. ideal Gaussian is -1 LSB.
- **Stale line buffer data on first frame**: after reset, `lb0_mem` and `lb1_mem` contain arbitrary data. Edge replication for rows 0-1 hides this; by row 2 the cascade has propagated correct data from the current frame.
- **SOF does not clear line buffers**: `sof_i` resets the row/col counters but does not zero the line buffer contents. The first two rows of a new frame re-fill the buffers naturally via the cascade, and edge replication masks any stale data.

---

## 10. References

- [sistenix.com — 2D Convolution Tutorial](https://sistenix.com/sobel.html) — SystemVerilog sliding window with line buffers
- [damdoy/fpga_image_processing](https://github.com/damdoy/fpga_image_processing) — Gaussian blur for ice40, Verilator-tested
- [Gowtham1729/Image-Processing](https://github.com/Gowtham1729/Image-Processing) — 3x3 convolution kernels (Apache 2.0)
