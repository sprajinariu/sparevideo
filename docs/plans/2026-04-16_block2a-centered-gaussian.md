# Block 2a: Centered Gaussian Pre-Filter

**Parent:** [motion-pipeline-improvements.md](motion-pipeline-improvements.md) — see block 2 for kernel math, line buffer sizing, and placement analysis.
**Predecessor:** [old/2026-04-16_block2-gaussian-prefilter.md](old/2026-04-16_block2-gaussian-prefilter.md) — the causal (backward-looking) implementation now being replaced.

---

## Motivation

The current `axis_gauss3x3` uses a **causal (backward-looking)** window: for input pixel at scan position (r, c), the 3x3 kernel uses rows {r-2, r-1, r} and columns {c-2, c-1, c}. The kernel center (weight 4) lands on (r-1, c-1), not (r, c). This creates a 1-pixel diagonal spatial shift between the Gaussian output and the pixel address used for background comparison and EMA write-back.

Research of other FPGA implementations (Xilinx Vitis, georgeyhere/FPGA-Video-Processing, MathWorks Vision HDL, FPGA Lover, Gowtham1729, Kocaoglu) shows that **6 out of 8 streaming implementations use true centered convolution**, accepting ~1 row of initial fill latency. The causal approach appears only in simple tutorials (sistenix.com — our original reference) and is not a deliberate optimization. The 1-row fill latency is negligible in a video pipeline.

This plan replaces the causal Gaussian with a **true centered** variant. The convolution math is identical — the change is in pipeline timing and sideband alignment.

---

## Overview

### What changes

The existing convolution in `axis_gauss3x3` already computes a result centered at (r-1, c-1) when the input scan position is (r, c). The output IS a valid centered Gaussian — it's just labeled for the wrong pixel. The core insight:

> **The convolution math doesn't change. The pipeline alignment does.**

To produce a correctly-aligned centered output:
1. `PIPE_STAGES` increases from **3** to **H_ACTIVE + 3** (323 at 320px)
2. `idx_pipe` in `axis_motion_detect` grows to match (register array → **BRAM FIFO**)
3. `axis_gauss3x3` adds an internal **output FIFO** (depth H_ACTIVE + 1) and **flush logic** for bottom/right borders
4. The Python model simplifies (standard centered convolution, no causal offset)

### Why the alignment works

At any given cycle during steady-state, the Gaussian output is the centered result for the pixel that was input H_ACTIVE + 1 cycles earlier (1 row + 1 column). With `PIPE_STAGES = H_ACTIVE + 3`:

- **idx_pipe**: delayed by H_ACTIVE + 3 stages → the memory address for pixel P is available at the same time as `y_smooth` for pixel P
- **Memory read**: issued at `idx_pipe[PIPE_STAGES-2]` (1 cycle before comparison) → reads `bg[P]`, which arrives aligned with `y_smooth` for pixel P

Both delays are identical, so `y_smooth` and `bg[P]` meet at the comparator on the same cycle. The existing pipeline algebra (`mem_rd_addr = idx_pipe[PIPE_STAGES-2]`, `mem_wr_addr = idx_pipe[PIPE_STAGES-1]`) remains valid — only the value of `PIPE_STAGES` changes.

Note: the RGB video path is no longer inside `axis_motion_detect` — it flows from `u_fork` directly to `u_overlay_bbox` at the top level, so no sideband RGB delay is needed here.

### Resource cost (at 320×240)

| Resource | Causal (current) | Centered (proposed) | Delta |
|----------|-------------------|---------------------|-------|
| `idx_pipe` | 3 × 17 = 51 FFs | 323 × 17 bits = 687 bytes → **1 BRAM** | +1 BRAM, −51 FFs |
| `axis_gauss3x3` output FIFO | — | 321 × 8 bits = 321 bytes → **1 BRAM** (shared) | +0–1 BRAM |
| `axis_gauss3x3` flush logic | — | ~30 FFs + mux | +30 FFs |
| **Total** | ~51 FFs | **1–2 BRAMs** + ~30 FFs | |

At 320px, both FIFOs fit in 1–2 BRAM18K blocks (each is 18,432 bits = 2,304 bytes). This is a modest cost on any FPGA with >10 BRAMs. The sideband pipeline (`valid_pipe`, `tlast_pipe`, `tuser_pipe`) stays as a short FF shift register since it's only 3 bits × PIPE_STAGES at any depth — total ≤1 KB even at 323 stages.

### Latency impact

| Metric | Causal | Centered |
|--------|--------|----------|
| First output pixel | Cycle 2 | Cycle H_ACTIVE + 3 (323) |
| Steady-state throughput | 1 pixel/cycle | 1 pixel/cycle (unchanged) |
| Flush after last pixel | None | H_ACTIVE + 1 cycles (321) |
| Frame processing time | 76,800 cycles | 77,121 cycles (+0.4%) |

The 323-cycle initial latency is ~3.2 µs at 100 MHz — invisible in a 60fps pipeline (16.7 ms/frame). The flush fits easily in VGA blanking.

---

## RTL Changes

### File: `hw/ip/gauss3x3/rtl/axis_gauss3x3.sv` (modify)

The convolution core (line buffers, column shift registers, edge muxing, adder tree) is **unchanged**. Three additions:

#### 1. Output FIFO (depth H_ACTIVE + 1)

A simple dual-port BRAM circular buffer between the convolution output register and `y_o`:

```
conv_sum[11:4] ──► [output FIFO, depth H_ACTIVE+1] ──► y_o
```

- Write pointer advances on `!stall_i && valid_d2` (when convolution produces a result)
- Read pointer advances on `!stall_i` when FIFO is non-empty and the output stage accepts
- The FIFO introduces H_ACTIVE + 1 cycles of delay, re-aligning the output from "centered at (r-1, c-1)" to "centered at the pixel that was input H_ACTIVE + 1 cycles earlier"
- `valid_o` is driven from the FIFO read side (non-empty AND `!stall_i`)
- FIFO occupancy at steady state: H_ACTIVE + 1 entries (full pipeline)

**Implementation**: simple dual-port RAM (`logic [7:0] fifo_mem [H_ACTIVE+1]`) with `wr_ptr` / `rd_ptr` counters. No flow control complexity — the write and read rates are identical (1 pixel/cycle), and the FIFO depth exactly matches the steady-state occupancy.

#### 2. Flush state machine

After the last pixel of a frame (detected as `row == V_ACTIVE-1 && col == H_ACTIVE-1 && valid_i && !stall_i`), the module enters a flush state for H_ACTIVE + 1 cycles. During flush:

- `valid_i` from the parent is ignored (no new external input accepted)
- The module internally generates virtual pixels by **reading LB1** (which holds the last real row) at each column, feeding these as `y_i` to the convolution pipeline
- The last virtual pixel (column H_ACTIVE, one past the end) uses the value from column H_ACTIVE - 1 (rightmost pixel replication)
- The row counter advances to V_ACTIVE (virtual row), triggering bottom-row edge replication
- The convolution results enter the output FIFO, producing the remaining centered outputs for the last row and rightmost column
- A `flushing` flag is exposed to the parent via a new `busy_o` output

The flush pixel source:
```
flush cycle 0..H_ACTIVE-1:  y_flush = lb1_mem[flush_col]  (row V-1, replicated as row V)
flush cycle H_ACTIVE:        y_flush = lb1_mem[H_ACTIVE-1] (last pixel, col H replication)
```

During flush, the cascade write (`lb0_mem[c] <= lb1_mem[c]; lb1_mem[c] <= y_flush`) writes the same value back to `lb1_mem` (since `y_flush = lb1_mem[c]`), preserving the line buffer contents. No data corruption.

#### 3. Edge replication for bottom/right borders

Add two new cases to the edge mux in the combinational `win[][]` block:

| Condition | Override |
|-----------|----------|
| `row_d1 == V_ACTIVE - 1` (last real row) | Bottom row replicated from middle row |
| `row_d1 >= V_ACTIVE` (flush/virtual row) | Top and middle rows replicated from bottom row |
| `col_d1 == H_ACTIVE - 1` (last column) | `c` replicated to `c+1` position — but since we use backward-looking columns, this maps to: no override needed (the shift register at the last column already holds valid data) |
| During flush at `flush_col >= H_ACTIVE - 1` | Rightmost column replicated |

Note: the existing top/left replication (rows 0–1, cols 0–1) remains unchanged.

#### 4. Interface changes

| Signal | Change |
|--------|--------|
| `busy_o` | **New** output, 1 bit. Asserted during flush. Parent uses this to suppress new pixel acceptance. |
| `valid_o` | Now driven from FIFO read, not from `valid_d2` directly. First valid output at cycle H_ACTIVE + 3 (was cycle 2). |

The `valid_i`, `sof_i`, `stall_i`, `y_i`, `y_o` interfaces are unchanged.

#### 5. SOF handling

On `sof_i`, the FIFO write/read pointers reset. The flush state machine resets. This ensures clean frame boundaries.

---

### No changes to `axis_fork`

The top-level `axis_fork` (`u_fork`) is a zero-latency combinational broadcast. It does not participate in the pipeline delay — the fork passes RGB through immediately to both consumers. No changes are needed here.

---

### File: `hw/ip/motion/rtl/axis_motion_detect.sv` (modify)

#### 1. `GAUSS_LATENCY` and `PIPE_STAGES`

```systemverilog
localparam int GAUSS_LATENCY = (GAUSS_EN != 0) ? (H_ACTIVE + 2) : 0;
localparam int PIPE_STAGES   = 1 + GAUSS_LATENCY;  // 1 (rgb2ycrcb) + H_ACTIVE+2 (gauss)
```

When `GAUSS_EN=0`: `PIPE_STAGES = 1` (unchanged).
When `GAUSS_EN=1`: `PIPE_STAGES = H_ACTIVE + 3` (was 3).

#### 2. `idx_pipe` → BRAM FIFO

The current `idx_pipe` is a register array of `PIPE_STAGES` entries. At 323 entries × 17 bits = 5,491 bits, replace with a BRAM circular buffer:

```systemverilog
generate
    if (PIPE_STAGES > 16) begin : gen_idx_bram
        // BRAM FIFO: width = $clog2(H_ACTIVE * V_ACTIVE), depth = PIPE_STAGES
        // wr_ptr advances on !fork_stall, rd_ptr = wr_ptr - PIPE_STAGES
    end else begin : gen_idx_ff
        // Existing register array (unchanged)
    end
endgenerate
```

The read port provides `idx_pipe_rd[PIPE_STAGES-2]` and `idx_pipe_rd[PIPE_STAGES-1]` for memory read and write addresses. Since the BRAM only has one read port, use two separate BRAMs or a 2-read-port register file. Alternatively, read at `rd_ptr` (for `PIPE_STAGES-1`) and `rd_ptr + 1` (for `PIPE_STAGES-2`) — but these are simultaneous reads at different addresses.

**Simpler approach**: Use two small registers for the last 2 idx_pipe stages (for memory read and write addresses), and a BRAM FIFO for stages 0..PIPE_STAGES-3:

```
pix_addr ──► [BRAM FIFO, depth PIPE_STAGES-2] ──► idx_penult ──► idx_last
                                                    (register)    (register)
```

`idx_penult` feeds `mem_rd_addr_o`. `idx_last` feeds `mem_wr_addr_o`. This avoids dual-read BRAM.

#### 3. Gaussian `busy_o` integration

When `u_gauss.busy_o` is asserted (flush in progress):
- The pipeline continues advancing (draining valid data) — `pipe_stall` still governs this
- New pixel acceptance is suppressed: gate `s_axis_tready_o` with `!gauss_busy`
- The Gaussian's flush cycles feed internal convolution results into the output FIFO, which then drain through the normal pipeline path

```systemverilog
logic gauss_busy;
assign gauss_busy = (GAUSS_EN != 0) ? u_gauss.busy_o : 1'b0;

// Suppress input acceptance during Gaussian flush
assign s_axis_tready_o = !gauss_busy && (!pipe_valid || m_axis_msk_tready_i);
```

This is straightforward since `axis_motion_detect` directly drives `s_axis_tready_o` (there is no internal fork that competes for this signal).

#### 4. Memory read/write timing

No change to the logic — the existing formulas are parameterized by `PIPE_STAGES`:

```systemverilog
// Read address: idx_pipe[PIPE_STAGES-2] (now from idx_penult register)
assign mem_rd_addr_o = ($bits(mem_rd_addr_o))'(RGN_BASE) +
                       (fork_stall ? pix_addr_hold : idx_penult);

// Write address: idx_pipe[PIPE_STAGES-1] (now from idx_last register)
mem_wr_addr_o <= ($bits(mem_wr_addr_o))'(RGN_BASE) + idx_last;
```

#### 5. Stall hold for `pix_addr_hold`

```systemverilog
always_ff @(posedge clk_i) begin
    if (!rst_n_i)
        pix_addr_hold <= '0;
    else if (!fork_stall)
        pix_addr_hold <= idx_penult;  // was: mem_rd_idx
end
```

Same pattern, just sourced from the new `idx_penult` register.

---

### No changes to these files

| File | Reason |
|------|--------|
| `sparevideo_top.sv` | External interface of `axis_motion_detect` unchanged; `axis_fork` is already in place |
| `axis_fork.sv` | Zero-latency broadcast; no pipeline depth changes needed |
| `motion_core.sv` | Still receives `y_smooth` and `mem_rd_data_i` — unchanged |
| `rgb2ycrcb.sv` | Unchanged |
| `axis_bbox_reduce.sv` | Unchanged |
| `axis_overlay_bbox.sv` | Unchanged |
| `sparevideo_pkg.sv` | No new shared types |
| `ram.sv` | Unchanged |

---

## Python Model

### `py/models/motion.py` — simplify `_gauss3x3()`

The causal offset is removed. Replace with a standard centered convolution:

```python
def _gauss3x3(y_frame):
    """3x3 Gaussian blur matching RTL centered kernel [1 2 1; 2 4 2; 1 2 1] / 16.

    Uses border replication (np.pad with mode='edge') to match the RTL
    edge handling. Integer arithmetic with >>4 truncation, not floating-point.
    """
    padded = np.pad(y_frame, 1, mode='edge')  # replicate borders
    h, w = y_frame.shape

    result = np.zeros((h, w), dtype=np.uint16)
    for dr in range(3):
        for dc in range(3):
            weight = [1, 2, 1][dr] * [1, 2, 1][dc]
            result += weight * padded[dr:dr+h, dc:dc+w].astype(np.uint16)

    return (result >> 4).astype(np.uint8)
```

Key change: `np.pad(y_frame, 1, ...)` instead of `np.pad(y_frame, 2, ...)`, and the slicing window starts at `[dr:dr+h, dc:dc+w]` (standard centered, no spatial offset).

### `py/models/mask.py`

Same change — uses `_gauss3x3` from `motion.py`.

### `py/tests/test_models.py`

Update Gaussian model tests:
- Impulse response test: output centered at the impulse position (was offset by -1, -1)
- Border pixel tests: verify all 4 borders (top, bottom, left, right) produce correct replicated values

---

## SV Testbench Changes

### `hw/ip/gauss3x3/tb/tb_axis_gauss3x3.sv` (modify)

#### Golden model update

The TB's inline golden model must produce centered results. For a pixel at position (r, c), the expected output uses rows {r-1, r, r+1} and columns {c-1, c, c+1} with edge replication at all 4 borders.

#### New test: Flush behavior (Test 7)

**Stimulus:** Feed a 16×8 frame where the last row has distinct values (e.g., row 7 = 255, all others = 0).

**Expected:** The centered Gaussian for the last row uses edge-replicated row 8 (= row 7 values). Verify that the last-row outputs match the expected centered convolution with replicated bottom border.

**Check:** All output pixels including last row and last column are correct.

#### New test: Latency measurement (Test 8)

**Stimulus:** Feed a uniform frame and count cycles from first `valid_i` to first `valid_o`.

**Expected:** H_ACTIVE + 3 cycles (= 19 for H=16).

**Check:** Exact cycle count.

#### Existing tests 1-6: Update expected values

All expected values change from causal to centered. The impulse response (test 2) center pixel now matches the impulse position, not (impulse_r - 1, impulse_c - 1).

### `hw/ip/motion/tb/tb_axis_motion_detect.sv` (modify)

The GAUSS_EN=1 golden model already uses a software Gaussian function. Update it to produce centered results (matching the new Python model). The GAUSS_EN=0 path is unchanged.

---

## Acceptance Criteria

### Must pass (blocking):

- [ ] `make lint` — no new warnings
- [ ] `make test-ip` — all unit tests pass
  - `test-ip-gauss3x3`: tests 1-8 (updated golden models for centered convolution)
  - `test-ip-motion-detect`: GAUSS_EN=0 regression (unchanged)
  - `test-ip-motion-detect-gauss`: GAUSS_EN=1 with centered golden model
  - All other IP tests unchanged
- [ ] `make run-pipeline CTRL_FLOW=motion` at `TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=mask` at `TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=passthrough` at `TOLERANCE=0`
- [ ] Python model `_gauss3x3()` produces standard centered Gaussian (matches `scipy.ndimage` to within truncation)
- [ ] Flush produces correct bottom/right border pixels (edge-replicated)
- [ ] Stall behavior correct under backpressure during both normal and flush operation
- [ ] Back-to-back frames work correctly (SOF resets FIFO and flush state)

### Should pass (non-blocking, verify manually):

- [ ] With `SOURCE="synthetic:noisy_moving_box"`, mask quality is comparable to causal version (1-pixel shift was negligible)
- [ ] BRAM utilization matches estimate (2-3 BRAMs for sideband + idx + gauss FIFOs)
- [ ] `make test-py` passes with updated model tests

---

## Integration Checklist

### Phase 0: Documentation (blocking)

- [ ] Update `docs/specs/axis_gauss3x3-arch.md` — remove causal offset sections, document FIFO, flush, centered semantics, new latency, `busy_o` port
- [ ] Update `docs/specs/axis_motion_detect-arch.md` — update PIPE_STAGES calculation, timing table, BRAM FIFO for sideband/idx_pipe

### Phase 1: RTL — `axis_gauss3x3` changes

- [ ] Add output FIFO (BRAM circular buffer, depth H_ACTIVE + 1)
- [ ] Add flush state machine (detect EOF, generate H_ACTIVE + 1 replicated pixels)
- [ ] Add `busy_o` output
- [ ] Add bottom/right edge replication cases
- [ ] Update `valid_o` to drive from FIFO read side
- [ ] Reset FIFO and flush on `sof_i`
- [ ] `make lint` passes

### Phase 2: RTL — `axis_motion_detect` changes

- [ ] Update `GAUSS_LATENCY` to `H_ACTIVE + 2`
- [ ] Replace `idx_pipe` register array with BRAM FIFO + 2 trailing registers (`idx_penult`, `idx_last`)
- [ ] Gate `s_axis_tready_o` with `!gauss_busy` during flush
- [ ] Update `pix_addr_hold` source to `idx_penult`
- [ ] `make lint` passes

### Phase 4: Testbenches

- [ ] Update `tb_axis_gauss3x3` golden model for centered convolution
- [ ] Add Test 7 (flush / bottom-right border) and Test 8 (latency measurement)
- [ ] Update `tb_axis_motion_detect` GAUSS_EN=1 golden model
- [ ] `make test-ip` all pass

### Phase 5: Python model + harness

- [ ] Simplify `_gauss3x3()` in `py/models/motion.py` (remove causal offset, use pad=1)
- [ ] Update `py/tests/test_models.py` expected values
- [ ] `make test-py` passes

### Phase 6: Full pipeline verification

- [ ] `make run-pipeline CTRL_FLOW=motion TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=mask TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=passthrough TOLERANCE=0`
- [ ] Verify all `CTRL_FLOW × GAUSS_EN × ALPHA_SHIFT` combinations at `TOLERANCE=0`

### Phase 7: Documentation updates (blocking — do not merge until complete)

- [ ] Update `README.md` if any user-visible options change
- [ ] Update `CLAUDE.md` if project structure changes
- [ ] Move this plan to `docs/plans/old/` with date stamp
- [ ] Update parent plan's sub-plans table
