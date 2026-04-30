# `axis_ccl` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.0 Plain-language overview](#40-plain-language-overview)
  - [4.1 Streaming union-find](#41-streaming-union-find)
  - [4.2 The ≤2-distinct-labels invariant](#42-the-2-distinct-labels-invariant)
  - [4.3 Single equiv write per pixel](#43-single-equiv-write-per-pixel)
  - [4.4 Overflow semantics](#44-overflow-semantics)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Data flow overview](#51-data-flow-overview)
  - [5.2 Row/column counters and SOF handling](#52-rowcolumn-counters-and-sof-handling)
  - [5.3 Label line buffer and 2-deep shift chain](#53-label-line-buffer-and-2-deep-shift-chain)
  - [5.4 Edge masking for NW/N/NE/W](#54-edge-masking-for-nwnnew)
  - [5.5 Label decision](#55-label-decision)
  - [5.6 Per-pixel writes](#56-per-pixel-writes)
  - [5.7 Accumulator bank](#57-accumulator-bank)
  - [5.8 Output double-buffer](#58-output-double-buffer)
  - [5.9 Resource cost summary](#59-resource-cost-summary)
- [6. Control Logic and State Machines](#6-control-logic-and-state-machines)
  - [6.1 EOF detection](#61-eof-detection)
  - [6.2 Phase A — path compression](#62-phase-a--path-compression)
  - [6.3 Phase B — accumulator fold](#63-phase-b--accumulator-fold)
  - [6.4 Phase C — min-size filter + top-N selection](#64-phase-c--min-size-filter--top-n-selection)
  - [6.5 Phase D — reset for next frame](#65-phase-d--reset-for-next-frame)
  - [6.6 PHASE_SWAP — front-buffer commit + priming](#66-phase_swap--front-buffer-commit--priming)
  - [6.7 Cycle budget](#67-cycle-budget)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_ccl` is a streaming 8-connected connected-component labeler. It consumes a 1-bit-per-pixel AXI4-Stream motion mask, assigns a distinct label to each foreground region using union-find with in-frame equivalence recording, accumulates `{min_x, max_x, min_y, max_y, count}` per label, and — at end-of-frame, during vblank — resolves equivalences, folds accumulators onto their roots, applies a min-pixel-count filter, and emits up to `N_OUT` bounding boxes on a double-buffered sideband.

It is nearly a pure sink on its AXIS port: `tready` is asserted during streaming (`PHASE_IDLE`) and deasserted only while the EOF resolution FSM is running (`PHASE_A..PHASE_SWAP`). All multi-cycle work (path compression, accumulator fold, top-N selection, reset) is scheduled during the vertical-blanking interval, and the tready deassert is both the structural invariant that makes per-pixel writes gatable on `PHASE_IDLE` and the back-pressure that stalls upstream if vblank is too short. `axis_ccl` does **not** perform morphological closing, temporal merging, or cross-frame object association; it has no dependency on the shared Y-ref RAM used by `axis_motion_detect`.

> **New to this module?** §4.0 gives a plain-language walkthrough of the algorithm and defines the terms (*label*, *equivalence*, *root*, *chain*, *chase*, *fold*, *sentinel*, *prime frames*) used throughout the rest of this spec.

---

## 2. Module Hierarchy

`axis_ccl` is a leaf module. It is instantiated in [`sparevideo_top`](sparevideo-top-arch.md) as `u_ccl`, between [`axis_motion_detect`](axis_motion_detect-arch.md) (producer of the mask stream) and [`axis_overlay_bbox`](axis_overlay_bbox-arch.md) (consumer of the `N_OUT` bbox sideband).

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per row; sets label line-buffer depth and `COL_W`. |
| `V_ACTIVE` | 240 | Active rows per frame; sets `ROW_W` and the EOF trigger row. |
| `N_LABELS_INT` | 64 (from pkg) | Internal label capacity. Label 0 is reserved (background + overflow); real labels occupy `1..N_LABELS_INT-1`. Sets `LABEL_W = $clog2(N_LABELS_INT)`. |
| `N_OUT` | 8 (from pkg) | Output bbox slots exposed on the sideband. |
| `MIN_COMPONENT_PIXELS` | 16 (from pkg) | Minimum pixel count for a component to survive Phase C. |
| `MAX_CHAIN_DEPTH` | 8 (from pkg) | Upper bound on Phase A per-label chase steps. |
| `PRIME_FRAMES` | 0 (from pkg) | Number of initial frames for which PHASE_SWAP skips the front-buffer update, giving the upstream EMA background model time to converge before any bbox is reported. |

### 3.2 Ports

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| **Clock and reset** | | | |
| `clk_i`   | input  | `logic`      | DSP clock (`clk_dsp`), rising edge. |
| `rst_n_i` | input  | `logic`      | Active-low synchronous reset. |
| `s_axis`  | input  | `axis_if.rx` | 1-bit mask input stream (DATA_W=1, USER_W=1; tdata[0]=mask bit; 1=foreground). tready = `(phase == PHASE_IDLE)` — deasserted during the EOF resolution FSM so upstream stalls rather than feeding pixels while the PHASE_IDLE write gate is inactive. |
| `bboxes`  | output | `bbox_if.tx` | N_OUT bounding-box sideband output (N_OUT=CCL_N_OUT). Per-slot `{min_x, max_x, min_y, max_y, valid}` arrays, stable for the full next frame after PHASE_SWAP commits them. |
| `bbox_swap_o`  | output | `logic` | 1-cycle strobe pulsed at PHASE_SWAP — indicates a new frame's bboxes are now visible on the front buffer. |
| `bbox_empty_o` | output | `logic` | Asserted when no slot is valid (i.e. `bbox_valid_o == '0`) — convenience signal for downstream. |

`s_axis.tready` is high during streaming and low during the EOF resolution FSM (§6.7). For how the parent wires this module into a multi-consumer broadcast in mask-display and ccl_bbox modes, see [sparevideo-top-arch.md](sparevideo-top-arch.md) §5.1.

---

## 4. Concept Description

### 4.0 Overview

`axis_ccl` consumes a 1-bit motion mask in raster order (one pixel per clock, left-to-right, top-to-bottom) and assigns each foreground pixel an integer **label** so that pixels in the same 8-connected blob share a label. A running bounding box and pixel count is kept per label. At end-of-frame — during vblank — the module resolves any label **equivalences** discovered during labeling, merges the per-label stats, picks the top-`N_OUT` blobs above a minimum-size threshold, and publishes their bounding boxes on a sideband. The resolve runs in vblank, so bboxes for frame N become visible at the start of frame N+1 — a one-frame lag (§7).

#### Glossary

| Term | Meaning |
|------|---------|
| **Label** | Positive integer ID (`1..N_LABELS_INT-1`) for a foreground pixel. Label 0 = background or overflow (§4.4). |
| **Equivalence** | A recorded "label A and label B are the same blob," stored as `equiv[A]=B` with A>B. |
| **Root** | The smallest label in an equivalence chain — its accumulator ends up holding the whole blob. `equiv[root]==root`. |
| **Chain** | A sequence `equiv[L1]=L2, equiv[L2]=L3, …` that can form when merges happen in an order that doesn't flatten the table in one step. 
| **Chase** | Walking `equiv[]` until a root is reached. Phase A does this, bounded by `MAX_CHAIN_DEPTH`. |
| **Path compression** | After a chase, overwriting `equiv[L] ← root` so the next chase from `L` is one step. |
| **Accumulator** | Per-label running `{min_x, max_x, min_y, max_y, count}` — bbox-in-progress. |
| **Sentinel** | Initial accumulator value chosen so the first foreground pixel always wins the min/max comparator. |
| **Fold** | Phase B: copy a non-root's accumulator into its root's, then clear the non-root. |
| **Prime frames** | First `PRIME_FRAMES` frames after reset, during which the front buffer stays empty so the EMA background has time to converge before any bbox is reported. |

#### Storage model

| Structure | Indexed by | Width | Purpose |
|---|---|---|---|
| `line_buf` | column | `LABEL_W` | One-row-deep label history — previous-row labels to the right of scan, current-row to the left. |
| `equiv[]` | label | `LABEL_W` | Equivalence table. Updated on merges; flattened at EOF in Phase A. |
| `acc_min_x`, `acc_max_x`, `acc_min_y`, `acc_max_y`, `acc_count` | label | coord/count | Per-label bbox-in-progress. |
| `next_free` | scalar | `LABEL_W+1` | Next label to allocate; saturates on overflow. |
| Output double-buffer | slot | `1 + 2·COL_W + 2·ROW_W` | `front_*` is visible; `back_*` is Phase C scratch. Swapped atomically at PHASE_SWAP. |

**No full-frame label image is stored.** Bboxes are a reduction (min/max/count) that can be maintained incrementally, so per-pixel labels need only survive one row. Once a row has passed, its contribution lives only in `acc_*[]`. This keeps the datapath in a few kb of distributed RAM instead of the ~460 kb a per-pixel label array would need.

#### Frame lifecycle

```
   ┌────────── active region ──────────┐┌── vblank ──┐┌── next active ──
   │ label + accumulate, 1 pix/cycle   ││A→B→C→D→SWAP││ frame-N bboxes
   │   tready = 1                      ││ tready = 0 ││ now visible
   └───────────────────────────────────┘└──────┬─────┘└─────────────────
                                               │
                                               └─ EOF FSM: ~1,280 cycles
                                                  worst case (§6.7)
```

Per-pixel: label + update accumulators in raster order (§4.1). At EOF, four FSM phases run back-to-back during vblank, then a swap (§6): **A** flattens `equiv[]` to roots, **B** folds non-root accumulators into roots, **C** picks the top-`N_OUT` blobs above `MIN_COMPONENT_PIXELS`, **D** restores sentinels for the next frame, **SWAP** publishes the new bboxes (skipped during prime frames). Frame N's bboxes are painted onto frame N+1's pixels — a one-frame lag (§7).

### 4.1 Streaming union-find

Classical raster CCL makes two passes over the image: one to assign provisional labels while recording label equivalences, and a second to relabel to canonical roots. This module streams instead — per-pixel labeling happens in one raster pass; equivalence resolution happens during vblank.

For each foreground pixel at `(r, c)`, the four already-labeled 8-connected neighbours `{NW, N, NE, W}` are inspected:

```
 NW  N  NE
  W  *
```

- All four background → start a new component, allocate from `next_free`.
- One non-zero label in the window → inherit it.
- Two distinct non-zero labels → take the smaller, record `equiv[max] = min`. Phase B will fold the two components at EOF.

The merge writes only `equiv[]`; earlier-row pixels stored under the larger label are not rewritten. Phase A chases the equivalence at EOF and Phase B folds the accumulators under the canonical root.

### 4.2 The ≤2-distinct-labels invariant

In 8-connected raster CCL, `{NW, N, NE, W}` can contain **at most two distinct non-zero labels**. Informal proof:

- `NW` and `N` are horizontally adjacent in the previous row. When `N` was labeled, it would have already been merged with `NW` if both were foreground. So `{NW, N}` contributes at most one label.
- The same argument applies to `{N, NE}`.
- Therefore `{NW, N, NE}` contributes at most one distinct label.
- Combined with `W`, that's ≤ 2 distinct labels.

Consequence: the equivalence table needs at most **one write per pixel**. A single 1W port suffices.

### 4.3 Single equiv write per pixel

On a 2-distinct merge, we unconditionally write `equiv[max_label] = min_label`. We do **not** chase roots at pixel time. Root chasing at pixel time would require multiple cycles per pixel (variable) or multiple 1R equiv ports to parallelise — both incompatible with the 1-pixel-per-cycle throughput budget on a 1R1W port.

Leaving the table partially compressed during the frame is safe: Phase A at EOF walks every label and flattens chains to roots (bounded by `MAX_CHAIN_DEPTH`) before the accumulator fold.

### 4.4 Overflow semantics

`next_free` starts at 1 and saturates at `N_LABELS_INT` (it is `LABEL_W+1` bits wide so the comparison `next_free < N_LABELS_INT` is exact, no wrap). Once saturated, any new component is assigned label 0. Label 0's accumulator pools all overflow pixels. If that pool exceeds `MIN_COMPONENT_PIXELS` it surfaces as a spurious catch-all bbox — documented, not a correctness bug.

---

## 5. Internal Architecture

### 5.1 Data flow overview

For each accepted mask beat, the datapath does three things: assemble the four already-labeled neighbours `{NW, N, NE, W}` (with off-image positions forced to 0), compute the label, and issue per-memory writes. Per-pixel writes are gated by `phase == PHASE_IDLE`, and `s_axis.tready=0` outside `PHASE_IDLE` so no beats arrive while the FSM owns the state.

**Three-neighbour read.** `line_buf` has a registered 1R1W port, but the label decision needs `NW`, `N`, and `NE` simultaneously. The read address is issued one column ahead of the scan position; the registered result feeds a 2-deep shift register so `NE`, `N`, `NW` all appear on the same cycle. The `W` neighbour is the label just written for the previous pixel.

```
                line_buf       shift register
   col ──► rd ──► register ──► N ──► NW
                  (= NE)       │      │
                               ▼      ▼
   w_label (= W) ──────────► edge mask (border → 0)
                                  │
                                  ▼
                            label decision  ◄── next_free
                                  │
                                  ▼
                       writes: line_buf, w_label,
                       equiv[], acc_*[], next_free
```

Sections §5.2–§5.7 cover counters and SOF handling, line-buffer organisation, edge masking, label arithmetic, per-pixel writes, and accumulator sentinels.

### 5.2 Row/column counters and SOF handling

`col` and `row` track the scan position. On accepted SOF they reset to `(col=1, row=0)` — the SOF beat itself is column 0. On accepted EOL `col` resets to 0 and `row` increments.

The stage-1 shadow registers `col_d1`/`row_d1` need to land on `(0, 0)` for the SOF pixel, not on the pre-reset values held over from the previous frame's EOL (which sit at `col=0, row=V_ACTIVE`). The stage-1 pipeline register therefore forces `(0, 0)` whenever SOF is observed at stage 0. Without this override, the SOF pixel would accumulate at `row = V_ACTIVE`, producing rogue bboxes with `max_y = V_ACTIVE`.

### 5.3 Label line buffer and 2-deep shift chain

`line_buf` is a distributed LUT-RAM (depth `H_ACTIVE`, width `LABEL_W`) holding the previous row's labels so the current row can read `{NW, N, NE}` without a second pass.

The read address is issued one column ahead of scan, so the registered read result is `NE` for the current column. A 2-deep register shift chain delays that tap by one and two cycles to give `N` and `NW`. All three values land on the same cycle. The shift chain advances on stage-1 beat acceptance, so stalls or idle cycles do not desync it.

### 5.4 Edge masking for NW/N/NE/W

Off-image neighbours are forced to background (label 0) combinationally; there is no explicit border row stored in `line_buf`. Row 0 reads are masked, so the buffer's reset state is irrelevant — row 0's writes refill it before row 1 reads.

| Neighbour | Masked to 0 when |
|-----------|-----------------|
| `nb_nw` | `col_d1 == 0` or `row_d1 == 0` |
| `nb_n` | `row_d1 == 0` |
| `nb_ne` | `col_d1 == H_ACTIVE - 1` or `row_d1 == 0` |
| `nb_w` | `col_d1 == 0` |

### 5.5 Label decision

Combinational logic computes `pick`, `need_merge`, `merge_hi`, `merge_lo` from the 4 edge-masked neighbours:

- All-zero window → `pick = next_free` (or 0 on overflow); no merge.
- One non-zero label in the window → `pick = that label`; no merge.
- Two distinct non-zero labels → `pick = min(nb_w, min_above)`, `need_merge = 1`, `merge_hi = max`, `merge_lo = min`.

`min_above = min(nb_nw, nb_n, nb_ne)` is a 3-comparator chain. By §4.2, `{NW, N, NE}` contributes at most one non-zero label, so tie-breaking order is irrelevant.

### 5.6 Per-pixel writes

`write_fg = accept_d1 && tdata_d1 && (phase == PHASE_IDLE)` gates the foreground updates; `line_buf` and `w_label` update on any accepted beat (so the previous row's label at this column is overwritten with 0 when the current pixel is background — no separate clear pass).

| Memory | Operation | Fires when |
|--------|-----------|-----------|
| `line_buf[col_d1]` | ← `write_fg ? pick : 0` | every `accept_d1` |
| `equiv[merge_hi]` | ← `merge_lo` | `write_fg && need_merge` |
| `acc_min_x[pick]` | ← `min(acc_min_x[pick], col_d1)` | `write_fg` |
| `acc_max_x[pick]` | ← `max(acc_max_x[pick], col_d1)` | `write_fg` |
| `acc_min_y[pick]` | ← `min(acc_min_y[pick], row_d1)` | `write_fg` |
| `acc_max_y[pick]` | ← `max(acc_max_y[pick], row_d1)` | `write_fg` |
| `acc_count[pick]` | ← `acc_count[pick] + 1` | `write_fg` |
| `next_free` | ← `next_free + 1` | `write_fg && !any_nonzero && next_free < N_LABELS_INT` |
| `w_label` | ← `(tuser\|tlast) ? 0 : (write_fg ? pick : 0)` | every `accept_d1` |

The `acc_min_*` / `acc_max_*` rows are gated conditional writes; the `min`/`max` notation describes the functional result. Sentinels (§5.7) ensure the first foreground pixel always wins the comparator.

### 5.7 Accumulator bank

Five parallel distributed-RAM arrays indexed by label (`0..N_LABELS_INT-1`). Sentinels are chosen so the first foreground pixel always wins the `<`/`>` comparators.

| Array | Width | Sentinel (reset / Phase D) |
|-------|-------|----------------------------|
| `acc_min_x` | `COL_W` | `H_ACTIVE - 1` |
| `acc_max_x` | `COL_W` | 0 |
| `acc_min_y` | `ROW_W` | `V_ACTIVE - 1` |
| `acc_max_y` | `ROW_W` | 0 |
| `acc_count` | `COUNT_W = ⌈log2(H·V+1)⌉` | 0 |

After Phase B, `count == 0` means the label was either never seen or has been folded into its root (the fold explicitly clears the non-root).

### 5.8 Output double-buffer

The overlay reads the `N_OUT` slots throughout the active region. To avoid tearing, Phase C writes a back bank while the front bank stays visible; PHASE_SWAP performs a bulk `front_* ← back_*` register copy as a single-cycle atomic transition, and `bbox_swap_o` strobes for that cycle. `back_valid` is cleared at the end of PHASE_SWAP so the next frame's Phase C starts from an empty slate — slots it does not fill remain deasserted.

Each bank holds `N_OUT` slots of `{valid, min_x, max_x, min_y, max_y}`. `front_*` drives the `bboxes` output interface; `back_*` is Phase C's scratch.

### 5.9 Resource cost summary

At defaults (`H_ACTIVE=320, V_ACTIVE=240, N_LABELS_INT=64, N_OUT=8`):

| Resource | Count | Notes |
|----------|-------|-------|
| Label line buffer | 320 × 6 = 1.92 kb | Distributed LUT-RAM, 1R1W |
| Equivalence table | 64 × 6 = 384 b | Distributed LUT-RAM, 1R1W |
| Accumulator bank | 64 × (9+9+8+8+17) = ~3.3 kb | Distributed LUT-RAM, 1R1W per array |
| `shift_nw`, `shift_n`, `w_label`, `line_rd_data_r` | 4 × 6 = 24 FFs | |
| Pipeline regs (`accept_d1`, `tdata_d1`, …, `col_d1`, `row_d1`) | 1+1+1+1 + COL_W + ROW_W = 21 FFs | |
| Front + back bbox buffers | 2 × 8 × (1+9+9+8+8) = 560 FFs | |
| FSM state (`phase`, `lbl_idx`, `scan_idx`, `out_slot`, …) | ~35 FFs | |
| Multipliers | 0 | |

Total: ~5.6 kb distributed RAM + ~640 FFs. No BRAM. No DSP. No shared RAM.

---

## 6. Control Logic and State Machines

### 6.1 EOF detection

`is_eof = accept_d1 && tlast_d1 && (row_d1 == V_ACTIVE − 1)`. A registered version drives the PHASE_IDLE → PHASE_A transition one cycle later, so the last pixel's accumulator RMW has committed before Phase A starts reading.

### 6.2 Phase A — path compression

*Rewrites each `equiv[L]` to point directly at its root, so Phase B can fold in one hop.*

For each label `L = 1..N_LABELS_INT-1`, the FSM walks `equiv[]` from `L` until it hits a fixed point (`equiv[x] == x`) or `MAX_CHAIN_DEPTH` steps, then writes the discovered root back into `equiv[L]`. Implemented as two states: `PHASE_A` seeds the chase from the next label, `PHASE_A_CHASE` advances one hop per cycle.

`MAX_CHAIN_DEPTH = 8` is well above chain depths observed on natural masks; deeper pathological chains leave tail labels orphaned (see §9).

### 6.3 Phase B — accumulator fold

*Merges each non-root's accumulator into its root and clears the non-root.*

For each label `L` with `equiv[L] ≠ L` and `acc_count[L] ≠ 0`, two cycles cover the 1R1W accumulator latency:

1. **Sample** — snapshot `acc[L]` into a local register; latch `fold_dst ← equiv[L]` (a root after Phase A).
2. **Commit** — `acc[fold_dst] ← merge(acc[fold_dst], snapshot)`, clear `acc_count[L]`, advance to the next label.

Roots and zero-count labels advance in a single cycle.

### 6.4 Phase C — min-size filter + top-N selection

*Drops components below `MIN_COMPONENT_PIXELS` and writes the largest `N_OUT` survivors into the back buffer.*

For each output slot `s = 0..N_OUT-1`, the FSM scans all labels (one per cycle) and picks the largest with `acc_count ≥ MIN_COMPONENT_PIXELS`. The winner is written into `back[s]` and its `acc_count` is cleared so the next slot picks the next-largest. If no label qualifies, `back_valid[s] ← 0`.

Label 0 is scanned, so an overflow pool (§4.4) can surface as a catch-all bbox when it exceeds the threshold.

### 6.5 Phase D — reset for next frame

Walks `L = 0..N_LABELS_INT-1`, restoring `equiv[]` and the accumulators to their sentinel values (§5.7). After the last label, `next_free ← 1` and the FSM advances to PHASE_SWAP.

### 6.6 PHASE_SWAP — front-buffer commit + priming

`front_* ← back_*` is a single-cycle bulk register copy. `back_valid` is then cleared and `bbox_swap_o` strobes for one cycle before the FSM returns to PHASE_IDLE.

During the first `PRIME_FRAMES` frames the copy is suppressed (back-buffer data is discarded; front stays all-invalid). `bbox_swap_o` still pulses so downstream consumers see a consistent "new frame ready" handshake. See the §4.0 glossary for why priming exists; the default `PRIME_FRAMES=0` is usually sufficient because `axis_motion_detect`'s frame-0 hard-init plus grace window already suppress the early-frame full-mask transient.

### 6.7 Cycle budget

| Phase | Cycles | Default (`N_LABELS=64`, `N_OUT=8`) |
|-------|--------|-----------------------|
| A (path compression) | `N_LABELS × (MAX_CHAIN_DEPTH + 1)` | 576 |
| B (fold) | `N_LABELS × 2` | 128 |
| C (top-N) | `N_OUT × N_LABELS` | 512 |
| D (reset) | `N_LABELS` | 64 |
| SWAP | 1 | 1 |
| **Total** | | **~1,280** |

VGA 640×480@60 Hz at 100 MHz DSP gives ~144 kcycles of vblank — ~100× headroom.

The headroom is a **correctness** constraint, not just throughput: per-pixel writes to `equiv[]`, `acc_*[]`, and `next_free` are gated on `PHASE_IDLE`. A pixel accepted during the FSM would silently drop those updates while `line_buf`, `w_label`, and the counters still advance, corrupting later labels. Two defences: `s_axis.tready` is deasserted outside `PHASE_IDLE` so upstream stalls structurally; an SVA traps any handshake during the FSM. Upstream FIFOs are finite, so integrating designs must still size the inter-frame idle window to exceed the budget above.

---

## 7. Timing

Three latency regimes:

- **Stream path** — zero. `axis_ccl` does not forward pixels; the RGB path the overlay draws onto has its own pipeline and is unaffected.
- **Sideband produce-time** — ~1,280 cycles worst case from the last mask pixel to the `bbox_swap_o` pulse (§6.7), well inside one vblank.
- **Frame-level** — **one frame.** Bboxes for frame N become visible at the start of frame N+1. During the first `PRIME_FRAMES` frames after reset the front buffer stays empty, so real bboxes first appear on frame `PRIME_FRAMES + 1`.

| Operation | Latency |
|-----------|---------|
| Input beat → first accumulator RMW of a frame | 2 cycles (stage 0 → stage 1) |
| Last mask pixel → `bbox_swap_o` pulse | ~1,280 cycles worst case (§6.7) |
| `bbox_swap_o` pulse → `bboxes` updated | 0 cycles (same edge as the front-buffer copy) |
| Steady-state throughput | 1 pixel / cycle |

---

## 8. Shared Types

All shared constants live in `hw/top/sparevideo_pkg.sv`:

- `CCL_N_LABELS_INT`, `CCL_N_OUT`, `CCL_MIN_COMPONENT_PIXELS`, `CCL_MAX_CHAIN_DEPTH`, `CCL_PRIME_FRAMES`.
- `CTRL_CCL_BBOX` (2'b11): top-level ctrl_flow selector that wires the mask-as-grey canvas to the overlay input for debug visibility into CCL output.

Module parameter defaults reference the package constants. Override at instantiation only where the unit TB wants to exercise edge behaviour (e.g., `PRIME_FRAMES=0` to assert on the first frame).

---

## 9. Known Limitations

- **Single equiv write per pixel can over-split vs. full union-find.** On noisy masks, two labels that would eventually unify via a third label may not merge within one frame if the chains haven't been built up by raster order. This is an accepted spec trade-off: the 1W port budget is tight, and over-splitting is safer than mis-merging.
- **`MAX_CHAIN_DEPTH = 8` is a hard bound.** Chains deeper than 8 leave tail labels referencing a *non-root* (Phase A writes `equiv[L] ← chase_root` even when the chase terminates on the depth limit rather than on a fixed point). Phase B then folds `acc[L]` into `acc[equiv[L]]`, which is itself a non-root, so the component ends up split between the root accumulator and the partially-chased midpoint. On natural masks, observed chain depth is small (≤3) and this has no visible effect. If `N_LABELS_INT` is raised substantially without a proportional bump to `MAX_CHAIN_DEPTH`, the silent-split behavior can degrade top-K selection — the split halves compete against each other for slots rather than being unified.
- **Label 0 overflow can produce a catch-all bbox.** When `N_LABELS_INT` is exhausted mid-frame, subsequent new components pool into label 0. If the pool exceeds `MIN_COMPONENT_PIXELS`, Phase C emits a spurious union-of-everything bbox. Mitigation: raise `N_LABELS_INT`; or add label recycling (future work).
- **Homogeneous object fragmentation is inherited from the mask.** EMA-based motion detection marks only leading/trailing edges of solid-color objects. CCL correctly labels these as separate components — there is no within-frame way to reunite them. Follow-ups (morphological closing, bbox-merge post-pass) are deferred.
- **No cross-frame object identity.** Frame N's slot 3 has no relationship to frame N+1's slot 3 beyond "largest first". Persistent IDs require a separate tracker stage.
- **Back-buffer not exported.** Only the front buffer is visible; the EOF pipeline running on frame N+1 while the overlay reads frame N is a future optimization (accumulator double-buffering), not a current feature.

---

## 10. References

- **Parent pipeline:** [axis_motion_detect-arch.md](axis_motion_detect-arch.md), [axis_overlay_bbox-arch.md](axis_overlay_bbox-arch.md), [sparevideo-top-arch.md](sparevideo-top-arch.md).
- **Rosenfeld, A. & Pfaltz, J.L., "Sequential operations in digital picture processing," JACM 13(4), 1966** — classical two-pass raster CCL with equivalence table. This module's per-pixel logic is the streaming adaptation.
