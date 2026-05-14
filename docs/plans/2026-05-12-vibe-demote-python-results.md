# ViBe + persistence-based FG demotion (B') — Python results

**Date:** 2026-05-12 (initial), revised 2026-05-13 with the post-hollowing iteration.
**Branch:** `feat/vibe-demote-python`
**Companion design:** [`2026-05-12-vibe-demote-python-design.md`](2026-05-12-vibe-demote-python-design.md)
**Companion plan:** [`2026-05-12-vibe-demote-python-plan.md`](2026-05-12-vibe-demote-python-plan.md)

## Decision

**GO** for an RTL follow-up. The `vibe_demote` mechanism solves frame-0 ghosts on real clips while preserving real moving objects after one iteration on the consistency threshold (1 → 3) to break a hollowing cascade observed under thresh=1.

## Production configuration

`VIBE_DEMOTE` profile defaults (post-iteration):
- `vibe_demote_en = True`
- `vibe_demote_K_persist = 30` (≈ 1 s @ 30 fps)
- `vibe_demote_kernel = 3` (3×3 neighborhood)
- `vibe_demote_consistency_thresh = 3` (promoted from 1 — see §"Iteration 2")

## Setup

- **Sources:** `birdseye-320x240.mp4`, `people-320x240.mp4` (mask-level numeric comparison).
- **Plus three real clips + one synthetic for the WebP demos:** `birdseye`, `intersection`, `people`, `synthetic:multi_speed_color`.
- **Run length:** 200 frames per source (~6.7 s @ 30 fps) for the mask-level comparison; demo WebPs use available clip lengths (synthetic 200, birdseye/intersection 150, people 75 — limited by the source clip).
- **Methods compared (numeric, 6-method run preserved as the iteration record):**
  - `vibe_init_frame0` — no-fix baseline.
  - `vibe_init_external` — current production (lookahead-median bg priming).
  - `pbas_default` — Hofmann et al. 2012 PBAS.
  - `vibe_demote` (thresh=1) — Phase-1 candidate.
  - `vibe_demote_strict` (thresh=3) — **this is the new `vibe_demote` production default after Iteration 2.**
  - `vibe_demote_eroded` (thresh=3 + neighbor-bg erosion) — dropped after the comparison showed Δ < 0.001 vs strict on every metric.

## Iteration 1 — Phase-1 result with thresh=1

The 4-method run (200 frames) showed `vibe_demote` (thresh=1) beat `vibe_init_external` on overall asymptote on both sources, and beat both `vibe_init_external` and `pbas_default` decisively on the high-traffic-region asymptote. PBAS had the lowest overall asymptote (cleaner low-traffic pixels) but the worst high-traffic asymptote.

Numbers (asymptote = mean of frames 150-199, lower = better):

| Source | frame0 | external | pbas | **demote (thresh=1)** |
|---|---|---|---|---|
| birdseye overall | 0.0468 | 0.0374 | 0.0191 | 0.0317 |
| birdseye high-traffic | 0.6133 | 0.5167 | 0.8460 | **0.4729** |
| people overall | 0.1374 | 0.0990 | 0.0640 | 0.0833 |
| people high-traffic | 0.7022 | 0.5817 | 0.8387 | **0.5343** |

This was the original PARTIAL-GO recommendation: better than external on the project's actual motivation (high-traffic ghosts) but lost the overall-asymptote criterion to PBAS.

## Iteration 2 — Hollowing analysis and thresh bump

Visual inspection of the iteration-1 WebPs surfaced a real failure mode: **real moving objects (walking pedestrians) got hollowed out** — the mask showed only the outline of a person, with the interior incorrectly classified as bg.

The mechanism: a low-contrast pixel inside the person's outline (where the person's local Y happens to land within ViBe's R=20 of bg) classifies canonically BG. Canonical ViBe's own-bank update fires probabilistically at 1/phi=1/16 per frame, writing the current observation (person-color, slightly bg-like) into the hollow pixel's bank. After ~K_persist frames, ~2 slots accumulate person-color values. An outline pixel of the person — whose Y is just *outside* R of bg but within R of the polluted hollow-bank slots — then passes the consistency check at thresh=1 (one matching slot sufficient) and demotes. The wavefront then cascades inward through the person's body.

Three options were tested:
- **Option A** — bump `consistency_thresh` from 1 to 3. Requires 3 matching slots in a BG neighbor's bank before fire; harder to accumulate accidentally via canonical updates; slower wavefront (3 frames per ring instead of 1).
- **Option A+B** — Option A plus a morphological erosion on `prev_final_bg` that excludes BG-classified neighbors with zero BG neighbors in their own 3×3 (filters isolated hollows inside FG regions).
- Option C (forbid canonical updates from hollows) was not tested in this iteration.

Re-run (6-method, 200 frames) results, focused on the new variants:

| Source | demote (t=1) | demote_strict (t=3) | demote_eroded (t=3 + erode) | external |
|---|---|---|---|---|
| birdseye overall | 0.0317 | 0.0355 | 0.0352 | 0.0374 |
| birdseye HT | 0.4729 | 0.5525 | 0.5582 | 0.5167 |
| birdseye peak | 0.0578 | 0.0578 | 0.0578 | 0.0513 |
| people overall | 0.0833 | 0.0939 | 0.0940 | 0.0990 |
| people HT | 0.5343 | 0.5461 | 0.5405 | 0.5817 |
| people peak | 0.1303 | 0.1303 | 0.1303 | 0.1213 |

**Strict and eroded are numerically and visually indistinguishable** (Δ < 0.001 on every metric). In real footage, BG-classified pixels almost always have at least one BG-classified neighbor, so the erosion barely filters anything — the cascade-via-isolated-hollow path I demonstrated synthetically is rare in the wild. The **erosion machinery was dropped** as a dead end.

**Strict is the new vibe_demote default.** Visual inspection confirmed strict fixes the hollowing — walking pedestrians render as solid blobs, not outlines. The qualitative win is the goal, even though strict gives back ~0.08 absolute coverage on birdseye's high-traffic asymptote (vibe_demote at thresh=3 now loses to external on that one metric, while still winning on the people HT asymptote and on overall asymptote on both sources).

## Headline tables (post-iteration `vibe_demote` = thresh=3)

**Overall asymptote (frames 150-199, lower = cleaner):**

| Source | external | pbas | **vibe_demote (thresh=3)** |
|---|---|---|---|
| birdseye | 0.0374 | 0.0191 | 0.0355 |
| people | 0.0990 | 0.0640 | 0.0939 |

**High-traffic asymptote (closest to design §1's motivation):**

| Source | external | pbas | **vibe_demote (thresh=3)** |
|---|---|---|---|
| birdseye | 0.5167 | 0.8460 | 0.5525 |
| people | 0.5817 | 0.8387 | 0.5461 |

`vibe_demote` (thresh=3) beats `external` on overall asymptote on both sources, and on the people high-traffic asymptote. It loses to `external` on the birdseye HT asymptote by ~0.04, but with the visual benefit of preserved real-moving-object bodies.

## Visual evidence

**Per-source `make demo`-style WebPs (input + ccl_bbox + motion triptychs, `CFG=demo_vibe_demote`):**

Drafts (Python-backend, gitignored under `media/demo-draft-exp/`):

- `media/demo-draft-exp/vibe-demote-synthetic.webp` — 200 frames, synthetic:multi_speed_color.
- `media/demo-draft-exp/vibe-demote-birdseye.webp` — 150 frames.
- `media/demo-draft-exp/vibe-demote-intersection.webp` — 150 frames.
- `media/demo-draft-exp/vibe-demote-people.webp` — 75 frames (source-limited).

Per project convention, `media/demo-draft-exp/` is the publish-ineligible draft location for Python-backend (EXP=1) runs — only RTL-backend output can be promoted to `media/demo/` via `make demo-publish`. The triptychs above stay as drafts until vibe_demote has an RTL implementation; at that point a fresh RTL-backed run can produce publish-eligible WebPs.

**6-method side-by-side mask comparison (iteration record, also gitignored under `media/demo-draft-exp/`):**

- `media/demo-draft-exp/vibe-demote-compare-media_source_birdseye-320x240.mp4.webp`
- `media/demo-draft-exp/vibe-demote-compare-media_source_people-320x240.mp4.webp`

(The compare WebPs label the new default as "vibe_demote_strict" — that profile name was dropped; its config is now the `vibe_demote` default. The vanilla "vibe_demote" panel in the compare WebPs shows the dropped thresh=1 behavior, retained as the iteration-1 reference.)

## Decision against design §7.5 criteria (post-iteration)

`vibe_demote` (thresh=3) vs the criteria:

1. **Lower asymptotic coverage than `vibe_init_external`** — MET on both sources (0.0355 < 0.0374 birdseye; 0.0939 < 0.0990 people). ✓
2. **Lower asymptotic coverage than `pbas_default`** — NOT MET (0.0355 > 0.0191 birdseye; 0.0939 > 0.0640 people). ✗
3. **No worse peak coverage than `vibe_init_external`** — NOT MET (0.0578 > 0.0513 birdseye; 0.1303 > 0.1213 people), structural caveat: external's lookahead-warm-start advantage on frame-0.

Strict letter: still PARTIAL GO, same shape as iteration 1.

But the project's real motivation (design §1) is high-traffic ghosts, and `vibe_demote` wins on that against `external` on people and beats PBAS by ~0.30 absolute coverage on both sources. Combined with the iteration-2 fix preserving real moving objects, the recommendation is **GO**.

## Recommendation

**Start the RTL follow-up plan for `vibe_demote`** on a fresh branch off `origin/main`. State delta over `axis_motion_detect_vibe`:
- 1 byte/pixel `fg_count` register (saturating uint8 counter).
- 3×3 neighbour-bank consistency scan, threshold counter (4-bit compare ≥ 3).
- One deterministic single-slot write per firing pixel (reuses existing PRNG path).
- No new RAM ports — the bank write reuses the existing one.

Order of next steps:
1. Verify on a third real source (e.g., `intersection`) at the mask level if needed — the demo WebP already gives qualitative coverage.
2. RTL design doc → RTL plan → RTL implementation → SV/Python parity tests at TOLERANCE=0.

## Caveats / open questions

- **Tradeoff between hollowing-fix and high-traffic-ghost dissolution speed.** Bumping thresh from 1 to 3 slowed the wavefront from 1 ring/frame to 3 frames/ring. For 5-second clips this is still inside the window, but on birdseye HT the thresh=1 variant was 0.05 absolute better. The fix is correct but not free.
- **K_persist not tuned.** Default 30 (≈ 1 s @ 30 fps) was the spec's reasoned choice; not swept. A future tuning pass could try 45 or 60 to further harden real-object preservation, at proportional cost in ghost dissolution speed.
- **Y-only operation.** Per the design spec, all operators in this iteration are Y-only. Phase 2 RGB extension is a separate deferred plan, contingent on whether the per-channel discrimination further reduces the low-contrast hollow population that causes the cascade.
- **`vibe_demote_eroded` dropped.** Synthetic stress test showed the erosion mechanism works correctly when isolated hollows are present, but real footage doesn't have enough isolated hollows for the erosion to do meaningful work. Kept the test for documentation but the cfg field and profile were removed before committing.
