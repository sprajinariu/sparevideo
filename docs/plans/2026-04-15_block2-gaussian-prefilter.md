# Block 2: Gaussian Pre-Filter (3x3 on Y Channel)

**Parent:** [motion-pipeline-improvements.md](motion-pipeline-improvements.md) — see block 2 for architecture rationale, data flow, kernel math, line buffer sizing, and placement analysis.

---

## Overview

Add a 3x3 Gaussian blur on the Y (luma) channel inside `axis_motion_detect`, between the `rgb2ycrcb` output and the `motion_core` comparison. This reduces per-pixel sensor noise before thresholding, which directly reduces salt-and-pepper speckle in the motion mask.

The Gaussian is implemented as a new submodule `axis_gauss3x3` instantiated internally inside `axis_motion_detect` (the glue module). The external AXIS interfaces of `axis_motion_detect` are unchanged — `sparevideo_top` wiring does not change. The RGB passthrough carries the original sharp video (not the blurred image).

> **Note:** As of the `refactor/split-motion-detect-submodules` refactor,
> `axis_motion_detect` is a glue module that instantiates:
> - `axis_fork_pipe` (reusable 1-to-2 fork + sideband pipeline)
> - `rgb2ycrcb` (RGB → Y conversion)
> - `motion_core` (combinational: abs-diff threshold + EMA update)
>
> The Gaussian sits between `rgb2ycrcb` and `motion_core` — it replaces
> the `y_cur` signal wired to `motion_core.y_cur_i` with `y_smooth`.
> Fork-internal signals (`tvalid_pipe`, `tuser_pipe`) are not directly
> accessible; the Gaussian's control signals must be derived from signals
> available in the glue module.

### Key design decisions (from parent doc)

- **Option A (internal to `axis_motion_detect`) is used**, not Option B (external AXIS stage). Reasons: only Y is smoothed (1 set of line buffers, not 3); RGB passthrough is unblurred; no `sparevideo_top` changes; Gaussian is an implementation detail of the detector.
- **3x3 kernel only** — no parameterized NxN. A 3x3 is sufficient for 320x240; a 5x5 would blur away small-object motion at this resolution.
- **Line buffers as simple dual-port BRAM** — works at any resolution via the `H_ACTIVE` parameter. Shift-register FFs would also work at 320px but don't scale.
- **Edge handling: border pixel replication** — clamp window coordinates at image edges.

---

## RTL Changes

### New file: `hw/ip/motion/rtl/axis_gauss3x3.sv`

A standalone combinational+registered module (not a full AXIS stage with its own handshake — it is a synchronous pipeline element controlled by `axis_motion_detect`'s existing handshake logic).

**Interface:**

```systemverilog
module axis_gauss3x3 #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240
) (
    input  logic       clk_i,
    input  logic       rst_n_i,

    // Control (from axis_motion_detect pipeline logic)
    input  logic       valid_i,     // pixel is valid (tvalid && tready upstream)
    input  logic       sof_i,       // start-of-frame (resets row/col counters)
    input  logic       stall_i,     // pipeline stall — freeze all state

    // Data
    input  logic [7:0] y_i,         // raw Y from rgb2ycrcb
    output logic [7:0] y_o,         // smoothed Y
    output logic       valid_o      // output valid (delayed by fill latency)
);
```

**Internal architecture:**

1. **Row/column counters** — track position within frame for edge detection. Reset on `sof_i`. Frozen during `stall_i`.

2. **Two line buffers** (simple dual-port BRAM, depth = `H_ACTIVE`, width = 8 bits each):
   - Line buffer 0: holds row `r-2` (oldest)
   - Line buffer 1: holds row `r-1`
   - Live input: row `r` (current pixel)

   Each line buffer is a circular buffer with a read/write address counter. On each valid pixel: read the old value at the current column, write the new value. The old value from LB0 is the `r-2` pixel; the old value from LB1 is the `r-1` pixel; the value being written to LB1 is the current row's pixel shifted down from LB0.

   Data flow per valid pixel at column `c`:
   ```
   row_r2 = LB0.read(c)     // oldest row
   row_r1 = LB1.read(c)     // middle row
   row_r0 = y_i             // current input

   LB0.write(c, row_r1)     // shift middle → oldest
   LB1.write(c, row_r0)     // shift current → middle
   ```

3. **Column shift registers** (2 FFs per row = 6 FFs total):
   Each row's output feeds through a 2-deep shift register to produce columns `c-2`, `c-1`, `c`:
   ```
   win[0][0..2] = {row_r2_delayed2, row_r2_delayed1, row_r2}  // top row of window
   win[1][0..2] = {row_r1_delayed2, row_r1_delayed1, row_r1}  // middle row
   win[2][0..2] = {row_r0_delayed2, row_r0_delayed1, row_r0}  // bottom row (live)
   ```

4. **Edge muxing** — controlled by row/col counters:
   - First row (`row == 0`): replace `row_r2` and `row_r1` outputs with `row_r0` (replicate current row upward)
   - Second row (`row == 1`): replace `row_r2` output with `row_r1` (replicate middle row upward)
   - First column (`col == 0`): replace `c-2` and `c-1` shift register taps with `c` value
   - Second column (`col == 1`): replace `c-2` shift register tap with `c-1` value
   - Last column (`col == H_ACTIVE-1`): no special handling needed (window doesn't extend right since we process left-to-right)

   Note: the same logic applies symmetrically for the last row / last column. For the last row, no special handling is needed since we use the live input for the bottom row. For the last column, the `c-1` and `c-2` taps naturally hold valid previous-column data.

5. **Convolution (combinational adder tree):**
   ```
   // All multiplications are bit-shifts (wiring only):
   //   *1 = identity, *2 = <<1, *4 = <<2
   // Kernel: [1 2 1; 2 4 2; 1 2 1], sum = 16
   
   sum = win[0][0]      + (win[0][1] << 1) + win[0][2]
       + (win[1][0]<<1) + (win[1][1] << 2) + (win[1][2] << 1)
       + win[2][0]      + (win[2][1] << 1) + win[2][2];
   
   y_o = sum >> 4;  // divide by 16 (just wiring — drop bottom 4 bits)
   ```

   Bit widths: each input is 8 bits, max shifted value is 10 bits (`<<2`), sum of 9 terms fits in 12 bits. `sum[11:4]` is the output.

6. **Output valid timing:**
   The Gaussian produces valid output starting from the first pixel of the first row (using replicated borders). There is no multi-row fill delay because edge replication means every pixel position produces a valid output. The latency is the column shift register depth: **2 clock cycles** (to fill the `c-2` and `c-1` taps).

   However, for the first 2 pixels of each row, the column taps use replicated edge values, so the output is valid but edge-replicated. This is correct Gaussian behavior and requires no output suppression.

   `valid_o` follows `valid_i` with a 2-cycle delay (matching the column shift register fill time). During stall, `valid_o` holds its last value.

### File: `hw/ip/motion/rtl/axis_motion_detect.sv`

> `axis_motion_detect` is now a glue module that instantiates `axis_fork_pipe`,
> `rgb2ycrcb`, and `motion_core`. Fork-internal signals (`tvalid_pipe`,
> `tuser_pipe`) are not directly accessible. The signals available for wiring
> the Gaussian are:
> - `fork_stall` (exported `pipe_stall_o` from `axis_fork_pipe`)
> - `fork_beat_done` (exported `beat_done_o` from `axis_fork_pipe`)
> - `s_axis_tvalid_i && s_axis_tready_o` (pixel acceptance — can be registered
>   to derive a stage-0 valid signal)
> - `s_axis_tuser_i` (SOF — can be registered alongside the valid signal)

**1. Add `GAUSS_EN` parameter (default 1):**

```systemverilog
parameter int GAUSS_EN = 1  // 1 = Gaussian pre-filter enabled, 0 = bypass (raw Y)
```

This allows disabling the Gaussian for comparison testing and for the unit TB (which uses small 4x2 frames where a 3x3 kernel doesn't make sense).

**2. Increase `PIPE_STAGES` to account for Gaussian latency:**

The Gaussian adds 2 cycles of column-shift latency. The sideband pipeline (inside `axis_fork_pipe`) must grow to match:

```systemverilog
localparam int GAUSS_LATENCY = GAUSS_EN ? 2 : 0;
localparam int PIPE_STAGES   = 1 + GAUSS_LATENCY;  // 1 (rgb2ycrcb) + 2 (gauss) = 3
```

`PIPE_STAGES` is passed to `axis_fork_pipe` via its parameter, so the fork's sideband pipeline grows automatically.

**3. Derive Gaussian control signals and instantiate `axis_gauss3x3`:**

The Gaussian needs a `valid_i` that fires one cycle after pixel acceptance (aligned with `y_cur` from `rgb2ycrcb`), and a `sof_i` for the same cycle. These are derived by registering the acceptance signals in `axis_motion_detect` (not from fork internals):

```systemverilog
// ---- Gaussian control signals (1-cycle delayed acceptance) ----
logic gauss_pixel_valid;
logic gauss_sof;

always_ff @(posedge clk_i) begin
    if (!rst_n_i) begin
        gauss_pixel_valid <= 1'b0;
        gauss_sof         <= 1'b0;
    end else if (!fork_stall) begin
        gauss_pixel_valid <= s_axis_tvalid_i && s_axis_tready_o;
        gauss_sof         <= s_axis_tuser_i;
    end
end

// ---- Optional Gaussian pre-filter on Y channel ----
logic [7:0] y_smooth;

generate
    if (GAUSS_EN) begin : gen_gauss
        logic gauss_valid;

        axis_gauss3x3 #(
            .H_ACTIVE (H_ACTIVE),
            .V_ACTIVE (V_ACTIVE)
        ) u_gauss (
            .clk_i   (clk_i),
            .rst_n_i (rst_n_i),
            .valid_i (gauss_pixel_valid),
            .sof_i   (gauss_sof),
            .stall_i (fork_stall),
            .y_i     (y_cur),           // raw Y from rgb2ycrcb
            .y_o     (y_smooth),
            .valid_o (gauss_valid)
        );
    end else begin : gen_no_gauss
        assign y_smooth = y_cur;
    end
endgenerate
```

**4–5. Wire `y_smooth` to `motion_core` instead of `y_cur`:**

Since `motion_core` is a separate combinational module with `y_cur_i` and `y_bg_i` input ports, the change is a single wire swap in `axis_motion_detect` — no modification to `motion_core.sv` itself:

Current:
```systemverilog
    motion_core #(...) u_core (
        .y_cur_i      (y_cur),
        ...
    );
```

Changed to:
```systemverilog
    motion_core #(...) u_core (
        .y_cur_i      (y_smooth),   // smoothed Y when GAUSS_EN=1, raw Y when 0
        ...
    );
```

This automatically changes both the diff comparison and EMA update inside `motion_core`, since both use `y_cur_i`.

**6. Adjust memory read timing:**

The RAM read address is issued at cycle C, data arrives at C+1 (after `rgb2ycrcb`). With the Gaussian adding 2 more cycles, `mem_rd_data_i` arrives at C+1 but `y_smooth` arrives at C+3. The memory read must be delayed by 2 cycles to align.

Two options:
- **Option A:** Delay `mem_rd_addr_o` issuance by 2 cycles (register the address). This means the read issues at C+2, data arrives at C+3 — aligned with `y_smooth`.
- **Option B:** Register `mem_rd_data_i` through 2 pipeline stages to align with `y_smooth`.

**Option A is preferred** — it avoids extra registers and keeps the read-data path short. The `pix_addr` pipeline already exists (`idx_pipe`); use `idx_pipe[GAUSS_LATENCY-1]` (or `idx_pipe[1]` when `GAUSS_EN=1`) to issue the delayed read:

```systemverilog
assign mem_rd_addr_o = ($bits(mem_rd_addr_o))'(RGN_BASE) +
                       (fork_stall ? pix_addr_hold : idx_pipe[GAUSS_LATENCY]);
```

The `pix_addr_hold` stall logic also needs to sample from `idx_pipe[GAUSS_LATENCY]` instead of `pix_addr`:

```systemverilog
always_ff @(posedge clk_i) begin
    if (!rst_n_i)
        pix_addr_hold <= '0;
    else if (!fork_stall)
        pix_addr_hold <= idx_pipe[GAUSS_LATENCY];
end
```

**7. Memory write-back address uses the end of the pipeline (`idx_pipe[PIPE_STAGES-1]`), which is already correct** — no change needed for the write path.

### No changes to `sparevideo_top.sv`

The external interface of `axis_motion_detect` is unchanged. `GAUSS_EN` can optionally be propagated as a top-level parameter, but the default (enabled) is fine.

### FuseSoC / core file

Add `hw/ip/motion/rtl/axis_gauss3x3.sv` to `hw/ip/motion/motion.core` (files_rtl list, before `axis_motion_detect.sv`). Also add it to `dv/sim/Makefile` in both `IP_MOTION_RTL` and the `test-ip-motion-detect` target.

---

## SV Testbench Plan

### New file: `hw/ip/motion/tb/tb_axis_gauss3x3.sv`

A standalone unit testbench for the `axis_gauss3x3` module in isolation, testing the convolution and line buffer logic without the complexity of the full motion detector.

#### Test 1: Uniform image (DC pass-through)

**Stimulus:** Feed a 16x8 image where every pixel = 128.

**Expected:** Every output pixel = 128. A Gaussian blur of a uniform image is the same uniform image (kernel weights sum to 1).

**Check:** Verify `y_o == 128` for all valid output pixels.

#### Test 2: Single bright pixel (impulse response)

**Stimulus:** Feed a 16x8 image where all pixels = 0 except pixel (4, 4) = 255.

**Expected:** The output at (4, 4) = `(4 * 255) >> 4 = 63` (center weight). The 8 neighbors get the corresponding kernel-weighted values: 2-weighted neighbors get `(2 * 255) >> 4 = 31`, 1-weighted corners get `(1 * 255) >> 4 = 15`. All other pixels remain 0.

**Check:** Verify the 3x3 output region around (4, 4) matches the kernel weights scaled by 255/16. Verify all pixels outside the 3x3 region are 0.

#### Test 3: Horizontal gradient (smoothing verification)

**Stimulus:** Feed a 16x8 image where pixel value = column index * 16 (i.e., 0, 16, 32, ..., 240).

**Expected:** The Gaussian smooths the gradient. Interior pixels should be the weighted average of 3 consecutive columns. Edge pixels should show border-replicated smoothing.

**Check:** Compute expected output in the testbench using the kernel formula and compare.

#### Test 4: Edge replication (first row, first column, last row, last column)

**Stimulus:** Feed a 16x8 image with a known pattern (e.g., checkerboard). Focus on verifying the output pixels at image borders.

**Expected:** Border pixels use replicated neighbors. Compute the expected value for each border pixel using the replicated-border kernel formula.

**Check:** Verify all 4 borders produce correct edge-replicated results.

#### Test 5: Stall behavior

**Stimulus:** Feed a known image while periodically asserting `stall_i` (10 cycles on, 3 cycles off pattern).

**Expected:** Same output as without stalls, just spread over more clock cycles. The internal line buffer and shift register state must not corrupt during stalls.

**Check:** Compare output pixel sequence bit-for-bit against the no-stall reference.

#### Test 6: Multi-frame reset via SOF

**Stimulus:** Feed 2 consecutive frames (16x8 each) with different content. Assert `sof_i` on the first pixel of the second frame.

**Expected:** The row/column counters reset on SOF. The second frame's output is independent of the first frame's content (line buffers are irrelevant after SOF resets the counters and the new frame fills them).

**Check:** Verify the second frame's output matches what it would produce if processed alone.

### File: `hw/ip/motion/tb/tb_axis_motion_detect.sv` (existing — extend)

Add a test that exercises the Gaussian within the full motion detector:

#### Test 7: Motion detect with Gaussian enabled (end-to-end)

**Stimulus:** Instantiate `axis_motion_detect` with `GAUSS_EN=1` and a larger frame size (e.g., 16x8) to make the 3x3 kernel meaningful. Feed 3+ frames with a moving bright block on a dark background.

**Expected:** The motion mask should be similar to the non-Gaussian case but with smoother edges (fewer isolated mask pixels at object boundaries). Compute expected output using the Python model with Gaussian enabled.

**Check:** Bit-exact match against the Python model output.

#### Test 8: GAUSS_EN=0 regression

**Stimulus:** Same as existing tests but with explicit `GAUSS_EN=0`.

**Expected:** Behavior identical to the current (pre-Gaussian) motion detector. All existing golden values should match.

**Check:** Verify no regression in the existing test suite when Gaussian is disabled.

---

## Python Model

### Changes to `py/models/motion.py`

Add Gaussian pre-filtering as a step between luma extraction and frame differencing:

```python
def _gauss3x3(y_frame):
    """3x3 Gaussian blur matching RTL kernel [1 2 1; 2 4 2; 1 2 1] / 16.
    
    Uses border replication (np.pad with mode='edge') to match the RTL
    edge handling. Integer arithmetic with >>4 truncation, not floating-point.
    """
    padded = np.pad(y_frame, 1, mode='edge')  # replicate borders
    h, w = y_frame.shape
    
    # Build the 9-term sum using shifts (matching RTL: *1, *2=<<1, *4=<<2)
    result = np.zeros((h, w), dtype=np.uint16)
    for dr in range(3):
        for dc in range(3):
            weight = [1, 2, 1][dr] * [1, 2, 1][dc]  # separable kernel
            result += weight * padded[dr:dr+h, dc:dc+w].astype(np.uint16)
    
    return (result >> 4).astype(np.uint8)
```

The `run()` function gains a `gauss_en` parameter (default `True`):

```python
def run(frames, thresh=16, alpha_shift=3, gauss_en=True, **kwargs):
    ...
    for i, frame in enumerate(frames):
        y_cur = _rgb_to_y(frame)
        
        # Optional Gaussian pre-filter
        if gauss_en:
            y_cur_filt = _gauss3x3(y_cur)
        else:
            y_cur_filt = y_cur
        
        # Motion mask uses filtered Y
        mask = _compute_mask(y_cur_filt, y_ref, thresh)
        
        ...
        
        # EMA also uses filtered Y (matches RTL)
        y_ref = _ema_update(y_cur_filt, y_ref, alpha_shift)
        ...
```

### Changes to `py/models/mask.py`

Same change — import and apply `_gauss3x3` before mask computation:

```python
from models.motion import _rgb_to_y, _compute_mask, _ema_update, _gauss3x3

def run(frames, thresh=16, alpha_shift=3, gauss_en=True, **kwargs):
    ...
    for frame in frames:
        y_cur = _rgb_to_y(frame)
        if gauss_en:
            y_cur_filt = _gauss3x3(y_cur)
        else:
            y_cur_filt = y_cur
        mask = _compute_mask(y_cur_filt, y_ref, thresh)
        ...
        y_ref = _ema_update(y_cur_filt, y_ref, alpha_shift)
```

### Harness / Makefile integration

The `GAUSS_EN` parameter needs to flow through the build chain:

- `Makefile`: add `GAUSS_EN ?= 1`, pass to sim as `SIM_VARS`, pass to verify as `--gauss-en $(GAUSS_EN)`
- `dv/sim/Makefile`: add `GAUSS_EN ?= 1` default, add to `VLT_FLAGS` as `-GGAUSS_EN=$(GAUSS_EN)`, add to config stamp
- `py/harness.py`: add `--gauss-en` argument, pass to `run_model()`
- `py/models/motion.py` and `py/models/mask.py`: accept `gauss_en` kwarg

### Tests in `py/tests/test_models.py`

Add model-level tests:

1. **Gaussian identity on uniform frame** — verify `_gauss3x3(np.full((8, 16), 128))` produces all 128s.
2. **Gaussian impulse response** — verify the 3x3 output region around a single bright pixel matches kernel weights.
3. **Motion model with gauss_en=True** — verify full pipeline produces expected output for a noisy moving box scene.
4. **Motion model with gauss_en=False** — verify it matches the pre-Gaussian behavior exactly (regression check).

---

## Acceptance Criteria

### Must pass (blocking):

- [ ] `make lint` — no new warnings from the Gaussian module or modified `axis_motion_detect`
- [ ] `make test-ip` — all existing unit tests still pass with `GAUSS_EN=0` (no regression)
- [ ] New `tb_axis_gauss3x3` tests 1-6 pass
- [ ] `tb_axis_motion_detect` test 7 (Gaussian enabled, end-to-end) passes
- [ ] `tb_axis_motion_detect` test 8 (GAUSS_EN=0 regression) passes
- [ ] `make run-pipeline CTRL_FLOW=motion GAUSS_EN=1` — full pipeline produces valid output with bbox overlay
- [ ] `make run-pipeline CTRL_FLOW=mask GAUSS_EN=1` — mask display path works correctly
- [ ] `make run-pipeline CTRL_FLOW=passthrough GAUSS_EN=1` — passthrough unaffected (Gaussian is internal to motion detect, passthrough doesn't use it)
- [ ] Python model with `gauss_en=True` produces bit-identical output to RTL simulation at `TOLERANCE=0`
- [ ] Line buffer contents are not corrupted across frame boundaries (SOF reset)
- [ ] Stall behavior correct: output matches no-stall reference under consumer backpressure

### Should pass (non-blocking, verify manually):

- [ ] With `SOURCE="synthetic:noisy_moving_box"`, the mask is visibly cleaner (fewer isolated noise pixels) with Gaussian enabled vs disabled
- [ ] With `SOURCE="synthetic:moving_box"` (clean background), the mask is nearly identical with and without Gaussian (Gaussian doesn't degrade performance on already-clean input)
- [ ] Edge pixels (first/last row/column) produce reasonable values (no black borders, no artifacts)
- [ ] Verify all control flows × `GAUSS_EN` × `ALPHA_SHIFT` combinations at `TOLERANCE=0`:
  - `CTRL_FLOW=passthrough` × `GAUSS_EN=0,1` × `ALPHA_SHIFT=0,3`
  - `CTRL_FLOW=motion` × `GAUSS_EN=0,1` × `ALPHA_SHIFT=0,1,2,3`
  - `CTRL_FLOW=mask` × `GAUSS_EN=0,1` × `ALPHA_SHIFT=0,1,2,3`

---

## Integration Checklist

- [ ] Create `hw/ip/motion/rtl/axis_gauss3x3.sv` with line buffer + window + adder tree
- [ ] Add `GAUSS_EN` parameter to `axis_motion_detect` (default 1)
- [ ] Increase `PIPE_STAGES` dynamically based on `GAUSS_EN` (passed to `axis_fork_pipe`)
- [ ] Add `gauss_pixel_valid` / `gauss_sof` control registers in `axis_motion_detect`
- [ ] Instantiate `axis_gauss3x3` inside `axis_motion_detect` (generate block, gated by `GAUSS_EN`)
- [ ] Wire `y_smooth` to `motion_core.y_cur_i` instead of `y_cur` (no changes to `motion_core.sv`)
- [ ] Adjust memory read address timing (delay by `GAUSS_LATENCY` cycles via `idx_pipe`)
- [ ] Add `axis_gauss3x3.sv` to `hw/ip/motion/motion.core` and `dv/sim/Makefile`
- [ ] No changes to `sparevideo_top`, `axis_fork_pipe`, `motion_core`, or `sparevideo_pkg` needed
- [ ] No changes to `ram`, `axis_bbox_reduce`, or `axis_overlay_bbox` needed
- [ ] Create `hw/ip/motion/tb/tb_axis_gauss3x3.sv` with tests 1-6
- [ ] Extend `hw/ip/motion/tb/tb_axis_motion_detect.sv` with tests 7-8
- [ ] Add `_gauss3x3()` to `py/models/motion.py`
- [ ] Add `gauss_en` parameter to `py/models/motion.py` and `py/models/mask.py`
- [ ] Add `GAUSS_EN` to Makefile parameter propagation chain (top Makefile → SIM_VARS → dv/sim/Makefile → VLT_FLAGS → tb parameter)
- [ ] Add `--gauss-en` to `py/harness.py`
- [ ] Add Gaussian model tests to `py/tests/test_models.py`
- [ ] Run `make run-pipeline` with all control flow × GAUSS_EN × ALPHA_SHIFT combinations
- [ ] Create architecture doc `docs/specs/axis_gauss3x3-arch.md` before implementation (invoke `hardware-arch-doc` skill)
- [ ] Update `docs/specs/axis_motion_detect-arch.md` to document the Gaussian submodule and `GAUSS_EN` parameter
