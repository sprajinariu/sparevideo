# Temporal-Differencing Ghost Detector — Implementation Plan

**Date:** 2026-04-23
**Status:** RETIRED 2026-04-23 — Phase A failed its decision gate on textured backgrounds and could not find a source-agnostic tuning. Parked. The LBSP+ViBe plan (`2026-04-22-lbsp-vibe-motion-pipeline-plan.md`) remains the escalation path when real-world / textured-bg deployments demand proper ghost suppression. Retained here for the record so the next attempt can read what was tried and why.

---

## Retrospective (2026-04-23)

### Outcome
Phase A reached its decision gate and was rejected. Phase B was never started. No documentation, RTL, or parameter-chain work was done.

### What was actually prototyped (all code still in `py/experiments/` pending cleanup)
A single fork `motion_tempdiff.py` with two orthogonal axes — four combinations tested against the 9-source stress matrix:

- **ref_mode ∈ {prev_frame, fast_ema}** — the temporal reference signal:
  - `prev_frame` (variant 1): `y_ref = y_{t-1}` — a literal previous-frame buffer.
  - `fast_ema` (variant 2): `y_ref = y_short`, an unconditional fast EMA with `SHORT_SHIFT`. Intended to preserve signal on slow-moving objects whose `y_{t-1}` identically matches `y_t` in the interior. Empirically worse than variant 1 on every source — the smoothing bled motion signal into ghost regions and inflated the motion ratio in pure-ghost sub-blobs.
- **classification_mode ∈ {ratio, fill}** — the spatial aggregation:
  - `ratio` (initial design): per-blob motion-votes / size ratio, with optional erosion-split (`blob_erode_iters`) to break fused ghost+object blobs. Same framework as Sobel `blob_erode`.
  - `fill` (added mid-experiment): pixel-level test `ghost = raw_motion AND NOT binary_dilation(frame_motion, iters=GHOST_FILL_ITERS)`. Sidesteps blob connectivity entirely.

### What the numbers said
Mask-area totals across the 9-source matrix, measured in pixels summed over 24 frames (lower = better ghost suppression):

| Source | baseline | Sobel best | tempdiff ratio+erode | **tempdiff fill iters=5** |
|---|---:|---:|---:|---:|
| moving_box | 149k | 71k | 98k | **56k** |
| dark_moving_box | 200k | 80k | 126k | **60k** |
| two_boxes | 91k | 44k | 52k | **36k** |
| noisy_moving_box | 125k | 125k | 93k | **44k** |
| multi_speed | 160k | 151k | 138k | **66k** |
| entering_object | 105k | 105k | 84k | **42k** |
| stopping_object | 133k | 129k | 55k | **28k** |
| lit_moving_object | 145k | 116k | 145k | **55k** |
| textured_static | 0 | 0 | 0 | 0 |

On **uniform-background** sources, `fill` with `ghost_fill_iters=5` produced visibly clean single-bbox tracking on `dark_moving_box` (documented in `dv/data/renders/tempdiff_vs_sobel_*.png`), better than any Sobel variant. The numerical story was *decisively* positive across the board.

### Why the plan was rejected despite the numbers

**1. `ghost_fill_iters=5` is an overfit to synthetic geometry.** The parameter is tied to the specific object size (80 px) and per-frame displacement (10 px) of our synthetic sources. Change either dimension and the sweet spot moves. This is the same pattern that killed the Sobel `blob_erode iters=5` — a good number on the test matrix that doesn't generalise. Mirroring the mistake into Phase B would bake a source-specific constant into RTL.

**2. Textured backgrounds produce spotty frame_motion, which the spatial dilation cannot repair.** On a uniform bg, the leading-edge frame_motion band is continuous: `|object_luma − bg_luma|` is one large value everywhere along the edge. On a textured bg, it becomes `|object_luma − bg_texture[p]|`, which varies per pixel — wherever the local texture happens to be close to the object's luma, the diff drops below `FRAME_DIFF_THRESH` and frame_motion has holes. Dilation from those holes gives scattered coverage of the object interior. Per-pixel classification then punches holes in the mask at every dropped edge pixel; CCL emits each hole as its own bbox → the "many small bboxes around the leading/trailing edge" artefact on textured sources.

The failure is at the **spatial aggregation** level, not the signal level. The per-pixel `frame_motion` signal is genuinely texture-invariant (static texture is identical between frames — it contributes zero). What's not texture-invariant is the step that tries to turn a sparse, partial edge signal into a full-object mask without knowing how big the object is or how fast it's moving.

**3. Every other aggregation trick we tried has the same kind of overfit.** The ratio mode needed `GHOST_MOTION_RATIO` tuned to object size. The erosion split needed `blob_erode_iters` tuned to the neck width between connected positions. The fill mode needs `GHOST_FILL_ITERS` tuned to half the per-frame displacement. All three are flavours of the same class of problem: without a real feature (optical flow, LBSP, multi-modal bg), any spatial aggregation of the motion evidence requires per-geometry parameter tuning.

### Three-frame differencing, considered and rejected
Mentioned mid-review as a possible escalation. Rejected after analysis:
- On slow-moving wide objects (our case), a pixel in the object's interior has `y_t ≈ y_{t-1} ≈ y_{t-2}` — all three equal. Three-frame AND gives no interior coverage; two-frame didn't either, and three-frame is no better.
- At the current leading edge, `|y_{t-1} − y_{t-2}| = 0` by definition (the object hadn't arrived yet at either). Three-frame AND zeros out the current leading edge entirely — strictly worse than two-frame. It is a *middle-frame* detector designed for fast small objects whose displacement exceeds their size, which is not our regime.

### Root cause
Approach A's per-pixel signal (`frame_motion`) is correct and texture-invariant. Approach A's spatial aggregation of that signal is not source-agnostic because any purely local / morphological classifier needs parameters that are functions of object geometry and motion rate. To break out of this loop you need either:
- A feature that already encodes the right spatial structure (LBSP's binary neighbourhood comparisons; optical flow's per-pixel motion vectors).
- A bg model that represents the pixel's genuine variability over time (ViBe / GMM).

Both paths are captured in the parked `2026-04-22-lbsp-vibe-motion-pipeline-plan.md`. That plan's cost estimate (~3 weeks RTL) stands.

### What superseded this
Nothing smaller or cheaper. The current choice is:
- **Ship baseline (grace + selective-EMA) as-is.** Uniform-bg ghosts remain. Textured-bg works. This is the honest answer if ghost suppression is not on the critical path.
- **Escalate to LBSP+ViBe when real footage demands it.** Multi-week scope; should be preceded by a Phase 1 Python experiment on representative real footage, not synthetics.

### Artifacts worth keeping
- `py/experiments/motion_tempdiff.py`, `test_tempdiff.py` (25 passing tests), `tempdiff_compare.py`, `tempdiff_vs_sobel.py`, `tempdiff_summary.py`. Moved to `py/experiments/old/` at cleanup time.
- `dv/data/renders/tempdiff_*.png` — visual evidence of the uniform-bg success and textured-bg failure.
- The `_compute_ghost_mask` dispatcher with per-pixel and blob-level classification variants — directly reusable by the LBSP+ViBe plan if the texture-invariant signal becomes available.

### Lessons to carry forward
1. "Beats Sobel on every synthetic source" is a weak endorsement when every synthetic source shares the same geometry. The Phase-A decision gate should have required sources with genuinely different object-to-displacement ratios before declaring a winner. Our `multi_speed` source was the closest we had, but even its three objects share the same size.
2. A parameter whose defensible value has to be justified post-hoc ("half the per-frame displacement") is a warning sign, not an explanation. If the rule generalised, it would have been a design input, not a retro-fit.
3. The Sobel plan's Phase 1 discipline continues to pay for itself: ~1.5 days of Python rejected an approach that would have cost ~5 days of RTL to re-reject. The pattern is: experiment, measure, *accept the result even when the numbers look good if the mechanism is fragile*.
4. Per-pixel *signal* correctness and per-pixel *aggregation* correctness are separate questions. Approach A had the first but not the second. When evaluating future ghost-detection proposals, ask both questions explicitly before prototyping.

---

## Original plan — preserved below for reference

---

## Session Context (read this first if starting fresh)

### How this plan came about
The prior plan, `docs/plans/2026-04-22-sobel-ghost-detector-plan.md`, proposed an asymmetric Sobel edge-match ghost classifier (`edge(bg) − edge(y) > tol`). Its Phase 1 Python experiment (still in `py/experiments/`) went through three variants:
1. **Per-pixel Sobel** — fragmented ghost blobs into rings → many false bboxes.
2. **Blob-level majority vote** — couldn't separate fused ghost+object blobs.
3. **Blob-level + erosion (iters=5)** — worked on `dark_moving_box` but required per-source tuning and still degraded on textured backgrounds.

A literature review (`docs/plans/2026-04-22-lbsp-vibe-motion-pipeline-plan.md` references Sakbot / MDPI / Sehairi) identified the failure mode as a signal choice: edge asymmetry is dominated by static texture on textured bg. The canonical simple replacement from the literature is temporal differencing combined with bg subtraction — exactly the hybrid the Sehairi survey flags as baseline good practice, and the signal Sakbot approximates at lower cost than optical flow.

A more complete literature-standard rewrite (LBSP + two-layer ViBe + dynamic thresholds) is parked as future work in `2026-04-22-lbsp-vibe-motion-pipeline-plan.md`. This plan is the smaller, pragmatic fix.

### What stays the same (do not touch)
- Priming (frame-0 hard-init) — `primed` register in `axis_motion_detect`.
- Grace window — `grace_cnt`, `GRACE_FRAMES`, `GRACE_ALPHA_SHIFT`.
- EMA background model — bg RAM, `_ema_update`, `_selective_ema_update`.
- Selective EMA (fast-rate vs slow-rate mask-driven update) — protects real moving objects' bg from self-contamination.
- `axis_gauss3x3`, `axis_fork`, `axis_overlay_bbox`, `rgb2ycrcb`.

### What changes
- New per-pixel signal `frame_motion = |y_t − y_ref| > FRAME_DIFF_THRESH` computed inside `axis_motion_detect`. Needs a new RAM holding `y_ref`. Two Phase-A variants for the reference signal:
  - **Variant 1 — literal prev-frame:** `y_ref = y_{t−1}`. Simplest. Slow-object weakness: interior pixels of objects moving ≤1 px/frame have zero `frame_motion` because consecutive frames match; only dilation widens the leading/trailing edge band.
  - **Variant 2 — short-term fast EMA:** `y_ref = y_short`, where `y_short ← y_short + (y_t − y_short) >> SHORT_SHIFT` at a fixed fast rate, unconditionally (not mask-selective). A slow-moving object's interior has `y_short` lagging toward the object's luma, so `|y_t − y_short|` remains nonzero for roughly `1/α_short` frames after the object arrives — giving usable motion signal down to ~1 px per `1/α_short` frames. Stationary absorption becomes a tuning knob (`SHORT_SHIFT`) instead of a hard 1-frame edge. Same RAM cost as variant 1; adds one EMA update.
  Phase A runs both and the decision gate picks the one that generalises cleanly. If both pass, variant 1 wins on simplicity (one fewer parameter, no EMA arithmetic in the reference path). This plan describes the shared skeleton; the RTL section (B.3) spells out the two code paths.
- A small dilation stage over `frame_motion` (handles wide objects with large interior overlap between consecutive frames). Parameterised by `GHOST_DILATE_ITERS`.
- `axis_ccl` gains one new per-label accumulator (count of frame_motion pixels per blob), one new parameter (`GHOST_MOTION_RATIO`), and one new EOF test (ratio < threshold → blob flagged ghost).
- `motion_core` rewrites the 4-way `bg_next` mux `ghost` branch: source of ghost signal is now (previous frame's) CCL per-blob ghost classification mapped to pixels, not Sobel asymmetry.
- No Sobel, no bg_linebuf, no erosion. Net removal of the three stages the Sobel plan had proposed for Phase 3.

### Pipeline after this plan
```
RGB AXIS in → rgb2ycrcb → axis_gauss3x3 → y_smooth
                                            │
                                            ├──► bg RAM[out_addr] → y_bg
                                            │                       │
                                            │                       ▼
                                            │               raw_motion = |y_smooth − y_bg| > T1
                                            │
                                            └──► y_ref RAM → y_ref
                                                 (variant 1: y_ref = y_{t-1})
                                                 (variant 2: y_ref updated as fast EMA
                                                  y_short ← y_short + (y_t - y_short)>>SHORT_SHIFT)
                                                                  │
                                                                  ▼
                                                    frame_motion = |y_smooth − y_ref| > T2
                                                                  │
                                                                  ▼
                                                    dilate(frame_motion) → fm_dil

                                  raw_motion ──► axis_ccl (blob labeling)
                                  fm_dil     ──► axis_ccl (per-label vote accumulator)
                                                    │
                                                    ▼ EOF:
                                                    motion_ratio(b) = vote_count(b) / size(b)
                                                    if ratio < GHOST_MOTION_RATIO: ghost blob
                                                    emit (bbox, ghost_flag) per blob

                            (feedback, 1-frame delay)   ghost blob labels → per-pixel ghost map
                                                                              │
                                                                              ▼
                                                                     motion_core bg_next mux
```

### Key files
| File | Role | Change |
|---|---|---|
| `hw/ip/motion/rtl/axis_motion_detect.sv` | Wrapper — bg RAM, priming, grace, selective EMA, feeds CCL | Add `y_ref` RAM + subtractor + compare. Variant 2 adds a fast-EMA update on the RAM write path. Optional: add dilation stage. Rework the bg_next mux ghost source. |
| `hw/ip/motion/rtl/motion_core.sv` | Combinational bg_next decision | Replace ghost input from Sobel with ghost from CCL feedback (per-pixel map). |
| `hw/ip/motion/rtl/axis_ccl.sv` | Streaming CCL, per-label accumulators, EOF resolution | Add per-label vote accumulator; widen EOF bbox-emit to include ghost classification; optionally add per-pixel label output port. |
| `hw/top/sparevideo_pkg.sv` | Project parameters | Add `FRAME_DIFF_THRESH`, `GHOST_MOTION_RATIO`, `GHOST_DILATE_ITERS`. Plus `SHORT_SHIFT` if variant 2 is picked. |
| `py/models/motion.py`, `py/models/mask.py`, `py/models/ccl_bbox.py` | Reference models | Promote temporal-diff logic; drop Sobel paths. |
| `py/models/ccl.py` | CCL reference model | Add vote accumulator + EOF ghost classification. |
| `py/experiments/` | Phase A prototype lives here | New `motion_tempdiff.py`, new test + compare harness. Phase 1 Sobel code stays around for A/B comparison until Phase A completes, then gets cleaned up. |
| `dv/sv/tb_sparevideo.sv`, top `Makefile`, `dv/sim/Makefile` | Parameter propagation | Add the three new parameters through the full chain. |
| `docs/specs/axis_motion_detect-arch.md` | Architecture contract | Add temporal-diff section; update bg_next mux description; remove or supersede §10.1 Sobel follow-up. |
| `docs/specs/axis_ccl-arch.md` | CCL architecture | Add vote accumulator; update EOF FSM cycle budget if ghost classification widens the `V_BLANK` requirement. |

### Project conventions (from CLAUDE.md)
- SV, no SVA, no classes. `logic` only. `always_ff` / `always_comb`.
- Active-low reset. Parameters in `hw/top/sparevideo_pkg.sv`.
- New compile-time knobs propagate through the full Makefile chain: top Makefile `?=` → SIM_VARS → dv/sim/Makefile → VLT_FLAGS `-G` → `tb_sparevideo` → DUT.
- Commit messages: conventional-commits style, no `Co-Authored-By` trailer.
- Docs go to `docs/plans/` (design + plan files) and `docs/specs/` (arch contracts). **Not** `docs/superpowers/specs/`.
- `make lint` clean after every RTL change.
- Reference-model-golden unit TBs; `TOLERANCE=0` gate.

---

## Phase A — Python Prototype + Visual Decision Gate

**Objective:** Prove temporal-differencing + blob-level motion-ratio meets the plan's decision criteria on all stress-test sources from the Sobel experiment, including the textured/dynamic cases where Sobel failed. All work in `py/experiments/` — fully isolated; deletable if the experiment fails.

### Deliverables
- `py/experiments/motion_tempdiff.py` — fork of `py/models/motion.py`. Implements:
  - Per-pixel `frame_motion` via a reference-luma buffer (seeded with priming frame). Two modes selectable via `ref_mode ∈ {"prev_frame", "fast_ema"}`:
    - `prev_frame` (variant 1): each frame, `y_ref ← y_t` after reading the previous value for the diff. One copy op per frame, no arithmetic.
    - `fast_ema` (variant 2): `y_ref ← y_ref + (y_t − y_ref) >> SHORT_SHIFT`, unconditionally (not mask-driven). Default `SHORT_SHIFT=2` (α=1/4).
  - Optional dilation of `frame_motion` (parameter `ghost_dilate_iters`, default 2).
  - Per-blob motion-ratio aggregation using `scipy.ndimage.label` on `raw_motion` (mirrors how `_blob_promote` already works in `motion_sobel.py`).
  - Ghost decision at blob level: `ratio < GHOST_MOTION_RATIO` (default 0.05) → suppress.
  - 4-way bg update mux — same shape as today; ghost branch overrides slow-EMA with fast-EMA.
  - `run`, `run_mask`, `run_ccl_bbox` entry points matching the Sobel experiment's interface (reuse compare / diagnostic harness plumbing).
  - `ghost_enable=False` reduces to the baseline motion model bit-for-bit (regression invariant), independent of `ref_mode`.
- `py/experiments/test_tempdiff.py` — unit tests:
  - Frame-diff operator on canonical patterns (uniform, translating block, static texture).
  - Baseline equivalence when disabled (four sources × TOLERANCE=0).
  - Baseline equivalence with an unreachable ratio (mode on, ratio=1.1 — no blob can exceed → no suppression).
  - Pure ghost blob (no frame_motion inside) gets suppressed.
  - Pure real blob (frame_motion dense inside) is kept.
  - Slow-object regression: W=64 blob, D=2 px/frame — is NOT spuriously suppressed at default `GHOST_DILATE_ITERS` and `GHOST_MOTION_RATIO`.
  - Variant-2 decay behaviour: with `ref_mode="fast_ema"`, a static injected blob's `frame_motion` decays to zero within ~`1/α_short` frames (closed-form sanity check against the EMA math).
  - Variant equivalence when disabled: both `ref_mode` values produce identical output when `ghost_enable=False` (regression invariant is mode-independent).
- `py/experiments/tempdiff_compare.py` — A/B/C comparison harness mirroring `sobel_ghost_compare.py`:
  - For each source: renders row-stack of INPUT / BASELINE (ghost off) / VARIANT-1 ratio=0.05 / VARIANT-1 ratio=0.10 / VARIANT-2 ratio=0.05 / VARIANT-2 ratio=0.10. Outputs `dv/data/renders/tempdiff_experiment_<source>_<view>.png`. Views: `mask`, `motion`, `ccl_bbox`.
- `py/experiments/tempdiff_vs_sobel.py` — side-by-side: BASELINE / SOBEL-BLOB-ERODE (best-of the old prototype) / TEMPDIFF (Phase-A chosen variant). Makes the decision-gate comparison explicit.

### Test matrix
- **Nine synthetic sources** (all from the existing stress-test): `moving_box`, `dark_moving_box`, `two_boxes`, `noisy_moving_box`, `multi_speed`, `entering_object`, `stopping_object`, `lit_moving_object`, `textured_static`.
- **Dimensions**: WIDTH=320, HEIGHT=240, FRAMES=24.
- **Parameter sweeps**:
  - `ref_mode ∈ {"prev_frame", "fast_ema"}` — the two Phase-A variants.
  - `FRAME_DIFF_THRESH ∈ {8, 16, 24}` — find the threshold that rejects sensor noise on `noisy_moving_box` without missing real motion elsewhere.
  - `GHOST_DILATE_ITERS ∈ {0, 1, 2, 3}` — measure impact on slow-object regression and on ghost-trail suppression.
  - `GHOST_MOTION_RATIO ∈ {0.02, 0.05, 0.10}` — find the lowest threshold that still cleanly separates zero-motion ghosts from any-motion real blobs.
  - `SHORT_SHIFT ∈ {1, 2, 3}` — only swept with `ref_mode="fast_ema"`. α ∈ {1/2, 1/4, 1/8} → stationary-absorption time ∈ {~3, ~6, ~15} frames. Lower shift = faster absorption; higher shift = longer sustained signal for slow objects at the cost of more lingering ghosts.
- **Gaussian prefilter** (`GAUSS_EN=1`) on by default; should particularly help `noisy_moving_box`.

### Decision gate
Human reviews the rendered PNGs. **Proceed to Phase B only if** ALL of:
1. `dark_moving_box`: post-grace ghost is absent or dramatically reduced; bbox tracks only the current object; no extra trailing bboxes.
2. `moving_box`: same as (1).
3. `two_boxes`: both objects tracked independently; no merging; no spurious bboxes in the trail.
4. `noisy_moving_box`: no spurious bboxes from noise; ghost suppression still works on the real object's trail.
5. `lit_moving_object`: textured bg does NOT spuriously trigger frame_motion; objects tracked; any remaining issue is no worse than baseline (gradual illumination is out of scope for this plan).
6. `textured_static`: zero mask output — static texture alone must not trigger frame_motion after EMA has settled.
7. `stopping_object`: explicit human call — under this approach, a stopped object disappears from the bbox output within ~1/alpha_fast frames (~8 frames). This is intentional "stationary object absorption" per the literature. Gate passes if reviewer confirms this behaviour is desired for the project, or if the source is retired from the regression suite because the intent of the test is re-evaluated.
8. `entering_object`, `multi_speed`: at least as clean as the old baseline; no regressions.

If any gate fails: iterate on parameters (sweep above) first; if no combination passes all gates, stop and park this plan as well. The fallback is the parked LBSP+ViBe plan.

### Investigation items for Phase B scoping

Two orthogonal Phase-B scoping decisions come out of Phase A. Both should be resolved before committing RTL effort.

- **Reference-signal variant (1 vs 2).** Variant 1 (literal prev-frame) is strictly simpler — no EMA arithmetic, one fewer parameter. Variant 2 (fast-EMA `y_short`) gains usable ghost signal on slow-moving objects at the cost of one more knob. Pick variant 1 if it passes the decision gate alone. Escalate to variant 2 only if the slow-object regression criterion fails under variant 1 at every sweep setting.
- **Feedback scope (A1 vs A2).** Orthogonal to the variant choice:
  - **A1**: ghost blobs drop out of bbox output ONLY (no bg-update feedback). Ghost pixels still drift at slow selective-EMA rate → bg heals slowly (~64 frames).
  - **A2**: ghost blobs also feed back to bg-update (fast EMA override for ghost pixels). bg heals in ~8 frames.
  If A1 passes all gates, Phase B skips the per-pixel-label output port on `axis_ccl` and saves meaningful RTL complexity. If only A2 passes, Phase B takes on that additive CCL change.

The two decisions give a 2×2 outcome matrix. Record the chosen cell explicitly at the end of Phase A.

### Effort estimate
~1.5 days of Python, assuming direct reuse of the Sobel experiment's render / compare infrastructure. The half-day addition vs. the single-variant plan covers the variant-2 EMA update logic and the additional sweep dimension.

---

## Phase B — Documentation, RTL, Verification

Only start after Phase A's decision gate passes and the A1-vs-A2 question is settled.

### B.1 — Documentation first (~0.5 day)

Update before any RTL touches code:

- **`docs/specs/axis_motion_detect-arch.md`**:
  - New §5 Temporal-Differencing subsection under Datapath: `y_ref` RAM, frame_diff subtractor, comparator, optional dilation stage. Document the Phase-A-chosen variant (literal prev-frame vs fast-EMA `y_short`) and why the other was rejected.
  - Update §4.4 selective-EMA to cross-reference the ghost override source.
  - Update §3.1 parameter table: add `FRAME_DIFF_THRESH`, `GHOST_DILATE_ITERS`. Plus `SHORT_SHIFT` if variant 2 was picked.
  - Remove §10.1 (Sobel follow-up) — feature superseded.
  - Add to §6 signal table: `frame_motion`, `fm_dil` (if dilation used), `ghost_blob_mask` (from CCL feedback). Plus `y_short` if variant 2 was picked.
- **`docs/specs/axis_ccl-arch.md`**:
  - Add per-label vote accumulator to the state description.
  - Update EOF resolution FSM phase description if an extra cycle is needed for the ratio test.
  - Add `GHOST_MOTION_RATIO` to the parameter table.
  - If Phase A chose A2, document the per-pixel label output port.
- **`CLAUDE.md`** — "Motion pipeline — lessons learned": add a bullet explaining the hybrid (bg-subtraction for shape, frame-diff for motion validity), and a bullet noting the stationary-object-absorption behaviour under this design.
- **`README.md`** — add the three new parameters to the parameter table and build-command example.
- **Top `Makefile`** — add parameters to `help:` output.

### B.2 — Python reference model alignment (~0.5 day)

- Promote `motion_tempdiff.py` logic back into `py/models/motion.py`, `py/models/mask.py`, `py/models/ccl_bbox.py`.
- Extend `py/models/ccl.py` with the per-label vote accumulator and EOF ghost classification.
- Update `py/harness.py` to accept `--frame-diff-thresh`, `--ghost-dilate-iters`, `--ghost-motion-ratio`. Plus `--short-shift` if variant 2 was picked.
- Update `py/tests/test_models.py` with end-to-end coverage for the new ghost logic across every control flow (motion, mask, ccl_bbox).

### B.3 — RTL implementation (~2–3 days)

- **`axis_motion_detect.sv`**:
  - Add `y_ref` RAM (same size and port shape as the existing bg RAM). Seed with the priming frame's `y_smooth`.
  - **Variant 1 (literal prev-frame)**: RAM write-back is `y_ref ← y_t` on the beat-accepted edge. No arithmetic on the ref path. This is the simplest wiring — effectively a frame delay line in RAM form.
  - **Variant 2 (fast-EMA y_short)**: RAM write-back is `y_ref ← y_ref + (y_t − y_ref) >>> SHORT_SHIFT`, unconditionally (not mask-gated). Structurally identical to the bg-EMA path but with a fixed small shift, so the existing EMA adder/shifter infrastructure can be reused as a second instance. Propagate `SHORT_SHIFT` as a compile-time parameter.
  - Add frame-diff comparator producing `frame_motion = |y_t − y_ref_read| > FRAME_DIFF_THRESH`.
  - Optional: implement dilation as a small 3×3 morphological-OR streaming stage reusing `axis_gauss3x3`'s 2-line buffer skeleton (compile-time iters via an unrolled chain or shared-buffer loop).
  - Emit both `raw_motion` and (dilated) `frame_motion` into the CCL stream.
  - Wire the CCL's per-pixel ghost feedback (A2) or per-blob ghost flags (A1) into the bg_next mux.
  - Propagate `FRAME_DIFF_THRESH`, `GHOST_DILATE_ITERS`, and (variant 2 only) `SHORT_SHIFT` parameters.
- **`motion_core.sv`**:
  - Accept a per-pixel ghost input (fed from the CCL feedback, 1-frame latency — matches how selective-EMA already uses `raw_mask`).
  - 4-way mux keeps the same priority: `!primed → y_smooth`, `in_grace → ema_grace`, `ghost → ema_fast`, `raw_motion → ema_slow`, `else → ema_fast`.
- **`axis_ccl.sv`**:
  - Accept a second per-pixel input stream alongside the mask. Gate it on the same beat-strobe pattern used for the mask (see CLAUDE.md "Beat-strobe pattern for multi-consumer mask broadcast").
  - Per-label: existing `acc_*[]` + size counter + new `motion_vote_count[]`.
  - EOF: extend the resolution FSM with a per-kept-label ratio test; mark labels whose ratio < `GHOST_MOTION_RATIO` as ghost; suppress ghost labels from the output bbox stream.
  - If A2: emit per-pixel ghost mask into a downstream output port sized 1 bit per pixel, streaming alongside pixel output during the next frame's active period (or via a dedicated frame buffer).
  - Update the vblank FSM cycle budget; the EOF ratio test adds one pass over kept labels.
- **`hw/top/sparevideo_pkg.sv`**, **`sparevideo_top.sv`**, **`tb_sparevideo.sv`**, **top `Makefile`**, **`dv/sim/Makefile`**: propagate the new parameters through the full chain (`FRAME_DIFF_THRESH`, `GHOST_MOTION_RATIO`, `GHOST_DILATE_ITERS`, plus `SHORT_SHIFT` if variant 2 was picked). Update `dv/sim/Makefile`'s config stamp so changes trigger recompilation.

### B.4 — Verification (~1 day)

- `make lint` clean.
- Unit TBs:
  - Extend `hw/ip/motion/tb/tb_axis_motion_detect.sv` to mirror the new Python model (golden-model parity at TOLERANCE=0).
  - Extend `hw/ip/motion/tb/tb_axis_ccl.sv` (or equivalent) to cover vote-accumulation and ghost classification.
- Integration: `make run-pipeline` at TOLERANCE=0 across the full control-flow × parameter matrix:
  - 4 control flows × 9 sources × `{GHOST_ENABLE=0, GHOST_ENABLE=1}` × `FRAME_DIFF_THRESH ∈ {Phase-A default, ±50%}` × `GHOST_MOTION_RATIO ∈ {Phase-A default, ±50%}`.
- Visual parity check: render each source end-to-end and confirm the RTL output matches the Phase A Python baseline at the decision-gate settings.

### Cleanup
- After B.4 passes, move the Sobel experiment in `py/experiments/` to `py/experiments/old/` with a README explaining why it was superseded.
- Move this plan to `docs/plans/old/2026-04-23-temporal-diff-ghost-plan.md` following the project convention.
- Move the Sobel plan (`2026-04-22-sobel-ghost-detector-plan.md`) to `docs/plans/old/` with an "experiment failed, superseded by..." note at the top.

### Effort estimate
B.1 + B.2 + B.3 + B.4 ≈ **4–5 days** end-to-end, compared to the Sobel plan's Phase 3 estimate of 2–3 days. The RTL change is simpler (one new stage vs. three) but the CCL extension is non-trivial — particularly A2.

---

## Known Risks / Open Questions

1. **Per-frame sensor noise triggering `frame_motion`.** On `noisy_moving_box` the noise amplitude is 10; `|noise_t − noise_{t-1}|` can reach 20. The Gaussian prefilter reduces this by ~3× (effective amp ≈ 3, diff ≈ 6), well below a `FRAME_DIFF_THRESH` of 16. But if Gaussian is disabled (`GAUSS_EN=0`), the threshold must be raised accordingly. Phase A sweep identifies the safe minimum.

2. **Slow-object regression.** At very low displacement (≤ 1 px/frame on wide objects), the naive prev-frame-diff motion-ratio shrinks toward zero. Three mitigations stack, in order of cost: dilation of `frame_motion`, a low ratio threshold, and variant 2's fast-EMA `y_short` reference which holds residual signal for objects moving slower than `1/α_short` pixels per frame. A truly-stopped object (D=0 for more than the absorption window) gets absorbed into bg by design. Any application that needs persistent stopped-object tracking requires a separate feature (out of scope).

3. **CCL per-pixel label output port (A2).** Exposing a stream of labels mid-frame is non-trivial because union-find may merge labels later. Options: (a) emit at EOF after resolution, buffering feature data for a frame — costs memory; (b) emit provisional labels and apply the equivalence chain retroactively — complex. Decide only if Phase A shows A1 (no feedback) is insufficient.

4. **Interaction with the CCL `V_BLANK` budget.** The vblank margin is sized for the current EOF FSM (~16 lines). Adding a per-label ratio pass consumes additional cycles. Verify in Phase B.3 and extend `V_BLANK` if needed; `sparevideo_top`'s existing SVAs `assert_fifo_in_not_full` / `assert_fifo_out_not_full` catch overflows.

5. **Illumination changes.** Gradual per-frame illumination shift (as in `lit_moving_object`) produces small but nonzero frame_motion globally. At default thresholds this typically stays below the trigger level, but fast illumination changes will cause spurious whole-frame motion. This is a known limitation — proper handling requires LBSP or histogram equalisation (parked in the LBSP+ViBe plan).

6. **Shadow handling.** Not addressed here. Shadows cast by moving objects will be tracked as motion (they change frame-to-frame at the shadow's leading/trailing edges). If shadow suppression is later added, it belongs as a pre-filter on `raw_motion` before CCL (Sakbot-style HSV test), not in the ghost detector.

---

## Decision Gates Summary

| Gate | Question | If No → |
|---|---|---|
| End of Phase A | Do the renders meet all eight gate criteria with a single settings combination? | Iterate on parameter sweep; if exhausted, park this plan and reconsider LBSP+ViBe. |
| Variant 1 vs 2 | Does variant 1 (literal prev-frame) pass all gates by itself? | If yes, lock variant 1 for Phase B (simpler, one fewer parameter). If no, escalate to variant 2 (fast-EMA `y_short`). If neither passes, park. |
| A1 vs A2 | Does A1 (no bg-update feedback) already pass all gates? | If yes, skip the per-pixel label output port in Phase B. If no, A2 is required; accept the additional CCL output port. |
| End of Phase B.1 | Is the arch doc self-consistent with the Phase A Python? | Iterate on docs before starting RTL. |
| End of Phase B.4 | Do all integration tests pass at TOLERANCE=0 and does each source's visual match Phase A? | Debug RTL↔Python parity gap before cleanup. |

---

## References

- `docs/plans/2026-04-22-sobel-ghost-detector-plan.md` — the predecessor plan. Phase 1 findings are the direct motivation for this plan.
- `docs/plans/2026-04-22-lbsp-vibe-motion-pipeline-plan.md` — the parked future-work plan. If approach A fails textured/real-world coverage, that plan is the next escalation.
- Sakbot: Cucchiara et al., IEEE TPAMI 2003 — canonical ghost taxonomy; their actual ghost test is optical flow, temporal differencing is the simpler approximation.
- Sehairi et al., J. Electron. Imaging 2017 (arXiv 1804.05459) — the survey; flags `frame differencing + bg subtraction` hybrid as canonical simple ghost handling.
- MDPI Two-Layer, Sensors 2020 (PMC7472150) — source of the LBSP/histogram-similarity complement for future work.

---

## Starting-state checklist (for a fresh session)

1. **Branch and commits:**
   ```bash
   git branch --show-current          # current feature branch
   git log --oneline -15              # see the Sobel Phase 1 commits and this plan's commit
   git status --short                 # expect only py/experiments/* from Sobel still present
   ```

2. **Toolchain sanity:**
   ```bash
   source .venv/bin/activate
   make lint                          # expect: PASS
   make test-ip                       # expect: all block TBs green
   pytest py/tests/ py/experiments/ -v   # expect: ~77+20 = ~97 passing (Sobel experiment still around)
   make run-pipeline SOURCE="synthetic:dark_moving_box" CTRL_FLOW=motion FRAMES=12 TOLERANCE=0
   # expect: PASS; rendered PNG shows the post-grace ghost bug (this plan fixes it).
   ```

3. **Read the prior plans (in order):**
   - `2026-04-21-motion-mask-quality-design.md` — original design spec for priming + selective EMA.
   - `2026-04-22-motion-grace-window-plan.md` — grace window plan (implemented).
   - `2026-04-22-sobel-ghost-detector-plan.md` — the Phase-1 failure we're superseding.
   - `docs/specs/axis_motion_detect-arch.md` — authoritative arch contract.

4. **Acceptance criteria:** see the eight bullets in Phase A's Decision Gate.
