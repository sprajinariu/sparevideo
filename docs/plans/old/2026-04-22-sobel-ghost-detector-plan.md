# Sobel Ghost Detector — High-Level Implementation Plan

**Date:** 2026-04-22
**Status:** RETIRED 2026-04-23 — Phase 1 failed its decision gate. Superseded by `2026-04-23-temporal-diff-ghost-plan.md`. Retained here for the record so the next ghost-detection attempt can read what was tried and why it was abandoned.

---

## Retrospective (2026-04-23)

### Outcome
Phase 1's Python experiment reached the decision gate and did not pass it. Phases 2 and 3 were never started. No RTL was written.

### What was actually prototyped (all code still in `py/experiments/` pending clean-up)
Three progressively more elaborate variants of the Sobel asymmetric-edge criterion:

1. **Per-pixel Sobel vote** (`motion_sobel.run` with `ghost_mode="per_pixel"`). Classifies each pixel via `edge(bg) − edge(y) > GHOST_EDGE_TOL`. Suppresses individual pixels from the CCL input mask.
2. **Blob-level majority vote** (`ghost_mode="blob_level"`). Groups `raw_motion` pixels into 8-connected blobs; casts per-pixel ghost/real votes; majority ≥ `GHOST_BLOB_RATIO` → suppress whole blob.
3. **Blob-level with pre-erosion split** (`ghost_mode="blob_erode"`). Erodes `raw_motion` to break narrow necks between fused ghost+object blobs before labelling, propagates labels back via distance transform.

All three share the same 4-way `bg_next` mux and the same asymmetric-edge signal. Tests (`py/experiments/test_sobel.py`, 24 passing) verify baseline-equivalence invariants and per-blob classification correctness.

### What the experiment revealed — why each variant failed

**Per-pixel.** The Sobel classifier fires only on *edges*. Uniform-interior blobs (e.g. `dark_moving_box`) abstain inside. CCL then sees the ghost trail as a chain of hollow ring-shaped components, each big enough to clear `MIN_COMPONENT_PIXELS`. The bbox view gets **worse** than baseline — one merged ghost bbox fragments into many small outline-bboxes. Observable in `dv/data/renders/sobel_experiment_*_motion.png`.

**Blob-level (no erosion).** On uniform sources the ghost trail and current object are spatially connected through consecutive-frame overlap. The 80%-majority vote is binary per blob:
- tight tolerance → suppresses the entire fused blob, losing the current object.
- loose tolerance → keeps the fused blob, bbox bounds the entire trail.

At `GHOST_EDGE_TOL=16`, the measured ghost-vote ratio at a representative post-grace frame was 0.797 — just under the 0.80 threshold, so the classifier silently declined to fire. Any threshold adjustment traded one failure mode for the other.

**Blob-level with erosion.** Erosion with `iters=5` at `ratio=0.8` produced a clean single-object bbox on `dark_moving_box`, which initially looked decisive. Stress-testing revealed:
- The `iters=5` value is tied to the object-size × per-frame-displacement ratio of this specific source. Smaller objects are erased by the erosion entirely; wider trails need more erosion than the object can survive.
- **Textured-background sources** (`lit_moving_object`, `entering_object`, `multi_speed`) still produced scattered ghost bboxes. `edge(bg)` and `edge(y)` are both dominated by static texture gradient, so the asymmetric residual is swamped by texture noise — the signal itself fails, independent of aggregation strategy.

### Root cause
The Sobel asymmetric-edge primitive is the wrong signal on textured backgrounds. Static texture contributes large gradient magnitudes to **both** `edge(y)` and `edge(bg)`, so `edge(bg) − edge(y)` loses its discriminating power against genuine ghost content. No amount of aggregation (per-pixel → blob → blob-erode) rescues a signal with insufficient per-pixel SNR on the workloads we care about.

### Literature review findings
Commissioned in response to the textured-source failure:
- Sakbot (Cucchiara, TPAMI 2003) uses **optical flow**, not edge matching, as the ghost criterion. Edges are for *shadow* detection via HSV chromaticity.
- The MDPI two-layer paper (Sensors 2020) uses **LBSP** (a texture-shift-invariant binary descriptor), **sample-based multi-layer bg**, **histogram similarity**, and **dynamic per-pixel thresholds** — four features, not one.
- The Sehairi survey flags **frame differencing + bg subtraction** as the canonical simple ghost-handling hybrid.

None of the literature uses asymmetric edge magnitude as a primary ghost classifier. The plan's design inherited the criterion from the "shadow removal by edges matching" paper, where the feature serves a different purpose.

### What superseded this
Two plans written the same day as this retrospective:
- **`2026-04-23-temporal-diff-ghost-plan.md`** — the pragmatic replacement. Replaces Sobel with temporal differencing (`|y_t − y_{t-1}| > T`) as the ghost-discrimination signal, kept inside the existing blob-aggregation framework. Texture-invariant by construction. ~4–5 days of RTL vs. this plan's 2–3 days, but drops Sobel, bg_linebuf, and erosion entirely.
- **`2026-04-22-lbsp-vibe-motion-pipeline-plan.md`** — parked literature-standard rewrite. Full MDPI-style LBSP + ViBe two-layer + dynamic threshold pipeline. ~3–4 weeks. Revisited only if the temporal-diff plan also fails to cover the textured/real-world use cases.

### Artifacts worth keeping
- `py/experiments/sobel.py`, `motion_sobel.py`, `test_sobel.py`, `sobel_ghost_compare.py`, `sobel_blob_diagnostic.py`, `sobel_stress_test.py` — all the Phase 1 prototype code. Will be moved to `py/experiments/old/` at the end of the temporal-diff plan's Phase B.4. Useful as a reference implementation and as A/B comparison rows in the temporal-diff experiment.
- The rendered comparison PNGs under `dv/data/renders/sobel_*.png` and `sobel_diag_*.png` — direct visual evidence of the failure modes described above.
- The blob-level infrastructure (`_blob_promote`, `_blob_promote_erode`, 8-connectivity + vote accumulation + distance-transform relabeling) is **reusable** by the temporal-diff plan with only the vote-signal source changed.

### Lessons to carry forward
1. On synthetic uniform-interior sources, the "connected trail" topology is a structural property of the motion, not a tuning problem. No per-pixel classifier can decompose a fused ghost+object blob without either a temporal signal (approach A) or a segmentation technique outside our current tool set.
2. A classifier's per-pixel signal-to-noise ratio on textured backgrounds is the first thing to measure, not the last. All three Sobel variants share one unusable signal on textured bg — we could have caught this with a 10-line SNR test before building the aggregation logic.
3. Phase 1's "experiment-first before documentation and RTL" gate worked exactly as designed: ~1.5 days of Python exposed a failure mode that would have cost ~3 days of RTL to rediscover. The discipline is worth keeping for the temporal-diff plan.

---

## Original plan — preserved below for reference

---

## Session Context (read this first if starting fresh)

### What the project is
`sparevideo` is a video-processing pipeline in SystemVerilog targeting Verilator. Top-level `sparevideo_top` takes AXI4-Stream RGB in on a 25 MHz pixel clock, crosses to 100 MHz DSP clock via `axis_async_fifo`, runs a control-flow-selectable motion-detection pipeline, crosses back, and drives an instantiated `vga_controller`. Orientation notes:
- RTL: `hw/top/`, `hw/ip/motion/rtl/`, `hw/ip/gauss3x3/rtl/`, `hw/ip/axis/rtl/`, `hw/ip/vga/rtl/`
- Testbench: `dv/sv/tb_sparevideo.sv`, unit TBs in `hw/ip/*/tb/`
- Python reference models: `py/models/{motion,mask,ccl_bbox,passthrough,ccl}.py` — bit-exact golden reference; RTL must match at `TOLERANCE=0`
- Docs live in `docs/specs/` (architecture) and `docs/plans/` (designs + plans — **never** `docs/superpowers/specs/` per CLAUDE.md)
- Build: top `Makefile` + `dv/sim/Makefile`. `make run-pipeline` is the end-to-end gate.
- Compile-time parameters propagate: top Makefile → dv/sim/Makefile (`-G...`) → `tb_sparevideo` → `sparevideo_top` → IP modules. Missing any link silently bakes in the default. See CLAUDE.md "Motion pipeline — lessons learned §2".

### Current motion pipeline (what's in the tree, committed + staged)

Signal flow in `axis_motion_detect.sv`:
```
RGB AXIS in → rgb2ycrcb → [axis_gauss3x3 if GAUSS_EN=1] → y_smooth ─┐
                                                                      ├→ motion_core → mask, bg_next
                                              bg RAM[out_addr] ──────┘
                                              ↑
                                              bg written back: mem_wr_data_o = bg_next
```

`motion_core.sv` is purely combinational: takes `y_smooth`, `y_bg`, `primed_i`, `in_grace_i` not yet (see staged changes below), outputs `mask_bit_o`, `raw_motion_o`, and three EMA-updated bg candidates (`ema_update_o`, `ema_update_slow_o`, `ema_update_grace_o`). The wrapper picks one for `bg_next` based on state.

**Detection rule (current): three-tier.**
1. **Priming** (`primed=0`, frame 0 only): `bg_next = y_smooth` (hard-init the RAM directly). Mask forced 0.
2. **Grace window** (`primed=1 && grace_cnt < GRACE_FRAMES`, default 8): `bg_next = ema_update_grace` (aggressive rate `α = 1/(1<<GRACE_ALPHA_SHIFT)`, default `α=1/2`). Mask also blanked (`m_axis_msk_tdata_o = mask_bit && !in_grace`).
3. **Post-grace selective EMA**:
   - Non-motion pixel (`!raw_motion`): `bg_next = ema_update` (fast, `α=1/(1<<ALPHA_SHIFT)`, default `α=1/8`).
   - Motion pixel (`raw_motion`): `bg_next = ema_update_slow` (slow, `α=1/(1<<ALPHA_SHIFT_SLOW)`, default `α=1/64`).

Compile-time parameters: `ALPHA_SHIFT=3`, `ALPHA_SHIFT_SLOW=6`, `GRACE_FRAMES=8`, `GRACE_ALPHA_SHIFT=1`, `GAUSS_EN=1`, `THRESH=16`.

### Expected pipeline after this plan is executed

Signal flow in `axis_motion_detect.sv` after Phase 3 lands (bold = new or changed):

```
┌─ Spatial-filter stages ──────────────────────────────────────────────────────────────────┐
│                                                                                            │
│   RGB AXIS in → rgb2ycrcb → axis_gauss3x3 → y_smooth ─┬─→ **axis_sobel3x3_y**  → edge_y   │
│                                                        │                                   │
│   bg RAM[out_addr] → y_bg ─────────────────────────────┤                                   │
│                                                        │                                   │
│                                                        └→ **bg_linebuf** → **axis_sobel3x3_bg** → edge_bg  │
│                                                                                            │
└─────────────────────┬──────────────────────┬──────────────────────┬───────────────────────┘
                       │                      │                      │
                   y_smooth                y_bg               edge_y, edge_bg
                       ↓                      ↓                      ↓
┌─ motion_core (extended) ──────────────────────────────────────────────────────────────────┐
│                                                                                            │
│   raw_motion = |y_smooth − y_bg| > THRESH                                                 │
│   **ghost    = raw_motion && (edge_bg − edge_y > GHOST_EDGE_TOL)**   ← NEW classifier     │
│                                                                                            │
│   bg_next (4-way mux, priority top-down):                                                 │
│     !primed                         → y_smooth           (hard-init)                      │
│     in_grace                        → ema_update_grace   (aggressive α during grace)       │
│     **ghost**                       → **ema_update_fast** ← override selective EMA       │
│     raw_motion && !ghost            → ema_update_slow    (selective protect real object)  │
│     else                            → ema_update_fast    (non-motion steady-state)        │
│                                                                                            │
│   mask_bit_o = primed && !in_grace && raw_motion && **!ghost**                            │
│                                                                                            │
└─────────────────────┬──────────────────────────────────────┬──────────────────────────────┘
                       │                                      │
                  mask_bit                                 bg_next
                       ↓                                      ↓
                   axis_ccl                          mem_wr_data_o → bg RAM
                       │
                       ↓
              CCL blobs / bboxes
                       │
                       ↓ (optional Phase 3 Option B — only if Phase 1 shows it's needed)
┌─ Blob-level promoter ─────────────────────────────────────────────────────────────────────┐
│   During CCL pass: accumulate per-blob ghost_votes / motion_votes from per-pixel labels.  │
│   End-of-frame: blob_label = majority vote. Ghost-classified blobs are suppressed from    │
│   the overlay/bbox output stream (does not alter bg update — bg already cleaned fast by   │
│   the motion_core ghost branch during CCL integration).                                   │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

**What changes vs today:**
- **New modules**: `axis_sobel3x3` (3×3 Sobel magnitude, reused twice — once for y, once for bg); `bg_linebuf` (2-row buffer so bg-side Sobel can build a 3×3 window out of RAM reads).
- **Extended `motion_core`**: two new inputs (`edge_y_i`, `edge_bg_i`), one new output (`ghost_o`), mux grows from 4-way to 4-way-with-override (the ghost branch overrides what would otherwise be `ema_update_slow`).
- **Extended mask gate**: `mask_bit_o` gains `&& !ghost` so ghost-classified pixels don't reach CCL as motion pixels (cleaner CCL blobs downstream).
- **Optional blob-level promoter**: lives downstream of `axis_ccl`, activated only if Phase 1 shows per-pixel Sobel leaves interior ghosts on our synthetic sources. See "Per-pixel Sobel vs blob-level classification" section below for the rationale.

**What stays the same:**
- Frame-0 hard-init (`primed` register, priming branch).
- Grace window (`grace_cnt`, `GRACE_FRAMES`, `GRACE_ALPHA_SHIFT` — still aggressive bg cleanup at init).
- Selective EMA (still protects real moving objects from trail contamination — the ghost branch only overrides the specific subset of motion pixels that Sobel classifies as ghost).
- RAM port width, depth, or count. Bg-linebuf is on-chip block RAM, not external.
- Output stream format (RGB or mask or ccl_bbox, same as today).

**New compile-time parameters introduced:** `GHOST_ENABLE` (default 1 after Phase 1 approval, 0 for regression-equivalence with current design), `GHOST_EDGE_TOL` (calibrated from Phase 1 sweep). Both propagate through the full Makefile → TB → top → IP chain (same pattern as `GRACE_ALPHA_SHIFT`).

**What is committed on `feat/ccl` and what is staged-but-not-committed (as of this plan's creation):**
- Committed: frame-0 hard-init, selective EMA (two-rate), grace window (first version with `mask_bit` live during grace and grace using `ALPHA_SHIFT` rate).
- **Staged but NOT committed** (11 files, see `git status`): mask-gate during grace (`mask_bit && !in_grace`), `GRACE_ALPHA_SHIFT` parameter with default `α=1/2`, full chain propagation. Commit message suggested but not applied. A fresh session should decide whether to commit these first or build Phase 1 on top of the staged state.

### Why this plan exists — the residual bug

The grace window fixes most frame-0 ghosts, but there is a failure mode it cannot cover:

**For continuously-moving objects, the last-grace-frame position always has contaminated bg.** At grace frame `K-1` the object is at pixel `P_{K-1}` → `bg[P_{K-1}]` is updated toward foreground. At grace end (frame `K`), the object has moved to `P_K`. Pixel `P_{K-1}` now reads true background in `y` but foreground in `bg` → `raw_motion=1` → selective EMA latches its slow rate on that pixel → ghost persists for `~1/α_slow = 64` frames.

The user's own report: after grace ends, a ghost appears at the last-grace-position, "becomes stronger for ~16 frames, fades over ~50 frames." Math checks out: selective slow rate at α=1/64 closes a delta of ~105 in ~95 frames.

**This is intrinsic to any selective-EMA-based detector.** The "most recently vacated pixel" is always contaminated. Grace cannot fix this because no matter how long grace is, there is always a "last pixel visited" with zero post-visit grace frames to decay.

**Alternatives considered and rejected:**
- **Extend GRACE_FRAMES to ~24** — works mathematically but adds 0.8 s blind window per sim run; user rejected as impractical.
- **Revert selective EMA** — trails return on every moving-object departure (~8-frame trail at α=1/8). This was the bug selective EMA was introduced to fix.
- **Cooldown window** (post-grace mask-visible fast-EMA) — reduces but doesn't eliminate the ghost, and reintroduces short trails. Documented as fallback if Sobel fails Phase 1.

**This plan's answer: Sobel edge-match ghost classifier, layered on top of selective EMA (not replacing it).**

### Design rationale (from literature synthesis)

Per Cucchiara's Sakbot (IEEE TPAMI 2003), the MDPI two-layer paper (2020), and the Sehairi survey (arXiv 1804.05459), the canonical pipeline for this class of detector uses **four pixel classes with different bg-update rules**:

| Class | `y` characteristics | `bg` characteristics | Update rule |
|---|---|---|---|
| Stationary background | matches bg | matches y | Fast EMA (tracks lighting drift) |
| Real moving object | has object edges | clean | **Slow EMA** (protect bg from contamination — this is selective EMA's job) |
| Ghost | reveals uniform true bg | still holds old object content with its edges | **Fast EMA / force-reset** (accelerate cleanup — overrides selective EMA) |
| Shadow | matches bg up to luma scale | clean | Suppress from mask, no bg update (not handled in this plan) |

Selective EMA handles row 2 (the reason we have it). The grace window approximates row 3 by time but can't handle post-grace ghosts. Sobel's job is row 3: **detect ghosts structurally and override selective EMA's slow-rate latch for those pixels**.

**Asymmetric edge criterion (key insight — the symmetric version "edges match" doesn't work):**

```
edge_y  = |Gx(y_smooth)| + |Gy(y_smooth)|          # current frame gradient magnitude
edge_bg = |Gx(y_bg)|     + |Gy(y_bg)|              # bg model gradient magnitude

ghost       = raw_motion && (edge_bg - edge_y > GHOST_EDGE_TOL)   # bg has edges y doesn't
real_motion = raw_motion && !ghost                                # otherwise
```

Why asymmetric: both ghost and real-motion pixels have *some* edge mismatch. The direction disambiguates:
- Ghost: object was at P, bg learned its edges. Object leaves. `y[P]` now reveals uniform true bg → `edge(y) = low`. `bg[P]` still has old-object edges → `edge(bg) = high`. So `edge(bg) > edge(y)`.
- Real motion: object arrives at P. `y[P]` has fresh object edges → `edge(y) = high`. `bg[P]` is still clean bg → `edge(bg) = low`. So `edge(y) > edge(bg)`.

**Gaussian interaction:** Sobel is noise-sensitive. Gaussian preprocessing is the *classical* preprocessing for Sobel (this is what Canny does). Our existing `axis_gauss3x3` already provides it — Sobel on `y_smooth` gets noise-suppressed gradients for free. Edge magnitudes are lower under Gaussian, so `GHOST_EDGE_TOL` must be calibrated for that; if `GAUSS_EN=0`, a different (higher) tolerance is needed.

### Per-pixel Sobel vs blob-level classification — how the information actually flows

Sobel responds at edges, not interiors. So the per-pixel classifier has **strong directional evidence only at blob boundaries**, not throughout the blob:

- **Boundary pixels**: `edge(y)` and `edge(bg)` are both large *but directionally asymmetric*. Ghost boundary → `edge(bg) > edge(y)` (bg remembers old object outline, y reveals uniform true bg). Real-object boundary → `edge(y) > edge(bg)` (y has fresh object outline, bg is clean). The classifier fires with high confidence.
- **Interior pixels**: `edge(y) ≈ edge(bg) ≈ 0` on uniform blobs. The asymmetric test returns "ambiguous" and the pixel falls through to the existing rule (selective EMA — which latches the ghost at slow rate, the failure mode we're trying to fix).

Why this still works in practice, via two mechanisms:

**1. Most real objects have internal texture.**
People, cars, buildings — they have edges throughout (shadows, creases, panels, clothing). Sobel fires densely inside real blobs, not just on the outline. The per-pixel classifier covers most of the blob's pixels. The "only at boundaries" case is specific to abstract synthetic sources like `dark_moving_box` (solid dark rectangle on solid white bg).

**2. For uniform-interior blobs, CCL promotes boundary votes into a blob-level label.**
CCL is already in the pipeline. If per-pixel Sobel marks a ghost blob's boundary as "ghost-like" but is ambiguous inside, we accumulate two counters per blob during CCL: `ghost_votes` and `motion_votes` from per-pixel Sobel classifications. At end-of-frame, each blob gets a single class label by majority vote (e.g., ≥80% of the blob's boundary is ghost-like → label the whole blob, including its interior, as ghost). This is Sakbot's "object-level selective update." Cheap because CCL is already computing the blobs.

The full information flow:
```
Per-pixel Sobel        →  edge(y), edge(bg) at every pixel
       ↓
Asymmetric classifier  →  per-pixel vote: {ghost, real_motion, ambiguous}
       ↓
CCL (already present)  →  group motion pixels into blobs; accumulate per-blob ghost/motion vote counts
       ↓
Blob-level classifier  →  majority vote promotes sparse boundary votes into one label per blob
       ↓
Per-pixel label        →  every pixel in a blob inherits the blob's label
       ↓
Update rule            →  ghost blob: force fast bg update, suppress from mask output
                          real blob: selective EMA slow rate (protect bg), mask stays on
```

**Per-pixel Sobel is necessary (only source of structural evidence) but not always sufficient (ambiguous in uniform interiors). CCL promotion makes it sufficient.**

#### Concrete blob-level algorithm (Phase 3 Option B)

The per-pixel classifier produces one of three labels per pixel:

```
if edge_bg - edge_y > GHOST_EDGE_TOL:     sobel_class = GHOST
elif edge_y - edge_bg > GHOST_EDGE_TOL:   sobel_class = REAL_MOTION
else:                                      sobel_class = AMBIGUOUS   # uniform region — no structural evidence
```

CCL is already walking the mask pixel-by-pixel assigning blob labels. In the same walk, two counters per blob accumulate the ballots:

```
for each pixel in mask:
    b = ccl_label[pixel]          # which blob this pixel belongs to (−1 = unlabeled)
    if b < 0:  continue
    if sobel_class[pixel] == GHOST:
        ghost_votes[b] += 1
    elif sobel_class[pixel] == REAL_MOTION:
        motion_votes[b] += 1
    # AMBIGUOUS pixels cast no vote — they do not dilute either count
```

At end-of-frame (CCL EOF phase), tally and label:

```
for each blob b:
    total = ghost_votes[b] + motion_votes[b]
    if total == 0:
        blob_label[b] = REAL_MOTION                      # no evidence → default safe (don't suppress)
    elif ghost_votes[b] / total >= GHOST_BLOB_RATIO:     # e.g. 0.8
        blob_label[b] = GHOST
    else:
        blob_label[b] = REAL_MOTION
```

Feedback:
- **Ghost blob** → every pixel in the blob is treated as ghost: suppressed from mask/overlay output, and on the next frame those pixels get the fast-EMA override path in `motion_core` (same as if per-pixel Sobel had fired on each one).
- **Real-motion blob** → normal selective-EMA protection continues; bbox emitted.

**Key property: AMBIGUOUS pixels don't vote, which is exactly why this works for uniform-interior blobs.** The small ring of boundary pixels that *do* vote carries the decision for the entire blob. Interior pixels cannot dilute the majority by contributing "unknown" ballots — they simply step aside and inherit whatever the boundary decides.

**Sizing:** For H=320, V=240 and `MAX_LABELS=64` (matching existing CCL state), the additional per-blob counters cost `64 × 2 × log2(H×V) bits ≈ 2 kb`. Trivial on top of CCL's existing per-blob state.

Gaussian preprocessing helps: a Gaussian-smoothed edge is spread across several pixels of gradient instead of a single step, so Sobel's boundary response is *thicker* after Gaussian — more pixels cast strong votes per blob, which makes both the per-pixel classifier (more coverage) and the blob-level majority (more robust counts) more reliable.

**Phase 1 tells us which regime we're in.** For textured real-world sources, per-pixel alone is likely enough and we skip the blob-level step. For our synthetic `dark_moving_box`, per-pixel alone may leave interior ghosts and the blob-level promotion becomes a Phase 3 requirement. The Phase 1 renders answer the question experimentally before we commit to the more complex implementation.

### Key files and what they do

| File | Role |
|---|---|
| `docs/specs/axis_motion_detect-arch.md` | Architecture contract for the motion pipeline. §3.1 parameters, §4.4 EMA + grace, §6 signal table, §10 follow-ups. Sobel currently documented as §10.1 follow-up; Phase 2 will promote it to a main section. |
| `docs/plans/2026-04-21-motion-mask-quality-design.md` | Original brainstorming spec for frame-0 priming + selective EMA. |
| `docs/plans/2026-04-22-motion-grace-window-plan.md` | Prior bite-sized plan for the grace window (implemented). Good template for the Phase 3 detailed plan this one will spawn. |
| `hw/ip/motion/rtl/motion_core.sv` | Pure-combinational motion decision + 3 EMA candidates. Sobel integration extends this with `edge_y_i`, `edge_bg_i` inputs and a `ghost` classifier output. |
| `hw/ip/motion/rtl/axis_motion_detect.sv` | Wrapper — owns `primed`, `grace_cnt`, the bg_next mux. Phase 3 adds Sobel stages and wires edge signals into `motion_core`. |
| `hw/ip/gauss3x3/rtl/axis_gauss3x3.sv` | **Reference template for `axis_sobel3x3`.** Same streaming skeleton: 2-line buffer + 3×3 window + adder tree + phantom-cycle handling + stall-safety (`busy_o`). Phase 3's new Sobel stage mirrors this module's structure. |
| `hw/ip/motion/tb/tb_axis_motion_detect.sv` | Unit TB with Python-parity golden model (mirrors the full detection rule). Phase 3 extends this for ghost classification. |
| `py/models/motion.py` | Golden reference model. Functions: `_rgb_to_y`, `_gauss3x3`, `_compute_mask`, `_ema_update`, `_selective_ema_update`, `_run_bg_trace`, `run`. Phase 1 experiment forks this into `py/experiments/motion_sobel.py`; Phase 3 promotes the changes back. |
| `py/models/mask.py`, `py/models/ccl_bbox.py` | Parallel models; must be updated in lockstep with `motion.py` (they share the same priming/grace/selective-EMA logic). |
| `py/harness.py` | CLI harness (prepare / verify / render). Sub-parsers `verify` and `render` take `--alpha-shift`, `--alpha-shift-slow`, `--grace-frames`, `--grace-alpha-shift`, `--gauss-en`. Phase 3 adds `--ghost-enable`, `--ghost-edge-tol`. |

### Project conventions (CLAUDE.md essentials)

- SystemVerilog only — no SVA, no interfaces, no classes (Icarus-12 compat even though Verilator is the primary target). `logic` not `reg`/`wire`. `always_ff` / `always_comb`.
- Active-low reset `rst_n_i`. 8-bit per channel RGB. Line-based streaming with `tvalid/tready/tlast/tuser` (tlast=EOL, tuser=SOF).
- All parameters and shared types in `hw/top/sparevideo_pkg.sv`. New compile-time knobs propagate through the full build chain.
- Commit messages: conventional-commits style, no `Co-Authored-By` trailer.
- WSL/Ubuntu shell. Python venv at `.venv/`. No `wsl bash -lc` wrapping.
- Run `make lint` after every RTL change; resolve warnings, don't add waivers unless the reason is documented at the waiver site.
- Unit TBs are golden-model-parity: the TB computes the expected output using the same rule as the Python reference, and diff'ing pixel-by-pixel at `TOLERANCE=0` is the acceptance gate. Mismatches mean either RTL or model is wrong — investigate both.
- Documentation order: docs first, then RTL + Python, then verification. This plan inverts it only for Phase 1 (experiment-first) because Sobel's value is uncertain enough to warrant proof before doc effort.

### Literature references (URLs in case a fresh session wants to re-fetch)

- Cucchiara et al., "Detecting Moving Objects, Ghosts and Shadows in Video Streams," IEEE TPAMI 2003 — <https://aimagelab-legacy.ing.unimore.it/imagelab/pubblicazioni/pami_sakbot.pdf>
- Ghost Detection and Removal Based on Two-Layer Background Model, MDPI Sensors 2020 — <https://www.mdpi.com/1424-8220/20/16/4558>
- Sehairi et al., Comparative study of motion detection methods, arXiv 1804.05459 — <https://arxiv.org/pdf/1804.05459>
- Compute-Extensive Background Subtraction for Efficient Ghost Suppression, IEEE 2019 — <https://ieeexplore.ieee.org/document/8812734/>
- Shadows Removal by Edges Matching, Springer — <https://link.springer.com/chapter/10.1007/978-3-642-10520-3_41>

---

## Design summary (short form)

- Asymmetric edge criterion: `ghost = raw_motion && (edge(y_bg) − edge(y_smooth) > GHOST_EDGE_TOL)`.
  - Ghost pixel: `y` reveals uniform true background, `bg` still holds old object content → edges-in-bg > edges-in-y.
  - Real moving object: `y` shows object content with edges, `bg` is clean → edges-in-y > edges-in-bg.
- Sobel magnitude approximated as `|Gx| + |Gy|` (L1, no sqrt).
- Gaussian preprocessing is already in place — classical Canny ordering.
- Classifier coexists with selective EMA, not replaces it. Selective EMA still protects bg under real moving objects; Sobel overrides that protection for the subset of motion-flagged pixels classified as ghost.

**Execution order (strict):**
1. **Phase 1 — Python experiment + visual checkpoint.** Validate that Sobel actually improves the visible mask/motion output before committing to RTL effort. Decision gate: human reviews comparison renders; if Sobel doesn't help, plan stops here and is discarded.
2. **Phase 2 — Documentation.** Only after Phase 1 confirms value. Pin the design in the arch doc + CLAUDE.md + README before any RTL change.
3. **Phase 3 — RTL design + implementation.** Mirror the Python model bit-for-bit. Full verification matrix at TOLERANCE=0.

---

## Phase 1 — Python Experiment + Visual Decision Gate

**Objective:** Prove (or disprove) that per-pixel Sobel ghost classification meaningfully improves the mask / motion output on our existing synthetic sources, *on top of* the already-staged grace-window + selective-EMA baseline. All work isolated in `py/experiments/` so it can be cleanly deleted if the experiment fails.

### Deliverables
- `py/experiments/sobel.py` — 3×3 Sobel magnitude operator (`|Gx| + |Gy|`) on 2D uint8 numpy arrays. Edge-replicated borders (matches `_gauss3x3` convention).
- `py/experiments/motion_sobel.py` — fork of `py/models/motion.py` that adds the asymmetric ghost classifier and the 4-way `bg_next` branch (`prime / grace / ghost-fast / non-motion-fast / motion-slow`). Parameterized with `ghost_enable: bool`, `ghost_edge_tol: int`. When `ghost_enable=False`, must reduce to the baseline model exactly (regression invariant).
- `py/experiments/sobel_ghost_compare.py` — harness that, for each test source, runs the baseline model and the Sobel-enabled model end-to-end and renders a 3-row comparison PNG (input / baseline / sobel) to `dv/data/renders/sobel_experiment_<source>.png`.
- `py/experiments/test_sobel.py` — unit tests: Sobel on known patterns (step edge, uniform, impulse), baseline-equivalence when `ghost_enable=False`.

### Test matrix
Comparison renders on four sources at H=320, W=240, FRAMES=24, GAUSS_EN=1, GRACE_FRAMES=8, GRACE_ALPHA_SHIFT=1 (matching current staged defaults):

| Source | What we're checking |
|---|---|
| `moving_box` | baseline healthy case — Sobel shouldn't make it worse |
| `dark_moving_box` | the specific ghost bug Phase 1 is trying to fix |
| `noisy_moving_box` | ensure Sobel doesn't spuriously trigger on noise edges |
| `two_boxes` | two independent objects — Sobel must not confuse their tracking |

### Parameter sweep
- `ghost_edge_tol ∈ {8, 16, 32}` — find the threshold that separates ghost from real-motion on Gaussian-smoothed inputs.
- Render all combinations for human review. Lowest tolerance that still cleanly rejects noise wins.

### Decision gate
Human reviews the rendered PNGs. **Proceed to Phase 2 only if:**
1. `dark_moving_box`: post-grace ghost is visibly smaller, fainter, or absent compared to baseline.
2. `moving_box`: tracking is at least as clean as baseline (no regressions on healthy case).
3. `noisy_moving_box`: no new spurious mask pixels from Sobel false-positives on noise edges.
4. `two_boxes`: both objects tracked independently — Sobel does not merge or drop bboxes.

If any of 1–4 fail on all tested tolerances: **plan stops**. Either tune further or abandon Sobel and revisit alternatives (cooldown window, revert selective EMA).

### Effort estimate
~0.5–1 day of Python. The experiment is read-only against the existing models — worst case we delete `py/experiments/` and lose nothing.

---

## Phase 2 — Documentation Update

**Objective:** Pin the design in prose before any RTL. If Phase 1 approved the mechanism, the experimental Python code is the authoritative description — Phase 2 translates it into architecture-spec language and propagates to the other doc surfaces.

### Deliverables
- **`docs/specs/axis_motion_detect-arch.md`** — major revision:
  - New `§5 Sobel Ghost Detector` subsection under Datapath: describes the 3×3 Sobel stage, asymmetric edge-magnitude comparator, and the 4-way `bg_next` mux including the ghost-override branch.
  - Update `§4.4` selective-EMA subsection to cross-reference the ghost override.
  - Update `§3.1` parameter table: add `GHOST_ENABLE` (default 1), `GHOST_EDGE_TOL` (default determined in Phase 1).
  - Remove or rewrite `§10.1 Edge-match ghost detector (Sobel-based)` from the Follow-Ups section (the feature is no longer a follow-up).
  - Add to `§6` signal table: `edge_y`, `edge_bg`, `ghost`.
- **`CLAUDE.md` — "Motion pipeline — lessons learned"** — add a bullet explaining the three-tier detection: abs-diff (motion) + asymmetric Sobel (ghost) + selective EMA (real-motion bg protection).
- **`README.md`** — add `GHOST_ENABLE` / `GHOST_EDGE_TOL` to the parameter tables and build-command example.
- **Top `Makefile`** — add the two parameters to `help:` output.

### Effort estimate
~0.5 day. Mostly prose; no functional changes.

---

## Phase 3 — RTL Design + Implementation

**Objective:** Implement the Phase 1 / Phase 2 design in SystemVerilog, bit-exact against the Python reference model, verified at TOLERANCE=0 across the full matrix.

### New / modified modules

| Module | Responsibility | Change type |
|---|---|---|
| `hw/ip/motion/rtl/axis_sobel3x3.sv` | Streaming 3×3 Sobel on Y (mirrors `axis_gauss3x3` pattern: 2 line buffers, 3×3 window, two adder trees for Gx/Gy, `\|Gx\|+\|Gy\|`). | **Create** |
| `hw/ip/motion/rtl/bg_linebuf.sv` | 2-row buffer for bg pixels fetched from RAM so the bg-side Sobel can build a 3×3 window. | **Create** |
| `hw/ip/motion/rtl/motion_core.sv` | Add `edge_y_i`, `edge_bg_i` inputs; add ghost classifier; extend bg_next mux to 4-way. | Modify |
| `hw/ip/motion/rtl/axis_motion_detect.sv` | Instantiate `axis_sobel3x3` on the y_smooth path, `bg_linebuf` + `axis_sobel3x3` on the bg path; wire edge magnitudes into `motion_core`; propagate new parameters. | Modify |
| `hw/top/sparevideo_pkg.sv` / `sparevideo_top.sv` | Expose `GHOST_ENABLE`, `GHOST_EDGE_TOL` as top-level parameters. | Modify |
| `dv/sv/tb_sparevideo.sv`, top `Makefile`, `dv/sim/Makefile` | Parameter propagation chain. | Modify |
| `hw/ip/motion/tb/tb_axis_sobel3x3.sv` | Unit TB for the Sobel stage (compare against Python reference). | **Create** |
| `hw/ip/motion/tb/tb_axis_motion_detect.sv` | Extend existing TB to verify ghost classification + 4-way mux. | Modify |
| `py/models/motion.py` / `mask.py` / `ccl_bbox.py` | Promote the experimental Sobel logic from `py/experiments/` into the production models (replacing whatever subset of experimental code survived Phase 1). | Modify |
| `py/harness.py` | Add `--ghost-enable`, `--ghost-edge-tol` flags. | Modify |
| `py/tests/test_models.py` | Add ghost-detector tests (covered by Phase 1 experiments, translated into production tests). | Modify |

### Pipeline timing
- Sobel-Y stage: `H_ACTIVE + 3` cycle latency on top of existing Gaussian (same streaming skeleton).
- Sobel-BG stage: same, but reads from `bg_linebuf` instead of a live AXI-Stream input.
- `motion_core` remains combinational.
- Total added latency before mask output: ~one extra line period. Needs a corresponding bump to `V_BLANK` timing if the existing margin is already tight (verify during integration; the current 16-line `V_BLANK` was sized for CCL's EOF FSM and likely has headroom).

### Resource cost (target: 320×240 @ 8-bit Y)
- 3 small BRAMs (one per sobel-y line buffer pair, one for bg_linebuf, one for sobel-bg line buffer pair — or 2 if we fuse sobel-bg's buffer with bg_linebuf).
- ~700 LUTs (2× Sobel adder trees + magnitude + comparator + updated bg_next mux).
- No change to bg RAM depth or width.

### Verification
- `make lint` clean.
- `make test-ip` — all existing unit TBs green, plus the new `tb_axis_sobel3x3`.
- `make run-pipeline` at TOLERANCE=0 for the full control-flow × parameter matrix:
  - 4 control flows × 3 sources × `{GHOST_ENABLE=0, GHOST_ENABLE=1}` × sweep of `GHOST_EDGE_TOL ∈ {Phase-1-default, ±50%}`.
- Visual check on `dark_moving_box` — confirm RTL matches the Python Phase 1 result.

### Effort estimate
~2–3 days of RTL + verification. Largest single chunk is writing and unit-testing `axis_sobel3x3.sv` (similar complexity to `axis_gauss3x3.sv`, which already exists as a template).

---

## Known Risks / Open Questions

1. **Uniform-color object interiors.** Sobel is edge-concentrated, so uniform-interior blobs have ambiguous per-pixel classifications inside. See the "Per-pixel Sobel vs blob-level classification" subsection above for the full information flow and the blob-level promotion that handles this case. The question Phase 1 answers: do our synthetic sources exhibit interior-ghost persistence with per-pixel-only Sobel, or is per-pixel enough? If the former, blob-level promotion becomes a Phase 3 requirement; if the latter, it stays deferred.

2. **GHOST_EDGE_TOL calibration depends on `GAUSS_EN`.** With Gaussian on, edge magnitudes are lower; with Gaussian off, they're sharper. We may need two defaults or a runtime scaling factor. Phase 1 sweep will reveal the needed range; if both need wildly different tolerances, make `GHOST_EDGE_TOL` a per-build parameter with a comment explaining the dependency.

3. **Shadow vs ghost.** The literature Sobel criterion can false-flag shadows as ghosts (shadows also have "edges in bg but not in y" in some cases). Our pipeline doesn't currently handle shadows at all, so this is not a regression — but worth noting that if shadow handling is later added, it should be another tier before Sobel (shadow → suppressed, not reclassified as ghost).

4. **Alternative to abandoning.** If Phase 1 shows Sobel doesn't help enough to justify the RTL cost, the fallback is the "cooldown window" idea (post-grace, K frames of mask-visible fast-EMA before selective kicks in). That's a smaller change and can be written as a separate plan if Phase 1 kills Sobel.

---

## Decision Gates Summary

| Gate | Question | If No → |
|---|---|---|
| End of Phase 1 | Do the side-by-side renders show Sobel meaningfully improving mask/motion quality with no regressions? | Abandon plan; consider cooldown-window alternative. |
| End of Phase 2 | Is the arch doc self-consistent and aligned with the Phase 1 experimental code? | Iterate on docs before starting Phase 3. |
| End of Phase 3 | Do all integration tests pass at TOLERANCE=0 and does the `dark_moving_box` visual match Phase 1's result? | Debug RTL↔Python parity gap before archiving. |

---

## Open-Endedness

This plan is intentionally **high-level**. Once Phase 1 confirms the approach, Phase 2 and Phase 3 each get their own detailed bite-sized plan with per-file TDD steps (like `2026-04-22-motion-grace-window-plan.md`). Writing those in advance would be wasted effort if Phase 1 kills the idea.

---

## Starting-state checklist (for a fresh session)

Before touching code, a new session should verify:

1. **Branch and commits:**
   ```bash
   git branch --show-current        # expect: feat/ccl (or its successor)
   git log --oneline -10            # should show the grace-window commits ending with b29ba87
   git status --short               # may show 11 staged files from the mask-gate + GRACE_ALPHA_SHIFT work
   ```

2. **If staged changes are present** (mask gate during grace + `GRACE_ALPHA_SHIFT`): decide whether to
   - **commit them as the baseline** for Phase 1 (recommended; they are the current best baseline), or
   - **build Phase 1 on top of the index** (valid; `py/experiments/` is isolated from the staged code).
   The staged state is described in the "Current motion pipeline" section above. A suggested commit message exists in the prior session transcript but was not applied.

3. **Toolchain sanity:**
   ```bash
   source .venv/bin/activate
   make lint                        # expect: PASS
   make test-ip                     # expect: all block TBs green
   pytest py/tests/ -v              # expect: 49 passing (pre-Phase-1 baseline)
   make run-pipeline SOURCE="synthetic:dark_moving_box" CTRL_FLOW=motion FRAMES=12 TOLERANCE=0
   # expect: PASS at TOLERANCE=0, with a ghost still visible in the rendered PNG post-grace
   ```

4. **Read the prior plans** (all in `docs/plans/`):
   - `2026-04-21-motion-mask-quality-design.md` — original design spec for priming + selective EMA.
   - `2026-04-22-motion-grace-window-plan.md` — bite-sized plan template for the grace window (good structural reference for Phase 3's future detailed plan).
   - `docs/specs/axis_motion_detect-arch.md` — the authoritative architecture contract. §4.4 (EMA + grace), §3.1 (params), §10.1 (current Sobel follow-up placeholder).

5. **Acceptance criteria for Phase 1's visual check** (human-in-loop): see the four bullets under "Decision gate" in Phase 1. If Phase 1 fails, the fallback is documented under "Known Risks / Open Questions #4" (cooldown-window alternative).

A fresh session with access to this plan + the repo at the stated state should be able to execute Phase 1 end-to-end without needing the prior session's chat transcript.
