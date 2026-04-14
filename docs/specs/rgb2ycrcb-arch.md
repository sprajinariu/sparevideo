# `rgb2ycrcb` Architecture

## 1. Purpose and Scope

`rgb2ycrcb` converts a single 8-bit RGB888 pixel to 8-bit YCrCb using Rec.601-inspired fixed-point coefficients. It is a single-cycle pipeline: one `always_ff` stage that registers the top byte of each 17-bit MAC sum. Coefficient choices guarantee that all intermediate values are non-negative and fit within 17 bits without saturation. It does **not** implement the full Rec.601 standard (no studio-swing offsets), process multiple pixels in parallel, or buffer frames.

---

## 2. Module Hierarchy

`rgb2ycrcb` is a leaf module — no submodules.

---

## 3. Interface Specification

### Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk_i` | input | 1 | Clock (any domain) |
| `rst_n_i` | input | 1 | Active-low synchronous reset — clears outputs to 0 |
| `r_i` | input | 8 | Red channel |
| `g_i` | input | 8 | Green channel |
| `b_i` | input | 8 | Blue channel |
| `y_o` | output | 8 | Luma (Y), registered, 1-cycle latency |
| `cb_o` | output | 8 | Chroma blue (Cb), registered, 1-cycle latency |
| `cr_o` | output | 8 | Chroma red (Cr), registered, 1-cycle latency |

No `tvalid`/`tready` — the module has no flow control; it always produces an output 1 cycle after each input.

---

## 4. Datapath Description

### Coefficient equations

```
Y  = ( 77·R + 150·G +  29·B         ) >> 8
Cb = (-43·R -  85·G + 128·B + 32768 ) >> 8
Cr = (128·R - 107·G -  21·B + 32768 ) >> 8
```

The `+32768` offset for Cb/Cr keeps intermediate sums non-negative for all valid 8-bit inputs, eliminating the need for saturation logic. The `>>8` is implemented as `sum[15:8]` (bit-select, no logic).

### Pipeline

**Cycle C (combinational)**:
- `y_sum_c  = 17'(77·R) + 17'(150·G) + 17'(29·B)` — result ∈ [0, 65280]
- `cb_sum_c = 17'(32768) − 17'(43·R) − 17'(85·G) + 17'(128·B)` — result ∈ [128, 65408]
- `cr_sum_c = 17'(32768) + 17'(128·R) − 17'(107·G) − 17'(21·B)` — result ∈ [128, 65408]

**Cycle C+1 (registered)**:
- `y_o  <= y_sum_c[15:8]`
- `cb_o <= cb_sum_c[15:8]`
- `cr_o <= cr_sum_c[15:8]`

### Verified corner cases

| RGB | Y | Cb | Cr |
|-----|---|----|----|
| `(0,0,0)` — black | 0 | 128 | 128 |
| `(255,255,255)` — white | 255 | 128 | 128 |
| `(128,128,128)` — gray | 128 | 128 | 128 |
| `(255,0,0)` — red | 76 | 85 | 255 |
| `(0,255,0)` — green | 149 | 43 | 21 |
| `(0,0,255)` — blue | 28 | 255 | 107 |

Unit testbench (`hw/ip/rgb2ycrcb/tb/tb_rgb2ycrcb.sv`) checks all 6 cases with ±1 LSB tolerance.

---

## 5. Control Logic

No control logic or FSM. Outputs are updated every cycle unconditionally (when `rst_n_i=1`).

---

## 6. Timing

| Event | Latency |
|-------|---------|
| `r_i`, `g_i`, `b_i` → `y_o`, `cb_o`, `cr_o` | 1 clock cycle |
| Throughput | 1 pixel / cycle |

---

## 7. Shared Types

None from `sparevideo_pkg`.

---

## 8. Known Limitations

- **Rec.601 approximation**: coefficients are hand-tuned 8-bit approximations, not exact Rec.601. Maximum error vs. full-precision Rec.601 is ±1 LSB on Y, ±2 LSB on Cb/Cr.
- **Full-swing only**: no studio-swing (16–235 range) support. All 256 input/output codes are used.
- **`Cb`/`Cr` currently unused**: only `y_o` is consumed by `axis_motion_detect`. The other outputs are available for future pipeline stages.
- **No vendor primitives**: multipliers map to generic logic. A synthesis tool may infer DSP blocks; no pragmas are applied.
