# Block 1: EMA Background Model

**Parent:** [motion-pipeline-improvements.md](motion-pipeline-improvements.md) — see block 1 for architecture rationale, data flow, and placement.

---

## Overview

Replace the raw previous-frame write-back in `axis_motion_detect` with an exponential moving average (EMA). The background RAM stores a temporally smoothed estimate of each pixel's luma instead of the raw value from the last frame. This reduces false positives from sensor noise and gradual lighting changes.

The change is confined to the write-back datapath of `axis_motion_detect`. No new modules, no new AXIS stages, no changes to `sparevideo_top` wiring.

---

## RTL Changes

### File: `hw/ip/motion/rtl/axis_motion_detect.sv`

**1. Add parameter:**

```systemverilog
parameter int ALPHA_SHIFT = 3   // EMA alpha = 1 / (1 << ALPHA_SHIFT), default 1/8
```

**2. Add EMA computation signals (after the `diff` / `mask_bit` block, ~line 192):**

```systemverilog
// ---- EMA background update ----
logic signed [8:0] ema_delta;     // y_cur - bg, signed 9-bit
logic signed [8:0] ema_step;      // delta >>> ALPHA_SHIFT (arithmetic right-shift)
logic        [7:0] ema_update;    // new background value

assign ema_delta  = {1'b0, y_cur} - {1'b0, mem_rd_data_i};
assign ema_step   = ema_delta >>> ALPHA_SHIFT;
assign ema_update = mem_rd_data_i + ema_step[7:0];
```

**3. Change the write-back (in the `always_ff` block at ~line 197-207):**

Current:
```systemverilog
mem_wr_data_o <= y_cur;
```

Changed to:
```systemverilog
mem_wr_data_o <= ema_update;
```

**4. Propagate `ALPHA_SHIFT` parameter** through `sparevideo_top` instantiation (or use the default).

### No other files change.

The `sparevideo_pkg`, `sparevideo_top`, `ram`, `axis_bbox_reduce`, and `axis_overlay_bbox` modules are all untouched. The AXIS interfaces of `axis_motion_detect` are unchanged — same ports, same timing, same backpressure behavior.

---

## SV Testbench Plan

### File: `hw/ip/motion/tb/tb_axis_motion_detect.sv` (existing — extend)

The existing TB already tests basic frame differencing. Add test scenarios targeting EMA-specific behavior:

### Test 1: Static scene convergence

**Stimulus:** Feed 10+ frames of a completely static image (every pixel identical across frames).

**Expected:** After the first frame (priming), the background RAM should converge toward the static pixel values. The motion mask should be all-zeros from frame 3 onward (after the EMA has had 2-3 frames to converge from the initial zero state).

**Check:** Verify `mask == 0` for all pixels in frames 3..N. Verify that `mem_wr_data` converges toward `y_cur` (the values should get closer each frame, within rounding).

### Test 2: Single pixel step change (object arrival)

**Stimulus:** Feed 5 frames of a static scene (all pixels = luma 100). On frame 6, change one pixel to luma 200. Keep it at 200 for frames 7-15.

**Expected:**
- Frame 6: `diff = |200 - 100| = 100 > THRESH` → mask = 1 (motion detected)
- Frame 7: background has moved toward 200 by `(200-100) >> 3 = 12` → bg ≈ 112, diff = 88 → mask = 1
- Frame 8: bg ≈ 123, diff ≈ 77 → mask = 1
- ...frames 9-12: diff gradually decreases as bg converges to 200
- Eventually: bg ≈ 200, diff ≈ 0 → mask = 0 (object absorbed into background)

**Check:** Mask is 1 for the first several frames, then transitions to 0. The exact frame where it crosses threshold depends on ALPHA_SHIFT and THRESH — compute in Python model and compare.

### Test 3: Single pixel step change (object departure)

**Stimulus:** Same as test 2, but after the background has converged to 200, change the pixel back to 100 on frame 20.

**Expected:** Mirror of test 2 — mask = 1 for several frames as the background adapts from 200 back toward 100, then mask = 0.

**Check:** Symmetric convergence behavior.

### Test 4: Gradual lighting ramp

**Stimulus:** Feed frames where all pixels increase by +1 luma per frame (simulating slow brightening). Run for 30 frames.

**Expected:** The EMA tracks the slow ramp. `diff = |Y_cur - bg|` should be small (~1-2 after a few frames) and stay below THRESH. Mask should be all-zeros after initial convergence.

**Check:** Zero mask from frame 3 onward. The background values should trail the current values by approximately `ramp_rate / alpha` ≈ `1 / (1/8)` = 8 levels behind.

### Test 5: Backpressure during EMA write-back

**Stimulus:** Feed a frame with a known moving object while periodically deasserting `m_axis_vid_tready_i` (consumer stall pattern: 10 cycles on, 3 cycles off).

**Expected:** Same mask output as without stalls. The EMA write-back must fire exactly once per pixel (gated by `both_ready`), not repeated during stall cycles.

**Check:** Compare mask output bit-for-bit with the no-stall reference. Verify `mem_wr_en_o` assertion count equals exactly `H_ACTIVE * V_ACTIVE` per frame.

### Test 6: ALPHA_SHIFT parameter sweep

**Stimulus:** Same step-change scenario (test 2), but instantiate with `ALPHA_SHIFT = 1, 2, 3, 4, 5`.

**Expected:** Higher ALPHA_SHIFT → slower convergence → motion detected for more frames. Lower ALPHA_SHIFT → faster convergence → motion detected for fewer frames.

**Check:** For each ALPHA_SHIFT value, verify convergence frame count matches the Python model.

---

## Python Model

### Prerequisite: `py/models/` infrastructure

This plan depends on the model verification infrastructure described in [python-model-verification.md](python-model-verification.md). That plan establishes:

- `py/models/` package with one file per control flow and dispatch via `run_model()`
- `py/models/motion.py` — the baseline motion pipeline reference model
- `make verify --ctrl-flow motion` comparing RTL output against the model at TOLERANCE=0

### Changes to `py/models/motion.py`

The EMA changes the reference buffer update step in the motion model. Currently the model stores raw `Y_cur` as the reference for the next frame. With EMA, the reference update becomes:

```python
def _ema_update(y_cur, bg_prev, alpha_shift=3):
    """EMA background update from algorithm spec.
    
    bg_new = bg_prev + (y_cur - bg_prev) >> alpha_shift
    Uses arithmetic right-shift (sign-preserving) and uint8 clamping.
    """
    delta = y_cur.astype(np.int16) - bg_prev.astype(np.int16)
    step = delta >> alpha_shift  # numpy >> is arithmetic for signed types
    new_bg = bg_prev.astype(np.int16) + step
    return np.clip(new_bg, 0, 255).astype(np.uint8)
```

The motion model's `run()` function gains an `alpha_shift` parameter (default 3). When `alpha_shift=0`, the model reduces to the current raw-frame behavior (`step = delta`, so `bg_new = y_cur`).

The write-back line in the frame loop changes from:
```python
y_ref = y_cur  # raw write-back
```
to:
```python
y_ref = _ema_update(y_cur, y_ref, alpha_shift)  # EMA write-back
```

### Harness / Makefile integration

The `ALPHA_SHIFT` parameter needs to flow from the Makefile through to the Python model:
- `Makefile`: add `ALPHA_SHIFT ?= 3`, pass to verify as `--alpha-shift $(ALPHA_SHIFT)`
- `py/harness.py`: add `--alpha-shift` argument, pass to `run_model()`
- `py/models/motion.py`: `run(frames, thresh=16, alpha_shift=3)`

### New synthetic sources (`py/frames/video_source.py`)

The existing synthetic sources (`moving_box`, `dark_moving_box`, etc.) all have perfectly clean backgrounds — every background pixel is identical across frames. Raw frame differencing already produces a perfect mask for these scenes, so they cannot demonstrate EMA's improvement. Add new sources that inject per-frame background noise to simulate real camera behavior:

**`noisy_moving_box`** — Same as `moving_box` (red box on black background, diagonal motion) but with random luma jitter (±3-5) on every background pixel each frame. Without EMA, this produces salt-and-pepper false positives across the entire background. With EMA, the background model converges to the mean and the jitter stays below threshold.

```python
def _gen_noisy_moving_box(width, height, num_frames):
    """A red box moving diagonally on a background with per-frame sensor noise.

    Background pixels jitter ±5 luma per frame (simulating camera sensor noise).
    EMA should suppress the noise; raw frame differencing will produce false positives.
    """
    rng = np.random.default_rng(seed=42)  # deterministic for reproducibility
    box_w, box_h = width // 4, height // 4
    base_bg = 80  # mid-gray background
    noise_amplitude = 5  # ±5 luma jitter
    frames = []
    for i in range(num_frames):
        # Background: base gray + per-pixel, per-frame noise
        noise = rng.integers(-noise_amplitude, noise_amplitude + 1,
                             size=(height, width), dtype=np.int16)
        bg = np.clip(base_bg + noise, 0, 255).astype(np.uint8)
        frame = np.stack([bg, bg, bg], axis=-1)  # gray RGB
        # Foreground: bright red box
        t = i / max(num_frames - 1, 1)
        cx = int(t * (width - box_w))
        cy = int(t * (height - box_h))
        frame[cy : cy + box_h, cx : cx + box_w] = (255, 0, 0)
        frames.append(frame)
    return frames
```

**`lighting_ramp`** — All pixels start at luma 100 and increase by +1 per frame (simulating slow brightening from a cloud passing). A moving box is overlaid. Without EMA, the brightness ramp could cause a transient full-frame motion detection if the ramp rate ever exceeds the per-frame threshold. With EMA, the background tracks the slow drift and only the moving box triggers motion.

```python
def _gen_lighting_ramp(width, height, num_frames):
    """Moving box on a background that slowly brightens (+1 luma/frame).

    Tests that EMA tracks gradual lighting changes without producing
    false positives across the entire frame.
    """
    box_w, box_h = width // 4, height // 4
    frames = []
    for i in range(num_frames):
        bg_level = min(100 + i, 255)
        frame = np.full((height, width, 3), bg_level, dtype=np.uint8)
        t = i / max(num_frames - 1, 1)
        cx = int(t * (width - box_w))
        cy = int(t * (height - box_h))
        # Box color stays constant (bright) so it stands out against rising bg
        frame[cy : cy + box_h, cx : cx + box_w] = (255, 0, 0)
        frames.append(frame)
    return frames
```

Register both in the `generators` dict in `_generate_synthetic()`.

These sources enable a direct visual comparison: run `make run-pipeline CTRL_FLOW=mask SOURCE="synthetic:noisy_moving_box" FRAMES=15` before and after the EMA change. The rendered mask output should visibly show fewer false-positive white pixels on the background with EMA enabled.

### Test vectors

The SV testbench tests (1-6 above) should each have a corresponding Python model assertion in `py/tests/test_models.py` that verifies the model itself produces the expected convergence behavior. The RTL is then verified against the model via `make verify`.

---

## Acceptance Criteria

### Must pass (blocking):

- [ ] `make lint` — no new warnings from the EMA signals
- [ ] `make test-ip` — all existing unit tests still pass (no regression)
- [ ] Tests 1-5 above pass in the extended `tb_axis_motion_detect`
- [ ] `make run-pipeline CTRL_FLOW=motion` — full pipeline still produces valid output with bbox overlay
- [ ] `make run-pipeline CTRL_FLOW=mask` — mask display path still produces valid B/W output with EMA-updated background
- [ ] Python model produces bit-identical mask output for tests 1-5 when compared to RTL simulation output
- [ ] `mem_wr_en_o` fires exactly `H_ACTIVE * V_ACTIVE` times per frame (no duplicate writes during stalls)
- [ ] The `PrimeFrames` suppression in `axis_bbox_reduce` still works correctly (EMA convergence doesn't interfere with the priming logic)

### Should pass (non-blocking, verify manually):

- [ ] With `moving_box` synthetic source, the bbox is tighter than with raw frame differencing (fewer noise pixels → smaller bbox margin around the object)
- [ ] With a static source, the mask is all-zeros from frame 3 onward (no persistent noise flicker)
- [ ] ALPHA_SHIFT parameter override works at `sparevideo_top` instantiation level
- [ ] `make run-pipeline CTRL_FLOW=mask SOURCE="synthetic:noisy_moving_box" FRAMES=15` — mask should show motion only around the box, not salt-and-pepper noise across the background (compare visually against raw frame differencing baseline)
- [ ] `make run-pipeline CTRL_FLOW=mask SOURCE="synthetic:lighting_ramp" FRAMES=20` — mask should show motion only around the box, not full-frame false positives from the brightness ramp

---

## Integration Checklist

- [ ] Add `ALPHA_SHIFT` parameter to `axis_motion_detect` with default value
- [ ] Propagate parameter through `sparevideo_top` instantiation (optional — default is fine initially)
- [ ] No changes to `sparevideo_top` wiring needed
- [ ] No changes to `sparevideo_pkg` needed
- [ ] No changes to `ram`, `axis_bbox_reduce`, or `axis_overlay_bbox` needed
- [ ] Update `docs/specs/axis_motion_detect-arch.md` to document the EMA write-back and `ALPHA_SHIFT` parameter (spec is the primary source of truth — must reflect the intended change before implementation begins)
- [ ] Update `docs/specs/sparevideo-top-arch.md` if `ALPHA_SHIFT` is propagated or if the datapath description references raw Y write-back
- [ ] Add `noisy_moving_box` and `lighting_ramp` synthetic sources to `py/frames/video_source.py`
- [ ] Add Python model to `py/models/`
- [ ] Verify `make run-pipeline CTRL_FLOW=motion SOURCE="synthetic:moving_box" FRAMES=10`
- [ ] Verify `make run-pipeline CTRL_FLOW=mask SOURCE="synthetic:moving_box" FRAMES=10`
- [ ] Verify `make run-pipeline CTRL_FLOW=mask SOURCE="synthetic:noisy_moving_box" FRAMES=15`
- [ ] Verify `make run-pipeline CTRL_FLOW=mask SOURCE="synthetic:lighting_ramp" FRAMES=20`
