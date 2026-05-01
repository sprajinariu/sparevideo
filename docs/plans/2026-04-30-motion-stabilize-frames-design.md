# Motion-Detect `stabilize_frames` — Smooth Grace→Selective-EMA Transition

**Status:** Design (brainstorming output)
**Date:** 2026-04-30
**Driver:** Bake-in ghosts on real-video clips, observed during the README-demo plan.

## 1. Problem

`axis_motion_detect` runs an EMA background model in three regimes:

| Regime | Trigger | Rate | Mask output |
|---|---|---|---|
| Hard-init | `!primed` (frame 0) | `bg = y_smooth` | gated 0 |
| Grace | `in_grace` (first `grace_frames` frames after priming) | `α = 1/(1<<grace_alpha_shift)` | gated 0 |
| Post-grace selective | else | fast `α = 1/(1<<alpha_shift)` if `!raw_motion`, slow `α = 1/(1<<alpha_shift_slow)` if `raw_motion` | live |

The selective-EMA rule (slow rate when `raw_motion=1`) is correct for *steady-state* operation: it prevents `bg` from absorbing stationary objects, so a stopped car keeps producing a mask instead of being silently merged into the background.

**The defect.** At the cliff at frame `grace_frames+1`, every pixel evaluates `raw_motion` for the first time post-grace. If a real object was at pixel P during the *last grace frame* (frame `grace_frames`), then `bg[P]` averaged at α=1/2 is still heavily contaminated by that object's color (50% weight on `Y[grace_frames]`, 25% on `Y[grace_frames-1]`, ...). When the object moves on at frame `grace_frames+1`, `Y[P]` is the true background but `bg[P]` is the contaminated value → `diff > THRESH` → `raw_motion=1` → slow EMA latches on a contaminated pixel and the ghost persists for ~`1/α_slow` frames.

This isn't a leak from frame 0; it's **fresh contamination from the last grace frame itself**. Bumping `grace_frames` does not help — there's always a "last grace frame" through which objects pass.

The synthetic README demo dodges this because frame 0 is bg-only by construction *and* the synthetic objects are small/fast. Real clips do not have either property.

## 2. Goal

Add a post-grace **stabilize window** in which the mask is enabled (so bboxes appear) but the slow-EMA branch is suppressed (every pixel uses the fast rate regardless of `raw_motion`). After the stabilize window expires, normal selective EMA resumes.

Why this works: a freshly-revealed pixel at the start of the window has `diff > THRESH`. Fast EMA at α=1/4 drives `diff` below THRESH within ~4–5 frames. Once the pixel's diff drops below THRESH, `raw_motion` flips to 0 and the pixel transitions cleanly into "non-motion fast EMA" mode. By the end of the stabilize window every contamination has either been flushed (if static) or is being actively driven by a real moving object (if dynamic). When selective EMA finally activates, only genuinely-moving pixels see slow rate — no cliff bake-in.

## 3. Non-goals

- Eliminating *all* trail effects from sustained-motion objects. Selective EMA is still the correct steady-state behavior; this design fixes only the grace-cliff bake-in.
- Changing the existing grace mechanism (rate, mask gating, counter). Grace remains as is.
- Changing the synthetic-source EMA behavior. With `stabilize_frames=0` (the default for non-demo profiles) behavior is identical to today.

## 4. Algorithm

New `cfg_t` field `stabilize_frames` (int, default 0).

State machine in `axis_motion_detect.sv`:

```
in_grace      = primed && (grace_cnt     <  grace_frames)
in_stabilize  = primed && !in_grace && (stabilize_cnt < stabilize_frames)
```

Both counters increment on `beat_done_eof` (end-of-frame strobe), only while their owning regime is active. `stabilize_cnt` is held at 0 until grace ends, then increments each frame until it reaches `stabilize_frames`.

`bg_next` selection:

```
if      (!primed)       bg_next = y_smooth;        // hard-init
else if (in_grace)      bg_next = ema_update_grace; // grace rate
else if (in_stabilize)  bg_next = ema_update;       // fast rate, regardless of motion
else if (!raw_motion)   bg_next = ema_update;       // post-stabilize fast
else                    bg_next = ema_update_slow;  // post-stabilize slow
```

Mask output gating:

```
m_axis_msk.tdata = mask_bit && !in_grace
```

(Unchanged from today. Stabilize emits real masks; only grace blanks.)

## 5. Behavior with `stabilize_frames=0`

When `stabilize_frames=0`, `in_stabilize` is always 0 (since `stabilize_cnt < 0` is never true for an unsigned counter), so the new branch never fires and the algorithm collapses to the existing three-regime logic. All current regression vectors remain bit-accurate.

## 6. Recommended values

| Profile | `stabilize_frames` | Rationale |
|---|---|---|
| `default`, `default_hflip`, `no_*` | 0 | preserve existing regression behavior |
| `demo` | 8 | ~0.5 s @ 15 fps; long enough for cliff residuals to decay below THRESH at α=1/4, short enough to leave 2 s of useful demo output after grace |

The exact value can be tuned at integration time.

## 7. Component impact

### 7.1 RTL (`hw/ip/motion/rtl/axis_motion_detect.sv`)

- New module parameter `STABILIZE_FRAMES` (compile-time, propagated from `cfg_t.stabilize_frames`).
- New register `stabilize_cnt` of width `STAB_CNT_W = $clog2(STABILIZE_FRAMES + 1)` (or 1 bit when `STABILIZE_FRAMES==0`).
- New combinational `in_stabilize`.
- `bg_next` `always_comb` extended with the new branch, ahead of `raw_motion`.
- Mask gating unchanged.

### 7.2 RTL (`hw/top/sparevideo_pkg.sv`)

- New field `int stabilize_frames` in `cfg_t` struct.
- Add `stabilize_frames: 0` to every existing `CFG_*` localparam (preserves behavior).
- Set `CFG_DEMO.stabilize_frames: 8`.

### 7.3 RTL (`hw/top/sparevideo_top.sv`)

- Propagate `CFG.stabilize_frames` as a named `.STABILIZE_FRAMES(...)` parameter to the `axis_motion_detect` instance.

### 7.4 Python model (`py/models/motion.py`)

- Implement the same regime selector. The Python model is the verification reference (`make verify` runs at `TOLERANCE=0`), so it must mirror the RTL exactly.

### 7.5 Python profiles (`py/profiles.py`)

- Add `stabilize_frames=0` (or whatever the field default is) to `DEFAULT`.
- `DEMO` overrides with `stabilize_frames=8`.

### 7.6 Tests

- `py/tests/test_profiles.py` — picks up the new field automatically via the existing parity check (no test code change required, just verify it still passes).
- New cases in `py/tests/test_models.py` — exercise the stabilize regime against a synthetic input where the cliff scenario fires (object at `Y[grace_frames]` removed at `Y[grace_frames+1]`) and assert the post-stabilize mask is clean.
- `hw/ip/motion/tb/` unit testbench — extend with a stabilize-window scenario, drive a known frame sequence, check that `mask_bit` decays cleanly across the stabilize window for a fresh post-grace contamination.

### 7.7 Architecture spec (`docs/specs/axis_motion_detect-arch.md`)

- Add a §X.Y "Stabilize window" subsection adjacent to the existing grace-window description.
- Update the regime table in the spec to include the new branch.
- Add a "Why selective EMA isn't enough on its own" rationale paragraph that points at the cliff issue.

## 8. Validation

- Existing `make test-py` and `make test-ip` regression matrix passes with `stabilize_frames=0` everywhere — bit-accurate, no behavioral changes.
- `make run-pipeline CFG=default` passes at `TOLERANCE=0` — Python and RTL agree.
- `make run-pipeline CFG=demo` passes at `TOLERANCE=0` — new branch is exercised and the model matches RTL.
- `make demo-real` produces a `real.webp` with no cliff bake-in (subjective visual confirmation).

## 9. Out of scope / future extensions

- **Sustained-motion trail decay** — pixels that genuinely register slow-rate motion across many frames still leave bg-contamination trails when the object moves on. Selective EMA is the correct trade-off for steady state, but a follow-up could explore "decay slow rate to fast rate after K frames of unchanging mask=1" if real-clip trails remain visible after this fix.
- **Camera-stabilization improvements** — the current OpenCV-based prep step (`py/demo/stabilize.py`) handles tripod sway adequately for short clips. Larger camera motions (handheld, panning) would need optical-flow registration in the RTL itself, which is a much larger plan.
- **Adaptive thresholding** — `motion_thresh` is per-stream rather than per-pixel; the cliff issue could also be tempered by an adaptive threshold that ignores low-confidence pixels during stabilize. Out of scope here.
