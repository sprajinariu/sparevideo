# Motion Mask Quality — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the motion detector's unconditional EMA with (1) a one-frame hard-init priming pass and (2) a two-rate selective-EMA background update, so the mask is clean from frame 1 and trails don't survive moving-object departure.

**Architecture:** Contained changes in two RTL files (`motion_core.sv`, `axis_motion_detect.sv`) + one Python reference model (`py/models/motion.py`). One new compile-time parameter `ALPHA_SHIFT_SLOW` threaded through the Makefile chain. No new modules, no RAM width change, no top-level plumbing beyond parameter passing.

**Tech Stack:** SystemVerilog (Verilator 12-compatible, synthesis-style; no SVA, no classes), Python 3 (numpy, pytest), Make, FuseSoC.

**Spec:** `docs/plans/2026-04-21-motion-mask-quality-design.md`

---

## File Structure

### Files created
*(none — all changes to existing files)*

### Files modified

| File | Responsibility | Scope of change |
|------|----------------|-----------------|
| `docs/specs/axis_motion_detect-arch.md` | Arch contract for motion detect | Document `primed` register, 3:1 `bg_next` mux, `ALPHA_SHIFT_SLOW`, frame-0 priming. Rewrite the "no first-frame priming" passage. |
| `CLAUDE.md` | Project conventions / lessons | Replace "No first-frame priming" bullet; add `ALPHA_SHIFT_SLOW` to parameter-propagation example and verification sweep matrix. |
| `README.md` | User-facing docs | Update motion section; add `ALPHA_SHIFT_SLOW` to build-command examples and parameter table. |
| `Makefile` (top) | Help text + parameter wiring | Document `ALPHA_SHIFT_SLOW` in help; add to `SIM_VARS`, config.mk emission, verify/render CLI plumbing. |
| `hw/top/sparevideo_pkg.sv` | Project-wide parameters | Add `ALPHA_SHIFT_SLOW = 6` localparam. |
| `hw/ip/motion/rtl/motion_core.sv` | Combinational compare + EMA | Add `primed_i` input and `ALPHA_SHIFT_SLOW` parameter. Compute `ema_delta` once, emit `ema_update_o` + `ema_update_slow_o`. Gate `mask_bit_o` with `primed_i`. |
| `hw/ip/motion/rtl/axis_motion_detect.sv` | Wrapper: RGB→Y, Gauss, addressing, RAM port | Add `primed` 1-bit register; add `ALPHA_SHIFT_SLOW` parameter; implement 3:1 `bg_next` mux feeding `mem_wr_data_o`. |
| `hw/top/sparevideo_top.sv` | Top DUT | Add `ALPHA_SHIFT_SLOW` parameter and pass to `axis_motion_detect` instance. |
| `dv/sv/tb_sparevideo.sv` | Integration TB | Add `ALPHA_SHIFT_SLOW` parameter, pass to DUT. |
| `dv/sim/Makefile` | Sim driver | Add `ALPHA_SHIFT_SLOW ?= 6`, `-GALPHA_SHIFT_SLOW=`, include in config stamp. |
| `hw/ip/motion/tb/tb_axis_motion_detect.sv` | Unit TB | Rewrite golden model for new priming + selective EMA rule; update per-frame checks. |
| `py/models/motion.py` | Python ref model | Implement 3-way update rule (priming / motion-slow / non-motion-fast); accept `alpha_shift_slow` kwarg. |
| `py/harness.py` | CLI | Add `--alpha-shift-slow` argument on verify/render; pass to `run_model`. |
| `py/tests/test_models.py` | Python unit tests | Add frame-0 priming test, selective-EMA test. Update any static-scene test that relied on slow convergence. |

### Files moved (at end of plan)
- `docs/plans/2026-04-21-motion-mask-quality-design.md` → `docs/plans/old/2026-04-21-motion-mask-quality-design.md` (post-implementation archive per CLAUDE.md convention).
- `docs/plans/2026-04-21-motion-mask-quality-plan.md` → `docs/plans/old/2026-04-21-motion-mask-quality-plan.md` (same).

---

## Task 1: Documentation Updates (Step 1)

Docs first: pin the intent in prose so the code matches the design, not the other way around.

**Files:**
- Modify: `docs/specs/axis_motion_detect-arch.md`
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `Makefile` (help text only)

- [ ] **Step 1.1: Update `docs/specs/axis_motion_detect-arch.md` §3.1 Parameters table**

Find the current parameters table and add a row for `ALPHA_SHIFT_SLOW` between `ALPHA_SHIFT` and `GAUSS_EN`:

```markdown
| `ALPHA_SHIFT_SLOW` | 6 | EMA smoothing factor applied when the current pixel is flagged as motion (`raw_motion=1`). alpha = 1 / (1 << ALPHA_SHIFT_SLOW). Default 6 → alpha = 1/64. Larger than `ALPHA_SHIFT` so motion pixels barely drift the background estimate, preventing foreground bleed (trails). When a flagged pixel stays flagged (stopped object), this rate governs absorption into the background; with default 6 at 30 fps, a stopped object absorbs in ~2 s. |
```

- [ ] **Step 1.2: Update §4.4 "Temporal background model — EMA"**

At the end of §4.4, replace the "Why not raw-frame priming?" paragraph (the one that begins "Writing raw `y_cur` to RAM on frame 0 was evaluated but rejected") with this new subsection:

```markdown
#### Frame-0 hard initialization

The background RAM is zero-initialized on reset, which would produce a multi-frame convergence ramp (and near-full-frame mask=1 on frame 0). Instead, a single-bit `primed` register gates the module into a one-frame priming pass:

- While `primed == 0` (first frame only): every accepted pixel writes its own `Y_smooth` value directly to `bg[addr]`, and `mask_bit` is forced to 0. No EMA is applied.
- `primed` latches to 1 on the last beat of frame 0 (`end_of_row && out_row == V_ACTIVE-1 && beat_done`). Frame 1's very first pixel sees `primed == 1`.
- From frame 1 onward: normal threshold + selective-EMA compute path applies.

An earlier design considered raw first-frame priming (write `y_cur` straight to bg, **but also compute mask**). That was rejected because any foreground object present in frame 0 would be committed to the background and then, when it moved, leave a departure ghost for `~1/alpha` frames. The current design avoids this by **suppressing the mask output during priming** and, more importantly, combining priming with selective EMA (next subsection) so subsequent frames do not keep rewriting the background under moving objects.

#### Selective EMA — two rates

The EMA rate differs based on the current pixel's mask bit:

- **Non-motion pixel** (`raw_motion = 0`) — `alpha = 1 / (1 << ALPHA_SHIFT)`, default 1/8. Tracks slow scene changes (illumination drift, AGC).
- **Motion pixel** (`raw_motion = 1`) — `alpha = 1 / (1 << ALPHA_SHIFT_SLOW)`, default 1/64. Nearly freezes the background under a moving object, which is what prevents trail formation. Also governs absorption of objects that stop moving; at 30 fps and default 6, a stopped object is absorbed in ~2 s.

Both rates share one subtractor; the two shifts are constant fan-outs of the same signed `ema_delta`, so synthesis collapses the cost.
```

- [ ] **Step 1.3: Update §5.4 "Temporal background model implementation — EMA"**

Replace the code listing in §5.4 with this expanded version:

```systemverilog
// motion_core — EMA path (shared subtract, two shifts, two adders)
logic signed [8:0] ema_delta       = {1'b0, y_cur_i} - {1'b0, y_bg_i};   // one signed 9-bit subtract
logic signed [8:0] ema_step_fast   = ema_delta >>> ALPHA_SHIFT;          // wire shift, α=1/(1<<ALPHA_SHIFT)
logic signed [8:0] ema_step_slow   = ema_delta >>> ALPHA_SHIFT_SLOW;     // wire shift, α=1/(1<<ALPHA_SHIFT_SLOW)
logic        [7:0] ema_update_o      = y_bg_i + ema_step_fast[7:0];      // non-motion branch
logic        [7:0] ema_update_slow_o = y_bg_i + ema_step_slow[7:0];      // motion branch
```

Then add a new paragraph below it:

```markdown
`axis_motion_detect` selects among three write-back sources per pixel:

```
bg_next = !primed     ? y_smooth          // frame-0 hard init
        :  raw_motion ? ema_update_slow_o // motion pixel → slow rate
        :               ema_update_o      // non-motion pixel → fast rate
```

The selection is driven by one combinational mux feeding `mem_wr_data_o`. `raw_motion` is the unchanged threshold comparison `(|Y_smooth - bg| > THRESH)`. The mask output stream uses `mask_bit_o`, which is gated by `primed_i` inside `motion_core` so the wrapper does not re-implement the gate on the AXIS output.
```

- [ ] **Step 1.4: Update §6 "State / Control Logic" table in the same file**

Add a row for the new register:

```markdown
| `primed` | `axis_motion_detect` | 1-bit sticky flag — 0 during frame 0, set to 1 on the last beat of frame 0 and held. Gates the 3:1 `bg_next` mux and the `mask_bit_o` output. |
```

- [ ] **Step 1.5: Update §7 "Timing" in the same file**

Replace the two post-table paragraphs (the ones starting "Frame 0: RAM is zero-initialized" and "EMA convergence: After a step change") with:

```markdown
Frame 0 (priming): `primed == 0` for all `H_ACTIVE × V_ACTIVE` beats. Each pixel writes its own `Y_smooth` to `bg[addr]` and emits `mask_bit = 0`. By the end of frame 0 the RAM holds a valid per-pixel background model. `primed` latches to 1 on the last beat; frame 1's first pixel uses normal compare + selective-EMA.

EMA convergence (frame ≥ 1): a pixel whose true scenery value shifts by Δ converges toward the new value at rate α per frame. For non-motion pixels α = 1/8 (full convergence in ~8 frames); for motion pixels α = 1/64 (convergence / absorption in ~64 frames). Once a pixel flagged as motion returns to matching its stored bg (object departure), the mask clears on the very next frame — there is no cleanup phase because the bg was not contaminated in the first place.
```

- [ ] **Step 1.6: Update §9 "Known Limitations" in the same file**

Replace the "Fixed ALPHA_SHIFT" bullet with:

```markdown
- **Fixed ALPHA_SHIFT / ALPHA_SHIFT_SLOW**: both are compile-time parameters. Different scenes may benefit from different adaptation rates; runtime control would require promotion to input ports driven by a future `sparevideo_csr` AXI-Lite register.
```

And add a new bullet at the end of the section:

```markdown
- **Frame-0 priming assumes a representative bg**: if the very first frame contains a foreground object, that object's luma is committed to the background in that region. Subsequent frames will flag the object as motion (since it still occupies that pixel) and selective EMA (slow rate) will absorb it over ~64 frames. Acceptable for typical scenes where bring-up starts with an empty frame; deliberate deployment with a pre-populated scene may want a reset sequence.
```

- [ ] **Step 1.7: Update `CLAUDE.md` "Motion pipeline — lessons learned" section**

Find the "No first-frame priming." bullet (search: `**No first-frame priming.**`). Replace the entire bullet (from `**No first-frame priming.**` through the end of its paragraph, up to the next blank line) with:

```markdown
**Frame-0 hard-init + selective EMA.** The background RAM is primed in frame 0 by writing `y_smooth` directly (mask forced to 0 for that frame), then from frame 1 onward the EMA rate is selected per pixel: `ALPHA_SHIFT` (fast, α=1/8) when the pixel is *not* flagged as motion, `ALPHA_SHIFT_SLOW` (slow, α=1/64) when it *is*. The slow rate on motion pixels prevents foreground contamination (trails) while still absorbing stopped objects over ~1/α_slow frames. This combination supersedes the earlier "no first-frame priming" rule, whose failure mode (departure ghosts from frame-0 foreground) is prevented by the selective rate, not by avoiding priming.
```

- [ ] **Step 1.8: Update `CLAUDE.md` parameter-propagation example**

In the same "Motion pipeline — lessons learned" section, find the "Compile-time RTL parameters must propagate through the full Makefile chain" bullet. Replace the "Any new `-G` parameter (e.g., KERNEL_SIZE, MAX_LABELS)" sentence with:

```markdown
Any new `-G` parameter (e.g., `ALPHA_SHIFT_SLOW`, `KERNEL_SIZE`, `MAX_LABELS`) needs: top Makefile `?=` default → SIM_VARS → dv/sim/Makefile `?=` default → VLT_FLAGS `-G` → tb_sparevideo.sv parameter → DUT.
```

- [ ] **Step 1.9: Update `CLAUDE.md` verification sweep matrix**

Find the "Verify all control flows × parameter combinations." bullet. Replace its body with:

```markdown
**Verify all control flows × parameter combinations.** After any motion pipeline change, test the matrix: all 4 control flows (passthrough, motion, mask, ccl_bbox) × multiple ALPHA_SHIFT values (0,1,2,3) × multiple ALPHA_SHIFT_SLOW values (5,6,7) × multiple sources at TOLERANCE=0.
```

- [ ] **Step 1.10: Update `README.md` parameter table**

Find the row for `ALPHA_SHIFT` (line ~219). Immediately after that row, add:

```markdown
| `ALPHA_SHIFT_SLOW` | `6` | EMA background adaptation rate for motion pixels: `alpha = 1/(1 << N)`. Default 6 (α=1/64). Larger than `ALPHA_SHIFT` so motion pixels barely drift bg → no trails. Also governs absorption time of stopped objects. Compile-time RTL parameter propagated via `-G`. |
```

- [ ] **Step 1.11: Update `README.md` motion-tuning example**

Find the line starting `make run-pipeline SOURCE="synthetic:noisy_moving_box"` (line ~147). Replace that one-line block with:

```bash
# EMA background model tuning (ALPHA_SHIFT/ALPHA_SHIFT_SLOW are compile-time Verilator parameters)
make run-pipeline SOURCE="synthetic:noisy_moving_box" CTRL_FLOW=mask ALPHA_SHIFT=2 ALPHA_SHIFT_SLOW=6 FRAMES=8
```

- [ ] **Step 1.12: Update `README.md` supported-variables table**

Find the `ALPHA_SHIFT` row in the "Pipeline variables — which steps honour them" table (around line 186):

```markdown
| `ALPHA_SHIFT` | ✓ | `compile`, `sim`, `sim-waves`, `sw-dry-run` |
```

Add immediately after it:

```markdown
| `ALPHA_SHIFT_SLOW` | ✓ | `compile`, `sim`, `sim-waves`, `sw-dry-run` |
```

- [ ] **Step 1.13: Update top `Makefile` help text**

Find the line documenting `ALPHA_SHIFT` (line 81). Replace the two lines around it with:

```make
	@echo "    ALPHA_SHIFT=3                    EMA adaptation (non-motion pixel): alpha=1/(1<<N) (default 3)"
	@echo "    ALPHA_SHIFT_SLOW=6               EMA adaptation (motion pixel): alpha=1/(1<<N) (default 6)"
```

- [ ] **Step 1.14: Commit docs-first changes**

```bash
git add docs/specs/axis_motion_detect-arch.md CLAUDE.md README.md Makefile
git commit -m "docs(motion): describe adaptive-background design before implementation

Document frame-0 hard-init priming and two-rate selective EMA in the
axis_motion_detect arch doc, CLAUDE.md lessons-learned, and README.
Add ALPHA_SHIFT_SLOW to parameter tables and help text. No code changes
yet — the design lands first so the implementation matches the spec.
"
```

---

## Task 2: Python Reference Model

Implement the new bg-update rule in the Python model, driven by TDD. The model is the source of truth for `make verify`.

**Files:**
- Modify: `py/tests/test_models.py`
- Modify: `py/models/motion.py`
- Modify: `py/harness.py`
- Modify: `Makefile` (top — verify/render alpha-shift-slow plumbing)

- [ ] **Step 2.1: Add failing tests for new behavior**

Open `py/tests/test_models.py` and append the following tests at the end of the file (after the last existing test):

```python
# ---- Frame-0 priming + selective EMA tests ----

def _get_internal_bg(frames, alpha_shift=3, alpha_shift_slow=6, gauss_en=True):
    """Run the motion model and return the internal bg state at each frame boundary.

    Returns a list of bg arrays (uint8, shape H×W) — one per *processed* frame.
    bg[0] is the state after frame 0 has been consumed.
    """
    from models.motion import _run_bg_trace
    return _run_bg_trace(frames, alpha_shift=alpha_shift,
                         alpha_shift_slow=alpha_shift_slow, gauss_en=gauss_en)


def test_motion_frame0_priming_writes_bg():
    """After frame 0, bg[px] equals Y(frame_0[px]) for every pixel (no EMA lag)."""
    from models.motion import _rgb_to_y, _gauss3x3
    frames = _static_frames(width=16, height=8, num_frames=1,
                             color=(120, 60, 200))
    bg_trace = _get_internal_bg(frames, alpha_shift=3, alpha_shift_slow=6,
                                 gauss_en=True)
    y0 = _rgb_to_y(frames[0])
    y0_filt = _gauss3x3(y0)
    np.testing.assert_array_equal(bg_trace[0], y0_filt)


def test_motion_frame0_priming_mask_all_zero():
    """The motion model's frame-0 output is visually indistinguishable from input
    (no bbox overlay is drawn because primed=False and bbox state is all-None).
    Also: mask bits emitted during frame 0 would be all zero."""
    frames = _static_frames(width=16, height=8, num_frames=1,
                             color=(120, 60, 200))
    out = run_model("motion", frames, alpha_shift=3, alpha_shift_slow=6,
                    gauss_en=True)
    # frame 0 output is input (bbox state all-None on first frame regardless)
    np.testing.assert_array_equal(out[0], frames[0])


def test_motion_selective_ema_rates():
    """Frame 2: after frame 1 establishes a stable bg, construct frame 2 so
    that half the pixels are flagged motion and half are not. bg should drift
    at the slow rate on motion pixels and fast rate on non-motion pixels."""
    from models.motion import _rgb_to_y, _gauss3x3
    w, h = 16, 8
    num_frames = 3
    # Build: frame 0 and frame 1 identical (prime + stabilize). frame 2 has
    # a delta in the left half that exceeds thresh, and a sub-threshold delta
    # in the right half.
    frame0 = np.full((h, w, 3), 100, dtype=np.uint8)
    frame1 = frame0.copy()
    frame2 = frame0.copy()
    frame2[:, :w // 2] = 180                       # Y delta ~80 > thresh
    frame2[:, w // 2:] = 105                        # Y delta 5 < thresh
    bg_trace = _get_internal_bg([frame0, frame1, frame2],
                                 alpha_shift=3, alpha_shift_slow=6,
                                 gauss_en=False)
    # After frame 1, bg should equal Y(100) everywhere (primed on f0 → bg=100;
    # frame 1 non-motion → fast EMA step toward 100 → still 100).
    y_after_f1 = bg_trace[1]
    assert np.all(y_after_f1 == 100)

    # After frame 2:
    #   Left half: motion pixel. delta=180-100=80. step = 80>>6 = 1. bg=101.
    #   Right half: non-motion. delta=105-100=5.   step = 5>>3 = 0.  bg=100.
    y_after_f2 = bg_trace[2]
    assert np.all(y_after_f2[:, :w // 2] == 101), (
        f"motion half should drift by (80>>6)=1, got {y_after_f2[0, 0]}")
    assert np.all(y_after_f2[:, w // 2:] == 100), (
        f"non-motion half should not drift, got {y_after_f2[0, -1]}")


def test_motion_no_trail_after_object_departure():
    """Object moves across a pixel for 2 frames then leaves. With selective EMA,
    the pixel immediately stops flagging as motion once the object is gone."""
    w, h = 16, 8
    # f0: empty scene (Y=100)
    # f1: object at left half (Y=200) — motion, but slow EMA barely drifts bg
    # f2: object gone (Y=100 everywhere) — bg is still ~100, delta=0, mask=0
    frame_empty  = np.full((h, w, 3), 100, dtype=np.uint8)
    frame_object = np.full((h, w, 3), 100, dtype=np.uint8)
    frame_object[:, :w // 2] = 200
    frames = [frame_empty, frame_object, frame_empty]
    bg_trace = _get_internal_bg(frames, alpha_shift=3, alpha_shift_slow=6,
                                 gauss_en=False)
    # After f2, bg in the former-motion region:
    #   Before f2: bg=100 (f0 primed=100; f1 motion → slow-step: 100+(100>>6)=101)
    #   f2: delta = 100-101 = -1, |diff|=1, thresh=16 → not motion → fast rate
    #       step = -1>>3 = -1 (arithmetic) → bg = 100
    # Mask at f2 left half should be 0 (no trail).
    from models.motion import _rgb_to_y, _gauss3x3, _compute_mask
    y2 = _rgb_to_y(frames[2])
    # bg before f2 is bg_trace[1]; but we verify the *consequence*: mask at f2
    # is zero everywhere when we recompute against bg_trace[1].
    mask_f2 = _compute_mask(y2, bg_trace[1], thresh=16)
    assert not mask_f2.any(), (
        f"No trail expected; got {int(mask_f2.sum())} motion pixels in f2")
```

- [ ] **Step 2.2: Run tests — verify they fail**

```bash
source .venv/bin/activate && python -m pytest py/tests/test_models.py -v -k "frame0_priming or selective_ema or no_trail"
```

Expected: 4 tests collected, all FAIL (ImportError on `_run_bg_trace`, or AttributeError on `alpha_shift_slow` kwarg, etc.).

- [ ] **Step 2.3: Update `py/models/motion.py` — add `_run_bg_trace` helper and new update rule**

Open `py/models/motion.py`. Replace the entire `run(frames, ...)` function and add the `_run_bg_trace` helper above it. The new code is:

```python
def _selective_ema_update(y_cur, bg_prev, mask, alpha_shift, alpha_shift_slow):
    """Two-rate EMA update (bit-exact with RTL).

    Motion pixels update at the slow rate, non-motion at the fast rate.
    Both rates share one subtraction; two arithmetic right-shifts; uint8 wrap.
    """
    delta = y_cur.astype(np.int16) - bg_prev.astype(np.int16)
    step_fast = delta >> alpha_shift        # numpy >> is arithmetic for signed
    step_slow = delta >> alpha_shift_slow
    step = np.where(mask, step_slow, step_fast)
    new_bg = bg_prev.astype(np.int16) + step
    return np.clip(new_bg, 0, 255).astype(np.uint8)


def _run_bg_trace(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6,
                  gauss_en=True):
    """Run the motion model's bg trajectory for inspection. Returns a list of
    bg arrays — one per frame, representing the RAM state after that frame is
    processed. Does not produce visual output.
    """
    if not frames:
        return []
    h, w = frames[0].shape[:2]
    y_bg = np.zeros((h, w), dtype=np.uint8)
    primed = False
    trace = []
    for i, frame in enumerate(frames):
        y_cur = _rgb_to_y(frame)
        y_cur_filt = _gauss3x3(y_cur) if gauss_en else y_cur
        if not primed:
            y_bg = y_cur_filt.copy()
            primed = True
        else:
            mask = _compute_mask(y_cur_filt, y_bg, thresh)
            y_bg = _selective_ema_update(y_cur_filt, y_bg, mask,
                                          alpha_shift, alpha_shift_slow)
        trace.append(y_bg.copy())
    return trace


def run(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6, gauss_en=True,
        **kwargs):
    """Motion pipeline reference model (CCL-based, multi-bbox).

    Frame 0: priming — bg[px] = Y_smooth(frame_0[px]), mask forced to 0.
    Frame N>0: selective EMA — motion pixels drift at slow rate, non-motion at
    fast rate.
    """
    if not frames:
        return []

    h, w = frames[0].shape[:2]
    y_bg = np.zeros((h, w), dtype=np.uint8)
    primed = False
    bboxes_state = [None] * N_OUT

    outputs = []
    for i, frame in enumerate(frames):
        y_cur = _rgb_to_y(frame)
        y_cur_filt = _gauss3x3(y_cur) if gauss_en else y_cur

        if not primed:
            # Frame 0 — hard-init bg, mask forced to zero
            mask = np.zeros((h, w), dtype=bool)
            out = _draw_bboxes(frame, bboxes_state)  # bboxes_state all-None
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
            y_bg = _selective_ema_update(y_cur_filt, y_bg, mask,
                                          alpha_shift, alpha_shift_slow)

        # Bbox priming suppression (unchanged)
        primed_for_bbox = (i >= PRIME_FRAMES)
        bboxes_state = new_bboxes if primed_for_bbox else [None] * N_OUT

        outputs.append(out)

    return outputs
```

Note: the existing `_ema_update` function can remain for backward compat if other code imports it; the new `_selective_ema_update` supersedes it for the run path.

- [ ] **Step 2.4: Run tests — verify they pass**

```bash
source .venv/bin/activate && python -m pytest py/tests/test_models.py -v -k "frame0_priming or selective_ema or no_trail"
```

Expected: 4 tests PASS.

- [ ] **Step 2.5: Run full test suite — verify no regressions**

```bash
source .venv/bin/activate && python -m pytest py/tests/test_models.py -v
```

Expected: all tests PASS. If any prior test fails because it depended on the old EMA-from-zero convergence, update its expectation to reflect the new priming behavior. Investigate each failure before modifying — the test may be catching a real regression.

Likely-affected prior tests to eyeball: `test_motion_static_scene` (previously assumed 16-frame warm-up with bbox-suppressed priming; under new rule, bg is stable from frame 1, so static scene is a no-op from frame 0 onward). Adjust the convergence-frame count in that test if needed, but only after confirming the new behavior is correct.

- [ ] **Step 2.6: Update `py/harness.py` — add `--alpha-shift-slow` CLI**

Open `py/harness.py`. In `cmd_verify`, after line `alpha_shift = getattr(args, "alpha_shift", 3)`, add:

```python
    alpha_shift_slow = getattr(args, "alpha_shift_slow", 6)
```

Change the `run_model(...)` call in `cmd_verify` from:

```python
    expected_frames = run_model(ctrl_flow, input_frames, alpha_shift=alpha_shift,
                                gauss_en=gauss_en)
```

to:

```python
    expected_frames = run_model(ctrl_flow, input_frames, alpha_shift=alpha_shift,
                                alpha_shift_slow=alpha_shift_slow,
                                gauss_en=gauss_en)
```

Do the identical change in `cmd_render` — add `alpha_shift_slow` lookup and pass it to `run_model(...)`.

In the `verify` subparser section (around line 190), after the `--alpha-shift` argument, add:

```python
    p_ver.add_argument("--alpha-shift-slow", type=int, default=6, dest="alpha_shift_slow",
                       help="EMA alpha on motion pixels = 1/(1 << N). Default 6 (α=1/64).")
```

Do the identical addition in the `render` subparser section (around line 207).

- [ ] **Step 2.7: Update top `Makefile` — thread ALPHA_SHIFT_SLOW through prepare/verify/render**

Open `Makefile` at the repository root.

After line 18 (`ALPHA_SHIFT ?= 3`), add:

```make
# EMA background adaptation rate on motion pixels: alpha = 1 / (1 << ALPHA_SHIFT_SLOW).
ALPHA_SHIFT_SLOW ?= 6
```

In the `SIM_VARS` definition (line 35), add `ALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW)`:

```make
SIM_VARS = SIMULATOR=$(SIMULATOR) \
           WIDTH=$(WIDTH) HEIGHT=$(HEIGHT) FRAMES=$(FRAMES) \
           MODE=$(MODE) CTRL_FLOW=$(CTRL_FLOW) \
           ALPHA_SHIFT=$(ALPHA_SHIFT) ALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW) GAUSS_EN=$(GAUSS_EN) \
           INFILE=$(CURDIR)/$(PIPE_INFILE) \
           OUTFILE=$(CURDIR)/$(PIPE_OUTFILE)
```

In the `prepare` target's `printf` (line 109), add `ALPHA_SHIFT_SLOW = %s\n` and `$(ALPHA_SHIFT_SLOW)`:

```make
	@printf 'SOURCE = %s\nWIDTH = %s\nHEIGHT = %s\nFRAMES = %s\nMODE = %s\nCTRL_FLOW = %s\nALPHA_SHIFT = %s\nALPHA_SHIFT_SLOW = %s\nGAUSS_EN = %s\n' \
		'$(SOURCE)' '$(WIDTH)' '$(HEIGHT)' '$(FRAMES)' '$(MODE)' '$(CTRL_FLOW)' '$(ALPHA_SHIFT)' '$(ALPHA_SHIFT_SLOW)' '$(GAUSS_EN)' > $(DATA_DIR)/config.mk
```

In the `verify` target (line 134-137), add `--alpha-shift-slow`:

```make
	cd py && $(HARNESS) verify \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) --ctrl-flow $(CTRL_FLOW) --tolerance $(TOLERANCE) \
		--alpha-shift $(ALPHA_SHIFT) --alpha-shift-slow $(ALPHA_SHIFT_SLOW) --gauss-en $(GAUSS_EN)
```

In the `RENDER_OUT` definition (line 140), add `__alpha-shift-slow=$(ALPHA_SHIFT_SLOW)`:

```make
RENDER_OUT = $(CURDIR)/$(DATA_DIR)/renders/$(RENDER_SOURCE_SAFE)__width=$(WIDTH)__height=$(HEIGHT)__frames=$(FRAMES)__ctrl-flow=$(CTRL_FLOW)__alpha-shift=$(ALPHA_SHIFT)__alpha-shift-slow=$(ALPHA_SHIFT_SLOW)__gauss-en=$(GAUSS_EN).png
```

In the `render` target, add `--alpha-shift-slow`:

```make
	cd py && $(HARNESS) render \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) --ctrl-flow $(CTRL_FLOW) --alpha-shift $(ALPHA_SHIFT) \
		--alpha-shift-slow $(ALPHA_SHIFT_SLOW) --gauss-en $(GAUSS_EN) \
		--render-output $(RENDER_OUT)
```

- [ ] **Step 2.8: Run Python unit tests again — verify no regressions from harness changes**

```bash
source .venv/bin/activate && python -m pytest py/tests/test_models.py -v
```

Expected: all tests PASS.

- [ ] **Step 2.9: Commit Python model changes**

```bash
git add py/models/motion.py py/tests/test_models.py py/harness.py Makefile
git commit -m "feat(motion-py): frame-0 priming + two-rate selective EMA

py/models/motion.py: implement new bg-update rule. Frame 0 is a
mask-suppressed priming pass that writes Y_smooth directly to bg.
From frame 1 onward, the EMA rate is selected per pixel — fast
(ALPHA_SHIFT) on non-motion, slow (ALPHA_SHIFT_SLOW) on motion.

Add _run_bg_trace helper for introspection in tests. Add 4 new tests
covering priming and selective-EMA rates.

Plumb --alpha-shift-slow through harness.py and the top Makefile
(SIM_VARS, config.mk, verify, render).
"
```

---

## Task 3: RTL — `motion_core.sv` and `axis_motion_detect.sv`

TDD on the existing unit TB: update the golden model first, confirm the TB now fails against unchanged RTL, then change the RTL to pass.

**Files:**
- Modify: `hw/ip/motion/tb/tb_axis_motion_detect.sv`
- Modify: `hw/ip/motion/rtl/motion_core.sv`
- Modify: `hw/ip/motion/rtl/axis_motion_detect.sv`

- [ ] **Step 3.1: Update `tb_axis_motion_detect.sv` golden model — add `primed` tracking and selective EMA**

Open `hw/ip/motion/tb/tb_axis_motion_detect.sv`.

After line 32 (`localparam int ALPHA_SHIFT = 3;`), add:

```systemverilog
    localparam int ALPHA_SHIFT_SLOW = 6;
```

In the DUT instantiation (around line 117), add the new parameter:

```systemverilog
    axis_motion_detect #(
        .H_ACTIVE         (H),
        .V_ACTIVE         (V),
        .THRESH           (THRESH),
        .ALPHA_SHIFT      (ALPHA_SHIFT),
        .ALPHA_SHIFT_SLOW (ALPHA_SHIFT_SLOW),
        .GAUSS_EN         (GAUSS_EN),
        .RGN_BASE         (0),
        .RGN_SIZE         (NUM_PIX)
    ) u_dut (
```

Add a TB-side `primed` flag and frame-index tracker. After line 164 (`logic [7:0]  y_prev [NUM_PIX];`), add:

```systemverilog
    // TB-side tracking of the DUT's internal `primed` flag.
    // primed starts 0, flips to 1 after the last beat of frame 0 is accepted.
    // The TB mirrors the RTL by updating its golden model identically.
    logic tb_primed = 1'b0;
```

Replace the body of `update_y_prev` (lines 287-295) with the new selective-EMA rule that also handles priming:

```systemverilog
    task automatic update_y_prev(input logic [23:0] pixels [NUM_PIX]);
        logic signed [8:0] delta, step_fast, step_slow, step;
        logic [7:0] yc;
        logic raw_motion;
        compute_y_eff(pixels);
        if (!tb_primed) begin
            // Frame 0: hard-init bg from current frame
            for (int i = 0; i < NUM_PIX; i++)
                y_prev[i] = y_eff[i];
            tb_primed = 1'b1;
        end else begin
            for (int i = 0; i < NUM_PIX; i++) begin
                yc        = y_eff[i];
                delta     = {1'b0, yc} - {1'b0, y_prev[i]};
                step_fast = delta >>> ALPHA_SHIFT;
                step_slow = delta >>> ALPHA_SHIFT_SLOW;
                raw_motion = ((yc > y_prev[i]) ? (yc - y_prev[i]) : (y_prev[i] - yc)) > THRESH[7:0];
                step      = raw_motion ? step_slow : step_fast;
                y_prev[i] = y_prev[i] + step[7:0];
            end
        end
    endtask
```

Replace the body of `check_mask_golden` (lines 247-263). The mask is 0 during priming; from frame 1 on, it's the threshold comparison:

```systemverilog
    task automatic check_mask_golden(input logic [23:0] pixels [NUM_PIX], input string label);
        integer i;
        logic [7:0] yc, diff;
        logic exp_msk;
        compute_y_eff(pixels);
        for (i = 0; i < NUM_PIX; i = i + 1) begin
            yc   = y_eff[i];
            diff = (yc > y_prev[i]) ? (yc - y_prev[i]) : (y_prev[i] - yc);
            // During priming (frame 0, tb_primed still 0 when this is called),
            // mask is forced to 0. After priming, it's the threshold compare.
            exp_msk = tb_primed ? (diff > THRESH[7:0]) : 1'b0;
            if (cap_msk[i] !== exp_msk) begin
                $display("FAIL %s msk px%0d (%0d,%0d): got=%0b exp=%0b yeff=%0d yprev=%0d d=%0d primed=%0b",
                         label, i, i/H, i%H, cap_msk[i], exp_msk, yc, y_prev[i], diff, tb_primed);
                num_errors = num_errors + 1;
            end
        end
        $display("%s: mask golden check done (primed=%0b)", label, tb_primed);
    endtask
```

Note: `check_mask_golden` must run **before** `update_y_prev` in frame 0, so it sees `tb_primed=0` and expects all-zero mask. After `update_y_prev` runs at the end of frame 0, `tb_primed` flips to 1.

- [ ] **Step 3.2: Update the frame-0 check expectation**

Because frame 0 now produces an all-zero mask (regardless of `frame_pixels` content), the existing frame-0 test at lines 389-401 becomes a pure sanity check on priming. Replace the comment at line 390 and the block at lines 392-401 with:

```systemverilog
        // ================================================================
        // Frame 0: PRIMING — mask forced to 0 for every pixel; bg initialized
        // to Y_eff(frame_pixels).
        // ================================================================
        $display("=== Frame 0 (priming: mask=0, bg init) ===");
        reset_capture();
        fork
            drive_frame(frame_pixels);
            wait_frame_captured();
        join
        repeat (5) @(posedge clk);
        check_mask_golden(frame_pixels, "frame0");  // expects all-zero (tb_primed still 0)
        update_y_prev(frame_pixels);                 // hard-init path, flips tb_primed
        // Verify RAM holds Y_eff(frame_pixels) after priming
        repeat (5) @(posedge clk);
        check_ram_ema("frame0");
```

Frame 1 no longer sees a convergence delta — bg now matches Y_eff(frame_pixels) exactly, so all-zero mask is expected. Replace the block at lines 404-417:

```systemverilog
        // ================================================================
        // Frame 1: same pixels; bg already matches (from priming) → all-zero mask
        // ================================================================
        $display("=== Frame 1 (same pixels after priming, expect all-zero mask) ===");
        reset_capture();
        fork
            drive_frame(frame_pixels);
            wait_frame_captured();
        join
        repeat (5) @(posedge clk);
        check_mask_golden(frame_pixels, "frame1");
        update_y_prev(frame_pixels);
        repeat (5) @(posedge clk);
        check_ram_ema("frame1");
```

Frames 2–5 exercise the selective-EMA rule on mixed/block pixels; the existing frame 2–5 blocks remain structurally the same, but the internal golden-model updates already reflect selective EMA via the revised `update_y_prev`. No further per-frame edits needed.

- [ ] **Step 3.3: Compile the (still-unchanged) RTL against the new TB — verify failure**

```bash
make test-ip-motion-detect 2>&1 | tail -30
```

Expected: compilation succeeds (TB references `ALPHA_SHIFT_SLOW` parameter that doesn't exist yet on the RTL → compile FAIL, OR TB passes it via `.ALPHA_SHIFT_SLOW(...)` port that is missing). If compile fails on the unknown parameter, that is the expected failure mode; proceed to step 3.4.

If for some reason the Verilator port-association check allows unknown parameters as a warning, the test may fail at runtime on frame 0 mask expectations. Either failure mode is acceptable; the point is the TB exercises the new contract, and the RTL doesn't satisfy it yet.

- [ ] **Step 3.4: Update `motion_core.sv` — add `primed_i`, `ALPHA_SHIFT_SLOW`, two update outputs**

Open `hw/ip/motion/rtl/motion_core.sv`. Replace the module body entirely:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Motion detection core — pure combinational.
//
// Computes a 1-bit motion mask (abs(y_cur - y_bg) > THRESH) and TWO
// EMA-updated background values (fast and slow rates), so the caller can
// mux between them based on the mask bit. The mask output is gated by
// `primed_i` so the wrapper does not re-implement the frame-0 suppression.
// No clock, no state — instantiated by axis_motion_detect.

module motion_core #(
    parameter int THRESH           = 16,
    parameter int ALPHA_SHIFT      = 3,    // alpha = 1/8 — non-motion rate
    parameter int ALPHA_SHIFT_SLOW = 6     // alpha = 1/64 — motion rate
) (
    input  logic [7:0] y_cur_i,            // current-frame luma (post-Gaussian)
    input  logic [7:0] y_bg_i,             // background luma from RAM
    input  logic       primed_i,           // 1 = frame >= 1; 0 = priming frame 0

    output logic       mask_bit_o,         // 1 = motion detected (gated by primed_i)
    output logic [7:0] ema_update_o,       // bg + (delta >>> ALPHA_SHIFT)      — non-motion branch
    output logic [7:0] ema_update_slow_o   // bg + (delta >>> ALPHA_SHIFT_SLOW) — motion branch
);

    // ---- Motion comparison (gated by primed_i) ----
    logic [7:0] diff;
    logic       raw_motion;

    assign diff       = (y_cur_i > y_bg_i) ? (y_cur_i - y_bg_i)
                                            : (y_bg_i - y_cur_i);
    assign raw_motion = (diff > THRESH[7:0]);
    assign mask_bit_o = primed_i && raw_motion;

    // ---- EMA background update — shared subtract, two parallel shifts ----
    logic signed [8:0] ema_delta;
    logic signed [8:0] ema_step_fast;
    logic signed [8:0] ema_step_slow;

    assign ema_delta         = {1'b0, y_cur_i} - {1'b0, y_bg_i};
    assign ema_step_fast     = ema_delta >>> ALPHA_SHIFT;
    assign ema_step_slow     = ema_delta >>> ALPHA_SHIFT_SLOW;
    assign ema_update_o      = y_bg_i + ema_step_fast[7:0];
    assign ema_update_slow_o = y_bg_i + ema_step_slow[7:0];

endmodule
```

- [ ] **Step 3.5: Update `axis_motion_detect.sv` — add `primed` register, 3:1 `bg_next` mux**

Open `hw/ip/motion/rtl/axis_motion_detect.sv`.

Add the new parameter. Change lines 51-58:

```systemverilog
module axis_motion_detect #(
    parameter int H_ACTIVE         = 320,
    parameter int V_ACTIVE         = 240,
    parameter int THRESH           = 16,
    parameter int ALPHA_SHIFT      = 3,    // alpha = 1/(1 << ALPHA_SHIFT), default 1/8 — non-motion rate
    parameter int ALPHA_SHIFT_SLOW = 6,    // alpha = 1/(1 << ALPHA_SHIFT_SLOW), default 1/64 — motion rate
    parameter int GAUSS_EN         = 1,
    parameter int RGN_BASE         = 0,
    parameter int RGN_SIZE         = H_ACTIVE * V_ACTIVE
) (
```

Add the `primed` register immediately before the "Motion core" instantiation. After the existing `end_of_frame` / `out_addr` assignments (just before line 264 `// ---- Motion core`):

```systemverilog
    // ---- Priming flag: latches on end_of_frame of frame 0, held thereafter. ----
    // While primed==0, the write-back path stores y_smooth directly (hard-init)
    // and mask_bit is forced to 0 inside motion_core.
    logic primed;
    logic beat_done_eof;

    assign beat_done_eof = pipe_valid && !pipe_stall && end_of_frame;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i)
            primed <= 1'b0;
        else if (beat_done_eof)
            primed <= 1'b1;
    end
```

Update the `motion_core` instance (lines 268-276) to pass the new signals:

```systemverilog
    // ---- Motion core (combinational: threshold + EMA, two rates) ----
    logic       mask_bit;
    logic [7:0] ema_update;
    logic [7:0] ema_update_slow;
    logic       raw_motion;

    motion_core #(
        .THRESH           (THRESH),
        .ALPHA_SHIFT      (ALPHA_SHIFT),
        .ALPHA_SHIFT_SLOW (ALPHA_SHIFT_SLOW)
    ) u_core (
        .y_cur_i            (y_smooth),
        .y_bg_i             (mem_rd_data_i),
        .primed_i           (primed),
        .mask_bit_o         (mask_bit),
        .ema_update_o       (ema_update),
        .ema_update_slow_o  (ema_update_slow)
    );

    // raw_motion: recompute locally (same logic motion_core uses, but without
    // the primed gate) so the wrapper can select between the two EMA update
    // sources based on the threshold decision alone.
    logic [7:0] raw_diff;
    assign raw_diff   = (y_smooth > mem_rd_data_i) ? (y_smooth - mem_rd_data_i)
                                                   : (mem_rd_data_i - y_smooth);
    assign raw_motion = (raw_diff > THRESH[7:0]);
```

Replace the memory write-back block (lines 280-290) with the 3:1 `bg_next` mux:

```systemverilog
    // ---- Memory write-back: priming (hard-init) / motion (slow EMA) / non-motion (fast EMA) ----
    // Fire on beat_done so each accepted output writes exactly once.
    logic [7:0] bg_next;
    always_comb begin
        if (!primed)
            bg_next = y_smooth;        // frame-0 hard-init
        else if (raw_motion)
            bg_next = ema_update_slow; // motion pixel → slow rate
        else
            bg_next = ema_update;      // non-motion pixel → fast rate
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            mem_wr_en_o   <= 1'b0;
            mem_wr_addr_o <= '0;
            mem_wr_data_o <= '0;
        end else begin
            mem_wr_en_o   <= beat_done;
            mem_wr_addr_o <= ($bits(mem_wr_addr_o))'(RGN_BASE) + out_addr;
            mem_wr_data_o <= bg_next;
        end
    end
```

- [ ] **Step 3.6: Run unit TB — verify pass (both GAUSS_EN variants)**

```bash
make test-ip-motion-detect && make test-ip-motion-detect-gauss
```

Expected: both testbenches report PASS.

If a failure occurs, compare the TB's FAIL message's `yeff` / `yprev` / `d` / `primed` values against your expectation of the new rule. Common causes:
- `primed` latches on the wrong cycle (off-by-one).
- Wrapper's `raw_motion` disagrees with `motion_core`'s internal `raw_motion` due to stale `mem_rd_data_i` — verify the address timing hasn't regressed.
- TB's `update_y_prev` was called in the wrong order relative to `check_mask_golden` in one of the per-frame blocks.

- [ ] **Step 3.7: Run lint — verify clean**

```bash
make lint 2>&1 | tail -40
```

Expected: no new warnings. If new `UNUSEDSIGNAL` appears for `_unused_tlast` or similar, this is unrelated. Any new warning in `motion_core.sv` or `axis_motion_detect.sv` must be resolved (not waived) before proceeding — the new signed shifts reuse the existing pattern, so there should be nothing novel.

- [ ] **Step 3.8: Commit RTL changes**

```bash
git add hw/ip/motion/rtl/motion_core.sv hw/ip/motion/rtl/axis_motion_detect.sv hw/ip/motion/tb/tb_axis_motion_detect.sv
git commit -m "feat(motion-rtl): frame-0 priming + two-rate selective EMA

motion_core: add primed_i input and ALPHA_SHIFT_SLOW parameter.
Compute ema_delta once, shift twice, emit both ema_update_o and
ema_update_slow_o. Gate mask_bit_o with primed_i so the wrapper does
not re-implement frame-0 suppression.

axis_motion_detect: add primed register latched on last beat of
frame 0. Add ALPHA_SHIFT_SLOW parameter passed to motion_core.
Implement the 3:1 bg_next mux: y_smooth during priming, ema_update_slow
on motion pixels, ema_update on non-motion.

Unit TB updated with new golden model (tb_primed, selective-EMA
update_y_prev, primed-gated check_mask_golden).
"
```

---

## Task 4: Parameter Propagation to Integration

With the RTL and Python model in place, thread `ALPHA_SHIFT_SLOW` through the remaining files so `make sim` and `make run-pipeline` pick it up.

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv`
- Modify: `hw/top/sparevideo_top.sv`
- Modify: `dv/sv/tb_sparevideo.sv`
- Modify: `dv/sim/Makefile`

- [ ] **Step 4.1: Add localparam to `sparevideo_pkg.sv`**

The existing package does not currently hold `ALPHA_SHIFT` (it's a module parameter on `sparevideo_top`). Keep that pattern — do NOT add `ALPHA_SHIFT_SLOW` to the package. The package is already consistent.

(This step is an explicit no-op to document the decision. Move to 4.2.)

- [ ] **Step 4.2: Add `ALPHA_SHIFT_SLOW` parameter to `sparevideo_top.sv`**

Open `hw/top/sparevideo_top.sv`. After line 34 (`parameter int ALPHA_SHIFT   = 3,`), add:

```systemverilog
    // EMA background adaptation rate on MOTION pixels: alpha = 1 / (1 << ALPHA_SHIFT_SLOW).
    // Default 6 → alpha = 1/64. Larger than ALPHA_SHIFT so moving objects barely drift bg.
    parameter int ALPHA_SHIFT_SLOW = 6,
```

Find the `axis_motion_detect` instantiation (search for `.ALPHA_SHIFT (ALPHA_SHIFT),`) and add the new parameter immediately after it:

```systemverilog
        .ALPHA_SHIFT      (ALPHA_SHIFT),
        .ALPHA_SHIFT_SLOW (ALPHA_SHIFT_SLOW),
```

- [ ] **Step 4.3: Add `ALPHA_SHIFT_SLOW` parameter to `tb_sparevideo.sv`**

Open `dv/sv/tb_sparevideo.sv`. After line 23 (`parameter int ALPHA_SHIFT = 3,`), add:

```systemverilog
    parameter int ALPHA_SHIFT_SLOW = 6,
```

In the DUT instantiation (around line 109), add:

```systemverilog
        .ALPHA_SHIFT      (ALPHA_SHIFT),
        .ALPHA_SHIFT_SLOW (ALPHA_SHIFT_SLOW),
```

- [ ] **Step 4.4: Add `-GALPHA_SHIFT_SLOW` to `dv/sim/Makefile`**

Open `dv/sim/Makefile`. After line 26 (`ALPHA_SHIFT ?= 3`), add:

```make
ALPHA_SHIFT_SLOW ?= 6
```

In `VLT_FLAGS` (line 76), add `-GALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW)`:

```make
            -GH_ACTIVE=$(WIDTH) -GV_ACTIVE=$(HEIGHT) -GALPHA_SHIFT=$(ALPHA_SHIFT) -GALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW) -GGAUSS_EN=$(GAUSS_EN) \
```

In the `CONFIG_STAMP` rule (lines 87-90), add `$(ALPHA_SHIFT_SLOW)` to the stamp:

```make
$(CONFIG_STAMP): FORCE
	@mkdir -p $(VOBJ_DIR)
	@echo "$(WIDTH) $(HEIGHT) $(ALPHA_SHIFT) $(ALPHA_SHIFT_SLOW) $(GAUSS_EN)" | cmp -s - $@ || echo "$(WIDTH) $(HEIGHT) $(ALPHA_SHIFT) $(ALPHA_SHIFT_SLOW) $(GAUSS_EN)" > $@
```

- [ ] **Step 4.5: Run `make sim` — verify compile chain passes end-to-end**

```bash
make clean && make sim SOURCE="synthetic:color_bars" CTRL_FLOW=passthrough FRAMES=2 2>&1 | tail -30
```

Expected: compile succeeds, `Vtb_sparevideo` runs, prints `PASS`. If the compile fails with "unknown parameter `ALPHA_SHIFT_SLOW`" on any module, the plumbing is incomplete — re-check steps 4.2–4.4.

- [ ] **Step 4.6: Commit parameter propagation**

```bash
git add hw/top/sparevideo_top.sv dv/sv/tb_sparevideo.sv dv/sim/Makefile
git commit -m "feat(build): thread ALPHA_SHIFT_SLOW through Makefile/TB/top chain

sparevideo_top: add ALPHA_SHIFT_SLOW parameter, pass to
axis_motion_detect. tb_sparevideo: matching parameter + DUT override.
dv/sim/Makefile: -GALPHA_SHIFT_SLOW + config stamp so parameter
changes force Verilator recompile.
"
```

---

## Task 5: Integration Verification

With the code complete, run the full verification matrix mandated by the spec.

- [ ] **Step 5.1: Lint clean**

```bash
make lint 2>&1 | tee /tmp/lint.out | tail -20
```

Expected: `Info: Lint: 0 Errors, 0 Warnings`. If warnings appear, investigate and fix (not waive) in motion RTL.

- [ ] **Step 5.2: All IP unit TBs pass**

```bash
make test-ip 2>&1 | tail -20
```

Expected: `All block testbenches passed.`

- [ ] **Step 5.3: Passthrough smoke test**

```bash
make clean && make run-pipeline SOURCE="synthetic:color_bars" CTRL_FLOW=passthrough FRAMES=2
```

Expected: `PASS: 2 frames verified (model=passthrough, tolerance=0)` and `Pipeline complete!`.

- [ ] **Step 5.4: Primary mask-flow gates at TOLERANCE=0**

Run each of these three invocations. Each must end with `PASS: <N> frames verified (model=mask, tolerance=0)`:

```bash
make clean && make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=mask FRAMES=4 TOLERANCE=0
make clean && make run-pipeline SOURCE="synthetic:dark_moving_box" CTRL_FLOW=mask FRAMES=4 TOLERANCE=0
make clean && make run-pipeline SOURCE="synthetic:noisy_moving_box" CTRL_FLOW=mask FRAMES=4 TOLERANCE=0
```

If any fails at TOLERANCE=0, diff the first failing frame between RTL and model. Look at `dv/data/input.txt` vs `dv/data/output.txt` per CLAUDE.md's debugging guide.

- [ ] **Step 5.5: Motion-flow gate at TOLERANCE=0**

```bash
make clean && make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=motion FRAMES=4 TOLERANCE=0
make clean && make run-pipeline SOURCE="synthetic:two_boxes" CTRL_FLOW=motion FRAMES=4 TOLERANCE=0
```

Expected: `PASS` on both. The motion flow adds bbox overlay on top of the mask path; CCL and overlay code are unchanged, so this is a regression check.

- [ ] **Step 5.6: ccl_bbox flow sanity**

```bash
make clean && make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=ccl_bbox FRAMES=4 TOLERANCE=0
```

Expected: `PASS`.

- [ ] **Step 5.7: Parameter sweep spot-check**

Run a representative subset of the matrix (4 flows × 4 ALPHA_SHIFT × 3 ALPHA_SHIFT_SLOW is 48 runs; check boundary combinations):

```bash
for AS in 0 3; do
  for ASS in 5 7; do
    make clean && \
    make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=mask FRAMES=4 \
         TOLERANCE=0 ALPHA_SHIFT=$AS ALPHA_SHIFT_SLOW=$ASS || { echo "FAIL at AS=$AS ASS=$ASS"; exit 1; }
  done
done
```

Expected: all 4 combinations PASS.

- [ ] **Step 5.8: Visual check (human-in-loop)**

```bash
make clean && make run-pipeline SOURCE="synthetic:dark_moving_box" CTRL_FLOW=motion FRAMES=8
```

Open `dv/data/renders/synthetic-dark-moving-box__*.png` and confirm:
- (a) frame 0 shows no bbox (priming suppresses mask to zero → CCL produces no components).
- (b) frames 1+ show a single bbox tracking the box with no trail behind it on departure.
- (c) no multi-component fragmentation during the first few frames.

Report back in text what you see; do not mark this step complete unless the visual check passes. If Claude cannot view the PNG, explicitly state so and ask the user to confirm.

- [ ] **Step 5.9: Commit any drift in plan or spec found during verification**

If the verification surfaced something that demands a spec update, fold those changes in a separate commit before archiving:

```bash
git status
# If any *-design.md or *-plan.md changes are pending:
git add docs/plans/
git commit -m "docs(motion): corrections found during verification"
```

- [ ] **Step 5.10: Archive the spec and plan**

Per CLAUDE.md convention:

```bash
git mv docs/plans/2026-04-21-motion-mask-quality-design.md docs/plans/old/2026-04-21-motion-mask-quality-design.md
git mv docs/plans/2026-04-21-motion-mask-quality-plan.md docs/plans/old/2026-04-21-motion-mask-quality-plan.md
git commit -m "docs(plans): archive motion-mask-quality after implementation"
```

---

## Self-Review Notes

- **Spec coverage:** Each section of the spec maps to a task — Design → Tasks 2 & 3; Implementation Order (docs first) → Task 1; Architecture Surface / Parameter Propagation → Tasks 3 & 4; Verification Plan → Tasks 2.1-2.5 (Python), 3.1-3.6 (RTL unit), 5.1-5.8 (integration); Documentation Updates → Task 1.
- **No placeholders:** all code blocks contain concrete content. No `TODO`/`TBD`. Every test is fully written out; every RTL change shows the full replacement.
- **Type consistency:** the port/signal names used are consistent across tasks — `primed_i` (motion_core input), `primed` (wrapper register), `ema_update_slow_o`/`ema_update_slow` (matched), `ALPHA_SHIFT_SLOW` (parameter, identical everywhere). The TB's `tb_primed` is a separate golden-model flag — clearly named.
- **Scope:** ~50 bite-sized steps, 5 logical commits. Each task produces a coherent, reviewable slice.

---

**Next:** Ready for execution. Choose Subagent-Driven or Inline per the writing-plans handoff.
