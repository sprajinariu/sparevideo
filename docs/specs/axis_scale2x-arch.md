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
  - [5.2 FSM and counters](#52-fsm-and-counters)
  - [5.3 Output beat formatter](#53-output-beat-formatter)
  - [5.4 Backpressure and buffer write policy](#54-backpressure-and-buffer-write-policy)
  - [5.5 Resource cost summary](#55-resource-cost-summary)
- [6. Control Logic](#6-control-logic)
- [7. Timing](#7-timing)
- [7a. Clock Assumptions](#7a-clock-assumptions)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

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
| `clk_i`   | input  | `logic`      | `clk_dsp`, rising edge |
| `rst_n_i` | input  | `logic`      | Active-low synchronous reset |
| `s_axis`  | input  | `axis_if.rx` | RGB input stream. `tready` is asserted only while the FSM is in `S_RX_FIRST` or `S_RX_NEXT` (see §5.2); it is deasserted during top-row beat emission and during the entire bot-row replay phase that follows each source row. |
| `m_axis`  | output | `axis_if.tx` | Upscaled RGB output stream. `tuser` marks the very first beat of each frame; `tlast` asserts on the last beat of every output row (so twice per source row, once at the end of the top output row and once at the end of the bot output row). |

There is no `enable_i` port — the module's presence in the build is itself the enable.

---

## 4. Concept Description

A 2× spatial upscaler maps each input pixel `S[r, c]` (input row `r`, input column `c`) to a 2×2 block of output pixels at `(2r, 2c)`, `(2r, 2c+1)`, `(2r+1, 2c)`, `(2r+1, 2c+1)`. The total output frame size is `(2·V_ACTIVE_IN) × (2·H_ACTIVE_IN)`.

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

Equivalently, sliding the anchor across an input row `S[r] = (A, B, C, …, X)` of `W = H_ACTIVE_IN` pixels yields the row-level form:

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
            ┌────────────────────────────────────────────────────────────┐
            │                       axis_scale2x                         │
            │                                                            │
            │     ┌─────────────────────────────────┐                    │
            │     │  6-state FSM                    │                    │
            │     │  S_RX_FIRST → S_RX_NEXT →       │                    │
            │     │  S_TOP1/2 → S_BOT1/2            │                    │
            │     └─────────────────────────────────┘                    │
            │                                                            │
   s_axis ──┼──► ┌──────────────────┐    cur_q                           │
            │    │ peek window      │ ─────────────┐                     │
            │    │ cur_q, next_q    │              │                     │
            │    └────────┬─────────┘              │                     │
            │             │                        ▼                     │
            │             │ writes        ┌─────────────────┐            │
            │             ▼               │  output         │            │
            │    ┌──────────────────┐     │  formatter      │            │
            │    │ buf0, buf1       │ ──► │  S_TOP1: cur_q  │ ──► m_axis │
            │    │ (W × 24b each)   │     │  S_TOP2:        │            │
            │    │ ping-pong        │     │   avg2(cur,nxt) │            │
            │    │ cur_sel_q        │     │  S_BOT1/2:      │            │
            │    └──────────────────┘     │   bot_even/odd  │            │
            │                             │   from buffers  │            │
            │                             └─────────────────┘            │
            └────────────────────────────────────────────────────────────┘
```

Top-row beats are formatted from the `cur_q`/`next_q` peek window during the source row's intake. Bot-row beats are formatted by replaying both buffers (current row and previous row) after the source row's `tlast` has been seen. The two phases never overlap on the same source row.

### 5.2 FSM and counters

Six states. **Output beats are emitted sequentially, one per cycle when `m_axis.tready = 1` — never in parallel.** The four output pixels associated with one source anchor `S[r, c]` are produced by four distinct FSM states across two non-contiguous time windows:

- **Top pair** (`out[2r, 2c]` and `out[2r, 2c+1]`) — emitted during `S_TOP1`/`S_TOP2`, **interleaved with input acceptance** as the source row streams in.
- **Bot pair** (`out[2r+1, 2c]` and `out[2r+1, 2c+1]`) — **deferred** until after the entire source row has been consumed, then emitted as part of the `2W`-beat bot-row replay during `S_BOT1`/`S_BOT2`.

The output stream is raster-scan: for source row `r`, all `2W` top-row beats are emitted first (interleaved with intake), then all `2W` bot-row beats (back-to-back, no input).

#### Input backpressure pattern

`s_axis.tready` is asserted only in `S_RX_FIRST` and `S_RX_NEXT`. The input therefore sees backpressure in two distinct regimes:

- **Within-row, intermittent.** Each peeked input pair `(cur, next)` requires 1 RX cycle followed by 2 TOP-emit cycles before another input can be accepted. At steady state `tready` follows a `1·0·0` pattern (one accept per three cycles). The right-edge replicate adds one extra `(0, 0)` TOP pair without intervening RX, since `next` is held equal to `cur`.
- **Cross-row, sustained.** Once the row's last input has been peeked, `tready` deasserts for the full `2W` cycles of bot-row replay. The next row's first pixel is accepted in the cycle after the bot row's last beat retires.

The handshake itself is a single line of RTL — see §5.4.

#### State transitions

```
                 ┌───────────────────────────────────────────────────────┐
                 │  end-of-bot-row: out_col_q == 2W-1                    │
                 │  (flip cur_sel_q, clear first_row_q)                  │
                 ▼                                                       │
            ┌─────────────┐                                              │
            │ S_RX_FIRST  │◄────────────────────────────────┐            │
            └──────┬──────┘                                 │            │
                   │ rx_accept                              │            │
                   ▼                                        │            │
            ┌─────────────┐                                 │            │
            │ S_RX_NEXT   │◄────────────────────┐           │            │
            └──────┬──────┘                     │           │            │
                   │ rx_accept                  │           │            │
                   ▼                            │           │            │
            ┌─────────────┐                     │           │            │
       ┌───►│ S_TOP1      │                     │           │            │
       │    └──────┬──────┘                     │           │            │
       │           │ m_tready                   │           │            │
       │           ▼                            │           │            │
       │    ┌─────────────┐                     │           │            │
       │    │ S_TOP2      │                     │           │            │
       │    └──┬───────┬──┘                     │           │            │
       │       │       │ m_tready,              │           │            │
       │       │       │ !cur_is_last           │           │            │
       │       │       ├────────────────────────┘           │            │
       │       │       │ (next_is_last? S_TOP1 : S_RX_NEXT) │            │
       │       │       │                                    │            │
       │       │       └─────► (right-edge: back to S_TOP1) │            │
       │       │                                            │            │
       │       │ m_tready, cur_is_last                      │            │
       │       │ (out_col_q ← 0, in_col_q ← 0)              │            │
       │       ▼                                            │            │
       │  ┌─────────────┐                                   │            │
       │  │ S_BOT1      │◄─────────────────┐                │            │
       │  └──────┬──────┘                  │                │            │
       │         │ m_tready                │                │            │
       │         │ (out_col_q += 1)        │                │            │
       │         ▼                         │                │            │
       │  ┌─────────────┐                  │                │            │
       │  │ S_BOT2      │                  │                │            │
       │  └──────┬───┬──┘                  │                │            │
       │         │   │ m_tready,           │                │            │
       │         │   │ out_col_q < 2W-1    │                │            │
       │         │   │ (out_col_q += 1)    │                │            │
       │         │   └─────────────────────┘                │            │
       │         │                                          │            │
       │         │ m_tready, out_col_q == 2W-1              │            │
       └─────────┴──────────────────────────────────────────┘            │
                                                                         │
                                                                         │
                  Right-edge replicate path (S_TOP2 → S_TOP1) ───────────┘
```

The S_RX_FIRST / S_RX_NEXT block is the only place `tready = 1`; everything to the right of S_TOP1 holds `tready = 0`.

#### Cycle-by-cycle example (W = 4, `m_tready = 1` throughout)

For one source row `(A, B, C, D)`, 20 cycles total: 12 cycles of top-row intake/emit, 8 cycles of bot-row replay. Inputs are accepted on cycles 0, 1, 4, 7; outputs are emitted on cycles 2–11 (top) and 12–19 (bot).

| cyc | state       | s.tready | s_axis input  | m.tvalid | m_axis output       | notes                                          |
|----:|-------------|:--------:|---------------|:--------:|---------------------|------------------------------------------------|
|  0  | S_RX_FIRST  | 1        | A (sof, !lst) | 0        | —                   | accept A → cur                                 |
|  1  | S_RX_NEXT   | 1        | B (!lst)      | 0        | —                   | accept B → next                                |
|  2  | S_TOP1      | 0        |               | 1        | A                   | emit anchor A; tuser=1 (sof of frame)          |
|  3  | S_TOP2      | 0        |               | 1        | avg2(A, B)          | shift cur ← B; → S_RX_NEXT                    |
|  4  | S_RX_NEXT   | 1        | C (!lst)      | 0        | —                   | accept C → next                                |
|  5  | S_TOP1      | 0        |               | 1        | B                   |                                                |
|  6  | S_TOP2      | 0        |               | 1        | avg2(B, C)          | shift cur ← C                                  |
|  7  | S_RX_NEXT   | 1        | D (lst)       | 0        | —                   | accept D → next, next_is_last=1                |
|  8  | S_TOP1      | 0        |               | 1        | C                   |                                                |
|  9  | S_TOP2      | 0        |               | 1        | avg2(C, D)          | next_is_last=1 → S_TOP1 (skip RX_NEXT)         |
| 10  | S_TOP1      | 0        |               | 1        | D                   |                                                |
| 11  | S_TOP2      | 0        |               | 1        | avg2(D, D) = D      | cur_is_last=1; tlast=1; → S_BOT1              |
| 12  | S_BOT1      | 0        |               | 1        | bot_even @ src_c=0  | out_col_q ← 1                                  |
| 13  | S_BOT2      | 0        |               | 1        | bot_odd  @ src_c=0  | out_col_q ← 2                                  |
| 14  | S_BOT1      | 0        |               | 1        | bot_even @ src_c=1  | out_col_q ← 3                                  |
| 15  | S_BOT2      | 0        |               | 1        | bot_odd  @ src_c=1  | out_col_q ← 4                                  |
| 16  | S_BOT1      | 0        |               | 1        | bot_even @ src_c=2  | out_col_q ← 5                                  |
| 17  | S_BOT2      | 0        |               | 1        | bot_odd  @ src_c=2  | out_col_q ← 6                                  |
| 18  | S_BOT1      | 0        |               | 1        | bot_even @ src_c=3  | out_col_q ← 7                                  |
| 19  | S_BOT2      | 0        |               | 1        | bot_odd  @ src_c=3  | out_col_q == 2W-1; tlast=1; → S_RX_FIRST       |

This matches the §7 budget: `5W = 20` cycles for `4W = 16` output beats, sustained `0.8` beats/cycle. Within-row throughput is `2/3` (2 outputs per 3 cycles) during the intake-interleaved top phase, then `1.0` during the bot phase.

#### State table

| State          | Behaviour |
|----------------|-----------|
| `S_RX_FIRST`   | Accept the first source pixel of a new source row (the row's leftmost column). Buffer the pixel into `buf0`/`buf1` per the write policy in §5.4. Latch `cur_q ← s_axis.tdata`. → `S_RX_NEXT`. |
| `S_RX_NEXT`    | Accept the peeked-ahead pixel as `next_q`. Buffer it. → `S_TOP1`. |
| `S_TOP1`       | Emit top-row even beat: `tdata = cur_q`. → `S_TOP2`. |
| `S_TOP2`       | Emit top-row odd beat: `tdata = avg2(cur_q, next_q)`. If `cur_is_last_q`, source row is done → `S_BOT1`. Else: shift `cur_q ← next_q`. If the just-shifted pair is the right edge (`next_is_last_q`), hold `next_q` and skip back to `S_TOP1`; otherwise → `S_RX_NEXT` to peek the next sample. |
| `S_BOT1`       | Emit bot-row even beat: `tdata = bot_even`. Increment `out_col_q`. → `S_BOT2`. |
| `S_BOT2`       | Emit bot-row odd beat: `tdata = bot_odd`, `tlast = 1` on the last out-col (`out_col_q == 2W − 1`). End-of-row: flip `cur_sel_q` and clear `first_row_q`. → `S_RX_FIRST`. Else: increment `out_col_q` → `S_BOT1`. |

Counters and pipeline registers:

| Signal           | Width                        | Role |
|------------------|------------------------------|------|
| `state_q`        | 3 b                          | Current FSM state. |
| `in_col_q`       | `$clog2(W+1)`                | Source column where the **next** accepted input pixel lands in the buffer. |
| `pair_col_q`     | `$clog2(W+1)`                | Source column of `cur_q`, used to gate `tuser` to the very first emitted beat. |
| `out_col_q`      | `$clog2(2W+1)`               | Output column during bot-row replay, range `[0, 2W − 1]`. |
| `cur_q`, `next_q`| 24 b each                    | Two-pixel peek window for top-row emit. |
| `cur_is_last_q`  | 1 b                          | `cur_q` was the source row's last pixel. |
| `next_is_last_q` | 1 b                          | `next_q` was the source row's last pixel (drives right-edge replicate). |
| `sof_pending_q`  | 1 b                          | Latched on accepted `s_axis.tuser`; cleared on the very first emitted beat (drives `m_axis.tuser`). |
| `first_row_q`    | 1 b                          | 1 while emitting the first row of a frame; clears at end of bot row of row 0. |
| `cur_sel_q`      | 1 b                          | Buffer ping-pong select — picks which of `buf0`/`buf1` is "cur" for bot-row reads. |

### 5.3 Output beat formatter

The combinational formatter selects `m_axis.tdata`/`tvalid`/`tlast`/`tuser` from `state_q`:

| State        | `tdata`                              | `tvalid` | `tlast`                                                                 | `tuser`                                |
|--------------|--------------------------------------|----------|--------------------------------------------------------------------------|----------------------------------------|
| `S_RX_FIRST` | —                                    | 0        | 0                                                                        | 0                                      |
| `S_RX_NEXT`  | —                                    | 0        | 0                                                                        | 0                                      |
| `S_TOP1`     | `cur_q`                              | 1        | 0                                                                        | `sof_pending_q && pair_col_q == 0`     |
| `S_TOP2`     | `avg2(cur_q, next_q)`                | 1        | `cur_is_last_q`                                                          | 0                                      |
| `S_BOT1`     | `bot_even`                           | 1        | 0                                                                        | 0                                      |
| `S_BOT2`     | `bot_odd`                            | 1        | `out_col_q == 2W − 1`                                                    | 0                                      |

The bot-row data is fed by combinational reads from the two ping-pong buffers, with `cur_sel_q` selecting which buffer is "cur" and which is "prev":

```
src_c        = out_col_q >> 1
src_c_next   = min(src_c + 1, W − 1)                        — right-edge clamp

cur_top_odd   = avg2(cur_buf [src_c], cur_buf [src_c_next]) — horizontal 2-tap, current row
prev_top_odd  = avg2(prev_buf[src_c], prev_buf[src_c_next]) — horizontal 2-tap, previous row

bot_even = avg2(cur_buf [src_c], prev_buf[src_c])           — vertical 2-tap
bot_odd  = avg2(cur_top_odd,    prev_top_odd)               — sequential 2-tap (≡ 4-tap ±1 LSB)
```

`avg2(a, b)` is the per-channel 2-tap round-half-up average: `((a + b + 1) >> 1)` applied independently to each 8-bit colour channel.

### 5.4 Backpressure and buffer write policy

**Backpressure.** The handshake is one line:

```
s_axis.tready = (state_q == S_RX_FIRST) || (state_q == S_RX_NEXT)
```

There is no skid buffer. Output `tvalid`/`tdata` are combinational from `state_q`; downstream stall holds `state_q` because every state-advance in the always_ff is gated on `m_axis.tready`.

**Buffer writes.** A pixel accepted in `S_RX_FIRST` or `S_RX_NEXT` is written by the `write_lbufs` task, which always writes to the "cur" buffer at index `in_col_q`. If `effective_first_row` is asserted, the same pixel is *also* written to the "prev" buffer — this seeds the top-edge replicate so row 0's bot-row replay reads `prev == cur` and produces `cur` for every bot beat.

**Ping-pong.** At end of bot row (last beat in `S_BOT2`), `cur_sel_q ← ~cur_sel_q` so the row just streamed in becomes the new "prev" row for the next source row.

**SOF override.** `first_row_q` and `cur_sel_q` are updated by the always_ff tail on the SOF cycle, but those updates only take effect *next* cycle. The case-block writing the buffers in `S_RX_FIRST` runs in the *same* cycle and must therefore see the post-SOF values. Two combinational overrides supply them:

```
is_sof_pixel        = (state_q == S_RX_FIRST) && rx_accept && s_axis.tuser
effective_first_row = first_row_q || is_sof_pixel
effective_cur_sel   = is_sof_pixel ? 1'b0 : cur_sel_q
```

Without this override, the first pixel of every non-zero frame would land in only one buffer (chosen by stale `cur_sel_q`) and the top-edge replicate write to the other buffer would be skipped (because `first_row_q` is still 0 from the previous frame). The visible failure is two mismatched pixels on output row 1 of every non-zero frame whenever the input differs across frame boundaries.

### 5.5 Resource cost summary

Quantities at `H_ACTIVE_IN = 320`. Per-channel adders are 9-bit; counts are pre-synthesis-sharing.

| Resource                              | Count                                                                          |
|---------------------------------------|--------------------------------------------------------------------------------|
| Line buffers (`buf0`, `buf1`)         | 2 × 320 × 24 b = 15,360 b.                                                     |
| Pipeline data regs                    | `cur_q` + `next_q` = 48 b.                                                     |
| Sideband regs                         | `cur_is_last_q`, `next_is_last_q`, `sof_pending_q`, `first_row_q`, `cur_sel_q` = 5 b. |
| Counters                              | `in_col_q` + `pair_col_q` (each `$clog2(321) = 9` b) + `out_col_q` (`$clog2(641) = 10` b) = 28 b. |
| `avg2` instances per channel          | 5 — one in `S_TOP2`, four in the bot-replay datapath (`cur_top_odd`, `prev_top_odd`, `bot_even`, `bot_odd`). 15 9-bit adders total across R/G/B before any synthesis sharing. |
| Multipliers / DSPs                    | 0.                                                                             |

---

## 6. Control Logic

The §5.2 FSM is the entire control. There are no nested FSMs.

- **Reset (`rst_n_i = 0`).** `state_q ← S_RX_FIRST`; all counters and data regs cleared; `sof_pending_q ← 0`; `first_row_q ← 1`; `cur_sel_q ← 0`. Line-buffer contents are undefined; they are not consumed before the first source row's `tlast` is seen.
- **Frame entry.** A new frame is detected by an accepted input beat with `tuser = 1`. The SOF override (§5.4) takes effect in the same cycle to seed the top-edge replicate; the always_ff tail re-arms `first_row_q ← 1` and `cur_sel_q ← 0` for the next cycle.
- **End of source row.** `cur_is_last_q == 1` on the accepted top-row odd beat steers the FSM into `S_BOT1`, with `out_col_q ← 0` and `in_col_q ← 0` to start the bot-row replay and prepare for the next source row's writes.
- **End of bot row.** `out_col_q == 2W − 1` in `S_BOT2` returns the FSM to `S_RX_FIRST`, flips `cur_sel_q`, and clears `first_row_q`.

---

## 7. Timing

| Metric                                                       | Value                                                                       |
|--------------------------------------------------------------|-----------------------------------------------------------------------------|
| Latency from accepted SOF beat to first `m_axis` beat        | 2 `clk_dsp` cycles (peek-ahead)                                              |
| Steady-state output ratio                                    | 4 output beats per source pixel                                              |
| Cycle budget per source row of `W` pixels                    | ≈ `5W` `clk_dsp` cycles for `4W` output beats — output rate ≈ 0.8 beats/cycle |
| Top-row emit phase                                           | `2W` cycles, interleaved with input acceptance                               |
| Bot-row replay phase                                         | `2W` cycles, **input fully back-pressured** (no `s_axis` accept during this window) |
| Hold under downstream stall                                  | indefinite — `state_q` and combinational outputs hold while `m_axis.tready = 0` |

The 4× output-per-input ratio matches a 1:4 input-pixel-clock to DSP-clock ratio in steady state. The `2W`-cycle bot-row replay produces a bursty access pattern at the top-level output FIFO: the source-row's `2W` top beats are interleaved with input accepts (~0.5 beats/cycle), then `2W` bot beats are produced back-to-back with no input. Output FIFO sizing at the top level must absorb this burst.

---

## 7a. Clock Assumptions

This module lives in `clk_dsp`. Correctness depends on the surrounding top-level wiring, where the input AXIS arrives via a CDC FIFO from `clk_pix_in_i` and the output AXIS leaves via a CDC FIFO into `clk_pix_out_i`.

- **Long-term rate balance.** For every input pixel the module emits 4 output pixels, so `clk_pix_in_i × 4 = clk_pix_out_i` on average over a frame. Sustained mismatch drifts the output FIFO and trips the top-level FIFO-overflow / output-underrun SVAs.
- **Per-frame startup.** The module's first-output latency is 2 `clk_dsp` cycles after an accepted SOF. The much larger startup cost is the per-row pattern in §7: each source row produces a `2W`-cycle bot-row replay during which `s_axis` is back-pressured. As long as the downstream VGA controller's `V_BLANK` exceeds those bursts in real time (which it does by a wide margin at any reasonable resolution), no output underflow occurs.
- **Phase between input SOF and output VGA frame boundary** is **not** enforced by this module. Frame-0 alignment is a top-level concern; subsequent frames rely on the rate balance plus output `V_BLANK` slack to absorb the per-frame startup delay above.
- **Real-silicon deployments** must satisfy the rate-balance constraint through one of: (a) genlock — derive `clk_pix_out_i` from `clk_pix_in_i` via a PLL; (b) a frame buffer between the pipeline and VGA, with explicit drop/duplicate-frame logic; (c) audit headroom for the worst-case crystal tolerance on both clocks.

---

## 8. Shared Types

| Symbol | Usage |
|--------|-------|
| `sparevideo_pkg::H_ACTIVE`    | Default for `H_ACTIVE_IN`. |
| `sparevideo_pkg::V_ACTIVE`    | Default for `V_ACTIVE_IN` (informational only). |

The module declares its data registers and arithmetic intermediates as raw `logic [23:0]` (packed RGB888, `[23:16]`=R, `[15:8]`=G, `[7:0]`=B) and `logic [8:0]` (per-channel 9-bit add). It does not use the `pixel_t`/`component_t` typedefs from the package.

---

## 9. Known Limitations

- **`H_ACTIVE_IN` must be even.** The horizontal output width is `2·H_ACTIVE_IN`; the right-edge-replication logic assumes the input width is exact. Odd widths are not supported.
- **Right-edge replication is the only horizontal edge policy.** No reflect, no zero-pad. The penultimate horizontal interpolant past the last column duplicates the last sample.
- **Top-edge replication is the only vertical edge policy for `r = 0`.** The first input row's bottom output row equals its top output row.
- **2× only.** No support for non-2× factors (1.5×, 3×, …). A future general scaler would replace this module rather than parameterise it.
- **Bot-row replay is bursty.** During each source row's bot-replay phase the input is back-pressured for `2W` consecutive cycles (§7). Top-level output FIFO sizing must absorb this; not addressed inside this module.

---

## 10. References

- [`sparevideo-top-arch.md`](sparevideo-top-arch.md) — Top-level pipeline.
- **ARM IHI0051A — AMBA AXI4-Stream Protocol Specification** — §2.2 (handshake), §2.7 (`tuser`/`tlast`).
