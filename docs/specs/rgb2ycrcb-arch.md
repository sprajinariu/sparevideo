# `rgb2ycrcb` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Ports](#31-ports)
- [4. Concept Description](#4-concept-description)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Coefficient equations](#51-coefficient-equations)
  - [5.2 Pipeline](#52-pipeline)
  - [5.3 Resource cost](#53-resource-cost)
  - [5.4 Design corner cases](#54-design-corner-cases)
- [6. Control Logic and State Machines](#6-control-logic-and-state-machines)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`rgb2ycrcb` converts a single 8-bit RGB888 pixel to 8-bit YCrCb using Rec.601-inspired fixed-point coefficients. It is a single-cycle pipeline: one `always_ff` stage that registers the top byte of each 17-bit MAC sum. Coefficient choices guarantee that all intermediate values are non-negative and fit within 17 bits without saturation. It does **not** implement the full Rec.601 standard (no studio-swing offsets), process multiple pixels in parallel, or buffer frames.

---

## 2. Module Hierarchy

`rgb2ycrcb` is a leaf module — no submodules.

---

## 3. Interface Specification

### 3.1 Ports

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

## 4. Concept Description

RGB→YCrCb separates a pixel's brightness (luma Y) from its colour (chrominance Cb, Cr). Many video algorithms — motion detection, edge detection, compression — operate primarily on brightness, so the conversion lets downstream stages ignore the colour channels.

ITU-R BT.601 defines the conversion as a weighted linear combination of R, G, B. The luma weights `0.299R + 0.587G + 0.114B` reflect human visual sensitivity (green dominant, then red, then blue). Cb and Cr are the blue- and red-difference signals, centred at 128.

This module approximates the Rec.601 coefficients as 8-bit integers (77, 150, 29 for Y) and performs the multiply-accumulate in 17-bit unsigned arithmetic. A constant `+32768 = 128 << 8` is added to Cb and Cr before the divide, keeping all intermediates non-negative — no signed arithmetic or saturation needed.

---

## 5. Internal Architecture

### 5.1 Coefficient equations

```
Y  = ( 77·R + 150·G +  29·B         ) >> 8
Cb = (-43·R -  85·G + 128·B + 32768 ) >> 8
Cr = (128·R - 107·G -  21·B + 32768 ) >> 8
```

The `+32768` offset for Cb/Cr keeps intermediate sums non-negative for all valid 8-bit inputs, eliminating the need for saturation logic. The `>>8` is implemented as `sum[15:8]` (bit-select, no logic).

### 5.2 Pipeline

The three sums in §5.1 are computed combinationally in cycle C; the top byte of each sum (`sum[15:8]`) is registered into `y_o`/`cb_o`/`cr_o` on cycle C+1. The Y sum lies in [0, 65280] and the Cb/Cr sums in [128, 65408], so the top byte never overflows.

### 5.3 Resource cost

9 constant-coefficient multiplications (3 channels × 3 outputs); synthesis typically maps them to DSP blocks or LUT-based multipliers. 24 FFs for the registered outputs. No RAM.

### 5.4 Design corner cases

| RGB | Y | Cb | Cr |
|-----|---|----|----|
| `(0,0,0)` — black | 0 | 128 | 128 |
| `(255,255,255)` — white | 255 | 128 | 128 |
| `(128,128,128)` — gray | 128 | 128 | 128 |
| `(255,0,0)` — red | 76 | 85 | 255 |
| `(0,255,0)` — green | 149 | 43 | 21 |
| `(0,0,255)` — blue | 28 | 255 | 107 |

---

## 6. Control Logic and State Machines

No control logic or FSM. Outputs are updated every cycle unconditionally (when `rst_n_i=1`).

---

## 7. Timing

| Event | Latency |
|-------|---------|
| `r_i`, `g_i`, `b_i` → `y_o`, `cb_o`, `cr_o` | 1 clock cycle |
| Throughput | 1 pixel / cycle |

---

## 8. Shared Types

None from `sparevideo_pkg`.

---

## 9. Known Limitations

- **Rec.601 approximation**: coefficients are hand-tuned 8-bit approximations, not exact Rec.601. Maximum error vs. full-precision Rec.601 is ±1 LSB on Y, ±2 LSB on Cb/Cr.
- **Full-swing only**: no studio-swing (16–235 range) support. All 256 input/output codes are used.
- **`Cb`/`Cr` currently unused**: only `y_o` is consumed by `axis_motion_detect`. The other outputs are available for future pipeline stages.
- **No vendor primitives**: multipliers map to generic logic. A synthesis tool may infer DSP blocks; no pragmas are applied.

---

## 10. References

- [ITU-R BT.601 — Studio encoding parameters of digital television](https://www.itu.int/rec/R-REC-BT.601/)
- [RGB to YCbCr color conversion — Wikipedia](https://en.wikipedia.org/wiki/YCbCr#ITU-R_BT.601_conversion)
