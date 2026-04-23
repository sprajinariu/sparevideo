# Motion Grace Window — Frame-0 Ghost Suppression — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a configurable K-frame "grace window" that forces the bg update rate to the fast EMA (ignoring `raw_motion`) for the first K frames after priming, eliminating the frame-0 hard-init ghost that the current selective-EMA rule leaves behind for ~64 frames. Also document a Sobel-based edge-match ghost detector as the next escalation path in the arch spec.

**Architecture:** One new compile-time parameter `GRACE_FRAMES` (default 8). One new register in `axis_motion_detect.sv` (`grace_cnt`, `$clog2(GRACE_FRAMES+1)` bits, saturating) that increments on every `end_of_frame` while `primed && grace_cnt < GRACE_FRAMES`. The existing 3:1 `bg_next` mux grows a new condition: **during grace, use `ema_update` (fast) unconditionally instead of selecting via `raw_motion`**. `motion_core` is unchanged — the wrapper owns the grace logic. The mask output is **not** gated by grace (ghosts fade within K frames as bg self-corrects at α=1/8; user can escalate to Sobel if residual ghosts prove problematic).

**Tech Stack:** SystemVerilog RTL, Python reference model (numpy), Verilator simulation, pytest.

---

## Background

The current motion pipeline combines:
- **Frame-0 hard-init**: `bg[P] = y_smooth(frame_0[P])`, mask forced to 0 for frame 0.
- **Selective EMA from frame 1**: motion pixels update at `α = 1/(1<<ALPHA_SHIFT_SLOW) = 1/64` (default), non-motion at `α = 1/(1<<ALPHA_SHIFT) = 1/8`.

**The bug:** if an object is present in frame 0 and moves in frame 1, `bg[P_original]` holds foreground luma, so in frame 1 that pixel shows `raw_motion=1` (ghost). Selective EMA then keeps the ghost alive at α=1/64 ≈ 64 frames.

**The fix:** for the first `GRACE_FRAMES` frames after priming, bypass `raw_motion` in the rate selector and always use the fast rate. The ghost at `P_original` decays in ~`1/α_fast = 8` frames instead of ~64.

**Design rationale:** this is the canonical "hybrid blind + selective update" pattern from the background-subtraction literature (see references in the arch doc follow-ups section). The grace window is a *time-based* approximation of the deeper "motion-stuck counter" technique (ViBe-style per-pixel blink counters). We adopt the cheaper time-based version first; the per-pixel counter is documented as a future option only if grace proves insufficient.

---

## File Structure

| File | Responsibility | Change type |
|---|---|---|
| `docs/specs/axis_motion_detect-arch.md` | RTL architecture spec | Modify: add `GRACE_FRAMES` param; extend §4.4 priming text; add Sobel follow-up section |
| `CLAUDE.md` | Project-wide guidance | Modify: update "Motion pipeline — lessons learned" with grace-window rule |
| `README.md` | Build & param docs | Modify: add `GRACE_FRAMES` to param tables |
| `Makefile` (top) | Build orchestration | Modify: add `GRACE_FRAMES ?= 8`, propagate to sim and python |
| `dv/sim/Makefile` | Simulator invocation | Modify: add `GRACE_FRAMES`, `-GGRACE_FRAMES`, config stamp |
| `dv/sv/tb_sparevideo.sv` | Top-level TB | Modify: add `GRACE_FRAMES` parameter, plumb to DUT |
| `hw/top/sparevideo_top.sv` | Top RTL | Modify: add `GRACE_FRAMES` parameter, plumb to `axis_motion_detect` |
| `hw/ip/motion/rtl/axis_motion_detect.sv` | Motion wrapper | Modify: add `GRACE_FRAMES` param, `grace_cnt`, `in_grace`, updated `bg_next` mux |
| `hw/ip/motion/rtl/motion_core.sv` | Motion comb logic | **Unchanged** — grace lives in wrapper |
| `hw/ip/motion/tb/tb_axis_motion_detect.sv` | Unit TB | Modify: add `GRACE_FRAMES` localparam, track `tb_grace_cnt`, update `update_y_prev` |
| `py/models/motion.py` | Motion reference model | Modify: `_selective_ema_update` gains `in_grace` arg; `run()` tracks grace counter |
| `py/models/mask.py` | Mask-display model | Modify: mirror the same grace rule |
| `py/models/ccl_bbox.py` | ccl_bbox model | Modify: mirror the same grace rule |
| `py/harness.py` | Pipeline harness | Modify: accept/pass `--grace-frames` arg |
| `py/tests/test_models.py` | Model unit tests | Modify: add 3 grace-window tests |

---

## Task 1: Documentation updates

Rationale: per the project convention ("update docs before RTL"), pin the design in prose first. This also defines the `GRACE_FRAMES=0 ≡ current behavior` invariant that Task 2's regression test relies on.

**Files:**
- Modify: `docs/specs/axis_motion_detect-arch.md`
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `Makefile` (help text only)

- [ ] **Step 1.1: Update `docs/specs/axis_motion_detect-arch.md` parameter table**

In §3.1 (or wherever parameters are listed), add a row for `GRACE_FRAMES`:

```
| GRACE_FRAMES     | 8        | Number of frames after priming during which bg updates use the fast EMA rate unconditionally (ignoring raw_motion). Suppresses frame-0 hard-init ghosts. Set to 0 to disable (recover pre-grace selective-EMA behavior). |
```

- [ ] **Step 1.2: Update `docs/specs/axis_motion_detect-arch.md` §4.4 (priming + EMA rule)**

Extend the existing selective-EMA description. Add this text after the existing two-rate explanation:

```
### 4.4.3 Grace window

Frame-0 hard-init seeds bg directly from frame-0 luma. If any pixel is
occupied by a moving object during frame 0, that pixel's bg is contaminated
with foreground luma. In frame 1 the object has moved on, so the pixel
shows true background vs. a foreground-valued bg and is flagged as motion
— a "ghost" at the object's frame-0 location.

Under the plain selective-EMA rule, this ghost updates at the slow rate
(α ≈ 1/64) and persists for ~64 frames.

The grace window overrides the rate selector for the first GRACE_FRAMES
frames after priming completes:

  in_grace = primed && (grace_cnt < GRACE_FRAMES)

  bg_next = !primed                      ? y_smooth
          : (in_grace || !raw_motion)    ? ema_update       (fast, α = 1/(1<<ALPHA_SHIFT))
          :                                 ema_update_slow (slow, α = 1/(1<<ALPHA_SHIFT_SLOW))

`grace_cnt` is a wrapper-level register, `$clog2(GRACE_FRAMES+1)` bits,
reset to 0 and incremented on every `beat_done_eof` while
`primed && grace_cnt < GRACE_FRAMES`. Once `grace_cnt == GRACE_FRAMES` the
counter saturates and the mux reverts to the plain selective-EMA rule.

During the grace window the ghost decays at α ≈ 1/8 — within GRACE_FRAMES=8
frames the bg[P_original] has moved ~66% of the way toward true background,
and `|y_cur - bg| < THRESH` becomes true soon after (exact convergence
depends on luma delta and THRESH). The mask output is NOT gated by grace;
residual ghosts during grace are visible but fade quickly and CCL/bbox
suppression (PRIME_FRAMES=2) already hides the worst of the first two frames.

Setting GRACE_FRAMES=0 disables the override: in_grace is always false, and
behavior reverts to plain selective-EMA (preserved for regression parity).
```

- [ ] **Step 1.3: Add a "Follow-Ups / Future Improvements" section to `docs/specs/axis_motion_detect-arch.md`**

Append a new section at the end of the document (after the current last section):

```
## 10. Follow-Ups / Future Improvements

### 10.1 Edge-match ghost detector (Sobel-based)

If real-scene testing reveals ghosts that survive the grace window — e.g.,
an object that was stationary throughout the first GRACE_FRAMES frames and
then moves, or a grace window too short to let bg converge below THRESH —
the next escalation is an edge-based ghost detector.

Motivation
----------
A ghost region is a "phantom motion" blob with no corresponding real object.
The defining property: the edges inside a ghost blob match the background
model's edges (because the ghost is revealed true background), while a real
moving object has edges that do not match the bg model (the foreground
content differs from bg).

Technique
---------
1. Apply a cheap edge operator (3x3 Sobel, 8-neighbor gradient magnitude) to
   both `y_cur` and `y_bg` in parallel with the existing threshold path.
2. For each motion pixel (raw_motion=1), compare `edge(y_cur)` and `edge(y_bg)`:
   - If they match (within a small tolerance EDGE_MATCH_TOL), classify the
     pixel as ghost and force `mask_bit=0` and `bg_next=ema_update` (fast
     rate) to accelerate bg self-correction.
   - Otherwise, normal selective-EMA rule applies.
3. Optionally gate the ghost classifier on a blob-level statistic from CCL
   (e.g., reject ghost-only if ≥80% of the CCL component's pixels are
   edge-matching), to avoid false-positive ghost calls on real objects with
   low internal texture.

Cost estimate
-------------
- One Sobel line buffer (3×H_ACTIVE × 8-bit ≈ 960 B at H=320) per image
  (current and bg) — 2× cost shared with the existing Gaussian filter's
  line buffers. Possibly reusable.
- Two adder trees for gradient magnitude (|Gx| + |Gy|, not sqrt).
- One comparator per output.
- No change to RAM ports or data widths.

Trigger condition
-----------------
Only implement this if real-scene verification reveals residual ghosts that
tuning GRACE_FRAMES (up to ~16) cannot suppress. Synthetic `moving_box` and
`dark_moving_box` are not expected to need it once the grace window is in
place.

References
----------
- Cucchiara et al., "Detecting Moving Objects, Ghosts and Shadows in Video
  Streams," IEEE TPAMI 2003 — original object-level ghost/shadow classifier.
- Sehairi et al., "Comparative study of motion detection methods" (arXiv:
  1804.05459) — survey of ghost-suppression approaches.
- MDPI Sensors 2020 — "Ghost Detection and Removal Based on Two-Layer
  Background Model and Histogram Similarity" (more expensive, not proposed
  here).

### 10.2 Motion-stuck per-pixel counter (ViBe-style)

Per-pixel counter that tracks how many consecutive frames a pixel has been
flagged as motion. If it exceeds a threshold (e.g., 2 × GRACE_FRAMES), force
the pixel to the fast EMA rate regardless of `raw_motion`. Cost: `log2(K)`
bits per pixel (~4-6 bits × H×V ≈ 50-100 kbit at 320×240). Targets ghosts
that arrive *after* the grace window. More principled than grace but more
expensive. Consider only if grace + edge-match together still leave residuals.
```

- [ ] **Step 1.4: Update `CLAUDE.md` "Motion pipeline — lessons learned" section**

In the existing "Frame-0 hard-init + selective EMA" bullet, append:

```
**Grace window prevents frame-0 ghosts.** Hard-init seeds bg from frame 0,
so any object present in frame 0 contaminates bg[P_original]. When the
object moves in frame 1, raw_motion latches at P_original and the slow
selective-EMA rate keeps that ghost alive for ~1/α_slow frames. The
`GRACE_FRAMES` parameter (default 8) forces the fast rate unconditionally
for the first K frames after priming — the ghost decays at α=1/8 within K
frames, after which the normal selective-EMA rule resumes. Set GRACE_FRAMES=0
to disable (recovers pre-grace behavior for regression parity).
```

Also update the parameter propagation example to include `GRACE_FRAMES` alongside `ALPHA_SHIFT` and `ALPHA_SHIFT_SLOW`.

- [ ] **Step 1.5: Update `README.md`**

In the parameter table (wherever `ALPHA_SHIFT_SLOW` is listed), add:

```
| GRACE_FRAMES     | 8 | Frames after priming where bg updates use the fast EMA rate unconditionally. Suppresses frame-0 hard-init ghosts. Set to 0 to disable. |
```

In the motion tuning example, add a `GRACE_FRAMES=8` or `GRACE_FRAMES=16` example alongside the existing `ALPHA_SHIFT`/`ALPHA_SHIFT_SLOW` tuning.

- [ ] **Step 1.6: Update top `Makefile` help text**

In the `help:` target (around line 83), add a row:

```
	@echo "    GRACE_FRAMES=8                   Fast-EMA grace window after priming (default 8)"
```

- [ ] **Step 1.7: Commit**

```bash
git add docs/specs/axis_motion_detect-arch.md CLAUDE.md README.md Makefile
git commit -m "docs(motion): document grace window + Sobel ghost-detector follow-up"
```

---

## Task 2: Python reference model + tests (TDD)

Rationale: the Python model is the spec-driven golden reference. RTL must be bit-exact against it. TDD: write the tests first, let them fail, then update the model.

**Files:**
- Modify: `py/models/motion.py`
- Modify: `py/models/mask.py`
- Modify: `py/models/ccl_bbox.py`
- Modify: `py/tests/test_models.py`

- [ ] **Step 2.1: Add failing test `test_motion_grace_window_zero_equals_no_grace`**

This test pins the invariant `GRACE_FRAMES=0 ⇒ pre-grace selective-EMA behavior` — the model's regression safety net.

Add to `py/tests/test_models.py`:

```python
def test_motion_grace_window_zero_equals_no_grace():
    """GRACE_FRAMES=0 must produce identical bg trajectory to plain selective EMA."""
    from models.motion import _run_bg_trace

    # Scene: object in frame 0, moves in frame 1+, static after
    h, w = 16, 16
    frames = []
    for i in range(6):
        f = np.full((h, w, 3), 200, dtype=np.uint8)  # white bg
        if i == 0:
            f[4:8, 4:8] = [10, 10, 10]  # dark box at (4..7, 4..7)
        elif i < 3:
            f[4:8, 10:14] = [10, 10, 10]  # dark box moved right
        frames.append(f)

    # With grace_frames=0, behavior must match the plain selective-EMA path.
    trace_with_grace_zero = _run_bg_trace(
        frames, alpha_shift=3, alpha_shift_slow=6, grace_frames=0
    )
    trace_no_grace_arg = _run_bg_trace(
        frames, alpha_shift=3, alpha_shift_slow=6  # default grace_frames=0
    )
    for a, b in zip(trace_with_grace_zero, trace_no_grace_arg):
        np.testing.assert_array_equal(a, b)
```

- [ ] **Step 2.2: Add failing test `test_motion_grace_window_clears_frame0_ghost`**

This is the bug test — proves the ghost is suppressed.

Add to `py/tests/test_models.py`:

```python
def test_motion_grace_window_clears_frame0_ghost():
    """Object present in frame 0 that moves in frame 1 must not produce a
    persistent ghost at its frame-0 location when grace window is active."""
    from models.motion import run

    # Scene: dark box at (4..7, 4..7) in frame 0, moves to (4..7, 10..13) in
    # frames 1..10, then stays there. We check the mask at the ORIGINAL
    # location (4..7, 4..7) to see if a ghost persists.
    h, w = 24, 24
    frames = []
    for i in range(12):
        f = np.full((h, w, 3), 220, dtype=np.uint8)
        if i == 0:
            f[4:8, 4:8] = [10, 10, 10]
        else:
            f[4:8, 10:14] = [10, 10, 10]
        frames.append(f)

    # With grace_frames=8, by frame 10 the ghost at (4..7, 4..7) must be
    # fully gone (bg self-corrected at fast rate during grace).
    outputs = run(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6,
                  grace_frames=8, gauss_en=False)

    # Sample the mask at frame 10 by comparing output with input at ghost
    # region. Since `run()` returns RGB with bbox overlay, we can't easily
    # recover the mask. Instead, use the bg_trace helper and recompute.
    from models.motion import _run_bg_trace, _rgb_to_y, _compute_mask
    trace = _run_bg_trace(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6,
                          grace_frames=8, gauss_en=False)
    y_f10 = _rgb_to_y(frames[10])
    mask_f10 = _compute_mask(y_f10, trace[9], 16)  # mask uses bg from frame 9

    # Ghost region must be clean: no motion pixels at frame-0 object location
    assert not mask_f10[4:8, 4:8].any(), \
        f"ghost persists at frame 10: mask[4:8,4:8]={mask_f10[4:8, 4:8]}"
```

- [ ] **Step 2.3: Add failing test `test_motion_grace_window_preserves_trail_suppression`**

This ensures the grace window doesn't break the existing trail-suppression guarantee (object that moves AFTER grace must not leave a trail).

Add to `py/tests/test_models.py`:

```python
def test_motion_grace_window_preserves_trail_suppression():
    """After grace window ends, selective EMA must still suppress trails."""
    from models.motion import _run_bg_trace, _rgb_to_y, _compute_mask

    # Empty scene for 10 frames (longer than grace), then object appears and
    # moves, then leaves. Trail suppression is about departure, so we care
    # about frames AFTER the object has left.
    h, w = 24, 24
    frames = []
    # Frames 0-9: empty background (establish clean bg, outlasts grace=8)
    for i in range(10):
        frames.append(np.full((h, w, 3), 220, dtype=np.uint8))
    # Frames 10-13: object enters and moves
    for i in range(4):
        f = np.full((h, w, 3), 220, dtype=np.uint8)
        f[4:8, 4 + i:8 + i] = [10, 10, 10]
        frames.append(f)
    # Frames 14-18: object gone, empty scene again
    for i in range(5):
        frames.append(np.full((h, w, 3), 220, dtype=np.uint8))

    trace = _run_bg_trace(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6,
                          grace_frames=8, gauss_en=False)

    # At frame 18 (4 frames after object departure), the trail at the LAST
    # position the object occupied (4..7, 7..10) must not be flagged as
    # motion — selective EMA on motion pixels uses slow rate, so the object
    # barely contaminated bg while present, and there is no trail on exit.
    y_f18 = _rgb_to_y(frames[18])
    mask_f18 = _compute_mask(y_f18, trace[17], 16)

    # Departure region clean (no trail after 4 empty frames)
    assert not mask_f18[4:8, 7:11].any(), \
        f"trail persists at frame 18: mask[4:8,7:11]={mask_f18[4:8, 7:11]}"
```

- [ ] **Step 2.4: Run tests — expect all three to fail**

```bash
source .venv/bin/activate
pytest py/tests/test_models.py::test_motion_grace_window_zero_equals_no_grace \
       py/tests/test_models.py::test_motion_grace_window_clears_frame0_ghost \
       py/tests/test_models.py::test_motion_grace_window_preserves_trail_suppression -v
```

Expected: all three FAIL. First two fail with `TypeError: _run_bg_trace() got unexpected keyword argument 'grace_frames'` (or similar); third might pass coincidentally — re-check after impl.

- [ ] **Step 2.5: Update `py/models/motion.py` — add grace-window logic**

Replace the `_run_bg_trace` function with:

```python
def _run_bg_trace(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6,
                  grace_frames=0, gauss_en=True):
    """Run the motion model's bg trajectory for inspection. Returns a list of
    bg arrays — one per frame, representing the RAM state after that frame is
    processed. Does not produce visual output.

    `grace_frames`: during the first K frames after priming, bg updates use
    the fast EMA rate unconditionally (ignoring the mask). This suppresses
    frame-0 hard-init ghosts. K=0 disables (recovers plain selective-EMA).
    """
    if not frames:
        return []
    h, w = frames[0].shape[:2]
    y_bg = np.zeros((h, w), dtype=np.uint8)
    primed = False
    grace_cnt = 0  # counts frames since priming completed
    trace = []
    for i, frame in enumerate(frames):
        y_cur = _rgb_to_y(frame)
        y_cur_filt = _gauss3x3(y_cur) if gauss_en else y_cur
        if not primed:
            y_bg = y_cur_filt.copy()
            primed = True
        else:
            mask = _compute_mask(y_cur_filt, y_bg, thresh)
            in_grace = grace_cnt < grace_frames
            if in_grace:
                # Fast rate everywhere — ignore mask
                y_bg = _ema_update(y_cur_filt, y_bg, alpha_shift)
                grace_cnt += 1
            else:
                y_bg = _selective_ema_update(y_cur_filt, y_bg, mask,
                                              alpha_shift, alpha_shift_slow)
        trace.append(y_bg.copy())
    return trace
```

Also update the `run()` function signature and internals to accept and use `grace_frames`:

```python
def run(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6, grace_frames=0,
        gauss_en=True, **kwargs):
    """Motion pipeline reference model (CCL-based, multi-bbox).

    Frame 0: priming — bg[px] = Y_smooth(frame_0[px]), mask forced to 0.
    Frames 1..grace_frames: fast-EMA grace window — bg updates use α = 1/(1<<alpha_shift)
    regardless of mask. Suppresses frame-0 hard-init ghosts.
    Frames > grace_frames: selective EMA — motion pixels drift at slow rate,
    non-motion at fast rate.
    """
    if not frames:
        return []

    h, w = frames[0].shape[:2]
    y_bg = np.zeros((h, w), dtype=np.uint8)
    primed = False
    grace_cnt = 0
    bboxes_state = [None] * N_OUT

    outputs = []
    for i, frame in enumerate(frames):
        y_cur = _rgb_to_y(frame)
        y_cur_filt = _gauss3x3(y_cur) if gauss_en else y_cur

        if not primed:
            # Frame 0 — hard-init bg, mask forced to zero
            mask = np.zeros((h, w), dtype=bool)
            out = _draw_bboxes(frame, bboxes_state)
            new_bboxes = run_ccl(
                [mask],
                n_out=N_OUT,
                n_labels_int=N_LABELS_INT,
                min_component_pixels=MIN_COMPONENT_PIXELS,
                max_chain_depth=MAX_CHAIN_DEPTH,
            )[0]
            y_bg = y_cur_filt.copy()
            primed = True
        else:
            mask = _compute_mask(y_cur_filt, y_bg, thresh)
            out = _draw_bboxes(frame, bboxes_state)
            new_bboxes = run_ccl(
                [mask],
                n_out=N_OUT,
                n_labels_int=N_LABELS_INT,
                min_component_pixels=MIN_COMPONENT_PIXELS,
                max_chain_depth=MAX_CHAIN_DEPTH,
            )[0]
            in_grace = grace_cnt < grace_frames
            if in_grace:
                y_bg = _ema_update(y_cur_filt, y_bg, alpha_shift)
                grace_cnt += 1
            else:
                y_bg = _selective_ema_update(y_cur_filt, y_bg, mask,
                                              alpha_shift, alpha_shift_slow)

        primed_for_bbox = (i >= PRIME_FRAMES)
        bboxes_state = new_bboxes if primed_for_bbox else [None] * N_OUT

        outputs.append(out)

    return outputs
```

- [ ] **Step 2.6: Run tests — expect all three to pass**

```bash
pytest py/tests/test_models.py::test_motion_grace_window_zero_equals_no_grace \
       py/tests/test_models.py::test_motion_grace_window_clears_frame0_ghost \
       py/tests/test_models.py::test_motion_grace_window_preserves_trail_suppression -v
```

Expected: all three PASS.

- [ ] **Step 2.7: Apply the same grace-window logic to `py/models/mask.py`**

Read `py/models/mask.py`. The `run()` function there has identical EMA+priming logic to `motion.py`. Add `grace_frames` parameter with default 0, mirror the same grace-window branching pattern:

```python
def run(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6, grace_frames=0,
        gauss_en=True, **kwargs):
    # ... existing setup ...
    primed = False
    grace_cnt = 0
    # ... for each frame ...
    if not primed:
        # hard-init, mask=0
        ...
    else:
        mask = _compute_mask(...)
        in_grace = grace_cnt < grace_frames
        if in_grace:
            y_bg = _ema_update(y_cur_filt, y_bg, alpha_shift)
            grace_cnt += 1
        else:
            y_bg = _selective_ema_update(...)
```

- [ ] **Step 2.8: Apply the same grace-window logic to `py/models/ccl_bbox.py`**

Same pattern as Step 2.7.

- [ ] **Step 2.9: Update `py/harness.py` to accept `--grace-frames`**

Find the `verify` and `render` subparsers (same place `--alpha-shift-slow` is added). Add:

```python
subparser.add_argument("--grace-frames", type=int, default=0,
                       help="Fast-EMA grace window frames after priming (default 0, must match RTL)")
```

Pass `grace_frames=args.grace_frames` into `run_model(...)` calls.

- [ ] **Step 2.10: Run full Python test suite**

```bash
pytest py/tests/ -v
```

Expected: all tests pass (previous count + 3 new = 49).

- [ ] **Step 2.11: Commit**

```bash
git add py/models/motion.py py/models/mask.py py/models/ccl_bbox.py py/harness.py py/tests/test_models.py
git commit -m "feat(motion-py): add grace-window fast-EMA override for frame-0 ghost suppression"
```

---

## Task 3: RTL — axis_motion_detect + unit TB

Rationale: `motion_core` stays pure-combinational and unchanged. The grace counter and modified `bg_next` mux live in the wrapper, alongside the existing `primed` register and the selective-EMA mux they extend.

**Files:**
- Modify: `hw/ip/motion/rtl/axis_motion_detect.sv`
- Modify: `hw/ip/motion/tb/tb_axis_motion_detect.sv`

- [ ] **Step 3.1: Add `GRACE_FRAMES` parameter and `grace_cnt` register to `axis_motion_detect.sv`**

After the existing `ALPHA_SHIFT_SLOW` parameter (line 56), add:

```systemverilog
    parameter int ALPHA_SHIFT_SLOW = 6,    // alpha = 1/(1 << ALPHA_SHIFT_SLOW), default 1/64 — motion rate
    parameter int GRACE_FRAMES     = 8,    // fast-EMA grace frames after priming; 0 disables
    parameter int GAUSS_EN         = 1,    // 1 = Gaussian pre-filter enabled, 0 = bypass (raw Y)
```

Add a localparam for counter width, immediately after the existing `IDX_W` localparam (line 86):

```systemverilog
    localparam int IDX_W        = $clog2(H_ACTIVE * V_ACTIVE);
    localparam int GRACE_CNT_W  = (GRACE_FRAMES > 0) ? $clog2(GRACE_FRAMES + 1) : 1;
```

- [ ] **Step 3.2: Add grace counter logic in `axis_motion_detect.sv`**

After the `primed` register block (currently ending around line 278), add:

```systemverilog
    // ---- Grace-window counter: fast-EMA override for first GRACE_FRAMES frames after priming. ----
    // While `in_grace == 1`, bg_next always uses ema_update (fast rate), regardless of raw_motion.
    // This suppresses the frame-0 hard-init ghost (any object present in frame 0 contaminates
    // bg[P_original]; without grace, the slow EMA keeps that ghost alive for ~1/α_slow frames).
    logic [GRACE_CNT_W-1:0] grace_cnt;
    logic                   in_grace;

    assign in_grace = primed && (grace_cnt < (GRACE_CNT_W)'(GRACE_FRAMES));

    always_ff @(posedge clk_i) begin
        if (!rst_n_i)
            grace_cnt <= '0;
        else if (beat_done_eof && in_grace)
            grace_cnt <= grace_cnt + 1'b1;
    end
```

- [ ] **Step 3.3: Update the `bg_next` mux in `axis_motion_detect.sv`**

Replace the existing `bg_next` combinational block (currently around lines 302-310) with:

```systemverilog
    // ---- Memory write-back: priming (hard-init) / grace (fast EMA) / motion (slow EMA) / non-motion (fast EMA) ----
    // Fire on beat_done so each accepted output writes exactly once.
    logic [7:0] bg_next;
    always_comb begin
        if (!primed)
            bg_next = y_smooth;        // frame-0 hard-init
        else if (in_grace || !raw_motion)
            bg_next = ema_update;      // grace-window or non-motion pixel → fast rate
        else
            bg_next = ema_update_slow; // motion pixel (post-grace) → slow rate
    end
```

- [ ] **Step 3.4: Run lint on the modified RTL**

```bash
make lint
```

Expected: PASS with no new warnings. If a new warning about `GRACE_CNT_W` unused-width or similar appears, inspect and add width casts as needed.

- [ ] **Step 3.5: Update `hw/ip/motion/tb/tb_axis_motion_detect.sv` — add GRACE_FRAMES parameter**

Add after the existing `ALPHA_SHIFT_SLOW` localparam (around line 35):

```systemverilog
    localparam int ALPHA_SHIFT_SLOW = 6;
    localparam int GRACE_FRAMES     = 8;
```

Pass `GRACE_FRAMES` into the DUT instantiation (after `.ALPHA_SHIFT_SLOW`):

```systemverilog
        .ALPHA_SHIFT_SLOW (ALPHA_SHIFT_SLOW),
        .GRACE_FRAMES     (GRACE_FRAMES),
```

- [ ] **Step 3.6: Add `tb_grace_cnt` tracker in `tb_axis_motion_detect.sv`**

Near the existing `tb_primed` declaration (around line 173), add:

```systemverilog
    // TB-side tracking of the DUT's grace counter.
    // Increments once per frame while tb_primed==1 and tb_grace_cnt < GRACE_FRAMES.
    int tb_grace_cnt = 0;
```

- [ ] **Step 3.7: Update `update_y_prev` task in `tb_axis_motion_detect.sv` to implement grace-window logic**

The existing task handles !tb_primed (hard-init) and tb_primed (selective EMA). Modify it so that when `tb_primed && tb_grace_cnt < GRACE_FRAMES`, the update uses the fast rate unconditionally:

Replace the relevant branch (around line 304-320) with:

```systemverilog
        if (!tb_primed) begin
            // Hard-init branch
            y_prev[i] = y_smooth;
            // ...existing priming logic...
            tb_primed = 1'b1;
        end else begin
            logic signed [8:0] delta;
            logic signed [8:0] step_fast;
            logic signed [8:0] step_slow;
            logic              raw_motion;

            delta      = {1'b0, y_smooth} - {1'b0, y_prev[i]};
            step_fast  = delta >>> ALPHA_SHIFT;
            step_slow  = delta >>> ALPHA_SHIFT_SLOW;
            raw_motion = ((y_smooth > y_prev[i]) ? (y_smooth - y_prev[i])
                                                 : (y_prev[i] - y_smooth)) > THRESH;

            if ((tb_grace_cnt < GRACE_FRAMES) || !raw_motion)
                y_prev[i] = y_prev[i] + step_fast[7:0];  // fast rate
            else
                y_prev[i] = y_prev[i] + step_slow[7:0];  // slow rate
        end
```

After the full-frame update loop, increment `tb_grace_cnt`:

```systemverilog
        if (tb_primed && (tb_grace_cnt < GRACE_FRAMES))
            tb_grace_cnt = tb_grace_cnt + 1;
```

- [ ] **Step 3.8: Run unit TBs**

```bash
make test-ip
```

Expected: PASS. The `tb_axis_motion_detect` test compares RTL mask against the TB-computed expected mask; the grace-window logic must match bit-for-bit.

- [ ] **Step 3.9: Commit**

```bash
git add hw/ip/motion/rtl/axis_motion_detect.sv hw/ip/motion/tb/tb_axis_motion_detect.sv
git commit -m "feat(motion-rtl): add GRACE_FRAMES fast-EMA override for frame-0 ghost suppression"
```

---

## Task 4: Parameter propagation through the build chain

Rationale: per CLAUDE.md "Motion pipeline — lessons learned §2", compile-time `-G` parameters must traverse: top Makefile → dv/sim Makefile → TB → top RTL → IP. Missing any link silently bakes in the default instead of the requested value.

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv` (optional — only if the package exposes ALPHA_SHIFT_SLOW; check first)
- Modify: `hw/top/sparevideo_top.sv`
- Modify: `dv/sv/tb_sparevideo.sv`
- Modify: `dv/sim/Makefile`
- Modify: `Makefile` (top)

- [ ] **Step 4.1: Add `GRACE_FRAMES` to `hw/top/sparevideo_top.sv` parameters**

After the existing `ALPHA_SHIFT_SLOW` parameter (line 37), add:

```systemverilog
    // Fast-EMA grace window after priming: for GRACE_FRAMES frames, bg updates
    // at the fast rate regardless of raw_motion, suppressing frame-0 ghosts.
    parameter int GRACE_FRAMES = 8,
```

Pass it into the `axis_motion_detect` instantiation (after `.ALPHA_SHIFT_SLOW`):

```systemverilog
        .ALPHA_SHIFT_SLOW (ALPHA_SHIFT_SLOW),
        .GRACE_FRAMES     (GRACE_FRAMES),
```

- [ ] **Step 4.2: Add `GRACE_FRAMES` to `dv/sv/tb_sparevideo.sv`**

After the existing `ALPHA_SHIFT_SLOW` parameter (line 24), add:

```systemverilog
    parameter int GRACE_FRAMES     = 8,
```

Pass it into the DUT instantiation (after `.ALPHA_SHIFT_SLOW`):

```systemverilog
        .ALPHA_SHIFT_SLOW (ALPHA_SHIFT_SLOW),
        .GRACE_FRAMES     (GRACE_FRAMES),
```

- [ ] **Step 4.3: Add `GRACE_FRAMES` to `dv/sim/Makefile`**

After the existing `ALPHA_SHIFT_SLOW ?= 6` (line 27), add:

```makefile
GRACE_FRAMES     ?= 8
```

Update the VLT_FLAGS line (line 77) to include `-GGRACE_FRAMES`:

```makefile
            -GH_ACTIVE=$(WIDTH) -GV_ACTIVE=$(HEIGHT) -GALPHA_SHIFT=$(ALPHA_SHIFT) -GALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW) -GGRACE_FRAMES=$(GRACE_FRAMES) -GGAUSS_EN=$(GAUSS_EN) \
```

Update the CONFIG_STAMP line (line 91) to include `GRACE_FRAMES` so param changes trigger recompilation:

```makefile
	@echo "$(WIDTH) $(HEIGHT) $(ALPHA_SHIFT) $(ALPHA_SHIFT_SLOW) $(GRACE_FRAMES) $(GAUSS_EN)" | cmp -s - $@ || echo "$(WIDTH) $(HEIGHT) $(ALPHA_SHIFT) $(ALPHA_SHIFT_SLOW) $(GRACE_FRAMES) $(GAUSS_EN)" > $@
```

- [ ] **Step 4.4: Add `GRACE_FRAMES` to top `Makefile`**

After the existing `ALPHA_SHIFT_SLOW ?= 6` (line 20), add:

```makefile
# Fast-EMA grace window after priming (frames). Default 8. Set to 0 to disable.
GRACE_FRAMES ?= 8
```

Update the `$(SIM_VARS)` line (line 40) — append:

```makefile
           ALPHA_SHIFT=$(ALPHA_SHIFT) ALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW) GRACE_FRAMES=$(GRACE_FRAMES) GAUSS_EN=$(GAUSS_EN) \
```

Update the `prepare` config-stamp `printf` (line 112-113) to include `GRACE_FRAMES`:

```makefile
	@printf 'SOURCE = %s\nWIDTH = %s\nHEIGHT = %s\nFRAMES = %s\nMODE = %s\nCTRL_FLOW = %s\nALPHA_SHIFT = %s\nALPHA_SHIFT_SLOW = %s\nGRACE_FRAMES = %s\nGAUSS_EN = %s\n' \
		'$(SOURCE)' '$(WIDTH)' '$(HEIGHT)' '$(FRAMES)' '$(MODE)' '$(CTRL_FLOW)' '$(ALPHA_SHIFT)' '$(ALPHA_SHIFT_SLOW)' '$(GRACE_FRAMES)' '$(GAUSS_EN)' > $(DATA_DIR)/config.mk
```

Update the `verify` target (line 140) to pass `--grace-frames`:

```makefile
		--alpha-shift $(ALPHA_SHIFT) --alpha-shift-slow $(ALPHA_SHIFT_SLOW) --grace-frames $(GRACE_FRAMES) --gauss-en $(GAUSS_EN)
```

Update the `render` target (lines 151-152) similarly:

```makefile
		--mode $(MODE) --ctrl-flow $(CTRL_FLOW) --alpha-shift $(ALPHA_SHIFT) \
		--alpha-shift-slow $(ALPHA_SHIFT_SLOW) --grace-frames $(GRACE_FRAMES) --gauss-en $(GAUSS_EN) --render-output $(RENDER_OUT)
```

Update `RENDER_OUT` filename (line 143) to include grace:

```makefile
RENDER_OUT = $(CURDIR)/$(DATA_DIR)/renders/$(RENDER_SOURCE_SAFE)__width=$(WIDTH)__height=$(HEIGHT)__frames=$(FRAMES)__ctrl-flow=$(CTRL_FLOW)__alpha-shift=$(ALPHA_SHIFT)__alpha-shift-slow=$(ALPHA_SHIFT_SLOW)__grace=$(GRACE_FRAMES)__gauss-en=$(GAUSS_EN).png
```

- [ ] **Step 4.5: Sanity-check the passthrough flow still compiles and runs**

```bash
make clean
make sim CTRL_FLOW=passthrough TOLERANCE=0
```

Expected: PASS. If fail, re-read error — usually a parameter name typo or missing `-G` flag.

- [ ] **Step 4.6: Commit**

```bash
git add Makefile dv/sim/Makefile dv/sv/tb_sparevideo.sv hw/top/sparevideo_top.sv
git commit -m "feat(build): thread GRACE_FRAMES through Makefile/TB/top chain"
```

---

## Task 5: Integration verification

Rationale: the full matrix per CLAUDE.md — 4 control flows × parameter combinations × multiple sources at TOLERANCE=0. Plus a visual check for the specific ghost the grace window is designed to fix.

- [ ] **Step 5.1: Lint clean**

```bash
make lint
```

Expected: PASS with no new warnings.

- [ ] **Step 5.2: All unit TBs green**

```bash
make test-ip
```

Expected: PASS (all motion, CCL, gauss, axis, overlay TBs).

- [ ] **Step 5.3: Passthrough regression**

```bash
make clean && make run-pipeline CTRL_FLOW=passthrough TOLERANCE=0
```

Expected: PASS.

- [ ] **Step 5.4: Mask flow on all motion sources**

```bash
for src in moving_box dark_moving_box noisy_moving_box; do
  make clean
  make run-pipeline SOURCE="synthetic:$src" CTRL_FLOW=mask FRAMES=12 TOLERANCE=0 || exit 1
done
```

Expected: all PASS at TOLERANCE=0 (model-vs-RTL bit-exact).

- [ ] **Step 5.5: Motion flow on sources**

```bash
for src in moving_box two_boxes; do
  make clean
  make run-pipeline SOURCE="synthetic:$src" CTRL_FLOW=motion FRAMES=12 TOLERANCE=0 || exit 1
done
```

Expected: all PASS at TOLERANCE=0.

- [ ] **Step 5.6: ccl_bbox flow**

```bash
make clean
make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=ccl_bbox FRAMES=8 TOLERANCE=0
```

Expected: PASS.

- [ ] **Step 5.7: Grace-window regression matrix**

```bash
# GRACE_FRAMES=0 must preserve pre-grace behavior (no new ghosts vs. pre-grace baseline,
# but also no worse — this is the "disable" knob).
make clean && make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=mask GRACE_FRAMES=0 TOLERANCE=0

# GRACE_FRAMES=8 default — the ghost-suppression fix
make clean && make run-pipeline SOURCE="synthetic:dark_moving_box" CTRL_FLOW=mask GRACE_FRAMES=8 TOLERANCE=0

# Parameter sweep — ALPHA and GRACE co-vary
for a in 0 3; do
  for s in 5 7; do
    for g in 0 8 16; do
      make clean
      make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=mask FRAMES=12 \
        ALPHA_SHIFT=$a ALPHA_SHIFT_SLOW=$s GRACE_FRAMES=$g TOLERANCE=0 || exit 1
    done
  done
done
```

Expected: all 13 combinations PASS at TOLERANCE=0.

- [ ] **Step 5.8: Visual check — frame-0 ghost eliminated**

```bash
make clean
make run-pipeline SOURCE="synthetic:dark_moving_box" CTRL_FLOW=motion FRAMES=12 \
  GRACE_FRAMES=8 GAUSS_EN=1
```

Open the resulting render under `dv/data/renders/`. **Expected visual outcome:**

- Frame 0: no bbox (priming).
- Frame 1-2: no bbox (bbox priming suppression).
- Frame 3 onwards: single bbox tracking the moving box.
- **No second bbox at the frame-0 position** — this is the regression the grace window fixes. Compare against a render with `GRACE_FRAMES=0` to see the ghost bbox that used to appear.

If the frame-0 ghost is still visible at `GRACE_FRAMES=8`, escalate: try `GRACE_FRAMES=16`. If still present, the grace window is insufficient → implement the Sobel follow-up from arch doc §10.1.

- [ ] **Step 5.9: Archive the plan and this task's spec text**

Once visual check is confirmed, move this plan and the design discussion into the archive per project convention:

```bash
mkdir -p docs/plans/old
git mv docs/plans/2026-04-22-motion-grace-window-plan.md docs/plans/old/2026-04-22-motion-grace-window-plan.md
git commit -m "chore(docs): archive completed motion grace window plan"
```

(If a separate design doc was created, archive it too.)

---

## Self-Review Notes

**Spec coverage:**
- ✅ Grace window parameter introduced and propagated through the full chain
- ✅ bg_next mux updated for in_grace branch
- ✅ Counter register with saturating behavior
- ✅ Default K=8, user-tunable
- ✅ GRACE_FRAMES=0 ≡ pre-grace behavior (regression safety)
- ✅ Python model mirrors RTL rule (bit-exact verification preserved)
- ✅ Sobel follow-up documented in arch spec §10.1 (future escalation path)
- ✅ Motion-stuck counter documented in arch spec §10.2 (further escalation)

**YAGNI check:**
- Single global counter (not per-pixel) — matches option 1's minimal-cost premise.
- Mask NOT gated by grace — ghost decays naturally at α=1/8; gating would add a blind window we don't need.
- No ghost-detection classifier in this plan — documented as follow-up only.

**TDD:**
- Task 2 writes 3 failing tests before any production code changes.
- Task 3 relies on existing TB's mask-golden check for bit-exact parity.
- Task 5 is full integration matrix at TOLERANCE=0.

**Type consistency:**
- `GRACE_FRAMES` (int, compile-time, RTL+Makefile+Python) — consistent spelling everywhere.
- `grace_cnt` (RTL register), `tb_grace_cnt` (TB int), `grace_cnt` (Python int) — distinct namespaces but parallel meaning.
- `in_grace` (RTL wire + Python bool) — consistent.
