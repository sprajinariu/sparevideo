# `axis_scale2x` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.1 Bilinear 2×](#41-bilinear-2)
  - [4.2 Edge handling](#42-edge-handling)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Data flow overview](#51-data-flow-overview)
  - [5.2 Counters, registers, and rotation](#52-counters-registers-and-rotation)
    - [5.2.1 Buffer role assignment](#521-buffer-role-assignment)
    - [5.2.2 SOF same-cycle override](#522-sof-same-cycle-override)
    - [5.2.3 Beat-to-address decode](#523-beat-to-address-decode)
    - [5.2.4 Rotation and boundary synchronization](#524-rotation-and-boundary-synchronization)
    - [5.2.5 Per-row timing](#525-per-row-timing)
  - [5.3 Output beat formatter](#53-output-beat-formatter)
  - [5.4 Backpressure and buffer write policy](#54-backpressure-and-buffer-write-policy)
  - [5.5 Resource cost summary](#55-resource-cost-summary)
- [6. Control Logic](#6-control-logic)
- [7. Timing](#7-timing)
- [8. Clock Assumptions](#8-clock-assumptions)
- [9. Shared Types](#9-shared-types)
- [10. Known Limitations](#10-known-limitations)
- [11. References](#11-references)

---

## 1. Purpose and Scope

`axis_scale2x` is a 2× spatial upscaler on a 24-bit RGB AXI4-Stream. For each input row of width `H_ACTIVE_IN` it emits two output rows, each of width `2 · H_ACTIVE_IN`, so an `H_ACTIVE_IN × V_ACTIVE_IN` frame becomes a `2·H_ACTIVE_IN × 2·V_ACTIVE_IN` frame at the output.

The interpolation kernel is bilinear with 2-tap horizontal and 2×2 vertical kernels. There is no runtime enable and no kernel selection — the module's presence in the build is itself the enable.

---

## 2. Module Hierarchy

`axis_scale2x` is a leaf module — no submodules.

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter       | Default                            | Description |
|-----------------|------------------------------------|-------------|
| `H_ACTIVE_IN`   | `sparevideo_pkg::H_ACTIVE` = 320   | Active pixels per input line. Sets the line-buffer depth and the input-column counter range. Must be even. |
| `V_ACTIVE_IN`   | `sparevideo_pkg::V_ACTIVE` = 240   | Active lines per input frame. Informational only — the module emits 2× rows live and never stores a full frame. |

### 3.2 Ports

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| `clk_i`   | input  | `logic`      | `clk_dsp`, rising edge. |
| `rst_n_i` | input  | `logic`      | Active-low synchronous reset. |
| `s_axis`  | input  | `axis_if.rx` | RGB input stream (24-bit packed RGB888 on `tdata`). |
| `m_axis`  | output | `axis_if.tx` | Upscaled RGB output stream. Same encoding as `s_axis`. |

There is no `enable_i` port — the module's presence in the build is itself the enable. The handshake (`tready`/`tvalid`) and sideband framing (`tuser`/`tlast`) on both ports are detailed in §5.3 and §5.4.

---

## 4. Concept Description

A 2× spatial upscaler maps each input pixel `S[r, c]` (input row `r`, input column `c`) to a 2×2 block of output pixels at `(2r, 2c)`, `(2r, 2c+1)`, `(2r+1, 2c)`, `(2r+1, 2c+1)`. The total output frame size is `(2·V_ACTIVE_IN) × (2·H_ACTIVE_IN)`.

For brevity throughout this document, `W` denotes `H_ACTIVE_IN` (input row width in pixels), and a "**pair**" is the two output rows produced from one input source row — `out[2r]` (top) and `out[2r+1]` (bot). Each pair is `4W` output beats long.

### 4.1 Bilinear 2×

Each input pixel `S[r, c]` is the **anchor** of a 2×2 output block at output coords `(2r..2r+1, 2c..2c+1)`. The anchor is copied unchanged; the three non-anchor output positions are filled with averages drawn from the anchor's right and previous-row neighbours. Each interpolated position lies geometrically *between* the source samples it averages, so a smooth source ramp turns into a smooth output ramp instead of a step at every second column / row. The visible effect is softer edges and no pixel-doubling staircase, at the cost of two extra add-and-shift datapaths per channel and one source-row line buffer; no multipliers are needed because all weights are 1/2 or 1/4.

The source neighbourhood is the anchor pixel plus its right neighbour and the same two columns from the **previous** input row:

```
Source 2×2 neighbourhood around anchor MC = S[r, c]:

       col:    c       c+1
            ┌───────┬───────┐
   row r-1: │  TC   │  TR   │   ← from previous-row line buffer
            ├───────┼───────┤
   row r:   │  MC   │  MR   │   ← current row, just accepted
            └───────┴───────┘
                              MR is the c+1 sample of the current row
                              (right-edge replicate when c = W-1)
```

The 2×2 output block emitted from this neighbourhood:

```
Output coordinates (rows downward, cols rightward):

                col 2c                 col 2c+1
              ┌─────────────────┬───────────────────────────┐
   row 2r:    │      MC         │    (MC + MR + 1) >> 1     │   ← copy ; horizontal 2-tap
              ├─────────────────┼───────────────────────────┤
   row 2r+1:  │ (MC + TC + 1)   │ (MC+MR+TC+TR + 2) >> 2    │   ← vertical 2-tap ; 2×2 box
              │      >> 1       │                           │
              └─────────────────┴───────────────────────────┘
              even out col          odd out col
```

All weights are powers of two, so the datapath is shift-and-add. Round-half-up is implemented by adding `1` (2-tap) before the shift. R, G, and B are processed independently with the same weights. The `(2r+1, 2c+1)` corner can be computed in either of two near-equivalent forms: a single 4-tap `(a + b + c + d + 2) >> 2`, or a sequential 2-tap `avg2(avg2(a, b), avg2(c, d))`. The two differ by at most ±1 LSB depending on the input bit pattern. The implementation uses the **sequential 2-tap** form (see §5.3) — same area, identical `avg2` adder reused across all four output formulas, and the rounding behaviour is fully specified by the same per-channel `(a + b + 1) >> 1` rule used everywhere else.

Equivalently, sliding the anchor across an input row `S[r] = (A, B, C, …, X)` of `W` pixels yields the row-level form:

- **Top output row** `out[2r]` (column-doubled, with horizontal interpolants in the odd columns):
  ```
  out[2r] = (A,  (A+B+1)>>1,   B,  (B+C+1)>>1,   C,  …,  X,  X)
  ```
  The last sample is replicated so the output row width is exactly `2·W`.

- **Bottom output row** `out[2r+1]` (vertical interpolants between the current input row and the previous input row):
  ```
  out[2r+1, 2c  ] = (S[r,c]      + S[r-1,c]                   + 1) >> 1
  out[2r+1, 2c+1] = (S[r,c] + S[r,c+1] + S[r-1,c] + S[r-1,c+1] + 2) >> 2
  ```

> **Note.** At integer 2× the bilinear kernel degenerates to plain equal-weight averaging of the 1, 2, or 4 source samples nearest the new pixel — which is why no multipliers are needed. Non-integer scale factors (e.g. 1.5×) would require fractional weights and a different module.

### 4.2 Edge handling

- **Top edge (`r = 0`).** No previous input row exists. The "previous row" line buffer is seeded from the current row on its first pass, so `S[-1, c] = S[0, c]` for every `c`. The bottom output row of the first input row therefore equals its top output row.
- **Right edge (`c = W - 1`).** The horizontal interpolant past the last sample replicates the last sample, i.e. the final two output columns of every row both carry the curve value at the last input column. This keeps the output width exactly `2·W`.
- **Left edge (`c = 0`).** No replication is needed: the first output column on every row is the unmodified source pixel.
- **Bottom edge (`r = V_ACTIVE_IN - 1`).** The bottom output row of the last input row uses the previous-row registers from `S[V_ACTIVE_IN - 2]` and the current input row from `S[V_ACTIVE_IN - 1]`; no special case.

---

## 5. Internal Architecture

### 5.1 Data flow overview

```
        ┌─────────────────────────────────────────────────────┐
        │                   axis_scale2x                      │
        │                                                     │
        │             ┌─────────────────────────┐             │
s_axis ─┼────────────►│      input writer       │             │
        │             └────────────┬────────────┘             │
        │                          │                          │
        │                          ▼                          │
        │               ┌──────────┬──────────┐               │
        │               │         1:3         │               │
        │ wr_sel_q ────►│        demux        │               │
        │               └─┬────────┬────────┬─┘               │
        │                 │        │        │                 │
        │                 ▼        ▼        ▼                 │
        │             ┌───┬───┐┌───┬───┐┌───┬───┐             │
        │             │ buf 0 ││ buf 1 ││ buf 2 │             │
        │             └───┬───┘└───┬───┘└───┬───┘             │
        │                 │        │        │                 │
        │                 ▼        ▼        ▼                 │
        │             ┌───┬────────┬────────┬───┐             │
        │ anchor_sel ►│     3:1 row mux × 2     │◄ prev_sel   │
        │             │   (anchor + prev rows;  │             │
        │             │    each cols c, c+1)    │             │
        │             └───────┬─────────┬───────┘             │
        │                     │         │                     │
        │                     ▼         ▼                     │
        │             ┌───────┬─────────┬───────┐             │
        │             │     output emitter      │─────────────┼─► m_axis
        │             └─────────────────────────┘             │
        └─────────────────────────────────────────────────────┘
```

The three line buffers live in a single array `buf_mem[3][W]` of 24-bit words. The input writer feeds a 1:3 demux selected by `wr_sel_q`; each `buf[k]` exposes a *pair* of combinational reads per cycle (at `src_c` and `src_cp1`), and two parallel 3:1 row muxes — selected by `anchor_sel` and `prev_sel` — pick which buffer's column-pair becomes the anchor row and which becomes the prev row. The four scalar outputs `anchor_c`, `anchor_cp1`, `prev_c`, `prev_cp1` feed the output emitter.

The per-row buffer roles are aliases over the same array. A 2-bit register `wr_sel_q` selects the write target; `anchor_sel` and `prev_sel` follow combinationally (§5.2). At each row boundary the rotation advances `wr_sel_q` by one (mod 3): the just-filled buffer becomes the next anchor, the previous anchor becomes the next prev, and the previous prev becomes the next write target. Writer and emitter never share a buffer — they run as two independent processes synchronized only at the rotation.

### 5.2 Counters, registers, and rotation

Two independent processes — the **writer** (filling the next buffer with input pixels) and the **emitter** (reading two buffers to produce the output pair) — synchronize only at row boundaries. Control reduces to two counters and a few boolean flags; there is no FSM.

| Signal | Width | Role |
|---|---|---|
| `wr_sel_q` | 2 b | Buffer index being written for the current input row. Advances mod 3 at each rotation. |
| `in_col_q` | `$clog2(W+1)` | Source column where the next accepted pixel lands; resets on `tlast`. |
| `out_beat_q` | `$clog2(4W+1)` | Output beat counter, 0..4W−1; wraps at retirement. |
| `in_done_q` | 1 b | High between accepted `tlast` and the next rotation; deasserts `s_axis.tready`. |
| `emit_armed_q` | 1 b | High while a pair is emitting; gates `m_axis.tvalid`. Cleared at end-of-pair, re-asserted at the next rotation. |
| `first_pair_q` | 1 b | High during pair 0 of a frame; tells the writer to also seed `anchor_buf` (top-edge replicate). Cleared at the first rotation. |
| `sof_pending_q` | 1 b | Latches on accepted input SOF; clears on emitted output SOF. |

#### 5.2.1 Buffer role assignment

The three buffer roles (write, anchor, prev) always pick three different buffers, so the writer and emitter never share one. Roles are derived from `wr_sel_q`: `anchor_sel = (wr_sel_q − 1) mod 3`, `prev_sel = (wr_sel_q − 2) mod 3`. The anchor holds the source row currently being emitted as a pair; the prev buffer holds the source row immediately above it.

#### 5.2.2 SOF same-cycle seed

`first_pair_q` is registered, so on the SOF cycle its new value isn't visible yet. To make the SOF column's seed land on the same edge as the SOF accept, the buffer-write logic uses a combinational override that forces the seed-write condition true on any accepted input SOF, regardless of the registered flag. After that one cycle, the registered flag takes over normally.

#### 5.2.3 Beat-to-address decode

`out_beat_q` is decoded combinationally into a phase (top vs. bot row of the pair), a source column index `src_c = (out_beat_q mod 2W) >> 1`, and an odd/even parity bit. `src_c+1` is clamped at `W−1` to give the right-edge replicate. The output formatter and the buffer-read addresses consume these directly.

#### 5.2.4 Rotation and boundary synchronization

A **rotation** advances `wr_sel_q` mod 3 and re-arms the emitter for the next pair. It fires when both processes are done with the current row: the writer has accepted `tlast` (sets `in_done_q`) and the emitter has retired its `(4W−1)`-th beat (clears `emit_armed_q`). When both conditions hold, the rotation increments `wr_sel_q`, clears `in_done_q`, sets `emit_armed_q`, and clears `first_pair_q`.

A new frame's accepted SOF re-arms `first_pair_q`. `wr_sel_q` is **not** reset — seeding to `anchor_sel` (not to a fixed index) keeps pair 0's `prev_sel` aligned with the seed regardless of where the rotation cycle stands.

#### 5.2.5 Per-row timing

Under the nominal 1:4 input-to-DSP rate ratio (§8), the writer's `W` input cycles and the emitter's `4W` DSP cycles complete simultaneously and the rotation is seamless. If upstream stalls, the emitter idles after its last beat until input finishes. If downstream stalls, the writer idles after `tlast` (with `tready` low) until the emitter catches up. Either way, the rotation waits for both.

### 5.3 Output beat formatter

Each output cycle the formatter selects `m_axis.tdata` from the buffer reads (`anchor_c`, `anchor_cp1`, `prev_c`, `prev_cp1`) according to the phase and parity bits decoded in §5.2:

```
                       beat_is_odd = 0          beat_is_odd = 1
                       (even out col)           (odd out col)
top phase:             anchor_c                 avg2(anchor_c, anchor_cp1)
(out_beat in [0, 2W))

bot phase:             avg2(anchor_c, prev_c)   avg2( avg2(anchor_c, anchor_cp1),
(out_beat in [2W, 4W))                                avg2(prev_c,   prev_cp1)   )
```

`avg2(a, b)` is the per-channel 2-tap round-half-up average `((a + b + 1) >> 1)`, applied independently to R, G, and B. `avg2(a, a) = a` exactly. The bot-odd 4-tap is the sequential-2-tap form (avg2 of two avg2s), differing from a true 4-tap `(a + b + c + d + 2) >> 2` by at most ±1 LSB but reusing the same `avg2` adder and producing a fully specified rounding rule.

Sideband signals on `m_axis`:

- `tlast` asserts at the last beat of each output row: `out_beat_q == 2W − 1` (end of top row) or `out_beat_q == 4W − 1` (end of bot row, end of pair). Each output row is therefore a separate AXI-Stream packet.
- `tuser` asserts at the first beat of the first pair of a frame: `sof_pending_q && out_beat_q == 0`.

### 5.4 Backpressure and buffer-write policy

`s_axis.tready` is gated by `in_done_q` — the writer accepts pixels until `tlast`, then `tready` goes low until the rotation fires. There is no per-pixel back-pressure. `m_axis.tvalid` follows `emit_armed_q`, which is cleared at end-of-pair and re-asserted at the rotation.

Long-term throughput is therefore clamped to one input row per `4W` DSP cycles. A faster-than-1:4 upstream finishes early and is held at the row boundary; a slower upstream lets the emitter retire first, then the rotation waits for `tlast`. Bursty input is absorbed within a row.

A narrow defensive stall additionally holds `tready` low if an input SOF arrives while a pair is still emitting, so the new frame's seed cannot clobber the `anchor_buf` the in-flight pair is still reading. Under nominal V_BLANK timing this never fires.

**Buffer writes.** Each accepted pixel is written to `write_buf[in_col_q]`. During pair 0 of every frame the same pixel is *also* written to `anchor_buf[in_col_q]` — that's the top-edge replicate seed, placed where pair 0's `prev_sel` will read it after the next rotation. `anchor_buf` is not read during pair-0 intake, so there is no conflict.

**Frame entry.** Accepted SOF re-arms `first_pair_q`; `wr_sel_q` continues rotating from wherever the previous frame left it.

### 5.5 Resource cost summary

Quantities at `H_ACTIVE_IN = 320`. Per-channel adders are 9-bit; counts are pre-synthesis-sharing.

| Resource | Count |
|---|---|
| Line buffers (`buf_mem[0..2]`) | 3 × 320 × 24 b = 23,040 b. |
| Counters | `in_col_q` (9 b) + `wr_sel_q` (2 b) + `out_beat_q` (11 b) = 22 b. |
| Sideband regs | `in_done_q`, `emit_armed_q`, `first_pair_q`, `sof_pending_q` = 4 b. |
| `avg2` instances per channel | 5 — `avg2(anchor_c, anchor_cp1)`, `avg2(prev_c, prev_cp1)`, `avg2(anchor_c, prev_c)`, and the two outer averages of the bot-odd sequential-2-tap formula. 15 9-bit adders total across R/G/B before any synthesis sharing. |
| Multipliers / DSPs | 0. |

---

## 6. Control Logic

§5.2 covers the entire control surface — there is no separate FSM. The relevant boundary behaviours are:

- **Reset (`rst_n_i = 0`).** `wr_sel_q ← 0`; counters cleared (`in_col_q`, `out_beat_q`); `in_done_q ← 0`; `emit_armed_q ← 0`; `first_pair_q ← 1`; `sof_pending_q ← 0`. Line-buffer contents are undefined; they are not consumed before the first source row's `tlast` is seen.
- **Frame entry.** An accepted input beat with `tuser = 1` re-arms `first_pair_q ← 1` (so the same-cycle `effective_first_pair` triggers the top-edge-replicate seed write into `anchor_buf`) and latches `sof_pending_q ← 1`. `wr_sel_q` continues rotating from wherever the previous frame left it — the rotation is invariant under starting offset (see §5.4).
- **End of source row.** Accepted `s_axis.tlast` resets `in_col_q ← 0` and asserts `in_done_q ← 1`. `s_axis.tready` deasserts so no further input is accepted until the rotation fires.
- **End of pair emit.** The retiring `out_beat_q == 4W − 1` beat resets `out_beat_q ← 0` and clears `emit_armed_q ← 0`.
- **Boundary rotation.** When both `in_done_q == 1` and `emit_armed_q == 0` are true on the same cycle, `wr_sel_q` advances by 1 (mod 3), `in_done_q` clears, `emit_armed_q` re-asserts (next pair begins emitting), and `first_pair_q` clears (after the first pair's seed has been written).

---

## 7. Timing

| Metric | Value |
|---|---|
| Latency from accepted SOF beat to first `m_axis` beat | `4W` `clk_dsp` cycles (1 input row at the nominal 1:4 input/DSP rate) |
| Steady-state output ratio | 4 output beats per source pixel |
| Cycle budget per source row of `W` pixels | `4W` `clk_dsp` cycles for `4W` output beats — output rate **1.0 beats/cycle** sustained |
| Top-row emit phase | First 2W of the 4W cycles, no input-side back-pressure |
| Bot-row emit phase | Second 2W of the 4W cycles, no input-side back-pressure |
| Hold under downstream stall | Indefinite — `out_beat_q` and `emit_armed_q` hold; `in_done_q` blocks new input once the row completes |
| Hold under upstream stall | Indefinite — emitter idles once `out_beat_q == 4W−1` retires; rotation waits for `in_done_q` |

The 1-row startup latency is the cost of the uniform schedule: pair 0's bot row uses row 0 as both anchor and prev (top-edge replicate), so it can't be emitted until row 0 is fully buffered. From pair 1 onward the design is in steady state — every row consumes exactly 4W DSP cycles, with the emitter and writer running concurrently and finishing simultaneously under nominal rate balance.

---

## 8. Clock Assumptions

This module lives in `clk_dsp`. Correctness depends on the surrounding top-level wiring, where the input AXIS arrives via a CDC FIFO from `clk_pix_in_i` and the output AXIS leaves via a CDC FIFO into `clk_pix_out_i`.

- **Long-term rate balance.** For every input pixel the module emits 4 output pixels, so `clk_pix_in_i × 4 = clk_pix_out_i` on average over a frame. Sustained mismatch drifts the output FIFO and trips the top-level FIFO-overflow / output-underrun SVAs.
- **Per-frame startup.** The module's first-output latency is `4W` `clk_dsp` cycles after an accepted SOF — one full input row at the 1:4 input/DSP rate, needed because pair 0's bot row reads row 0 from a fully-buffered anchor (and the seeded prev). After this 1-row primer, the module runs at uniform sustained throughput: each source row produces 4W output beats over 4W DSP cycles. Downstream `V_BLANK` slack absorbs the per-frame primer; with sparevideo's `V_BACK_PORCH_OUT_2X` etc. (output blanking doubled with the scaler enabled) there is far more than 4W cycles of headroom.
- **Phase between input SOF and output VGA frame boundary** is **not** enforced by this module. Frame-0 alignment is a top-level concern; subsequent frames rely on the rate balance plus output `V_BLANK` slack to absorb the per-frame startup delay above.
- **Real-silicon deployments** must satisfy the rate-balance constraint through one of: (a) genlock — derive `clk_pix_out_i` from `clk_pix_in_i` via a PLL; (b) a frame buffer between the pipeline and VGA, with explicit drop/duplicate-frame logic; (c) audit headroom for the worst-case crystal tolerance on both clocks.

---

## 9. Shared Types

| Symbol | Usage |
|--------|-------|
| `sparevideo_pkg::H_ACTIVE`    | Default for `H_ACTIVE_IN`. |
| `sparevideo_pkg::V_ACTIVE`    | Default for `V_ACTIVE_IN` (informational only). |

The module declares its data registers and arithmetic intermediates as raw `logic [23:0]` (packed RGB888, `[23:16]`=R, `[15:8]`=G, `[7:0]`=B) and `logic [8:0]` (per-channel 9-bit add). It does not use the `pixel_t`/`component_t` typedefs from the package.

---

## 10. Known Limitations

- **`H_ACTIVE_IN` must be even.** The horizontal output width is `2·H_ACTIVE_IN`; the right-edge-replication clamp assumes the input width is exact. Odd widths are not supported.
- **Right-edge replication is the only horizontal edge policy.** No reflect, no zero-pad. The penultimate horizontal interpolant past the last column duplicates the last sample.
- **Top-edge replication is the only vertical edge policy for `r = 0`.** The first input row's bottom output row equals its top output row.
- **2× only.** No support for non-2× factors (1.5×, 3×, …). A future general scaler would replace this module rather than parameterise it.
- **One-input-row latency from SOF to first output beat.** This is structural to the uniform 3-buffer schedule (pair 0's bot needs row 0 fully buffered before it can read it). For the project's video resolutions this is sub-millisecond and irrelevant; for ultra-low-latency applications a different upscaler would be needed.
- **`H_ACTIVE_IN`-deep × 24-bit × 3 line buffers** are instantiated regardless of the input row's actual width. Rows are assumed to always be exactly `H_ACTIVE_IN` wide (matches top-level usage); shorter rows are not supported.

---

## 11. References

- [`sparevideo-top-arch.md`](sparevideo-top-arch.md) — Top-level pipeline.
- **ARM IHI0051A — AMBA AXI4-Stream Protocol Specification** — §2.2 (handshake), §2.7 (`tuser`/`tlast`).
