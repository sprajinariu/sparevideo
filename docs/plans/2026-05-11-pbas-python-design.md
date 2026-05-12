# PBAS Python reference and empirical comparison — design

**Date:** 2026-05-11
**Status:** Design (pre-implementation)
**Branch:** `feat/pbas-python` (off `origin/main`)
**Background:** [`2026-05-11-vibe-ghost-rescue-addendum.md`](2026-05-11-vibe-ghost-rescue-addendum.md) (lessons + literature re-verification that motivate PBAS as the next step)

## 1. Motivation

Phase A's empirical results showed that the project's current `vibe_init_external`
(look-ahead-median ROM pre-pass) remains the best frame-0 ghost mitigation, but
that no fully-online published mechanism rescues high-contrast ghost interiors
directly — every literature-grounded online technique relies on outside-in
dissolution. PBAS (Hofmann, Tiefenbacher & Rigoll, CVPRW 2012) is the canonical
extension of ViBe with adaptive per-pixel feedback that **accelerates** the
outside-in dissolution by ~8× at maximum tuning vs canonical ViBe.

This sub-project builds a Python PBAS reference, faithful to the published
reference implementation, and runs an empirical comparison against the existing
ViBe-based pipeline on the project's real-clip sources (birdseye, people). If
the experiment shows PBAS materially improves over `vibe_init_external` on real
clips, a follow-up plan will move it into RTL.

## 2. Scope

**In scope.**
- New Python operator `py/models/ops/pbas.py` — PBAS class faithful to the
  [andrewssobral PBAS.cpp reference impl](https://github.com/andrewssobral/simple_vehicle_counting/blob/master/package_bgs/PBAS/PBAS.cpp),
  **Y + gradient feature variant** (matching the published PBAS configuration).
- New adapter `py/models/_pbas_mask.py` — `produce_masks_pbas(...)` parallel to
  `produce_masks_vibe(...)`.
- New `cfg_t` field `bg_model = BG_MODEL_PBAS (value 2)` and Python profile
  mirroring.
- Two PBAS profiles:
  - `pbas_default` — PBAS's published init (first N frames as bank slots).
  - `pbas_lookahead` — bank seeded from lookahead-median (project's init), then
    PBAS-style updates.
- A Python comparison runner producing per-source coverage curves +
  convergence tables.
- Labelled animated WebPs for `birdseye` and `people`, side-by-side comparison
  of four methods (see §7).
- Unit tests verifying determinism, R/T-bound enforcement, gradient feature
  contribution, and equivalence-to-ViBe in a degenerate parameter regime (R
  fixed, T fixed, alpha=0 → behaves like ViBe with N=20).

**Out of scope.**
- RGB-per-channel feature storage (always single-channel Y in this iteration).
- RTL implementation, top-level integration into the RTL pipeline.
- New ctrl_flow modules (`motion_pbas.py` / `mask_pbas.py` / `ccl_bbox_pbas.py`).
  This sub-project's comparison is at the mask level only; integration into
  the full pipeline can come in a follow-up plan if results justify.
- ViBe ghost-rescue cleanup (separate work on `docs/vibe-ghost-rescue`
  branch, per the addendum).

## 3. Algorithm — Y + gradient PBAS

### 3.1 Per-pixel feature vector

Each "sample" in the bank is a pair `(intensity, gradient_magnitude)`. The
current pixel is converted to the same pair before matching:

```
y[r,c]    = frame[r,c]                                 # uint8
gx[r,c]   = sobel_x_3x3(frame)[r,c]                    # signed
gy[r,c]   = sobel_y_3x3(frame)[r,c]                    # signed
g[r,c]    = clip(hypot(gx, gy), 0, 255).astype(uint8)  # uint8 magnitude
```

Sobel runs once per frame on the (optionally gauss-filtered, per the existing
`gauss_en` profile knob) Y frame. The gradient magnitude is quantised to
uint8 to match the bank-slot storage width. (The reference C++ impl stores
gradient as float, but quantising to uint8 is sufficient for our parameter
range and matches what the RTL follow-up will use.)

### 3.2 Per-pixel state

| State | Type | Init | Role |
|---|---|---|---|
| `samples_y[r,c,k]` | uint8, k=0..N-1 | first N frames' intensities | bank of historic intensity samples |
| `samples_g[r,c,k]` | uint8, k=0..N-1 | first N frames' gradient magnitudes | bank of historic gradient magnitudes |
| `R(r,c)` | float32 | `R_lower` | adaptive matching radius |
| `T(r,c)` | float32 | `R_lower` | adaptive update-rate denominator |
| `meanMinDist(r,c)` | float32 | 0 | running mean of per-frame minimum sample distance |

### 3.3 Per-frame scalar state (NOT per-pixel)

| State | Type | Init | Role |
|---|---|---|---|
| `formerMeanMag` | float32 | 20.0 | running estimate of mean gradient magnitude across the frame; used as the normalising denominator in the gradient-distance term. Updated at end-of-frame: `formerMeanMag = max(mean(g over fg pixels), 20)`. |

### 3.4 Distance function

For pixel `(r,c)` against bank slot `k`:

```
d_intensity = |y[r,c] - samples_y[r,c,k]|         # uint8 diff
d_gradient  = |g[r,c] - samples_g[r,c,k]|         # uint8 diff
distance    = (alpha * d_gradient) / formerMeanMag + beta * d_intensity
```

The gradient term is normalised by `formerMeanMag` so that scenes with weak
texture (mostly-flat) don't have the gradient term collapse to zero, and
scenes with strong texture don't have it dominate. This is the same scaling
the reference impl uses.

### 3.5 Verified parameters (from PBAS.cpp constructor)

| Constant | Value | Role |
|---|---|---|
| `N` | 20 | bank size |
| `Raute_min` | 2 | min-match threshold (ViBe's `min_match` equivalent) |
| `R_lower` | 18 | lower bound on `R(x)` |
| `R_scale` | 5 | `R(x)` adapts toward `meanMinDist × R_scale` |
| `R_incdec` | 0.05 | multiplicative ±5% per-frame on `R(x)` |
| `T_lower` | 2 | lower bound on `T(x)` |
| `T_upper` | 200 | upper bound on `T(x)` |
| `T_init` | 18 (= `R_lower`) | initial `T(x)` |
| `T_inc` | 1 | bg-side change scaling: `T -= T_inc / (meanMinDist+1)` |
| `T_dec` | 0.05 | fg-side change scaling: `T += T_dec / (meanMinDist+1)` |
| **`alpha`** | **7** | **gradient-term weight in distance** |
| **`beta`** | **1** | **intensity-term weight in distance** |
| **`formerMeanMag_min`** | **20.0** | **floor for the per-frame magnitude normaliser** |

(`T_inc`/`T_dec` naming preserved from the reference impl. Note: `T_inc` is
used on the BG side as a *decrement* to T; `T_dec` is used on the FG side as
an *increment*. Counter-intuitive but kept for code-comparison clarity.)

### 3.6 Per-pixel per-frame procedure

Pre-step (frame-wide): compute Sobel `g` for the whole frame.

For each pixel `(r,c)`:

1. **Matching.** Loop over bank slots; count slots whose **per §3.4 distance** is `< R(r,c)` (early-exit when count reaches `Raute_min`). Track `minDist = min_k distance_k`.
2. **Classification.** If `count >= Raute_min` → bg. Else → fg.
3. **`meanMinDist` update.** Running mean with weight `1/N`:
   `meanMinDist[r,c] = ((N-1) * meanMinDist[r,c] + minDist) / N`.
4. **Bank update (BG only).** Compute `ratio = ceil(T_upper / T(r,c))`. With probability `ratio / T_upper`:
   - Own bank: pick random slot `k`, set `samples_y[r,c,k] = y[r,c]` AND `samples_g[r,c,k] = g[r,c]`.
   - Neighbor bank: pick random 3×3 neighbor `(r',c')` (clipped to image), pick random slot `k'`, set `samples_y[r',c',k'] = y[r,c]` AND `samples_g[r',c',k'] = g[r,c]`. (Note: the neighbor receives the **current pixel's** y/g, not its own — matches reference impl behaviour.)
5. **`R` regulator.** If `R(r,c) > meanMinDist[r,c] × R_scale`, then `R *= (1 - R_incdec)`. Else `R *= (1 + R_incdec)`. Clamp to `R >= R_lower`.
6. **`T` regulator.** If BG: `T -= T_inc / (meanMinDist+1)`. If FG: `T += T_dec / (meanMinDist+1)`. Clamp to `[T_lower, T_upper]`.

Post-frame: `formerMeanMag = max(mean(g) over fg pixels, formerMeanMag_min=20)` for next frame's distance computations. (If no fg pixels this frame, `formerMeanMag = formerMeanMag_min`.)

### 3.7 Initialisation modes

- **`pbas_default`.** First `N=20` frames are pushed onto the bank, one slot per frame — both `samples_y[r,c,k]` and `samples_g[r,c,k]` for `k=0..N-1` are populated. No matching / classification occurs during init. Frame 0..19 emit all-zero masks. From frame 20 onward, normal processing per §3.6. `formerMeanMag` is also populated during init by averaging gradients of the init frames.
- **`pbas_lookahead`.** Per-pixel temporal median over the entire input clip seeds `samples_y` slots; `samples_g` slots are seeded from the gradient magnitude of the median frame (single value replicated across all N slots). From frame 0 onward, normal PBAS processing. `formerMeanMag` is initialised from the mean gradient magnitude of the median frame. (PBAS state — `R, T, meanMinDist` — initialised at their default values regardless of init mode.)

### 3.8 Determinism

The reference impl uses a precomputed table of 1000 random ints per draw category (`randomT`, `randomTN`, `randomN`, `randomX`, `randomY`, `randomMinDist`) and indexes by a counter. We mirror this in Python using NumPy `default_rng(seed)` to generate the same fixed-length tables at construction time. Same seed → same masks, exactly.

## 4. `cfg_t` and profile diff

### 4.1 SV / Python field

Single new field:

| Field | Type | Default | Notes |
|---|---|---|---|
| `bg_model` | `logic [1:0]` | unchanged (0=EMA) | extend the existing enum: 0=EMA, 1=VIBE, **2=PBAS**. |

All PBAS constants are **compile-time** (project convention — see `vibe_K`, `vibe_R` etc. in `cfg_t`). The plan adds matching cfg fields:

| Field | Type | Default (DEFAULT, non-PBAS) | Default (DEFAULT_PBAS) |
|---|---|---|---|
| `pbas_N` | `logic [7:0]` | 20 | 20 |
| `pbas_R_lower` | `logic [7:0]` | 18 | 18 |
| `pbas_R_scale` | `logic [3:0]` | 5 | 5 |
| `pbas_Raute_min` | `logic [3:0]` | 2 | 2 |
| `pbas_T_lower` | `logic [7:0]` | 2 | 2 |
| `pbas_T_upper` | `logic [7:0]` | 200 | 200 |
| `pbas_T_init` | `logic [7:0]` | 18 | 18 |
| `pbas_R_incdec_q8` | `logic [7:0]` | 13 (= round(0.05 × 256)) | 13 |
| `pbas_T_inc_q8` | `logic [15:0]` | 256 (= round(1.0 × 256)) | 256 |
| `pbas_T_dec_q8` | `logic [15:0]` | 13 (= round(0.05 × 256)) | 13 |
| `pbas_alpha` | `logic [7:0]` | 7 | gradient-term weight |
| `pbas_beta` | `logic [7:0]` | 1 | intensity-term weight |
| `pbas_mean_mag_min` | `logic [7:0]` | 20 | floor for `formerMeanMag` |
| `pbas_bg_init_lookahead` | `logic [0:0]` | 0 | 0 (pbas_default) or 1 (pbas_lookahead) |
| `pbas_prng_seed` | `logic [31:0]` | `0xDEADBEEF` | `0xDEADBEEF` |

Q8 fixed-point representation chosen for the multiplicative `R_incdec`,
`T_inc/dec` so values are integers in the cfg struct (matches the existing
project convention). Python adapter divides by 256 to recover the float
values. `alpha`, `beta`, `mean_mag_min` are integer-valued in the published
reference impl, no Q8 needed.

### 4.2 Profile matrix

| Profile | `bg_model` | `pbas_bg_init_lookahead` | Role |
|---|---|---|---|
| `default` | 0 (EMA) | 0 | unchanged |
| `default_vibe` | 1 (ViBe) | n/a | unchanged |
| `vibe_init_external` | 1 (ViBe) | n/a | unchanged |
| `pbas_default` *(NEW)* | 2 (PBAS) | 0 | PBAS with paper-faithful init |
| `pbas_lookahead` *(NEW)* | 2 (PBAS) | 1 | PBAS with lookahead-median init |

Per-pixel PBAS state (`R`, `T`, `meanMinDist`) is allocated by the operator
regardless of profile. The `pbas_bg_init_lookahead` knob only switches the
bank-seeding routine.

## 5. File structure

```
py/models/ops/pbas.py            — PBAS class (Y-only)
py/models/_pbas_mask.py          — produce_masks_pbas() adapter
py/profiles.py                   — add 12 pbas_* fields + 2 new profiles
hw/top/sparevideo_pkg.sv         — mirror cfg_t fields (Phase-A-style shadow)
py/tests/test_pbas.py            — unit tests
py/experiments/run_pbas_compare.py    — comparison runner
py/viz/render_pbas_compare_webp.py    — labelled WebP renderer (uses py/viz/render.py)
docs/plans/2026-05-XX-pbas-python-results.md  — results doc (post-experiment)
```

The new `py/models/ops/pbas.py` mirrors the structure of the andrewssobral
PBAS.cpp reference impl: an `__init__` with all constants as kwargs (defaults
matching the C++ defaults exactly), an `init_from_frames(frames)` method
implementing the two init modes, and a `process_frame(frame) → mask` method
implementing the per-frame procedure of §3.6. Sobel computation lives inside
the class so callers pass raw Y frames; the operator computes the gradient
magnitude internally each frame and maintains `formerMeanMag` across frames.

## 6. Unit tests

| Test | Purpose |
|---|---|
| `test_pbas_init_from_frames_paper_default` | After 20-frame paper-default init, bank has 20 slots, one per frame, no PBAS processing occurred. |
| `test_pbas_init_from_lookahead` | Lookahead init: bank slots all derived from median (verify by querying samples). |
| `test_pbas_deterministic_under_fixed_seed` | Two runs with same seed produce bit-identical masks. |
| `test_pbas_R_clamped_to_R_lower` | After many frames of stable bg, R(x) clamps to R_lower (does not undershoot). |
| `test_pbas_T_clamped_to_bounds` | T(x) stays within [T_lower, T_upper] across long runs. |
| `test_pbas_meanMinDist_running_mean_formula` | Single-pixel run with controlled minDist sequence verifies the IIR running-mean math. |
| `test_pbas_gradient_distance_contribution` | With `alpha=7, beta=0`, distance is gradient-only — verify a frame with identical intensity but differing gradient produces non-zero distance. |
| `test_pbas_formerMeanMag_clamped_to_min` | A frame with zero gradient everywhere produces `formerMeanMag = mean_mag_min` (20), not 0 (prevents divide-by-zero / explosion of the gradient term). |
| `test_pbas_degenerates_to_vibe_when_rates_fixed` | With `R_incdec=0, T_inc=0, T_dec=0, alpha=0`, R/T frozen at init + gradient term zeroed → PBAS behaves like ViBe with `R=R_lower, phi=T_upper/T_init, N=20`. |

The degenerate-equivalence test (last row) is the key correctness gate — it
proves the shared mechanism (bank, matching, neighbor diffusion) is wired
correctly by freezing PBAS's adaptive feedback AND zeroing the gradient
contribution, leaving only the ViBe-equivalent distance function.

## 7. Empirical comparison and demos

### 7.1 Sources

- `media/source/birdseye-320x240.mp4`
- `media/source/people-320x240.mp4`

(The synthetic `ghost_box_*` sources are excluded from this comparison; the
question we're answering is "does PBAS beat `vibe_init_external` on real
clips?", and synthetic stressors don't address that.)

### 7.2 Methods compared

For each source:

1. `vibe_init_frame0` — no-fix baseline.
2. `vibe_init_external` — today's production.
3. `pbas_default` — PBAS, paper-faithful init.
4. `pbas_lookahead` — PBAS + lookahead init.

### 7.3 Per-source artefacts

Under `py/experiments/our_outputs/pbas_compare/<source>/`:

- `coverage.png` — 4-curve overlay (frame vs mean mask coverage).
- `convergence_table.csv` — asymptote / peak / time-to-1%-coverage per method.

Under `media/demo/`:

- `pbas-compare-<source>.webp` — 200-frame animated WebP, 4-up labelled
  side-by-side. Uses `py/viz/render.py`'s labelled-row helper (addresses the
  earlier complaint about unlabelled grids).

### 7.4 Decision criterion

`pbas_default` and/or `pbas_lookahead` must show **clear improvement** over
`vibe_init_external` on at least one real source, measured by:

- Lower asymptotic coverage (avg of last 50 frames), AND
- No worse peak coverage during convergence.

If neither PBAS variant beats `vibe_init_external` on either real source,
this is a NO-GO for the RTL follow-up. Document the finding and revert to
shipping `vibe_init_external` as the project's default (Option I from the
addendum).

## 8. Phasing

Single phase: Python only. RTL is explicitly deferred to a separate
follow-up plan, contingent on this experiment's NO-GO/GO outcome.

| Step | Deliverable |
|---|---|
| 1 | `py/models/ops/pbas.py` + unit tests passing |
| 2 | `py/models/_pbas_mask.py` adapter + integration tests |
| 3 | cfg_t / profile updates + parity test passing |
| 4 | Comparison runner |
| 5 | WebP renderer with labelled rows |
| 6 | Run experiment, write results doc |
| 7 | GO / NO-GO decision |

## 9. Open questions and follow-ups

1. **RTL move.** If experiment is GO, the RTL follow-up will need: per-pixel
   adaptive R/T storage (~6 bytes/pixel: 1 byte each for R, T, meanMinDist
   in q8/q12), a 2× wider sample bank (intensity + gradient per slot, ~40
   bytes/pixel), a Sobel pre-filter block (project has 3×3 windowed-filter
   primitives under `hw/ip/filters/`), a `formerMeanMag` running-mean
   accumulator (frame-wide scalar), an extra `meanMinDist` reduction in the
   comparator tree, two tiny update controllers, and a 3×3-neighbor
   random-selection block. Estimated 3–4 weeks RTL work (one week more than
   the Y-only estimate).
2. **Per-pixel state cost.** Python uses float32 freely; RTL will need
   quantization. Q8.0 for R/T (uint8 storage) covers the published value
   range exactly; Q4.4 might suffice for `meanMinDist`. Gradient bank slots
   stay uint8 quantised (same as intensity). To be determined in the RTL
   follow-up.
3. **RGB-per-channel features.** The reference impl stores intensity +
   gradient for *each* of 3 RGB channels (6 features per slot). We're
   keeping Y-only single-channel — drops 6×→ 2× per-slot width while
   preserving the gradient mechanism. Worth flagging as a deviation from the
   published variant; could be revisited if Y+gradient still underperforms.

## 10. References

- Hofmann, M., Tiefenbacher, P. & Rigoll, G. (2012). *"Background Segmentation with Feedback: The Pixel-Based Adaptive Segmenter."* CVPRW 2012. [Semantic Scholar](https://www.semanticscholar.org/paper/Background-segmentation-with-feedback:-The-Adaptive-Hofmann-Tiefenbacher/333c1563d72a75f8d3ff3830350555380dc54ebc)
- Reference implementation: [andrewssobral/simple_vehicle_counting/PBAS.cpp](https://github.com/andrewssobral/simple_vehicle_counting/blob/master/package_bgs/PBAS/PBAS.cpp)
- Background literature re-verification and Phase A retrospective: [`2026-05-11-vibe-ghost-rescue-addendum.md`](2026-05-11-vibe-ghost-rescue-addendum.md)
- Original ViBe paper: Barnich & Van Droogenbroeck 2011, IEEE TIP.
- Lookahead-median init experiment (the existing `vibe_init_external` mechanism): [`2026-05-05-vibe-lookahead-init-results.md`](2026-05-05-vibe-lookahead-init-results.md)
