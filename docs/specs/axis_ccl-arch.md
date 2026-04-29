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

The module replaces the earlier single-global-bbox reducer (`axis_bbox_reduce`). Two people walking in opposite corners now produce two distinct bboxes instead of one frame-spanning rectangle.

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
| `PRIME_FRAMES` | 2 (from pkg) | Number of initial frames for which PHASE_SWAP skips the front-buffer update, giving the upstream EMA background model time to converge before any bbox is reported. |

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

### 4.0 Plain-language overview

`axis_ccl` consumes a 1-bit motion mask, one pixel per clock, in raster order (left-to-right, top-to-bottom). Each foreground pixel gets assigned an integer **label** such that two pixels sharing a label are part of the same connected blob (8-connected: horizontal, vertical, and diagonal neighbours all count). While labels are being assigned, the module maintains a running bounding box (min/max x, min/max y) and a pixel count per label. At end-of-frame — during the vertical-blanking interval, when no pixels are arriving — it resolves any label **equivalences** that piled up during labeling, merges the per-label stats accordingly, picks the top-`N_OUT` largest blobs above a minimum-size threshold, and publishes their bounding boxes on a sideband. Because the resolve runs in vblank, the bboxes for frame N become visible at the start of frame N+1 — a one-frame lag is architectural (§7).

#### Glossary

| Term | Meaning in this module |
|------|------------------------|
| **Label** | A small positive integer ID (`1..N_LABELS_INT-1`) assigned to a foreground pixel. Pixels belonging to the same blob should eventually share one label. Label 0 means background (or overflow — §4.4). |
| **Equivalence** | A recorded statement "label A and label B are really the same blob." Stored as `equiv[A] = B` (with A > B by convention). Discovered mid-frame when a pixel's neighbourhood contains two distinct non-zero labels. |
| **Root** (canonical root) | The smallest label in an equivalence chain — the one whose accumulator ends up holding the whole blob. A label `L` is its own root when `equiv[L] == L`. |
| **Chain** | A sequence `equiv[L1]=L2, equiv[L2]=L3, …` that can form when merges happen in an order that doesn't flatten the table in one step. Chains are unavoidable with a 1-write-per-pixel budget (§4.3). |
| **Chase** | Walking `equiv[]` from a label until you reach a root (a fixed point, `equiv[x]==x`). Done in Phase A, bounded by `MAX_CHAIN_DEPTH` to keep the cycle budget finite. |
| **Path compression** | After a chase finds the root, overwriting `equiv[L] ← root` so the next chase from `L` terminates in one step. Phase A performs this. |
| **Accumulator** | The per-label running stats (`acc_min_x[L]`, `acc_max_x[L]`, `acc_min_y[L]`, `acc_max_y[L]`, `acc_count[L]`) — effectively a bbox-in-progress. Updated once per accepted foreground pixel. |
| **Sentinel** | The initial value of each accumulator field, chosen so the first foreground pixel automatically wins the min/max comparator. `min_*` sentinels are set to the maximum possible coordinate; `max_*` sentinels are set to 0; `count` starts at 0. |
| **Fold** | At EOF, copying a non-root label's accumulator into its root's accumulator (element-wise min/min/max/max/sum) and zeroing the non-root. Phase B does this. |
| **Prime frames** | The first `PRIME_FRAMES` frames after reset, during which the module computes bboxes internally but hides them (the front buffer stays empty). `axis_motion_detect`'s EMA background starts at zero, so early frames read as mostly-foreground and would produce huge spurious bboxes; suppressing output until the EMA has converged avoids that. See §6.6. |

#### Storage model

State maintained during a frame, by size:

| Structure | Indexed by | Width | Purpose |
|---|---|---|---|
| `line_buf` | column (`0..H_ACTIVE-1`) | `LABEL_W` bits | **One-row-deep** rolling label history. Holds the previous row's labels to the right of the scan position (source of `NW / N / NE`) and the current row's labels to the left (the `W` neighbour itself is kept in a separate register for timing). |
| `equiv[]` | label (`0..N_LABELS_INT-1`) | `LABEL_W` bits | Global equivalence table. `equiv[L]` is the label `L` has been recorded equivalent to. Updated in-frame on merges; chased and flattened at EOF by Phase A. |
| `acc_min_x`, `acc_max_x`, `acc_min_y`, `acc_max_y`, `acc_count` | label | coordinate / count | Per-label running bbox and pixel count — the bbox-in-progress for each label. |
| `next_free` | (scalar) | `LABEL_W+1` bits | Next label to allocate; saturates at `N_LABELS_INT` (overflow, §4.4). |
| Pipeline registers | — | few bits each | `line_rd_data_r`, `shift_n`, `shift_nw`, `w_label`, and stage-1 payload registers (§5.1). |
| Output double-buffer | slot (`0..N_OUT-1`) | `1 + 2·COL_W + 2·ROW_W` | `front_*` visible on the output ports; `back_*` written by Phase C. Swapped atomically at `PHASE_SWAP` (§6.6). |

**No full-frame label image is stored.** Full CCL conceptually labels every pixel, but at EOF all we want is bboxes. Bboxes are a *reduction* (min/max/count) that can be maintained incrementally, so we never need to store per-pixel labels past the one-row window needed to compute neighbours. Each pixel's label lives in `line_buf` only until the next row overwrites it. Once a row has passed, the only surviving trace of its labels is the contribution already aggregated into `acc_*[]`. This is what keeps the datapath in a few kb of distributed RAM instead of the ~460 kb a per-pixel label array would cost (`H_ACTIVE · V_ACTIVE · LABEL_W` bits at defaults). Everything at EOF — Phases A–D and the `N_OUT` bboxes — is computed from `equiv[]` and `acc_*[]` alone.

#### How it works, walked through

**Per-pixel (active region).** For every foreground mask pixel at `(row, col)`, the module examines the four already-labeled 8-connected neighbours that have already been processed — NW, N, NE from the previous row, and W to the immediate left:

```
   NW  N  NE
    W  *
```

Four cases:
- **All four are background** → start a new component: allocate a fresh label from `next_free`.
- **Exactly one non-zero label appears** (anywhere in the window) → inherit it.
- **Two distinct non-zero labels appear** → the current foreground pixel is adjacent to both, so the two labels must describe the same blob. The pixel takes the smaller of the two, and we record `equiv[larger] = smaller`. Those two labels will be folded at EOF. (§4.2 shows that two is the *most* distinct non-zero labels the window can ever hold, which is why one `equiv[]` write per pixel is sufficient.)
- Three-or-four matching neighbours is just a sub-case of the single-label path.

*Local vs. global.* Two separate things happen on a merge: the current pixel is given the label `smaller` and that label is stored in `line_buf[col_d1]` (a **per-pixel** write, touching only this one field); and `equiv[larger] = smaller` is written to the **global** equivalence table (a single table shared across the whole frame). Earlier-row pixels that were already stored as `larger` are *not* rewritten — they keep their stored label, and the `equiv[]` entry carries the "these two labels describe one blob" fact forward to EOF. Phase A then chases `equiv[larger]` to a root and Phase B folds `acc[larger]` into `acc[root]`, which is how the earlier-row pixels' contributions end up accounted for under the canonical label.

A raster-order invariant guarantees `{NW, N, NE, W}` can hold at most *two* distinct non-zero labels — see §4.2. That is what lets us get away with a single `equiv[]` write per pixel.

**Example: a U-shape that only merges at the bottom.**

```
    col:   0  1  2  3  4
  row 0:   .  X  .  X  .     new label 1 at (0,1); new label 2 at (0,3)
  row 1:   .  X  .  X  .     inherit 1 at (1,1); inherit 2 at (1,3)
  row 2:   .  X  .  X  .     inherit 1 at (2,1); inherit 2 at (2,3)
  row 3:   .  X  X  X  .     at (3,1): N=1 → label 1
                              at (3,2): W=1, NE=2 → pick=1, record equiv[2]=1
                              at (3,3): W=1, N=2  → pick=1 (equiv[2]=1 already set)

  Labels as stored (just before EOF):
           .  1  .  2  .
           .  1  .  2  .
           .  1  .  2  .
           .  1  1  1  .

  equiv[] at EOF:    equiv[1]=1 (root), equiv[2]=1   (label 2 resolves to label 1)
  acc_count at EOF:  [_, 5, 3, 0, …]                (label 1 owns 5 px, label 2 owns 3 px)

  Phase A (compress):  both entries already point at a root → no change.
  Phase B (fold):      acc[1] ← merge(acc[1], acc[2]); acc_count[2] ← 0.
  Phase C (top-N):     label 1 survives with count=8; bbox = cols 1..3, rows 0..3.
```

**At end-of-frame (vblank).** Four FSM phases run back-to-back, then a swap:
1. **Phase A — path compression.** For each label, chase `equiv[]` until a root is hit, then overwrite `equiv[L]` with that root. Every label now points directly at its root.
2. **Phase B — fold.** For each non-root label with a non-zero pixel count, add its accumulator to its root's accumulator and clear the non-root.
3. **Phase C — top-N selection.** Scan every label's pixel count, reject anything below `MIN_COMPONENT_PIXELS`, pick the top `N_OUT` by count, write survivors into the back buffer.
4. **Phase D — reset.** Restore `equiv[L] ← L` and all accumulators to their sentinels, ready for the next frame. `PHASE_SWAP` then copies back → front (except during prime frames) and pulses `bbox_swap_o`.

While this FSM runs, `s_axis.tready` is deasserted: upstream pixels wait until the module is back in `PHASE_IDLE`.

#### Frame lifecycle at a glance

```
   ┌──────────── active region ────────────┐┌── vblank ───┐┌──── next active ────
   │ label + accumulate, 1 pix/cycle       ││ A→B→C→D→SWAP││ (bboxes for previous
   │   tready = 1                          ││ tready = 0  ││  frame now visible)
   └───────────────────────────────────────┘└─────────────┘└──────────────────────
                                                  │        ▲
                                                  │        └── bbox_swap_o pulses
                                                  │            (front buffer now
                                                  │             holds frame-N bboxes)
                                                  │
                                                  └── EOF FSM: ~1,280 cycles worst
                                                      case (§6.7). Vblank headroom
                                                      ~5× in the TB, ~100× at real
                                                      VGA 640×480@60 Hz.
```

Consequence: bboxes describing frame N are painted onto frame N+1's pixels. See §7 for the full latency breakdown.

### 4.1 Streaming union-find

Classical raster CCL makes two passes over the image: one to assign provisional labels while recording label equivalences, and a second to relabel everything to canonical roots. We stream: per-pixel labeling happens in one raster pass as pixels arrive; equivalence resolution happens in the vblank window between the last pixel of frame N and the first pixel of frame N+1.

For each foreground mask pixel at `(r, c)`, we examine the four already-labeled 8-connected neighbours from the previous row and the left-adjacent column in the current row:

```
 NW  N  NE
  W  *
```

If all four are background the pixel starts a new component (`next_free` allocation). If exactly one non-zero label appears, the pixel inherits it. If two distinct non-zero labels appear, the pixel joins the smaller one (`pick = min`) and we record `equiv[max] = min` so the fold phase later merges the two components.

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

For each accepted mask beat, the datapath does three things:

1. **Assemble neighbours.** Gather `{NW, N, NE, W}` for the current pixel; mask border positions to 0.
2. **Compute the label.** Combinational logic over those four neighbours produces `pick` and, on a 2-label merge, `need_merge / merge_hi / merge_lo`.
3. **Issue writes.** Update `line_buf` with `pick`; on a foreground pixel, update `equiv[]`, `acc_*[]`, `next_free`, and `w_label`.

**How the three neighbours arrive together.** `line_buf` has a registered read (1-cycle latency) and only one read port, but the label decision needs `NW`, `N`, and `NE` on the same cycle. The read address is issued one column ahead of the current scan position, and the registered result feeds a 2-deep shift register. On each cycle: `line_rd_data_r = NE`, `shift_n = N`, `shift_nw = NW` — all three available at once. The `W` neighbour is the label just written for the previous pixel, held in `w_label`.

**Active only during `PHASE_IDLE`.** During the EOF FSM, `s_axis.tready = 0` blocks new beats from arriving, and per-pixel writes to `equiv[]`, `acc_*[]`, and `next_free` are additionally gated on `phase == PHASE_IDLE`. The FSM has exclusive access to that state during vblank.

**Dataflow.**

```
   col ──► +1 (wrap) ──► line_buf[rd] ──► line_rd_data_r ──► shift_n ──► shift_nw    ← §5.2, §5.3
                          (1R1W RAM)          (NE)            (N)         (NW)

                                                  w_label   (W)
                                                      │
                                                      ▼
                                        ┌────────── edge-mask ───────────┐  ← §5.4
                                        │   4 muxes, one per neighbour   │ ◄─ at_col0
                                        │   border → 0, else pass-thru   │ ◄─ at_row0
                                        │                                │ ◄─ at_colmax
                                        └───────────────┬────────────────┘
                                                        │ nb_nw / nb_n / nb_ne / nb_w
                                                        ▼
                                        ┌────────── label decision ──────┐  ← §5.5
                                        │  (a) all bg   → pick = new     │ ◄─ next_free
                                        │  (b) one lbl  → pick = that    │
                                        │  (c) two lbls → pick = min;    │
                                        │                 need_merge=1   │
                                        └───────────────┬────────────────┘
                                                        │ pick, need_merge,
                                                        │ merge_hi, merge_lo
                                                        ▼
                                        ┌────────── writes (if accept) ──┐  ← §5.6
                                        │  line_buf[col_d1] ← pick or 0  │
                                        │  w_label          ← pick or 0  │
                                        │                                │
                                        │  equiv[merge_hi] ← merge_lo    │
                                        │                  (if merge)    │
                                        │                                │
                                        │  acc_*[pick] ← RMW min/max/cnt │  ← RMW = read-modify-write
                                        │  next_free   ← +1 (if new lbl) │
                                        └────────────────────────────────┘
```

For per-memory detail — counters and SOF handling (`col_d1 / row_d1` reset on `tuser`), line buffer organisation, edge-mask conditions, label-decision arithmetic, accumulator sentinels — see §5.2 through §5.7.

### 5.2 Row/column counters and SOF handling

`col` and `row` track the scan position of incoming beats. On `s_axis_tuser_i` they reset to `(col=1, row=0)` — the next cycle will be col 1, since the tuser cycle itself consumed col 0. On `s_axis_tlast_i` `col` resets to 0 and `row` increments.

The stage-1 shadow `col_d1`/`row_d1` must match the **logical** position of the tuser pixel (0, 0), not the pre-reset counter values held over from the previous frame's tlast (which sit at `col=0, row=V_ACTIVE`). The stage-1 pipeline register forces `col_d1 <= '0, row_d1 <= '0` whenever `s_axis_tuser_i` is observed at stage 0:

```systemverilog
col_d1 <= s_axis_tuser_i ? '0 : col;
row_d1 <= s_axis_tuser_i ? '0 : row;
```

Without this override, the first foreground pixel of a frame would get wrongly accumulated at `row=V_ACTIVE` (one past the last valid row) — producing rogue bboxes with `max_y = V_ACTIVE`.

### 5.3 Label line buffer and 2-deep shift chain

`line_buf` is a distributed LUT-RAM of depth `H_ACTIVE`, width `LABEL_W`. It holds the labels assigned to the previous row so the current row can read `{NW, N, NE}` without a second pass.

The read address is issued one column ahead of the scan position so that after the registered read, `line_rd_data_r` is aligned with `NE` for the stage-1 window. A 2-deep register shift chain `(shift_n, shift_nw)` converts that one-ahead tap into three successive taps across consecutive cycles:

```
cycle t   :  line_rd_data_r  = line_buf[col_d1 + 1]   → NE
cycle t+1 :  shift_n         = (previous cycle's line_rd_data_r) → N
cycle t+2 :  shift_nw        = (previous cycle's shift_n)        → NW
```

At steady state the three values for the column being processed arrive synchronously. The shift chain advances on `accept_d1` (stage-1 beat valid), so stalls or idle cycles do not desync it.

### 5.4 Edge masking for NW/N/NE/W

Off-image neighbours are forced to background (label 0) combinationally, not stored. There is no explicit border row in `line_buf`:

| Neighbour | Masked to 0 when |
|-----------|-----------------|
| `nb_nw` | `col_d1 == 0` or `row_d1 == 0` |
| `nb_n` | `row_d1 == 0` |
| `nb_ne` | `col_d1 == H_ACTIVE - 1` or `row_d1 == 0` |
| `nb_w` | `col_d1 == 0` |

`line_buf` is not explicitly cleared between frames. Row 0 reads are masked out combinationally (`at_row0` forces `nb_nw/nb_n/nb_ne` to 0), so stale contents don't matter; writes during row 0 then re-fill the buffer before row 1 starts reading.

### 5.5 Label decision

Combinational logic computes `pick_label`, `need_merge`, `merge_hi`, and `merge_lo` from the 4 edge-masked neighbours:

```
any_above   = |{nb_nw, nb_n, nb_ne} ≠ 0
min_above   = min(nb_nw, nb_n, nb_ne), treating 0 as absent
any_nonzero = any_above || (nb_w ≠ 0)

if !any_nonzero:                 pick = next_free, or 0 on overflow   // pick       : label to assign to current pixel
else if !any_above:              pick = nb_w                          //              (written to line_buf, w_label, indexes acc_*)
else if nb_w == 0:               pick = min_above
else if nb_w == min_above:       pick = nb_w                    (single label, no merge)
else:                            pick = min(nb_w, min_above)
                                 need_merge = 1                       // need_merge : two distinct labels seen — record equivalence
                                 merge_hi   = max(nb_w, min_above)    // merge_hi   : larger label (equiv[] key, child in union-find)
                                 merge_lo   = min(nb_w, min_above)    // merge_lo   : smaller label (equiv[] value, parent/root)
```

`min_above` is computed as a chain of three comparators (not a parameterized `min`-reduction). Since `{nb_nw, nb_n, nb_ne}` can contribute at most one non-zero label (invariant §4.2), the particular tie-breaking order between them is irrelevant — at least two of the three inputs are 0 whenever any foreground is present.

### 5.6 Per-pixel writes

All per-pixel writes are conditioned on a foreground beat (`write_fg = accept_d1 && tdata_d1`) AND `phase == PHASE_IDLE`, except for `line_buf` and `w_label` which update on any accepted beat.

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

The four `acc_min_*` / `acc_max_*` rows are implemented as gated conditional writes (e.g. write only if `col_d1 < acc_min_x[pick]`); the `min`/`max` notation in the table describes the functional result. Sentinels in §5.7 ensure the first foreground pixel always wins the comparator.

`line_buf` is always written on an accepted beat (even if the pixel is background), so the prior row's label at `col_d1` is overwritten with 0 when the current pixel is background. This keeps the line buffer representing the most recent row without a separate clear pass.

### 5.7 Accumulator bank

Five parallel distributed-RAM arrays, each indexed by label (`0..N_LABELS_INT-1`):

| Array | Width | Sentinel after reset / PHASE_D |
|-------|-------|-------------------------------|
| `acc_min_x` | `COL_W` | `H_ACTIVE - 1` |
| `acc_max_x` | `COL_W` | 0 |
| `acc_min_y` | `ROW_W` | `V_ACTIVE - 1` |
| `acc_max_y` | `ROW_W` | 0 |
| `acc_count` | `COUNT_W = ⌈log2(H·V+1)⌉` | 0 |

Sentinels ensure the first foreground pixel always wins the `<`/`>` comparators. An accumulator with `count == 0` after Phase B is either untouched (background-only label) or a non-root that has been folded into its root (explicitly cleared by the fold logic).

### 5.8 Output double-buffer

**Why two buffers.** The overlay consumer reads the `N_OUT` slots continuously throughout the active region (every pixel checks "am I on the border of any valid bbox?"). If Phase C wrote directly to the visible buffer, the overlay would see a mix of new and old slots as Phase C walks through them, producing a torn frame with mixed-generation rectangles. Double-buffering decouples the two sides: Phase C writes `back_*` at its own pace during vblank; the overlay reads the stable `front_*` from the previous frame. The swap happens during vblank, when the overlay is inactive anyway, so the transition is never observed mid-rectangle.

Two independent register banks: `front_*` (visible on the ports) and `back_*` (written by Phase C). At PHASE_SWAP, `front_* <= back_*` is a bulk register-to-register copy (not a memory op), so the swap is a single-cycle atomic transition from the consumer's perspective. `bbox_swap_o` is a 1-cycle strobe on the swap cycle.

Each bank is a family of 5 `N_OUT`-entry arrays — one entry per bbox slot:

| Field | Per-slot width | Role |
|-------|----------------|------|
| `*_valid` | 1 | slot occupied |
| `*_min_x` | `COL_W` | left edge |
| `*_max_x` | `COL_W` | right edge |
| `*_min_y` | `ROW_W` | top edge |
| `*_max_y` | `ROW_W` | bottom edge |

`front_*` is driven onto the `bboxes` interface output (per-slot `{valid, min_x, max_x, min_y, max_y}` arrays). 
`back_*` is Phase C's scratch space.

`back_valid` is cleared at the end of PHASE_SWAP so PHASE_C of the *next* frame starts from an empty slate (slots it does not fill stay de-asserted).

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

*Detects the last pixel of the active region and triggers the vblank FSM.*

```
is_eof   = accept_d1 && tlast_d1 && (row_d1 == V_ACTIVE - 1)
is_eof_r = register(is_eof)    // 1-cycle delay so last-pixel acc write has committed
```

`is_eof_r` drives PHASE_IDLE → PHASE_A. The 1-cycle delay between `is_eof` and entering Phase A gives the last pixel's accumulator RMW (scheduled on the same cycle as `is_eof`) time to land before Phase A reads start.

### 6.2 Phase A — path compression

*Rewrites each `equiv[L]` to point directly at its root, so Phase B can fold in one hop.*

For each label `L = 1..N_LABELS_INT-1`:

```
chase_root ← L
chase_cnt  ← 0
while equiv[chase_root] ≠ chase_root and chase_cnt < MAX_CHAIN_DEPTH:
    chase_root ← equiv[chase_root]
    chase_cnt  ← chase_cnt + 1
equiv[L] ← chase_root
```

Implemented as two states: `PHASE_A` seeds the chase, `PHASE_A_CHASE` advances one step per cycle. When the chase terminates (fixpoint or depth bound), the current label's entry is overwritten with the discovered root and we either advance to the next label or drop into Phase B.

Bounded by `MAX_CHAIN_DEPTH = 8`, which is well above the chain depth observed on natural masks. Pathological masks with deeper chains leave tail labels orphaned; their pixels survive Phase C on their own or are dropped by the min-size filter.

### 6.3 Phase B — accumulator fold

*Merges each non-root's accumulator into its root and clears the non-root.*

For each label `L` with `equiv[L] ≠ L` and `acc_count[L] ≠ 0`:

```
cycle 1 (sample):   fold_src ← acc[L]         (snapshot)
                    fold_dst_lbl ← equiv[L]
                    fold_wr_pending ← 1
cycle 2 (commit):   acc[equiv[L]] ← merge(acc[equiv[L]], fold_src)
                    acc_count[L]  ← 0
                    fold_wr_pending ← 0
                    advance L
```

Where:
- `fold_src` — snapshot of the non-root's accumulator tuple `(min_x, max_x, min_y, max_y, count)`, taken on cycle 1 so cycle 2 can read a different address without a structural hazard.
- `fold_dst_lbl` — the root label that will absorb `fold_src`. Equals `equiv[L]` after Phase A (path compression guarantees all non-roots point directly to their root, so this is one read, no chase).
- `fold_wr_pending` — 1-cycle flag marking "cycle 1 captured, commit the write on cycle 2".

Two cycles per fold candidate covers the 1R1W latency of the distributed-RAM-style accumulator arrays. Non-folded labels (roots, or non-roots with count=0) advance in a single cycle.

### 6.4 Phase C — min-size filter + top-N selection

*Drops components below `MIN_COMPONENT_PIXELS` and writes the largest `N_OUT` survivors into `back_*`.*

For each output slot `s = 0..N_OUT-1`:

```
best_count ← 0
best_lbl   ← 0
for L = 0..N_LABELS_INT-1:
    if acc_count[L] ≥ MIN_COMPONENT_PIXELS and acc_count[L] > best_count:
        best_count ← acc_count[L]
        best_lbl   ← L
if best_count ≥ MIN_COMPONENT_PIXELS:
    back[s] ← acc[best_lbl]; back_valid[s] ← 1
    acc_count[best_lbl] ← 0       # consumed, excluded from next slot's scan
else:
    back_valid[s] ← 0
```

Implemented as a per-slot inner loop over all labels (one label per cycle). The terminal cycle (`scan_idx == N_LABELS_INT - 1`) must evaluate the current candidate *and* commit — the running best is registered and only visible on the following cycle, but there is no following cycle for that slot. A block-local `eff_best_count`/`eff_best_lbl` capture the current-cycle-effective value for the commit.

Note: Label 0 is scanned — overflow-pooled pixels can produce a catch-all bbox if they exceed `MIN_COMPONENT_PIXELS`. This is the documented overflow behaviour (§4.4).

### 6.5 Phase D — reset for next frame

*Restores `equiv[]` and all accumulators to their sentinel values so the next frame starts clean.*

Walks `L = 0..N_LABELS_INT-1`, restoring each row to the sentinel state described in §5.7. After the last label, `next_free ← 1` and PHASE_D → PHASE_SWAP.

### 6.6 PHASE_SWAP — front-buffer commit + priming

*Atomically copies `back_* → front_*` (except during the prime window) and pulses `bbox_swap_o`.*

```
if prime_cnt ≥ PRIME_FRAMES:
    front_* ← back_*
else:
    prime_cnt ← prime_cnt + 1
back_valid ← 0
bbox_swap_o ← 1      (1-cycle pulse)
phase ← PHASE_IDLE
```

During the priming window, back-buffer data is computed and then *discarded* — the front buffer stays all-invalid so the overlay draws no rectangles. `bbox_swap_o` still pulses, so downstream consumers see a consistent "new frame ready, contents empty" handshake.

*Why this exists.* `axis_motion_detect`'s EMA background model starts at zero. On frame 0 every pixel differs maximally from the (empty) background, so the mask is mostly foreground and CCL would report one or more frame-filling bboxes — an obvious visual artifact. The EMA converges within `~1/ALPHA` frames; with the default `ALPHA_SHIFT=2` (α=1/4), two frames is enough to suppress the worst of it.

### 6.7 Cycle budget

| Phase | Cycles | Notes |
|-------|--------|-------|
| A (path compression) | `N_LABELS × (MAX_CHAIN_DEPTH + 1)` worst case | 64 × 9 = 576 |
| B (fold) | `N_LABELS × 2` worst case | 128 |
| C (top-N) | `N_OUT × N_LABELS` | 8 × 64 = 512 |
| D (reset) | `N_LABELS` | 64 |
| SWAP | 1 | — |
| **Total** | — | **~1,280 worst case** |

Vblank at real VGA 640×480 @ 60 Hz on a 100 MHz DSP clock is ~144 kcycles — ~100× headroom.

This headroom is a **correctness** constraint, not just a throughput one: the per-pixel writes to `equiv[]`, `acc_*[]`, and `next_free` are gated on `phase == PHASE_IDLE`. If a pixel is accepted while the FSM is still in any of `PHASE_A..PHASE_SWAP`, its label/accumulator update is silently dropped, while `line_buf`, `w_label`, and `col`/`row` still advance — corrupting the labeling state when streaming resumes. The RTL defends against this two ways: (a) `s_axis.tready = (phase == PHASE_IDLE)` structurally back-pressures the upstream for the FSM duration; (b) an SVA `assert_no_accept_during_eof_fsm` traps any handshake during the FSM. Integrating designs must still size the inter-frame idle window to exceed the cycle budget above, since the FIFOs in front of `axis_ccl` have finite depth.

---

## 7. Timing

**Three latency regimes.** (1) *Stream path:* zero. `axis_ccl` is effectively a sink on its AXIS port — it does not forward pixels. The RGB path that the overlay ultimately draws onto has its own pipeline and is unaffected by this module. (2) *Sideband produce-time:* ~1,280 cycles worst case from the last mask pixel of a frame to the `bbox_swap_o` pulse (§6.7), fitting comfortably inside a single vblank. (3) *Frame-level:* **one frame.** The bboxes describing frame N become visible only at the start of frame N+1, because `PHASE_SWAP` runs in the vblank between them. During the first `PRIME_FRAMES` frames after reset the front buffer stays empty (§6.6), so real bboxes are first observable on frame `PRIME_FRAMES + 1` — overlay sees no rectangles before then.

| Operation | Latency |
|-----------|---------|
| `s_axis_tvalid_i` → accumulator RMW (first foreground pixel of frame) | 2 cycles (stage 0 → stage 1) |
| Last mask pixel of frame → `bbox_swap_o` pulse | ~1,280 cycles worst case (see §6.7) |
| `bbox_swap_o` pulse → `bboxes` updated | 0 cycles (`bbox_swap_o` fires on the same cycle the front buffer updates) |
| Steady-state mask throughput | 1 pixel / cycle |

`tready` is asserted whenever `phase == PHASE_IDLE` (the streaming phase). During `PHASE_A..PHASE_SWAP` (the EOF resolution FSM) `tready` is deasserted so in-flight pixels stall upstream rather than being silently misprocessed. See §6.7 for the cycle budget that determines the worst-case stall length.

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
