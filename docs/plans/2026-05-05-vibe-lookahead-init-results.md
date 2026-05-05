# ViBe Look-Ahead Median Init — Results

**Date:** 2026-05-05
**Branch:** feat/vibe-lookahead-init
**Companion plan:** [`2026-05-05-vibe-lookahead-init-plan.md`](2026-05-05-vibe-lookahead-init-plan.md)
**Companion design doc:** [`2026-05-05-vibe-lookahead-init-design.md`](2026-05-05-vibe-lookahead-init-design.md)

## Decision

**PASS** — `init_lookahead_full` (per-pixel temporal median over the entire clip) is a clear win on every source and survives the production motion pipeline. Recommend promoting to a `cfg_t.bg_init_mode` knob in the Phase-1+ ViBe design doc.

## Headline experiment — raw ViBe, three init modes

ViBe params: K=20, R=20, min_match=2, φ_update=16, φ_diffuse=16, init_scheme=c, coupled_rolls=True, prng_seed=0xDEADBEEF. 200 frames per source.

| Source | init_frame0 avg | init_lookahead_n20 avg | init_lookahead_full avg |
|---|---|---|---|
| synthetic:ghost_box_disappear | 0.0584 | 0.0003 | 0.0003 |
| synthetic:ghost_box_moving | 0.1225 | 0.0544 | 0.0307 |
| media/source/birdseye-320x240.mp4 | 0.0503 | 0.0453 | 0.0371 |
| media/source/people-320x240.mp4 | 0.1196 | 0.1155 | 0.0855 |
| media/source/intersection-320x240.mp4 | 0.0883 | 0.0771 | 0.0581 |

Max-coverage context (peak per-frame coverage over the 200-frame window):

| Source | frame0 max | n20 max | full max |
|---|---|---|---|
| ghost_box_disappear | 0.0625 | 0.0625 | 0.0625 |
| ghost_box_moving | 0.1250 | 0.1248 | 0.1247 |
| birdseye | 0.0655 | 0.0602 | 0.0436 |
| people | 0.1452 | 0.1462 | 0.0993 |
| intersection | 0.1762 | 0.1574 | 0.1481 |

Reductions vs `init_frame0` (avg coverage):

| Source | N=20 | full |
|---|---|---|
| ghost_box_disappear | −99.5% | −99.5% |
| ghost_box_moving | −55.6% | −74.9% |
| birdseye | −9.9% | −26.2% |
| people | −3.4% | −28.5% |
| intersection | −12.7% | −34.2% |

**Takeaway.** Both look-ahead modes essentially eliminate the synthetic frame-0 ghost on `ghost_box_disappear` (0.0584 → 0.0003, ~200× reduction) — exactly as predicted by the design doc since at any pixel the bg color dominates the temporal median. `init_lookahead_full` is the unambiguous winner on every source, with avg-coverage reductions of 26–34% on real clips and 75–99% on synthetic ghost sources. `init_lookahead_n20` is positive but marginal on real clips, especially `people` (only −3.4%) — likely because slow-moving foreground (walking pedestrians) occupies any given pixel for >20 frames, so the N=20 temporal median still has foreground contamination. No inverse-ghost regression is visible in the headline coverage curves on any source.

**Visual evidence.** Per-source coverage curves and side-by-side mask grids under `py/experiments/our_outputs/lookahead_init/<source>/{coverage.png, grid.png}`. The synthetic ghost sources show the canonical-baseline ghost as a visible non-zero plateau on row 1 (`init_frame0`), with rows 2–3 (`init_lookahead_n20`, `init_lookahead_full`) flat near zero. Real clips show modest curve-level reductions consistent with the table.

## Pipeline follow-up — full motion pipeline, two init modes

Validation that the headline win survives `gauss3x3 → ViBe → morph_open → morph_close (kernel=3)` (matching `CFG_DEFAULT`). Three real demo clips × `init_frame0` baseline + `init_lookahead_full` (the headline winner). Same ViBe params as the headline run.

| Source | init_frame0 avg | init_lookahead_full avg |
|---|---|---|
| media/source/birdseye-320x240.mp4 | 0.0333 (max 0.0494) | 0.0261 (max 0.0334) |
| media/source/people-320x240.mp4 | 0.1124 (max 0.1421) | 0.0858 (max 0.1018) |
| media/source/intersection-320x240.mp4 | 0.0774 (max 0.1699) | 0.0525 (max 0.1456) |

Reductions vs `init_frame0` (post-pipeline):

| Source | post-pipeline | (raw-ViBe headline for context) |
|---|---|---|
| birdseye | −22% | −26% |
| people | −24% | −29% |
| intersection | −32% | −34% |

**Takeaway.** Post-pipeline avg coverages are systematically lower than raw because `morph_open` removes single-pixel salt noise that contributes to the raw-ViBe coverage. The relative win compresses slightly (~−22 to −32% post-pipeline vs ~−26 to −34% raw) but is unambiguous on every source — the look-ahead-init contribution is **not** subsumed by `morph_clean`, which is the key risk this follow-up was designed to rule out.

## Recommendation

**Promote.** Add `bg_init_mode: "frame0" | "lookahead_median"` and `bg_init_lookahead_n: int | None` (sentinel `None` meaning "all available frames") to the Phase-1+ control-knob list in [`2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md). Default value: `bg_init_mode = "lookahead_median"` with `bg_init_lookahead_n = None` (the `init_lookahead_full` mode that won the headline run).

For RTL implementation: this requires a startup-buffer of `bg_init_lookahead_n` frames (or full-clip if `None`) of frame storage and a streaming-median compute, before normal `process_frame` operation can begin. Latency: `bg_init_lookahead_n` frames of inactivity at startup, after which the bank is seeded with high-quality bg estimates for every pixel that was visible at any point in the buffer.

## Caveats / open questions

1. **Inverse-ghost edge case (§2 of design doc).** A pixel under foreground for >50% of the look-ahead window will have its median collapse to a foreground value, producing an *inverse* ghost (the true bg appears as motion when the object eventually moves away). For `ghost_box_moving` under `lookahead_full`, the moving box passes through each pixel for only a fraction of the 200 frames, so no inverse-ghost is visible. For real clips with slow-moving subjects (e.g., `people`), the moving subject's per-pixel time fraction is below 50% and no inverse-ghost manifests. Worth flagging that this could appear on clips with extremely slow / nearly-stationary moving objects where one pixel is occupied >50% of the window.

2. **Why `init_lookahead_n20` underperformed on `people`.** N=20 frames is ~0.7s at 30 fps; people walking through the scene occupy the same pixel longer than that, so the N=20 median still has foreground-pixel contamination. The full-clip mode wins precisely because over ~6.7s (200 frames) the same pixel gets enough bg observation to dominate the median. Practical implication: for real-time RTL deployment, `bg_init_lookahead_n` should be sized for the slowest-moving expected foreground at the target frame rate (rule of thumb: > 2× time-to-cross-one-pixel).

3. **Promotion does not change ViBe defaults retroactively.** Existing Phase-0 verification continues to use `init_from_frame` (canonical Barnich init) so all 36 unit tests + 200-frame upstream cross-check still pass at TOLERANCE=0. The new mode is opt-in via `cfg_t.bg_init_mode`.

## Embedded artifacts (gitignored, regenerable)

- `py/experiments/our_outputs/lookahead_init/<source>/{grid,coverage}.png` — five sources × three init modes (headline run).
- `py/experiments/our_outputs/lookahead_init_pipeline/<source>/{grid,coverage}.png` — three real clips × two init modes (pipeline follow-up).

Regenerate end-to-end:

```bash
source .venv/bin/activate
python py/experiments/run_lookahead_init.py
python py/experiments/run_lookahead_init_pipeline.py  # only after headline winner is identified; edit WINNING_MODE if needed
```
