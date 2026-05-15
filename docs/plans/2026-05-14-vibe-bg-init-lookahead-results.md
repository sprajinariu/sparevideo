# ViBe BG Init — Look-Ahead Beyond Median — Results

**Date:** 2026-05-14
**Branch:** feat/vibe-bg-init-lookahead
**Companion design:** [`2026-05-14-vibe-bg-init-lookahead-design.md`](2026-05-14-vibe-bg-init-lookahead-design.md)
**Companion plan:** [`2026-05-14-vibe-bg-init-lookahead-plan.md`](2026-05-14-vibe-bg-init-lookahead-plan.md)

## Decision

**GO — promote MVTW** (`vibe_bg_init_mode=2`, `vibe_bg_init_mvtw_k=12`) as the new default for `DEFAULT_VIBE`. All 3 new modes (IMRM, MVTW, MAM) pass the GO criteria; MVTW wins the tiebreaker on mean high-traffic asymptote across real clips and additionally dominates the `ghost_box_moving` synthetic by a ~5x margin.

## Setup

ViBe params (fixed across all methods): K=20, R=20, min_match=2, φ_update=16, φ_diffuse=16, init_scheme=c, coupled_rolls=True, prng_seed=0xDEADBEEF. 200 frames per source. Source dimensions 320×240.

Methods compared (5):
- `vibe_init_external` — current production baseline (lookahead-median bg init).
- `vibe_init_imrm` — iterative motion-rejected median (tau=32).
- `vibe_init_mvtw` — per-pixel min-variance temporal window (k=12).
- `vibe_init_mam` — motion-aware (frame-diff outlier rejection) median (delta=6).
- `vibe_demote` — runtime control: lookahead-median init + persistence-based FG demotion (the existing production "best ghost suppression").

Sources (5): `birdseye-320x240.mp4`, `intersection-320x240.mp4`, `people-320x240.mp4`, `synthetic:ghost_box_disappear`, `synthetic:ghost_box_moving`.

## Knob sweep (Task 9 — one-pass on people-320x240.mp4)

| label | asym_overall | HT | LT |
|---|---|---|---|
| imrm_tau12 | 0.0994 | 0.5783 | 0.0922 |
| imrm_tau20 | 0.0995 | 0.5757 | 0.0917 |
| imrm_tau32 | 0.0994 | **0.5738** | 0.0913 |
| mvtw_k12  | 0.1002 | **0.5498** | 0.0904 |
| mvtw_k24  | 0.1006 | 0.5511 | 0.0905 |
| mvtw_k60  | 0.1016 | 0.6145 | 0.0913 |
| mam_delta6  | 0.0996 | **0.5477** | 0.0909 |
| mam_delta12 | 0.0992 | 0.5502 | 0.0914 |

Selected per-mode defaults: IMRM tau=32, MVTW k=12, MAM delta=6. Selection rule: lowest `asymptote_high_traffic` such that `asymptote_low_traffic` does not regress by more than +0.001 vs the median baseline. Profile dicts in `py/profiles.py` and matching SV `CFG_*` localparams were updated as part of Task 9.

## Headline — 5×5 high-traffic asymptote

Lower is better. Best non-demote per row in bold.

| Source | external | imrm | mvtw | mam | demote |
|---|---|---|---|---|---|
| birdseye | 0.5167 | 0.5060 | **0.4722** | 0.4880 | 0.5525 |
| intersection | 0.5295 | **0.5009** | 0.5089 | 0.5027 | 0.3991 |
| people | 0.5817 | 0.5738 | 0.5498 | **0.5477** | 0.5461 |
| ghost_box_disappear (HT) | nan | nan | nan | nan | 0.9487 |
| ghost_box_moving (HT) | 0.6692 | 0.6692 | **0.1374** | 0.6132 | 0.5799 |

`ghost_box_disappear` HT is NaN for the init-only methods because the disappearing object scenario has no persistent high-traffic pixels once the object leaves — there is no HT region to score against. `demote`'s HT value here reflects scoring over a different region definition driven by the runtime persistence map.

## Headline — 5×5 overall asymptote

Lower is better.

| Source | external | imrm | mvtw | mam | demote |
|---|---|---|---|---|---|
| birdseye | 0.0374 | 0.0386 | 0.0385 | 0.0377 | 0.0355 |
| intersection | 0.0535 | 0.0539 | 0.0547 | 0.0544 | 0.0541 |
| people | 0.0990 | 0.0994 | 0.1002 | 0.0996 | 0.0939 |
| ghost_box_disappear | 0.0016 | 0.0016 | 0.0016 | 0.0016 | 0.0593 |
| ghost_box_moving | 0.0455 | 0.0455 | **0.0084** | 0.0454 | 0.0806 |

## Per-source observations

- **birdseye:** MVTW wins HT (0.4722 vs external 0.5167; −8.6%). All 3 new modes beat external. `demote` regresses (0.5525).
- **intersection:** IMRM wins HT among init methods (0.5009 vs external 0.5295). MVTW (0.5089) and MAM (0.5027) also beat external. `demote` wins outright at 0.3991 but at the cost of its known hollowing failure mode (visual inspection of WebPs).
- **people:** MAM wins HT (0.5477 vs external 0.5817). MVTW close behind (0.5498). MAM and `demote` (0.5461) essentially tie.
- **ghost_box_disappear:** All init methods tied at 0.0016 overall — by design, the disappearing-object scenario has no persistent high-traffic pixels once the ghost departs. `demote` is much worse (0.0593) because its persistence-based mechanism requires sustained FG classification that the disappearing object cannot provide.
- **ghost_box_moving:** MVTW DOMINATES (HT 0.1374 vs external 0.6692, overall 0.0084 vs external 0.0455 — a ~5x improvement). The K=12 temporal window is short enough that even under sustained motion, MVTW finds the BG-clear segment. IMRM and MAM provide no improvement on this source (within numerical noise of external).

## GO criteria check

- **Must (dominate external HT on all 3 real clips):** all 3 new modes pass.
  - birdseye: imrm 0.5060, mvtw 0.4722, mam 0.4880 — all < external 0.5167. ✓
  - intersection: imrm 0.5009, mvtw 0.5089, mam 0.5027 — all < external 0.5295. ✓
  - people: imrm 0.5738, mvtw 0.5498, mam 0.5477 — all < external 0.5817. ✓
- **Must not (regress synthetic ghost asymptote by >0.001):** all 3 new modes ≤ external on both ghost sources.
  - `ghost_box_disappear` overall: all four at 0.0016 (tie). ✓
  - `ghost_box_moving` overall: imrm 0.0455 = external, mvtw 0.0084 < external, mam 0.0454 < external. ✓
- **Tiebreaker (mean HT across real clips):** IMRM 0.5269, MAM 0.5128, **MVTW 0.5103 (winner)**.
- **Bonus (match/beat `demote` on HT):** MVTW beats `demote` on birdseye (0.4722 vs 0.5525), comparable on people (0.5498 vs 0.5461), loses on intersection (0.5089 vs 0.3991). MAM and IMRM show a similar pattern. The new init modes are an alternative path to demote-class ghost suppression — trading runtime mechanism complexity (`demote_en` + `K_persist` + `consistency_thresh`) for offline preprocessing (per-pixel temporal computation). Crucially, init-mode wins on `ghost_box_disappear` where `demote` regresses by ~37x (0.0016 vs 0.0593).

## Recommendation

**Promote MVTW as the new default** for `DEFAULT_VIBE`:
- `vibe_bg_init_mode = 2` (BG_INIT_MVTW)
- `vibe_bg_init_mvtw_k = 12`

Keep IMRM and MAM available as selectable profile modes (`vibe_init_imrm`, `vibe_init_mam`). The `vibe_init_external` (median) profile remains as the previous baseline reference.

For the RTL pipeline: the chosen winner is pre-computed in Python and pre-loaded into the bank via the existing external-init hook — no new RTL paths, no streaming-init compute. The `cfg_t.vibe_bg_init_mode` field is propagated for future RTL ROM generation if needed (`py/gen_vibe_init_rom.py` would need to learn the new modes, but that is deferred — out of scope for this plan).

## Caveats / open questions

- **MVTW recency tie-break.** The implementation prefers the most recent min-variance window on ties (see `_bg_mvtw` docstring). This matches the FG-then-BG scenario where BG is revealed late in the clip. Any future RTL port must use the same tie-break rule.
- **K=12 sensitivity to frame rate.** All sources were 30 fps. K=12 frames ≈ 0.4 s — short enough to find clean windows even with sustained motion at typical pedestrian/vehicle speeds. Variable-fps sources would need K scaled to time, not frames. Not exercised by this experiment set.
- **Pre-existing RuntimeWarning in MAM.** `np.nanmedian` warns on all-NaN slices when every frame at some pixel is flagged motion. The all-motion fallback correctly returns the plain median, so the output is correct — cosmetic noise only, could be suppressed in a follow-up.
- **No hollow-fraction direct measurement.** The tiebreaker used mean HT asymptote as a proxy. Visual inspection of the per-source coverage curves and mask grids in `py/experiments/our_outputs/bg_init_compare/<source>/` is recommended to confirm no hollowing-class failure mode regression.

## Artifacts

Per-source artifacts (gitignored, regenerable via `python py/experiments/run_bg_init_compare.py`):
- `py/experiments/our_outputs/bg_init_compare/<source>/coverage.png`
- `py/experiments/our_outputs/bg_init_compare/<source>/convergence_table.csv`
- `py/experiments/our_outputs/bg_init_compare/<source>/coverage_by_region.csv`

Knob sweep artifact:
- `py/experiments/our_outputs/bg_init_compare/_sweep/summary.csv`
