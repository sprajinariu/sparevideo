# ViBe Phase 0 Re-do — Design Doc

**Date:** 2026-05-05
**Branch:** feat/vibe-motion-design (continuation)
**Companion plan:** [`2026-05-01-vibe-phase-0-plan.md`](2026-05-01-vibe-phase-0-plan.md)
**Companion design doc:** [`2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md)
**Prior results:** [`2026-05-04-vibe-phase-0-results.md`](2026-05-04-vibe-phase-0-results.md)

## Goal

Three refinements to Phase 0 that together either close or fully characterize the remaining numerical gaps from the prior verdict, and add one new exploratory comparison the user requested:

1. **Init-noise-width fix** — widen our scheme (c) noise range from ±8 to ±20 to match upstream. The prior results doc identified this as the most likely root cause of the `lighting_ramp` outlier (per-frame `|ours − upstream| = 0.0630`) and the residual ~0.012 real-clip parity gap.
2. **K-comparison source change** — the current `synthetic:textured_static` source produces 0.000 coverage at every K, so it tells us nothing. Replace with `synthetic:noisy_moving_box`, where K materially affects how much noise the sample bank can absorb.
3. **Ghost-decay control sweep** — new exploratory experiment on `synthetic:ghost_box_disappear` answering "which knobs decrease the number of frames before a frame-0 ghost clears?" Sweep `phi_diffuse` along the full power-of-2 ladder with `coupled_rolls=False` (the only mode where `phi_diffuse` is meaningful).

The first two are fixes to known-defective comparisons; the third is exploratory and orthogonal to upstream parity.

## Non-goals

- No RTL changes — those are Phase 2 work.
- No re-capture of upstream baselines — upstream's `randint(-20, 20)` init stays as-is; only our side moves to match it.
- No new synthetic patterns.
- No `coupled_rolls=True` variant of the φ-diffuse sweep. In coupled mode `phi_diffuse` is unused (collapsed under `phi_update`), so the user's exploratory question is meaningless there.
- No 2-D crossing with `phi_update` — the user's question is specifically about diffusion probability. `phi_update` interaction stays as a follow-up if the φ-diffuse sweep alone shows a ceiling.

## Component changes

### 1. `_init_scheme_c` in `py/experiments/motion_vibe.py`

**Current (4-bit lanes, 1 PRNG advance/pixel):**
```python
state = self._next_prng()
for k in range(self.K):
    nibble = (state >> (4 * k)) & 0xF
    noise = nibble - 8        # signed [-8, +7]; width 16
```

**New (8-bit lanes, 2 PRNG advances/pixel):**
```python
s0 = self._next_prng()
s1 = self._next_prng()
for k in range(self.K):
    if k < 4:
        byte = (s0 >> (8 * k)) & 0xFF
    else:
        byte = (s1 >> (8 * (k - 4))) & 0xFF
    noise = (byte % 41) - 20  # signed [-20, +20]; width 41
```

Notes:
- 41 is non-power-of-two so modulo introduces a slight non-uniformity (15 of the 256 byte values map to one extra count on each integer in `[-20, +20]` — ~5.9% bias, well below the K=20 sample-bank smoothing). Matches upstream's behavior closely enough; upstream itself uses Python's `random.randint(-20, 20)` which is uniform.
- The 2 PRNG advances per pixel during init shift the global PRNG state vs. the prior run, so all downstream coverage numbers will drift slightly. Expected and the whole point of the re-do.
- `K > 8` requires more lanes than 8 bytes can hold. Keep an assertion `K <= 8` with a clear error message — Phase 2 RTL will need a per-K-step PRNG advance scheme, but Phase 0 doesn't exercise K > 8 today (the K-comparison test uses K ∈ {8, 20}; the K=20 path doesn't go through `_init_scheme_c` for noise lanes beyond k=7 because there are no more lanes — see test plan §K-coverage below for how this is handled).

**K=20 init-scheme-c handling.** The current 4-bit-lane code is silently broken for K > 8. With state bounded to 32 bits and `nibble = (state >> (4*k)) & 0xF`, any `k ≥ 8` shifts past the state and yields `nibble = 0`, so `noise = -8` for every slot k=8..19 of every pixel. **Effective behavior today: K=20 init has only 8 noisy slots (k=0..7); slots k=8..19 are all degenerate `clamp(y - 8, 0, 255)` for every pixel.** The 8-bit-lane variant of the new code has the same problem in worse form (only 4 lanes per state word). Three options:

- **(a)** Advance PRNG `ceil(K / 4)` times per pixel when K > 8, providing one byte per slot. K=20 → 5 advances; K=8 → 2 advances; K=4 → 1 advance. Cleanest; eliminates the slot-degenerate bug.
- **(b)** Advance PRNG twice (8 lanes) and accept that slots 8..K-1 reuse lanes via modular indexing (`k % 8`). Preserves correlation across slots in the K > 8 path; still better than today's all-degenerate behavior but worse than (a).
- **(c)** Assert `K <= 8` in `_init_scheme_c` and force K=20 to use scheme (a)/(b).

**Choice: (a).** Cleanest semantics; the up-to-5× PRNG cost during init is one-time per source so negligible. Document the change in the docstring. The K=20 numbers in the re-do will differ from the prior run for two independent reasons combined (wider noise + non-degenerate lanes for k≥8); the results doc will call out both.

### 2. `run_k_comparison` in `py/experiments/run_phase0.py`

Three changes:

- Source: `"synthetic:textured_static"` → `"synthetic:noisy_moving_box"`.
- Pick up the upstream baseline for that source from `py/experiments/upstream_baseline_outputs/synthetic_noisy_moving_box` (already captured at K=20). Pass it via `upstream_masks_dir`. The K=8 row is then directly comparable to the same upstream-K=20 reference: a deviation tells us the parity cost of dropping K.
- Print per-K: `avg`, `steady-state[32:]`, **and** per-frame `|ours − upstream|` so we can see whether smaller K causes parity drift.

The function signature, the K values tested ({8, 20}), and the output directory layout (`our_outputs/k_comparison/{K8,K20}/`) stay the same.

### 3. New `run_phi_diffuse_sweep` in `py/experiments/run_phase0.py`

```python
def run_phi_diffuse_sweep(
    out_root: str = "py/experiments/our_outputs/phi_diffuse_sweep",
    num_frames: int = 200,
):
```

Behavior:

- Source: `synthetic:ghost_box_disappear` (frame 0 has a bright box at center; frames 1+ are pure black — the canonical frame-0-ghost stress source).
- Fixed knobs: `K=20, R=20, min_match=2, phi_update=16, init_scheme="c", coupled_rolls=False`.
- Sweep: `phi_diffuse ∈ {16, 8, 4, 2, 1}` (full power-of-2 ladder; 1 = always-fire ceiling).
- For each value: instantiate `ViBe(...)`, init from frame 0, process frames 1..N-1, collect masks. (Bypass `run_source` — calling it 5× would render 5 separate grids; we want one combined sweep grid.)
- Render **one** `phi_diffuse_sweep/grid.png` with rows in this order:
  - `phi=16` (current default; baseline reference)
  - `phi=8`
  - `phi=4`
  - `phi=2`
  - `phi=1` (always-fire ceiling)
  - `upstream` (from `upstream_baseline_outputs/synthetic_ghost_box_disappear`, K=20, coupled-rolls; for visual reference)
  - `ema` (the project's existing baseline)
- Render **one** `phi_diffuse_sweep/coverage.png` with all 7 curves overlaid (5 ours + upstream + ema). Title: `ghost_box_disappear | phi_diffuse sweep | coupled_rolls=False`.
- Print, for each φ, the **first frame at which coverage stays below `0.005` for 8 consecutive frames** ("ghost cleared" proxy). If the ghost never clears in the 200-frame window, print `>200` for that φ.
- Add `--matrix phi_diffuse_sweep` to the `argparse` choices and include it in `--matrix all`.
- Reuse `render_grid` (already accepts arbitrary labelled rows) and `render_coverage_curves` (already accepts arbitrary curve dicts). No render-side code changes.

### 4. Results doc updates ([2026-05-04-vibe-phase-0-results.md](2026-05-04-vibe-phase-0-results.md))

After the re-runs land:

- **Header date / "what changed"** — add a 5th bullet describing the noise-width fix and the latent-correlation fix in init scheme (c).
- **Per-source cross-check table** — re-run all sources at the new init; replace numbers; flag any source where `|ours − upstream|` *increased*.
- **Init-noise-width section** — re-frame as "resolved" (or "partially resolved" if `lighting_ramp` numbers don't fully close). Replace the deferred-TODO with the implementation note.
- **K=8 vs K=20 paragraph** — replace with the new `noisy_moving_box`-based numbers and parity-drift commentary.
- **New section "Ghost-decay control sweep"** — phi → first-cleared-frame table; reference `phi_diffuse_sweep/grid.png` and `coverage.png`. Add the takeaway: "lower φ_diffuse reduces ghost-clear time at known cost X; the canonical-ViBe φ_diffuse=16 setting is on the slow end of the curve."
- **Open TODOs table** — remove the init-noise-width row (resolved). Add a row noting that the φ-diffuse sweep is informational and that final RTL knob choice is made in writing-plans for Phase 2.

### Test changes (`py/tests/test_motion_vibe.py`)

- Update `test_init_scheme_c_samples_within_noise_band` (line ~24): expand bounds from `[120, 135]` (= `[128-8, 128+7]`) to `[108, 148]` (= `[128-20, 128+20]`).
- Update `test_init_scheme_c_clamps_at_edges` (line ~35): for frame value 0, expected `samples.max() <= 20` (was `<= 7`); for frame value 255, expected `samples.min() >= 235` (was `>= 247`).
- Update `test_init_scheme_c_deterministic_from_seed` and `test_init_scheme_c_different_seeds_differ` (lines ~52, 63): no logic change needed (they test equality, not specific values), but re-confirm they pass after the PRNG-advance-count change.
- Add one new assertion on a K=20 init at `init_scheme=c`: verify slots k=8..19 are NOT all degenerate `y - 8` for some center value (regression-protection for the latent slot-degenerate bug).
- Add one new assertion: across a 64×64 init at `init_scheme=c, K=8`, the observed noise range across all slots covers ≥ 90% of `[-20, +20]` (loose empirical bound; sanity-checks the modulo-41 isn't producing a degenerate distribution).
- All other tests untouched.

## Architecture / data flow

No structural changes. All modifications are local to:

- `py/experiments/motion_vibe.py` (one method body)
- `py/experiments/run_phase0.py` (one function source-line change + one new function + argparse update)
- `py/tests/test_motion_vibe.py` (re-baseline + one new test)
- `docs/plans/2026-05-04-vibe-phase-0-results.md` (text updates)

The existing `run_source` orchestration, `render_grid` / `render_coverage_curves` rendering, `coverage_curve` / `run_ema_baseline` metrics, and `xorshift32` PRNG are all unchanged.

## Error handling / edge cases

- **PRNG advance count drift** — every source's reproducibility is tied to the cumulative PRNG advance count. Going from 1→2 or 1→5 advances per pixel during init shifts everything downstream. Tests must be re-baselined; results numbers must be re-recorded. Flag in commit message.
- **`phi_diffuse=1` (always-fire) sample-bank churn** — at φ=1 every bg pixel diffuses every frame, so on a fully-bg frame the bank is heavily overwritten. Sanity-check: false-positive rate on a clean source (e.g., `synthetic:moving_box` post-frame-0) shouldn't explode. If it does, document and proceed (the sweep is exploratory; high-FP at φ=1 is itself a finding).
- **K > 8 in scheme (c)** — current code has a latent indexing bug that this fix removes. Document explicitly in the new docstring so future readers know the prior-run numbers had a noise-correlation artifact for K=20 init.

## Test plan

- Run `pytest py/tests/test_motion_vibe.py` — must pass.
- Run `pytest py/tests` — full project test suite, no regressions.
- Run `python py/experiments/run_phase0.py --matrix synthetic` — verify all 7 synthetic sources still produce sensible numbers.
- Run `python py/experiments/run_phase0.py --matrix real` — verify 3 real clips' numbers shift in the expected direction (parity gap should narrow, not widen).
- Run `python py/experiments/run_phase0.py --matrix k_comparison` — verify the new noisy_moving_box source produces non-zero numbers and the K=8/K=20 difference is visible.
- Run `python py/experiments/run_phase0.py --matrix phi_diffuse_sweep` — verify all 5 φ values produce a complete sweep grid and a coverage plot with monotonic-ish faster-decay-as-φ-decreases trend.
- Run `python py/experiments/summarize_phase0.py` — re-emit the per-source `|ours − upstream|` table for the results doc.

## Open questions

None remaining.

## Caveats

- The modulo-41 distribution introduces a small non-uniformity vs. upstream's exact `randint(-20, 20)`. Quantitative size of the residual `|ours − upstream|` after this fix is the experiment's whole point; if non-zero it bounds the modulo-bias contribution.
- The K=20 init-scheme-c slot-degenerate fix changes prior-run numbers for any K=20 + scheme=c combination. Cannot disentangle "noise-width-fix effect" from "non-degenerate-slots effect" in the K=20 path; document both as a single combined change in the results doc.
- The φ-diffuse sweep is exploratory. It does NOT validate that any single φ value is the right RTL default — that decision belongs in writing-plans for Phase 2 and balances ghost-decay against false-positive rate on real clips, not just frame-0 ghost decay.
