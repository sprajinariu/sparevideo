# Control Flow: Mask Display Mode

**Date:** 2026-04-15 (completed)

**Parent:** [motion-pipeline-improvements.md](motion-pipeline-improvements.md) — prerequisite for all 5 improvement blocks. Provides visual feedback on the motion mask for debugging and tuning.

---

## Overview

Add a third control flow option `mask` that displays the raw 1-bit motion mask as a black-and-white image on the VGA output. This lets the developer see exactly what the motion detector is producing — where it sees motion, where it doesn't, and how much noise is in the mask — without needing to infer it from the bounding box.

Currently `ctrl_flow_i` is 1 bit with two values:
- `0` = passthrough (raw video, no processing)
- `1` = motion (video with green bbox overlay)

After this change, `ctrl_flow_i` becomes 2 bits with three values:
- `2'b00` = passthrough
- `2'b01` = motion (bbox overlay)
- `2'b10` = mask (black/white mask display)

Usage: `make run-pipeline CTRL_FLOW=mask`

---

## What the user sees

```
Passthrough mode:         Motion mode:              Mask mode:
┌──────────────────┐     ┌──────────────────┐      ┌──────────────────┐
│                  │     │                  │      │                  │
│     ██████       │     │   ┌────────┐    │      │     ░░░░░░       │
│     █ cat █      │     │   │██████  │    │      │     ░░░░░░       │
│     ██████       │     │   │█ cat █ │    │      │     ░░░░░░       │
│          moving→ │     │   └────────┘    │      │     ░░░░░░       │
│                  │     │                  │      │                  │
│  original video  │     │  video + bbox    │      │  white=motion    │
└──────────────────┘     └──────────────────┘      │  black=static    │
                                                    └──────────────────┘
```

The mask display expands each 1-bit mask pixel to 24-bit RGB:
- `mask = 1` (motion) → `24'hFF_FF_FF` (white)
- `mask = 0` (no motion) → `24'h00_00_00` (black)

---

## RTL Changes

### 1. `hw/top/sparevideo_pkg.sv` — widen control flow type

Current:
```systemverilog
localparam logic CTRL_PASSTHROUGH   = 1'b0;
localparam logic CTRL_MOTION_DETECT = 1'b1;
```

Changed to:
```systemverilog
localparam logic [1:0] CTRL_PASSTHROUGH   = 2'b00;
localparam logic [1:0] CTRL_MOTION_DETECT = 2'b01;
localparam logic [1:0] CTRL_MASK_DISPLAY  = 2'b10;
```

### 2. `hw/top/sparevideo_top.sv` — widen port, update mux

**Port change:**
```systemverilog
// Current:
input  logic        ctrl_flow_i,
// Changed to:
input  logic [1:0]  ctrl_flow_i,
```

**Add mask-to-RGB expansion signals (after the existing `msk_*` signals):**
```systemverilog
// Mask display: expand 1-bit mask to 24-bit RGB for VGA output
logic [23:0] msk_rgb_tdata;
logic        msk_rgb_tvalid;
logic        msk_rgb_tready;
logic        msk_rgb_tlast;
logic        msk_rgb_tuser;
```

**Mask expansion (pure combinational, no new module needed):**
```systemverilog
assign msk_rgb_tdata  = msk_tdata ? 24'hFF_FF_FF : 24'h00_00_00;
assign msk_rgb_tvalid = msk_tvalid;
assign msk_rgb_tlast  = msk_tlast;
assign msk_rgb_tuser  = msk_tuser;
```

**Input gating change — motion pipeline must run for both `motion` and `mask` modes:**

Current:
```systemverilog
assign md_s_tvalid = (ctrl_flow_i == sparevideo_pkg::CTRL_MOTION_DETECT)
                   ? dsp_in_tvalid : 1'b0;
```

Changed to:
```systemverilog
logic motion_pipe_active;
assign motion_pipe_active = (ctrl_flow_i == sparevideo_pkg::CTRL_MOTION_DETECT)
                          || (ctrl_flow_i == sparevideo_pkg::CTRL_MASK_DISPLAY);
assign md_s_tvalid = motion_pipe_active ? dsp_in_tvalid : 1'b0;
```

**Output mux — add third case:**

Current mux is a 2-way `if/else`. Changed to 3-way:

```systemverilog
always_comb begin
    case (ctrl_flow_i)
        sparevideo_pkg::CTRL_PASSTHROUGH: begin
            proc_tdata    = dsp_in_tdata;
            proc_tvalid   = dsp_in_tvalid;
            proc_tlast    = dsp_in_tlast;
            proc_tuser    = dsp_in_tuser;
            dsp_in_tready = proc_tready;
            ovl_tready    = 1'b1;
            msk_rgb_tready = 1'b1;
        end
        sparevideo_pkg::CTRL_MASK_DISPLAY: begin
            proc_tdata    = msk_rgb_tdata;
            proc_tvalid   = msk_rgb_tvalid;
            proc_tlast    = msk_rgb_tlast;
            proc_tuser    = msk_rgb_tuser;
            dsp_in_tready = md_s_tready;
            ovl_tready    = 1'b1;       // overlay path unused, don't stall
            msk_rgb_tready = proc_tready;
        end
        default: begin // CTRL_MOTION_DETECT
            proc_tdata    = ovl_tdata;
            proc_tvalid   = ovl_tvalid;
            proc_tlast    = ovl_tlast;
            proc_tuser    = ovl_tuser;
            dsp_in_tready = md_s_tready;
            ovl_tready    = proc_tready;
            msk_rgb_tready = 1'b1;
        end
    endcase
end
```

**Backpressure note for mask mode:** In mask mode, the output mux routes `msk_rgb` to the output FIFO. The mask stream's `tready` (`msk_tready`) is currently driven by `axis_bbox_reduce` which is always-ready (`1'b1`). But now the mask also needs to respond to `msk_rgb_tready` (which carries FIFO backpressure).

The problem: `msk_tready` has two consumers — `axis_bbox_reduce` (always ready) and the output mux (may stall). Currently `msk_tready` is wired directly to `bbox_reduce`'s output. In mask mode, the mask stream is the bottleneck — if the output FIFO stalls, the mask stream must stall, which must stall `axis_motion_detect`, which must stall the video passthrough.

The fix is that in mask mode, `axis_motion_detect`'s `m_axis_msk_tready_i` must reflect the output FIFO's backpressure, not just `bbox_reduce`'s always-1. This means `msk_tready` should be driven by:
```systemverilog
// In mask mode: mask tready comes from the output path (via msk_rgb_tready)
// In other modes: mask tready comes from bbox_reduce (always 1)
logic msk_tready_mux;
assign msk_tready_mux = (ctrl_flow_i == sparevideo_pkg::CTRL_MASK_DISPLAY)
                       ? (proc_tready && bbox_reduce_tready)
                       : bbox_reduce_tready;
```

And `axis_motion_detect`'s `m_axis_msk_tready_i` connects to `msk_tready_mux` instead of directly to `bbox_reduce`'s tready.

In mask mode, the video passthrough from `axis_motion_detect` (`vid_*`) is unused — the overlay is bypassed. The `ovl_tready = 1'b1` in the mux drains through `axis_overlay_bbox` → `vid_tready`, so the video side doesn't stall. The mask side is what drives the pipeline rate, gated by the output FIFO.

### 3. `dv/sv/tb_sparevideo.sv` — add plusarg parsing

Add `"mask"` to the `CTRL_FLOW` plusarg parser:

```systemverilog
else if (ctrl_flow_str == "mask")
    ctrl_flow = sparevideo_pkg::CTRL_MASK_DISPLAY;
```

Widen `ctrl_flow` declaration from `logic` to `logic [1:0]`.

Update the display string:
```systemverilog
$display("  ctrl_flow: %s",
    (ctrl_flow == sparevideo_pkg::CTRL_PASSTHROUGH)  ? "passthrough" :
    (ctrl_flow == sparevideo_pkg::CTRL_MOTION_DETECT) ? "motion" :
    (ctrl_flow == sparevideo_pkg::CTRL_MASK_DISPLAY)  ? "mask" : "unknown");
```

### 4. `Makefile` / `dv/sim/Makefile` — accept `mask` value

The Makefile `CTRL_FLOW` variable already passes through as a string. The only change needed:
- Update the help text to include `mask`
- Adjust default `TOLERANCE` for mask mode (mask output differs entirely from input, so tolerance should be set high or verification should use a different model)

### 5. `hw/top/sparevideo_pkg.sv` — no other changes

The `ctrl_flow` constants are already being changed (step 1). No new parameters needed.

---

## Python Changes

### `py/models/mask.py` — mask display reference model

Add a Python reference model following the existing pattern (`passthrough.py`, `motion.py`). The mask model reuses the motion pipeline's luma extraction and frame-difference mask logic, but instead of computing a bounding box and overlaying it, it expands the raw 1-bit mask to 24-bit RGB:

```python
def run(frames, thresh=16, **kwargs):
    """Mask display reference model.

    Same motion detection front-end as motion.py (luma, frame-diff mask),
    but outputs the raw mask as black/white RGB instead of bbox overlay.
    """
```

**Algorithm (online, frame-by-frame with state):**

1. **Luma extraction** — identical to `motion.py`: `Y = (77*R + 150*G + 29*B) >> 8`
2. **Frame-difference motion mask** — identical to `motion.py`: `mask[y,x] = |Y_cur - Y_ref| > threshold`
3. **Mask-to-RGB expansion** — `mask=1` → `(255,255,255)`, `mask=0` → `(0,0,0)`
4. **Update reference buffer** — `Y_ref = Y_cur`

No bounding box, no priming suppression, no overlay delay. The mask display shows the raw mask as the motion detector produces it.

**Implementation note:** Import `_rgb_to_y` and `_compute_mask` from `motion.py` to avoid duplicating the luma/mask logic. These are the spec-defined operations and must stay in sync.

### `py/models/__init__.py` — register mask model

Add `"mask"` to the `_MODELS` dispatch dict:

```python
from models.mask import run as _run_mask

_MODELS = {
    "passthrough": _run_passthrough,
    "motion": _run_motion,
    "mask": _run_mask,
}
```

### `py/tests/test_models.py` — add mask model tests

**Mask identity (static scene):** Feed identical frames → all-black output (no motion, no mask pixels).

**Mask moving_box:** Feed `moving_box` frames → output is strictly black/white, white pixels form the region of displacement between consecutive frames.

**Mask frame 0:** First frame has Y_ref=0 (RAM init), so any non-black input pixel will produce motion → mostly white output. Verify this behavior matches RTL.

**Mask threshold boundary:** Pixel diffs at exactly `threshold` → black (no motion). Diffs at `threshold+1` → white (motion).

### `py/harness.py` — no changes needed

The `verify` subparser already accepts `--ctrl-flow` and dispatches to `run_model()`. Adding `"mask"` to the models package is sufficient — `harness.py` will automatically use the mask model for `CTRL_FLOW=mask`.

### Render step

The render step works as-is — it renders whatever frames are in the output file. The mask frames show up as black-and-white images in the comparison grid, which is exactly what we want for visual debugging.

---

## SV Testbench

### Test 1: Mask output matches motion detector's mask

**Stimulus:** Feed the `moving_box` synthetic source with `CTRL_FLOW=mask`.

**Expected:** Output pixels are either `24'h000000` (black) or `24'hFFFFFF` (white). No other values. The white pixels should form a region corresponding to the moving box's displacement between frames.

**Check:** Verify every output pixel is exactly black or white. Compare the binary mask (derived from output: white=1, black=0) against the mask from a `CTRL_FLOW=motion` run using the same input.

### Test 2: Passthrough and motion modes still work

**Stimulus:** Run existing test suite with `CTRL_FLOW=passthrough` and `CTRL_FLOW=motion`.

**Expected:** Identical output to before the change (the mux restructuring must not break existing paths).

**Check:** Bit-exact match with previous outputs.

### Test 3: Backpressure in mask mode

**Stimulus:** Feed frames while periodically stalling the output FIFO (via VGA blanking-induced backpressure).

**Expected:** No pixel drops, no FIFO overflow SVA violations. The mask output should be complete and correct.

**Check:** SVA assertions pass. Output frame has exactly `H_ACTIVE * V_ACTIVE` pixels.

### Test 4: First-frame behavior

**Stimulus:** Feed 3 frames with `CTRL_FLOW=mask`.

**Expected:** Frame 0's mask is meaningless (RAM not primed — everything looks like motion, so the output should be mostly white). Frame 1 onward should reflect actual motion. This matches the `PrimeFrames = 2` behavior in `axis_bbox_reduce`, but the mask display shows the *raw* mask before priming suppression — which is actually useful for debugging the priming logic itself.

**Check:** Frame 0 output is mostly white. Frame 2+ output has white only in the motion region.

---

## Acceptance Criteria

### Must pass:
- [ ] `make lint` — no new warnings
- [ ] `make test-ip` — no regression
- [ ] `make test-py` — mask model unit tests pass
- [ ] `make run-pipeline CTRL_FLOW=passthrough TOLERANCE=0` — exact match (no regression)
- [ ] `make run-pipeline CTRL_FLOW=motion` — still works with bbox overlay
- [ ] `make run-pipeline CTRL_FLOW=mask TOLERANCE=0` — pixel-accurate match against mask reference model
- [ ] Every output pixel in mask mode is exactly `000000` or `FFFFFF`
- [ ] No FIFO overflow or underrun in any mode

### Should verify visually:
- [ ] Rendered mask output shows white pixels only in the region where the synthetic source has motion
- [ ] Frame 0 mask is mostly white (RAM priming artifact — expected and useful to see)

---

## Integration Checklist

- [ ] Widen `ctrl_flow` in `sparevideo_pkg` from 1-bit to 2-bit
- [ ] Widen `ctrl_flow_i` port in `sparevideo_top`
- [ ] Widen `ctrl_flow` signal in `tb_sparevideo`
- [ ] Add mask-to-RGB expansion in `sparevideo_top`
- [ ] Update output mux to 3-way case
- [ ] Update input gating to activate motion pipeline for mask mode
- [ ] Handle mask `tready` backpressure in mask mode
- [ ] Add `"mask"` to TB plusarg parser
- [ ] Update Makefile help text
- [ ] Add `py/models/mask.py` reference model
- [ ] Register `"mask"` in `py/models/__init__.py`
- [ ] Add mask tests to `py/tests/test_models.py`
- [ ] Update `docs/specs/sparevideo-top-arch.md` control flow section
- [ ] Update `CLAUDE.md` to document the new control flow option

---

## Files Changed

| File | Change |
|------|--------|
| `hw/top/sparevideo_pkg.sv` | Widen control flow constants to 2-bit, add `CTRL_MASK_DISPLAY` |
| `hw/top/sparevideo_top.sv` | Widen port, add mask-RGB expansion, update mux + input gating + tready |
| `dv/sv/tb_sparevideo.sv` | Widen signal, add plusarg case |
| `Makefile` | Update help text |
| `dv/sim/Makefile` | No change (passes CTRL_FLOW as string already) |
| `py/models/mask.py` | **New** — mask display reference model (luma → mask → B/W RGB) |
| `py/models/__init__.py` | Register `"mask"` in `_MODELS` dispatch dict |
| `py/tests/test_models.py` | Add mask model tests (static, moving_box, frame 0, threshold) |
| `docs/specs/sparevideo-top-arch.md` | Document new control flow |
