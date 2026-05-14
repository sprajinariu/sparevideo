# ViBe with persistence-based foreground demotion — design

**Date:** 2026-05-12
**Status:** Design (pre-implementation)
**Branch:** `feat/vibe-demote-python` (off `origin/main`)
**Background:**
- [`2026-05-11-vibe-ghost-rescue-addendum.md`](2026-05-11-vibe-ghost-rescue-addendum.md) — Phase A lessons; lookahead-median is a synthetic shortcut, not a destination
- [`2026-05-11-pbas-python-design.md`](2026-05-11-pbas-python-design.md) — PBAS Python ref + comparison runner whose structure this plan mirrors

## 1. Motivation

The project's current best frame-0 ghost mitigation is `vibe_init_external`
(look-ahead temporal-median priming of the ViBe sample bank). Empirically it
works, but it is a **synthetic shortcut** with two real-data failure modes:

1. **High-traffic regions.** Temporal-median assumes the background dominates
   a pixel's history. In short clips (~5–7 seconds) of busy scenes, foreground
   objects often occupy a pixel for most of the lookahead window — the median
   then bakes the object *into* the background, producing ghosts on departure.
2. **Forward ghosts.** Objects that linger or stop for much of the clip
   poison the median's bg estimate even more strongly. The median has no
   notion of "this was a foreground event, exclude from bg estimation."

PBAS (`pbas_default`) partially mitigates ghosts via adaptive `T(x)` that
accelerates outside-in diffusion. But on real clips it leaves **persistent
ghost interiors** that linger for the duration of the clip and interfere with
real motion detection in those regions. This is mechanistic: PBAS, ViBe, ViBe+,
and SuBSENSE all gate bank updates on **bg-classified pixels only**. None of
them directly resets ghost-interior pixels — they all rely on diffusion from
the bg-classified exterior, with geometry that takes much longer than 150
frames for typical-size ghosts.

This plan adds a different mechanism: **persistence-based foreground demotion
with neighbor-bank-consistency gating** (working name `vibe_demote`, internally
"B'"). A foreground-classified pixel that has stayed FG for `K_persist` frames
*and* whose current observation matches a confident bg-classified neighbor's
bank sample is **demoted to bg**, with its own bank deterministically seeded
with the current pixel value. This produces a fast outside-in wavefront that
dissolves ghosts in `K_persist + r` frames (where `r` is the ghost radius),
without resorting to lookahead.

The mechanism is engineering-derived, not lifted from a single published
algorithm. The primitives are validated by published work (PAWCS's
neighbor-bank consistency for word-importance scoring; ViBe's own neighbor
diffusion mechanism), but the *inversion* — using neighbor consistency to
**demote** persistent FG rather than to score word importance — is this
project's engineering choice. We accept that the "high certainty of a working
model" criterion is met by mechanism-level reasoning and empirical validation,
not by direct citation. See §9 for the honest grounding discussion.

## 2. Scope

**In scope.**
- Extend `py/models/ops/vibe.py` with a `vibe_demote_en`-gated B' path.
- Add 4 new `cfg_t` fields and one new profile (`vibe_demote`).
- Mirror cfg fields into `hw/top/sparevideo_pkg.sv` (Phase-A-style shadow;
  no RTL implementation in this plan).
- Unit tests for the demotion path, including a bit-exact regression that
  `vibe_demote_en=0` is equivalent to canonical ViBe.
- Python comparison runner against `vibe_init_frame0`, `vibe_init_external`,
  and `pbas_default` on real-clip sources (`birdseye`, `people`).
- Labelled animated WebP demos for `birdseye` and `people`.
- Results doc and GO / NO-GO decision.

**Out of scope.**
- RTL implementation. Deferred to a follow-up plan contingent on GO.
- RGB ViBe and RGB B'. Deferred to a separate Phase 2 plan that will also
  close the Y-only deviation in the existing PBAS operator.
- Composition with `vibe_init_external` (a `vibe_demote_external` profile).
  This plan answers "does B' alone beat lookahead alone?" without
  confounding.
- New `ctrl_flow` modules. The comparison is at the mask level.
- Modifications to the existing PBAS or canonical ViBe operators beyond the
  shared cfg parity test.

## 3. Algorithm — Y-only B' on canonical ViBe

### 3.1 New per-pixel state

A single uint8 counter is added on top of canonical ViBe's K-slot sample
bank.

| State | Type | Init | Role |
|---|---|---|---|
| `fg_count[r,c]` | uint8, saturating at 255 | 0 | consecutive FG-classified frames |

Total state delta over canonical ViBe: 1 byte/pixel.

### 3.2 Per-pixel per-frame procedure (additions to canonical ViBe)

Runs after canonical ViBe has classified the current pixel.

1. **Counter update.**
   - If classified FG: `fg_count[r,c] = min(fg_count[r,c] + 1, 255)`.
   - If classified BG: `fg_count[r,c] = 0`.
2. **Demotion eligibility.** Skip steps 3–4 unless `classified == FG AND
   fg_count[r,c] >= K_persist`.
3. **Neighbor-bank-consistency check.** Scan the
   `vibe_demote_kernel`-sized neighborhood centered on `(r,c)`, excluding the
   center. For each neighbor `(r',c')`:
   - Use the **previous frame's `final_bg` map** (defined in step 5;
     registered, not same-frame combinational — for RTL portability).
   - Skip neighbors whose previous-frame `final_bg` was 0 (FG).
   - Count slots `k ∈ [0,K)` of `samples[r',c',k]` where `|Y[r,c] -
     samples[r',c',k]| < R` (ViBe's existing match radius).
   - If count ≥ `vibe_demote_consistency_thresh`, demotion **fires** —
     short-circuit, no need to check more neighbors.
4. **Demotion action (Candidate 1 — deterministic write).** When fired:
   - Pick a random slot `k` (existing PRNG path), write `samples[r,c,k] =
     Y[r,c]`. Single-slot write — seeds the bank with the current
     observation, lets future canonical classification flip to bg as bank
     slots accumulate.
   - **Do NOT reset `fg_count[r,c]`.** Letting demote re-fire on subsequent
     frames is what produces the wavefront described in §3.4. Resetting
     would stall the wavefront for another `K_persist` frames.
   - **Do NOT** trigger the neighbor-diffusion-write that canonical
     bg-classified pixels perform. Cascade risk: one mis-demotion could
     propagate across a region in a single frame. Keep demotion's effect
     local to the demoted pixel's own bank; let canonical ViBe dynamics
     propagate on subsequent frames.
5. **Final classification.** The output of the operator at pixel `(r,c)`,
   *and* the value of the classification map registered for next-frame
   neighbor checks at step 3, is:

   `final_bg[r,c] = canonical_bg[r,c] OR demote_fire[r,c]`

   So a demoted pixel reports as bg on the demote-fire frame itself (output
   mask = 0; ghost dissolves visibly without a one-frame lag). The
   next-frame neighbor check on adjacent inner-ring pixels also reads this
   pixel as previously-bg, which is what makes the wavefront advance one
   ring per frame at `consistency_thresh = 1` (see §3.4).

### 3.3 Initialization

Same as canonical ViBe: frame-0 hard-init (so frame-0 ghosts form, then B'
resolves them). `vibe_demote_en=1` does not interact with the init phase.

### 3.4 Wavefront dynamics

For a ghost region of radius `r`:

- **Frame `K_persist`.** Outermost ring `R(0)` has non-ghost BG-classified
  neighbors (in the surrounding real bg). Their banks contain real-bg
  samples that match `R(0)`'s current Y (which is also real-bg, now that the
  object has moved). Consistency check passes (at threshold = 1, a single
  matching slot suffices). Demote fires. One slot of `R(0)`'s bank is
  written with real-bg Y.
- **Frame `K_persist + 1`.** Canonical classifier re-evaluates `R(0)`. Bank
  now has 1 real-bg slot + (K-1) frame-0 object slots. Match count = 1.
  Canonical match threshold is typically 2 (`Raute_min`), so still FG
  canonically. But `fg_count` ≥ K_persist, consistency check still passes
  (real-bg neighbors unchanged), and demote re-fires. A second bank slot is
  written.

  Meanwhile, `R(1)` (the next inner ring) checks its previous-frame
  neighbors. `R(0)` was demote-classified-BG at frame `K_persist` (the
  previous frame's *final* classification). `R(0)`'s bank at the start of
  frame `K_persist + 1` has 1 real-bg slot. `R(1)`'s consistency check
  passes (at threshold = 1). `R(1)` fires.
- **Frame `K_persist + 2`.** `R(0)` is canonically BG (2 real-bg slots ≥
  `Raute_min`). `R(1)` is 1 frame into its demote sequence. `R(2)` starts
  its sequence.
- ...
- **Frame `K_persist + r`.** Deepest interior pixel fires. Ghost fully
  dissolved.

**Total dissolution time = `K_persist + r` frames.** At default `K_persist =
30`, a 30-radius person-sized ghost dissolves by frame 60 of the clip — well
inside a 150-frame (5s @ 30fps) window. A 120-radius ghost dissolves by
frame 150, the clip boundary.

The wavefront propagation rate is set by **`vibe_demote_consistency_thresh`**:
- `= 1` (default): 1 ring per frame after `K_persist`.
- `= 2`: 2 frames per ring (wait for two real-bg slots in prior ring's bank).
- General: `consistency_thresh` frames per ring.

### 3.5 Determinism

Deterministic-under-fixed-seed property of canonical ViBe is preserved: the
demotion's only randomness is the single-slot bank-write at step 4, which
uses the existing PRNG stream. Two runs of `vibe_demote` with the same seed
produce bit-identical masks.

### 3.6 Why this discriminates ghosts from slow-moving uniform objects

The neighbor-bank-consistency check distinguishes the two failure modes:

- **Ghost interior pixel.** Current Y is real-bg (object has moved). The
  surrounding pixels (outside the ghost) are canonically BG and their banks
  contain real-bg samples matching current Y. Consistency check passes →
  demote fires correctly.
- **Slow-moving uniform-color object's interior pixel.** Current Y is
  object-color. The surrounding pixels (outside the object) are canonically
  BG and their banks contain bg-color samples — not object-color.
  Consistency check fails → no false demotion.

The mechanism does **not** distinguish ghosts from real *stopped* objects (a
person who genuinely stops for ≥ K_persist frames will be absorbed into bg).
This matches the long-standing convention in bg-subtraction literature
("stopped objects eventually become background"). For the 5-second clip use
case, this is acceptable.

The remaining edge case is **low-contrast objects on similar-colored bg**
(object color within ViBe's R radius of neighbor banks' samples). B' demotes
these faster than canonical ViBe — but canonical ViBe already barely
detects them as FG to begin with, so B' shifts an existing failure quantitatively
without introducing a new failure class. Phase 2 (RGB) further reduces this
failure mode by tightening the per-channel match radius.

## 4. `cfg_t` and profile diff

### 4.1 New cfg fields

Added to `hw/top/sparevideo_pkg.sv` and mirrored in `py/profiles.py` (the
existing `test_profiles.py` parity test catches drift).

| Field | Type | Default in canonical profiles | Default in `vibe_demote` | Role |
|---|---|---|---|---|
| `vibe_demote_en` | `logic` | 0 | 1 | gate the entire B' mechanism |
| `vibe_demote_K_persist` | `logic [7:0]` | 30 | 30 | persistence threshold (~1s @ 30fps) |
| `vibe_demote_kernel` | enum {3,5} | 3 | 3 | neighborhood size for consistency check |
| `vibe_demote_consistency_thresh` | `logic [3:0]` | 1 | 1 | min matching bank slots in BG neighbor to fire |

Field naming follows the existing `vibe_*` prefix convention in `cfg_t`.

### 4.2 New profile

| Profile | `bg_model` | `vibe_demote_en` | Init | Role |
|---|---|---|---|---|
| `vibe_demote` *(NEW)* | 1 (ViBe) | 1 | frame-0 hard-init | core test — B' alone, no lookahead crutch |

All existing profiles (`default`, `default_vibe`, `vibe_init_external`,
`pbas_default`, `pbas_lookahead`, etc.) set `vibe_demote_en = 0` and are
bit-exact regression-preserved by the `test_demote_disabled_bit_exact_canonical_vibe`
test (§5).

**Deliberately not added in this plan:** a `vibe_demote_external` profile
combining B' with lookahead-median init. The Phase 1 question is "does B'
alone beat lookahead alone?" Composition is a natural Phase 2 candidate if
the experiment justifies it.

## 5. File structure

```
py/models/ops/vibe.py                          — extend with vibe_demote_en-gated path
py/profiles.py                                 — add 4 cfg fields + vibe_demote profile
hw/top/sparevideo_pkg.sv                       — mirror cfg_t fields (shadow only)
py/tests/test_vibe_demote.py                   — unit tests
py/experiments/run_vibe_demote_compare.py      — comparison runner
py/viz/render_vibe_demote_compare_webp.py      — labelled WebP renderer
docs/plans/2026-05-XX-vibe-demote-results.md   — results doc (post-experiment)
```

**Implementation choice — extend `vibe.py` rather than fork.** The state
delta is one uint8/pixel; the logic delta is one neighbor scan + one
conditional bank write. A separate `vibe_demote.py` would double the
maintenance surface (Phase 2 RGB-ification, future RTL parity, future
profile additions) for no testability benefit — the bit-exact regression
test is cleaner on a single gated operator than on two parallel files.

## 6. Unit tests (`py/tests/test_vibe_demote.py`)

| Test | Purpose |
|---|---|
| `test_demote_disabled_bit_exact_canonical_vibe` | With `vibe_demote_en=0`, `vibe.process_frame()` is byte-for-byte equal to canonical ViBe over a multi-frame sequence. **The core regression gate.** |
| `test_fg_count_increments_and_resets` | Per-pixel: increments on FG frames, resets on BG, saturates at 255. Drive a controlled FG/BG pattern at one pixel and observe the counter. |
| `test_demote_fires_after_K_persist_at_ghost_edge` | Construct a synthetic frame-0 ghost (prime bank with object samples, run real-bg frames). Verify that at frame `K_persist`, the outermost ring pixels demote (one bank slot written with the real-bg value). Use `K_persist = 4` for fast tests. |
| `test_wavefront_propagates_one_ring_per_frame` | Same synthetic ghost. Verify that ring `i` demotes at frame `K_persist + i`. Cover `r = 0..5` in one test. |
| `test_no_demotion_when_no_BG_neighbor` | A pixel surrounded entirely by FG-classified pixels — `fg_count` exceeds `K_persist` but consistency check fails. Counter keeps incrementing past `K_persist` with no demotion. |
| `test_slow_moving_uniform_object_not_demoted` | Construct a uniform-color object (interior pixel value differs from bg by > R) moving slowly across the frame. Verify the object's interior never demotes. |
| `test_consistency_thresh_2_doubles_propagation_time` | With `vibe_demote_consistency_thresh = 2`, the wavefront takes 2 frames per ring instead of 1. Validates the parameter is wired correctly. |
| `test_demote_deterministic_under_fixed_seed` | Two runs with the same seed produce bit-identical masks. Verifies the new code path didn't introduce non-determinism. |

The first test is non-negotiable: it gates every existing profile against
regression. The fourth test (wavefront propagation) is the empirical
verification of §3.4's timing math.

## 7. Empirical comparison and demos

### 7.1 Sources and run length

- `media/source/birdseye-320x240.mp4` — high-traffic birds-eye real footage.
- `media/source/people-320x240.mp4` — people walking, ghost-prone real footage.

**Run length: 200 frames per source** (~6.7s at 30fps), matching the PBAS
comparison. The window comfortably contains worst-case dissolution
(`K_persist=30` + ghost_radius up to ~170 pixels) plus a steady-state tail
for the asymptote metric.

Synthetic `ghost_box_*` sources are excluded: they exercise the mechanism in
testing (§6) but do not answer the production question.

### 7.2 Methods compared

| Method | Init | bg_model | Role |
|---|---|---|---|
| `vibe_init_frame0` | frame-0 hard-init | ViBe | no-fix baseline |
| `vibe_init_external` | look-ahead median | ViBe | synthetic-shortcut gold standard (the one this plan aims to retire) |
| `pbas_default` | first-N frames | PBAS | non-lookahead published online method already in tree |
| `vibe_demote` *(NEW)* | frame-0 hard-init | ViBe + B' | the candidate |

`pbas_lookahead` is **not** included — comparing two lookahead methods
against `vibe_demote` would add noise to the "online-only" decision.

### 7.3 Per-source artefacts

Under `py/experiments/our_outputs/vibe_demote_compare/<source>/`:

- `coverage.png` — 4-curve overlay (frame number vs mean mask coverage).
- `convergence_table.csv` — per method: asymptote (mean of last 50 frames),
  peak coverage during convergence, time-to-1%-coverage (frame index at
  which coverage first drops below 1%).
- `coverage_by_region.csv` — *new vs the PBAS comparison:* coverage split
  into "high-traffic" vs "low-traffic" regions, where a region is
  high-traffic if the time-averaged FG-classification mask exceeds 50% over
  the clip. Directly tests the high-traffic motivation in §1.

Under `media/demo/`:

- `vibe-demote-compare-<source>.webp` — 200-frame animated WebP, 4-up
  labelled side-by-side. Uses `py/viz/render.py`'s labelled-row helper.

### 7.4 Optional K_persist sweep

Behind a CLI flag in `run_vibe_demote_compare.py`: re-runs the `vibe_demote`
method with `K_persist ∈ {15, 30, 60, 120}` on each source, producing a fan
of coverage curves. Useful for validating the chosen default and surfacing
the speed/safety tradeoff. Skipped by default in the canonical comparison.

### 7.5 Decision criterion

`vibe_demote` is a **GO** for an RTL follow-up plan iff, on **both** real
sources:

1. Lower asymptotic coverage (mean of frames 150–199 of the 200-frame run)
   than `vibe_init_external`, AND
2. Lower asymptotic coverage than `pbas_default`, AND
3. No worse peak coverage during convergence than `vibe_init_external`
   (i.e., ghost-dissolution speed is not paid for by suppressing legitimate
   motion masks).

**Partial GO** (`vibe_demote` beats `pbas_default` but not
`vibe_init_external`): document the finding, defer RTL until Phase 2 (RGB)
closes the gap or another mechanism is tried.

**NO-GO** (`vibe_demote` doesn't beat either): the mechanism doesn't
deliver on real clips at Y-only resolution. Phase 2 (RGB) may still be worth
running as a separate experiment, but no automatic continuation.

## 8. Phasing

Single phase: Python only. RTL is explicitly deferred to a follow-up plan,
contingent on this experiment's GO outcome.

| Step | Deliverable |
|---|---|
| 1 | Extend `py/models/ops/vibe.py` with B' path + unit tests passing (§6) |
| 2 | cfg_t / profile updates + parity test passing |
| 3 | Comparison runner (§7) |
| 4 | WebP renderer with labelled rows |
| 5 | Run experiment on `birdseye` and `people` |
| 6 | Write results doc |
| 7 | GO / NO-GO decision |

## 9. Honest grounding discussion

The Phase A ghost-rescue addendum
([`2026-05-11-vibe-ghost-rescue-addendum.md`](2026-05-11-vibe-ghost-rescue-addendum.md))
established a discipline: distinguish "principle is published" from
"mechanism is published." That discipline applies here.

**What is published.**
- ViBe's neighbor-bank diffusion mechanism (Barnich & Van Droogenbroeck,
  IEEE TIP 2011): a bg-classified pixel probabilistically writes its current
  value into a random 3×3 neighbor's bank.
- PAWCS's neighbor-bank consensus (St-Charles, Bilodeau, Bergevin, IEEE TIP
  2016): pixel-level word importance is scored based on local recurrence
  across the 3×3 neighborhood.
- Stationary-FG detection (Bayona et al., ICIP 2010; Porikli, EURASIP J.
  Adv. Sig. Proc. 2008): persistence counter + temporal stability used to
  detect abandoned objects.

**What this plan does that is not directly published.**
- Inverts stationary-FG detection: use the persistence signal to **demote**
  ghosts to bg, rather than to flag abandoned objects.
- Inverts PAWCS-style neighbor consensus: use it as a gate on demotion,
  rather than as a score for word importance.

These are reasonable engineering inversions of established primitives, but
"high certainty of a working model" is established here by **mechanism-level
reasoning** (§3.4, §3.6) and **empirical validation** (§6, §7), not by
direct citation. Phase 2 (RGB) hardens the discrimination component further;
if Phase 1 GOes and Phase 2 lands, the combined operator is functionally a
ViBe-base, PAWCS-style-consensus-gated, ghost-demoting variant — well
within the published-literature design space, but assembled differently.

## 10. References

- Barnich, O. & Van Droogenbroeck, M. (2011). *ViBe: A Universal Background
  Subtraction Algorithm for Video Sequences.* IEEE TIP 20(6).
  [Paper page](https://www.telecom.uliege.be/publi/publications/barnich/Barnich2011ViBe/)
- Hofmann, M., Tiefenbacher, P. & Rigoll, G. (2012). *Background
  Segmentation with Feedback: The Pixel-Based Adaptive Segmenter.* CVPRW.
- St-Charles, P.-L., Bilodeau, G.-A. & Bergevin, R. (2016). *Universal
  Background Subtraction Using Word Consensus Models (PAWCS).* IEEE TIP
  25(10). [IEEE Xplore](https://ieeexplore.ieee.org/document/7539354/)
- St-Charles, P.-L., Bilodeau, G.-A. & Bergevin, R. (2014). *SuBSENSE: A
  Universal Change Detection Method With Local Adaptive Sensitivity.* CVPRW.
- Bayona, A., San Miguel, J. & Martinez, J. (2010). *Stationary Foreground
  Detection Using Background Subtraction and Temporal Difference in Video
  Surveillance.* ICIP.
  [IEEE Xplore](https://ieeexplore.ieee.org/document/5650699/)
- Porikli, F. (2008). *Robust Abandoned Object Detection Using Dual
  Foregrounds.* EURASIP J. Adv. Sig. Proc.
  [Paper](https://asp-eurasipjournals.springeropen.com/articles/10.1155/2008/197875)
- Phase A retrospective: [`2026-05-11-vibe-ghost-rescue-addendum.md`](2026-05-11-vibe-ghost-rescue-addendum.md)
- PBAS Python ref design: [`2026-05-11-pbas-python-design.md`](2026-05-11-pbas-python-design.md)
