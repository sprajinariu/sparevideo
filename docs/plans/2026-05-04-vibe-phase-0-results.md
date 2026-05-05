# ViBe Phase 0 — Decision Gate Results

**Date:** 2026-05-04 (initial verdict) / **2026-05-05** (re-validated three times: parameter-matched cross-check, then upstream Python patched for grayscale, then `coupled_rolls=True` matching upstream's coupling); init noise widened 2026-05-05
**Branch:** feat/vibe-motion-design
**Companion plan:** [`2026-05-01-vibe-phase-0-plan.md`](2026-05-01-vibe-phase-0-plan.md)
**Companion design doc:** [`2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md)

## Decision

**PASS** — Phase 0 validates our ViBe re-implementation against upstream's PyTorch reference at fully parameter-matched and behavior-matched settings. **Per-frame `|ours − upstream|` ≤ 0.0057 on every source after the init-noise-width fix** (was ≤ 0.0121 with one outlier at 0.0630). Phase 1 (Python ref promotion) and Phase 2 (RTL implementation) can proceed.

## What changed since the original 2026-05-04 verdict

The initial verdict passed but on a much weaker basis than implied. Three rounds of fixes uncovered and corrected:

1. **Parameter mismatch in capture script.** Initial captures used upstream's defaults (K=20, R=10, φ=8) while we ran K=8 / R=20 / φ=16. The `±0.06` cross-check passed across two different parameter sets — coincidental, not algorithmic parity.
2. **Upstream Python `4.5×` matchingThreshold scaling.** [`model.py:90`](https://github.com/vandroogenbroeckmarc/vibe/blob/main/Python/src/model.py#L90) hard-codes `matchingThreshold = 4.5 * self.matchingThreshold` (a 3-channel L1-summed scaling, applied unconditionally even for grayscale). Capture script now passes `R/4.5` to compensate for grayscale.
3. **Upstream Python skipped sample-bank updates entirely for grayscale input.** The whole self-update + diffusion body was inside `if self.channels == 3:`. Patched out (in our local copy of upstream — see `~/eval/vibe-upstream/Python/src/model.py`); now updates fire on grayscale too.
4. **Our re-impl's two-phi independent rolls don't match upstream's coupled-rolls behavior.** Added `coupled_rolls` option to ViBe (default False at the class level for backward compat, `True` at `run_source` for parameter-matched cross-check). When True, one PRNG roll per pixel determines whether self-update + diffusion both fire on the same pixel under shared probability `1/phi_update` — mirrors upstream.
5. **Init noise width widened from ±8 to ±20 + K>8 slot-degenerate bug fix.** Scheme (c) now uses 8-bit lanes with `byte % 41 - 20` and `ceil(K/4)` PRNG advances per pixel during init (K=20 → 5 advances; K=8 → 2; K=4 → 1). This eliminates the prior latent bug where K=20 slots k=8..19 all collapsed to `clamp(y - 8, 0, 255)` because `(state >> (4*k)) & 0xF == 0` for any k ≥ 8 on a 32-bit state. The widened noise alone closes the `lighting_ramp` outlier (0.0630 → 0.0057 per-frame |diff|) and the real-clip gap (~0.012 → ≤0.0022). See [`2026-05-05-vibe-phase-0-redo-design.md`](2026-05-05-vibe-phase-0-redo-design.md) for full rationale.

## Final per-source cross-check (parameter-matched + coupled_rolls + patched upstream, 200 frames each)

| Source | ours avg | upstream avg | EMA avg | per-frame `|ours − upstream|` |
|---|---|---|---|---|
| synthetic:moving_box | 0.062 | 0.062 | 0.064 | **0.0000** |
| synthetic:dark_moving_box | 0.062 | 0.062 | 0.225 | **0.0000** |
| synthetic:noisy_moving_box | 0.062 | 0.062 | 0.074 | **0.0004** |
| synthetic:textured_static | 0.000 | 0.000 | 0.000 | **0.0000** |
| synthetic:lighting_ramp | 0.694 | 0.688 | 0.218 | **0.0057** ← was 0.0630 |
| synthetic:ghost_box_disappear | 0.058 | 0.059 | 0.017 | **0.0007** |
| synthetic:ghost_box_moving | 0.122 | 0.123 | 0.081 | **0.0002** |
| birdseye-320x240.mp4 | 0.051 | 0.051 | 0.095 | **0.0004** ← was 0.0118 |
| people-320x240.mp4 | 0.119 | 0.121 | 0.298 | **0.0022** ← was 0.0106 |
| intersection-320x240.mp4 | 0.088 | 0.089 | 0.171 | **0.0004** ← was 0.0121 |

All ten sources show per-frame `|ours − upstream| ≤ 0.0057` after the init-noise-width fix. The previously-outlier `lighting_ramp` source is now in line with the rest (was 0.0630, an order of magnitude above all other sources). Real-clip per-frame diffs collapsed by ~10× as well, confirming the init-noise hypothesis from the prior round.

## Cross-check budget tightening

The original Phase-0 plan budget was `±0.10`, set when the only baseline was a parameter-mismatched upstream. After the init-noise-width fix, every source is now inside `±0.0057` per-frame mean diff (was `±0.013` with one `lighting_ramp` outlier at `0.063` before). **A more honest budget for parameter-matched ViBe-vs-ViBe is `±0.01`**, and we satisfy that on **all 10 of 10 sources**.

## Init-noise-width discrepancy — RESOLVED

The previous round identified the init noise range as the most likely cause of the `lighting_ramp` outlier and the residual ~0.012 real-clip gap. Hypothesis confirmed.

**Fix landed 2026-05-05.** Scheme (c) was widened from ±8 (4-bit lanes, 1 PRNG advance per pixel) to **±20** (8-bit lanes, `ceil(K/4)` PRNG advances per pixel during init), matching upstream's `randint(-20, 20)` range. The implementation also fixed a latent slot-degenerate bug under the old code: with `state` bounded to 32 bits, `(state >> (4*k)) & 0xF == 0` for any k ≥ 8, so K=20 slots 8..19 all collapsed to `clamp(y - 8, 0, 255)` for every pixel. The new `ceil(K/4)`-advance scheme eliminates this — K=20 → 5 advances, K=8 → 2, K=4 → 1, with one byte per slot.

**Effect on per-frame `|ours − upstream|`** (200 frames each):
- `lighting_ramp`: 0.0630 → 0.0057 (~11× reduction)
- `birdseye`: 0.0118 → 0.0004 (~30× reduction)
- `people`: 0.0106 → 0.0022 (~5× reduction)
- `intersection`: 0.0121 → 0.0004 (~30× reduction)

Other sources (which had per-frame |diff| already ≤ 0.0031 in the prior round) are essentially unchanged.

**Implementation note for Phase 2 RTL.** The Python reference now requires `ceil(K/4)` PRNG advances per pixel during init in scheme (c). The future RTL must mirror this advance count to maintain bit-exact parity at TOLERANCE=0. The modulo-41 noise generation introduces a small (~5.9%) non-uniformity bias relative to upstream's uniform `randint(-20, 20)`, accepted as below the K-slot smoothing threshold and below the residual numerical noise floor.

## Ghost-mechanism findings (revised)

### Correction to the prior report

The previous report claimed "no ghost is created at init" on the basis that the original synthetic patterns (`moving_box`, `dark_moving_box`, etc.) deliberately have frame 0 = bg-only. **That claim is now misleading.** The new ghost-test sources (`synthetic:ghost_box_disappear`, `synthetic:ghost_box_moving`) deliberately violate that convention to force frame-0 contamination, and **on those sources both ours and upstream produce a clear ghost**:

- `ghost_box_disappear`: frame 0 has a bright box at center; frames 1+ are pure black. Frame 1 ghost coverage ≈ 0.0625 (the box's footprint), and that coverage stays roughly that level for 200 frames — both ours (0.058 avg) and upstream (0.059 avg) confirm it.
- `ghost_box_moving`: frame 0 has the box top-left; frames 1+ have the box at a moving position elsewhere. Coverage ≈ 0.062 (frame-0 ghost) + 0.062 (moving box detected) = 0.124 — both impls match (0.123).

So the correct statement is: **a frame-0 ghost IS created when the source has frame-0 foreground, and at K=20/φ=16 the diffusion mechanism cannot clear an 80×60 ghost in 200 frames.** Visual evidence: the user observed ghost being slowly "eaten away" at the boundary on row 1 (ours), and the same is now visible on row 2 (upstream) after the upstream-Python patch.

### Why the ghost doesn't clear in 200 frames

Boundary-driven cascade math (Doc B §2): inward leaks per frame ≈ `B / (k · φ)`. For an 80×60 ghost (boundary B≈280, k≈8, φ=16) that's ≈2.2 inward leaks per frame. Over 200 frames: ~440 leaks against 4800 ghost pixels × 20 sample slots = 96,000 slots. Just 0.5% of slots get refreshed by diffusion in 200 frames at this ghost size. **The ghost cannot be repaired in 200 frames at this scale.**

Doc B §2's quote of "50–150 frames" is from the canonical Barnich paper test using smaller ghosts and possibly relaxed parameters. The Doc B "≤200 frames" gate criterion was over-confident for 80×60+ ghost regions; should be revised to a clear "small ghost" qualifier or removed.

### What this means for Phase 0

The persistent-ghost behavior is **expected canonical-ViBe behavior**, not a defect. Both ours and upstream agree on the ghost rate. Visual confirmation matches numerical: per-frame |diff| ≤ 0.0007 on `ghost_box_disappear`. Phase 0 validates that our diffusion mechanism is implemented faithfully; it does NOT validate that vanilla ViBe's diffusion is fast enough for arbitrary real-world clips. PBAS (Doc A §6) is the literature answer for fast-decay-needed deployment; vanilla ViBe is what we implement.

## K=8 vs K=20 stress-test

Re-targeted from the prior `synthetic:textured_static` source (which produced 0.000 coverage at every K, telling us nothing) to `synthetic:noisy_moving_box`. The new source has both real motion and per-pixel noise, so K materially affects how much noise the sample bank can absorb.

| K | avg | steady-state (32+) | per-frame `|ours − upstream|` |
|---|---|---|---|
| 8 | 0.065 | 0.065 | **0.0031** |
| 20 | 0.062 | 0.062 | **0.0002** |

Upstream is captured at K=20, so the K=20 row is direct parity (matches to 4 decimals). The K=8 row sits ~10× further from upstream — the parity cost of dropping K from 20 to 8. Both Ks remain numerically reasonable; K=8 is acceptable when memory is the constraint.

## Ghost-decay control sweep (`synthetic:ghost_box_disappear`)

Sweep over `phi_diffuse ∈ {16, 8, 4, 2, 1}` with `coupled_rolls=False`, `phi_update=16`, K=20, init scheme c. Source: frame 0 has bright box at center; frames 1+ are pure black (canonical frame-0-ghost stress).

| phi_diffuse | per-pixel-per-frame fire prob | avg coverage | first cleared frame |
|---|---|---|---|
| 16 | 6.25% | 0.058 | >200 |
| 8  | 12.5% | 0.053 | >200 |
| 4  | 25%   | 0.045 | >200 |
| 2  | 50%   | 0.031 | >200 |
| 1  | 100%  | 0.017 | **111** |

"First cleared frame" = first frame F at which coverage stays below 0.005 for 8 consecutive frames. `>200` means the ghost did not clear within the 200-frame window at this strict criterion.

Visual + curves: `py/experiments/our_outputs/phi_diffuse_sweep/{grid,coverage}.png`.

**Takeaway.** Ghost decay is monotonically faster as `phi_diffuse` decreases (avg coverage 0.058 → 0.017 across the 16-fold range). Only the always-fire setting (φd=1) clears the 80×60 frame-0 ghost within 200 frames at the strict 0.005-for-8-consecutive criterion. The canonical-ViBe `phi_diffuse=16` is on the slow end of the curve and does not clear in 200 frames at this scale of ghost. The cost of aggressive `phi_diffuse` is faster sample-bank churn — see Doc B Phase 2 analysis for the false-positive tradeoff on real clips. **For Phase 2 RTL, this sweep is informational only; the final knob choice balances ghost decay vs. real-clip false-positive rate, not just frame-0 ghost decay.**

## Frame-0 init scheme comparison (Doc B §10.4) — coupled_rolls mode

| Source | scheme (a) | scheme (b) | scheme (c) |
|---|---|---|---|
| ghost_box_disappear | 0.055 | 0.058 | 0.058 |
| ghost_box_moving | 0.121 | 0.123 | 0.123 |

Scheme (a) — paper-canonical 3×3 neighborhood draws — is again **marginally best** on `ghost_box_disappear` because boundary-of-ghost pixels start with a few "true-bg" samples drawn from neighbors that ARE bg in frame 0. The advantage is small (~0.003) but consistent across runs.

**Recommendation unchanged from prior report:** keep scheme (c) as the design default (matches upstream; simplest hardware via PRNG bit slicing). Switch to scheme (a) in RTL only if Phase 2 shows the modest ghost-decay improvement is worth the 3-line buffer cost.

## Negative control on `synthetic:ghost_box_disappear` — INCONCLUSIVE in coupled_rolls mode

`phi_diffuse=0` setting is **ignored when `coupled_rolls=True`** because the coupled path uses only `phi_update`. So the negative control no longer ablates diffusion in coupled mode (avg=0.058, same as the regular run). This is a known limitation of the coupled-rolls + negative-control combination.

The diffusion mechanism is independently validated by:
1. **Per-frame parity with upstream** (|diff| ≤ 0.0007 on `ghost_box_disappear`) — same diffusion rate as upstream.
2. **Visual evidence** — the ghost is being slowly eaten at the boundary in both ours and (now-patched) upstream rows of `ghost_box_disappear/grid.png`.
3. **Independent-rolls negative control still works** — running with `coupled_rolls=False, phi_diffuse=0` reproduces the no-diffusion baseline (avg=0.062, vs 0.058 with diffusion). Available via the `coupled_rolls=False` profile if explicit ablation is needed.

## Test status

181 unit tests pass:
- `test_xorshift.py` — 3 (PRNG bit-exactness)
- `test_motion_vibe.py` — 33 (init schemes a/b/c, decision rule, self-update, diffusion, process_frame, K=20 + K=any-positive support, **coupled_rolls=True**, **±20-noise band + K=20 slot-degenerate regression + 90% noise-coverage** new in the 2026-05-05 redo)
- `test_metrics.py` — 10
- `test_frame_io.py` — 6 (incl. 2 ghost-pattern tests)
- 129 pre-existing project tests, no regressions

## Recommendation

- ✅ **Greenlight Phase 1** — promote `py/experiments/motion_vibe.py` to `py/models/motion_vibe.py` with `cfg_t.bg_model` field per Doc B §4–5. Default to `coupled_rolls=True` for parity with the canonical algorithm.
- ✅ **Greenlight Phase 2** — RTL `motion_core_vibe` + `axis_motion_detect_vibe` per Doc B.
- **Default cfg knobs validated:** K=20 (or K=8 for memory budget), R=20, min_match=2, phi_update=φ=16, init_scheme=c, **coupled_rolls=True**.
- **Doc B §2 + §8 ghost-convergence claims need revision** (the "50–150 frames" / "≤200 frames" numbers are too aggressive for 80×60+ ghost regions; should specify ghost-size qualifier or be removed).
- **Doc B §2 should add the `coupled_rolls` parameter description** as the new canonical-matching default.

## Open TODOs (deferred to Phase 1 / writing-plans)

| TODO | Why it matters | Cheap fix or scope |
|---|---|---|
| **Final RTL phi_diffuse choice for Phase 2** | The phi_diffuse sweep here is informational. Final RTL knob choice balances ghost decay vs. real-clip false-positive rate; defer to writing-plans for Phase 2. | None — design decision in Phase 2. |
| **`coupled_rolls=False` ablation profile in Phase 1** | Doc B §2's two-phi generalization remains a useful ablation knob; the negative-control test only works in this mode. | Already implemented; just needs to be exercised in Phase 1 testing as a regression-protection ablation. |
| **C-reference port for higher confidence (deferred per user direction)** | Upstream Python had bugs (4.5× scaling, grayscale-skipped updates). The C reference doesn't have these. Porting C to Python gives a true bit-exact reference. | Out of scope for Phase 0. Revisit if Phase 1 / Phase 2 needs stronger numerical validation. |

## Caveats

1. **Upstream Python had two grayscale-only bugs** (`4.5×` scaling and `if self.channels == 3:` gating the entire update path). Both are patched in our local copy (`~/eval/vibe-upstream/Python/src/model.py`) — see `feat/vibe-motion-design` git history at commits `2778ffe` (capture-script compensation) and the local `if True:` patch. Upstream itself is not modified; the patches live only in the local eval-licensed clone.

2. **No remaining numerical gaps at parameter-matched defaults.** The prior init-noise-width discrepancy is resolved (see the RESOLVED section above); all 10 sources are within `±0.0057` per-frame `|ours − upstream|`. The residual gap on `lighting_ramp` (0.0057) is plausibly attributable to the modulo-41 non-uniformity in our 8-bit-lane noise generator vs. upstream's uniform `randint(-20, 20)`, but is well below any meaningful budget.

3. **Stochastic algorithm parity discipline** (Doc B §10.5): the Xorshift32 PRNG is mirrored bit-exactly between our Python ref and the future RTL via `py/tests/test_xorshift.py`. `make verify` at TOLERANCE=0 will work for the future RTL.

4. **Real-world ghosts persist** because in busy scenes the contaminated region's boundary keeps being motion-classified by ongoing scene activity, leaving diffusion no bg-classified ports to leak through. Vanilla ViBe (what we implement) has no mechanism for this; PBAS does (per-pixel adaptive R(x)). Documented in Doc A §6 / Doc B §10.3 as the fallback path if Phase 1+2 deployment shows this matters.

## Embedded artifacts (gitignored, regenerable)

- `py/experiments/our_outputs/synthetic/<source>/grid.png` and `coverage.png` — input + ours + upstream + ema rows.
- `py/experiments/our_outputs/real/<source>/grid.png` and `coverage.png`.
- `py/experiments/our_outputs/k_comparison/{K8,K20}/`.
- `py/experiments/our_outputs/negative_control/phi_diffuse_0/`.
- `py/experiments/our_outputs/init_schemes/<source>/scheme_{a,b,c}/`.
- `py/experiments/upstream_baseline_outputs/<source>/mask_NNNNN.png` (200 frames each).

Regenerate end-to-end:

```bash
# Re-capture upstream (requires ~/eval/vibe-upstream/.venv with PyTorch + the local 4.5× and grayscale-update patches)
~/eval/vibe-upstream/.venv/bin/python py/experiments/capture_upstream.py
# Re-run our matrices with coupled_rolls=True
source .venv/bin/activate
python py/experiments/run_phase0.py --matrix all
# Per-source diffs
python py/experiments/summarize_phase0.py
```
