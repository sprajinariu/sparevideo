# axis_scale2x 3-Buffer Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `axis_scale2x`'s 6-state phase-switching FSM (2 line buffers, ~5W cycles/row with a 2W-cycle bot-replay back-pressure burst) with a uniform counter-driven design (3 line buffers, 4W cycles/row, sustained ~25% input duty) so the control logic reduces to two independent counters plus a small buffer-rotation register.

**Architecture:** The current design serializes intake-then-replay across two phases (`S_TOP1/2` interleaved with input acceptance, then `S_BOT1/2` with input back-pressured for 2W cycles). Replace with a parallel design: **3 line buffers in cyclic rotation** (write target rotates each row), **single output beat counter** (`out_beat_q ∈ [0, 4W)`), **single input column counter** (`in_col_q ∈ [0, W)`). Top-row beats live at `out_beat_q ∈ [0, 2W)` and read only the anchor buffer; bot-row beats live at `[2W, 4W)` and read both anchor and prev. The "right-edge replicate," "S_TOP2 → S_TOP1 right-edge bounce," "ping-pong cur_sel," and "bot-replay phase" all dissolve into address arithmetic on `out_beat_q`. The cost is one extra `H_ACTIVE_IN × 24b` line buffer (`+50%` line-buffer storage) and a `4W`-cycle (1-input-row) startup latency from SOF to first output beat. See `docs/specs/axis_scale2x-arch.md` for the full background and the prior 2-buffer architecture being replaced.

**Tech Stack:**
- **RTL:** SystemVerilog (`hw/ip/scaler/rtl/axis_scale2x.sv`).
- **Verification:** Verilator (lint + unit TB at `hw/ip/scaler/tb/tb_axis_scale2x.sv`); top-level simulation TB (`dv/sv/tb_sparevideo.sv`); Python reference model (`py/models/ops/scale2x.py`) — **unchanged**, the model is spec-driven and the bit-exact output is identical.
- **Build:** `make lint`, `make test-ip-scale2x`, `make test-ip`, `make test-py`, `make run-pipeline`.

**Precondition (before Task 1):** this plan depends on `feat/axis-scale2x` (the kill-NN simplification, which removes the second `SCALE_FILTER` arm and cross-codebase NN references) being unmerged at plan-creation time. Per `CLAUDE.md`'s "one branch per plan" rule with the dependent-branch carve-out, create the new branch from the predecessor:

```bash
git checkout -B refactor/scale2x-3buf feat/axis-scale2x
```

The dependency on `feat/axis-scale2x` should be noted in the PR description (Task 5).

---

## File Structure

| File | Role | Change |
|---|---|---|
| `hw/ip/scaler/rtl/axis_scale2x.sv` | RTL — 3-buffer counter-based body | **Full rewrite** (~120 LOC; current is ~250) |
| `hw/ip/scaler/tb/tb_axis_scale2x.sv` | Unit TB | **Tweak** — extend the post-stimulus settle window for the 1-row startup latency; goldens are unchanged |
| `docs/specs/axis_scale2x-arch.md` | Arch spec | **Rewrite §5 + §7** — new data-flow diagram, new FSM/counter section, new resource-cost table; §1–§4 (purpose, interface, concept) unchanged |
| `py/models/ops/scale2x.py` | Reference model | **No change** — bit-exact output is identical |
| `py/tests/test_scale2x.py` | Model tests | **No change** |
| `hw/top/sparevideo_top.sv` | Top-level instantiation | **No change** — same module interface |
| `hw/top/sparevideo_pkg.sv` | Profile struct | **No change** |
| `dv/sv/tb_sparevideo.sv` | Top-level TB | **No change** |
| `Makefile`, `dv/sim/Makefile` | Build glue | **No change** |
| `README.md`, `CLAUDE.md` | Top-level docs | **No change** — public-facing description still "2x bilinear spatial upscaler" |

---

## Architectural Reference (for the implementer)

### Counters and registers

| Signal | Width | Role |
|---|---|---|
| `wr_sel_q` | 2 b | Index in `{0, 1, 2}` of the buffer being **written** for the current input row. Anchor buffer = `(wr_sel_q − 1) mod 3`. Prev buffer = `(wr_sel_q − 2) mod 3` ≡ `(wr_sel_q + 1) mod 3`. Advances by 1 (mod 3) at each input-row + emit-pair boundary. |
| `in_col_q` | `$clog2(W+1)` b | Source column where the **next** accepted input pixel lands. Resets to 0 on input `tlast`. |
| `out_beat_q` | `$clog2(4W+1)` b | Output beat counter, 0..4W−1. Top phase: 0..2W−1. Bot phase: 2W..4W−1. End-of-row tlast bits at out_beat == 2W−1 and 4W−1. |
| `in_done_q` | 1 b | "Current input row is fully written; waiting for emit to also finish so we can rotate." |
| `emit_armed_q` | 1 b | "Currently emitting a pair (m_axis.tvalid pulled from this)." |
| `first_pair_q` | 1 b | "We're in the first pair of a frame — top-edge replicate semantics: also write each input pixel into the prev buffer." |
| `sof_pending_q` | 1 b | Latched on accepted `s_axis.tuser`; cleared on emitted `m_axis.tuser`. |

### Buffer rotation

```
Row index r → wr_sel_q value (mod 3) for the FIRST frame after reset:
  r=0 → 0       (writes go to buf0; first_pair_q=1 also writes to buf2 = anchor_sel)
  r=1 → 1       (anchor = buf0 = row 0; prev = buf2 = row 0 from first-pair seed)
  r=2 → 2       (anchor = buf1 = row 1; prev = buf0 = row 0)
  r=3 → 0       (anchor = buf2 = row 2; prev = buf1 = row 1)  -- buf0 row 0 obsolete
  r=4 → 1       (anchor = buf0 = row 3; prev = buf2 = row 2)  -- buf1 row 1 obsolete
  …
```

`anchor_sel` and `prev_sel` are combinational (3-way case from `wr_sel_q`).

**Why the seed goes to `anchor_sel`, not `prev_sel`.** Seeded buffer must equal `prev_sel` *during pair 0's emit*. Pair 0 emit happens during row 1's intake, when `wr_sel_q` has advanced by 1. So pair 0's `prev_sel = (wr_sel_q@row1 − 2) mod 3 = (wr_sel_q@row0 − 1) mod 3 = anchor_sel@row0`. Writing the seed to `anchor_sel` during row 0 intake therefore lands it exactly where pair 0's `prev_sel` will read it. (`anchor_sel` is unused during row 0 intake — there's no anchor read because `emit_armed_q = 0` during the latency phase, so the seed write is free to use it.)

**Frame boundaries: don't reset `wr_sel_q`.** The rotation is invariant under starting offset — for any starting `wr_sel_q = X`, the seed-to-anchor-sel rule keeps the post-rotation `prev_sel` aligned for pair 0's read. So at the start of a new frame the only thing that needs rearming is `first_pair_q ← 1` (and we re-establish `sof_pending_q`). `wr_sel_q` continues rotating naturally from wherever the previous frame left it (typically `V_ACTIVE_IN mod 3`).

**SOF stall (defensive).** The previous frame's last pair (pair V−1) emits during the input V_BLANK window (4W DSP cycles fit comfortably within V_BLANK at sparevideo's resolutions, see §7a of the arch doc). To rule out a malformed-upstream race in which a new frame's SOF would arrive during pair V−1's emit and the seed-write would clobber the buffer being read, the input handshake stalls SOF acceptance while `emit_armed_q` is high:

```
s_axis.tready = !in_done_q && !(s_axis.tvalid && s_axis.tuser && emit_armed_q)
```

This is a no-op under nominal operation (V_BLANK >> 4W) but makes the module robust to back-to-back frame boundaries.

### Output formula by `out_beat_q`

```
phase_col   = in_bot_phase ? (out_beat_q - 2W) : out_beat_q   -- 0..2W-1
src_c       = phase_col >> 1
src_cp1     = (src_c == W-1) ? src_c : src_c + 1               -- right-edge clamp
beat_is_odd = out_beat_q[0]

if !in_bot_phase:                                               -- top row
    tdata = beat_is_odd ? avg2(anchor_c, anchor_cp1) : anchor_c
else:                                                           -- bot row
    tdata = beat_is_odd ? avg2(avg2(anchor_c, anchor_cp1),
                                 avg2(prev_c,   prev_cp1))
                        : avg2(anchor_c, prev_c)
```

### Handshake

```
s_axis.tready = !in_done_q && !(s_axis.tvalid && s_axis.tuser && emit_armed_q)
m_axis.tvalid = emit_armed_q
m_axis.tlast  = emit_armed_q && (out_beat_q == 2W-1 || out_beat_q == 4W-1)
m_axis.tuser  = emit_armed_q && sof_pending_q && out_beat_q == 0
```

### Boundary synchronization (the only "FSM" left)

```
on accepted SOF input (s_axis.tuser):
    first_pair_q  <= 1     -- top-edge replicate seed for new frame
    sof_pending_q <= 1     -- output tuser flag

on input tlast:
    in_col_q  <= 0
    in_done_q <= 1

on emitted last beat of pair (out_beat_q == 4W-1):
    out_beat_q   <= 0
    emit_armed_q <= 0       -- pause emit until next row available

on (in_done_q && !emit_armed_q):
    -- Both processes idle: rotate buffer roles and start emitting next pair.
    wr_sel_q     <= (wr_sel_q + 1) mod 3
    in_done_q    <= 0
    emit_armed_q <= 1
    first_pair_q <= 0       -- after first transition, no more replicate seeding
```

`wr_sel_q` is **not** reset at SOF — the rotation is invariant under starting offset (see plan §"Buffer rotation"). This drops one source of mid-stream state surgery present in the current arch's `effective_cur_sel` override.

### Why the rotation works without read/write conflict

During row `r`'s intake, `write_buf = wr_sel_q`'s buffer. The bot-row reads (cycles `2W..4W−1`) read `anchor_buf` and `prev_buf`, which are different buffers from `write_buf`. So writes and reads never touch the same cell — no timing constraint between them, unlike the 2-buffer "bot-first" alternative we considered earlier.

### What goes away vs. the current design

| Current arch | 3-buffer arch |
|---|---|
| 6 states (`S_RX_FIRST`, `S_RX_NEXT`, `S_TOP1/2`, `S_BOT1/2`) | No FSM states; two counters + 5 boolean flags |
| Peek window (`cur_q`, `next_q`, `cur_is_last_q`, `next_is_last_q`) | Gone — read directly from buffers via `out_beat_q` |
| `S_TOP2 → S_TOP1` right-edge replicate path | Gone — collapses to `src_cp1 = min(src_c+1, W-1)` clamp |
| `cur_sel_q` 1-bit ping-pong | Replaced by 2-bit `wr_sel_q` cycling mod 3 |
| `effective_first_row` / `effective_cur_sel` SOF same-cycle override | Gone — write/read use disjoint buffers; `first_pair_q` is sufficient |
| 2W-cycle bot-replay back-pressure burst per row | Gone — `tready` is high through the row's full 4W cycles, deasserting only briefly between rows |

---

## Task 1: Update arch spec

Spec-first. Write the new architecture into `docs/specs/axis_scale2x-arch.md` so the implementer (and reviewers) can refer to a single source of truth while writing the RTL.

**Files:**
- Modify: `docs/specs/axis_scale2x-arch.md`

- [ ] **Step 1: Replace §5.1 data-flow diagram and intro**

The current §5.1 shows a 2-buffer ping-pong with a peek window. Replace with the 3-buffer rotation. Open the file and replace §5.1 (`### 5.1 Data flow overview`) up to (but not including) `### 5.2`, with:

````markdown
### 5.1 Data flow overview

```
            ┌─────────────────────────────────────────────────────────────┐
            │                       axis_scale2x                          │
            │                                                             │
            │   ┌──────────────┐                                          │
            │   │ buffer       │   wr_sel_q (mod 3)                       │
            │   │ rotation:    │   advances 1 per input-row + emit-pair   │
            │   │  buf0/1/2    │   boundary                               │
            │   └──────────────┘                                          │
            │                                                             │
   s_axis ──┼──► write_buf[in_col_q] = s_axis.tdata                       │
            │      where write_sel = wr_sel_q                             │
            │      (also anchor_buf[in_col_q] when first_pair_q,          │
            │       seeding top-edge replicate for the first frame —      │
            │       lands where pair 0's prev_sel will look after the     │
            │       next rotation)                                        │
            │                                                             │
            │      anchor_sel = (wr_sel_q − 1) mod 3   holds row r-1      │
            │      prev_sel   = (wr_sel_q − 2) mod 3   holds row r-2      │
            │                                                             │
            │   ┌──────────────────────┐                                  │
            │   │ output beat counter  │ out_beat_q ∈ [0, 4W)             │
            │   │ ─ top phase: 0..2W−1 │   reads anchor_buf only          │
            │   │ ─ bot phase: 2W..4W  │   reads anchor_buf + prev_buf    │
            │   └────────┬─────────────┘                                  │
            │            ▼                                                │
            │   ┌──────────────────────┐                                  │
            │   │ beat formatter       │ ─► m_axis                        │
            │   │  even col: anchor_c  │   raster-scan output             │
            │   │            or bot_e  │                                  │
            │   │  odd  col: avg2 ↑    │                                  │
            │   │            or bot_o  │                                  │
            │   └──────────────────────┘                                  │
            └─────────────────────────────────────────────────────────────┘
```

The input writer and output emitter run as **two independent processes**: the writer fills `write_buf` at the input rate (1 col / 4 DSP cycles under nominal `clk_dsp = 4 × clk_pix_in` rate balance); the emitter drains 4W output beats over 4W DSP cycles. Their disjoint buffer-role assignments (write/anchor/prev are always three different buffers) mean writes and reads never alias — there is no bot-replay phase, no ping-pong sel toggle, and no peek window. The rotation register `wr_sel_q` advances by 1 (mod 3) at each row+pair boundary so the buffer that just received row `r` becomes the new anchor and the buffer that held row `r−2` becomes the next write target.

````

- [ ] **Step 2: Replace §5.2 (FSM/counters)**

Replace the entire §5.2 (everything from `### 5.2 FSM and counters` to just before `### 5.3`) with:

````markdown
### 5.2 Counters, registers, and rotation

There is no traditional FSM — only two independent counters and a small set of boolean flags.

| Signal | Width | Role |
|---|---|---|
| `wr_sel_q` | 2 b | Index of the buffer being **written** for the current input row, in `{0, 1, 2}`. Advances by 1 mod 3 at each row+pair boundary. Reset to 0 on accepted SOF input. |
| `in_col_q` | `$clog2(W+1)` | Source column where the next accepted input pixel lands. Resets to 0 on input `tlast`. |
| `out_beat_q` | `$clog2(4W+1)` | Output beat counter, 0..4W−1. Wraps to 0 when `(4W−1)`-th beat retires. |
| `in_done_q` | 1 b | Asserted between input `tlast` accept and the next rotation. While high, `s_axis.tready = 0`. |
| `emit_armed_q` | 1 b | Asserted while emitting a pair. Pulled into `m_axis.tvalid` directly. Deasserts on the cycle after the `(4W−1)`-th beat retires; re-asserts on the next rotation. |
| `first_pair_q` | 1 b | Asserted while emitting pair 0 of a frame. Causes the input writer to *also* write each accepted pixel into `prev_buf` (top-edge replicate seed). Cleared at the first row+pair boundary of the frame. |
| `sof_pending_q` | 1 b | Latched on accepted `s_axis.tuser`; cleared on emitted `m_axis.tuser`. |

Combinational role assignments:

```
case (wr_sel_q)
    2'd0: { anchor_sel, prev_sel } = { 2'd2, 2'd1 }
    2'd1: { anchor_sel, prev_sel } = { 2'd0, 2'd2 }
    2'd2: { anchor_sel, prev_sel } = { 2'd1, 2'd0 }
endcase
```

Beat-to-address combinational decode:

```
in_bot_phase = (out_beat_q >= 2W)
phase_col    = in_bot_phase ? (out_beat_q − 2W) : out_beat_q     // 0..2W-1
src_c        = phase_col >> 1                                     // 0..W-1
src_cp1      = (src_c == W − 1) ? src_c : src_c + 1               // right-edge clamp
beat_is_odd  = out_beat_q[0]
```

Two boundary events drive all state changes:

- **Input row complete** (`s_axis.tvalid && s_axis.tready && s_axis.tlast`): `in_col_q ← 0`, `in_done_q ← 1`.
- **Output pair complete** (`m_axis.tvalid && m_axis.tready && (out_beat_q == 4W−1)`): `out_beat_q ← 0`, `emit_armed_q ← 0`.

When both have fired (`in_done_q && !emit_armed_q`), the rotation triggers in the same cycle:

```
wr_sel_q     ← (wr_sel_q == 2) ? 0 : (wr_sel_q + 1)
in_done_q    ← 0
emit_armed_q ← 1
first_pair_q ← 0
```

A new frame (accepted `s_axis.tuser`) re-arms `first_pair_q ← 1`. `wr_sel_q` is **not** reset — the rotation is invariant under starting offset, and seeding to `anchor_sel` (rather than to a fixed buffer index) keeps pair 0's `prev_sel` aligned with the seed regardless of where the rotation cycle is.

#### Per-row timing

Under nominal rate balance (`clk_dsp = 4 × clk_pix_in`), the writer's W input cycles and the emitter's 4W DSP cycles complete at the same instant — both events fire on the same boundary cycle and the rotation is seamless. If the upstream FIFO holds up the input, the emitter idles after its last beat (`emit_armed_q = 0`) until the input row finishes. If the downstream stalls the output, the writer idles after its last input (`in_done_q = 1`, `s_axis.tready = 0`) until the emitter catches up. Either way, the rotation waits for both.
````

- [ ] **Step 3: Replace §5.3 (formatter) and §5.4 (write policy)**

Replace `### 5.3` through the end of `### 5.4` with:

````markdown
### 5.3 Output beat formatter

```
                       beat_is_odd = 0          beat_is_odd = 1
                       (even out col)           (odd out col)
top phase:             anchor_c                  avg2(anchor_c, anchor_cp1)
(out_beat in [0, 2W))

bot phase:             avg2(anchor_c, prev_c)    avg2( avg2(anchor_c, anchor_cp1),
(out_beat in [2W, 4W))                                avg2(prev_c,   prev_cp1)   )
```

`avg2(a, b)` is the per-channel 2-tap round-half-up average `((a + b + 1) >> 1)`. `avg2(a, a) = a` exactly. The bot-odd 4-tap is the sequential-2-tap form (avg2 of two avg2s), differing from a true 4-tap by at most ±1 LSB and matching `py/models/ops/scale2x.py` bit-exactly.

`m_axis.tlast` asserts at the last beat of each output row: `out_beat_q == 2W − 1` (end of top row) or `out_beat_q == 4W − 1` (end of bot row, end of pair).

`m_axis.tuser` asserts at the first beat of the first pair of a frame: `sof_pending_q && out_beat_q == 0`.

### 5.4 Backpressure and buffer-write policy

**Backpressure.**

```
s_axis.tready = !in_done_q && !(s_axis.tvalid && s_axis.tuser && emit_armed_q)
m_axis.tvalid = emit_armed_q
```

Within a row, `s_axis.tready` stays high (input arrives at ~25% duty under the 1:4 clock ratio). It deasserts only between input `tlast` and the next rotation — typically zero cycles when the writer and emitter complete simultaneously, and a small number of cycles only if the upstream is faster than nominal rate balance. The second term defensively stalls SOF acceptance while a previous-frame pair is still emitting (so the seed write doesn't clobber the buffer being read); under nominal V_BLANK timing this is a no-op.

**Buffer writes.** A pixel accepted while `s_axis.tready = 1` is always written to `write_buf[in_col_q]` (the buffer indexed by `wr_sel_q`). When `first_pair_q = 1` (or the SOF same-cycle override `effective_first_pair`), the same pixel is *also* written to `anchor_buf[in_col_q]` (the buffer indexed by `anchor_sel`). The seed lands where pair 0's `prev_sel` will read it after the next rotation, so pair 0's bot row reads `prev == anchor` (top-edge replicate). Note: `anchor_buf` is unused for *reads* during row 0 intake (no emit happens — `emit_armed_q = 0` during the latency phase), so the seed write to `anchor_sel` doesn't conflict with anything.

**Frame entry.** Accepted `s_axis.tuser` re-arms `first_pair_q ← 1`. `wr_sel_q` continues rotating from wherever the previous frame left it; the seed-to-`anchor_sel` rule keeps the rotation invariant under starting offset.
````

- [ ] **Step 4: Replace §5.5 (resource cost)**

Replace `### 5.5 Resource cost summary` (until the next `---` or `## 6`) with:

````markdown
### 5.5 Resource cost summary

Quantities at `H_ACTIVE_IN = 320`. Per-channel adders are 9-bit; counts are pre-synthesis-sharing.

| Resource | Count |
|---|---|
| Line buffers (`buf0`, `buf1`, `buf2`) | 3 × 320 × 24 b = 23,040 b. **+50% vs. the prior 2-buffer design**, in exchange for the FSM simplification and elimination of the bot-replay back-pressure burst. |
| Counters | `in_col_q` + `wr_sel_q` (`$clog2(321) + 2 = 11` b) + `out_beat_q` (`$clog2(1281) = 11` b) = 22 b. |
| Sideband regs | `in_done_q`, `emit_armed_q`, `first_pair_q`, `sof_pending_q` = 4 b. |
| `avg2` instances per channel | 5 — one in each of `anchor_top_odd`, `prev_top_odd`, `bot_even`, `bot_odd`-inner-1, `bot_odd`-inner-2. The first two collapse to `avg2(anchor_c, anchor_cp1)` and `avg2(prev_c, prev_cp1)` reused between top-phase and bot-phase formulas. 15 9-bit adders total across R/G/B before any synthesis sharing. |
| Multipliers / DSPs | 0. |

Compared with the prior 2-buffer arch: +1 line buffer, −1 peek-window register pair (`cur_q`, `next_q`), −2 last-flag registers (`cur_is_last_q`, `next_is_last_q`), and the FSM state register collapses from 3 b (6 states) to 2 b (`wr_sel_q`).
````

- [ ] **Step 5: Replace §7 (Timing)**

Replace the entire `## 7. Timing` section (until `## 7a. Clock Assumptions`) with:

````markdown
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

Compared with the prior 2-buffer design: the 2W-cycle per-row bot-replay back-pressure burst is gone. `s_axis.tready` instead follows a sustained ~25% duty cycle (1 accept per 4 DSP cycles) throughout each row, with brief deassertion only at row boundaries when the writer and emitter desync. Top-level output FIFO sizing can therefore be relaxed from the prior burst-absorbing `OUT_FIFO_DEPTH = 1024` if desired (not in scope for this plan; the existing depth remains correct, just with extra slack).
````

- [ ] **Step 5b: Update §7a (Clock Assumptions)**

The "Per-frame startup" bullet of `## 7a. Clock Assumptions` references the eliminated 2W bot-replay back-pressure. Replace that bullet (only — leave the other §7a bullets untouched) with:

````markdown
- **Per-frame startup.** The module's first-output latency is `4W` `clk_dsp` cycles after an accepted SOF — one full input row at the 1:4 input/DSP rate, needed because pair 0's bot row reads row 0 from a fully-buffered anchor (and the seeded prev). After this 1-row primer, the module runs at uniform sustained throughput: each source row produces 4W output beats over 4W DSP cycles with no per-row back-pressure burst (the prior 2-buffer arch's bot-replay phase is eliminated). Downstream `V_BLANK` slack absorbs the per-frame primer; with sparevideo's `V_BACK_PORCH_OUT_2X` etc. (output blanking doubled with the scaler enabled) there is far more than 4W cycles of headroom.
````

- [ ] **Step 5c: Replace §6 (Control Logic)**

Replace the entire `## 6. Control Logic` section (everything from `## 6. Control Logic` through to but not including `## 7. Timing`) with:

````markdown
## 6. Control Logic

§5.2 covers the entire control surface — there is no separate FSM. The relevant boundary behaviours are:

- **Reset (`rst_n_i = 0`).** `wr_sel_q ← 0`; counters cleared (`in_col_q`, `out_beat_q`); `in_done_q ← 0`; `emit_armed_q ← 0`; `first_pair_q ← 1`; `sof_pending_q ← 0`. Line-buffer contents are undefined; they are not consumed before the first source row's `tlast` is seen.
- **Frame entry.** An accepted input beat with `tuser = 1` re-arms `first_pair_q ← 1` (so the same-cycle `effective_first_pair` triggers the top-edge-replicate seed write into `anchor_buf`) and latches `sof_pending_q ← 1`. `wr_sel_q` continues rotating from wherever the previous frame left it — the rotation is invariant under starting offset (see §5.4).
- **End of source row.** Accepted `s_axis.tlast` resets `in_col_q ← 0` and asserts `in_done_q ← 1`. `s_axis.tready` deasserts so no further input is accepted until the rotation fires.
- **End of pair emit.** The retiring `out_beat_q == 4W − 1` beat resets `out_beat_q ← 0` and clears `emit_armed_q ← 0`.
- **Boundary rotation.** When both `in_done_q == 1` and `emit_armed_q == 0` are true on the same cycle, `wr_sel_q` advances by 1 (mod 3), `in_done_q` clears, `emit_armed_q` re-asserts (next pair begins emitting), and `first_pair_q` clears (after the first pair's seed has been written).
````

- [ ] **Step 6: Update §9 (Known Limitations)**

Replace the `### 9. Known Limitations` section (everything between `## 9. Known Limitations` and `## 10. References`) with:

````markdown
- **`H_ACTIVE_IN` must be even.** The horizontal output width is `2·H_ACTIVE_IN`; the right-edge-replication clamp assumes the input width is exact. Odd widths are not supported.
- **Right-edge replication is the only horizontal edge policy.** No reflect, no zero-pad. The penultimate horizontal interpolant past the last column duplicates the last sample.
- **Top-edge replication is the only vertical edge policy for `r = 0`.** The first input row's bottom output row equals its top output row.
- **2× only.** No support for non-2× factors (1.5×, 3×, …). A future general scaler would replace this module rather than parameterise it.
- **One-input-row latency from SOF to first output beat.** This is structural to the uniform 3-buffer schedule (pair 0's bot needs row 0 fully buffered before it can read it). For the project's video resolutions this is sub-millisecond and irrelevant; for ultra-low-latency applications a different upscaler would be needed.
- **`H_ACTIVE_IN`-deep × 24-bit × 3 line buffers** are instantiated regardless of the input row's actual width. Rows are assumed to always be exactly `H_ACTIVE_IN` wide (matches top-level usage); shorter rows are not supported.
````

- [ ] **Step 7: Verify the doc renders cleanly**

Run a quick sanity check on the markdown structure:

```bash
grep -n '^##\|^###' docs/specs/axis_scale2x-arch.md
```

Expected: §§1–10 present with §5.1–§5.5 subsections matching the new content. No orphaned subsection numbers.

- [ ] **Step 8: Commit the spec update**

```bash
git add docs/specs/axis_scale2x-arch.md
git commit -m "docs(scale2x): rewrite arch spec for 3-buffer uniform design"
```

---

## Task 2: Rewrite the RTL

Replace the FSM-driven body with the counter-driven 3-buffer body. The module's port list and parameters are unchanged, so callers (`hw/top/sparevideo_top.sv`) need no edits.

**Files:**
- Modify: `hw/ip/scaler/rtl/axis_scale2x.sv`

- [ ] **Step 1: Read the existing RTL for reference**

```bash
cat hw/ip/scaler/rtl/axis_scale2x.sv | wc -l
```

Expected: ~250 lines. Familiarise yourself with the current `avg2` function (line ~75) and port declarations — both carry over verbatim.

- [ ] **Step 2: Replace the entire RTL file with the 3-buffer body**

Overwrite `hw/ip/scaler/rtl/axis_scale2x.sv` with exactly this content:

```sv
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_scale2x -- 2x bilinear spatial upscaler on a 24-bit RGB AXIS.
//
// Three line buffers in cyclic rotation give "write target" / "anchor" /
// "prev" disjoint at all times, so the input writer and the output emitter
// run as two independent processes with no read/write aliasing.
//
// Per-row schedule (steady state, after row 0):
//   - Input writer: writes one pixel per 4 DSP cycles (under clk_dsp = 4 *
//     clk_pix_in rate balance) into write_buf at column in_col_q.
//   - Output emitter: emits one beat per DSP cycle for 4W cycles, reading
//     anchor_buf during the top phase (out_beat_q in [0, 2W)) and reading
//     anchor_buf + prev_buf during the bot phase ([2W, 4W)).
//   - At input tlast + emit-pair-done, wr_sel_q advances mod 3.
//
// Frame entry: accepted s_axis.tuser re-arms first_pair_q (top-edge
// replicate seed -- writes go to BOTH write_buf AND anchor_buf for the
// first pair of a frame; the seed lands where pair 0's prev_sel will read
// it after the next rotation). wr_sel_q is NOT reset on SOF -- the rotation
// is invariant under starting offset.
//
// Latency: 4W clk_dsp cycles from accepted SOF to first m_axis beat (one
// full input row of 1:4-paced intake before pair 0's bot can read row 0).
// Steady-state output rate: 1.0 beats/cycle sustained, no per-row burst.

module axis_scale2x #(
    parameter int H_ACTIVE_IN = sparevideo_pkg::H_ACTIVE,
    parameter int V_ACTIVE_IN = sparevideo_pkg::V_ACTIVE   // informational
) (
    input  logic clk_i,
    input  logic rst_n_i,
    axis_if.rx   s_axis,                                    // DATA_W=24, USER_W=1
    axis_if.tx   m_axis                                     // DATA_W=24, USER_W=1
);

    localparam int COL_W     = $clog2(H_ACTIVE_IN + 1);
    localparam int OUT_COL_W = $clog2(2*H_ACTIVE_IN + 1);
    localparam int BEAT_W    = $clog2(4*H_ACTIVE_IN + 1);

    // ---- Three line buffers ----
    logic [23:0] buf0 [H_ACTIVE_IN];
    logic [23:0] buf1 [H_ACTIVE_IN];
    logic [23:0] buf2 [H_ACTIVE_IN];

    // ---- Buffer rotation ----
    logic [1:0] wr_sel_q;
    logic [1:0] anchor_sel, prev_sel;
    always_comb begin
        unique case (wr_sel_q)
            2'd0:    begin anchor_sel = 2'd2; prev_sel = 2'd1; end
            2'd1:    begin anchor_sel = 2'd0; prev_sel = 2'd2; end
            default: begin anchor_sel = 2'd1; prev_sel = 2'd0; end
        endcase
    end

    // ---- Counters and flags ----
    logic [COL_W-1:0]  in_col_q;
    logic [BEAT_W-1:0] out_beat_q;
    logic              in_done_q;
    logic              emit_armed_q;
    logic              first_pair_q;
    logic              sof_pending_q;

    // ---- Per-channel 2-tap round-half-up average. avg2(a, a) = a. ----
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [23:0] avg2(input logic [23:0] a,
                                         input logic [23:0] b);
        logic [8:0] r_sum, g_sum, b_sum;
        begin
            r_sum = {1'b0, a[23:16]} + {1'b0, b[23:16]} + 9'd1;
            g_sum = {1'b0, a[15:8]}  + {1'b0, b[15:8]}  + 9'd1;
            b_sum = {1'b0, a[7:0]}   + {1'b0, b[7:0]}   + 9'd1;
            avg2  = {r_sum[8:1], g_sum[8:1], b_sum[8:1]};
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- Beat -> address decode ----
    logic                  in_bot_phase;
    logic [OUT_COL_W-1:0]  phase_col;
    logic [COL_W-1:0]      src_c, src_cp1;
    logic                  beat_is_odd;

    assign in_bot_phase = (out_beat_q >= BEAT_W'(2*H_ACTIVE_IN));
    assign phase_col    = in_bot_phase
                            ? OUT_COL_W'(out_beat_q - BEAT_W'(2*H_ACTIVE_IN))
                            : OUT_COL_W'(out_beat_q);
    assign src_c        = phase_col[OUT_COL_W-1:1];
    assign src_cp1      = (src_c == COL_W'(H_ACTIVE_IN - 1))
                            ? src_c
                            : COL_W'(src_c + COL_W'(1));
    assign beat_is_odd  = out_beat_q[0];

    // ---- Buffer reads (combinational, two reads per buffer) ----
    logic [23:0] anchor_c, anchor_cp1, prev_c, prev_cp1;
    always_comb begin
        unique case (anchor_sel)
            2'd0:    begin anchor_c = buf0[src_c]; anchor_cp1 = buf0[src_cp1]; end
            2'd1:    begin anchor_c = buf1[src_c]; anchor_cp1 = buf1[src_cp1]; end
            default: begin anchor_c = buf2[src_c]; anchor_cp1 = buf2[src_cp1]; end
        endcase
        unique case (prev_sel)
            2'd0:    begin prev_c = buf0[src_c]; prev_cp1 = buf0[src_cp1]; end
            2'd1:    begin prev_c = buf1[src_c]; prev_cp1 = buf1[src_cp1]; end
            default: begin prev_c = buf2[src_c]; prev_cp1 = buf2[src_cp1]; end
        endcase
    end

    // ---- Output beat formatter ----
    logic [23:0] tx_data;
    always_comb begin
        if (!in_bot_phase) begin
            tx_data = beat_is_odd ? avg2(anchor_c, anchor_cp1) : anchor_c;
        end else begin
            tx_data = beat_is_odd
                        ? avg2(avg2(anchor_c, anchor_cp1),
                               avg2(prev_c,   prev_cp1))
                        : avg2(anchor_c, prev_c);
        end
    end

    // ---- SOF same-cycle override ----
    // first_pair_q rearms at the SOF tail of always_ff (NBA), but the
    // seed write needs the post-SOF value in the SAME cycle as the SOF
    // accept. effective_first_pair makes the buffer-write code see
    // first_pair_q=1 on the SOF cycle of every new frame.
    logic do_accept, do_emit;
    logic is_sof_pixel;
    logic effective_first_pair;

    assign do_accept           = s_axis.tvalid && s_axis.tready;
    assign do_emit             = m_axis.tvalid && m_axis.tready;
    assign is_sof_pixel        = do_accept && s_axis.tuser;
    assign effective_first_pair = first_pair_q || is_sof_pixel;

    // ---- AXIS port drives ----
    // tready stalls a SOF input while emit is still in progress (defensive
    // against malformed back-to-back frames; see plan §"SOF stall"). Under
    // nominal V_BLANK it is a no-op.
    assign s_axis.tready = !in_done_q && !(s_axis.tvalid && s_axis.tuser && emit_armed_q);
    assign m_axis.tdata  = tx_data;
    assign m_axis.tvalid = emit_armed_q;
    assign m_axis.tlast  = emit_armed_q && ((out_beat_q == BEAT_W'(2*H_ACTIVE_IN - 1)) ||
                                            (out_beat_q == BEAT_W'(4*H_ACTIVE_IN - 1)));
    assign m_axis.tuser  = emit_armed_q && sof_pending_q && (out_beat_q == '0);

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            wr_sel_q       <= 2'd0;
            in_col_q       <= '0;
            out_beat_q     <= '0;
            in_done_q      <= 1'b0;
            emit_armed_q   <= 1'b0;
            first_pair_q   <= 1'b1;
            sof_pending_q  <= 1'b0;
        end else begin
            // ---- Input writer ----
            if (do_accept) begin
                // Write to write_buf
                unique case (wr_sel_q)
                    2'd0:    buf0[in_col_q] <= s_axis.tdata;
                    2'd1:    buf1[in_col_q] <= s_axis.tdata;
                    default: buf2[in_col_q] <= s_axis.tdata;
                endcase
                // First-pair top-edge replicate seed: also write to anchor_buf
                // (which becomes prev_buf for pair 0 emit after the next
                // rotation; see plan §"Why the seed goes to anchor_sel").
                if (effective_first_pair) begin
                    unique case (anchor_sel)
                        2'd0:    buf0[in_col_q] <= s_axis.tdata;
                        2'd1:    buf1[in_col_q] <= s_axis.tdata;
                        default: buf2[in_col_q] <= s_axis.tdata;
                    endcase
                end
                if (s_axis.tuser)
                    sof_pending_q <= 1'b1;
                if (s_axis.tlast) begin
                    in_col_q  <= '0;
                    in_done_q <= 1'b1;
                end else begin
                    in_col_q <= in_col_q + COL_W'(1);
                end
            end

            // ---- Output emitter ----
            if (do_emit) begin
                if (out_beat_q == BEAT_W'(4*H_ACTIVE_IN - 1)) begin
                    out_beat_q   <= '0;
                    emit_armed_q <= 1'b0;
                end else begin
                    out_beat_q <= out_beat_q + BEAT_W'(1);
                end
                if (sof_pending_q && (out_beat_q == '0))
                    sof_pending_q <= 1'b0;
            end

            // ---- Boundary rotation ----
            // Triggers when input row is done AND emitter is idle. There may
            // be a 1-cycle bubble between consecutive pairs (m_axis.tvalid=0
            // for one cycle while emit_armed_q transitions through 0); this
            // is acceptable and adds 1/(4W) overhead.
            if (in_done_q && !emit_armed_q) begin
                wr_sel_q     <= (wr_sel_q == 2'd2) ? 2'd0 : (wr_sel_q + 2'd1);
                in_done_q    <= 1'b0;
                emit_armed_q <= 1'b1;
                first_pair_q <= 1'b0;
            end

            // ---- SOF re-arm ----
            // Accepted SOF input rearms first_pair_q for the new frame's
            // top-edge replicate seeding. wr_sel_q is NOT reset — the
            // rotation is invariant under starting offset.
            if (is_sof_pixel) begin
                first_pair_q <= 1'b1;
            end
        end
    end

    // V_ACTIVE_IN is informational only; touch to keep Verilator quiet.
    logic _unused;
    assign _unused = &{1'b0, V_ACTIVE_IN[0]};

endmodule
```

- [ ] **Step 3: Lint**

```bash
make lint
```

Expected: `exit=0`, no new warnings beyond the pre-existing `parameter-name-style` advisories on `COL_W`/`OUT_COL_W`/`BEAT_W` (the project uses `ALL_CAPS` for localparams; the lint regex prefers `CamelCase`).

- [ ] **Step 4: Commit the RTL rewrite (lint passing, tests pending)**

```bash
git add hw/ip/scaler/rtl/axis_scale2x.sv
git commit -m "refactor(scale2x): 3-buffer counter-driven body (replaces 2-buffer FSM)"
```

---

## Task 3: Adjust the unit testbench

The TB at `hw/ip/scaler/tb/tb_axis_scale2x.sv` drives a 2x2 frame with `H_ACTIVE_IN = 2`, then waits 64 cycles for outputs and checks 16 beats. The new architecture has a 1-input-row startup latency (`4W = 8` DSP cycles for `W = 2`), which is well within the existing 64-cycle settle window — but the test driver's `repeat (64) @(posedge clk)` may complete *before* the bot row finishes emitting under the new schedule, depending on exact handshake timing. Verify, and bump the wait if needed.

**Files:**
- Modify: `hw/ip/scaler/tb/tb_axis_scale2x.sv`

- [ ] **Step 1: Run the existing TB unchanged**

```bash
make test-ip-scale2x
```

Expected outcomes:
- **Best case:** `PASS`. The 64-cycle window covers the new latency. Skip to Step 4.
- **Likely case:** Some output indices fail because not enough cycles have elapsed for all 16 beats to retire. Continue to Step 2.

- [ ] **Step 2: If beats are missing, extend the settle wait**

Open `hw/ip/scaler/tb/tb_axis_scale2x.sv` and find both occurrences of:

```sv
        repeat (64) @(posedge clk);
```

Change them to:

```sv
        repeat (256) @(posedge clk);
```

Rationale: with `H_ACTIVE_IN = 2`, two source rows take `2 × 4W = 16` DSP cycles minimum to fully process under the new arch, plus the 1-row startup. 256 cycles is comfortable headroom and keeps the test fast.

- [ ] **Step 3: Re-run the TB**

```bash
make test-ip-scale2x
```

Expected: `PASS`.

- [ ] **Step 4: Verify the PASS line is real, not a false positive**

```bash
make test-ip-scale2x 2>&1 | grep -E 'PASS|FAIL|errors'
```

Expected: a single `PASS` line and no `FAIL` lines.

- [ ] **Step 5: Commit (only if Step 2 was needed)**

```bash
git add hw/ip/scaler/tb/tb_axis_scale2x.sv
git commit -m "test(scale2x): extend unit TB settle wait for new 1-row startup latency"
```

---

## Task 4: Run the full verification suite

The Python reference model is unchanged, so all model-vs-RTL parity tests should pass at `TOLERANCE=0`. This task is a verification gate — no code changes if it passes.

**Files:**
- (None — verification only)

- [ ] **Step 1: All per-block IP testbenches**

```bash
make test-ip
```

Expected: `All block testbenches passed.` line at the end. Every testbench printing `PASS` (or its module-specific pass marker).

- [ ] **Step 2: Python tests (95 tests including profile parity and scale2x model)**

```bash
source .venv/bin/activate && PYTHONPATH=py pytest py/tests -q
```

Expected: `95 passed` (or however many tests exist; all must pass).

- [ ] **Step 3: End-to-end pipeline, default profile, motion ctrl flow**

```bash
make run-pipeline CTRL_FLOW=motion CFG=default FRAMES=4 MODE=binary
```

Expected: `Pipeline complete!` at the end. `make verify` step internally reports `PASS` at `TOLERANCE=0`.

- [ ] **Step 4: End-to-end pipeline, no_scaler profile (sanity — the scaler is bypassed by the generate gate)**

```bash
make run-pipeline CTRL_FLOW=motion CFG=no_scaler FRAMES=4 MODE=binary
```

Expected: `Pipeline complete!`. Verifies the bypass path is unaffected.

- [ ] **Step 5: End-to-end pipeline, all four control flows × default profile**

Run the four control flows in sequence:

```bash
for cf in passthrough motion mask ccl_bbox; do
    make run-pipeline CTRL_FLOW=$cf CFG=default FRAMES=4 MODE=binary || exit 1
done
```

Expected: each invocation ends with `Pipeline complete!`. Any failure exits with non-zero.

- [ ] **Step 6: End-to-end pipeline, default profile × no_morph and no_gauss profiles**

Light coverage of the profile matrix:

```bash
make run-pipeline CTRL_FLOW=motion CFG=no_morph FRAMES=4 MODE=binary
make run-pipeline CTRL_FLOW=motion CFG=no_gauss FRAMES=4 MODE=binary
```

Expected: both end with `Pipeline complete!`.

---

## Task 5: Squash and document the change

Per `CLAUDE.md`: "Once a plan is fully implemented and its tests pass, squash all of the plan's commits into a single commit before opening the PR."

**Files:**
- (None — git operations only)

- [ ] **Step 1: Confirm all plan commits belong to this scope**

```bash
git log --oneline feat/axis-scale2x..HEAD
```

Expected: 4–5 commits — one for the plan doc, then `docs(scale2x): …`, `refactor(scale2x): …`, `test(scale2x): …` (the latter only if Task 3 Step 2 was needed). No unrelated commits. The base `feat/axis-scale2x..HEAD` (rather than `origin/main..HEAD`) excludes the predecessor's commits from this PR's scope — they ship in their own PR.

If unrelated commits appear (typo fixes, adjacent refactors), per `CLAUDE.md` move them to their own branch + PR before squashing here.

- [ ] **Step 2: Squash to a single commit**

```bash
git reset --soft feat/axis-scale2x
git commit -m "$(cat <<'EOF'
refactor(scale2x): 3-buffer uniform-FSM upscaler

Replaces the prior 2-buffer phase-switching FSM with a 3-buffer cyclic
rotation + counter-driven datapath. The control logic collapses from 6
states with a peek window, right-edge replicate path, and bot-replay
back-pressure phase to two independent counters (in_col_q for the input
writer, out_beat_q for the output emitter) plus a 2-bit wr_sel_q rotation
register and a few boundary-flag bits.

Key changes:
- 3 line buffers (buf0/1/2) in cyclic rotation. write_buf, anchor_buf,
  prev_buf are always disjoint, so writes and reads never alias.
- Output beats are addressed directly from out_beat_q, with phase, src_c,
  src_cp1, and beat parity all combinationally decoded. The right-edge
  "S_TOP2 -> S_TOP1 bounce" collapses to src_cp1 = min(src_c+1, W-1).
- The cur_q/next_q peek window is gone — top-row beats read straight from
  the anchor buffer.
- The 2W-cycle bot-replay back-pressure burst is gone. s_axis.tready
  follows a sustained ~25% duty cycle through the row, with brief
  deassertion only at row boundaries when writer/emitter desync.

Trade-off: +1 line buffer (15 360 b -> 23 040 b at H_ACTIVE=320, +50%),
and a 4W-cycle (one input row) startup latency from SOF to first output
beat. These are documented in axis_scale2x-arch.md §5.5 and §7. Public
interface (parameters, ports) and bit-exact output are unchanged; the
Python reference model in py/models/ops/scale2x.py was already
spec-driven and required no edits.

Verification:
- make lint clean
- make test-ip-scale2x PASS
- make test-ip (all blocks) PASS
- pytest py/tests (95 tests) PASS
- make run-pipeline across all 4 ctrl flows + default/no_scaler/no_morph/
  no_gauss profiles, TOLERANCE=0
EOF
)"
```

- [ ] **Step 3: Open the PR**

```bash
gh pr create --base feat/axis-scale2x --title "refactor(scale2x): 3-buffer uniform-FSM upscaler" --body "$(cat <<'EOF'
## Summary
- Replaces axis_scale2x's 6-state phase-switching FSM with a 3-buffer cyclic rotation + counter-driven datapath. RTL drops from ~250 to ~140 LOC.
- Eliminates the 2W-cycle bot-replay back-pressure burst per row. Steady-state input duty becomes a uniform ~25% (1 accept per 4 DSP cycles).
- Costs +1 line buffer (+50%, 15.36 Kb -> 23.04 Kb at H_ACTIVE=320) and a 4W-cycle (1-input-row) startup latency from SOF to first output beat.

**Depends on `feat/axis-scale2x`** (kill-NN simplification). This PR is based on that branch and should merge after it.

## Test plan
- [x] make lint
- [x] make test-ip-scale2x
- [x] make test-ip (all blocks)
- [x] pytest py/tests (95 tests)
- [x] make run-pipeline across all 4 ctrl flows + 4 profiles, TOLERANCE=0
EOF
)"
```

- [ ] **Step 4: Move this plan file to docs/plans/old/ once the PR merges**

After the PR is merged, per `CLAUDE.md`'s "After implementing a plan, move it to docs/plans/old/":

```bash
mv docs/plans/2026-04-28-scale2x-3buf-plan.md docs/plans/old/
```

Followed by a small follow-up commit on `main` archiving it. (This step happens *after* the PR merges, not in this PR.)
