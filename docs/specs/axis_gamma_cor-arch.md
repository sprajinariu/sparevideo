# `axis_gamma_cor` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.1 Two domains: normalised intensity vs. 8-bit code](#41-two-domains-normalised-intensity-vs-8-bit-code)
  - [4.2 sRGB transfer function (normalised form)](#42-srgb-transfer-function-normalised-form)
  - [4.3 LUT-based approximation](#43-lut-based-approximation)
  - [4.4 Visual shape of the transfer function](#44-visual-shape-of-the-transfer-function)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Data flow overview](#51-data-flow-overview)
  - [5.2 Pipeline stages](#52-pipeline-stages)
  - [5.3 Backpressure handling](#53-backpressure-handling)
  - [5.4 Resource cost summary](#54-resource-cost-summary)
- [6. Control Logic](#6-control-logic)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_gamma_cor` applies per-channel sRGB display-curve correction to a 24-bit RGB AXI4-Stream pixel. Each 8-bit colour component is independently mapped through a piecewise-linear approximation of the IEC 61966-2-1 sRGB transfer function, converting a linear light value in [0, 255] to a gamma-encoded value suitable for direct output to an sRGB display.

For where this module sits in the surrounding system, see [`sparevideo-top-arch.md`](sparevideo-top-arch.md).

---

## 2. Module Hierarchy

`axis_gamma_cor` is a leaf module — no submodules. Instantiated in `sparevideo_top` as `u_gamma_cor` between the control-flow output mux and `u_fifo_out`.

```
sparevideo_top
├── [control-flow mux]   — passthrough / motion / mask / ccl_bbox  →  proc_axis
├── axis_gamma_cor       (u_gamma_cor)   — this module
└── axis_async_fifo      (u_fifo_out)    — CDC clk_dsp → clk_pix
```

---

## 3. Interface Specification

### 3.1 Parameters

None. The sRGB LUT is a `localparam` baked into the module body (33 × 8 bits); the curve is fixed at synthesis time and cannot be overridden per-instance.

### 3.2 Ports

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| `clk_i`    | input  | `logic`      | `clk_dsp`, rising edge |
| `rst_n_i`  | input  | `logic`      | Active-low synchronous reset |
| `enable_i` | input  | `logic`      | Block enable. `0` bypasses the module (output equals input). |
| `s_axis`   | input  | `axis_if.rx` | RGB input stream (DATA_W=24, USER_W=1; `tdata[23:16]`=R, `tdata[15:8]`=G, `tdata[7:0]`=B; `tuser`=SOF). `tready` is asserted combinationally based on downstream readiness and pipeline vacancy. |
| `m_axis`   | output | `axis_if.tx` | Gamma-corrected RGB output stream (DATA_W=24, USER_W=1). Same framing convention as `s_axis`. |

---

## 4. Concept Description

Standard display panels follow the IEC 61966-2-1 sRGB electro-optical transfer function. Linear light values rendered without gamma encoding appear too dark on these panels because the panel's native response applies an inverse curve. Gamma correction encodes linear light through the sRGB curve so that the net light emitted by the display is perceptually proportional to the signal level.

### 4.1 Two domains: normalised intensity vs. 8-bit code

The IEC standard defines the sRGB transfer function as a continuous mapping on **normalised** real-valued intensity `u ∈ [0.0, 1.0]`, where `u = 0.0` is "no light" and `u = 1.0` is peak white. The numerical constants that appear in the formula below — `12.92`, `0.0031308`, `1.055`, `0.055`, `1/2.4` — are dimensionless and live in this normalised space. They are *not* 8-bit pixel codes and have no direct meaning in 8-bit space on their own; for example, `12.92` is the *slope of `sRGB(u)` near `u = 0`*, not a number that ever appears in an 8-bit code value.

This module operates on **8-bit integer pixel codes** `p ∈ {0, 1, …, 255}`. The bridge between the two domains is the standard right-aligned full-scale convention:

```
u   =  p / 255          (8-bit code → normalised intensity)
out =  round(v · 255)   (normalised result v ∈ [0,1] → 8-bit code, clamped to 255)
```

Composing both bridges with the sRGB function gives the function this module realises in 8-bit space:

```
out(p) = round( sRGB( p / 255 ) · 255 )       for p ∈ [0, 255]
```

So whenever the constants below appear (`12.92`, `1/2.4`, …), read them as operating on the intermediate `u = p / 255`, not on `p` itself.

### 4.2 sRGB transfer function (normalised form)

For `u ∈ [0, 1]`:

```
sRGB(u) =  12.92 · u                          if u ≤ 0.0031308    (linear segment)
sRGB(u) =  1.055 · u^(1/2.4) − 0.055          otherwise            (power segment)
```

The linear segment exists to keep the slope finite at `u = 0` (a pure power curve has infinite slope there). For 8-bit integer inputs, this segment is barely reachable: the threshold `u = 0.0031308` corresponds to `p = 0.0031308 · 255 ≈ 0.80`, so the only integer pixel value on the linear segment is `p = 0` (which yields `out = 0` either way). Every input `p ∈ [1, 255]` falls on the power segment. In other words, the `12.92 · u` branch is a property of the continuous sRGB definition, not a code path that actually runs at 8-bit precision.

### 4.3 LUT-based approximation

Computing `u^(1/2.4)` per pixel in hardware is expensive. The module replaces it with a 33-entry LUT plus per-pixel linear interpolation. The LUT samples `out(p)` at every 8th input code (so 32 segments span the full `p ∈ [0, 256]` range, with one extra sentinel point at the top):

```
GAMMA_LUT[i] = round( sRGB( (i · 8) / 255 ) · 255 )    for i = 0, 1, …, 32
```

`i = 32` is the upper sentinel: it represents the pixel value `p = 256` (one past full scale), clamped to `out = 255`. It is read as `LUT[addr+1]` only when `addr = 31` (i.e. when `p ∈ [248, 255]`).

For an input pixel `p`, decompose into integer and fractional parts:

```
addr = p[7:3]        (5 bits, selects the LUT entry: 0 ≤ addr ≤ 31)
frac = p[2:0]        (3 bits, weight for interpolation: 0 ≤ frac ≤ 7)
```

The per-channel interpolation between two adjacent LUT entries is:

```
out = ( GAMMA_LUT[addr] · (8 − frac)  +  GAMMA_LUT[addr+1] · frac ) >> 3
```

This is standard 1-D linear interpolation between the two LUT samples that bracket the input pixel, expressed in integer arithmetic. Reading it step by step:

- `addr` selects the **lower** of the two surrounding LUT samples — i.e. `LUT[addr]` is the curve value at the largest sampled input `≤ p`, and `LUT[addr+1]` is the curve value at the next sampled input above. Concretely, `LUT[addr]` is the curve at code `addr · 8`, and `LUT[addr+1]` is the curve at code `addr · 8 + 8`.
- `frac` is how far `p` has progressed across that 8-code-wide segment: it ranges `0..7`, meaning "0/8, 1/8, …, 7/8 of the way from the lower sample toward the upper one". `frac = 0` lands exactly on the lower sample; `frac = 7` is 7/8 of the way to the upper sample (it never reaches the upper sample because the upper sample is itself reached when `addr` increments).
- The two entries are blended with weights that always sum to 8: `(8 − frac)` for the lower entry, `frac` for the upper. This is the integer-arithmetic form of the textbook fractional formula

  ```
  out_real = LUT[addr] · (1 − frac/8)  +  LUT[addr+1] · (frac/8)
  ```

  Multiplying both terms by 8 to clear the fraction gives the numerator we compute. The accumulator after the multiply-add lives in the range `[0, 8 · 255] = [0, 2040]`, fitting in 11 bits.
- `>> 3` is integer divide by 8, which restores the result to the original `[0, 255]` range. It truncates toward zero (no rounding bit is added), so the interpolation has at most ~0.5 LSB of bias relative to round-to-nearest. The mismatch is invisible at 8-bit display resolution and is matched by the Python reference model so RTL and model agree at `TOLERANCE = 0`.

Worked example, `p = 100`: `addr = 100 >> 3 = 12`, `frac = 100 & 7 = 4`. With `LUT[12] = 165` and `LUT[13] = 171` (the curve sampled at `p = 96` and `p = 104`):

```
out = (165 · (8 − 4)  +  171 · 4) >> 3
    = (165 · 4  +  171 · 4)       >> 3
    = (  660    +    684)         >> 3
    =  1344                       >> 3
    =  168
```

`frac = 4` puts `p = 100` exactly halfway between the two sample points, so the result is the midpoint of `LUT[12]` and `LUT[13]`: `(165 + 171) / 2 = 168`. Correct.

All three channels (R, G, B) apply the same LUT and the same formula independently.

### 4.4 Visual shape of the transfer function

```
 out
  255 ┤                                                  ╭───●  (255,254)
      │                                            ╭────╯
      │                                     ╭──────╯
      │                              ╭──────╯
  192 ┤                       ╭──────╯
      │                ╭──────╯
      │          ╭─────╯
  128 ┤     ╭────╯
      │  ╭──╯
      │ ╭╯
   64 ┤╭╯
      │╱
      ╱
    0 ●───────────┬───────────┬───────────┬───────────┬─── in
      0          64         128         192         255
```

- The slope is steep at low inputs (the power exponent `1/2.4 < 1` makes `sRGB'(u) → ∞` as `u → 0+`, so the discrete 8-bit jumps `0 → 13 → 50` at `p = 0, 1, 8` are large), then flattens above mid-tones and approaches `out = 255` at `p = 255`.
- The curve sits strictly above the identity line `out = p` across the open interval `(0, 255)` and meets it at the two endpoints. Mid-tones are lifted — e.g. `p = 128` maps to `out = 188`, not 128 — which is what compensates for the inverse curve a typical sRGB display panel applies.
- Sample input/output pairs from this formula (computed in `py/gen_gamma_lut.py`):

  | `p`      |  0 |  1 |  8 | 32 | 64 | 128 | 192 | 255 |
  |----------|---:|---:|---:|---:|---:|----:|----:|----:|
  | `out(p)` |  0 | 13 | 50 | 99 |137 | 188 | 225 | 254 |

---

## 5. Internal Architecture

### 5.1 Data flow overview

```
                  ┌──────────────────────────────────────────────────────────┐
                  │                     axis_gamma_cor                       │
                  │                                                          │
                  │  ┌────────────────┐   cycle 0   ┌──────────────────────┐ │
   s_axis  ──────►│  │ addr/frac      │ ──────────► │  3× LUT-interp       │ │──►  m_axis
                  │  │ extractor      │             │  datapath            │ │
                  │  │ (combinational)│             │  (registered output) │ │
                  │  └────────────────┘             └──────────────────────┘ │
                  │                                                          │
                  └──────────────────────────────────────────────────────────┘
```

### 5.2 Pipeline stages

The datapath is a 1-stage pipeline:

**Cycle 0 — extraction and registration.** On each accepted beat (`s_axis.tvalid && s_axis.tready`), the following are registered:

- Per channel: `addr_r = p_r[7:3]`, `frac_r = p_r[2:0]` (and likewise `_g`, `_b` for the G and B channels).
- AXI4-Stream sideband: `tlast_q <= s_axis.tlast`, `tuser_q <= s_axis.tuser`.
- Pipeline valid flag: `pipe_valid_q` is set.

**Cycle 1 — interpolation and output registration.** The three interpolations are evaluated combinationally from the cycle-0 registers:

```
interp_r = ( GAMMA_LUT[addr_r] * (8 - frac_r)  +  GAMMA_LUT[addr_r+1] * frac_r ) >> 3
interp_g = ( GAMMA_LUT[addr_g] * (8 - frac_g)  +  GAMMA_LUT[addr_g+1] * frac_g ) >> 3
interp_b = ( GAMMA_LUT[addr_b] * (8 - frac_b)  +  GAMMA_LUT[addr_b+1] * frac_b ) >> 3
```

These combinational results are registered onto `m_axis.tdata = {interp_r, interp_g, interp_b}` on the cycle-1 clock edge. `m_axis.tlast` and `m_axis.tuser` propagate from the cycle-0 sideband registers with no additional delay.

The LUT is a `localparam logic [7:0] GAMMA_LUT [0:32]` with 33 entries. Three asynchronous reads are performed per cycle (one per channel). At 33 × 8 = 264 bits the LUT is small enough to map to LUTRAM (distributed logic) rather than block RAM.

### 5.3 Backpressure handling

`axis_gamma_cor` uses the standard single-entry skid pattern:

```
s_axis.tready = m_axis.tready || !pipe_valid_q
```

The cycle-0 registers advance only when `s_axis.tvalid && s_axis.tready` is true. The cycle-1 output register advances only when `m_axis.tready || !pipe_valid_q` is true. This ensures a stalled downstream consumer causes `s_axis.tready` to deassert within one cycle, holding upstream data without dropping beats.

### 5.4 Resource cost summary

| Resource | Count |
|----------|-------|
| LUT (33 × 8-bit, shared by all channels) | 264 bits (LUTRAM) |
| Cycle-0 pipeline registers (addr + frac, 3 ch) | 3 × (5 + 3) = 24 bits |
| Cycle-0 sideband registers (`tlast_q`, `tuser_q`) | 2 bits |
| `pipe_valid_q` | 1 bit |
| Output data register (`m_axis.tdata`) | 24 bits |
| Multipliers | 0 (weights 0–8 map to shifts/adds; synthesiser infers no DSP) |

---

## 6. Control Logic

No FSM. The module contains only:

- A `pipe_valid_q` flag that resets to 0 and is set/cleared per the skid rule in §5.3.
- Registered sideband and address/fraction fields that reset to 0.

On reset (`rst_n_i = 0`), `pipe_valid_q`, `tlast_q`, and `tuser_q` are synchronously cleared; data registers take undefined reset values (pipeline outputs are not consumed while `pipe_valid_q = 0`).

---

## 7. Timing

| Metric | Value |
|--------|-------|
| Latency | 1 `clk_dsp` cycle |
| Long-term throughput | 1 pixel / `clk_dsp` cycle |
| `s_axis.tready` deassertion | 1 cycle after downstream stall (standard skid) |

---

## 8. Shared Types

| Type | Usage |
|------|-------|
| `sparevideo_pkg::pixel_t` | Type of `m_axis.tdata` (24-bit packed RGB: `[23:16]` R, `[15:8]` G, `[7:0]` B). |
| `sparevideo_pkg::component_t` | Type of each 8-bit channel intermediate (`interp_r`, `interp_g`, `interp_b`) and each LUT entry. |

---

## 9. Known Limitations

- **Single fixed sRGB curve.** The LUT is a `localparam` baked at synthesis time. No runtime curve selection or CSR override is supported. A parameterised or CSR-driven LUT is a future extension.
- **LUT parity.** The 33 LUT entries are computed from the closed-form sRGB formula. Any Python reference model that mirrors this module must derive its LUT from the same formula and the same rounding mode. A parity test guards against drift between the SV `localparam` values and the Python LUT.
- **No clamping beyond LUT bounds.** The interpolation uses `addr = p[7:3]` (range 0–31) and reads `LUT[addr+1]` (range 1–32). With `p ∈ [0, 255]` this is always in-bounds; no overflow check is needed. Input values outside [0, 255] are not possible given an 8-bit `component_t` input.
- **No higher-order interpolation.** Linear interpolation between 33 LUT points introduces at most ~0.5 LSB quantisation error relative to the true sRGB curve evaluated at each input value. Cubic or higher-order interpolation is not implemented.

---

## 10. References

- [`sparevideo-top-arch.md`](sparevideo-top-arch.md) — Top-level pipeline; placement of `axis_gamma_cor` between the control-flow mux and `u_fifo_out`.
- `docs/plans/2026-04-23-pipeline-extensions-design.md` §3.4 — Per-block design detail (33-entry LUT, linear interpolation).
- **IEC 61966-2-1 (1999)** — Multimedia systems and equipment — Colour measurement and management — Part 2-1: Colour management — Default RGB colour space — sRGB. Defines the transfer function implemented by this module.
