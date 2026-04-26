# `axis_hflip` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Block diagram](#51-block-diagram)
  - [5.2 Receive phase datapath](#52-receive-phase-datapath)
  - [5.3 Transmit phase datapath](#53-transmit-phase-datapath)
  - [5.4 `enable_i` bypass semantics](#54-enable_i-bypass-semantics)
  - [5.5 Resource cost summary](#55-resource-cost-summary)
- [6. Control Logic and State Machines](#6-control-logic-and-state-machines)
  - [6.1 FSM states and transitions](#61-fsm-states-and-transitions)
  - [6.2 SOF edge rule](#62-sof-edge-rule)
- [7. Timing](#7-timing)
  - [7.1 Latency and throughput](#71-latency-and-throughput)
  - [7.2 Backpressure and FIFO sizing](#72-backpressure-and-fifo-sizing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. Verification](#10-verification)
- [11. References](#11-references)

---

## 1. Purpose and Scope

`axis_hflip` implements a horizontal mirror ("selfie-cam" semantic) on a 24-bit RGB AXI4-Stream video stream. It is placed at the head of the `clk_dsp` processing pipeline, before the `ctrl_flow` mux, so that all downstream consumers — motion detection, CCL, bounding-box overlay, mask display — operate on the already-mirrored frame. Motion masks and bounding-box coordinates therefore agree with the user-visible frame without any coordinate translation downstream.

The module accepts one RGB pixel per cycle on its AXI4-Stream input, stores an entire active line in a single-ported line buffer, and replays the stored line in reverse order on its AXI4-Stream output. The net effect is a left-right flip of every row. Row order (top-to-bottom) is unchanged. The `tuser` (SOF) and `tlast` (EOL) framing signals are regenerated to match the mirrored output timing.

When `enable_i = 0`, the module is a zero-latency combinational passthrough: all five AXIS signals map directly from input to output and the line buffer is neither read nor written.

`axis_hflip` does not modify luma, chroma, alpha, or any per-pixel metadata beyond flipping column order. It does not perform any vertical operation, scaling, or color conversion.

For the role of this stage in the larger pipeline (placement relative to the input CDC FIFO, the motion-detect path, and the `ctrl_flow` mux), see [`sparevideo-top-arch.md`](sparevideo-top-arch.md).

---

## 2. Module Hierarchy

`axis_hflip` is a leaf module — no submodules. It is instantiated in `sparevideo_top` as `u_hflip`, between `u_fifo_in` (input CDC FIFO) and the `ctrl_flow` mux.

```
sparevideo_top
...
├── axis_async_fifo  (u_fifo_in)    — CDC clk_pix → clk_dsp
├── axis_hflip       (u_hflip)      — horizontal mirror; this module
├── [ctrl_flow mux]                 — passthrough / motion / mask / ccl_bbox
...
```

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter  | Default                        | Description |
|------------|-------------------------------|-------------|
| `H_ACTIVE` | `sparevideo_pkg::H_ACTIVE` = 320 | Active pixels per line. Sets the line buffer depth and the column counter range. |
| `V_ACTIVE` | 240                            | Active lines per frame. Informational only — not used internally. Provided for documentation consistency with other filter modules. |

### 3.2 Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| **Clock and reset** | | | |
| `clk_i` | input | 1 | DSP clock (`clk_dsp`), rising edge active |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| **Sideband** | | | |
| `enable_i` | input | 1 | When 1: horizontal mirror is active (FSM + line buffer in use). When 0: `s_axis_*` is forwarded directly to `m_axis_*` with zero latency. Must be held stable across an entire frame; toggling mid-frame is undefined. |
| **AXI4-Stream input (24-bit RGB)** | | | |
| `s_axis_tdata_i` | input | 24 | RGB pixel: `[23:16]` = R, `[15:8]` = G, `[7:0]` = B |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | AXI4-Stream ready. In `S_RECV` state: driven 1 (module accepts input). In `S_XMIT` state: driven 0 (module is replaying the line buffer; upstream must wait). When `enable_i=0`: combinatorially mirrors `m_axis_tready_i`. |
| `s_axis_tlast_i` | input | 1 | End-of-line (asserted on the last pixel of each active row) |
| `s_axis_tuser_i` | input | 1 | Start-of-frame (asserted on the first pixel of each active frame) |
| **AXI4-Stream output (24-bit RGB)** | | | |
| `m_axis_tdata_o` | output | 24 | Mirrored RGB pixel |
| `m_axis_tvalid_o` | output | 1 | AXI4-Stream valid. Asserted throughout `S_XMIT`; deasserted during `S_RECV`. When `enable_i=0`: mirrors `s_axis_tvalid_i`. |
| `m_axis_tready_i` | input | 1 | Downstream ready |
| `m_axis_tlast_o` | output | 1 | End-of-line, asserted when `rd_col == H_ACTIVE-1` (last reversed pixel). When `enable_i=0`: mirrors `s_axis_tlast_i`. |
| `m_axis_tuser_o` | output | 1 | Start-of-frame, asserted on the first output beat of the first line of each frame (`sof_pending && rd_col == 0`). When `enable_i=0`: mirrors `s_axis_tuser_i`. |

---

## 4. Concept Description

A horizontal mirror maps each pixel at column `c` of an `H_ACTIVE`-wide row to column `H_ACTIVE - 1 - c` in the output. Because pixels arrive in raster-scan order (left-to-right, top-to-bottom), it is impossible to produce column `H_ACTIVE - 1 - 0 = H_ACTIVE - 1` (the last input pixel of a row, which is the first output pixel of the mirrored row) until the entire input row has been received. This mandates buffering at least one complete line before any mirrored output can be produced.

The module operates in two alternating phases per input line:

- **Receive (RECV):** the module absorbs one complete input line into the line buffer, pixel by pixel, left to right. The downstream output is stalled during this phase.
- **Transmit (XMIT):** the module reads the stored line in reverse order (right to left) and presents each pixel to the output. The upstream input is stalled during this phase.

Because `pix_clk = 25 MHz` and `dsp_clk = 100 MHz`, and because each phase processes exactly `H_ACTIVE` pixel beats at 100 MHz (1 beat/cycle), the two phases each take 320 dsp-clock cycles = 80 pix-clock cycles. The long-term throughput is therefore 1 pixel/cycle at the DSP clock when averaged across both phases, which matches the input pixel rate.

When a RECV beat with `s_axis_tuser_i = 1` is accepted, `sof_pending` is set and `wr_col` is overridden to 0 (the pixel is written at column 0, and `wr_col` advances to 1 on the next beat). `sof_pending` is driven onto the output's `tuser` on the first beat of the subsequent XMIT phase (`rd_col == 0`), ensuring the SOF framing aligns with the mirrored pixel stream.

---

## 5. Internal Architecture

### 5.1 Block diagram

```
                      enable_i
                          |
   s_axis_*  ─────────────┼──────────────────────────────────►  m_axis_*
   (input)                │           (combinational bypass when enable_i=0)
                          |
              ┌───────────▼──────────────────────────┐
              │            axis_hflip                 │
              │                                       │
              │  s_axis_*                             │
              │  ─────►  ┌───────────┐               │
              │           │  S_RECV  │  (tready=1)   │
              │           │  wr_col  ├─────────────── │──► line_buf[wr_col] = tdata
              │           └────┬─────┘               │
              │      tlast &&  │  accepted beat       │
              │      valid     ▼                      │
              │           ┌───────────┐               │
              │           │  S_XMIT  │  (tvalid=1)   │
              │           │  rd_col  ├──────────────► │──► tdata = line_buf[H_ACTIVE-1-rd_col]
              │           └───────────┘               │
              │                                       │
              └───────────────────────────────────────┘
```

### 5.2 Receive phase datapath

During `S_RECV`:

- `s_axis_tready_o = 1`: the module accepts every valid input beat.
- On each accepted beat (`s_axis_tvalid_i && s_axis_tready_o`): write `line_buf[wr_col] <= s_axis_tdata_i` and increment `wr_col`.
- If `s_axis_tuser_i = 1` on an accepted beat: set `sof_pending <= 1`, override `wr_col` to 0 (the pixel is written at column 0; `wr_col` advances to 1 on the next cycle). This realigns the write pointer to the start of the buffer whenever a new frame begins.
- On the accepted beat with `s_axis_tlast_i = 1` (end-of-line): reset `wr_col` to 0 and transition to `S_XMIT`.
- `m_axis_tvalid_o = 0` during the entire RECV phase; the downstream sees no output.

### 5.3 Transmit phase datapath

During `S_XMIT`:

- `m_axis_tvalid_o = 1`: the module drives output every cycle.
- `m_axis_tdata_o = line_buf[H_ACTIVE - 1 - rd_col]`: reads the line buffer in reverse order.
- `m_axis_tuser_o = sof_pending && (rd_col == 0)`: SOF fires on the first output beat only, and only when the buffered line was the first line of a frame.
- `m_axis_tlast_o = (rd_col == H_ACTIVE - 1)`: EOL fires on the last output beat.
- On each accepted output beat (`m_axis_tvalid_o && m_axis_tready_i`): increment `rd_col`.
- When `rd_col` reaches `H_ACTIVE - 1` and the beat is accepted: clear `sof_pending`, reset `rd_col` to 0, and return to `S_RECV`.
- `s_axis_tready_o = 0` for the entire XMIT phase; the upstream is stalled.

### 5.4 `enable_i` bypass semantics

When `enable_i = 0`, all five output signals map combinationally from the corresponding inputs:

- `m_axis_tdata_o  = s_axis_tdata_i`
- `m_axis_tvalid_o = s_axis_tvalid_i`
- `m_axis_tlast_o  = s_axis_tlast_i`
- `m_axis_tuser_o  = s_axis_tuser_i`
- `s_axis_tready_o = m_axis_tready_i`

The line buffer and FSM registers retain whatever values they hold, but no reads or writes to the line buffer occur. The bypass is purely combinational: zero additional latency is added to the pipeline when `enable_i = 0`.

`enable_i` must be held stable across a complete frame. Toggling `enable_i` mid-frame is undefined behavior — the line buffer and FSM will be in an inconsistent state.

### 5.5 Resource cost summary

At `H_ACTIVE = 320`:

| Resource | Count |
|----------|-------|
| Line buffer memory | 1 x H_ACTIVE x 24 bits = 7,680 bits (960 bytes) |
| Write column counter FFs | `$clog2(H_ACTIVE)` = 9 bits |
| Read column counter FFs | 9 bits |
| `sof_pending` FF | 1 bit |
| FSM state FF | 1 bit (`S_RECV`=0, `S_XMIT`=1) |
| Output combinational logic | address inversion (`H_ACTIVE-1-rd_col`), EOL/SOF decode |
| Multipliers | 0 |

---

## 6. Control Logic and State Machines

### 6.1 FSM states and transitions

The module has two states. Both `wr_col` and `rd_col` are synchronous registers that reset to 0. The FSM register resets to `S_RECV`.

| State | Meaning | `s_axis_tready_o` | `m_axis_tvalid_o` |
|-------|---------|-------------------|-------------------|
| `S_RECV` | Absorbing input line into line buffer | 1 | 0 |
| `S_XMIT` | Replaying line buffer in reverse to output | 0 | 1 |

**Transitions:**

| From | Condition | To | Side effects |
|------|-----------|----|--------------|
| `S_RECV` | `s_axis_tvalid_i && s_axis_tready_o && s_axis_tlast_i` | `S_XMIT` | Reset `wr_col = 0` (note: `sof_pending` is set earlier, on whichever accepted beat had `s_axis_tuser_i = 1`) |
| `S_XMIT` | `m_axis_tvalid_o && m_axis_tready_i && (rd_col == H_ACTIVE-1)` | `S_RECV` | Clear `sof_pending = 0`; reset `rd_col = 0` |

In `S_RECV`, `wr_col` increments on every accepted beat (`s_axis_tvalid_i`). When `tlast` is asserted on the accepted beat, `wr_col` resets to 0 as part of the transition.

In `S_XMIT`, `rd_col` increments on every accepted output beat (`m_axis_tready_i`). When `rd_col == H_ACTIVE-1` and the beat is accepted, `rd_col` resets to 0 as part of the transition back to `S_RECV`.

### 6.2 SOF edge rule

Whenever an accepted `S_RECV` beat carries `s_axis_tuser_i = 1` (the first pixel of a new frame's first line), two things happen simultaneously: `sof_pending` is set to 1, and `wr_col` is overridden to 0 so the pixel is written at column 0. This handles both the normal case (SOF arrives on the first beat of a clean line) and the fault-recovery case (SOF arrives mid-line after an upstream reset) — in both cases the write pointer is realigned to the start of the buffer and the partially-written preceding line, if any, is discarded. `sof_pending` is forwarded to `m_axis_tuser_o` only on the first XMIT beat of the resulting line (`rd_col == 0`), and is cleared on the `S_XMIT → S_RECV` transition (`xmit_eol` accepted).

---

## 7. Timing

### 7.1 Latency and throughput

| Metric | Value |
|--------|-------|
| Latency (`enable_i=1`) | 1 active line (~`H_ACTIVE` dsp-clock cycles from first input beat to first output beat) |
| Latency (`enable_i=0`) | 0 cycles (combinational passthrough) |
| Throughput (`enable_i=1`) | 1 pixel/cycle burst during XMIT; 0 pixel/cycle during RECV. Long-term average: 1 pixel/cycle (RECV and XMIT alternate, each `H_ACTIVE` cycles). |
| Throughput (`enable_i=0`) | 1 pixel/cycle (limited by upstream/downstream) |

At `H_ACTIVE = 320` and `clk_dsp = 100 MHz`, the per-line latency is 3.2 µs. Each phase (RECV and XMIT) takes 320 dsp cycles = 80 pix-clock cycles.

### 7.2 Backpressure and FIFO sizing

During `S_XMIT`, `s_axis_tready_o` is deasserted for the entire transmit phase duration. The upstream source (the output of `u_fifo_in`, the input-side CDC FIFO) must not lose pixels during this window.

**FIFO depth calculation:**

- `pix_clk = 25 MHz`, `dsp_clk = 100 MHz` (4:1 ratio).
- One XMIT phase lasts `H_ACTIVE = 320` dsp cycles = 80 pix-clock cycles.
- During those 80 pix-clock cycles, the upstream pixel clock continues to push pixels into the CDC FIFO at up to 1 pixel/pix-clock-cycle.
- Maximum accumulation: 80 pixels.
- `IN_FIFO_DEPTH = 128` provides 60% headroom above the 80-pixel worst case (≥ 50% target).

**Risk B1 (lower):** The stall alternation pattern means the input CDC FIFO (`u_fifo_in`) must be deep enough to buffer one XMIT phase worth of pixels without overflowing. The `IN_FIFO_DEPTH = 128` choice satisfies this with margin. A ping-pong buffer variant (two line buffers, overlapping RECV and XMIT) would eliminate the upstream stall entirely, but the single-buffer design is sufficient for the target clock ratio and is simpler to verify. The ping-pong variant is available as a future optimization if the clock ratio changes or if FIFO headroom becomes constrained.

Cross-reference: `docs/plans/2026-04-23-pipeline-extensions-design.md` §3.1.

---

## 8. Shared Types

`sparevideo_pkg::H_ACTIVE` is used as the default for the `H_ACTIVE` parameter. No other package types are directly used inside `axis_hflip`. The `tdata` encoding (`[23:16]`=R, `[15:8]`=G, `[7:0]`=B) follows the project-wide convention defined in the package.

---

## 9. Known Limitations

- **Single line buffer — upstream stall during XMIT.** The input-side CDC FIFO must be at least `ceil(H_ACTIVE / clock_ratio)` entries deep to absorb the upstream pixels that arrive while `tready` is deasserted. At the default 4:1 ratio and `H_ACTIVE=320`, `IN_FIFO_DEPTH=128` satisfies this. If the clock ratio narrows or `H_ACTIVE` increases, the FIFO depth must be re-audited (see §7.2 Risk B1).
- **`enable_i` must be frame-stable.** Toggling `enable_i` mid-frame leaves `wr_col`, `rd_col`, `sof_pending`, and the FSM state in an inconsistent relationship with the pixel stream. The output for that frame is undefined.
- **No inter-frame state.** The FSM and column counters do not carry any state across frames beyond `sof_pending`. A hard reset (`rst_n_i = 0`) returns the module to `S_RECV` with `wr_col = 0`, `rd_col = 0`, `sof_pending = 0`.
- **Line buffer not zeroed on reset.** After reset, `line_buf` contents are undefined until the first RECV phase completes. During the first XMIT phase, the output presents whatever was last in the line buffer from reset time. This is correct behavior — the framing signals (`tvalid`, `tuser`, `tlast`) are derived from the FSM counters and will be correct; only the pixel data is affected, and the first RECV phase happens before any output is produced.
- **`V_ACTIVE` parameter is not used internally.** It is provided for documentation and interface consistency with other filter modules. No logic depends on it.

---

## 10. Verification

**Unit testbench `tb_axis_hflip`** (to be located at `hw/ip/hflip/tb/tb_axis_hflip.sv`):

| Test | Stimulus | Pass condition |
|------|----------|----------------|
| T1 — Gradient ramp exact-mirror | Drive a row with pixel values `0, 1, ..., H_ACTIVE-1`; `enable_i=1` | Output row is `H_ACTIVE-1, ..., 1, 0` (exact bit-for-bit reversal); SOF asserts on output beat (0,0) |
| T2 — Multi-frame continuity / SOF | Drive two distinct frames back-to-back; `enable_i=1` | Second frame's first XMIT pixel carries `tuser=1`; SOF asserts exactly once per frame; EOL asserts on the last beat of every output line |
| T3 — Downstream stall mid-XMIT | Assert `m_axis_tready_i=0` for several cycles in the middle of XMIT; `enable_i=1` | Output equals the no-stall mirrored reference; no pixel dropped or duplicated |
| T4 — In-row upstream tvalid bubble | Drop `s_axis_tvalid_i` for one cycle mid-RECV row; `enable_i=1` | Output equals the no-bubble mirrored reference; no pixel dropped or duplicated |
| T5 — `enable_i=0` passthrough | Drive a frame; `enable_i=0` | Output is bit-for-bit identical to input (no mirror, no latency); `s_axis_tready_o = m_axis_tready_i` at all times |

**Top-level integration regression matrix** (from `docs/plans/2026-04-23-pipeline-extensions-design.md` §5.4):

- All-off: `HFLIP=0 MORPH=0 GAMMA_COR=0 SCALER=0 HUD=0` x `passthrough` — verifies zero-latency bypass.
- All-on: `HFLIP=1 MORPH=1 GAMMA_COR=1 SCALER=1 HUD=1` x {`passthrough`, `motion`, `mask`, `ccl_bbox`} — verifies hflip composes correctly with all downstream control flows.
- `HFLIP` toggled singly from all-on x `motion` — isolates hflip contribution.
- FIFO-depth audit (deferred to the SCALER plan's `make fifo-audit` target — see `docs/plans/2026-04-23-pipeline-extensions-design.md` §5.5): will confirm `u_fifo_in` observed maximum depth stays below `IN_FIFO_DEPTH` with ≥ 25% headroom when `HFLIP=1`. Until then, the `IN_FIFO_DEPTH = 128` sizing in §7.2 stands as a static analysis bound.

---

## 11. References

- [`sparevideo-top-arch.md`](sparevideo-top-arch.md) — Top-level pipeline; shows where `axis_hflip` sits between `u_fifo_in` and the `ctrl_flow` mux.
- `docs/plans/2026-04-23-pipeline-extensions-design.md` §3.1 — Per-block design detail for `axis_hflip`, including Risk B1 (stall alternation / CDC FIFO sizing).
- **Gonzalez & Woods, *Digital Image Processing*, 3rd ed.** — §2.4 (image coordinate conventions), §3.3 (geometric spatial transformations). Horizontal flip is an affine transform with reflection matrix `diag(-1, 1)`.
- **ARM IHI0051A — AMBA AXI4-Stream Protocol Specification** — §2.2 (tready/tvalid handshake), §2.7 (tuser/tlast sideband). The RECV/XMIT alternation is legal: a slave may deassert `tready` for any number of cycles between accepted beats.
