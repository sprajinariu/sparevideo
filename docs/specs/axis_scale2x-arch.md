# `axis_scale2x` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.1 Nearest-neighbour 2×](#41-nearest-neighbour-2)
  - [4.2 Bilinear 2×](#42-bilinear-2)
  - [4.3 Edge handling](#43-edge-handling)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Data flow overview](#51-data-flow-overview)
  - [5.2 FSM and counters](#52-fsm-and-counters)
  - [5.3 Output beat formatter](#53-output-beat-formatter)
  - [5.4 Backpressure handling](#54-backpressure-handling)
  - [5.5 Resource cost summary](#55-resource-cost-summary)
- [6. Control Logic](#6-control-logic)
- [7. Timing](#7-timing)
- [7a. Clock Assumptions](#7a-clock-assumptions)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_scale2x` is a 2× spatial upscaler on a 24-bit RGB AXI4-Stream. For each input row of width `H_ACTIVE_IN` it emits two output rows, each of width `2 · H_ACTIVE_IN`, so an `H_ACTIVE_IN × V_ACTIVE_IN` frame becomes a `2·H_ACTIVE_IN × 2·V_ACTIVE_IN` frame at the output. This lets the `clk_dsp` processing pipeline run at 320×240 — half the linear dimensions, a quarter of the pixel count — while still driving a standard 640×480 VGA panel at the output.

The module sits at the post-gamma tail of the `clk_dsp` pipeline, immediately before the output CDC FIFO, and is itself a compile-time choice: presence is gated by `SCALER == 1` at the top level, and the interpolation kernel is selected at synthesis time via the `SCALE_FILTER` string parameter (`"nn"` or `"bilinear"`). There is no runtime enable — when not desired, the module is omitted entirely from the build.

For where this module sits in the surrounding system, see [`sparevideo-top-arch.md`](sparevideo-top-arch.md).

---

## 2. Module Hierarchy

`axis_scale2x` is a leaf module — no submodules. Instantiated in `sparevideo_top` as `u_scale2x` between `u_gamma_cor.m_axis` and `u_fifo_out.s_axis`, wrapped in `generate if (SCALER == 1)`. When `SCALER == 0` the generate alternative ties `u_gamma_cor.m_axis` directly to `u_fifo_out.s_axis`.

```
sparevideo_top
├── [control-flow mux]   — passthrough / motion / mask / ccl_bbox  →  proc_axis
├── axis_gamma_cor       (u_gamma_cor)   — sRGB display-curve correction
├── axis_scale2x         (u_scale2x)     — this module (only when SCALER == 1)
└── axis_async_fifo      (u_fifo_out)    — CDC clk_dsp → clk_pix
```

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter       | Default                            | Description |
|-----------------|------------------------------------|-------------|
| `H_ACTIVE_IN`   | `sparevideo_pkg::H_ACTIVE` = 320   | Active pixels per input line. Sets the line-buffer depth and the input-column counter range. Must be even. |
| `V_ACTIVE_IN`   | `sparevideo_pkg::V_ACTIVE` = 240   | Active lines per input frame. Informational only — the module emits 2× rows live and never stores a full frame. |
| `SCALE_FILTER`  | `"bilinear"`                       | Interpolation kernel. `"nn"` selects nearest-neighbour (pixel doubling); `"bilinear"` selects bilinear with 2-tap horizontal and 2×2 vertical kernels. Fixed at synthesis time. |

### 3.2 Ports

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| `clk_i`   | input  | `logic`      | `clk_dsp`, rising edge |
| `rst_n_i` | input  | `logic`      | Active-low synchronous reset |
| `s_axis`  | input  | `axis_if.rx` | RGB input stream (DATA_W=24, USER_W=1; `tdata[23:16]`=R, `[15:8]`=G, `[7:0]`=B; `tuser`=SOF, `tlast`=EOL). `tready` is deasserted while the FSM is emitting the four output beats associated with an already-accepted input pixel. |
| `m_axis`  | output | `axis_if.tx` | Upscaled RGB output stream (DATA_W=24, USER_W=1). `tuser` marks the first output beat of the frame; `tlast` marks the last output beat of every output row. |

There is no `enable_i` port — the module's presence in the build is itself the enable.

---

## 4. Concept Description

A 2× spatial upscaler maps each input pixel `S[r, c]` (input row `r`, input column `c`) to a 2×2 block of output pixels at `(2r, 2c)`, `(2r, 2c+1)`, `(2r+1, 2c)`, `(2r+1, 2c+1)`. The total output frame size is `(2·V_ACTIVE_IN) × (2·H_ACTIVE_IN)`. Two interpolation kernels are supported.

### 4.1 Nearest-neighbour 2×

Every output pixel in the 2×2 block is a copy of the source pixel:

```
out(2r,   2c  ) = S[r, c]
out(2r,   2c+1) = S[r, c]
out(2r+1, 2c  ) = S[r, c]
out(2r+1, 2c+1) = S[r, c]
```

The two output rows associated with input row `r` are therefore identical, and each is the pixel-doubled copy of `S[r]`. No previous-row line buffer is needed.

### 4.2 Bilinear 2×

The horizontal kernel is a 2-tap average and the vertical kernel is a 2-tap average, applied separably. For an input row `S[r] = (A, B, C, …, X)` of `W = H_ACTIVE_IN` pixels:

- **Top output row** (column-doubled, with horizontal interpolants in the odd columns):
  ```
  row_top = (A,  (A+B+1)>>1,   B,  (B+C+1)>>1,   C,  …,  X,  X)
  ```
  The last sample is replicated to keep the output width an even `2·W`.

- **Bottom output row** (vertical interpolants between the top row and the previous-input-row's top row):
  ```
  row_bot[2c  ] = (S[r,c]      + S[r-1,c]      + 1) >> 1
  row_bot[2c+1] = (S[r,c] + S[r,c+1]
                 + S[r-1,c] + S[r-1,c+1] + 2) >> 2
  ```

All weights are powers of two, so the datapath is shift-and-add. Round-half-up is implemented by adding `1` (2-tap) or `2` (4-tap) before the shift: `(a + b + 1) >> 1` and `(a + b + c + d + 2) >> 2`. R, G, and B are processed independently with the same weights.

### 4.3 Edge handling

- **Top edge (`r = 0`).** No previous input row exists. The "previous row" registers are seeded from the current row on its first pass, so `S[-1, c] = S[0, c]` for every `c`. The bottom output row of the first input row therefore equals its top output row.
- **Right edge (`c = W - 1`).** The horizontal interpolant past the last sample replicates the last sample, i.e. the final two output columns of every row both carry the curve value at the last input column. This keeps the output width exactly `2·W`.
- **Left edge (`c = 0`).** No replication is needed: the first output column on every row is the unmodified source pixel.
- **Bottom edge (`r = V_ACTIVE_IN - 1`).** The bottom output row of the last input row uses the previous-row registers from `S[V_ACTIVE_IN - 2]` and the current input row from `S[V_ACTIVE_IN - 1]`; no special case.

---

## 5. Internal Architecture

### 5.1 Data flow overview

```
                  ┌───────────────────────────────────────────────────────┐
                  │                     axis_scale2x                      │
                  │                                                       │
   s_axis_*  ───► │  ┌───────────┐    ┌─────────────────────┐             │
                  │  │ line_buf  │    │  FSM                │             │
                  │  │ prev row  │ ─► │  cur_pix_q          │             │
                  │  │ (W × 24b) │    │  prev_pix_q         │ ─► out fmt  │ ──► m_axis_*
                  │  │           │    │  top_pix_q          │             │
                  │  └─────▲─────┘    │  out_col, out_phase │             │
                  │        │ write    └─────────────────────┘             │
                  │        │ on EOL of current row                        │
                  └────────┴──────────────────────────────────────────────┘
```

Bilinear mode uses two ping-pong source-row line buffers plus a 1-pixel peek window (`cur_q`, `next_q`) to feed the per-channel adders. The buffers store raw source pixels (24-bit RGB); the horizontally-expanded "top" row is recomputed combinationally from buf reads during PHASE_2. NN mode uses a single source-row line buffer and the `cur_q` register only.

### 5.2 FSM and counters

Two states drive the input-side admission and the output-row pairing:

| State              | Meaning                                                                 |
|--------------------|-------------------------------------------------------------------------|
| `S_FILL_FIRST_ROW` | After SOF, accept the first input row into the line buffer with no output. The "previous" row is logically primed equal to this row (top-edge replication). |
| `S_EMIT`           | Steady state. For each accepted input pixel, emit two output rows of two beats each: one beat in `OUT_TOP`, then one beat in `OUT_BOT`, repeated until both output rows for the current input row finish. After EOL of the current input row, the row that was just used as "previous" is overwritten by the current row in the line buffer, ready for the next input row. |

`S_FILL_FIRST_ROW` is entered only on a beat with `tuser = 1` (frame start); after the first row's EOL the FSM transitions unconditionally to `S_EMIT` and stays there until the next SOF, at which point it re-enters `S_FILL_FIRST_ROW`.

Two output counters track progress within the 2×2 block of the currently-held input pixel:

- `out_col` ∈ `[0, 2·H_ACTIVE_IN)` — output column within the current output row.
- `out_phase` ∈ `{OUT_TOP, OUT_BOT}` — selects which of the two output rows for the current input row is being emitted.

Per-input-pixel work is four output beats: two beats (even, odd) in `OUT_TOP`, then two beats (even, odd) in `OUT_BOT`. The "even" beat replays the original pixel (NN) or the column-aligned source (bilinear); the "odd" beat is the horizontal interpolant.

### 5.3 Output beat formatter

The combinational output formatter consumes `cur_pix_q`, `prev_pix_q`, `top_pix_q` (the current input pixel, the previous-column input pixel within the current row, and the same-column input pixel from the previous row) and selects the output `tdata` per `(out_phase, out_col[0])`:

| `out_phase` | `out_col[0]` | NN `tdata`   | Bilinear `tdata`                                  |
|-------------|--------------|--------------|---------------------------------------------------|
| `OUT_TOP`   | 0 (even)     | `cur_pix_q`  | `cur_pix_q`                                       |
| `OUT_TOP`   | 1 (odd)      | `cur_pix_q`  | `(cur_pix_q + cur_next + 1) >> 1` per channel     |
| `OUT_BOT`   | 0 (even)     | `cur_pix_q`  | `(cur_pix_q + top_pix_q + 1) >> 1` per channel    |
| `OUT_BOT`   | 1 (odd)      | `cur_pix_q`  | `(cur_pix_q + cur_next + top_pix_q + top_next + 2) >> 2` per channel |

`cur_next`/`top_next` are the column-`+1` neighbours; on the right edge they are replicated from `cur_pix_q`/`top_pix_q`. Sideband:

- `m_axis.tuser = (out_phase == OUT_TOP) && (out_col == 0) && first_input_row_of_frame`.
- `m_axis.tlast = (out_col == 2·H_ACTIVE_IN − 1)` — asserts on the last beat of every output row, i.e. twice per input row.
- `m_axis.tvalid` asserts whenever the formatter has a beat to present (i.e. the FSM is in `S_EMIT` and a current input pixel has been accepted).

### 5.4 Backpressure handling

`s_axis.tready` is asserted only when the FSM has fully drained the four output beats associated with the previously-accepted input pixel and the next input pixel is needed. Concretely:

```
s_axis.tready  =  (state_q == S_FILL_FIRST_ROW)
               || (state_q == S_EMIT && out_phase == OUT_BOT
                   && out_col == 2·H_ACTIVE_IN − 1
                   && m_axis.tvalid && m_axis.tready)
               || (state_q == S_EMIT && first_pixel_of_row_pending)
```

The first clause loads the line buffer; the second clause releases backpressure on the cycle the final output beat for the current input pixel is accepted; the third clause fast-paths the first input pixel of each new input row (no in-flight pixel to drain). Output side uses a standard registered-`tvalid` skid against `m_axis.tready` so a downstream stall holds the current beat without dropping it.

The previous-row line buffer is read at the input-column index of the input pixel currently being absorbed and written at the same index on the EOL beat that completes the row, so a single dual-port BRAM (or two single-port RAMs) suffices.

### 5.5 Resource cost summary

| Resource                                         | Count |
|--------------------------------------------------|-------|
| Source-row line buffers (bilinear mode)          | 2 × `H_ACTIVE_IN` × 24 bits = 15,360 bits at `H_ACTIVE_IN = 320`. Ping-pong: one buffer holds the row currently being streamed in (the "cur" row, used by both top-row and bot-row emit) while the other holds the previous row (used only by bot-row emit). On the first row of a frame both buffers are written identically to seed the top-edge replicate. NN mode uses only one such buffer. |
| Pipeline registers (`cur_pix_q`, `prev_pix_q`, `top_pix_q`) | 3 × 24 bits = 72 bits (`prev`/`top` unused in NN mode and optimised away) |
| Counters (`out_col`, `out_phase`, input-column counter) | `$clog2(2·H_ACTIVE_IN)` + 1 + `$clog2(H_ACTIVE_IN)` ≈ 19 bits at `H_ACTIVE_IN = 320` |
| Adders (per channel, 9-bit and 10-bit shift-and-add for 2-tap and 4-tap) | 3 × 2 (R/G/B × top-row + bottom-row) |
| Multipliers / DSPs                               | 0 |

---

## 6. Control Logic

The two-state FSM in §5.2 plus the `out_col`/`out_phase` counters form the entire control. There are no nested FSMs.

- **Reset (`rst_n_i = 0`).** `state_q ← S_FILL_FIRST_ROW`, `out_col ← 0`, `out_phase ← OUT_TOP`, `m_axis.tvalid ← 0`. Line-buffer contents are undefined and are not consumed before the first row's EOL.
- **State transitions.**
  - `S_FILL_FIRST_ROW → S_EMIT` on the accepted input beat with `tlast = 1` (end of first input row); the line buffer at that point holds row 0, and the FSM begins emitting paired output rows starting from row 0 with the previous-row registers seeded equal to the current row (top-edge replication).
  - `S_EMIT → S_FILL_FIRST_ROW` on any accepted input beat with `tuser = 1` (next frame's SOF). This re-arms the top-edge replication for the new frame.
- **Counter updates.** `out_col` increments on every accepted output beat; on `out_col == 2·H_ACTIVE_IN − 1` it wraps to 0 and `out_phase` toggles. After the second `out_phase` toggle (i.e. both output rows for the current input pixel are done), `s_axis.tready` is reasserted to admit the next input pixel.

---

## 7. Timing

| Metric | Value |
|--------|-------|
| Latency from first `s_axis` SOF beat to first `m_axis` beat | 1 input line (~`H_ACTIVE_IN` `clk_dsp` cycles) — the `S_FILL_FIRST_ROW` pass |
| Long-term throughput | 4 output pixels per input pixel, i.e. `s_axis` is back-pressured to one accepted beat every 4 `clk_dsp` cycles in steady state |
| `s_axis.tready` deassertion under output stall | 1 cycle (standard registered-output skid) |

The 4× output-to-input ratio matches the nominal 1:4 `clk_pix` : `clk_dsp` ratio, so the output CDC FIFO `u_fifo_out` continues to drain at one pixel per `clk_pix` cycle without underrun. Output FIFO depth must accommodate the run-length burst pattern and is sized at the top level, not here.

---

## 7a. Clock Assumptions

This module lives in `clk_dsp`. Correctness depends on the surrounding top-level wiring, where the input AXIS arrives via a CDC FIFO from `clk_pix_in_i` and the output AXIS leaves via a CDC FIFO into `clk_pix_out_i`.

- **Long-term rate balance.** For every input pixel the module emits 4 output pixels, so `clk_pix_in_i × 4 = clk_pix_out_i` on average over a frame. Sustained mismatch (≥ a few hundred ppm over thousands of frames) drifts the output FIFO and trips the top-level `assert_fifo_out_no_overflow` or `assert_no_output_underrun` SVAs.
- **Per-frame startup.** Every input SOF triggers `S_FILL_FIRST_ROW` — the module emits no output for ~1 input row of `clk_dsp` time. The output VGA controller is in `V_BLANK` for the matching real-time interval, so under nominal rate balance no underflow occurs at the seam between frames. With the TB porches (`H_BLANK=16, V_BLANK=16`), `S_FILL_FIRST_ROW` ≈ 50 µs vs output `V_BLANK` ≈ 430 µs ⇒ ~8× headroom.
- **Phase between input SOF and output VGA frame boundary** is **not** enforced by this module. The top-level `vga_started` one-shot aligns frame 0 to the first SOF; subsequent frames rely on the rate balance plus `V_BLANK_OUT` slack to absorb the per-frame startup delay above.
- **Real-silicon deployments** must satisfy the rate-balance constraint through one of: (a) genlock — derive `clk_pix_out_i` from `clk_pix_in_i` via a PLL; (b) a frame buffer between the pipeline and VGA, with explicit drop/duplicate-frame logic; (c) audit headroom for the worst-case crystal tolerance on both clocks. Sim is exempt because clock periods are exact.

See also `docs/plans/2026-04-23-pipeline-extensions-design.md` §2 ("Clock-stability assumptions") and §3.5 ("Per-frame startup", "Rate-balance precondition") for the cross-block treatment.

---

## 8. Shared Types

| Type | Usage |
|------|-------|
| `sparevideo_pkg::pixel_t`     | Type of `s_axis.tdata`, `m_axis.tdata`, and the `cur`/`prev`/`top` pipeline registers (24-bit packed RGB, `[23:16]` R, `[15:8]` G, `[7:0]` B). |
| `sparevideo_pkg::component_t` | Type of each 8-bit channel intermediate inside the per-channel adders. |
| `sparevideo_pkg::H_ACTIVE`    | Default for `H_ACTIVE_IN`. |
| `sparevideo_pkg::V_ACTIVE`    | Default for `V_ACTIVE_IN` (informational). |

---

## 9. Known Limitations

- **`H_ACTIVE_IN` must be even.** The horizontal output width is `2·H_ACTIVE_IN`; the right-edge-replication logic assumes the input width is exact. Odd widths are not supported.
- **Right-edge replication is the only horizontal edge policy.** No reflect, no zero-pad. The penultimate horizontal interpolant past the last column duplicates the last sample.
- **Top-edge replication is the only vertical edge policy for `r = 0`.** The first input row's bottom output row equals its top output row.
- **`SCALE_FILTER` is fixed at synthesis time.** No runtime kernel selection. Switching between NN and bilinear requires rebuild.
- **2× only.** No support for non-2× factors (1.5×, 3×, …). A future general scaler would replace this module rather than parameterise it.
- **Single previous-row line buffer.** A second buffer would let `S_FILL_FIRST_ROW` overlap with `S_EMIT` to remove the 1-line first-frame latency, but is not implemented.

---

## 10. References

- [`sparevideo-top-arch.md`](sparevideo-top-arch.md) — Top-level pipeline; placement of `axis_scale2x` between `u_gamma_cor` and `u_fifo_out`.
- `docs/plans/2026-04-23-pipeline-extensions-design.md` §3.5 — Per-block design detail (NN and bilinear kernels, edge policy).
- `docs/plans/2026-04-23-pipeline-extensions-design.md` Risk A1 — Output-side CDC FIFO depth must absorb the 4×-burst pattern produced by this module.
- `docs/plans/2026-04-23-pipeline-extensions-design.md` Risk A4 — Gamma correction must precede this module so interpolation operates on display-curve-encoded values, not linear values.
- **ARM IHI0051A — AMBA AXI4-Stream Protocol Specification** — §2.2 (handshake), §2.7 (`tuser`/`tlast`).
