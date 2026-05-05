# ViBe Motion Detector — Design

**Date:** 2026-05-01
**Status:** Design doc, ready for writing-plans handoff after user review.
**Companion:** [`2026-05-01-bg-models-survey-design.md`](2026-05-01-bg-models-survey-design.md) — survey that selected ViBe over MOG2 and PBAS.
**Scope:** Replace the frame-0-ghost-prone EMA mask producer with a sample-based ViBe core. EMA stays as a coexisting first-class option (compile-time gated). The mask consumers (morph, CCL, overlay), the video path, and everything else in the pipeline are untouched.

---

## 1. Context

The companion survey doc settled on **ViBe (Barnich & Van Droogenbroeck, IEEE TIP 2011)** as the EMA replacement, on the basis that it's the only candidate of the three considered (MOG2, ViBe, PBAS) with a *structural* fix for frame-0 ghosts (sample-diffusion across spatial neighbors), while also being the cheapest in compute (zero multiplies) and the smallest in tunability surface. See the survey's §8 for the full rationale.

This document is the design-level handoff for the eventual writing-plans implementation: it captures the algorithm, the datapath, the integration plan with the existing RTL, and the explicit decisions accumulated during brainstorming (separate peer module, 64b RAM, PRNG choice, EMA coexists). It is **not** itself an implementation plan — Phase 0 (Python ablation) gates the work, and a separate writing-plans plan follows once Phase 0 passes.

**Assumptions baked into this design:**

- **Stabilized input.** Camera-motion / jitter handling is a separate concern, addressed by the upstream [`2026-04-30-motion-stabilize-frames-design.md`](2026-04-30-motion-stabilize-frames-design.md) plan. ViBe (like EMA) assumes the input has already been stabilized; per-pixel sample matching breaks down under un-stabilized motion regardless of bg-model choice.
- **Mask output stays 1-bit binary.** Matches both the current `axis_motion_detect` AXIS contract *and* the canonical ViBe segmentation output — upstream's `segmentation_()` produces a binary 0/255 map per pixel, with the K-sample match count being a temporary internal to the decision pipeline (Python: `num_matches >= matchingNumber`; C: equivalent compare-and-set). Our design preserves this exactly: the 4-bit count *is* present as a wire inside `motion_core_vibe` after the popcount stage, but it's collapsed to 1 bit via `count ≥ min_match` before leaving the core, same as upstream. If a future downstream stage wants confidence-as-mask, that wire can be exposed with no algorithm change.
- **Single-channel Y8 feature.** The canonical ViBe algorithm is channel-extensible — upstream C ships both grayscale (`8u_C1R`) and color (`8u_C3R`, summed |Δ| across channels with threshold scaled by 4.5×) variants. Doc B's design takes the single-channel path (Y8) for cost and consistency with the existing pipeline (RGB → Y8 happens upstream of motion-detect). 3-channel RGB is a future axis if Y8-only proves insufficient; not implemented in this design.
- **No LBSP / texture feature.** Intensity-only. The bg-model axis (sample-based ViBe) and the feature axis (Y8 intensity) are separable: an LBSP descriptor could be retrofitted in a later iteration without changing the sample-storage / decision core. Out of scope here per "start simple" framing.
- **Forward-only temporal processing.** Streaming hardware processes frames in arrival order. The upstream README mentions "backwards analysis of images in a video stream" as an algorithmic innovation (process video in reverse temporal order to suppress ghosts at startup, then merge with the forward pass) — that's an application-level technique requiring a full-video-stored offline pipeline and is structurally incompatible with our streaming live-input architecture.

---

## 2. ViBe algorithm summary

For each pixel, the algorithm maintains **K stored sample values** (Y8 bytes) instead of a single bg estimate. Decision and update rules are entirely subtraction + comparison + bit count — no multiplies, no statistics.

**State per pixel.** K samples, plain Y8: `samples[0..K-1] : uint8`. Default K=8 (literature uses K=20; we cut for memory).

**Decision rule** (incoming sample `x`):

```
count = |{ i : |x − samples[i]| < R }|       # K parallel comparators
mask  = (count < min_match)                  # foreground if too few samples agree
```

Defaults: `R = 20`, `min_match = 2`. Mask = 1 means motion, 0 means background.

**Update rule** (only when classified as bg):

- With probability `1/φ_update` (default `φ_update = 16`, ~6.25% of bg pixels): pick a random slot `j ∈ [0, K)` and overwrite `samples[j] ← x` at the **current pixel**.
- With probability `1/φ_diffuse` (default = `φ_update`): pick a random one of the **8 spatial neighbors (3×3 window excluding center)**, pick a random slot `j' ∈ [0, K)`, and overwrite `samples[j']` of **that neighbor** with `x`. ← This is the **sample-diffusion mechanism that fixes frame-0 ghosts**: contaminated regions are repaired by their boundary leaking correct samples inward.

  *Note:* The upstream Python reference uses a 9-cell window *including* center (`randint(-1,+1)` per axis) — when (0,0) is selected, the diffusion write becomes a redundant self-update. Doc B excludes center for hardware cleanliness (the 8 useful targets are addressable with 3 PRNG bits, no degenerate-case handling needed).

**Initialization** (frame 0). For each pixel, fill its K samples by random draws from its 3×3 spatial neighborhood in frame 0. This gives every pixel a non-trivially-distributed initial stack from cycle 1.

**Why this fixes frame-0 ghosts.** A frame-0 foreground pixel ends up with a contaminated stack (all samples ≈ foreground color). When the foreground leaves, true-bg samples don't match → classified motion → no self-update happens. But the *neighbors* (correctly classified bg) fire diffusion writes, leaking real-bg samples into the contaminated region's stacks. The ghost dissolves from the boundary inward, parallel across all boundary pixels — typically 50–150 frames at default parameters, independent of region shape.

**Convergence math (for sizing Phase-0 expectations).** Convergence is **boundary-driven and parallel**. A ghost region with `B` boundary pixels has roughly `B / (k · φ_diffuse)` successful *inward* neighbor-diffusions per frame, where `k` is a small geometry constant (~5–8, depending on what fraction of each boundary pixel's 8 neighbors point into the ghost — corners contribute more than flat edges). Once any interior pixel accumulates `≥ min_match` correct samples it flips to bg-classified and becomes a diffusion source for its own neighbors, so the inward cascade accelerates. **Empirically** (Barnich & Van Droogenbroeck 2011, canonical "stationary fg at frame 0, removed at frame 1" test) full ghost dissipation takes **50–150 frames at φ_diffuse=16** across a wide range of region shapes. The implications for Phase 0:

- Convergence time scales roughly with `φ_diffuse · diameter`, not `φ_diffuse²` — the cascade dominates for any non-pathological region.
- Stronger dependence on `φ_diffuse` than on shape; lowering φ_diffuse from 16 to 8 should roughly halve convergence time.
- A solid ghost a few hundred pixels across is the worst case; thin/elongated ghosts converge faster (more boundary per area).

**Configuration.** Five `cfg_t` knobs (plus a deterministic PRNG seed):

| Field | Meaning | Default | Constraint |
|---|---|---|---|
| `K` | Samples per pixel | 8 | power of 2 (slot indices are clean bit slices) |
| `R` | Match radius (Y8 absolute distance) | 20 | 0 ≤ R ≤ 255 |
| `min_match` | Min matching samples to call bg | 2 | 1 ≤ min_match ≤ K |
| `phi_update` | Inverse self-update probability | 16 | **power of 2** (see §7.2) |
| `phi_diffuse` | Inverse diffusion probability | 16 | **power of 2** (see §7.2) |
| `prng_seed` | Initial Xorshift32 state | 0xDEADBEEF | non-zero |

The power-of-2 restriction on `phi_update` / `phi_diffuse` is what keeps the probability comparison free in hardware (a fixed-width zero-check on a PRNG bit slice — no comparator, no divider). The literature uses φ = 16 throughout, so this restriction loses nothing in expressiveness; it just forces the tuning surface into coarse log-scale steps (4, 8, 16, 32, 64) rather than fine integer steps.

**Note on the φ-split.** The canonical ViBe algorithm (Barnich 2011, upstream C/Python references) uses a **single** `updateFactor` covering both rolls — self-update and neighbor-diffusion fire together with one shared probability `1/φ`. Doc B exposes them as **two independent fields** (`phi_update`, `phi_diffuse`) because the two rolls tune different failure modes: `phi_update` controls temporal adaptation rate (analog of EMA's α), `phi_diffuse` controls spatial error-correction rate (the unique-to-ViBe ghost-recovery mechanism). Setting `phi_update == phi_diffuse` recovers canonical behavior exactly. The split adds zero hardware cost (each is its own zero-check) and zero algorithmic risk; it just opens a tuning axis Phase 0 may want to explore (e.g., `phi_diffuse=8` for faster ghost recovery while keeping `phi_update=16` for steady model state).

### 2.1 Why K parallel comparisons — advantages of the decision rule

The decision rule

```
count = |{ i ∈ [0,K) : |x − samples[i]| < R }|
mask  = (count < min_match)
```

is doing more than "compare against bg." It runs K=8 **independent membership tests** against a stack of recent bg observations and accepts the pixel as bg only if **at least 2 of them agree**. Five distinct advantages over single-sample / single-EMA-value comparison, each motivating the K and `min_match` choices.

**1. Multi-modal background per pixel.** A single pixel can legitimately see multiple bg values over time — a leaf swaying in/out of frame, water reflecting different colors, a flickering display, a windshield catching alternating reflections. EMA or single-sample compare can only sit on the *average* of those values, where it matches none of them and flags every variation as motion. The K=8 stack stores *actual past values*; any new pixel matching *any* stored mode (within R) contributes to the count. The stack natively represents up to K distinct bg modes per pixel simultaneously.

> *Concrete example:* a pixel under foliage that alternates Y=120 (sky) and Y=80 (leaf) every few frames. EMA settles at bg≈100; neither sky nor leaf is within THRESH=16 of bg, so both flag as motion → permanent flicker mask. ViBe holds samples like `[120, 80, 118, 82, 121, 79, …]`; each new sky or leaf observation finds ≥2 matches → both correctly classified bg.

**2. Voting robustness against individual stack contamination.** With `min_match=2`, a single corrupt or stale slot cannot single-handedly cause a false bg classification. If one slot got polluted (a misclassified update wrote a foreground value into it), the pixel is still correctly classified motion as long as the other 7 slots disagree with that polluted value. The decision is a **2-of-K vote** — robust to single-point stack failures.

> *Concrete example:* a slow-moving fg object briefly stops, gets misclassified bg for one frame, slot 5 of its pixel's stack absorbs the fg value. Single-sample compare would now classify any future appearance of that fg value as bg (a permanent ghost). K=8 / min_match=2 only flips to bg if a *second* slot also matches the fg value — requiring a sustained misclassification window, not a single frame of error.

**3. Long-term memory of rare bg modes.** The random-replacement update preserves old samples with non-zero probability indefinitely — each slot has `1/K` chance of being the next one overwritten on any update. So a sample of a rare-but-valid bg observation (the brief glimpse of true background between two passes of a waving leaf) persists with probability `(1 − 1/K)^N ≈ exp(-N/K)` after N updates. A strict-FIFO "oldest-first" replacement would evict the rare sample as soon as the leaf cycle returned; random replacement preserves it long enough that when the rare bg appears again, it usually finds a match in the stack.

> *Concrete example:* pixel where a leaf occludes the actual bg 90% of the time. After 80 update events at K=8, a rare-bg sample seen at update 0 still has ~exp(-10) ≈ 4.5% survival probability; after 16 updates, ~13% — long enough that when the rare bg appears again, it usually still has at least one matching slot.

**4. Diffusion landing zone (the frame-0-ghost mechanism).** The sample-diffusion mechanism that fixes frame-0 ghosts requires contaminated pixels to *accumulate* correct samples gradually rather than flip on the first leak. With K=8 slots, a neighbor's leaked good sample lands in one of 8 positions; the contaminated pixel doesn't flip to bg until ≥2 slots are correct. Diffusion gets multiple frames to land good samples one at a time without prematurely flipping the pixel on a single leaked sample (which might itself be wrong if the neighbor was on the boundary of misclassification). **This is the direct connection between K and our stated problem:** K=1 sample-bank with diffusion would still suffer frame-0 ghosts because every diffusion overwrite is binary — no gradual accumulation, no recovery from "diffusion landed a wrong sample." K=8 + min_match=2 makes the recovery process **statistically robust**, not just topologically possible.

**5. Smooth lighting-drift tracking.** With probability `1/φ_update` per bg pixel per frame, one of K slots is overwritten with the current value. Expected time before a given slot is replaced: `K · φ_update` frames (= 128 at K=8, φ=16). The stack thus adapts at roughly `1/(K · φ_update) = 1/128` per frame to current values — equivalent to EMA with α ≈ 1/128, but with the multimodality advantage of (1) layered on top.

#### Why `min_match = 2` specifically

The threshold value matters as much as K does:

| `min_match` | Behavior | Why not |
|---|---|---|
| **1** | Bg if *any* single sample matches | Too permissive — single-slot contamination causes false-bg directly. Reduces the K-of-K vote to 1-of-K, losing advantage 2. |
| **2** ← chosen | Bg if *any 2* samples match | Minimum that gives multi-sample voting. Robust to single-slot pollution. **Barnich 2011 default.** |
| **K−1 (=7)** | Bg if all-but-one match | Too restrictive — normal sensor noise drifts ≥1 sample outside R every frame, dropping the count below K−1 → every clean pixel reads as motion. |
| **K (=8)** | Bg only if all match | Brittle — equivalent to "we've never seen anything else." Any noise or any of advantages (1)/(3) is broken by demanding total consensus. |

`min_match=2` is the sweet spot: requires **corroboration** (defeats single-slot contamination, advantage 2) without requiring **consensus** (preserves multimodal representation, advantage 1, and tolerates the diversity that random-replacement intentionally maintains, advantage 3). The Barnich paper specifically argues 2 is optimal: "We empirically observed that 2 matches is sufficient and robust; higher values bring no improvement and increase false positives."

#### Implication for Phase 0 / writing-plans

Treat K and `min_match` as **load-bearing parameters**, not free variables. K=8 is already a memory-driven downward compromise from the literature K=20; reducing further (K=4, K=2) collapses several of the advantages above. Likewise, `min_match` should not be raised "for fewer false positives" — that defeats advantage 1. The right tuning surface for false-positive rate is **R** (match radius); for ghost convergence speed it is **φ_diffuse**. Reach for those knobs, not for K or `min_match`.

---

## 3. Datapath

The block decomposes into a wrapper (`axis_motion_detect_vibe`) that owns the AXIS plumbing, RAM port, and PRNG, plus a pure-combinational core (`motion_core_vibe`) that holds the comparator array and decision logic.

### 3.1 Wrapper-level dataflow

```
                       axis_motion_detect_vibe
   ┌─────────────────────────────────────────────────────────────────────┐
   │                                                                     │
   │   s_axis (RGB888 + tlast + tuser)                                   │
   │   ─────► rgb2ycrcb ──y_cur──► [opt. axis_gauss3x3] ──y_smooth──┐    │
   │            (1 cycle)            (when CFG.gauss_en=1)            │   │
   │                                                                  ▼   │
   │                                            ┌──────────────────────┐ │
   │   m_axis_msk (1-bit + tlast + tuser) ◄──── │  motion_core_vibe    │ │
   │                                            │  (combinational)     │ │
   │                                            └─┬───────▲────────────┘ │
   │                                              │       │              │
   │                              update writes   │       │ samples[63:0]│
   │                                              ▼       │              │
   │                            ┌─────────────────────────────────────┐  │
   │                            │  Sample bank RAM                    │  │
   │                            │   64 b × 76,800 deep                │  │
   │                            │   port A: read   (every cycle)      │  │
   │                            │   port B: write  (slot byte-enable) │  │
   │                            │   + 4-deep defer-write FIFO         │  │
   │                            └─────────────────────────────────────┘  │
   │                                                                     │
   │   PRNG (Xorshift32, 1 step per pixel) ─► slot j, slot j',           │
   │                                          neighbor sel,              │
   │                                          self/diff fire flags       │
   └─────────────────────────────────────────────────────────────────────┘
```

The RGB→Y and optional 3×3 Gaussian stages are **the same submodules used today** in `axis_motion_detect`. Instantiated identically; bit-exact behavior preserved.

### 3.2 motion_core_vibe internals

The core is pure combinational — same shape as the existing `motion_core` (which is also combinational), just wider input/output and a popcount instead of a single subtract+compare.

```
                      motion_core_vibe (combinational)

   y_smooth[7:0]
         │             samples[63:0] = {s7 s6 s5 s4 s3 s2 s1 s0}
         │                   │  │  │  │  │  │  │  │
         │                   ▼  ▼  ▼  ▼  ▼  ▼  ▼  ▼
         └─► (broadcast) ─► [|y − s_i| < R]  × 8 parallel comparators
                                  │
                                  ▼
                            match_vec[7:0]
                                  │
                                  ▼
                           ┌─────────────┐
                           │  popcount   │   (bit count, 4-bit result)
                           └──────┬──────┘
                                  │  count[3:0]
                                  ▼
                          [count ≥ min_match] ?
                                  │
                                  ▼
                              mask_bit
                          (0 = bg, 1 = motion)


   Update generation (also combinational; the wrapper applies the writes).
   PRNG bit slices are sized at compile time from CFG.phi_*/K (powers of 2).
   At literature defaults (φ_update=φ_diffuse=16, K=8) the slicing reduces to:

      prng[3:0]   == 0   → self_update_fires    (prob 1/16, zero-check on 4 bits)
      prng[6:4]          → self slot j ∈ [0, 7]
      prng[10:7]  == 0   → diff_update_fires    (prob 1/16, zero-check on 4 bits)
      prng[13:11]        → neighbor sel ∈ [0, 7]
      prng[16:14]        → diff slot j' ∈ [0, 7]

   For other parameter choices, slice widths and offsets adjust:
   width(roll_self)   = log2(phi_update)
   width(slot_self)   = log2(K)
   width(roll_diff)   = log2(phi_diffuse)
   etc. See §7.2 for the SV parameterization.
```

**No multiplies, no divides, no FSM in the core.** The 8 comparators run in parallel; the 8-bit popcount is a small adder tree (Xilinx fitting: < 10 LUTs total).

### 3.3 Pipeline depth

End-to-end mask latency from `s_axis` valid to `m_axis_msk` valid is the same as today's EMA path, ±1 cycle:

| Stage | Cycles |
|---|---|
| `rgb2ycrcb` | 1 |
| `axis_gauss3x3` (when `gauss_en`) | 2 |
| Sample-RAM read (port A registered output) | 1 |
| `motion_core_vibe` combinational | 0 |
| Output register | 1 |
| **Total** (gauss enabled) | **5 cycles** |

EMA today is 4–5 cycles depending on the same Gaussian gate, so latency parity is essentially unchanged. Downstream blocks (morph, CCL, overlay) are insensitive to the absolute latency anyway — bbox sideband is latched at EOF.

---

## 4. Integration with the current pipeline

### 4.1 What stays unchanged

| Block | Role | Why it still fits |
|---|---|---|
| [`axis_fork`](../../hw/ip/axis/rtl/axis_fork.sv) | Broadcasts input RGB to video and mask paths | ViBe lives on the mask path; fork is bg-model-agnostic. |
| [`rgb2ycrcb`](../specs/rgb2ycrcb-arch.md) | RGB888 → Y8 | Same coefficients as today; bit-exact preserved. |
| [`axis_gauss3x3`](../specs/axis_gauss3x3-arch.md) | 3×3 Gaussian pre-filter | Pre-filtering reduces sensor noise *before* the bg model — synergistic with ViBe the same way it is with EMA. `CFG.gauss_en` gate keeps working unchanged. |
| [`axis_motion_detect`](../../hw/ip/motion/rtl/axis_motion_detect.sv) (existing) | Existing EMA wrapper | **Untouched.** Stays as the EMA path, zero code edits. All existing EMA profiles (`default`, `default_hflip`, `no_ema`, `no_morph`, `no_gauss`, `no_gamma_cor`, `no_hud`, `no_scaler`) keep passing without re-verification. |
| [`motion_core`](../../hw/ip/motion/rtl/motion_core.sv) (existing) | EMA combinational core | **Untouched.** |
| [`axis_morph_clean`](../specs/axis_morph_clean-arch.md) | Mask cleanup (open + close) | ViBe still produces some boundary salt-and-pepper during diffusion convergence. Morph cleans it the same way it cleans EMA's noise. |
| [`axis_ccl`](../specs/axis_ccl-arch.md), [`axis_overlay_bbox`](../specs/axis_overlay_bbox-arch.md) | Mask consumers | Consume a 1-bit AXIS mask. ViBe produces a 1-bit AXIS mask. They don't know the difference. |
| [`py/profiles.py`](../../py/profiles.py), `cfg_t` profile system | Parameter struct mirrored Python ↔ SV | Mechanism reused; new fields added (see §5). `test_profiles.py` parity test catches drift. |
| `make verify` at TOLERANCE=0 | Python ref ↔ RTL bit-exact compare | Unchanged. The new Python ref `py/models/motion_vibe.py` joins the existing dispatch via `run_model()`. |

No new AXIS stage. No CDC change. No top-level rewiring beyond a single generate gate (§5). No VGA-side change.

### 4.2 What changes (the delta)

**New files:**

- [`hw/ip/motion/rtl/axis_motion_detect_vibe.sv`](../../hw/ip/motion/rtl/axis_motion_detect_vibe.sv) — peer wrapper, AXIS in/out + 64b memory port + PRNG, instantiates `rgb2ycrcb`, optional `axis_gauss3x3`, and `motion_core_vibe`. Mirrors `axis_motion_detect`'s shape but with the wider memory port.
- [`hw/ip/motion/rtl/motion_core_vibe.sv`](../../hw/ip/motion/rtl/motion_core_vibe.sv) — pure combinational K=8 comparator-array + popcount + decision + update-write generation.
- [`docs/specs/axis_motion_detect_vibe-arch.md`](../specs/axis_motion_detect_vibe-arch.md) — new arch spec for the new module.
- `hw/ip/motion/tb/tb_axis_motion_detect_vibe.sv` — new unit testbench.
- [`py/models/motion_vibe.py`](../../py/models/motion_vibe.py) — Python reference. Coexists with `py/models/motion.py`'s EMA path; the `run_model()` dispatch picks based on `cfg.bg_model`.
- `py/models/ops/xorshift.py` — Xorshift32 helper, mirrored bit-exactly in SV.

**Lightly touched files:**

- [`hw/top/sparevideo_top.sv`](../../hw/top/sparevideo_top.sv) — add a `bg_model` generate gate at the motion-detect instantiation site (§5).
- [`hw/top/sparevideo_pkg.sv`](../../hw/top/sparevideo_pkg.sv) — add `bg_model_e` enum + ViBe-specific `cfg_t` fields (`K`, `R`, `min_match`, `phi_update`, `phi_diffuse`, `prng_seed`, `bg_model`). EMA fields stay; consumed only when `bg_model == BG_MODEL_EMA`.
- [`py/profiles.py`](../../py/profiles.py) — mirror the new fields and add `default_vibe`, `vibe_k20`, `vibe_no_diffuse` profiles.
- [`hw/ip/motion/motion.core`](../../hw/ip/motion/motion.core) — add the new SV files to the FuseSoC core file.
- [`py/models/__init__.py`](../../py/models/__init__.py) — register `motion_vibe` in the dispatch.

That's it. The existing EMA module / core / spec / tests are not opened.

---

## 5. bg_model selection — top-level generate gate

The selection lives in `sparevideo_top`, not inside any wrapper. This mirrors how filters are gated today (`gauss_en`, `morph_en`, `scaler_en`, `hud_en`).

```sv
// hw/top/sparevideo_pkg.sv (additions)
typedef enum logic [1:0] {
  BG_MODEL_EMA  = 2'd0,
  BG_MODEL_VIBE = 2'd1
  // BG_MODEL_PBAS reserved for future
} bg_model_e;

typedef struct packed {
  // ... existing fields ...
  bg_model_e bg_model;
  int        K;             // ViBe: samples per pixel
  int        R;             // ViBe: match radius
  int        min_match;     // ViBe: min matching samples
  int        phi_update;    // ViBe: inverse self-update probability
  int        phi_diffuse;   // ViBe: inverse diffusion probability
  int        prng_seed;     // ViBe: Xorshift32 initial state
} cfg_t;
```

```sv
// hw/top/sparevideo_top.sv (excerpt at the motion-detect instantiation)
generate
  if (CFG.bg_model == BG_MODEL_EMA) begin : g_motion_ema
    axis_motion_detect      #(.CFG(CFG))     u_motion (.s_axis(...), .m_axis_msk(...), .mem(mem_8b));
  end else begin : g_motion_vibe
    axis_motion_detect_vibe #(.CFG(CFG))     u_motion (.s_axis(...), .m_axis_msk(...), .mem(mem_64b));
  end
endgenerate
```

**Only the selected branch synthesizes.** The unused module + its memory port + its dependent RAM are pruned. No double cost; no runtime selection.

### Profile sketch

| Profile | `bg_model` | Notes |
|---|---|---|
| `default` (current) | `EMA` | **Behavior preserved.** Default profile stays on EMA — zero regression risk for existing tests. |
| `default_vibe` (new) | `VIBE` | New canonical ViBe profile. K=8, R=20, min_match=2, φ_update=φ_diffuse=16. |
| `vibe_k20` (new) | `VIBE` | K=20 (literature default). Compares K=8 quality vs. K=20 at higher RAM cost. |
| `vibe_no_diffuse` (new) | `VIBE` | `phi_diffuse=∞` → ablate the spatial diffusion mechanism. **Should reproduce the frame-0 ghost.** Validates that diffusion is the actual fix (negative-control profile). |
| `vibe_no_gauss` (new) | `VIBE` | `gauss_en=0`. Verifies ViBe handles raw input as well as filtered. |
| `no_ema` (existing) | `EMA` | Unchanged. |
| `default_hflip` (existing) | `EMA` | Unchanged. |
| ... | ... | All existing EMA profiles unchanged. |

The `vibe_no_diffuse` profile is the most important diagnostic — it's the negative control proving that diffusion is what fixes the ghost, not some other side effect.

---

## 6. Sample storage — 64-bit wide RAM

### 6.1 Layout

A single dual-port BRAM, one logical block, with byte-enables on the write port.

```
                  pixel 0     pixel 1     pixel 2     ...    pixel 76,799
   addr = p:  [s7|s6|s5|s4|s3|s2|s1|s0] [...]      [...]    [...]
               └──────── 64 bits ──────┘
               one byte per sample slot, 8 slots per pixel

   Port A (read):  read 64b at addr p          every cycle
                   port-mode = READ_FIRST       (sees pre-update samples)
   Port B (write): byte_en = 1 << j             (overwrite single slot)
                   addr   = p_target            (current pixel or neighbor)
                   data   = y_smooth replicated  (only enabled byte lands)
```

**Total:** 64 b × 76,800 = 4.92 Mbit ≈ 615 KB. About 8× the current EMA bg RAM. This is the binding cost of the migration.

**Why one wide RAM, not 8 banks of 8b:**

- Single floorplan story, single port-conflict story (the deferred-write FIFO).
- Total BRAM bits identical to the 8-bank approach.
- Byte-enables make slot-selective writes a single primitive write transaction — no per-bank mux logic.
- Simpler reasoning for verification and lint.

### 6.2 Per-cycle behavior

Every cycle, port A reads `addr = pixel_addr`. Port B activity depends on the random rolls and the bg/fg classification:

| Cycle type | Port A | Port B | Frequency |
|---|---|---|---|
| Idle (mask=fg, or no random fires) | read | nothing | ~89% |
| Self-update (mask=bg, prng[3:0]==0) | read | write addr=p, BE=1<<j | ~5.5% |
| Diffusion only (mask=bg, prng[10:7]==0, prng[3:0]≠0) | read | write addr=p_neighbor, BE=1<<j' | ~5.5% |
| Joint (both fire same cycle) | read | write self **and** push diffusion to defer-FIFO | ~0.4% |
| Defer drain | read | write a queued diffusion | as needed |

The 4-deep defer-FIFO is generously sized — peak depth ≤ 1 in practice because joint cycles are rare and idle-Port-B cycles are abundant.

**Alternative considered: vblank-deferred neighbor-write queue.** Instead of a continuous defer-FIFO that drains opportunistically every cycle, an alternative is to *collect* neighbor diffusion writes into a per-frame queue and apply them all during vblank (when port A is idle). Bounded queue size ≈ pixels-per-frame / `φ_diffuse` ≈ 4,800 entries at default `φ`, which fits in BRAM. The continuous-FIFO approach is preferred because (a) it keeps writes spread across the active region rather than batched at frame boundaries (smoother memory access pattern), (b) the FIFO depth requirement is a single-digit number rather than thousands, and (c) it avoids consuming vblank cycles that are already budgeted for other end-of-frame work (e.g., the CCL FSM). The vblank-queue approach would only become attractive if the same-cycle joint-fire collision proves problematic in synthesis timing.

### 6.3 BRAM port modes

- **Port A — READ_FIRST**: when port B writes to `p` the same cycle that port A reads `p` (the self-update case), port A sees the **pre-update** samples. The comparators classify against the *old* model; the update writes back. This is the semantically correct order.
- **Port B — registered write**: writes commit at end-of-cycle, visible to the next cycle's port-A read. This handles the E-neighbor diffusion case (write to `p+1` at cycle T, read of `p+1` at cycle T+1) cleanly.

Both port modes are FPGA-BRAM defaults — no exotic configuration.

### 6.4 Diffusion-write timing across raster scan

Diffusion writes target one of 8 spatial neighbors. In raster scan their relative-to-current read happens in one of four ways:

| Neighbor direction | Last/Next read | Effect of the write |
|---|---|---|
| Above line (NW, N, NE) | Already read this frame | Modifies for *next frame's* classification. ✓ |
| Same line, west (W) | Read 1 cycle ago | Modifies for *next frame*. ✓ |
| Same line, east (E) | Read 1 cycle from now | Write commits at end of cycle T; next-cycle read sees it. Standard registered-write port-B mode handles this. ✓ |
| Below line (SW, S, SE) | Not yet read this frame | Lands ahead of the natural read — works as intended. ✓ |

So diffusion writes always land "for a future read," never racing the current read. The W/E same-line cases are the only subtle ones, both covered by the port modes above.

### 6.5 Frame-0 initialization

The bg model needs to be seeded before frame 1 starts streaming. Three init schemes were considered; **scheme (c) is the chosen default** because it matches the upstream C/Python reference verbatim, simplifying the Phase-0 cross-check (§8 step 2).

| Scheme | What it does | Source | Extra cycles | Extra LUTs | Extra RAM |
|---|---|---|---|---|---|
| (a) 3×3 neighborhood draws | For each pixel, draw K samples from its 3×3 spatial neighborhood in frame 0 | original Barnich 2011 paper | 0 (with 1-line warmup absorbed in frame 0) | ~150 | ~960 B (3-line Y8 buffer) |
| (b) Degenerate stack | All K slots = current pixel value | our cheap fallback | 0 | ~5 | 0 |
| **(c) Current ± noise** ← chosen | All K slots = `clamp(y_smooth + noise_i, 0, 255)` with independent small noise per slot | upstream C / Python reference (Van Droogenbroeck) | **0** | **~80** | 0 |

**Why (c).** Phase-0 cross-check requires our re-impl's mask-coverage curve to track the upstream reference within ±10% (§8 step 2). With scheme (a) or (b), some of that ±10% budget gets eaten by init-difference noise rather than algorithmic divergence. With scheme (c) — same init as upstream — the only divergence sources are the PRNG (different seed/family) and arithmetic precision (integer vs. floating-point), both genuine algorithmic differences we can reason about. Cleanest oracle.

**Implementation (scheme c).** Active only during frame 0 (gated by a frame-counter register that the wrapper already maintains for EMA's existing hard-init path). One PRNG advance per pixel, sliced into 8 small signed offsets, applied in parallel:

```sv
// Active only during frame 0
logic signed [4:0] noise   [0:7];
logic signed [9:0] sum     [0:7];
logic        [7:0] sample  [0:7];

genvar i;
generate
  for (i = 0; i < 8; i++) begin : g_init_lanes
    assign noise[i]  = $signed({1'b0, prng_state[i*4 +: 4]}) - 5'sd8;       // [-8, +7]
    assign sum[i]    = $signed({2'b0, y_smooth}) + 10'(noise[i]);
    assign sample[i] = (sum[i] < 0)   ? 8'd0
                     : (sum[i] > 255) ? 8'd255
                     :                   sum[i][7:0];
  end
endgenerate

wire [63:0] init_word = {sample[7], sample[6], sample[5], sample[4],
                         sample[3], sample[2], sample[1], sample[0]};

// During frame 0:
//   port_B.addr = pixel_addr
//   port_B.data = init_word
//   port_B.be   = 8'hFF             // write all 8 lanes
//   mask_bit    = 1'b0              // forced bg, downstream sees an empty mask frame 0
```

**Cycle cost: zero.** Frame-0 init runs in the same 1 px/clk cadence as the running pipeline; the only thing that changes is the byte-enable on port B (`8'hFF` during frame 0 vs. `1<<j` during frames ≥ 1) and the source of `port_B.data` (`init_word` vs. single-byte `y_smooth` replicated). No FSM stall, no extra cycles.

**Note on noise range.** Upstream's `rand() % 20 - 10` gives [-10, +9]. Our 4-bit slice gives [-8, +7]. The slight range reduction (3-bit-ish difference per slot) is dominated by the comparator's R=20 radius anyway — even at the extremes, the noised samples are well within R of `y_smooth`. Phase-0 ablation will confirm parity.

**Note on PRNG slice correlation.** The 8 noise values come from 8 different 4-bit slices of one Xorshift32 word. They're not statistically independent, but Xorshift32 mixes well enough that for frame-0 init this is negligible — we just need the K=8 samples per pixel to be spatially diverse, not cryptographically independent. If Phase-0 shows artifacts, we can advance the PRNG K times per pixel during frame 0 (still 1 cycle per pixel — Xorshift32 chains combinationally) at the cost of extra LUTs.

**Schemes (a) and (b) remain available** as alternatives. Phase-0 ablation should empirically compare all three on `synthetic:moving_box` and `synthetic:dark_moving_box` — if (c) shows no quality benefit over (b) on real footage, we can switch to (b) for the smaller LUT footprint. If (a) shows meaningful benefit over (c), we can revisit at the cost of the line buffer.

---

## 7. PRNG — Xorshift32

ViBe needs ~17 random bits per pixel per cycle (decision flags for self-update + diffusion, plus three 3-bit slot/neighbor indices). A single global Xorshift32 advanced once per pixel produces 32 well-mixed bits per cycle, generously covering this need.

### 7.1 The function

```
state ← state ⊕ (state << 13)
state ← state ⊕ (state >> 17)
state ← state ⊕ (state <<  5)
output = state               // 32 random bits per cycle
```

Period 2³² − 1 ≈ 4.3 billion. At 76,800 advances per frame the same pixel position sees the same state every ~56,000 frames (~15 minutes at 60 fps) — well past any meaningful timescale.

### 7.2 SV implementation

The probability-comparison trick: for an N-bit slice of a uniform-random word, `P(slice == 0) = 1/2^N`. So a "fires with probability `1/φ`" check, when `φ = 2^N`, is just "the low N bits of the PRNG slice are all zero." No comparator, no divider — a fixed-width zero-check, ~1 LUT. The slice width is set at compile time from `CFG.phi_*`.

```sv
// hw/ip/motion/rtl/axis_motion_detect_vibe.sv (PRNG block)
logic [31:0] prng_state;

function automatic logic [31:0] xorshift32 (input logic [31:0] s);
  logic [31:0] x;
  x = s ^ (s << 13);
  x = x ^ (x >> 17);
  x = x ^ (x <<  5);
  return x;
endfunction

always_ff @(posedge clk_i) begin
  if      (!rst_n_i)     prng_state <= CFG.prng_seed;
  else if (px_advance)   prng_state <= xorshift32(prng_state);
end

// Compile-time-derived slice widths from the φ parameters.
// φ must be a power of 2 (compile-time-checked below).
localparam int LOG2_K           = $clog2(CFG.K);            // 3 for K=8
localparam int LOG2_PHI_UPDATE  = $clog2(CFG.phi_update);   // 4 for φ=16
localparam int LOG2_PHI_DIFFUSE = $clog2(CFG.phi_diffuse);  // 4 for φ=16

initial begin
  assert(CFG.phi_update  == (1 << LOG2_PHI_UPDATE))
    else $fatal(1, "phi_update must be a power of 2");
  assert(CFG.phi_diffuse == (1 << LOG2_PHI_DIFFUSE))
    else $fatal(1, "phi_diffuse must be a power of 2");
  assert(CFG.K           == (1 << LOG2_K))
    else $fatal(1, "K must be a power of 2");
end

// Bit-slice budget (low-to-high). Adjacent slices, no overlap:
//   [LOG2_PHI_UPDATE-1 : 0]                                                   self-update fires?
//   [LOG2_PHI_UPDATE + LOG2_K - 1                : LOG2_PHI_UPDATE]           self slot j
//   [LOG2_PHI_UPDATE + LOG2_K + LOG2_PHI_DIFFUSE - 1
//                                                : LOG2_PHI_UPDATE + LOG2_K] diffusion fires?
//   ... + LOG2_K bits for neighbor index, + LOG2_K bits for neighbor slot.
// At default (φ=16, K=8) this is 4 + 3 + 4 + 3 + 3 = 17 bits, well under the 32 available.

wire        roll_self_update =  (prng_state[LOG2_PHI_UPDATE  - 1 : 0] == '0);
wire [LOG2_K-1 : 0] slot_self =   prng_state[LOG2_PHI_UPDATE  + LOG2_K - 1
                                            : LOG2_PHI_UPDATE];
wire        roll_diffusion   =  (prng_state[LOG2_PHI_UPDATE  + LOG2_K + LOG2_PHI_DIFFUSE - 1
                                            : LOG2_PHI_UPDATE  + LOG2_K] == '0);
wire [2:0]  neighbor_idx     =   prng_state[LOG2_PHI_UPDATE  + LOG2_K + LOG2_PHI_DIFFUSE + 2
                                            : LOG2_PHI_UPDATE  + LOG2_K + LOG2_PHI_DIFFUSE];
wire [LOG2_K-1 : 0] slot_neighbor
                             =   prng_state[LOG2_PHI_UPDATE + LOG2_K + LOG2_PHI_DIFFUSE + 2 + LOG2_K
                                            : LOG2_PHI_UPDATE + LOG2_K + LOG2_PHI_DIFFUSE + 3];
```

Cost: ~32 FFs (PRNG state) + 3 XORs combinational (Xorshift step) + two wide-zero ANDs (the two `roll_*` checks) + bit slicing (no logic). **< 50 LUTs total**, independent of the φ values within the supported range (4..64).

The `LOG2_PHI_*` slice widths and the corresponding zero-check widths are all set at compile time. Verilator and synthesis tools both handle parameter-driven bit slicing natively. The 17-bit example in the comments above is the literature-default budget; with φ=64 it grows to 19 bits; with K=16 it grows to 23 bits — all comfortably under the 32-bit PRNG output.

### 7.3 Python mirror

```python
# py/models/ops/xorshift.py
def xorshift32(state: int) -> int:
    state ^= (state << 13) & 0xFFFFFFFF
    state ^= (state >> 17)
    state ^= (state <<  5) & 0xFFFFFFFF
    return state & 0xFFFFFFFF
```

The Python reference must use this — *not* `random.random()`, *not* `numpy.random` — and seed identically to the SV. Same advance order (one step per pixel, raster order), same slicing. This is what makes `make verify` at TOLERANCE=0 work bit-exactly across the stochastic algorithm.

This pattern mirrors how `rgb2ycrcb`'s 8-bit fixed-point coefficients are mirrored Python ↔ SV today; the PRNG just becomes another mirrored op under `py/models/ops/`.

### 7.4 Determinism

- Same constant seed every reset → same PRNG sequence every run.
- Visual quality is unaffected (no human notices the same micro-pattern of "which sample got replaced when" between two simulations).
- Debugging benefit: failing tests are reproducible.
- If we ever want different sequences per run for stress testing, the seed becomes a TB plusarg — easy.

---

## 8. Phase-0 ablation gate (mandatory before any RTL work)

Survey-doc-confirmed gating discipline — Phase-0 Python ablation must pass before opening a writing-plans plan for the RTL.

1. **Implement vanilla ViBe** (K=8 and K=20 variants) in `py/experiments/motion_vibe.py` from the paper's pseudocode. Self-contained numpy port, deterministic Xorshift32 PRNG, integer arithmetic only. Mirrors what the `py/models/motion_vibe.py` parity reference will look like once promoted in Phase 1.

2. **Qualitative cross-check against the authors' upstream PyTorch reference** (Van Droogenbroeck et al., kept *outside* this repo's tree per its evaluation-only license). Run upstream on the same test sources at the same nominal parameters as our re-impl. Validate that our deterministic re-impl is qualitatively faithful: per-frame mask-coverage curves track within ≈ ±10%, ghost dissipation falls in the same window of frames. Bit-exact match is *not* expected (different PRNG, floating-point) — qualitative agreement is the bar. If divergence is meaningful, our re-impl is wrong; fix before continuing.

3. **Run our re-impl** on the existing motion-pipeline test sources, with focus on the ones that exercise the ghost mechanics:
   - `synthetic:moving_box`, `synthetic:dark_moving_box`, `synthetic:noisy_moving_box`, `synthetic:textured_static`, `synthetic:lighting_ramp`.
   - The real-world clip used for the README demo (frame-0 ghost is most visible there).

4. **Render side-by-side vs. current EMA** on each source. Measure per source:
   - Frame at which ghost falls below visible threshold (visual + per-frame `count_motion_pixels` curve).
   - False-positive rate during steady state.
   - Detection latency on real motion start.
   - The negative-control `vibe_no_diffuse` parameter set: confirm it reproduces the frame-0 ghost (validates that diffusion is the mechanism).

5. **Decision gate.** ViBe ghost convergence ≤ 200 frames (≤ 3 s at 60 fps) on the real-world clip; false-positive rate no worse than current EMA on `textured_static`; negative-control reproduces the ghost. Otherwise: escalate to PBAS Phase-0 (same ablation, with adaptive R/T) before opening any RTL plan, or accept and document the slower convergence as good enough for the project's footage.

6. **If the gate passes**, the next document is a writing-plans plan derived from this design doc.

---

## 9. Migration phasing

Three steps, each independently testable and revertible.

| Step | Scope | Files touched | Verify gate |
|---|---|---|---|
| **0** | Python `py/experiments/motion_vibe.py` (deterministic numpy + Xorshift32). Cross-checked qualitatively against upstream PyTorch reference. Side-by-side vs. EMA on existing test sources. Negative-control `phi_diffuse=∞` ablation. | New: `py/experiments/motion_vibe.py`, `py/experiments/upstream_baseline_outputs/` (gitignored) | Re-impl tracks upstream within ~10% per-frame mask coverage. Frame-0 ghost converges < 200 frames on real-world clip. No false-positive regression on `textured_static`. Negative control reproduces ghost. (See §8.) |
| **1** | Promote experiment to `py/models/motion_vibe.py`. Add `cfg_t.bg_model` field + ViBe fields. Wire `run_model()` dispatch. Add `default_vibe`, `vibe_k20`, `vibe_no_diffuse`, `vibe_no_gauss` profiles. RTL still EMA-only (Python ref runs against EMA for ViBe profiles via `make sw-dry-run`). | Edit: `sparevideo_pkg.sv`, `py/profiles.py`, `py/models/__init__.py`. New: `py/models/motion_vibe.py`, `py/models/ops/xorshift.py`, `py/tests/test_motion_vibe.py`. | All existing profiles still pass `make verify` (they're EMA, untouched). New ViBe profiles produce sane Python output. `test_profiles.py` parity passes. |
| **2** | Add RTL `motion_core_vibe` + `axis_motion_detect_vibe`. Top-level generate gate at `sparevideo_top`. New unit tb. New arch spec. | New: `hw/ip/motion/rtl/{axis_motion_detect_vibe.sv, motion_core_vibe.sv}`, `hw/ip/motion/tb/tb_axis_motion_detect_vibe.sv`, `docs/specs/axis_motion_detect_vibe-arch.md`. Edit: `sparevideo_top.sv`, `motion.core`. | New ViBe profiles pass `make run-pipeline ... CFG=default_vibe` at TOLERANCE=0 vs. Python ref. All existing EMA profiles still pass unchanged. `make lint` clean. `make test-ip` passes for the new unit tb. |

Pattern matches `axis_morph3x3_open`'s `morph_en=0` bypass and `axis_scale2x`'s `scaler_en=0` bypass — known-good migration shape in this codebase.

---

## 10. Open questions / risks

To resolve before or during the writing-plans plan. **None of these block the design as-is** — they are concerns to be answered with concrete data once Phase 0 begins.

### 10.1 FPGA-class BRAM budget validation

The 64b × 76,800 sample bank consumes ~615 KB. Combined with the existing scaler line buffers, CCL state RAM, and other on-chip storage, this puts pressure on the BRAM tile budget for any small/mid FPGA target. **Action:** before Phase 2, run `verilator --bbox` (or the actual synth tool's resource report on the target part) on a `default_vibe`-configured top-level to confirm the BRAM count fits. If it doesn't fit, fallback options ordered by cost:

- Drop K from 8 to 6 (47 KB savings, mild quality loss per literature).
- Use Y6 instead of Y8 storage (160 KB savings, mild quality loss).
- Move EMA out of the build (smaller cfg_t, slightly leaner top — but tiny savings).

### 10.2 Exact byte-enable / write-port semantics for the chosen BRAM IP

The 64b dual-port BRAM with byte-enables is a vendor-specific primitive. Xilinx 7-series, UltraScale, and Verilator's behavioral BRAM model all support this, but the exact instantiation pattern (inferred-by-coding-style vs. explicit primitive) and the read-during-write behavior (`READ_FIRST` vs. `WRITE_FIRST` vs. `NO_CHANGE`) vary. **Action:** before Phase 2 RTL, confirm the project's preferred BRAM coding style by inspecting one of the existing BRAM users (`axis_motion_detect`'s mem port, the scaler line buffers, the CCL state RAM) and follow that idiom. Verilator's BRAM model handles all three port modes correctly, so simulation isn't the constraint — synthesis-tool behavior is.

### 10.3 Phase-0 ablation gate failure path

If Phase 0 shows ViBe ghost convergence is unacceptably slow (>200 frames on real-world clip) the survey doc says "escalate to PBAS." Concretely this means:

- Adding per-pixel adaptive R(x) and T(x) per the Hofmann CVPRW 2012 paper.
- ~30–50% more per-pixel RAM (an extra ~200–300 KB).
- A larger `cfg_t` knob surface (~14 fields).
- The same migration phases, but with PBAS as the target.

**Decision criterion:** if the gate fails at >200 frames but ≤500 frames, accept ViBe and document the slower convergence as a known limitation (the project's typical footage is short clips where 500 frames = 8 s is fine). If the gate fails at >500 frames, escalate to PBAS.

This is a brainstorming-level decision; the actual call comes after Phase 0 produces data.

### 10.4 Frame-0 init mode (validate scheme c against alternatives)

§6.5 settled on scheme (c) — current ± noise — as the chosen default because it matches the upstream C/Python reference verbatim. **Action:** Phase-0 ablation should still empirically compare all three schemes (a/b/c) on `synthetic:moving_box` and `synthetic:dark_moving_box`. If (b) degenerate-stack shows no quality regression vs. (c), switch to (b) for the smaller LUT footprint. If (a) neighborhood-draws shows a meaningful ghost-convergence advantage over (c) on the real-world clip, revisit at the cost of a 3-line Y8 buffer. The default stays (c) unless data motivates a change.

### 10.5 Python ref vs. RTL parity discipline for stochastic algorithms

This is the first stochastic algorithm in the project's verification chain — every other reference model is deterministic-from-input. The discipline that the Python ref uses Xorshift32 with the same seed and same advance order as RTL is a *new* convention. **Action:** during Phase 1, add a `test_motion_vibe.py` test that explicitly checks the Python ref's PRNG output matches a reference golden at fixed seed (a small frozen 32-bit sequence). This protects against future Python edits silently breaking the parity contract.

### 10.6 K=8 sample-set mode-diversity erosion on dynamic backgrounds

Vanilla ViBe at K=8 is known in the literature to lose mode diversity over long runs on truly multi-modal backgrounds (waving foliage, rippling water, fluttering flags), because the random-replacement update policy gradually homogenizes the sample stack. K=20 (the literature default) is more robust on such scenes; K=8 is our memory-budget compromise. **Action:** Phase-0 ablation should explicitly stress-test K=8 against the upstream reference at K=20 on a textured / dynamic-bg synthetic source — same input frames, both implementations, side-by-side mask coverage curves over a long sequence (≥500 frames). If K=8 substantially degrades steady-state false-positive rate on dynamic-bg, options are (a) raise K to 12 or 16 with proportional RAM increase, (b) accept the limit and document, (c) add the morph_clean post-stage to absorb the residual flicker (already in the pipeline). This is the chief known-weakness of ViBe per the survey doc — flagging here so it doesn't get rediscovered during writing-plans.

### 10.7 Neighborhood radius (3×3 today; 5×5 as future axis)

The diffusion mechanism picks one of 8 spatial neighbors (3×3 window excluding center). The upstream Python reference exposes `neighborhoodRadius` as a constructor parameter (default 1 → 3×3). Some research extensions of ViBe use radius=2 (5×5 window, 24 useful targets) for stronger spatial coupling on larger ghost regions or coarser textures. Doc B fixes radius=1 for hardware simplicity (3 PRNG bits to address 8 targets; index decoding is a small mux). **Action:** if Phase 0 shows ghost convergence is slow on the real-world clip due to large ghost regions (≫30×30 px), revisit radius=2 in writing-plans — costs 5 PRNG bits to address 24 targets, plus a wider mux. Not in scope here; flagged as a known future axis.

---

## 11. References

- Barnich & Van Droogenbroeck, "ViBe: A Universal Background Subtraction Algorithm for Video Sequences," IEEE TIP 2011.
- *Patent:* US 8,009,918 B2 (filed 2009-08-13, granted, Univ. of Liège). Equivalent grants in EP (EP 2 015 252) and JP (JP 4699564). Expected expiry ~2029. Patent track: WO 2009/007198. The patent covers the full algorithm: sample-based bg, random time sampling, spatial propagation, frame-0 neighborhood initialization. For learning / personal-use this is acceptable. The algorithm is fully described in the paper and reimplementable from the spec — no licensed code is required to build a Python reference or RTL. Commercial deployment of *any* implementation (ours or otherwise) requires counsel.
- Marsaglia, "Xorshift RNGs," Journal of Statistical Software 2003.
- Companion survey: [`2026-05-01-bg-models-survey-design.md`](2026-05-01-bg-models-survey-design.md).
- Project prior art: [`docs/plans/motion-pipeline-improvements.md`](motion-pipeline-improvements.md), [`docs/plans/2026-04-22-lbsp-vibe-motion-pipeline-plan.md`](2026-04-22-lbsp-vibe-motion-pipeline-plan.md), [`docs/specs/axis_motion_detect-arch.md`](../specs/axis_motion_detect-arch.md), [`docs/plans/2026-04-30-motion-stabilize-frames-design.md`](2026-04-30-motion-stabilize-frames-design.md) (upstream stabilization assumed).
- Authors' upstream reference (eval-license): `https://github.com/vandroogenbroeckmarc/vibe`. Used for Phase-0 qualitative cross-check, kept outside this repo's tree.
