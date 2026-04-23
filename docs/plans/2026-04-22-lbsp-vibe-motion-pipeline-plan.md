# LBSP + ViBe Motion Pipeline — Future Work Plan

**Date:** 2026-04-22
**Status:** Parked. Revisit only if the simpler temporal-differencing fix (approach A, tracked separately) fails to recover ghost behaviour on textured / real-world footage.

---

## Context — why this exists

Phase 1 of the Sobel ghost detector plan (`2026-04-22-sobel-ghost-detector-plan.md`) investigated asymmetric Sobel edge-matching for ghost suppression. Three sub-variants were prototyped in `py/experiments/`:

1. **Per-pixel Sobel vote** — fragments a ghost blob's edges into many CCL components; fails by creating extra bboxes.
2. **Blob-level majority vote** — can't separate fused ghost+object blobs on uniform-interior sources; all-or-nothing per blob.
3. **Erosion-split blob vote** — works on `dark_moving_box` with tuned iters=5 but is a per-source knob, and still degrades on textured backgrounds where both `edge(y)` and `edge(bg)` are dominated by static texture, masking the ghost signal.

A literature review (Sakbot TPAMI 2003, MDPI two-layer Sensors 2020, Sehairi survey 2018) identified the failure mode as **signal choice**: asymmetric edge magnitude is the wrong primitive on textured backgrounds. The references use richer feature pipelines that this plan captures as a future-work option.

The expected first choice is the simpler **approach A — temporal differencing replaces Sobel** (its own plan). This plan (**approach C**) is the fallback when real-world / dynamic-background / illumination-change deployments show A isn't enough.

---

## Goal

Rebuild the motion detection front-end around the MDPI two-layer bg model with LBSP texture features and dynamic per-pixel thresholds. Target deployment scenarios:

- **Textured backgrounds** (foliage, fabric patterns, road surfaces) where single-scalar `|y − bg|` is overwhelmed by texture noise.
- **Dynamic backgrounds** (swaying branches, rippling water) where a single-EMA bg cannot represent multi-modal pixel distributions.
- **Illumination changes** where absolute intensity differences spuriously trigger motion but LBSP (an intensity-shift-invariant descriptor) does not.

---

## New RTL modules

| Module | Role | Rough cost |
|---|---|---|
| `axis_lbsp` | Per-pixel Local Binary Similarity Pattern. 5×5 window, 8-bit binary descriptor per pixel comparing centre to 8 neighbours. Same streaming skeleton as `axis_gauss3x3` (2-line buffer + adder-tree-equivalent). | ~200 LUTs, 1 BRAM |
| `axis_vibe_bg` | ViBe / two-layer sample-based background. Each pixel stores K main + K candidate samples (typical K=8 reduced from literature's K=20 to fit on-chip). Foreground decision = "distance to ≥M-of-K samples > R(x)". Stochastic sample replacement at probability 1/φ. | **Memory-dominated**: K=8 × 2 layers × 8 bits × 76.8 k pixels ≈ 10 Mbit. Boundary of on-chip BRAM — may force external DDR. |
| `axis_hist_accum` | Per-CCL-blob colour histogram accumulator. Taps a new per-pixel label stream from `axis_ccl`. Emits (blob, histogram) pairs at frame boundary. | ~500 LUTs, ~40 Kbit accumulator RAM |
| `axis_thresh_adapt` | Per-pixel dynamic threshold `R(x)` adaptation. Laplacian-driven update: higher texture complexity → larger threshold. Frame-shaped RAM, small state machine. | ~150 LUTs, 1 BRAM (same size as bg) |

## Reused modules (unchanged or additive change only)

| Module | Change |
|---|---|
| `axis_gauss3x3` | Unchanged — still useful as prefilter. |
| `axis_ccl` | **Additive**: expose per-pixel label stream on a new output port for `axis_hist_accum` to consume. Internal labeling logic unchanged. |
| `axis_overlay_bbox` | Unchanged. |
| `axis_fork`, `rgb2ycrcb` | Unchanged. |
| `axis_motion_detect` wrapper | Shell kept (stream-in / stream-out skeleton, bg-RAM interface, parameter plumbing). The guts (EMA update, priming, grace, selective EMA) are **replaced** by ViBe + LBSP decision logic. |
| `motion_core` | Replaced entirely. |

---

## Phase decomposition (all Python-first, same discipline as the Sobel plan)

### Phase 1 — Python experiment + decision gate (1 week)

Fork `py/models/motion.py` into `py/experiments/motion_lbsp.py` and implement the complete ViBe + LBSP + histogram pipeline in numpy/scipy. Render side-by-side comparisons against the current baseline and the temporal-diff variant (approach A) on:

- The four synthetic sources from the Sobel Phase 1 (`moving_box`, `dark_moving_box`, `noisy_moving_box`, `two_boxes`).
- **New** textured/dynamic sources introduced specifically for this phase: `textured_moving_object`, `swaying_branches_plus_moving_box` (to be added to `py/frames/video_source.py`).
- At least one real-world clip if available by then.

**Decision gate:** literature-standard beats approach A visibly on textured/dynamic sources, and does not regress on uniform sources. Otherwise stop.

### Phase 2 — Documentation (2–3 days)

Update `docs/specs/axis_motion_detect-arch.md` with the new datapath. Add LBSP, ViBe, histogram, and dynamic-threshold sections. Document the memory hierarchy decision (on-chip K= vs external DDR).

### Phase 3 — RTL implementation (2 weeks)

Implement the four new blocks, rewrite `motion_core`, add the CCL label-output port, rework parameter propagation through the Makefile chain. Verify at TOLERANCE=0 against the Phase 1 Python reference across the full source × parameter matrix.

**Total ballpark:** ~3–4 weeks including verification, vs. ~3–4 days for approach A.

---

## Key risks / open questions

1. **Memory budget.** The single biggest architectural decision. On-chip BRAM likely insufficient for MDPI's K=20 × 2 layers. Options: (a) reduce K to 4–8 per layer (degrades sample diversity), (b) add DDR controller (huge scope increase — not in the current toolchain), (c) drop the candidate layer and keep only main ViBe (loses the "periodic motion absorption" benefit). Phase 1 Python should sweep K to find the min K that still works, informing this decision before committing to RTL.

2. **CCL label-output port.** `axis_ccl` currently resolves labels internally at EOF. Exposing a per-pixel label stream mid-frame requires care: the stream labels may be overwritten by later union-find merges. Options: (a) emit labels at EOF after resolution (requires frame-size buffer for features), (b) emit provisional labels and apply the same equivalence chain to accumulated histograms (complex). Decide early in Phase 3.

3. **Histogram test may be redundant for us.** MDPI's histogram similarity test targets frame-0 initialisation artifacts. We solved that with priming + grace window. If Phase 1 shows histogram test adds no value after grace, drop it — saves ~40 Kbit + 500 LUTs.

4. **LBSP parameter tuning.** 5×5 vs 3×3 neighbourhood; similarity threshold per channel; Y-only vs per-channel. Phase 1 sweep decides.

5. **Dynamic threshold drift.** R(x) can runaway-grow in regions with repeated motion. MDPI caps it with Laplacian-derived upper bound. Need to replicate this discipline.

6. **Approach-A interaction.** If approach A has already shipped, this plan needs to decide: does the temporal-differencing stage stay (belt-and-braces) or get removed (keep only LBSP+ViBe)? Defer to Phase 1 ablation.

---

## Re-entry checklist (for whoever picks this up cold)

1. Read the Sobel plan (`2026-04-22-sobel-ghost-detector-plan.md`) — same project, same motion pipeline context.
2. Read the approach-A plan (whichever filename it ends up under — likely `2026-04-??-temporal-diff-ghost-plan.md`) and its retrospective. This plan only makes sense once approach A has been tried and found insufficient on textured/real-world footage.
3. Check what's in `py/experiments/` — the Sobel experiment code is likely still there and shares data-loading infrastructure we can reuse.
4. Confirm the decision gate: is the real complaint texture-robustness, dynamic-bg handling, or both? If only one, a partial build (e.g. LBSP without two-layer ViBe) may suffice.
5. Before touching RTL, run Phase 1 Python to completion. This plan's RTL ballpark assumes Phase 1 validated the approach; if Phase 1 kills it, abandon as with the Sobel plan.

---

## References

- Cucchiara et al., "Detecting Moving Objects, Ghosts and Shadows in Video Streams," IEEE TPAMI 2003 — Sakbot. Uses optical flow for ghost detection, HSV for shadows, object-level selectivity.
- "Ghost Detection and Removal Based on Two-Layer Background Model and Histogram Similarity," MDPI Sensors 2020 — the direct source of LBSP + two-layer + dynamic threshold + histogram ghost test.
- Sehairi et al., "Comparative study of motion detection methods," J. Electron. Imaging 2017 (arXiv 1804.05459) — family taxonomy; flags GMM/ViBe/LBSP+fusion as the canonical handlers of dynamic/textured bg; `frame differencing + bg subtraction` hybrid as the canonical simple ghost fix (our approach A).
- Barnich & Van Droogenbroeck, "ViBe: A universal background subtraction algorithm for video sequences," IEEE TIP 2011 — the canonical sample-based bg model the MDPI paper builds on.
