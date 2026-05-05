# ViBe Phase 0 Re-do Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine Phase 0 by widening init noise to ±20 (matching upstream), replacing the useless K-comparison source, and adding a `phi_diffuse` ghost-decay sweep. Re-run all matrices and update results.

**Architecture:** Three local Python changes — (1) `_init_scheme_c` becomes `ceil(K/4)`-advance 8-bit-lane noise generator with `[-20, +20]` range, (2) `run_k_comparison` source swap, (3) new `run_phi_diffuse_sweep` driver — followed by re-run of all matrices and results-doc updates. No RTL touched. No new infrastructure files.

**Tech Stack:** Python 3.12, NumPy, Pillow, Matplotlib (already in `.venv`). Pytest for unit tests.

**Branch:** Continue on `feat/vibe-motion-design` (this re-do iterates on the still-unmerged Phase 0 plan; no new branch needed). Squash all re-do commits along with prior Phase 0 commits at PR time.

**Spec:** [`docs/plans/2026-05-05-vibe-phase-0-redo-design.md`](2026-05-05-vibe-phase-0-redo-design.md)

---

## File Structure

**Modified:**
- `py/experiments/motion_vibe.py` — `_init_scheme_c` method body only.
- `py/tests/test_motion_vibe.py` — update 2 existing init-scheme-c tests, add 2 new tests.
- `py/experiments/run_phase0.py` — `run_k_comparison` source line, new `run_phi_diffuse_sweep` function, argparse choices update.
- `docs/plans/2026-05-04-vibe-phase-0-results.md` — text updates to per-source table, init-noise section, K-comparison paragraph; new ghost-decay-sweep section.

**Created (output artifacts, gitignored):**
- `py/experiments/our_outputs/phi_diffuse_sweep/grid.png`
- `py/experiments/our_outputs/phi_diffuse_sweep/coverage.png`
- Re-baselined `py/experiments/our_outputs/{synthetic,real,k_comparison,init_schemes,negative_control}/...` (overwritten in place by re-runs).

**Not touched:**
- `py/experiments/xorshift.py` — PRNG unchanged.
- `py/experiments/render.py`, `metrics.py`, `capture_upstream.py`, `summarize_phase0.py` — all unchanged.
- `py/models/`, `hw/`, any RTL.

---

### Task 1: Tighten the band-bound test to fail under the current ±8 implementation

**Files:**
- Modify: `py/tests/test_motion_vibe.py:24-32`

We start by making the existing band-bound test express the new contract (`[-20, +20]`). It will FAIL against the current code (which produces `[-8, +7]`), proving the test actually exercises the change before we touch `motion_vibe.py`.

- [ ] **Step 1: Update the test bounds**

In `py/tests/test_motion_vibe.py`, replace the body of `test_init_scheme_c_samples_within_noise_band`:

```python
def test_init_scheme_c_samples_within_noise_band():
    """Each slot of each pixel = current ± noise, range [-20, +20] (matches upstream)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    frame_0 = _y_frame(128, h=4, w=4)
    v.init_from_frame(frame_0)
    # All samples within [128-20, 128+20] = [108, 148] (no clamping at this center value).
    assert v.samples.min() >= 108
    assert v.samples.max() <= 148
    # The window must actually be exercised — at 4×4×8 = 128 slots, expect spread > 16.
    assert int(v.samples.max()) - int(v.samples.min()) > 16, \
        "Sample spread too narrow to be ±20 noise — likely still ±8 implementation"
```

- [ ] **Step 2: Run test to verify it FAILS**

Run from repo root:
```bash
source .venv/bin/activate && pytest py/tests/test_motion_vibe.py::test_init_scheme_c_samples_within_noise_band -v
```

Expected: FAIL — current `_init_scheme_c` produces values in `[120, 135]`; the new lower bound `>= 108` is satisfied trivially (120 ≥ 108) but the upper bound `<= 148` is also satisfied (135 ≤ 148). Hmm — those bounds would still pass. The spread assertion is what fails: under ±8 the spread is at most `7 - (-8) = 15`, which fails `> 16`.

So expected failure message: `AssertionError: Sample spread too narrow to be ±20 noise — likely still ±8 implementation`.

If the test PASSES at this step, something is wrong — investigate before continuing.

---

### Task 2: Implement ±20 noise with `ceil(K/4)` PRNG advances per pixel

**Files:**
- Modify: `py/experiments/motion_vibe.py:86-101` (the `_init_scheme_c` method body and docstring)

- [ ] **Step 1: Replace the `_init_scheme_c` method**

In `py/experiments/motion_vibe.py`, replace the current `_init_scheme_c` (lines 86-101):

```python
    def _init_scheme_c(self, frame_0: np.ndarray) -> None:
        """Scheme (c): each slot = clamp(y + noise, 0, 255), noise ∈ [-20, +20].

        8-bit lanes (one byte per slot) sliced from N PRNG state words, where
        N = ceil(K / 4). Each byte produces a noise via `(byte % 41) - 20`,
        matching upstream's `randint(-20, 20)` range. The modulo-41 introduces
        a small (~5.9%) non-uniformity below the K-slot smoothing threshold.

        K=20 specifically uses 5 PRNG advances per pixel during init; K=8 uses
        2; K=4 uses 1. This eliminates the prior latent slot-degenerate bug in
        which slots k≥8 collapsed to `clamp(y - 8, 0, 255)` because
        `(state >> (4*k)) & 0xF == 0` for any k ≥ 8 on a 32-bit state.

        Companion design doc: docs/plans/2026-05-05-vibe-phase-0-redo-design.md
        """
        n_advances = (self.K + 3) // 4  # ceil(K / 4)
        for r in range(self.H):
            for c in range(self.W):
                # Pre-roll all state words for this pixel so lane indexing is uniform.
                states = [self._next_prng() for _ in range(n_advances)]
                y = int(frame_0[r, c])
                for k in range(self.K):
                    word = states[k // 4]
                    byte = (word >> (8 * (k % 4))) & 0xFF
                    noise = (byte % 41) - 20  # signed [-20, +20]
                    val = y + noise
                    val = 0 if val < 0 else (255 if val > 255 else val)
                    self.samples[r, c, k] = val
```

- [ ] **Step 2: Re-run the band-bound test to verify it now PASSES**

```bash
source .venv/bin/activate && pytest py/tests/test_motion_vibe.py::test_init_scheme_c_samples_within_noise_band -v
```

Expected: PASS. Sample spread should be in the 30–40 range (up to 41 possible).

- [ ] **Step 3: Run the full test_motion_vibe.py file, expect 1 known-failing test (clamps_at_edges)**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: ONE failure in `test_init_scheme_c_clamps_at_edges` (still uses old bounds `<= 7` and `>= 247`; we'll fix it next). All other tests should PASS — including the determinism tests and the K=8 init tests.

If any other test fails (especially the K=8 ones), STOP and investigate before continuing.

---

### Task 3: Update the edge-clamp test to use the new bounds

**Files:**
- Modify: `py/tests/test_motion_vibe.py:35-49` (the `test_init_scheme_c_clamps_at_edges` function)

- [ ] **Step 1: Replace the test body**

In `py/tests/test_motion_vibe.py`, replace `test_init_scheme_c_clamps_at_edges`:

```python
def test_init_scheme_c_clamps_at_edges():
    """Samples clamp to [0, 255] when current ± noise would overflow."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    # Frame value 0 → samples in [-20, +20] → clamped to [0, 20].
    v.init_from_frame(_y_frame(0))
    assert v.samples.min() == 0
    assert v.samples.max() <= 20

    # Frame value 255 → samples in [235, 275] → clamped to [235, 255].
    v2 = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
              init_scheme="c", prng_seed=0xDEADBEEF)
    v2.init_from_frame(_y_frame(255))
    assert v2.samples.min() >= 235
    assert v2.samples.max() == 255
```

- [ ] **Step 2: Run the full test_motion_vibe.py file**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: ALL tests PASS.

If any test fails, STOP and investigate.

---

### Task 4: Add regression test that K=20 slots k=8..19 are NOT degenerate

**Files:**
- Modify: `py/tests/test_motion_vibe.py` (append new test)

This protects against the latent slot-degenerate bug being reintroduced.

- [ ] **Step 1: Add the new test**

Append to `py/tests/test_motion_vibe.py`:

```python
def test_init_scheme_c_k20_slots_not_degenerate():
    """K=20 init must produce noisy values for ALL slots, including k≥8.

    Regression test for the prior slot-degenerate bug: under the old 4-bit-lane
    code, slots k=8..19 all collapsed to `clamp(y - 8, 0, 255)` because
    `(state >> (4*k)) & 0xF == 0` for any k ≥ 8 on a 32-bit state.
    """
    v = ViBe(K=20, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    frame_0 = _y_frame(128, h=4, w=4)
    v.init_from_frame(frame_0)
    # Slots k=8..19 must NOT all be the same value (the prior bug made them all 120).
    high_slots = v.samples[:, :, 8:]  # (H, W, 12)
    unique_in_high = np.unique(high_slots)
    assert unique_in_high.size > 4, \
        f"K=20 slots k=8..19 are degenerate (only {unique_in_high.size} unique values) — regression of prior bug"
```

- [ ] **Step 2: Run the new test**

```bash
pytest py/tests/test_motion_vibe.py::test_init_scheme_c_k20_slots_not_degenerate -v
```

Expected: PASS — under the new ceil(K/4)=5 PRNG-advance scheme, slots k=8..19 are noisy.

---

### Task 5: Add empirical noise-coverage test

**Files:**
- Modify: `py/tests/test_motion_vibe.py` (append new test)

This sanity-checks the modulo-41 distribution isn't producing a degenerate output range.

- [ ] **Step 1: Add the new test**

Append to `py/tests/test_motion_vibe.py`:

```python
def test_init_scheme_c_noise_covers_full_range():
    """Across a 64×64 init at K=8, observed noise covers ≥ 90% of [-20, +20]."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    # Use mid-range (128) to avoid clamping, large grid for statistical coverage.
    frame_0 = _y_frame(128, h=64, w=64)
    v.init_from_frame(frame_0)
    noises = v.samples.astype(int) - 128  # recover signed noise per slot
    expected_values = set(range(-20, 21))  # 41 values
    observed = set(int(n) for n in np.unique(noises))
    coverage = len(observed & expected_values) / len(expected_values)
    assert coverage >= 0.90, \
        f"Noise coverage only {coverage:.2%} of [-20, +20] — distribution too narrow"
    # Sanity: nothing observed outside the band.
    assert min(observed) >= -20 and max(observed) <= 20, \
        f"Noise out of band: {min(observed)}..{max(observed)}"
```

- [ ] **Step 2: Run the new test**

```bash
pytest py/tests/test_motion_vibe.py::test_init_scheme_c_noise_covers_full_range -v
```

Expected: PASS — at 64×64×8 = 32,768 slots and 41 possible values, coverage should be 100%.

- [ ] **Step 3: Run the full test_motion_vibe.py file**

```bash
pytest py/tests/test_motion_vibe.py -v
```

Expected: ALL tests PASS (33 tests).

- [ ] **Step 4: Run the full project test suite**

```bash
pytest py/tests
```

Expected: ALL tests PASS, no regressions in any other module.

- [ ] **Step 5: Commit**

```bash
git add py/experiments/motion_vibe.py py/tests/test_motion_vibe.py
git commit -m "feat(experiments): widen init noise to ±20 + fix K>8 slot-degenerate bug

scheme (c) now uses ceil(K/4) PRNG advances per pixel during init,
8-bit lanes, byte%41-20 → [-20, +20], matching upstream's randint(-20, 20).
Eliminates the prior latent bug where K=20 slots k=8..19 all collapsed
to clamp(y-8, 0, 255)."
```

---

### Task 6: Change `run_k_comparison` source to `synthetic:noisy_moving_box`

**Files:**
- Modify: `py/experiments/run_phase0.py:191-206` (`run_k_comparison` function)

- [ ] **Step 1: Replace the function**

In `py/experiments/run_phase0.py`, replace `run_k_comparison`:

```python
def run_k_comparison(out_root: str = "py/experiments/our_outputs/k_comparison",
                     upstream_root: str = "py/experiments/upstream_baseline_outputs",
                     num_frames: int = 200):
    """Compare K=8 vs K=20 on noisy_moving_box (real motion + per-pixel noise).

    Includes upstream parity check (upstream is captured at K=20). The K=8 row
    therefore tells us the parity cost of dropping K vs the K=20 baseline.
    """
    src = "synthetic:noisy_moving_box"
    upstream_dir = os.path.join(upstream_root, src.replace(":", "_"))
    upstream = upstream_dir if os.path.isdir(upstream_dir) else None
    results = {}
    for K in (8, 20):
        out_dir = os.path.join(out_root, f"K{K}")
        result = run_source(
            source=src, num_frames=num_frames, K=K,
            out_dir=out_dir,
            upstream_masks_dir=upstream,
        )
        results[K] = result
        avg = result["coverage_curve_ours"].mean()
        steady = result["coverage_curve_ours"][32:].mean()
        line = f"  K={K}: avg={avg:.3f}  steady-state(32+)={steady:.3f}"
        if "coverage_curve_upstream" in result:
            up = result["coverage_curve_upstream"]
            ours = result["coverage_curve_ours"]
            per_frame_diff = float(np.abs(ours - up).mean())
            line += f"  |ours-upstream|={per_frame_diff:.4f}"
        print(line)
    return results
```

- [ ] **Step 2: Run the k_comparison matrix**

```bash
source .venv/bin/activate && python py/experiments/run_phase0.py --matrix k_comparison
```

Expected output: two non-zero `avg` values (the source has ~6% real motion). For example (numbers will vary):
```
=== K=8 vs K=20 stress-test ===
  K=8: avg=0.071  steady-state(32+)=0.069  |ours-upstream|=0.0050
  K=20: avg=0.065  steady-state(32+)=0.063  |ours-upstream|=0.0020
```

If both averages are 0 or identical, STOP — the source change didn't take effect.

- [ ] **Step 3: Verify output PNGs were written**

```bash
ls -la py/experiments/our_outputs/k_comparison/K8/grid.png py/experiments/our_outputs/k_comparison/K20/grid.png
```

Expected: both files exist with non-zero size.

- [ ] **Step 4: Commit**

```bash
git add py/experiments/run_phase0.py
git commit -m "feat(experiments): k_comparison uses noisy_moving_box (textured_static was 0/0)"
```

---

### Task 7: Add `run_phi_diffuse_sweep` driver

**Files:**
- Modify: `py/experiments/run_phase0.py` (append new function and update argparse)

- [ ] **Step 1: Add helper for "first-cleared-frame" calculation**

In `py/experiments/run_phase0.py`, after `_load_mask_sequence`, add:

```python
def _first_cleared_frame(coverage: np.ndarray, threshold: float = 0.005,
                         consecutive: int = 8) -> int:
    """Return first frame index F such that coverage[F:F+consecutive] all < threshold.

    Returns len(coverage) if the ghost never clears within the window.
    """
    n = len(coverage)
    for f in range(n - consecutive + 1):
        if np.all(coverage[f:f + consecutive] < threshold):
            return f
    return n
```

- [ ] **Step 2: Add the sweep driver**

After `run_init_scheme_comparison`, append:

```python
def run_phi_diffuse_sweep(
    out_root: str = "py/experiments/our_outputs/phi_diffuse_sweep",
    upstream_root: str = "py/experiments/upstream_baseline_outputs",
    num_frames: int = 200,
):
    """Sweep phi_diffuse over {16, 8, 4, 2, 1} on synthetic:ghost_box_disappear
    with coupled_rolls=False to characterize ghost-decay control.

    Renders one combined grid (5 ours-rows + upstream + ema) and one combined
    coverage plot. Prints per-φ first-cleared-frame metric.
    """
    os.makedirs(out_root, exist_ok=True)
    src = "synthetic:ghost_box_disappear"
    width, height = 320, 240

    # Load frames once (deterministic; same source for every φ).
    frames_rgb = load_frames(src, width=width, height=height, num_frames=num_frames)
    frames_y = [_rgb_to_y(f) for f in frames_rgb]

    # Run our ViBe at each phi_diffuse value.
    phi_values = [16, 8, 4, 2, 1]
    rows = []
    curves = {}
    print("=== phi_diffuse sweep on", src, "(coupled_rolls=False) ===")
    for phi in phi_values:
        v = ViBe(
            K=20, R=20, min_match=2,
            phi_update=16, phi_diffuse=phi,
            init_scheme="c", prng_seed=0xDEADBEEF,
            coupled_rolls=False,
        )
        v.init_from_frame(frames_y[0])
        masks = [np.zeros_like(frames_y[0], dtype=bool)]
        for f in frames_y[1:]:
            masks.append(v.process_frame(f))
        rows.append((f"ours φd={phi}", masks))
        cov = coverage_curve(masks)
        curves[f"ours φd={phi}"] = cov
        cleared = _first_cleared_frame(cov)
        cleared_str = f"{cleared}" if cleared < num_frames else f">{num_frames}"
        print(f"  φd={phi}: avg={cov.mean():.3f}  first-cleared-frame={cleared_str}")

    # Upstream reference (canonical ViBe, K=20, coupled-rolls under the hood).
    upstream_dir = os.path.join(upstream_root, src.replace(":", "_"))
    if os.path.isdir(upstream_dir):
        masks_up = _load_mask_sequence(upstream_dir, num_frames)
        rows.append(("upstream (canonical)", masks_up))
        curves["upstream (canonical)"] = coverage_curve(masks_up)

    # EMA baseline for reference.
    masks_ema = run_ema_baseline(frames_y)
    rows.append(("ema", masks_ema))
    curves["ema"] = coverage_curve(masks_ema)

    # Render combined grid + coverage plot.
    render_grid(frames_rgb, rows, out_path=os.path.join(out_root, "grid.png"))
    render_coverage_curves(
        curves, out_path=os.path.join(out_root, "coverage.png"),
        title=f"{src} | phi_diffuse sweep | coupled_rolls=False",
    )
    return curves
```

- [ ] **Step 3: Update the argparse choices**

In the `if __name__ == "__main__":` block, replace the choices list:

```python
    p.add_argument("--matrix", choices=[
        "synthetic", "real", "k_comparison", "negative_control",
        "init_schemes", "phi_diffuse_sweep", "all"
    ], default="synthetic")
```

And add the dispatch block before the final `init_schemes` dispatch:

```python
    if args.matrix in ("phi_diffuse_sweep", "all"):
        print("=== phi_diffuse sweep ===")
        run_phi_diffuse_sweep()
```

- [ ] **Step 4: Run the new sweep**

```bash
source .venv/bin/activate && python py/experiments/run_phase0.py --matrix phi_diffuse_sweep
```

Expected output (numbers will vary; trend should be monotonic-ish):
```
=== phi_diffuse sweep ===
=== phi_diffuse sweep on synthetic:ghost_box_disappear (coupled_rolls=False) ===
  φd=16: avg=0.0XX  first-cleared-frame=>200
  φd=8:  avg=0.0XX  first-cleared-frame=>200 or NNN
  φd=4:  avg=0.0XX  first-cleared-frame=NNN
  φd=2:  avg=0.0XX  first-cleared-frame=NNN
  φd=1:  avg=0.0XX  first-cleared-frame=NNN (smallest)
```

- [ ] **Step 5: Verify output PNGs**

```bash
ls -la py/experiments/our_outputs/phi_diffuse_sweep/grid.png py/experiments/our_outputs/phi_diffuse_sweep/coverage.png
```

Expected: both files exist with non-zero size.

- [ ] **Step 6: Commit**

```bash
git add py/experiments/run_phase0.py
git commit -m "feat(experiments): phi_diffuse sweep on ghost_box_disappear (coupled_rolls=False)"
```

---

### Task 8: Re-run synthetic + real matrices to capture new numbers

**Files:** No code changes; this task only re-runs experiments.

- [ ] **Step 1: Re-run synthetic matrix**

```bash
source .venv/bin/activate && python py/experiments/run_phase0.py --matrix synthetic
```

Expected: 7 lines, one per source. Capture the printed `ours_avg / ema_avg / upstream_avg` triples for the results-doc update.

- [ ] **Step 2: Re-run real matrix**

```bash
python py/experiments/run_phase0.py --matrix real
```

Expected: 3 lines (birdseye, people, intersection). Capture the printed numbers.

- [ ] **Step 3: Re-run summarize_phase0**

```bash
python py/experiments/summarize_phase0.py
```

Expected: per-source `|ours - upstream|` table — capture this output for the results-doc table update.

- [ ] **Step 4: Re-run init_schemes comparison**

```bash
python py/experiments/run_phase0.py --matrix init_schemes
```

Expected: 6 lines (2 sources × 3 schemes). Capture the new averages for the init-schemes table.

- [ ] **Step 5: Re-run negative_control**

```bash
python py/experiments/run_phase0.py --matrix negative_control
```

Expected: 1 line. Capture the number.

- [ ] **Step 6: Sanity-check the lighting_ramp parity gap closed (or shrunk)**

The whole point of Task 1–5 was to close the `lighting_ramp` outlier (was `|ours-upstream| = 0.0630` per the prior results doc). Verify in the summarize_phase0 output.

- If `|ours-upstream|` on `lighting_ramp` is now `≤ 0.013` (matching the other sources): full success — note in the results-doc update.
- If it dropped substantially but is still > 0.013: partial success — note the residual gap in the results doc as a remaining (smaller) discrepancy and document the likely root cause (modulo-41 non-uniformity, or upstream's matchingNumber-exact-slots subtlety we didn't replicate).
- If it didn't drop (or went up): STOP — investigate before continuing. This means our hypothesis ("init noise width is the cause") was wrong.

---

### Task 9: Update the results doc

**Files:**
- Modify: `docs/plans/2026-05-04-vibe-phase-0-results.md`

This is a doc-only edit using numbers captured in Task 8.

- [ ] **Step 1: Update the header date / "what changed" bullets**

In the prior results doc, find the existing list "What changed since the original 2026-05-04 verdict" (currently 4 bullets). Add a 5th bullet:

```markdown
5. **Init noise width widened from ±8 to ±20 + K>8 slot-degenerate bug fix.**
   Scheme (c) now uses 8-bit lanes with `byte % 41 - 20` and ceil(K/4) PRNG
   advances per pixel during init. Eliminates the prior bug where K=20 slots
   k=8..19 all collapsed to `clamp(y-8, 0, 255)`. See
   [`2026-05-05-vibe-phase-0-redo-design.md`](2026-05-05-vibe-phase-0-redo-design.md)
   for the full rationale.
```

- [ ] **Step 2: Update the per-source cross-check table**

Find the table starting `| Source | ours avg | upstream avg | EMA avg | per-frame |ours − upstream| |`. Replace every numeric cell with the corresponding number from `summarize_phase0.py` output captured in Task 8 step 3. Update the prose immediately after the table:

- If the `lighting_ramp` outlier closed (≤0.013), change the "Nine out of ten sources..." sentence to "All ten sources show per-frame `|diff| ≤ 0.013` after the init-noise widening."
- If it shrunk but didn't fully close, update the sentence to reflect the new max.

- [ ] **Step 3: Update the "Init-noise-width discrepancy" section**

Replace the section currently titled `## Init-noise-width discrepancy (the lighting_ramp outlier — TODO)`.

- If outlier closed: re-title to `## Init-noise-width discrepancy — RESOLVED` and replace the body with a 2-paragraph note: (1) what was fixed, (2) the resulting numbers vs. the previous run.
- If outlier shrunk but persists: re-title to `## Init-noise-width discrepancy — partially closed` and document the residual.

- [ ] **Step 4: Replace the K-comparison paragraph**

Find the section `## K=8 vs K=20 stress-test`. Replace its body with the new `synthetic:noisy_moving_box` numbers from Task 6 step 2 output. Add a sentence about K=8 vs K=20 parity drift vs. upstream.

- [ ] **Step 5: Add a new section "Ghost-decay control sweep"**

After the K-comparison section, insert:

```markdown
## Ghost-decay control sweep (`synthetic:ghost_box_disappear`)

Sweep over `phi_diffuse` ∈ {16, 8, 4, 2, 1} with `coupled_rolls=False`,
`phi_update=16`, K=20, init scheme c. Source: frame 0 has bright box at
center; frames 1+ are pure black (canonical frame-0-ghost stress).

| phi_diffuse | per-pixel-per-frame fire prob | avg coverage | first cleared frame |
|---|---|---|---|
| 16 | 6.25% | 0.XXX | >200 |
| 8  | 12.5% | 0.XXX | NNN |
| 4  | 25%   | 0.XXX | NNN |
| 2  | 50%   | 0.XXX | NNN |
| 1  | 100%  | 0.XXX | NNN |

"First cleared frame" = first frame F at which coverage stays below 0.005
for 8 consecutive frames. `>200` means the ghost did not clear within the
200-frame window.

Visual + curves: `py/experiments/our_outputs/phi_diffuse_sweep/{grid,coverage}.png`.

**Takeaway:** Ghost decay is monotonically faster as `phi_diffuse` decreases.
The canonical-ViBe `phi_diffuse=16` is on the slow end. The cost of
aggressive `phi_diffuse` is faster sample-bank churn — see Phase 2 Doc B
analysis for the false-positive tradeoff on real clips.
```

Replace the `0.XXX` and `NNN` cells with the actual numbers from Task 7 step 4 output.

- [ ] **Step 6: Update the Open TODOs table**

In the `## Open TODOs (deferred to Phase 1 / writing-plans)` table, remove the `**Init noise width: widen scheme (c) from ±8 to ±20**` row entirely (resolved). Add a new row above (or replace it with):

```markdown
| **Final RTL phi_diffuse choice** | The phi_diffuse sweep (this re-do) is informational. Final RTL knob choice balances ghost decay vs. real-clip false-positive rate; defer to writing-plans for Phase 2. | None — design decision in Phase 2. |
```

- [ ] **Step 7: Spot-check the doc renders**

```bash
grep -n "TODO\|TBD\|XXX\|NNN\|0\.XXX" docs/plans/2026-05-04-vibe-phase-0-results.md
```

Expected: no matches (other than the legitimate "TODO" in the surviving Open-TODOs section, if any). If `XXX/NNN/0.XXX` appears, you forgot to fill in actual numbers.

- [ ] **Step 8: Commit**

```bash
git add docs/plans/2026-05-04-vibe-phase-0-results.md
git commit -m "docs(plans): Phase 0 results — re-do with ±20 init noise + phi_diffuse sweep"
```

---

### Task 10: Final verification

**Files:** No code changes.

- [ ] **Step 1: Run the full project test suite**

```bash
source .venv/bin/activate && pytest py/tests
```

Expected: ALL tests PASS (≥182 + 2 new = ≥184). No regressions.

- [ ] **Step 2: Verify all expected output PNGs exist**

```bash
ls py/experiments/our_outputs/phi_diffuse_sweep/grid.png \
   py/experiments/our_outputs/phi_diffuse_sweep/coverage.png \
   py/experiments/our_outputs/k_comparison/K8/grid.png \
   py/experiments/our_outputs/k_comparison/K20/grid.png \
   py/experiments/our_outputs/synthetic/synthetic_lighting_ramp/grid.png
```

Expected: all 5 paths exist.

- [ ] **Step 3: Print the final git log of this re-do**

```bash
git log --oneline feat/vibe-motion-design ^origin/main | head -10
```

Expected: 4 new commits from this plan (test+impl, k_comparison, phi_diffuse_sweep, results-doc) plus the design-doc commit from before. Plus all the pre-existing Phase 0 commits.

- [ ] **Step 4: Inspect the updated results doc**

Open `docs/plans/2026-05-04-vibe-phase-0-results.md` and read end-to-end. Confirm:
- Per-source table has new numbers, no `XXX`.
- Init-noise section no longer says "TODO" / "outlier".
- K-comparison section uses noisy_moving_box numbers.
- Ghost-decay sweep section is present with all 5 phi values filled.

If anything looks wrong, fix it inline and amend the doc commit.

- [ ] **Step 5: Done**

The re-do is complete. All three user-requested refinements are landed; results doc is up to date. Branch stays at `feat/vibe-motion-design` for the eventual Phase 0 PR squash.
