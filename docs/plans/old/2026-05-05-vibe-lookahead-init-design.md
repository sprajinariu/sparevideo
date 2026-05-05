# ViBe Look-Ahead Median Init — Design

**Date:** 2026-05-05
**Status:** Design — pending implementation
**Companion (parent) doc:** [`2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md)
**Phase-0 ghost findings:** [`2026-05-04-vibe-phase-0-results.md`](2026-05-04-vibe-phase-0-results.md)

## 1. Goal & scope

### Goal

Add a Python-only experiment that seeds the ViBe sample bank using a *temporal-median over a look-ahead window* of the input clip, instead of the canonical frame-0 init. Measure whether this kills the frame-0 ghost on the synthetic stress sources (`ghost_box_disappear`, `ghost_box_moving`) and whether it improves real-demo-clip output (`birdseye`, `people`, `intersection`).

### Motivation

Phase-0 confirmed that canonical-ViBe diffusion at K=20, φ=16 cannot clear an 80×60 frame-0 ghost within 200 frames (~2.2 inward leaks per frame against ~96,000 sample slots — see [`2026-05-04-vibe-phase-0-results.md` §"Why the ghost doesn't clear in 200 frames"](2026-05-04-vibe-phase-0-results.md)). The φ_diffuse sweep showed that only the always-fire setting (φd=1) clears such a ghost in the 200-frame window, at the cost of much faster sample-bank churn on real clips.

The look-ahead-median init bypasses the diffusion-decay question entirely by giving ViBe a "true bg" estimate at frame 0, computed using knowledge of frames 1..N-1. It does not modify ViBe's decision or update rules; only the center value used by the existing scheme-(c) noise routine changes from "frame-0 pixel value" to "median pixel value over a look-ahead window".

### Scope (this experiment)

- Lives under `py/experiments/`. No changes to `py/models/`. No RTL implications.
- Reuses the existing `ViBe` class — adds a new init entry point (`init_from_frames`) without removing `init_from_frame`.
- Headline run: one new experiment script that runs five sources × three init modes on **raw** ViBe and emits coverage curves + a comparison grid.
- Conditional follow-up (gated on positive headline results): a second smaller script runs the winning look-ahead mode through the **full motion pipeline** (gauss → ViBe → morph_open → morph_close) on the three real-demo clips, to confirm the win survives pre/post-processing. Pipeline ops are imported from `py/models/`; no `py/models/` files are modified.

### Promotion path (if results are good)

API is designed so the look-ahead-median init can later become a `cfg_t`-selectable option in `py/models/motion_vibe.py` (e.g., `bg_init_mode: "frame0" | "lookahead_median"`, `bg_init_lookahead_n: int`). To keep that path clean, `init_from_frames` lives as a real method on `ViBe` (not a free function in the experiment script) and takes its parameters explicitly, so promotion is a copy of the method into the future `motion_vibe.py` plus wiring of the `cfg_t` field.

### Non-goals (this experiment)

- RTL feasibility analysis or implementation.
- Promoting to `py/models/motion_vibe.py` now.
- Replacing the canonical frame-0 init as the default.
- Changing the ViBe decision rule, update rule, or PRNG order.
- Sweeping `lookahead_n` over more than the two chosen values.
- Sweeping K, R, φ_update, φ_diffuse, init_scheme, or coupled_rolls.

## 2. Algorithm

**Look-ahead median init** (`init_from_frames(frames, lookahead_n)`):

1. Take the first `lookahead_n` frames of the clip (or all of them if `lookahead_n is None` → "full clip" mode). All frames are 2-D uint8 Y arrays of identical shape.
2. Stack to a `(N, H, W)` array; compute per-pixel temporal median → `bg_est: (H, W) uint8`.
3. Hand `bg_est` to the existing init-scheme routine — i.e., for the default `init_scheme="c"`, each of the K sample slots = `clamp(bg_est + noise, 0, 255)` with the same modulo-41 8-bit-lane PRNG path used today in [`_init_scheme_c`](../../py/experiments/motion_vibe.py). Schemes (a) and (b) are also dispatched; only the *center value* changes from "frame 0 pixel value" to "median pixel value".
4. PRNG advances are still `ceil(K/4)` per pixel (scheme c) or 1 per pixel (scheme a) or 0 per pixel (scheme b), matching the existing init-scheme contracts.

After init, `process_frame` is unchanged — the experiment runs all frames `0..end` against this seeded bank.

### Why median (not mean)

Median is robust to a single transient foreground occupying a pixel for <50% of the look-ahead window; mean would smear foreground values into the bg estimate. Both are O(N) per pixel (median via partition); for N=20 and 320×240 frames the cost is irrelevant.

### Edge case — pixel under foreground for >50% of the window

The median collapses to a foreground value. The bank seeds to "foreground colour ± 20 noise". On the first frames where the object is at that pixel, ViBe classifies it as bg (correctly for that *value*, wrongly for the *scene*). When the object moves away, raw bg appears as motion until diffusion clears it — this is the *inverse* ghost.

We do not expect this on `ghost_box_disappear` for `lookahead_full` (the box is at a pixel for frame 0 only, then absent for 199 frames → median = bg, no inverse ghost). On real clips with a slow-moving object lingering at one pixel for >half the window, an inverse ghost can appear. The coverage curves and visual grid will reveal this if it happens.

### What this does *not* address

A pixel that is under foreground for the **entire** look-ahead window has no bg ground truth available from the median, regardless of N. This is the same limitation the canonical frame-0 init has at every pixel touched by frame-0 foreground. For deployment, PBAS-style adaptive R(x) (per Doc A §6) is the literature answer; this experiment does not implement that.

## 3. API changes

**New method on `ViBe`** in [`py/experiments/motion_vibe.py`](../../py/experiments/motion_vibe.py):

```python
def init_from_frames(
    self,
    frames: np.ndarray,           # (N, H, W) uint8, N >= 1
    lookahead_n: Optional[int] = None,  # None = use all frames
) -> None:
    """Seed sample bank from temporal median over the first lookahead_n frames.

    Equivalent to init_from_frame(median(frames[:lookahead_n], axis=0)) but
    routes through the configured init_scheme so noise structure matches.
    """
```

Implementation:

- Validate: `frames.ndim == 3`, `frames.dtype == np.uint8`, and `1 <= lookahead_n <= len(frames)` (or `lookahead_n is None`, treated as `len(frames)`).
- `bg_est = np.median(frames[:n], axis=0).astype(np.uint8)` — `np.median` returns float; cast to uint8.
- Dispatch to existing `_init_scheme_a` / `_init_scheme_b` / `_init_scheme_c`, passing `bg_est` as the frame argument.

**No changes to** `init_from_frame`, `compute_mask`, `process_frame`, the self-update or diffusion paths, or the PRNG advance order. The constructor signature is unchanged.

## 4. Experiment harness

**New script** `py/experiments/run_lookahead_init.py` — sibling to the existing `run_phase0.py` and `capture_upstream.py` scripts.

### Sources

Five fixed sources hardcoded in the script:

1. `synthetic:ghost_box_disappear`
2. `synthetic:ghost_box_moving`
3. `birdseye-320x240.mp4`
4. `people-320x240.mp4`
5. `intersection-320x240.mp4`

### Init modes

For each source, run three init modes:

- `init_frame0` — `vibe.init_from_frame(frames[0])` (current behaviour, baseline).
- `init_lookahead_n20` — `vibe.init_from_frames(frames, lookahead_n=20)`.
- `init_lookahead_full` — `vibe.init_from_frames(frames, lookahead_n=None)`.

### Per-run procedure

1. Load all frames as Y (existing `frame_io` / `video_source` helpers); convert to `(N, H, W)` uint8.
2. Construct three fresh `ViBe` instances with identical params and identical `prng_seed`.
3. Call the appropriate init method on each.
4. Run `process_frame` on **all** frames `0..end`; collect masks and per-frame coverage (`mask.mean()`).
5. Emit per-source artifacts under `py/experiments/our_outputs/lookahead_init/<source>/`:
   - `coverage.png` — three curves (one per init mode) over frame index.
   - `grid.png` — input frames row + one mask row per init mode (using the existing `viz/render.py`-style grid).

### Fixed ViBe params

Phase-0-validated defaults: `K=20, R=20, min_match=2, phi_update=16, phi_diffuse=16, init_scheme="c", coupled_rolls=True, prng_seed=0xDEADBEEF`. No sweep over these — this experiment is *only* about init mode.

### Outputs

Generated artifacts are gitignored and regenerable. A short results table goes into a hand-written results doc after the run:
`docs/plans/2026-05-05-vibe-lookahead-init-results.md`.

### Runtime estimate

ViBe on 320×240 ≈ ~1 fps in pure Python (from Phase-0 timings). Five sources × ~150 frames × three init modes ≈ ~37 minutes total. Acceptable for a one-shot experiment; no optimisation needed.

### Follow-up validation (gated on positive headline results)

The headline run measures **raw** ViBe output to cleanly attribute mask-quality changes to the init mode. If the headline shows a clear win for one of the look-ahead modes, a second smaller run validates that the win survives the production motion pipeline's pre/post-processing:

- **Sources:** the three real-demo clips only (`birdseye`, `people`, `intersection`). Synthetic ghost sources are not included — they exist to exercise ViBe internals, and the morph open stage would erase the ghost fragments anyway, confounding the read.
- **Init modes:** the canonical baseline (`init_frame0`) and the **winning** look-ahead mode from the headline run (one of `init_lookahead_n20`, `init_lookahead_full`). Two modes, not three.
- **Pipeline:** gauss3×3 pre-filter → ViBe `process_frame` → `morph_open` → `morph_close` (the `default` profile config: `gauss_en=True, morph_open_en=True, morph_close_en=True, morph_close_kernel=3`). The pre/post helpers are imported from `py/models/motion.py` (`_gauss3x3`) and `py/models/ops/morph_open.py` / `morph_close.py`.
- **Outputs:** `py/experiments/our_outputs/lookahead_init_pipeline/<source>/{coverage.png, grid.png}` — same format as the headline run, two rows per grid instead of three.
- **Gate:** this run executes only if the headline results show one of the look-ahead modes is clearly preferred. If the headline is negative or inconclusive, the follow-up is skipped and the spec does not promote.

This keeps the headline experiment apples-to-apples with Phase-0 while giving a sanity-check on whether the init-mode improvement holds end-to-end. The follow-up is gated, not unconditional, because if raw ViBe shows no benefit from look-ahead init, running it through morph_clean cannot create one.

## 5. Tests

Two new tests in [`py/tests/test_motion_vibe.py`](../../py/tests/test_motion_vibe.py), extending the existing 33-test file. No new test file.

1. **`test_init_from_frames_single_frame_matches_init_from_frame`** — given a `(1, H, W)` stack, `init_from_frames(frames, lookahead_n=1)` produces a `samples` array bit-identical to `init_from_frame(frames[0])` after both run with the same `prng_seed` and `init_scheme="c"`. Locks the dispatch contract: when N=1, the median collapses to the single frame, so the two paths must agree.

2. **`test_init_from_frames_median_equivalence`** — given an arbitrary `(N, H, W)` stack, `init_from_frames(frames, lookahead_n=N)` produces a `samples` array bit-identical to `init_from_frame(np.median(frames, axis=0).astype(np.uint8))`. Locks the algorithmic contract: the new method is a thin wrapper that changes the center value before dispatching to the configured init scheme.

These two tests catch any drift in the wrapper logic. The underlying init scheme is already covered by the existing 33 tests.

### Validation argument

There is no automated pass/fail gate. The experiment's pass/fail is read by hand from the coverage curves and the visual grid; there is no numerical budget like the Phase-0 `±0.01` cross-check, because there is no upstream-impl baseline for "look-ahead median ViBe init" to compare against.

## 6. Deliverables & file layout

### New files

- `py/experiments/run_lookahead_init.py` — the experiment script (§4).
- `docs/plans/2026-05-05-vibe-lookahead-init-results.md` — the results doc, written by hand after the experiment runs. Mirrors the format of [`2026-05-04-vibe-phase-0-results.md`](2026-05-04-vibe-phase-0-results.md): per-source coverage table, grid pointers, takeaway, recommendation on promotion.

### Modified files

- [`py/experiments/motion_vibe.py`](../../py/experiments/motion_vibe.py) — adds `init_from_frames` method (§3).
- [`py/tests/test_motion_vibe.py`](../../py/tests/test_motion_vibe.py) — adds two tests (§5).
- *(Conditional on positive results)* [`docs/plans/2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md) — add `bg_init_mode` / `bg_init_lookahead_n` to the Phase-1+ control-knob list, citing the results doc. If results are inconclusive or negative, the parent design doc gets a brief note pointing to the results doc and explaining why this knob is not adopted.

### Generated (gitignored)

`py/experiments/our_outputs/lookahead_init/<source>/{coverage.png, grid.png}` for the five headline sources.

*(Conditional on positive headline results)* `py/experiments/our_outputs/lookahead_init_pipeline/<source>/{coverage.png, grid.png}` for the three real-clip follow-up sources.

### Branch

New branch `feat/vibe-lookahead-init` per the one-branch-per-plan rule in [`CLAUDE.md`](../../CLAUDE.md). Because this plan modifies `py/experiments/motion_vibe.py` and `py/tests/test_motion_vibe.py` — both Phase-0 deliverables that live on the unmerged predecessor branch `feat/vibe-motion-design` — the new branch is created **from `feat/vibe-motion-design`**, not from `origin/main`. CLAUDE.md explicitly allows this: *"If a new plan genuinely depends on an unmerged predecessor branch, create the new branch from that predecessor … and note the dependency in the PR description."* The dependency will be noted in the eventual PR.

### Out of scope

- RTL changes, `motion_core_vibe` updates, `cfg_t` field additions in `sparevideo_pkg.sv`.
- Scheme-(a) / scheme-(b) variants of look-ahead init in the headline grid (they are dispatched by the API but not exercised in the experiment).
- Sweeps over `lookahead_n` other than `{20, full}`.
- Sweeps over K, R, φ_update, φ_diffuse, coupled_rolls.

## 7. Implementation tasks (ordered)

1. Add `init_from_frames` method to `py/experiments/motion_vibe.py` (§3).
2. Add the two unit tests to `py/tests/test_motion_vibe.py` (§5); confirm both pass.
3. Write `py/experiments/run_lookahead_init.py` (§4 headline run).
4. Run the headline experiment end-to-end; inspect generated `coverage.png` and `grid.png` files.
5. **If headline results show a clear winner among the look-ahead modes:** write `py/experiments/run_lookahead_init_pipeline.py` (§4 follow-up validation), run it on the three real clips through the production pipeline (gauss → ViBe → morph_open → morph_close), inspect outputs.
6. Hand-write `docs/plans/2026-05-05-vibe-lookahead-init-results.md` summarising findings: per-source coverage table for the headline run, follow-up pipeline-validation table if applicable, takeaway, promotion recommendation.
7. **Conditional on positive results (headline win + follow-up holds):** update [`docs/plans/2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md) to add `bg_init_mode` and `bg_init_lookahead_n` as Phase-1+ control knobs, citing the results doc. If results are negative or inconclusive, instead add a brief note pointing to the results doc and explaining why this knob is not adopted.
