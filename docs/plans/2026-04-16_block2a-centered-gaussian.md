# Block 2a: Centered Gaussian Pre-Filter

**Parent:** [motion-pipeline-improvements.md](motion-pipeline-improvements.md) — see block 2 for kernel math, line buffer sizing, and placement analysis.
**Predecessor:** [old/2026-04-16_block2-gaussian-prefilter.md](old/2026-04-16_block2-gaussian-prefilter.md) — the causal (backward-looking) implementation now being replaced.

---

## Motivation

The current `axis_gauss3x3` uses a **causal (backward-looking)** window: for input pixel at scan position (r, c), the 3x3 kernel uses rows {r-2, r-1, r} and columns {c-2, c-1, c}. The kernel center (weight 4) lands on (r-1, c-1), not (r, c). This creates a 1-pixel diagonal spatial shift between the Gaussian output and the pixel address used for background comparison and EMA write-back.

Research of mainstream streaming-convolution implementations (MathWorks Vision HDL Toolbox, Xilinx Vitis Vision `Filter2D`/`Window2D`, georgeyhere/FPGA-Video-Processing, Kelvin Lin UW thesis) shows **all of them use true centered convolution**, accepting roughly `floor(K_h/2) = 1` line of initial fill latency. The causal approach appears only in simple tutorials (sistenix.com — our original reference) and is not a deliberate optimization. The 1-row fill latency is negligible in a video pipeline.

This plan replaces the causal Gaussian with a **true centered** variant. The convolution math is identical — the change is in pipeline timing and sideband alignment.

---

## Overview

### What changes

The existing convolution in `axis_gauss3x3` already computes a result centered at (r-1, c-1) when the input scan position is (r, c). The output IS a valid centered Gaussian — it's just labeled for the wrong pixel. The core insight:

> **The convolution math doesn't change. The pipeline alignment does.**

To produce a correctly-aligned centered output:

1. `PIPE_STAGES` in `axis_motion_detect` increases from **3** to **H_ACTIVE + 3** (323 at 320px) so that `idx_pipe[PIPE_STAGES-1]` carries the address of pixel (r-1, c-1) at the cycle its centered convolution result is produced.
2. The `idx_pipe` shift array grows with `PIPE_STAGES`; on Xilinx/Intel toolchains it synthesizes to **SRL-inferred shift registers** (SRL32 on Xilinx, equivalent on Intel). No BRAM FIFO or dual-read-port workaround is needed.
3. `axis_gauss3x3` extends its internal row/col counters by one (to `[0..V_ACTIVE]` × `[0..H_ACTIVE]`) so the right-edge and bottom-edge centered outputs can be produced. These phantom positions advance during **existing input blanking**, matching the MathWorks Vision HDL Toolbox approach (`floor(K_h/2)` lines of latency, drain during natural blanking gaps). A `busy_o` output exists as a fallback to stall upstream if blanking is absent.
4. The Python model simplifies (standard centered convolution, no causal offset).

### Why the alignment works

At any given cycle during steady-state, the centered Gaussian output for pixel P is produced H_ACTIVE + 1 valid cycles after P was input (1 row + 1 column of spatial offset), plus 2 cycles of combinational pipeline. With `PIPE_STAGES = H_ACTIVE + 3`:

- `idx_pipe[PIPE_STAGES-1]` at time T holds the address for the pixel input at T − (H_ACTIVE + 3), i.e., pixel P whose centered result is being emitted.
- `mem_rd_addr_o = idx_pipe[PIPE_STAGES-2]` (1 cycle before comparison) reads `bg[P]`, which arrives aligned with `y_smooth` for pixel P.

Both delays are identical, so `y_smooth` and `bg[P]` meet at the comparator on the same cycle. The existing pipeline algebra (`mem_rd_addr = idx_pipe[PIPE_STAGES-2]`, `mem_wr_addr = idx_pipe[PIPE_STAGES-1]`) remains valid — only the value of `PIPE_STAGES` changes.

Note: the RGB video path is no longer inside `axis_motion_detect` — it flows from `u_fork` directly to `u_overlay_bbox` at the top level, so no sideband RGB delay is needed here.

### Why blanking-based drain (not an internal FIFO)

The MathWorks Vision HDL Toolbox, which is the industry reference for HDL video, specifies for a `K_h × K_w` 2D filter:

- Latency = `floor(K_h/2)` lines (1 line for 3x3)
- Required horizontal blanking: `2 × K_w` cycles (6 for 3x3)
- Required vertical blanking: `K_h` lines (3 for 3x3)

Our TB already provides **H_BLANK = 16 cycles** and **V_BLANK = 6 lines** (`tb_sparevideo.sv`), well above the minimum. During blanking the upstream holds `valid_i = 0`; the gauss module can use those idle cycles to advance its internal row/col counters past the active-region edges and emit the remaining centered outputs (right column, bottom row) using edge-replicated window values. No internal FIFO is needed — the output stream simply contains the same H_ACTIVE × V_ACTIVE pixels, time-shifted by H_ACTIVE + 3 cycles.

A `busy_o` output stays in the interface as a fallback: if a future integration presents zero horizontal or vertical blanking, `busy_o` can deassert `s_axis_tready_o` for the 1 phantom cycle per row and the H_ACTIVE + 1 phantom cycles after the last row. In the current TB / VGA-timed integration, `busy_o` stays low.

### Resource cost (at 320×240)

| Resource | Causal (current) | Centered (proposed) | Delta |
|----------|-------------------|---------------------|-------|
| `idx_pipe` | 3 × 17 = 51 FFs | 323 × 17 bits as inferred SRLs ≈ **~170 LUTs** on Xilinx | +170 LUTs, −51 FFs |
| `valid_pipe` / `tlast_pipe` / `tuser_pipe` | 3 × 3 bits = 9 FFs | 3 bits × 323 stages ≈ **~30 LUTs** (SRLs) | +30 LUTs |
| `axis_gauss3x3` phantom-cycle counter + edge mux | — | ~20 FFs + combinational mux | +20 FFs |
| `axis_gauss3x3` output FIFO | — | — | 0 |
| **Total** | ~60 FFs | **~200 LUTs + ~20 FFs** | |

No BRAMs are added. On Xilinx 7-series (SRL32 primitives), 17 bits × 323 stages = ~170 LUTs; on Intel (SHIFTREG), similar density. The synthesis tool infers SRLs when the shift pattern has no reset on the data path — keep reset only on `valid_pipe` (already the case in the current code).

### Latency impact

| Metric | Causal | Centered |
|--------|--------|----------|
| First output pixel | Cycle 2 | Cycle H_ACTIVE + 3 (323) |
| Steady-state throughput | 1 pixel/cycle | 1 pixel/cycle (unchanged) |
| Phantom drain per row | 0 cycles | 1 cycle (absorbed in 16-cycle H_BLANK) |
| Phantom drain per frame (bottom row) | 0 cycles | H_ACTIVE + 1 cycles (absorbed in 6-line V_BLANK = 2016 cycles) |

The 323-cycle initial latency is ~3.2 µs at 100 MHz — invisible in a 60 fps pipeline (16.7 ms/frame). Per-row and per-frame phantom cycles fit entirely inside existing VGA blanking.

---

## RTL Changes

### File: `hw/ip/gauss3x3/rtl/axis_gauss3x3.sv` (modify)

The convolution core (line buffers, column shift registers, interior edge mux, adder tree) is **unchanged**. Changes:

#### 1. Extend internal scan to `[0..V_ACTIVE]` × `[0..H_ACTIVE]`

Widen `col` by 1 bit if needed so it can reach `H_ACTIVE` (one past the last real column). Similarly for `row` up to `V_ACTIVE`. The counters advance whenever an internal cycle is "consumed", which happens either when a real pixel is accepted (`valid_i && !stall_i`) OR during a phantom cycle (see §2).

#### 2. Phantom-cycle source (replaces the FSM-based flush in earlier draft)

A phantom cycle is a cycle where the module advances its internal pipeline **without consuming a real input pixel**. Phantom cycles are used exclusively to produce centered outputs for the last column of each row and the last row of the frame.

Per row: after real column `H_ACTIVE - 1` is consumed, one phantom cycle at `col = H_ACTIVE` is needed. Per frame: after the last real row, `H_ACTIVE + 1` phantom cycles at `row = V_ACTIVE` are needed (one full virtual row plus its trailing right-edge phantom).

Trigger logic:

```
phantom_needed = (col == H_ACTIVE - 1 && !stall_i && valid_i)   // after this beat, col=H_ACTIVE is the next step
              || (internal_col == H_ACTIVE && !stall_i)         // single phantom cycle at end of row
              || (internal_row == V_ACTIVE && !stall_i)         // whole virtual bottom row
```

During phantom cycles:

- The live input `y_i` is replaced by a replicated value (see §3).
- Line buffers are **not written** at `col = H_ACTIVE` (since there is no real input to store). During the phantom bottom row, `lb0_mem[c] <= lb1_mem[c]` cascade still runs so that consecutive frames start with the same semantic state (first frame's line buffers remain stale-but-ignored via existing top-row replication).
- The convolution output for the phantom cycle is a real centered output for the previous real pixel — it leaves the module via the normal `y_o` / `valid_o` path.

Phantom cycles are **executed during existing upstream blanking cycles**. When upstream holds `valid_i = 0` during blanking, the module is free to self-clock a phantom cycle (it still obeys `stall_i`). When upstream presents continuous `valid_i = 1` with no blanking, the module asserts `busy_o` (see §4) which the parent uses to deassert `s_axis_tready_o` for one cycle, creating the blanking window.

#### 3. Edge replication for bottom / right borders

Extend the combinational edge mux in the `win[][]` block with two new cases (in addition to the existing top / left replication):

| Condition | Override |
|-----------|----------|
| `row_d1 == V_ACTIVE - 1` | Bottom row of window replicated from middle row (existing LB behavior already provides this, confirm no change) |
| `row_d1 == V_ACTIVE` (phantom row) | Top and middle rows of window sourced from what was LB0/LB1 before entering phantom; bottom row replicated |
| `col_d1 == H_ACTIVE - 1` | Current column (`c`) replicated to the `c+1` position in the shift register on the next cycle |
| `col_d1 == H_ACTIVE` (phantom col) | Rightmost column of window replicated; shift register not advanced by new input |

The existing top / left replication (rows 0–1, cols 0–1) remains unchanged.

#### 4. Interface changes

| Signal | Change |
|--------|--------|
| `busy_o` | **New** output, 1 bit. Asserted for 1 cycle per row if the module needs to self-generate a horizontal phantom cycle under continuous input (no H-blank). Asserted for H_ACTIVE + 1 cycles after the last real row if no V-blank is available. In normal operation with the existing TB / VGA timing, this signal **stays low**. |
| `valid_o` | First valid output at cycle H_ACTIVE + 3 (was cycle 2). No other semantic change — still drives `y_o` one cycle after the adder tree. |

The `valid_i`, `sof_i`, `stall_i`, `y_i`, `y_o` interfaces are unchanged.

#### 5. SOF handling

On `sof_i`, internal `col` / `row` counters reset to 0. Any in-flight phantom cycles are cancelled (they were for the previous frame's trailing edge — losing them is acceptable because centered output for the final pixel of the previous frame is emitted within `V_BLANK`, well before the next `sof_i`).

#### 6. Update the RTL header comment

The existing [axis_gauss3x3.sv:18-22](../../hw/ip/gauss3x3/rtl/axis_gauss3x3.sv#L18-L22) describes the causal offset as the "standard" streaming pattern. Rewrite to cite MathWorks Vision HDL Toolbox (`floor(K_h/2)` lines of latency, edge padding with blanking) and Xilinx Vitis Vision `Filter2D`/`Window2D` as the reference convention.

---

### No changes to `axis_fork`

The top-level `axis_fork` (`u_fork`) is a zero-latency combinational broadcast. It does not participate in the pipeline delay — the fork passes RGB through immediately to both consumers. No changes are needed here.

---

### File: `hw/ip/motion/rtl/axis_motion_detect.sv` (modify)

#### 1. `GAUSS_LATENCY` and `PIPE_STAGES`

```systemverilog
localparam int GAUSS_LATENCY = (GAUSS_EN != 0) ? (H_ACTIVE + 2) : 0;
localparam int PIPE_STAGES   = 1 + GAUSS_LATENCY;  // 1 (rgb2ycrcb) + (H_ACTIVE + 2) (gauss)
```

When `GAUSS_EN=0`: `PIPE_STAGES = 1` (unchanged).
When `GAUSS_EN=1`: `PIPE_STAGES = H_ACTIVE + 3` (was 3).

#### 2. `idx_pipe` stays as a shift array — let synthesis infer SRLs

The current code at [axis_motion_detect.sv:130-140](../../hw/ip/motion/rtl/axis_motion_detect.sv#L130-L140) is already a clean shift-register pattern. At 323 stages × 17 bits, Vivado's SRL inference maps this to ~170 SRL32 LUTs on 7-series and equivalent primitives on Intel/Altera. **No BRAM FIFO, no dual-port workaround, no `idx_penult`/`idx_last` trailing registers.**

Inference requirement: the data path must have no reset. The existing code does reset `idx_pipe` inside `if (!rst_n_i)`, which prevents SRL inference. Split the reset so only `valid_pipe` / `tlast_pipe` / `tuser_pipe` carry reset; `idx_pipe` data is unreset (the invalid stages are ignored via the valid sideband anyway):

```systemverilog
always_ff @(posedge clk_i) begin
    if (!fork_stall) begin
        idx_pipe[0] <= pix_addr;
        for (int i = 1; i < PIPE_STAGES; i++)
            idx_pipe[i] <= idx_pipe[i-1];
    end
end
```

Confirm SRL inference by grepping the synth report for `SRL32` / `SRL16` primitives on `idx_pipe*`. If inference fails, the fallback is a small BRAM FIFO — but that complexity should not be pre-emptively added.

#### 3. Gaussian `busy_o` integration

In normal operation `busy_o` stays low and this path is inert. The integration is still wired up as a fallback:

```systemverilog
logic gauss_busy;
assign gauss_busy = (GAUSS_EN != 0) ? u_gauss.busy_o : 1'b0;

// Suppress input acceptance when gauss needs a phantom cycle
assign s_axis_tready_o = !gauss_busy && (!pipe_valid || m_axis_msk_tready_i);
```

This is straightforward since `axis_motion_detect` directly drives `s_axis_tready_o` (there is no internal fork that competes for this signal).

#### 4. Memory read/write timing

No change to the logic — the existing formulas are parameterized by `PIPE_STAGES`:

```systemverilog
// Read address: idx_pipe[PIPE_STAGES-2]
assign mem_rd_addr_o = ($bits(mem_rd_addr_o))'(RGN_BASE) +
                       (fork_stall ? pix_addr_hold : idx_pipe[PIPE_STAGES - 2]);

// Write address: idx_pipe[PIPE_STAGES-1]
mem_wr_addr_o <= ($bits(mem_wr_addr_o))'(RGN_BASE) + idx_pipe[PIPE_STAGES - 1];
```

#### 5. `pix_addr_hold` — no change in source

Still captures `idx_pipe[PIPE_STAGES-2]` on `!fork_stall`, matching the current stall-hold pattern.

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

#### New test: Impulse alignment (Test 7 — blocking for Phase 0)

**Purpose:** verify the `PIPE_STAGES = H_ACTIVE + 3` algebra before the rest of the plan is built on it.

**Stimulus:** A frame that is zero everywhere except a single non-zero pixel at a known interior position (e.g., (100, 150)).

**Expected:** The centered Gaussian places non-zero output at the 3x3 neighborhood of (100, 150). Exactly at (100, 150) the output is `4·impulse / 16`. Off by (±1, 0) or (0, ±1) is `2·impulse / 16`. Diagonals are `1·impulse / 16`. At all other positions, 0.

**Check:** Output at (100, 150) is the kernel-center value. If the causal bug were present, the center would appear at (101, 151) — the test distinguishes the two cases unambiguously.

#### New test: Bottom / right edge (Test 8)

**Stimulus:** Feed a 16×8 frame where the last row has distinct values (e.g., row 7 = 255, all others = 0).

**Expected:** Centered Gaussian for the last row uses edge-replicated row 8 (= row 7 values). Verify that the last-row outputs match the expected centered convolution with replicated bottom border.

**Check:** All output pixels including last row and last column are correct.

#### New test: Latency measurement (Test 9)

**Stimulus:** Feed a uniform frame with normal blanking, count cycles from first `valid_i` to first `valid_o`.

**Expected:** H_ACTIVE + 3 cycles (= 19 for H=16).

**Check:** Exact cycle count.

#### New test: No-blanking `busy_o` fallback (Test 10)

**Stimulus:** Feed a frame with `H_BLANK = 0` (continuous `valid_i`), confirm `busy_o` asserts at the expected cycles (row end, frame end) and data integrity is preserved.

**Check:** Output frame matches the centered golden model; no pixels lost; `busy_o` pulses match expected count (V_ACTIVE horizontal pulses + 1 vertical flush).

#### New test: Minimum-blanking compliance (Test 11)

**Stimulus:** Feed a frame with H_BLANK = 2·K_w = 6 cycles and V_BLANK = K_h = 3 lines (MathWorks-spec minimum), confirm `busy_o` stays low and data integrity is preserved.

#### Existing tests 1-6: Update expected values

All expected values change from causal to centered. The impulse response (test 2) center pixel now matches the impulse position, not (impulse_r - 1, impulse_c - 1).

### `hw/ip/motion/tb/tb_axis_motion_detect.sv` (modify)

The GAUSS_EN=1 golden model already uses a software Gaussian function. Update it to produce centered results (matching the new Python model). The GAUSS_EN=0 path is unchanged.

---

## Acceptance Criteria

### Must pass (blocking):

- [ ] **Phase 0: Impulse alignment test (Test 7)** — confirms `PIPE_STAGES = H_ACTIVE + 3` is correct before any motion-pipeline work is merged
- [ ] `make lint` — no new warnings
- [ ] `make test-ip` — all unit tests pass
  - `test-ip-gauss3x3`: tests 1-11 (updated golden models for centered convolution)
  - `test-ip-motion-detect`: GAUSS_EN=0 regression (unchanged)
  - `test-ip-motion-detect-gauss`: GAUSS_EN=1 with centered golden model
  - All other IP tests unchanged
- [ ] `make run-pipeline CTRL_FLOW=motion` at `TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=mask` at `TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=passthrough` at `TOLERANCE=0`
- [ ] Python model `_gauss3x3()` produces standard centered Gaussian (matches `scipy.ndimage` to within truncation)
- [ ] Phantom-cycle drain produces correct bottom / right border pixels (edge-replicated)
- [ ] Stall behavior correct under backpressure during both normal and phantom-cycle operation
- [ ] Back-to-back frames work correctly (SOF resets internal counters and in-flight phantom cycles)
- [ ] `busy_o` stays low during the standard TB / VGA-timed integration (normal blanking available)

### Should pass (non-blocking, verify manually):

- [ ] With `SOURCE="synthetic:noisy_moving_box"`, mask quality is comparable to causal version (1-pixel shift was negligible)
- [ ] SRL inference confirmed in synth report for `idx_pipe*` (no BRAM usage added)
- [ ] `make test-py` passes with updated model tests

---

## Integration Checklist

### Phase 0: Algebra sanity + Documentation (blocking)

- [ ] Implement and run Test 7 (impulse alignment) with a placeholder `PIPE_STAGES` value, empirically confirm the `H_ACTIVE + 3` formula before committing downstream work. If off-by-one, adjust and re-verify before proceeding.
- [ ] Update `docs/specs/axis_gauss3x3-arch.md` — remove causal offset sections, document centered semantics, phantom-cycle drain, blanking requirements, `busy_o` port, new latency
- [ ] Update `docs/specs/axis_motion_detect-arch.md` — update PIPE_STAGES calculation, timing table, note SRL inference for `idx_pipe`

### Phase 1: RTL — `axis_gauss3x3` changes

- [ ] Extend internal `col` / `row` counters to scan `[0..H_ACTIVE]` × `[0..V_ACTIVE]`
- [ ] Add phantom-cycle trigger logic (self-clock during upstream `valid_i=0` blanking; assert `busy_o` if no blanking available)
- [ ] Add bottom / right edge replication cases to the `win[][]` mux
- [ ] Gate line-buffer writes on real pixels only (no writes during phantom cycles)
- [ ] Add `busy_o` output
- [ ] Reset internal counters on `sof_i`
- [ ] Update file header comment to reference MathWorks / Xilinx Vitis instead of sistenix
- [ ] `make lint` passes

### Phase 2: RTL — `axis_motion_detect` changes

- [ ] Update `GAUSS_LATENCY` to `H_ACTIVE + 2`
- [ ] Remove reset from `idx_pipe` data path (keep reset on `valid_pipe` / `tlast_pipe` / `tuser_pipe`) to enable SRL inference
- [ ] Gate `s_axis_tready_o` with `!gauss_busy`
- [ ] `make lint` passes
- [ ] Confirm SRL inference in synth report (or document the BRAM fallback if inference fails)

### Phase 3: Testbenches

- [ ] Update `tb_axis_gauss3x3` golden model for centered convolution
- [ ] Add Test 7 (impulse alignment — Phase 0 blocker)
- [ ] Add Test 8 (bottom / right edge)
- [ ] Add Test 9 (latency measurement)
- [ ] Add Test 10 (no-blanking `busy_o` fallback)
- [ ] Add Test 11 (minimum-blanking compliance)
- [ ] Update `tb_axis_motion_detect` GAUSS_EN=1 golden model
- [ ] `make test-ip` all pass

### Phase 4: Python model + harness

- [ ] Simplify `_gauss3x3()` in `py/models/motion.py` (remove causal offset, use pad=1)
- [ ] Update `py/tests/test_models.py` expected values
- [ ] `make test-py` passes

### Phase 5: Full pipeline verification

- [ ] `make run-pipeline CTRL_FLOW=motion TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=mask TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=passthrough TOLERANCE=0`
- [ ] Verify all `CTRL_FLOW × GAUSS_EN × ALPHA_SHIFT` combinations at `TOLERANCE=0`

### Phase 6: Documentation updates (blocking — do not merge until complete)

- [ ] Update `README.md` if any user-visible options change
- [ ] Update `CLAUDE.md` if project structure changes
- [ ] Move this plan to `docs/plans/old/` with date stamp
- [ ] Update parent plan's sub-plans table

---

## References

Industry / academic streaming 2D convolution implementations that informed this plan:

- **MathWorks Vision HDL Toolbox** — `floor(K_h/2)` lines of latency, edge padding with blanking-based drain. Minimum blanking: 2·K_w cycles horizontal, K_h lines vertical. [visionhdl.ImageFilter](https://www.mathworks.com/help/visionhdl/ref/visionhdl.imagefilter-system-object.html), [Edge Padding](https://www.mathworks.com/help/visionhdl/ug/edge-padding.html), [Configure Blanking Intervals](https://www.mathworks.com/help/visionhdl/ug/configure-blanking-intervals.html)
- **Xilinx Vitis Vision `Filter2D` / `Window2D`** — line buffer depth `K_v-1`, window buffer, centered SOP. [2D Convolution Tutorial](https://xilinx.github.io/Vitis-Tutorials/2021-1/build/html/docs/Hardware_Acceleration/Design_Tutorials/01-convolution-tutorial/lab2_conv_filter_kernel_design.html)
- **georgeyhere/FPGA-Video-Processing** — fills three line buffers before streaming; output FIFO is CDC, not alignment. [GitHub](https://github.com/georgeyhere/FPGA-Video-Processing)
- **AMD/Xilinx UG949 — Coding Shift Registers and Delay Lines** — SRL inference guidance for deep shift registers without reset. [UG949](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Coding-Shift-Registers-and-Delay-Lines)
