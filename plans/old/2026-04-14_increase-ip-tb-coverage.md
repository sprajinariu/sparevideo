
---

## IP Testbench Coverage Improvement Plan

### Guiding principles

- Assume bugs exist in the RTL — testbenches must verify actual data values, not just control flow.
- Every output pixel or field must be checked against a TB-computed golden reference.
- Each IP TB must test threshold/boundary conditions, not just "all 0" or "all 1" outputs.
- Use the existing `drv_*` intermediary pattern and `$display`/`$fatal` style (no SVA).
- Keep frame sizes small (4×4 to 8×8) to minimize sim time.

---

### 1. `tb_axis_motion_detect` — Major rework

**Current state:** 3 frames; checks only that mask is all-1 or all-0. No data-path verification.

**What to add:**

#### 1a. RGB video passthrough check
- Capture `vid_tdata` on every handshake (vid_tvalid && vid_tready).
- Compare each captured pixel against the driven `frame_pixels[]` array.
- **Bug assumption:** RGB data may be corrupted through the pipeline (e.g. pipeline registers not gated correctly on stall).

#### 1b. Y8 luma golden-model check
- TB computes expected Y for each pixel using the same formula as `rgb2ycrcb`:
  `y_exp = (77*R + 150*G + 29*B) >> 8`
- After frame 0 completes, read back RAM contents via port B and compare each byte against `y_exp[i]`.
- **Bug assumption:** rgb2ycrcb coefficients, bit-width, or truncation may be wrong; RAM write-back address or data may be incorrect.

#### 1c. Per-pixel mask verification with golden model
- TB computes `diff = |y_cur - y_prev|` and `expected_mask = (diff > THRESH)` for each pixel.
- For frame 0: `y_prev = 0` (RAM zero-init), so `expected_mask[i] = (y_exp[i] > THRESH)`.
- For frame 1: `y_prev = y_exp` from frame 0 (identical pixels → diff=0 → mask=0).
- Compare captured mask bits against per-pixel expected values, not a blanket all-0/all-1.
- **Bug assumption:** threshold comparison may use `>=` instead of `>`, or diff computation may overflow/underflow.

#### 1d. Mixed-motion frame (frame 2 — new)
- Drive a frame where some pixels differ from frame 1 and some don't.
- Specifically choose pixels that produce `diff = THRESH-1` (expect mask=0), `diff = THRESH` (expect mask=0, since RTL uses `>`), and `diff = THRESH+1` (expect mask=1).
- TB golden model computes per-pixel expected mask.
- **Bug assumption:** off-by-one in threshold comparison.

#### 1e. Stall test with mixed data (frame 3 — replaces current frame 2)
- Same mixed-motion content as 1d, but with consumer stall pattern active.
- Verify that both mask bits and video passthrough data survive stalls intact.
- **Bug assumption:** stall logic may corrupt pipeline registers or cause double-writes to RAM.

#### 1f. RAM Y8 persistence across frames
- After frame 2 (mixed-motion), read RAM via port B and verify contents match the Y8 values of the pixels just driven (not the previous frame's Y8).
- **Bug assumption:** `mem_wr_en` gating may cause missed writes, or `mem_wr_addr` may be wrong.

---

### 2. `tb_axis_bbox_reduce` — Expand edge cases

**Current state:** 2 tests on 4×4; one known region, one all-zero.

**What to add:**

#### 2a. Single-pixel motion
- One mask=1 pixel at an interior position (e.g. row=2, col=1).
- Expected: `min_x == max_x == 1`, `min_y == max_y == 2`, `bbox_empty == 0`.
- **Bug assumption:** min/max logic may not handle degenerate (single-point) bbox.

#### 2b. Full-frame motion
- All mask bits = 1.
- Expected: `min_x=0, max_x=H-1, min_y=0, max_y=V-1`.
- **Bug assumption:** counters may not reach max values due to off-by-one.

#### 2c. Corner pixels only
- mask=1 at (0,0) and (H-1,V-1) only.
- Expected: bbox spans entire frame.
- **Bug assumption:** col/row reset logic at SOF/EOL may misalign with the first/last pixel.

#### 2d. Single-row motion
- mask=1 for all columns in one row (e.g. row=0).
- Expected: `min_y == max_y == 0`, `min_x=0, max_x=H-1`.
- Tests that horizontal-only motion still sets Y range correctly.

#### 2e. Single-column motion
- mask=1 for all rows in one column (e.g. col=H-1).
- Expected: `min_x == max_x == H-1`, `min_y=0, max_y=V-1`.

#### 2f. Larger frame size (8×8)
- Parameterize TB or add a second test with 8×8 to exercise wider address bits.
- Use a scattered pattern (mask=1 at 3-4 positions) and verify bbox.

#### 2g. SOF resets scratch correctly
- Drive two consecutive frames. First frame has motion at (0,0)-(1,1). Second frame has motion at (3,3) only.
- Verify that second frame's bbox is (3,3)-(3,3), NOT (0,0)-(3,3) — confirms SOF reset clears accumulators.
- **Bug assumption:** SOF `tuser` and mask update may happen in the same cycle, causing a race where the old scratch is used before reset.

---

### 3. `tb_axis_overlay_bbox` — Expand scenarios

**Current state:** 1 test, single bbox=(1,1)-(2,2) on 4×4, tready always high.

**What to add:**

#### 3a. Empty bbox (pure passthrough)
- Set `bbox_empty_i = 1`. Drive a frame of varied pixel colors.
- Verify every output pixel matches input exactly.
- **Bug assumption:** `on_rect` may not be properly gated by `bbox_empty`.

#### 3b. Full-frame bbox
- `bbox = (0,0)-(H-1,V-1)`. All edge pixels should be BBOX_COLOR; interior pixels (if any) should be passthrough.
- On a 4×4 frame: all 12 border pixels = BBOX_COLOR, 4 interior pixels = input color.
- **Bug assumption:** col/row counter may wrap or mis-compare at frame edges.

#### 3c. Single-pixel bbox
- `bbox = (2,2)-(2,2)`. Only pixel at (2,2) should be BBOX_COLOR.
- **Bug assumption:** `min==max` case may fail the range checks.

#### 3d. Edge-aligned bbox
- `bbox = (0,0)-(1,1)`. Tests bbox touching frame origin.
- `bbox = (H-2,V-2)-(H-1,V-1)`. Tests bbox touching frame corner.

#### 3e. Varied input pixel colors
- Instead of solid red, drive a unique color per pixel (e.g. `{row, col, 8'hAA}`).
- Verify non-bbox pixels are passed through unchanged with correct values.
- **Bug assumption:** tdata passthrough may be corrupted (e.g. shifted by one pixel due to col/row counter skew).

#### 3f. Backpressure test
- Add consumer stall pattern (same as motion detect TB).
- Drive a frame and verify correct output despite stalls.
- **Bug assumption:** combinational passthrough of tdata may glitch during stall if tdata input changes.

---

### 4. `tb_rgb2ycrcb` — Minor additions

**Current state:** 6 corner-case colors with ±1 LSB tolerance. Reasonably good.

**What to add:**

#### 4a. Sweep near-boundary values
- Add ~4 RGB values chosen to exercise rounding edge cases:
  - (1, 1, 1) — near-black, small MAC sums
  - (254, 254, 254) — near-white, large MAC sums
  - (128, 0, 255) — purple, exercises large Cb
  - (255, 128, 0) — orange, exercises large Cr
- **Bug assumption:** truncation `[15:8]` may produce off-by-one for specific coefficient products.

#### 4b. Exhaustive spot-check
- Pick 8 random RGB values, compute expected Y/Cb/Cr in TB using the exact `(coeff*channel)>>8` formula.
- ±0 tolerance (exact match, since TB uses the identical integer formula).
- **Bug assumption:** current ±1 tolerance may mask a systematic bias.

---

### 5. Implementation order

| Step | What | Why first |
|------|------|-----------|
| 1 | `tb_axis_motion_detect` 1a-1c (passthrough + Y8 + per-pixel mask) | Highest-risk gap: no data checks at all today |
| 2 | `tb_axis_motion_detect` 1d (threshold boundary frame) | Tests the core comparison logic |
| 3 | `tb_axis_motion_detect` 1e-1f (stall + RAM persistence) | Validates stall correctness with real data |
| 4 | `tb_axis_bbox_reduce` 2a-2g | Medium risk: current tests are too narrow |
| 5 | `tb_axis_overlay_bbox` 3a-3f | Medium risk: only one scenario tested |
| 6 | `tb_rgb2ycrcb` 4a-4b | Low risk: already has data checks, just expanding |
| 7 | Run `make test-ip`, fix any RTL bugs found | The whole point |

### 6. Expected RTL bugs to watch for

Based on code review, areas most likely to expose bugs:

1. **Threshold comparison polarity** — RTL uses `diff > THRESH` (strict). If any test expects `>=`, that's a spec ambiguity to resolve, not a TB bug.
2. **SOF + mask update race in bbox_reduce** — `s_axis_tuser_i` resets scratch, but mask update also happens in the same `if (s_axis_tvalid_i)` block. If the first pixel of a new frame has mask=1, the scratch may see the reset but then immediately update `sc_min_x` in the same cycle, which is correct in SV (sequential within always_ff). But verify this.
3. **Overlay col/row counter vs. combinational mux** — The overlay uses registered `col`/`row` but combinational `on_rect` feeding a combinational output mux (`s_axis_tdata_i`). Since `col`/`row` update on handshake, the first pixel of a frame has `col=0, row=0` (from SOF reset) — but that reset also happens in the registered block, meaning the actual col/row for pixel 0 may still reflect the previous cycle's values. Check timing carefully.
4. **RAM write-back data uses `y_cur`** — which is the registered rgb2ycrcb output. If `pipe_stall` causes `in_r/in_g/in_b` to switch sources, `y_cur` may glitch for one cycle after stall clears. The write is gated on `both_ready`, but verify the value is stable.
