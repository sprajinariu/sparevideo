# Background-Model Survey: Replacing EMA to Eliminate Frame-0 Ghosts

**Date:** 2026-05-01
**Status:** Survey / research artifact. Decision: ViBe (see §8). Implementation design in companion doc [`2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md).
**Scope:** Algorithm comparison only. The 1-bit motion mask producer that today lives in `axis_motion_detect`. Everything downstream of the mask (morphology, CCL, overlay, scaler, HUD) is treated as fixed. Integration with the existing pipeline, RAM layout, PRNG choice, and migration phasing are in the companion design doc, not here.

---

## 1. Problem statement

The current pipeline produces its motion mask via per-pixel exponential moving-average (EMA) background subtraction inside `axis_motion_detect` / `motion_core`:

- Frame 0 hard-init: `bg[p] := Y_smooth(frame_0[p])` for every pixel.
- Frames ≥1: `mask[p] = |Y_cur[p] − bg[p]| > THRESH`.
- bg update is selective:
  - Non-motion pixels at fast α (default `alpha_shift=3`, α=1/8).
  - Motion pixels at slow α (default `alpha_shift_slow=6`, α=1/64) so a transient foreground does not contaminate bg.
- Frames `1..grace_frames` ignore the selective rule and apply an aggressive uniform α (default `grace_alpha_shift=1`, α=1/2) with mask gated to zero, to absorb frame-0 contamination.

The **frame-0 ghost** is the failure mode that all of the above tries — and ultimately fails — to suppress: an object present in frame 0 is baked into `bg`. When that object later moves or leaves, the *original* location reads as motion (the bg expectation no longer matches reality), even though nothing is actually moving there. This produces a stationary "ghost" blob at the original position that the downstream CCL happily turns into a bbox.

Mitigations tried so far:

1. Skip-priming-frame-0 — replaced with hard-init (the ghost just deferred to frame 1 in a different shape).
2. Selective slow-EMA on motion pixels — narrows but does not eliminate the ghost; the ghost still survives ~1/α_slow ≈ 64 frames.
3. Grace window with aggressive α=1/2 — the ghost decays in ~4–5 frames but only if the foreground does not move during the grace window; on a real video with continuous motion the ghost is partially absorbed and partially flagged.

The problem is not parameter tuning. It is **structural**: a single per-pixel state (one Y8 value) cannot simultaneously represent the true bg and reject a wrong sample without overwriting one with the other. Any EMA-shaped solution converges only as fast as α permits, and α is bounded above by sensor noise (large α makes bg follow the noise, defeating the bg model's purpose).

This survey identifies three literature-standard background models that are **structurally** more capable than EMA and grades them on whether they would actually fix the frame-0 ghost — and at what hardware cost in our envelope.

---

## 2. Why EMA is structurally limited

Two interlocking limits, both inherent to the single-state-per-pixel formulation:

**(a) Single-mode representation.** `bg[p]` is one scalar. If a pixel's true bg distribution is bimodal (e.g., a leaf that occludes the background half the time), EMA can only sit on the average of the two modes, which matches *neither*. The frame-0 ghost is a degenerate case of the same limit: bg is "stuck" on the wrong mode (the foreground) and has no slot for the right one.

**(b) Coupled forgetting and learning.** With one state, learning a new sample (`bg += α·(x − bg)`) is the same operation as forgetting the old one. To accept a new bg correctly you must overwrite the wrong one in proportion to α. Setting α high enough to forget a frame-0 contamination quickly (~few frames) also prevents bg from rejecting per-frame sensor noise as foreground.

The candidates below address (a) and (b) by either:

- Storing **multiple modes** per pixel (MOG2 — parametric mixture; ViBe / PBAS — non-parametric samples), or
- Adding a **spatial mechanism** that imports correct bg samples from neighboring pixels into a contaminated pixel's model (ViBe, PBAS — sample diffusion).

The spatial mechanism is the structural fix for the frame-0 ghost specifically; multi-mode storage is a generalization that helps on dynamic backgrounds but does not by itself fix the ghost.

---

## 3. Evaluation lens

Each candidate is graded on these six axes:

| Axis | What it measures |
|---|---|
| Frame-0 ghost robustness | Does the algorithm provably suppress a frame-0 contaminated mode, and how many frames does it take? Sample-diffusion vs. weight-decay vs. nothing. |
| Per-pixel RAM @ 320×240 | Bytes per pixel × 76,800. Compared against current 76.8 KB EMA budget. On-chip BRAM only. |
| Compute @ 1 px/clk, 100 MHz | Multiplies, divides, sqrt, FP — what synthesizes vs. what doesn't. Hard veto on per-pixel divides. |
| Streaming friendliness | Can it run raster order, single pass, ≤2 cycles latency per stage, no vblank fixup? |
| Tunability surface | How many knobs land in `cfg_t`? Are they intuitive (like `alpha_shift`) or opaque (coupled hyperparameters)? |
| Beyond-ghost wins | What other failure modes does it close (dynamic bg, shadows, illumination shift, sensor noise)? Bonus, not required. |

Hardware envelope assumed throughout: 320×240 algorithmic resolution, 1 px/clk @ 100 MHz DSP clock, on-chip BRAM only (no DDR), Verilator-only sim, mask output stays 1-bit binary (matches the `axis_motion_detect` contract). RAM units below are 8b/px Y unless otherwise noted.

---

## 4. Candidate 1 — MOG2 (Adaptive Gaussian Mixture)

**References**

- Stauffer & Grimson, "Adaptive Background Mixture Models for Real-Time Tracking," CVPR 1999. (Original MOG.)
- Zivkovic, "Improved Adaptive Gaussian Mixture Model for Background Subtraction," ICPR 2004. (MOG2 — adaptive K via Dirichlet prior.)
- Zivkovic & van der Heijden, "Efficient Adaptive Density Estimation per Image Pixel for the Task of Background Subtraction," PRL 2006.

**Algorithm (per pixel)**

State: K Gaussian components, each `(μ_k, σ²_k, w_k)`. K is bounded above by `K_max` (typical 3–5); MOG2's Dirichlet prior shrinks unused components to zero weight, so effective K is data-dependent.

For incoming sample `x`:

1. Find the matching component: smallest `k` such that `(x − μ_k)² < D² · σ²_k` (typical `D=2.5`).
2. **If match exists** (component `m`):
   - `μ_m  ← (1−ρ)·μ_m + ρ·x`
   - `σ²_m ← (1−ρ)·σ²_m + ρ·(x − μ_m)²`
   - `w_k  ← (1−α)·w_k + α·[k==m]`        for all k
3. **If no match:** replace the lowest-weight component with `(μ=x, σ²=σ²_init, w=w_init)`.
4. Sort components by `w_k / σ_k` (proxy for confidence-per-spread).
5. Compute the bg cumulative weight: smallest `B` such that `Σ_{k=1..B} w_k > T_bg` (typical 0.7).
6. **Mask:** `x` is foreground iff `x` did not match any of the top-B components.

**Per-pixel RAM**

For `K_max = 3` and tight quantization (`μ`: 8b, `σ²`: 16b fixed-point, `w`: 8b normalized):
- 3 × (8 + 16 + 8) bits = 96 bits = **12 B/px** → **~900 KB** at 320×240.

That is **~12× the current EMA budget**. Below the on-chip BRAM ceiling on a mid-size FPGA, but a serious commitment.

**Compute per pixel**

For `K_max = 3` (the practical minimum for "mixture" to mean anything):

- 3 squared-distance comparisons → **3 multiplies** (`(x−μ_k)²`).
- 1 EM update on the matched component → 2 multiplies (μ update is just a shift+add when ρ is power-of-two; σ² update is a multiply).
- 3-way sort by `w_k / σ_k` → division, OR precompute `w_k² / σ²_k` and sort by that → 3 multiplies + 3-way comparator network.
- Cumulative-weight compare: trivial.

Realistic budget: **~6–9 fixed-point multiplies per pixel**, plus a 3-element sort. Fits in 100 MHz with pipelining (~5 stages), but we'd burn 6–9 DSP blocks just here. EMA today uses zero multiplies in the bg update.

**Streaming friendliness**

Workable. The K-element sort is O(K) compare-swaps, single-pass per pixel. No vblank fixup. The annoying part is the σ²-init constant on component-replace — a writable parameter, not a fundamental issue.

**Frame-0 ghost robustness — the critical issue**

MOG2 *does not structurally fix the frame-0 ghost.* Mechanism: in frame 0, the contaminated pixel initializes its dominant component to `(μ = foreground_value, w = 1, σ² = σ²_init)`. When the foreground later leaves and the true bg pixel arrives, that sample doesn't match the dominant component. MOG2 then either matches a *different* component (if K_max > 1 and a low-weight slot is available), or replaces the lowest-weight component with the new sample. In *both* cases:

1. The wrong component still has weight `w ≈ 1`, well above `T_bg`. So it's still classified as "background." The new (correct) sample is foreground until the wrong component's weight decays below `T_bg`.
2. Weight decay rate is `α` (typical 0.001–0.01). Time to fall below `T_bg=0.7` is roughly `(1 − T_bg) / α ≈ 30–300 frames`.

So **MOG2 trades EMA's ghost for a slightly different ghost with a similar timescale.** This is well documented in the literature — Barnich & Van Droogenbroeck's ViBe paper specifically calls out frame-0 ghost as "an unsolved problem in MOG-class methods" and motivates ViBe's spatial diffusion as the structural fix.

**Tunability surface**

`cfg_t` would gain at minimum: `K_max`, `alpha_w` (weight learning rate), `alpha_mu` (mean/variance learning rate ρ), `T_bg` (bg cumulative threshold), `D` (Mahalanobis distance multiplier), `sigma2_init`, `sigma2_min`, plus the Dirichlet prior `c_T` if we want auto-K. **~7–8 knobs**, several of which are coupled (changing α changes the effective T_bg crossover).

**Beyond-ghost wins**

- Multi-modal bg representation: if K_max ≥ 3, MOG2 can model swaying-leaves / flickering-screen / waving-flag scenarios that EMA cannot.
- Better noise floor: variance-aware threshold means quiet pixels have a tighter rejection radius, noisy pixels a looser one — automatic.

**Verdict**

Strictly more *capable* than EMA on dynamic backgrounds, but **does not solve the stated problem**. Frame-0 ghost is structurally similar in MOG2 and EMA; both rely on temporal weight decay alone. Costs ~12× the RAM and adds 6–9 DSP multiplies. If our problem were "EMA fails on swaying foliage," MOG2 would be the answer. Our problem is "EMA fails on frame-0 contamination," which MOG2 does not address.

---

## 5. Candidate 2 — ViBe (Visual Background Extractor)

**Reference**

- Barnich & Van Droogenbroeck, "ViBe: A Universal Background Subtraction Algorithm for Video Sequences," IEEE TIP 2011.
- *Patent note:* ViBe is covered by US patent 8,009,918 (filed 2009-08-13, Univ. of Liège), expected expiry around 2029. For a personal/learning project this is a minor concern but worth documenting; commercial deployment would need to either license, design around, or wait. The algorithm is fully described in the paper and reimplementable from the spec — no licensed code is required to build a Python reference or RTL.

**Algorithm (per pixel)**

State: K stored samples per pixel, plain Y8 values (no parameters, no statistics). Typical K=20; we'd cut to K=8 for memory.

For incoming sample `x`:

1. Count: `count = |{ i : |x − sample_i| < R }|` for `i = 1..K`.
2. **Mask:** `x` is bg iff `count ≥ #min` (typical `#min = 2`).
3. **Update (only if classified bg):** with probability `1/φ` (typical `φ = 16`, so 6.25% of bg pixels per frame):
   - Replace sample `j ← random(0, K−1)` with `x`.
   - Additionally, with probability `1/φ`, replace one random sample of one **random 8-neighbor pixel's** sample set with `x`. ← **The spatial diffusion that fixes ghosts.**

Initialization: from frame 0, fill each pixel's K samples by random draws from its 3×3 (or 5×5) spatial neighborhood. (So even at frame 0 the model is non-trivially distributed.)

**Per-pixel RAM**

For K=8, plain Y8:
- 8 × 8b = **8 B/px** → **614 KB** at 320×240.

For K=20 (literature default):
- 20 × 8b = 20 B/px → **1.5 MB** at 320×240. May exceed mid-size FPGA on-chip BRAM.

The **K=8 cut** is the realistic working point. The literature notes K can go as low as 6 with modest quality loss.

**Compute per pixel**

- K parallel `|x − sample_i| < R` comparators (subtractor + abs + 8b comparator).
- A K-bit popcount (trivially `count = Σ matches`).
- One comparator: `count ≥ #min`.
- Update logic: K-to-1 mux for sample replacement; an 8-neighbor random-target index; LFSR for the PRNG.

**Zero multiplies. Zero divides. Just SUB / CMP / popcount.** This is the cheapest of the three on raw arithmetic.

**Streaming friendliness**

Excellent. K parallel ops fit in one pipeline stage; standard dual-port BRAMs handle the read-while-write pattern needed for the spatial-diffusion mechanism without exotic primitives. Implementation-level details (port modes, deferred-write FIFO, etc.) are in the companion design doc.

**Frame-0 ghost robustness — the critical mechanism**

ViBe is the only candidate of the three with a **structural** ghost-killing mechanism. Walkthrough on our exact problem:

- Frame 0: foreground object at pixels P. Each pixel `p ∈ P`'s K samples are filled from 3×3 neighborhood of `p`. If the foreground object is wider than 1 px, all 8 neighbors of an interior `p` are also foreground, so all K samples are foreground-valued. Pixels at the edge of the foreground region get a mix: some samples from neighboring true-bg pixels.
- Frame N (foreground gone): true bg pixel `x` arrives at pixel `p ∈ P`. `count = 0` (no sample matches), so `p` is classified foreground. **No update happens** (ViBe only updates bg-classified pixels).
- BUT: pixels just *outside* `P` are correctly classified as bg. With probability `1/φ²`, each one of them propagates a true-bg sample into a random neighbor's sample set. After enough frames, true-bg samples leak into `P`'s sample sets via the boundary inward. Once any pixel in `P` has `≥ #min = 2` matching samples, it flips to bg, and from then on its own diffusion accelerates the inner pixels.

Convergence is **boundary-driven and parallel** — pixels just outside the contaminated region propagate true-bg samples inward through the diffusion mechanism, and the cascade accelerates as freshly-flipped pixels become diffusion sources for their interior neighbors. The original ViBe paper's empirical numbers on the canonical "stationary foreground at frame 0, removed at frame 1" test show **full ghost dissipation in 50–150 frames** at default parameters (φ=16), independent of region shape within reasonable bounds. The companion design doc has the rate math.

That's slower than the ~5-frame grace-window decay we have today on *narrow* ghosts — but unlike grace window, ViBe decay has no fundamental dependence on ghost size and no parameter to retune for different scenes. It just works.

**Tunability surface**

`cfg_t` would gain: `K`, `R`, `min_match` (#min), `phi_update`, `phi_diffuse`. **~5 knobs**, all intuitive. The literature defaults (`K=20, R=20, #min=2, φ=16`) work surprisingly broadly — Barnich & Van Droogenbroeck explicitly designed for parameter robustness.

**Beyond-ghost wins**

- Slow lighting drift: handled implicitly because samples gradually mix with current values.
- Sensor noise rejection: as good as `R` permits (R=20 on 8-bit Y is typical, ~8% of dynamic range).
- **Limitation**: not as good as MOG2 on truly multi-modal bg (waving foliage, rippling water). The K=8 sample set tends to lose mode diversity over time as updates randomize it.

**Verdict**

The single best fit for our stated problem. Hardware-friendly (no multipliers, K parallel comparators), structurally addresses frame-0 ghosts via a mechanism EMA literally cannot replicate, and the literature defaults are well-tested. Memory is ~8× the current EMA budget at K=8 — the binding constraint, but tractable.

---

## 6. Candidate 3 — PBAS (Pixel-Based Adaptive Segmenter)

**Reference**

- Hofmann, Tiefenbacher, Rigoll, "Background Segmentation with Feedback: The Pixel-Based Adaptive Segmenter," CVPRW 2012 (CDnet workshop).

**Algorithm (per pixel)**

PBAS = ViBe with two **per-pixel adaptive scalars**: a per-pixel match radius `R(x)` and a per-pixel update rate `T(x)`.

Decision rule: identical to ViBe but with `R(x)` instead of global `R`.

```
count = |{ i : |x − sample_i| < R(x) }|
mask  = (count < #min)
```

Adaptation rules (the additions over ViBe):

- Track `d_min(x) = min_i |x − sample_i|` per pixel each frame.
- Maintain a moving-average `d̄(x)` of `d_min(x)` over time (another EMA — small per-pixel scalar).
- **Radius update:** if `R(x) > d̄(x) · R_scale` then `R(x) ← R(x) · (1 − R_dec)` else `R(x) ← R(x) · (1 + R_inc)`.
  - Intuition: tighten R when the model is matching too well (we're in stable bg); loosen R when we're missing matches (suggests model needs slack).
- **Update rate:** if `mask == fg` then `T(x) ← T(x) + T_inc/d̄(x)` else `T(x) ← T(x) − T_dec/d̄(x)`.
  - Foreground pixels back off updates (don't poison bg with foreground); bg pixels update faster.
  - Hofmann uses 1/d̄(x) but in hardware we'd quantize or table-lookup that division.

**Per-pixel RAM**

ViBe samples (K=8): 8 B
+ R(x): 8b (or 16b if we want fine-grain headroom)
+ T(x): 8b (or 16b)
+ d̄(x): 8b (single moving-average scalar, not a full sample array)

Roughly **11–14 B/px** → **850 KB – 1.1 MB** at 320×240. About 30–50% over ViBe.

**Compute per pixel**

ViBe per-pixel logic, plus:

- Compute `d_min(x)`: `min` over K subtractor outputs — trivial (already computed; just take the min instead of count).
- Update `d̄(x)`: shift+add (EMA).
- Compare `R(x)` vs `d̄(x) · R_scale`: 1 multiply (or fixed shift if R_scale is power-of-two).
- Update `R(x)`: shift+add.
- Update `T(x)`: 1 division by `d̄(x)`. **This is the issue.** A per-pixel divide at 1 px/clk is the awkward thing.

Mitigations for the T-update divide:

- Quantize `d̄(x)` to a small set of bins, use a LUT for `T_inc/d̄(x)`. Cheap and good enough — Hofmann's later work confirms.
- Or skip the `1/d̄` factor entirely (use a constant `T_inc`), which slightly degrades adaptation quality but keeps the math multiply-only.

So PBAS is feasible without divides, with a small quality compromise in the T-update.

**Streaming friendliness**

Same as ViBe (K parallel comparators + a couple ALU ops for R/T updates). Good.

**Frame-0 ghost robustness**

**Strictly faster** than ViBe at ghost dissipation, because a contaminated pixel's `d_min` is large (no samples are close to the true bg arriving now), `d̄(x)` ramps up, `R(x)` follows, and eventually `R(x)` is large enough that the boundary diffusion's leaked sample matches even loosely. Empirical literature numbers (CDnet 2012 / 2014) show PBAS converging on ghost / abandoned-object / removed-object scenarios ~2–3× faster than vanilla ViBe.

The cost: 30–50% more per-pixel RAM and a more complex update path (with the divide-or-quantize question).

**Tunability surface**

ViBe's 5 knobs + `R_inc`, `R_dec`, `R_scale`, `R_lower`, `R_upper`, `T_inc`, `T_dec`, `T_lower`, `T_upper`. **~14 knobs**, several coupled. Hofmann gives sensible defaults but the surface is broader than ViBe's. This is the largest tunability-surface concern across the three.

**Beyond-ghost wins**

- Better discrimination on textured bg (R(x) tightens automatically on quiet regions, loosens on noisy ones).
- Same "intermittent motion" handling as ViBe but with tighter steady-state thresholds.

**Verdict**

A strict superset of ViBe in capability, with strictly more cost (RAM, compute, tunability surface). **The right "phase 2" upgrade if Phase-0 Python ablation shows vanilla ViBe converges too slowly on our actual footage**, but starting with PBAS would be premature optimization — Hofmann's whole framing is "ViBe + feedback," and the feedback only matters once you've established the underlying ViBe behavior on the target data.

---

## 7. Comparison

| Axis | EMA (today) | MOG2 | ViBe (K=8) | PBAS |
|---|---|---|---|---|
| Frame-0 ghost robustness | Weak (decay only, ~64 frames) | Weak (decay only, ~30–300 frames) | **Structural fix** (sample diffusion, ~50–150 frames empirical) | **Structural fix, faster** (adaptive R speeds up diffusion, ~25–75 frames empirical) |
| Per-pixel RAM | 1 B (76.8 KB total) | 12 B/px @ K=3 (900 KB) | 8 B/px @ K=8 (614 KB) | 11–14 B/px (850 KB – 1.1 MB) |
| Compute (1 px/clk) | 0 multiplies | 6–9 multiplies + 3-way sort + DSP | **0 multiplies**, K=8 parallel compare + popcount | 0 multiplies if d̄-divide is LUT'd; else 1 divide |
| Streaming friendly | Yes | Yes (with pipelining) | **Yes** (cleanest) | Yes (LUT for divide) |
| Tunability surface | 4 knobs | ~7–8 knobs (coupled) | **~5 knobs (intuitive defaults)** | ~14 knobs |
| Beyond-ghost wins | Slow lighting only | Multi-modal bg, variance-aware noise | Slow lighting, mild dynamic-bg | Multi-modal bg adaptation, textured bg |

ViBe dominates MOG2 on every axis that matters for the stated problem (lower RAM, lower compute, structurally fixes the ghost) at the cost of being weaker than MOG2 on dynamic-bg multimodality — which is *not the stated problem*. PBAS is a strict ViBe improvement on quality at strict ViBe cost increase on resources and knobs.

---

## 8. Recommendation

**Pick:** **ViBe (K=8, intensity-only feature)** as the EMA replacement.

**Reasons, ordered:**

1. The *only* candidate of the three that structurally addresses frame-0 ghost. MOG2's mechanism is the same shape as EMA's (temporal weight decay) and inherits the same problem; ViBe's spatial sample-diffusion is novel work the existing EMA cannot replicate.
2. Lowest hardware cost of the structural-fix candidates: 8 B/px (614 KB total, ~8× current bg RAM, well under the ~1 MB BRAM budget on the target FPGA class), zero multiplies, K=8 parallel comparators.
3. Smallest knob surface (5) and most-tested literature defaults of the three.
4. Strict subset of PBAS, so this choice does not foreclose the upgrade path: if Phase-0 ablation shows convergence is unacceptably slow on real footage, the PBAS adaptive-R extension can be added without touching the sample-storage / decision core.

**Defer:** PBAS — wait for ablation evidence before paying the extra RAM + 14-knob tax.

**Reject:** MOG2 — does not solve the stated problem. (Could be revisited if the project's problem changes to dynamic-bg multimodality, but that's a different design conversation.)

**Caveat:** ViBe is patented through ~2029 (see §5). For this project's learning/personal-use context the patent is acceptable. PBAS builds on the same sample-diffusion mechanism so it likely inherits the same patent exposure — anyone considering commercial deployment of this codebase should treat both options as patent-encumbered until counsel says otherwise.

### Phase-0 Python ablation gate (mandatory before any RTL work)

The recommendation must be validated with a Python ablation before any RTL plan opens. The full procedure (deterministic numpy re-implementation + cross-check against the authors' upstream PyTorch reference + side-by-side vs. EMA + decision gate) lives in the companion design doc: [`2026-05-01-vibe-motion-design.md` §8](2026-05-01-vibe-motion-design.md#8-phase-0-ablation-gate-mandatory-before-any-rtl-work).

The high-level gate criteria stay here as the survey-level decision boundary:

- **Pass:** ViBe ghost convergence ≤200 frames (≤3 s at 60 fps) on the real-world clip; false-positive rate no worse than current EMA on `textured_static`.
- **Fail:** escalate to PBAS Phase-0 with the same ablation discipline before opening any RTL plan.

This mirrors how the LBSP+ViBe plan ([2026-04-22-lbsp-vibe-motion-pipeline-plan.md](2026-04-22-lbsp-vibe-motion-pipeline-plan.md)) was disciplined.

---

## 9. Out of scope (deliberately)

This survey **does not** address, and does not pretend to address, any of the following:

- **Shadows.** A moving object's cast shadow is correctly classified as motion by ViBe (the bg model has no concept of "shadow"). Sakbot-style HSV shadow detection or a chromaticity-based test would be a separate downstream stage.
- **Dynamic backgrounds.** Waving foliage, rippling water, fluttering flags. ViBe handles mild cases, fails on severe ones; MOG2 or SuBSENSE would be better here. Not the user's stated problem.
- **Illumination flicker.** Sudden global luminance change (lights turning on, AGC step). Handled by per-pixel adaptive R (PBAS) but not by vanilla ViBe.
- **Camera motion / jitter.** Pre-stage stabilization is in a separate plan ([2026-04-30-motion-stabilize-frames-design.md](2026-04-30-motion-stabilize-frames-design.md)); bg-model survey assumes stabilized input.
- **Multi-camera fusion.** Out of project scope entirely.
- **LBSP / texture features.** Explicitly deferred per the user's "starts simple" framing. The bg-model and feature-extractor axes are separable; LBSP can be retrofitted onto any of the three candidates here in a later iteration if the intensity-only feature proves insufficient.
- **Per-pixel confidence output.** Mask stays 1-bit binary, matching the current `axis_motion_detect` contract. ViBe naturally produces `count` (0..K) which is a confidence proxy; converting to a multi-bit mask is a separate decision for a separate doc.

---

## 10. References

- Stauffer & Grimson, "Adaptive Background Mixture Models for Real-Time Tracking," CVPR 1999.
- Zivkovic, "Improved Adaptive Gaussian Mixture Model for Background Subtraction," ICPR 2004.
- Zivkovic & van der Heijden, "Efficient Adaptive Density Estimation per Image Pixel for the Task of Background Subtraction," PRL 2006.
- Barnich & Van Droogenbroeck, "ViBe: A Universal Background Subtraction Algorithm for Video Sequences," IEEE TIP 2011.
- Hofmann, Tiefenbacher, Rigoll, "Background Segmentation with Feedback: The Pixel-Based Adaptive Segmenter," CVPRW 2012.
- Project prior art: [`docs/plans/motion-pipeline-improvements.md`](motion-pipeline-improvements.md), [`docs/plans/2026-04-22-lbsp-vibe-motion-pipeline-plan.md`](2026-04-22-lbsp-vibe-motion-pipeline-plan.md), [`docs/specs/axis_motion_detect-arch.md`](../specs/axis_motion_detect-arch.md).
