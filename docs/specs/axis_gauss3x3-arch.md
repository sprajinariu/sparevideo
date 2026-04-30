# `axis_gauss3x3` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.1 Kernel](#41-kernel)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Data flow overview](#51-data-flow-overview)
  - [5.2 Convolution (combinational adder tree)](#52-convolution-combinational-adder-tree)
  - [5.3 Output register](#53-output-register)
  - [5.4 Resource cost summary](#54-resource-cost-summary)
- [6. Control Logic and State Machines](#6-control-logic-and-state-machines)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_gauss3x3` applies a 3×3 Gaussian blur to an 8-bit luma (Y) stream using the kernel `[1 2 1; 2 4 2; 1 2 1] / 16`. It is a **thin wrapper over [`axis_window3x3`](axis_window3x3-arch.md)**: the window primitive owns all raster/window infrastructure (row/column counters, line buffers, column shift registers, edge-replication muxing, phantom-cycle drain, SOF handling); this module contributes only the kernel-specific logic — a combinational 9-term adder tree on the exposed window taps, followed by a single output register.

The module is a synchronous pipeline element controlled by the parent ([`axis_motion_detect`](axis_motion_detect-arch.md)) via `valid_i`, `sof_i`, and `stall_i`. It does **not** implement its own AXI4-Stream handshake, process multi-channel data, or support parameterized kernel sizes. All kernel multiplications are bit-shifts (wiring only); no DSP multipliers are used.

For the role of this pre-filter in the motion-detection pipeline (why spatial smoothing, why pre-threshold, why Y-only), see [`axis_motion_detect-arch.md`](axis_motion_detect-arch.md) §4.

---

## 2. Module Hierarchy

```
axis_gauss3x3      (u_gauss, in axis_motion_detect, generate-gated by GAUSS_EN)
└── axis_window3x3  (u_window, DATA_WIDTH=8, EDGE_POLICY=REPLICATE)
```

All scan state, line buffers, phantom drain, and edge handling live in `axis_window3x3`. This module contains only the kernel adder tree and the output register.

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line — forwarded to `axis_window3x3` (line buffer depth, counter range) |
| `V_ACTIVE` | 240 | Active lines per frame — forwarded to `axis_window3x3` (row counter range) |

### 3.2 Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| **Clock and reset** | | | |
| `clk_i` | input | 1 | DSP clock (`clk_dsp`), rising edge |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| **Control** | | | |
| `valid_i` | input | 1 | Pixel valid — 1-cycle delayed acceptance from `axis_motion_detect` (aligned with `y_cur` from `rgb2ycrcb`) |
| `sof_i` | input | 1 | Start-of-frame — resets the window primitive's row/col counters |
| `stall_i` | input | 1 | Pipeline stall — forwarded to `axis_window3x3` and the output register |
| `busy_o` | output | 1 | Forwarded from `axis_window3x3.busy_o` — asserted when a phantom cycle must fire while upstream presents `valid_i=1`. Stays low under standard VGA-timed integration |
| **Data** | | | |
| `y_i` | input | 8 | Raw luma from `rgb2ycrcb` |
| `y_o` | output | 8 | Smoothed luma (registered) |
| `valid_o` | output | 1 | Output valid — follows `valid_i` with `H_ACTIVE + 3` cycle latency during initial fill; 1 pixel/cycle steady-state throughput thereafter |

No `tready` output — the module never back-pressures; stall control is external.

---

## 4. Concept Description

A 2D convolution slides a small weight matrix (the "kernel") over every pixel. For each output pixel, the kernel weights are multiplied by the corresponding 3×3 neighborhood and summed. The Gaussian kernel approximates a 2D Gaussian bell curve (sigma ≈ 0.85):

```
Kernel (integer):        Normalized (/ 16):

  [1  2  1]               [1/16  2/16  1/16]
  [2  4  2]               [2/16  4/16  2/16]
  [1  2  1]               [1/16  2/16  1/16]
```

The 3×3 neighborhood itself — sourcing the nine taps from a raster-scan stream, handling edges, and draining the bottom and right borders via phantom cycles — is the job of [`axis_window3x3`](axis_window3x3-arch.md). This spec only describes what is done with the nine taps once they arrive.

### 4.1 Kernel

For a window centered on pixel (r, c), the output is:

```
Y_out[r,c] = (1·Y[r-1,c-1] + 2·Y[r-1,c] + 1·Y[r-1,c+1]
            + 2·Y[r  ,c-1] + 4·Y[r  ,c] + 2·Y[r  ,c+1]
            + 1·Y[r+1,c-1] + 2·Y[r+1,c] + 1·Y[r+1,c+1]) >> 4
```

All weights are powers of 2: `×1` is identity (wiring), `×2` is `<<1` (wiring), `×4` is `<<2` (wiring). The final `>> 4` is a bit-select `sum[11:4]`. The convolution reduces to 9 additions with no multiplier hardware.

Centered convention: the output for the n-th pixel in scan order is the smoothed value at the same spatial position as the n-th input pixel — no diagonal shift. See [`axis_window3x3-arch.md`](axis_window3x3-arch.md) §4.1 for the full centering rationale and MathWorks/Xilinx references. Edge pixels use the `EDGE_REPLICATE` policy (nearest in-frame pixel); details in [`axis_window3x3-arch.md`](axis_window3x3-arch.md) §4.2.

---

## 5. Internal Architecture

### 5.1 Data flow overview

```
    y_i  ────────▶ ┌──────────────────────┐
    valid_i        │                      │
    sof_i    ────▶ │   axis_window3x3     │
    stall_i        │   (DATA_WIDTH=8,     │
                   │    EDGE_REPLICATE)   │
                   │                      │
                   └────┬─────────────┬───┘
                        │             │
                 window_o[9]    window_valid_o
                        │             │
                        ▼             │
             ┌───────────────────┐    │
             │ Adder tree        │    │    (combinational, §5.2)
             │ (9 terms, shifts) │    │
             └────────┬──────────┘    │
                      │               │
                 conv_sum[11:4]       │  (>> 4 = bit-select)
                      │               │
                      ▼               ▼
              ┌─────────────────────────┐
              │  Output register        │    (§5.3, gated by !stall_i)
              └────────┬────────────────┘
                       │
                       ▼
                    y_o, valid_o
```

The window primitive emits a 9-tap flat array `window_o[9]` (row-major: `[TL TC TR | ML CC MR | BL BC BR]`) and `window_valid_o`, both at the `d1` stage. The wrapper applies the kernel combinationally, then registers the `>>4` result into `y_o` and latches `window_valid_o` into `valid_o`. Under stall, both the window primitive and the output register are frozen.

### 5.2 Convolution (combinational adder tree)

```
conv_sum[11:0] = {4'b0, window_o[0]}       + {3'b0, window_o[1], 1'b0} + {4'b0, window_o[2]}
               + {3'b0, window_o[3], 1'b0} + {2'b0, window_o[4], 2'b0} + {3'b0, window_o[5], 1'b0}
               + {4'b0, window_o[6]}       + {3'b0, window_o[7], 1'b0} + {4'b0, window_o[8]};
```

Maximum shifted term: `255 << 2 = 1020` (11 bits). Sum of 9 terms: at most `255 × 16 = 4080` (12 bits). Output is `conv_sum[11:4]` — the `>> 4` is pure wiring.

### 5.3 Output register

`y_o` and `valid_o` are registered on each non-stall cycle (real or phantom advance, as decided by the window primitive), giving the wrapper a 1-cycle latency on top of the window's `H_ACTIVE + 2`. The first `valid_o=1` beat appears `H_ACTIVE + 3` cycles after the first input pixel.

### 5.4 Resource cost summary

This wrapper adds only the kernel adder tree and a single 9-bit output register. All other resources (line buffers, column shift registers, edge muxes, counters) are inside `axis_window3x3` — see [`axis_window3x3-arch.md`](axis_window3x3-arch.md) §5.8.

| Resource | Count |
|----------|-------|
| Adder tree | 8 adders (combinational), producing a 12-bit sum |
| Output register | 8 (`y_o`) + 1 (`valid_o`) = 9 bits |
| Multipliers | 0 (all kernel weights are wire shifts) |

---

## 6. Control Logic and State Machines

No FSM. The wrapper is stateless apart from the output register; all scan state lives in `axis_window3x3`. Control signals (`valid_i`, `sof_i`, `stall_i`) are forwarded to the window primitive verbatim; `busy_o` is forwarded back verbatim.

| Signal | Condition | Effect |
|--------|-----------|--------|
| `stall_i` | asserted | Output register frozen; window primitive also freezes (both see the same `stall_i`) |
| `!stall_i` | — | Output register advances one cycle; window primitive advances real or phantom |
| Everything else | — | Owned by `axis_window3x3` — see [`axis_window3x3-arch.md`](axis_window3x3-arch.md) §6 |

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| `y_i` → `window_o` (via `axis_window3x3`) | H_ACTIVE + 2 clock cycles |
| Adder tree + `>> 4` (combinational) | 0 clock cycles |
| `conv_sum` → `y_o` (output register) | 1 clock cycle |
| **Total: `y_i` → `y_o` (first output)** | **H_ACTIVE + 3 clock cycles** |
| Steady-state throughput | 1 pixel / cycle (when `!stall_i`) |

Blanking requirements come from `axis_window3x3` — see [`axis_window3x3-arch.md`](axis_window3x3-arch.md) §5.3 and §7:

- H-blank: ≥ 1 cycle per row (absorbs the per-row phantom column).
- V-blank: ≥ `H_ACTIVE + 1` cycles (absorbs the bottom-row phantom-row drain).


---

## 8. Shared Types

None from `sparevideo_pkg`. Frame geometry parameters (`H_ACTIVE`, `V_ACTIVE`) match the package values when instantiated from `axis_motion_detect`.

---

## 9. Known Limitations

- **H_ACTIVE + 3 initial latency**: first output pixel appears H_ACTIVE + 3 cycles after the first input. At 100 MHz this is 3.2 µs at 320px — invisible in a 60 fps pipeline. Steady-state throughput is 1 pixel/cycle.
- **3×3 only**: no parameterized kernel size. A 5×5 variant would require a different window primitive and a 25-term adder tree — a separate module.
- **Truncation, not rounding**: the `>> 4` is a bit-select and truncates toward zero. Maximum error vs. ideal Gaussian is −1 LSB.
- **No runtime bypass**: when `GAUSS_EN=0` in `axis_motion_detect`, the entire module is not instantiated (generate block). There is no runtime bypass inside `axis_gauss3x3` itself.
- **Window primitive caveats also apply**: stale line-buffer data for the first two rows after reset, SOF not flushing line buffers, distributed-RAM inference at 320 px. See [`axis_window3x3-arch.md`](axis_window3x3-arch.md) §9.

---

## 10. References

- [`axis_window3x3-arch.md`](axis_window3x3-arch.md) — the shared 3×3 window primitive; definitive reference for line buffers, phantom-cycle drain, edge replication, and blanking requirements.
- [`axis_motion_detect-arch.md`](axis_motion_detect-arch.md) — parent module; describes why the Gaussian is internal (rather than an external AXIS stage) and why spatial filtering must be pre-threshold (§4.6, §4.7).
- **MathWorks Vision HDL Toolbox** — `floor(K_h/2)` lines of latency, edge padding with blanking-based drain. [visionhdl.ImageFilter](https://www.mathworks.com/help/visionhdl/ref/visionhdl.imagefilter-system-object.html), [Edge Padding](https://www.mathworks.com/help/visionhdl/ug/edge-padding.html), [Configure Blanking Intervals](https://www.mathworks.com/help/visionhdl/ug/configure-blanking-intervals.html)
- **Xilinx Vitis Vision `Filter2D` / `Window2D`** — line buffer depth K_v−1, window buffer, centered SOP. [2D Convolution Tutorial](https://xilinx.github.io/Vitis-Tutorials/2021-1/build/html/docs/Hardware_Acceleration/Design_Tutorials/01-convolution-tutorial/lab2_conv_filter_kernel_design.html)
