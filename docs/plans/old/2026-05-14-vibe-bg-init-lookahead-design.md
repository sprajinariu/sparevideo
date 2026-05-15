# ViBe BG Init — Look-Ahead Beyond Median — Design

**Date:** 2026-05-14
**Owner:** sprajinariu
**Status:** Design (pre-implementation)
**Related:**
- Prior look-ahead init (current production baseline): [`docs/plans/old/2026-05-05-vibe-lookahead-init-design.md`](old/2026-05-05-vibe-lookahead-init-design.md), [`...-plan.md`](old/2026-05-05-vibe-lookahead-init-plan.md), [`...-results.md`](2026-05-05-vibe-lookahead-init-results.md)
- ViBe demote (runtime control method): [`docs/plans/old/2026-05-12-vibe-demote-python-design.md`](old/2026-05-12-vibe-demote-python-design.md), [`...-plan.md`](old/2026-05-12-vibe-demote-python-plan.md), [`...-results.md`](2026-05-12-vibe-demote-python-results.md)

## 1. Motivation

The current ViBe production init (`bg_init_mode = "lookahead_median"`, `n = None` — a per-pixel temporal median over all frames of the clip, seeded via `init_scheme=c`) is biased on high-traffic regions. The `2026-05-05-vibe-lookahead-init-results.md` doc already flagged the failure mode in §"Caveats / open questions":

> A pixel under foreground for >50% of the look-ahead window will have its median collapse to a foreground value, producing an *inverse* ghost.

For short clips (5–10 s ≈ 150–300 frames @ 30 fps) this matters: clips like `people-320x240.mp4` have slow-moving subjects that occupy individual pixels for a substantial fraction of the look-ahead window, biasing the median toward foreground colors. The downstream consequence is a seeded bank where high-traffic pixels carry FG-tinted BG estimates, which ViBe then has to "unlearn" during runtime — exactly the ghost-clearing latency we cannot afford in 5–10 s clips.

The current runtime mitigation, `vibe_demote` (persistence-based FG→BG demotion), partially addresses this at the cost of a hollowing failure mode on slow real subjects (see iteration-2 notes in the demote results doc).

This design proposes three alternative look-ahead BG init schemes that should be more robust than the plain temporal median against high-traffic bias.

## 2. Goal & Non-goals

**Goal.** Implement three new look-ahead BG init schemes in [`py/models/ops/vibe.py`](../../py/models/ops/vibe.py), benchmark them against the current `lookahead_median` baseline (and `vibe_demote` as a runtime control) on the standard source set, and promote whichever wins as the new default for `bg_init_mode`. Keep the others selectable.

**Non-goals.**
- No RTL work in this plan. The chosen winner is pre-computed in Python and pre-loaded into the bank via the existing external-init hook — no streaming-init compute, no startup-frame buffer in hardware.
- No changes to ViBe runtime (`process_frame`), `vibe_demote`, or any other downstream block.
- No new PRNG or seeding work. All three new schemes reuse the existing `_init_scheme_c` slot-seeding (just produce a different `bg_est` image to feed it).
- No new sources, no new evaluation metrics. The standard source set and metrics from the existing experiment harness are reused as-is.

## 3. Candidate init modes

All three are pure-numpy batch helpers that consume the full `(N, H, W)` uint8 stack of look-ahead frames and produce a `(H, W)` uint8 `bg_est`, which is then routed through `init_scheme=c` (same noise/PRNG path as today).

### (A) IMRM — Iterative motion-rejected median

Compute `M0 = median(frames, axis=0)`. Per pixel, mark frames where `|I_t − M0| > τ` as outliers; recompute median over inliers only → `M1`. Iterate. If at any pixel all frames are flagged outliers (degenerate case), fall back to `M0` at that pixel.

- **Mechanism.** Rejects FG samples by value-deviation from the current BG estimate; the median is iteratively pulled toward the dominant inlier cluster.
- **Fixes.** The "FG color dominates median" case as long as the inlier cluster ends up being BG.
- **Default knobs (pre-sweep):** `τ = 20` (matches ViBe's `R`), `iters = 3`.
- **Lit anchor.** Haritaoglu et al. *W4* (PAMI 2000) uses temporal-median + range filtering; iterated-reweighted variants are standard in robust statistics.

### (B) MVTW — Per-pixel min-variance temporal window

For each pixel, slide a `K`-frame window across time, compute variance per window, pick the window with minimum variance, return that window's mean as `bg_est` at that pixel. Implementation uses `np.lib.stride_tricks.sliding_window_view` to stay vectorized.

- **Mechanism.** Finds the temporal segment where the pixel is most stable — assumes BG appearance is locally stationary while FG passing through creates a high-variance interval.
- **Fixes.** The case where FG covers >50% of the clip but the pixel is briefly clear at some moment.
- **Default knob (pre-sweep):** `K = 24` (~0.8 s @ 30 fps — long enough to be statistically stable, short enough that a typical real clip has at least one fully-clear window for most pixels).
- **Edge case.** If `N < K` (clip shorter than the window), fall back to plain median on the full stack.
- **Lit anchor.** Temporal-stability / temporal-mode bootstrapping is discussed in Stauffer-Grimson (CVPR 1999) and motivated in Elgammal et al. KDE-BG (ECCV 2000) as a robustness justification.

### (C) MAM — Motion-aware median (frame-diff outlier rejection)

Two-pass:
1. **Motion pass.** Compute `|I_t − I_{t-1}| > δ` for `t ∈ [1, N)` → per-pixel binary motion mask of shape `(N-1, H, W)`. Pad by one frame at `t=0` (treat as motion, conservative). Dilate temporally by `dilate` frames in both directions (so a motion event "shadows" `dilate` frames on either side, capturing entry/exit transitions where the pixel still shows FG but the inter-frame delta is small).
2. **Median pass.** Per pixel, take median over the timestamps NOT flagged in the motion mask. Pixels with zero non-motion timestamps fall back to plain median.

- **Mechanism.** Rejects FG by *temporal signal* (motion) instead of *value deviation* from a median — useful when FG color is close to BG color but the FG is dynamic.
- **Fixes.** Slow-moving FG that doesn't deviate enough in value to be rejected by IMRM, but does change frame-to-frame.
- **Default knobs (pre-sweep):** `δ = 8` (sensitive enough to catch slow walkers), `dilate = 2`.
- **Lit anchor.** Frame-differencing bootstrap is the textbook init for codebook (Kim et al. 2005) and many GMM variants.

## 4. Architecture

### 4.1 Code organization in `vibe.py`

```python
def init_from_frames(
    self,
    frames: np.ndarray,                # (N, H, W) uint8
    lookahead_n: Optional[int] = None,
    mode: str = "median",              # "median" | "imrm" | "mvtw" | "mam"
    imrm_tau: int = 20,
    imrm_iters: int = 3,
    mvtw_k: int = 24,
    mam_delta: int = 8,
    mam_dilate: int = 2,
) -> None: ...
```

Mode dispatch is a switch inside `init_from_frames`. Each non-median mode is a private function:

- `_bg_imrm(frames, tau, iters) -> np.ndarray`
- `_bg_mvtw(frames, k) -> np.ndarray`
- `_bg_mam(frames, delta, dilate) -> np.ndarray`

All return a `(H, W)` uint8 `bg_est`. The existing `init_from_frame(bg_est)` is then called to seed the bank — unchanged PRNG and noise structure across modes, so only the `bg_est` image differs between modes.

### 4.2 `cfg_t` and profile plumbing

Add to `cfg_t` in [`hw/top/sparevideo_pkg.sv`](../../hw/top/sparevideo_pkg.sv) and the Python mirror in [`py/profiles.py`](../../py/profiles.py):

- `bg_init_mode: str` — `"median" | "imrm" | "mvtw" | "mam"`. Default `"median"` (no behavior change until promotion).
- `bg_init_imrm_tau: int`, `bg_init_imrm_iters: int`
- `bg_init_mvtw_k: int`
- `bg_init_mam_delta: int`, `bg_init_mam_dilate: int`

The existing `test_profiles.py` parity test will catch any drift between the SV package and the Python mirror, so no additional parity-test wiring is needed. The SV-side fields are declared for future RTL consumption; this plan's RTL path is "pre-loaded BG bank, no compute" so the fields are effectively ignored by RTL today.

### 4.3 Evaluation harness

New experiment script: `py/experiments/bg_init_compare/run.py`. Same shape as the existing `lookahead_init` and `vibe_demote` experiment runners.

- **Sources (5):** `birdseye-320x240.mp4`, `intersection-320x240.mp4`, `people-320x240.mp4`, `synthetic:ghost_box_disappear`, `synthetic:ghost_box_moving`.
- **Methods (5):** `lookahead_median` (baseline), `imrm`, `mvtw`, `mam`, `vibe_demote` (control; init = `lookahead_median`, demote_thresh=3, K_persist=30 — the production config).
- **ViBe params (fixed across methods):** `K=20, R=20, min_match=2, φ_update=16, φ_diffuse=16, init_scheme=c, coupled_rolls=True, prng_seed=0xDEADBEEF`. 200 frames per source.
- **Output artifacts** (under `py/experiments/our_outputs/bg_init_compare/<source>/`):
  - `coverage.png` — per-frame coverage curve, one line per method.
  - `grid.{png,webp}` — side-by-side mask grid for visual inspection.
  - `summary.md` (top-level) — avg-coverage, high-traffic-asymptote, hollow-fraction tables.

### 4.4 Knob sweep (pre-headline)

Each new mode runs a small one-knob sweep on `people-320x240.mp4` (the toughest case) before the headline 5×5 comparison:

- IMRM: `τ ∈ {12, 20, 32}` at `iters = 3`.
- MVTW: `K ∈ {12, 24, 60}`.
- MAM: `δ ∈ {6, 12}` at `dilate = 2`.

The best knob per mode (lowest high-traffic asymptote without hollow-fraction regression vs `lookahead_median`) is locked in as that mode's default and used in the headline 5×5. Sweep artifacts go to `py/experiments/our_outputs/bg_init_compare/_sweep/`.

## 5. Testing

New test file [`py/tests/test_vibe_init_modes.py`](../../py/tests/test_vibe_init_modes.py):

1. **`test_init_modes_dispatch`** — calling `init_from_frames(mode=m)` for each `m ∈ {"median", "imrm", "mvtw", "mam"}` runs to completion on a tiny synthetic stack and produces a bank of the expected shape/dtype.
2. **`test_init_modes_deterministic`** — same `frames`, same `prng_seed`, same `mode` → byte-identical bank.
3. **`test_imrm_recovers_bg_under_high_traffic`** — synthetic 100-frame stack: BG = constant 80, FG = constant 200 covering one pixel for 70/100 frames. Assert `_bg_imrm` recovers BG=80 (within ±2) at that pixel, and that plain `np.median` would return ≥150 (sanity contrast).
4. **`test_mvtw_recovers_bg_when_briefly_clear`** — 100-frame stack: BG=80, FG=200 covering one pixel for frames 0–79, clear for frames 80–99. Assert `_bg_mvtw(K=20)` recovers BG=80 (within ±2) — plain median would return ≥150.
5. **`test_mam_rejects_motion_frames`** — 100-frame stack with low-contrast FG drifting through a pixel (FG=90, BG=80; |FG−BG|=10, below IMRM's `τ=20`). FG moves frame-to-frame so the diff signal is strong. Assert `_bg_mam` recovers BG=80, IMRM would not.

No `cfg_t` parity test changes beyond adding fields to [`py/profiles.py`](../../py/profiles.py) — the existing `test_profiles.py` auto-catches drift.

## 6. Deliverables

- [`py/models/ops/vibe.py`](../../py/models/ops/vibe.py) — extend `init_from_frames` with mode dispatch + three private helpers.
- [`hw/top/sparevideo_pkg.sv`](../../hw/top/sparevideo_pkg.sv) + [`py/profiles.py`](../../py/profiles.py) — add `bg_init_mode` and per-mode knob fields to `cfg_t`.
- [`py/tests/test_vibe_init_modes.py`](../../py/tests/test_vibe_init_modes.py) — five unit tests above.
- `py/experiments/bg_init_compare/run.py` — knob-sweep + 5×5 headline experiment.
- `docs/plans/2026-05-14-vibe-bg-init-lookahead-results.md` — written at the end of the implementation plan, with the headline tables, decision, and (if applicable) the profile-default flip.

## 7. GO criteria for promoting a winner to default `bg_init_mode`

Following the framework established by the `vibe_demote` results doc:

- **Must:** dominate `lookahead_median` on the high-traffic-region asymptote on all three real clips (`birdseye`, `intersection`, `people`).
- **Must not:** regress the synthetic ghost asymptote on `ghost_box_disappear` or `ghost_box_moving` by more than 0.001 absolute vs `lookahead_median`.
- **Tiebreaker:** if multiple modes pass both, prefer the lowest hollow-fraction (mask-shape quality).
- **Bonus context (non-blocking).** Compare the winning init's high-traffic asymptote against `vibe_demote`. If the new init matches or beats `vibe_demote` while preserving full FG bodies (no hollowing), that is the cleanest possible promotion narrative — the new init obsoletes the demote runtime mechanism for the high-traffic case.

If no mode passes the must-criteria, the results doc records the experiment, recommends `lookahead_median` stay default, and notes whether any mode is at least non-regressive and worth keeping as a selectable option for future revisits.

## 8. Risks / open questions

- **Knob over-fit.** The sweep is run on `people` only, then locked in for the headline. If a knob value that's optimal for `people` is poor on `birdseye` or `intersection`, the headline numbers will reflect that — and is the correct outcome (we want one set of defaults that generalizes, not per-source tuning). Worst case: results doc recommends per-source knobs, which we decline to ship and instead pick the most robust global knob.
- **MAM degenerate pixels.** A pixel that is *always* in motion across the entire clip (e.g. a swaying tree branch under wind) has zero non-motion frames and falls back to plain median. This is intentional — those pixels are "true high-variance BG" and the median is at least not worse than the baseline. Will be visible in the mask grid if present.
- **MVTW window-size sensitivity.** `K = 24` assumes ~30 fps. If a source has a substantially different frame rate, the knob meaning shifts. All standard sources are normalized to 30 fps in the harness, so this is bounded. Documented for future work on variable-fps sources.
- **Compute cost at init.** `MVTW` is the heaviest of the three (sliding-window variance per pixel) but still trivial on 200×320×240×3 stacks (<1 s on a laptop). No optimization needed.
