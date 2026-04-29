# `axis_hflip` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Data flow overview](#51-data-flow-overview)
  - [5.2 RX/TX phases](#52-rxtx-phases)
  - [5.3 `enable_i` bypass](#53-enable_i-bypass)
  - [5.4 Resource cost summary](#54-resource-cost-summary)
- [6. Control Logic and State Machines](#6-control-logic-and-state-machines)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_hflip` performs a horizontal mirror ("selfie-cam") on a 24-bit RGB AXI4-Stream. Each input row is stored in a single line buffer and replayed in reverse column order; row order is unchanged. SOF (`tuser`) and EOL (`tlast`) are regenerated to match the mirrored output timing.

The module is placed at the head of the `clk_dsp` pipeline, before the control-flow mux, so motion masks and bbox coordinates downstream are computed on the user-visible (mirrored) frame. No coordinate translation is needed in any consumer.

When `enable_i = 0`, the module is a zero-latency combinational passthrough.

For placement context (input CDC FIFO, fork, control-flow mux) and for the system-level FIFO sizing implied by this module's stall behavior, see [`sparevideo-top-arch.md`](sparevideo-top-arch.md).

---

## 2. Module Hierarchy

`axis_hflip` is a leaf module — no submodules. Instantiated in `sparevideo_top` as `u_hflip` between the input CDC FIFO output and the control-flow mux.

```
sparevideo_top
├── axis_async_fifo  (u_fifo_in)   — CDC clk_pix → clk_dsp
├── axis_hflip       (u_hflip)     — this module
└── [control-flow mux]             — passthrough / motion / mask / ccl_bbox
```

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter  | Default                          | Description |
|------------|----------------------------------|-------------|
| `H_ACTIVE` | `sparevideo_pkg::H_ACTIVE` = 320 | Active pixels per line. Sets line-buffer depth and column-counter range. |
| `V_ACTIVE` | 240                              | Active lines per frame. Informational only — not used internally. |

### 3.2 Ports

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| `clk_i`    | input  | `logic`      | `clk_dsp`, rising edge |
| `rst_n_i`  | input  | `logic`      | Active-low synchronous reset |
| `enable_i` | input  | `logic`      | 1 = mirror via FSM; 0 = zero-latency combinational passthrough. Frame-stable. |
| `s_axis`   | input  | `axis_if.rx` | RGB input stream (DATA_W=24, USER_W=1; tuser=SOF). tready=1 during RX phase, 0 during TX; when `enable_i=0` mirrors `m_axis.tready`. |
| `m_axis`   | output | `axis_if.tx` | RGB mirrored output stream (DATA_W=24, USER_W=1). tvalid asserted during TX phase. |

---

## 4. Concept Description

A horizontal flip maps each pixel at column `c` of an `H_ACTIVE`-wide row to column `H_ACTIVE − 1 − c` in the output. Because pixels arrive in raster-scan order, the first output pixel of a row (which is the last input pixel) cannot be produced until the entire input row has been received. This forces buffering at least one full line.

The module alternates between two phases per input line:

- **RX:** absorb one complete input line into the line buffer, left-to-right; output is idle.
- **TX:** read the line buffer in reverse and present each pixel on the output; input is stalled.

SOF arriving on an accepted RX beat is latched and re-emitted on the first TX beat of the resulting line.

---

## 5. Internal Architecture

### 5.1 Data flow overview

```
                  ┌────────────────────────────────────────────────────┐
                  │                    axis_hflip                      │
                  │                                                    │
   s_axis_*  ───► │  ┌─────────┐  tlast accepted   ┌─────────┐         │
                  │  │  S_RX   │ ────────────────► │  S_TX   │         │
                  │  │ wr_col  │                   │ rd_col  │         │
                  │  └────┬────┘  ◄──────────────  └────┬────┘         │
                  │       │       eol accepted           │             │
                  │       ▼                              ▼             │
                  │  line_buf[wr_col] ◄── tdata    line_buf[H-1-rd_col]│ ───► m_axis_*
                  │                                                    │
                  └────────────────────────────────────────────────────┘
```

`enable_i = 0` is not shown: it bypasses the FSM by muxing all five output signals combinationally to the corresponding input signals (see §5.3).

### 5.2 RX/TX phases

**RX (`state_q == S_RX`):** `s_axis_tready_o = 1`. On each accepted beat (`tvalid && tready && enable_i`), write `line_buf[wr_col] <= tdata` and increment `wr_col`. If `tuser=1` on the beat, write `line_buf[0]` instead, set `sof_pending`, and set `wr_col` to 1. On the accepted beat with `tlast=1`, reset `wr_col` to 0 and transition to TX.

**TX (`state_q == S_TX`):** `m_axis_tvalid_o = 1`. The output drives `tdata = line_buf[H_ACTIVE − 1 − rd_col]`, `tuser = sof_pending && (rd_col == 0)`, `tlast = (rd_col == H_ACTIVE − 1)`. On each accepted output beat, increment `rd_col`. On the accepted beat with `rd_col == H_ACTIVE − 1`, clear `sof_pending`, reset `rd_col` to 0, and transition back to RX.

### 5.3 `enable_i` bypass

When `enable_i = 0`, the always_comb mux drives all five output signals combinationally from the corresponding inputs (`tdata`, `tvalid`, `tlast`, `tuser` direct; `s_axis_tready_o = m_axis_tready_i`). The FSM is held idle (`rx_accept` is gated by `enable_i`), the line buffer is neither read nor written, and zero latency is added. `enable_i` must be held stable across a frame.

### 5.4 Resource cost summary

| Resource | Count |
|----------|-------|
| Line buffer | 1 × H_ACTIVE × 24 bits = 7,680 bits at H_ACTIVE = 320 |
| Column counters (`wr_col`, `rd_col`) | 2 × `$clog2(H_ACTIVE+1)` = 2 × 9 bits at H_ACTIVE = 320 |
| Multipliers | 0 |

---

## 6. Control Logic and State Machines

Two states; both column counters reset to 0 and `state_q` resets to `S_RX`.

| State  | Meaning                                  | `s_axis_tready_o` | `m_axis_tvalid_o` |
|--------|------------------------------------------|-------------------|-------------------|
| `S_RX` | Absorbing input line into line buffer    | 1                 | 0                 |
| `S_TX` | Replaying line buffer in reverse to output | 0                 | 1                 |

| From    | Condition                                                  | To     | Side effects |
|---------|------------------------------------------------------------|--------|--------------|
| `S_RX`  | `tvalid && tready && enable_i && tlast`                    | `S_TX` | `wr_col ← 0` (`sof_pending` was set earlier on the SOF beat) |
| `S_TX`  | `tvalid && tready && (rd_col == H_ACTIVE − 1)`             | `S_RX` | `rd_col ← 0`, `sof_pending ← 0` |

`sof_pending` is set on whichever accepted RX beat carries `tuser=1` (the same beat that realigns `wr_col` to 0). It is propagated to `m_axis_tuser_o` only on the first TX beat of the resulting line, and cleared on the TX→RX transition.

---

## 7. Timing

| Metric                              | Value |
|-------------------------------------|-------|
| Latency (`enable_i = 1`)            | 1 active line (~`H_ACTIVE` `clk_dsp` cycles from first input beat to first output beat) |
| Latency (`enable_i = 0`)            | 0 cycles (combinational) |
| Long-term throughput                | 1 pixel / `clk_dsp` cycle (RX and TX alternate, each `H_ACTIVE` cycles) |
| Short-term throughput (`enable_i = 1`) | 1 pixel/cycle in TX bursts; 0 pixel/cycle during RX |

`s_axis_tready_o` is deasserted for the entire TX phase. Whatever upstream component feeds this module must be able to absorb that stall — for the project's `clk_pix` / `clk_dsp` ratio of 1:4 at `H_ACTIVE = 320`, that means absorbing up to 80 pix-clock pixels during one TX phase. The system-level CDC FIFO sizing that satisfies this is documented in [`sparevideo-top-arch.md`](sparevideo-top-arch.md) §5.2; it is out of scope here.

---

## 8. Shared Types

`sparevideo_pkg::H_ACTIVE` is the default for the `H_ACTIVE` parameter. The `tdata` encoding (`[23:16]` R, `[15:8]` G, `[7:0]` B) follows the project convention.

---

## 9. Known Limitations

- **Single line buffer — full-line upstream stall during TX.** A ping-pong buffer (two lines, overlapping RX and TX) would eliminate the stall but is not needed at the current clock ratio. A cheaper single-buffer alternative also exists: alternate the write direction (and therefore the read direction) per row, so reader and writer sweep the buffer in the same direction in lockstep, and the writer overwrites each slot the reader just emitted. This achieves continuous 1-pix/cycle throughput after a 1-line warmup with no second line buffer, at the cost of a row-parity bit, slightly trickier address generation, and tighter back-pressure coupling (downstream stall must back-pressure upstream so the writer cannot race ahead and clobber unread data). Not implemented today because the current clock ratio already absorbs the stall.
- **`enable_i` must be frame-stable.** `rx_accept` is gated by `enable_i`, so a 1→0 toggle freezes the FSM cleanly and 0→1 picks up on the next SOF; output pixels for a frame straddling the toggle are undefined.
- **Line buffer not zeroed on reset.** Contents are undefined until the first RX phase completes. The framing signals are derived from FSM counters and remain correct; only pixel data could be affected, and the first RX phase always completes before the first TX beat.
- **`V_ACTIVE` parameter is informational only.** It is provided for interface consistency with other filter modules; no internal logic depends on it.

---

## 10. References

- [`sparevideo-top-arch.md`](sparevideo-top-arch.md) — Top-level pipeline; placement of `axis_hflip` and CDC FIFO sizing.
- **ARM IHI0051A — AMBA AXI4-Stream Protocol Specification** — §2.2 (handshake), §2.7 (`tuser`/`tlast`).
