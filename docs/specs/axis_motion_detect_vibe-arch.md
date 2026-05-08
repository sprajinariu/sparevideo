# `axis_motion_detect_vibe` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
  - [2.1 Datapath overview](#21-datapath-overview)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.1 ViBe algorithm summary](#41-vibe-algorithm-summary)
  - [4.2 Decision rule](#42-decision-rule)
  - [4.3 Update and diffusion](#43-update-and-diffusion)
  - [4.4 Frame-0 self-initialization](#44-frame-0-self-initialization)
  - [4.5 Spatial pre-filter](#45-spatial-pre-filter)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Pipeline stages](#51-pipeline-stages)
  - [5.2 Sample-bank BRAM layout](#52-sample-bank-bram-layout)
  - [5.3 Defer-FIFO — W+1 pixel delay](#53-defer-fifo--w1-pixel-delay)
  - [5.4 K parallel comparator tree](#54-k-parallel-comparator-tree)
  - [5.5 PRNG — Xorshift32 (parallel streams for init)](#55-prng--xorshift32-parallel-streams-for-init)
  - [5.6 Backpressure — single-output stall](#56-backpressure--single-output-stall)
  - [5.7 Resource cost](#57-resource-cost)
- [6. State / Control Logic](#6-state--control-logic)
  - [6.1 Init-phase flag and self-init byte-enable](#61-init-phase-flag-and-self-init-byte-enable)
  - [6.2 External-init elaboration path](#62-external-init-elaboration-path)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_motion_detect_vibe` is a drop-in replacement for `axis_motion_detect` under `bg_model = BG_MODEL_VIBE`. It computes a 1-bit per-pixel motion mask (1 = foreground / motion, 0 = background / static) by applying the **ViBe** sample-based background model to the current frame's luma (Y8). Instead of a single running average, ViBe maintains **K stored Y8 samples** per pixel. A pixel is classified as background when at least `MIN_MATCH` of its K stored samples are within match radius `R` of the current luma value (where "within radius" means absolute difference `< R`).

The module's AXI4-Stream interface is identical to `axis_motion_detect`: one `axis_if` pixel input, one `axis_if` mask output. The top-level `bg_model` generate gate in `sparevideo_top` swaps between the two blocks transparently; no downstream module (morph, CCL, overlay) is aware of which background model is active.

The module does **not** perform morphological operations on the binary mask. Color-space conversion is delegated to `rgb2ycrcb`; optional spatial filtering is delegated to `axis_gauss3x3` (the same submodule used in `axis_motion_detect`). The sample bank is an internal dual-port BRAM; unlike `axis_motion_detect`, there is no external shared RAM port.

---

## 2. Module Hierarchy

```
axis_motion_detect_vibe (u_motion)
├── rgb2ycrcb           (u_rgb2y)   — RGB888 → Y8, 1-cycle pipeline
├── axis_gauss3x3       (u_gauss)   — Optional 3×3 Gaussian pre-filter (GAUSS_EN=1)
└── motion_core_vibe    (u_core)    — K comparators, match counter, update/diffusion logic
    └── sample_bank                 — Dual-port BRAM, 8*K bits × (WIDTH*HEIGHT) deep
```

`axis_motion_detect_vibe` is the AXIS wrapper. It owns the AXIS protocol, the pixel address counter, the stall mux, the PRNG state register, and the frame counter. It instantiates and wires `rgb2ycrcb`, optionally `axis_gauss3x3`, and one `motion_core_vibe`.

`motion_core_vibe` is the algorithm core. It holds the sample-bank BRAM, the K parallel absolute-difference comparators, the match popcount, the update/diffusion write-enable generation, and the W+1-delay defer-FIFO for diffusion writes. It takes `y_smooth`, the PRNG bit slices, and port-A read data as inputs, and produces `mask_bit`, Port-B write parameters, and the defer-FIFO push as outputs. See [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) for the filter's internal structure.

### 2.1 Datapath overview

```
                         axis_motion_detect_vibe
  ┌───────────────────────────────────────────────────────────────────────┐
  │                                                                       │
  │  s_axis_pix (RGB888 + tlast + tuser)                                  │
  │  ──────────────────────────────────────────────────────────────────   │
  │           │                                                           │
  │           ▼                                                           │
  │    ┌───────────────┐                                                  │
  │    │   rgb2ycrcb   │                                                  │
  │    │   (u_rgb2y)   │                                                  │
  │    └──────┬────────┘                                                  │
  │           │ y_cur                                                     │
  │           ▼                                                           │
  │    ┌────────────────┐                                                 │
  │    │ axis_gauss3x3  │  (optional, GAUSS_EN=1)                         │
  │    │   (u_gauss)    │                                                 │
  │    └──────┬─────────┘                                                 │
  │           │ y_smooth                                                  │
  │           ▼                                                           │
  │    ┌────────────────────────────────────────────────────────────┐     │
  │    │                   motion_core_vibe                         │     │
  │    │                                                            │     │
  │    │   Port-A read ◄── sample_bank ──► Port-B write             │     │
  │    │       │                                 ▲                  │     │
  │    │       │  samples[8*K-1:0]               │  update writes   │     │
  │    │       ▼                                 │                  │     │
  │    │   K comparators → popcount → mask   defer-FIFO             │     │
  │    │                                                            │     │
  │    └──────────────────────────────┬─────────────────────────────┘     │
  │                                   │ mask_bit                          │
  │                                   ▼                                   │
  │  m_axis_msk (1-bit + tlast + tuser)                                   │
  │         1 = foreground / motion                                       │
  │         0 = background / static                                       │
  │                                                                       │
  └───────────────────────────────────────────────────────────────────────┘
```

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `WIDTH` | 320 | Active pixels per line. |
| `HEIGHT` | 240 | Active lines per frame. |
| `K` | 8 | Samples per pixel. Constrained to {8, 20} in Phase 2. Must be a power of 2. |
| `R` | 20 | Match radius. A sample matches when `\|y_smooth − sample\| < R` (8-bit absolute difference). |
| `MIN_MATCH` | 2 | Minimum number of matching samples to classify a pixel as background. |
| `PHI_UPDATE` | 16 | Inverse self-update probability. On each background-classified pixel, one slot is overwritten with probability `1/PHI_UPDATE`. Must be a power of 2. |
| `PHI_DIFFUSE` | 16 | Inverse spatial-diffusion probability. On each background-classified pixel, one slot of a random spatial neighbor is overwritten with probability `1/PHI_DIFFUSE`. Must be a power of 2. |
| `GAUSS_EN` | 1 | `1` = instantiate `axis_gauss3x3` pre-filter; `0` = bypass (`y_smooth = y_cur`). |
| `VIBE_BG_INIT_EXTERNAL` | 0 | `0` = self-initialize sample bank from frame-0 luma; `1` = bank preloaded from `INIT_BANK_FILE` at elaboration. |
| `PRNG_SEED` | `32'hDEAD_BEEF` | Initial Xorshift32 PRNG state. SV-parameter-only; not in `cfg_t`. |
| `INIT_BANK_FILE` | `""` | Path to a `$readmemh`-format file containing the initial sample bank. Active only when `VIBE_BG_INIT_EXTERNAL=1`. SV-parameter-only; not in `cfg_t`. |

Power-of-2 constraints on `K`, `PHI_UPDATE`, and `PHI_DIFFUSE` are enforced at elaboration via `$error`. A K=20 configuration (non-power-of-2) is valid — the K-is-power-of-2 constraint applies to slot addressing inside `motion_core_vibe`; K=20 uses a different slot-select scheme described in §5.4.

### 3.2 Ports

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| `clk_i` | input | `logic` | DSP clock (`clk_dsp`). |
| `rst_n_i` | input | `logic` | Active-low synchronous reset. |
| `s_axis_pix` | input | `axis_if.rx` | RGB888 input stream (DATA_W=24, USER_W=1; tuser=SOF, tlast=EOL). tready deasserts when the pending pipeline slot is full. |
| `m_axis_msk` | output | `axis_if.tx` | Motion mask output stream (DATA_W=1, USER_W=1). tdata[0]=1 means motion; tdata[0]=0 means static. tuser=SOF, tlast=EOL, propagated from input. |

There is no external memory port. The sample bank is instantiated inside `motion_core_vibe`.

---

## 4. Concept Description

### 4.1 ViBe algorithm summary

ViBe (Barnich & Van Droogenbroeck, IEEE TIP 2011) is a **sample-based** background model. For each pixel position, the model maintains a set of K stored Y8 values drawn from recent background observations at that location and its spatial neighbors. The background/foreground decision at any pixel is a vote across K independent membership tests: if at least `MIN_MATCH` stored samples differ from the current pixel's luma by less than `R` (in absolute value), the pixel is classified as background; otherwise it is foreground (motion).

Sample-based models differ from single-value models (EMA) in two load-bearing ways. First, the K stored samples can represent **multiple background modes** at one pixel simultaneously — useful for pixels where legitimate background values fluctuate (foliage, water, flickering displays). Second, the **spatial diffusion** mechanism — which copies a pixel's observed background value into one of its 8 neighbors' sample sets — allows contaminated regions (frame-0 ghosts) to be repaired from the boundary inward over tens of frames, without the model ever being explicitly told that a ghost exists.

Full algorithm rationale and parameter-space analysis are in the master design at `docs/plans/2026-05-01-vibe-motion-design.md §2`.

### 4.2 Decision rule

The current pixel's luma `x` is compared against each of the K stored samples for that pixel. A slot **matches** when the absolute difference between `x` and the stored sample is less than `R`. The **match count** is how many of the K slots match. The pixel is classified as background when the match count is at least `MIN_MATCH`, foreground otherwise:

```
match_vec[i] = (|x − samples[p][i]| < R)  for i = 0..K-1
match_count  = match_vec[0] + match_vec[1] + ... + match_vec[K-1]
mask         = (match_count < MIN_MATCH)    -- 1 = foreground, 0 = background
```

`match_count` is a transient wire inside `motion_core_vibe` — 4 bits at K=8, 5 bits at K=20. It collapses to the 1-bit `mask` before leaving the core and is never exposed as an output.

**Foreground** (mask=1) means the pixel is classified as motion. **Background** (mask=0) means the pixel is classified as static.

### 4.3 Update and diffusion

Updates fire **only on pixels classified as background** (mask=0). A foreground pixel never modifies any of the K sample banks — neither its own nor a neighbor's. This is what keeps moving objects from being learned into the model.

**Why update at all.** Real backgrounds drift slowly (lighting changes, camera AGC, slow scene evolution). Without updates, the bank captured at frame 0 would gradually become a worse and worse match for the actual background, and false-positive motion would creep in. The two update mechanisms below adapt the model over time so it tracks the true background.

**Self-update.** When the current pixel `p` is classified as background, with probability `1/PHI_UPDATE` one of its K slots `j` (chosen uniformly from `[0, K)`) is overwritten with the current luma `x`: `samples[p][j] ← x`. The update only takes effect for the next frame's classification of pixel `p`; the current frame's classification has already used the pre-update samples.

**Spatial diffusion.** When the current pixel is classified as background, with probability `1/PHI_DIFFUSE` one of the 8 neighbors `p'` of `p` (3×3 window excluding center) has one of its slots `j'` overwritten with the same `x`: `samples[p'][j'] ← x`. The neighbor and slot `j'` are chosen uniformly. As with self-update, the write only takes effect for the next frame's classification of pixel `p'`. Diffusion is what propagates correct background information into pixel locations whose own banks are temporarily contaminated — most importantly, frame-0 ghosts behind a moving object that was present at startup.

**Why a low (1/16) probability.** Updates are stochastic so each individual frame contributes only a small adjustment. With `PHI_UPDATE = 16`, replacing all K=8 slots of a pixel takes roughly `K × PHI_UPDATE = 128` background frames on average — slow enough that a brief foreground occlusion slipping through the classifier (e.g. a single noisy frame) doesn't poison the bank, fast enough that a genuine slow background change is absorbed in seconds. The same logic applies to diffusion.

Both fires are decided independently by the PRNG bit slices for that pixel (coupled-roll convention; §5.5). When both fire on the same cycle, the self-update goes to Port B immediately and the diffusion write is pushed to the defer-FIFO (§5.3).

### 4.4 Frame-0 self-initialization

When `VIBE_BG_INIT_EXTERNAL=0`, the sample bank is seeded during frame 0 using **scheme (c)**: each slot is filled with a noise-jittered version of the current pixel's smoothed luma.

For each pixel, all K slots are written simultaneously via Port-B byte-enables set to all-ones. The write data per slot `i` is `clamp(y_smooth + noise_i, 0, 255)` where `noise_i = prng_state[i*4 +: 4] - 8` (range [-8, +7]). This matches the upstream canonical Barnich init and requires one PRNG advance per pixel — the same cadence as the runtime path. The frame-0 mask output is forced to 0 regardless of sample content. `primed` latches to 1 at the end of frame 0; frame 1 uses the normal decision rule.

At K=20, three parallel Xorshift32 streams supply the noise bits (see §5.4). The self-init byte-enable is held at `0` when `VIBE_BG_INIT_EXTERNAL=1`; the two paths are mutually exclusive.

When `VIBE_BG_INIT_EXTERNAL=1`, the BRAM is preloaded at elaboration via `$readmemh(INIT_BANK_FILE, sample_bank)`. A software tool (`py/gen_vibe_init_rom.py`) generates this file from a per-pixel temporal median over the first N input frames.

**Why this path exists.** Self-init bakes any frame-0 foreground into the bank as a "ghost" that only diffusion can dissolve, which takes 100+ frames for sizable objects — too slow for short demos and simulation. External init sidesteps the problem by computing the temporal median of N leading frames offline, which averages the moving object out. Real hardware can't see the future, so this path is for verification and demos only.

### 4.5 Spatial pre-filter

The optional 3×3 Gaussian pre-filter (`axis_gauss3x3`, enabled by `GAUSS_EN`) is identical to the filter used in `axis_motion_detect`. It attenuates spatial high-frequency noise in the Y channel before the decision rule, reducing single-pixel mask sparkle. When `GAUSS_EN=0`, `y_smooth = y_cur` and the submodule is elided. See [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) for full details.

---

## 5. Internal Architecture

### 5.1 Pipeline stages

**Per-pixel decision signals derived from the PRNG.** Two things have to be decided each pixel: *should* an update fire (the **roll** — a probability check, like a dice roll), and *if so, where should it land* (the **slot** — which of the K sample-bank slots gets overwritten). Self-update and diffusion each need their own roll and slot; diffusion additionally needs to pick which spatial neighbor to update. All five values are sliced out of one PRNG word per pixel:

| Signal | Width | Meaning |
|--------|-------|---------|
| `roll_self` | `log2(PHI_UPDATE)` | Probability check for self-update. Fires when this slice is all-zero (probability `1/PHI_UPDATE`). |
| `slot_self` | `log2(K)` | If self-update fires: index `j ∈ [0,K)` of which slot in the *current* pixel's bank is overwritten. |
| `roll_diff` | `log2(PHI_DIFFUSE)` | Probability check for spatial diffusion. Fires when this slice is all-zero (probability `1/PHI_DIFFUSE`). |
| `neighbor_idx` | 3 | If diffusion fires: which of the 8 neighbors (3×3 excluding center) receives the write. |
| `slot_neighbor` | `log2(K)` | If diffusion fires: index `j' ∈ [0,K)` of which slot in the chosen neighbor's bank is overwritten. |

Spatial neighbor encoding for `neighbor_idx[2:0]`:

```
       col-1   col   col+1
row-1   NW     N     NE      ← already read this frame
row     W      .     E       ← E is current row, ahead of read pointer
row+1   SW     S     SE      ← not yet read this frame
```

The pipeline from AXIS input acceptance to AXIS mask output is four registered stages:

| Stage | Label | Action |
|-------|-------|--------|
| S0 | Accept | AXIS pixel beat accepted. `held_tdata` latched. `pix_addr` drives Port-A read address (`pix_addr_hold` during stall). PRNG advances. |
| S1 | Compare | Port-A read data (`samples[8*K-1:0]`) lands. K parallel absolute-difference comparators run combinationally. PRNG bit slices produce `roll_self`, `slot_self`, `roll_diff`, `neighbor_idx`, `slot_neighbor`. |
| S2 | Decide | `match_count` tree completes. `mask_bit = (match_count < MIN_MATCH)`. Port-B write parameters are computed. If `roll_diff` fires on a background pixel, the diffusion write is pushed to the defer-FIFO with deadline `pix_count_s2 + W + 1`. |
| S3 | Output | AXIS-out beat becomes valid. Port-B write for self-update commits. If no self-update this cycle and the defer-FIFO head's deadline ≤ `pix_count_s2`, Port-B drains one defer-FIFO entry. |

**Total latency: 3 cycles** (S0 through S3, where S0 is the acceptance cycle and S3 is the first output-valid cycle). This matches `axis_motion_detect`'s latency, making the `bg_model` generate gate latency-neutral; no downstream skid buffer or timing adjustment is needed.

The `rgb2ycrcb` 1-cycle pipeline and the optional `axis_gauss3x3` pipeline sit upstream of S0 — their latency is absorbed into the wrapper's overall input-to-acceptance delay, not into the four stages above. The pixel address counter and sideband pipeline registers track pixel identity through the full chain.

### 5.2 Sample-bank BRAM layout

The sample bank is a single dual-port BRAM instantiated inside `motion_core_vibe`. Each address stores K samples for one pixel.

| Quantity | K=8 | K=20 |
|----------|-----|------|
| BRAM word width (bytes) | 8 | 20 |
| Byte-enable width | 8 | 20 |
| Depth (entries) | WIDTH × HEIGHT | WIDTH × HEIGHT |
| Total size at 320×240 | ~615 kB | ~1.54 MB |

Word layout: `{samples[K-1], samples[K-2], ..., samples[0]}`, MSB-first, one byte per slot. Slot `i` occupies bits `[i*8 +: 8]`.

**Port A — READ_FIRST mode.** Reads `8*K` bits at address `pix_addr` every active cycle. When a self-update write to the same address occurs on Port B in the same cycle, Port A returns the pre-update value, which is semantically correct — the comparators classify against the existing model; the update takes effect for the next frame's classification.

**Port B — registered write with byte-enables.** The byte-enable `(1 << slot_j)` selects the single slot to overwrite. During frame-0 self-init, byte-enable is `{K{1'b1}}` (all slots written simultaneously). Port B is also used by the defer-FIFO drain path for diffusion writes whose deadline has been reached.

### 5.3 Defer-FIFO — W+1 pixel delay

Diffusion writes target one of the 8 spatial neighbors of the current pixel. In raster order, four directions are *already-read* this frame and four are *not-yet-read*:

```
       col-1   col   col+1
row-1   NW     N     NE      ← already read this frame: write commits immediately, affects next frame
row     W      .     E       ← E is "ahead": at +1 pixel tick — must defer
row+1   SW     S     SE      ← all "ahead": at +W-1, +W, +W+1 pixel ticks — must defer
```

If an "ahead" diffusion write committed immediately, it would land *before* the target pixel's S0 read this frame, and the target pixel's classification would see contaminated samples. The defer-FIFO holds these writes long enough that they commit *after* the same-frame read but well before the next-frame read.

**Pixel ticks, not clock cycles.** Each entry carries a `deadline` measured in **accepted-pixel ticks**: a 32-bit `pixel_count_q` counter that increments only when the AXIS handshake actually accepts a pixel (`valid_i && ready_o && !pipe_stall_i`). It does not advance during V-blank, H-blank, or backpressure stalls, and it is **not reset between frames**. Counting in pixel ticks is what makes the W+1 delay invariant under input pacing — neighbor offsets in raster scan are always the same number of pixel ticks regardless of how often the upstream stalls.

For a diffusion firing at pixel-tick `C_fire`, the deadline is `C_fire + W + 1`. The worst-case ahead-of-firing neighbor (SE) sits exactly W+1 pixel ticks later in raster order, so a W+1 delay guarantees the write commits no earlier than that neighbor's same-frame read.

The pixel count is pipelined alongside the address as `pix_count_s1` and `pix_count_s2`. The FIFO push uses `pix_count_s2` (the firing pixel's count). The FIFO drain compares the head's deadline against the *current* `pix_count_s2`. End-of-frame firings whose deadlines spill into the next frame are still drained correctly because the counter is monotonic across frame boundaries — no special-case logic needed.

**Self-update writes do not go through the FIFO.** They target the current pixel (the one at S2) and use Port-B directly the same cycle. READ_FIRST semantics guarantee the S0 read two cycles earlier saw pre-update samples; the write commits and only the next frame's read sees the new value.

**Port-B priority per pixel cycle:**

| Source | Priority | Typical frequency |
|---|---|---|
| Frame-0 self-init (`init_phase`) | 1 (highest) | first frame only |
| Self-update for current S2 pixel | 2 | ≈ 1 / φ_update (≈ 6.25%) |
| FIFO head with deadline ≤ `pix_count_s2` | 3 | ≈ 1 / φ_diffuse on average |
| Idle | — | ≈ 88% |

When diffusion and self-update fire on the same pixel, self-update takes Port-B immediately and diffusion enqueues with the standard W+1 deadline.

**Sizing 64 entries.** At default `φ_diffuse = 16` and `W = 320`, on average one diffusion fires every 16 pixel ticks, and each FIFO entry sits in the queue for about W+1 = 321 ticks before its deadline arrives — so the typical occupancy is around 320/16 ≈ 20 entries. The actual count fluctuates because diffusion fires are random; under reasonable assumptions, transient peaks reach the high 30s. 64 entries gives roughly 60% headroom over the worst observed peak and fits comfortably in distributed LUTRAM (entry is 32-bit deadline + address + slot index + 8-bit data, ~56-64 bits × 64 entries ≈ 4 Kbit). An assertion fires in simulation if a push ever finds the FIFO near-full, so violations of this assumption surface immediately.

**Sizing assumption.** The 64-entry depth is sized for `W ≤ 640, φ_diffuse ≥ 16`. Larger frames or smaller φ require resizing (e.g. `W = 1024, φ = 16` would need ~128 entries).

**FIFO entry format:** `{deadline[31:0], addr[ADDR_W-1:0], slot[$clog2(K)-1:0], data[7:0]}`.

### 5.4 K parallel comparator tree

The comparator array is fully combinational inside `motion_core_vibe`. For each slot `i`:

```
match_vec[i] = (|y_smooth - samples[i*8 +: 8]| < R)
```

The compare is an 8-bit unsigned absolute difference: `|a - b| = (a >= b) ? (a - b) : (b - a)`.

`match_count` is produced by a binary adder tree over `match_vec[K-1:0]`. At 100 MHz, the combinational depth of this tree is comfortably within the cycle budget; no pipeline break inside the comparator array is needed.

### 5.5 PRNG — Xorshift32 (parallel streams for init)

ViBe's classification rule is deterministic, but updates and diffusion are **probabilistic**: a self-update fires with probability `1/PHI_UPDATE` per background pixel, a diffusion with probability `1/PHI_DIFFUSE`. We need a cheap source of pseudorandom bits to drive these decisions every accepted pixel.

**Xorshift32** is a small PRNG well-suited to hardware: a single 32-bit state, three XOR-shift stages, no multipliers or memory. The shift amounts `13, 17, 5` are the canonical Marsaglia values for a 32-bit Xorshift with full period (2³² − 1) and good statistical properties on standard randomness tests. One core fits in a few LUTs and meets timing easily at 100 MHz.

**Runtime PRNG (frames 1+).** A single Xorshift32 stream `prng_state` provides all random decisions during normal operation. The state register advances exactly once per accepted pixel beat, gated on `!pipe_stall`. During stall the register does not advance, so the per-pixel random decisions are a deterministic function of pixel index regardless of backpressure timing. State register: 32 bits.

**Init PRNG (frame 0 only, when `VIBE_BG_INIT_EXTERNAL=0`).** Frame-0 self-init writes K noise-perturbed luma values per pixel. Each slot needs one 8-bit noise sample, so K slots need `8*K` bits per accepted beat — more than a single 32-bit Xorshift word provides at K=20. We instantiate `N` parallel Xorshift32 streams, each with its own 32-bit state. All N streams advance once per accepted pixel beat (gated on `!pipe_stall`); their post-advance states concatenate into an `8*K`-bit noise pool. Each 8-bit lane maps to slot noise via `(byte % 41) − 20`, giving noise ∈ [−20, +20]. After frame 0 the init streams are dormant; all PRNG decisions revert to the single runtime stream.

**N as a function of K:**

| K | N | Init state bits |
|---|---|----------------|
| 8 | 2 | 64 |
| 20 | 5 | 160 |
| General | `ceil(K / 4)` | `N × 32` |

The Xorshift32 step function (shared by all streams):

```sv
function automatic logic [31:0] xorshift32(input logic [31:0] s);
    logic [31:0] x;
    x = s ^ (s << 13);
    x = x ^ (x >> 17);
    x = x ^ (x <<  5);
    return x;
endfunction
```

**Stream seeds:**

```sv
localparam logic [31:0] SEED_0 = PRNG_SEED;
localparam logic [31:0] SEED_1 = PRNG_SEED ^ 32'h9E3779B9;  // golden ratio constant
localparam logic [31:0] SEED_2 = PRNG_SEED ^ 32'hD1B54A32;
localparam logic [31:0] SEED_3 = PRNG_SEED ^ 32'hCAFEBABE;
localparam logic [31:0] SEED_4 = PRNG_SEED ^ 32'h12345678;
```

Seeds 0–1 are used at K=8 (N=2); seeds 0–4 are used at K=20 (N=5). The seed constants are part of the module's external contract — changing them changes the per-pixel noise pool and therefore every pixel of the initial bank.

**Runtime bit-slice table.** Bit slices from `prng_state` produce the runtime random decisions at compile-time-derived widths:

| Slice | Width | Usage |
|-------|-------|-------|
| `[LOG2_PHI_UPDATE-1 : 0]` | `log2(PHI_UPDATE)` | `roll_self`: fires when all bits are zero (prob `1/PHI_UPDATE`) |
| `[LOG2_PHI_UPDATE + LOG2_K - 1 : LOG2_PHI_UPDATE]` | `log2(K)` | `slot_self`: self-update target slot |
| `[... + LOG2_PHI_DIFFUSE - 1 : ...]` | `log2(PHI_DIFFUSE)` | `roll_diff`: fires when all bits are zero |
| `[... + 3 : ...]` | 3 | `neighbor_idx`: selects one of 8 neighbors |
| `[... + LOG2_K - 1 : ...]` | `log2(K)` | `slot_neighbor`: diffusion target slot |

At literature defaults (K=8, PHI_UPDATE=PHI_DIFFUSE=16), the total slice budget is 4+3+4+3+3 = 17 bits, well within the 32 available. Each probability check is a zero-test on a fixed-width slice: `P(slice == 0) = 1/2^N` — one wide-AND gate, no comparator or divider.

**Why parallel streams for init.** Chaining N advances of one stream combinationally produces consecutive outputs of the same stream, which exhibit measurable serial correlation across the K slots of one pixel. N independent streams with distinct seeds have no analytically derivable inter-stream correlation. The critical-path cost is one xorshift core regardless of N, whereas a chained design adds N cores in series. The register cost is N×32 bits for the init states — small relative to the `8*K × WIDTH × HEIGHT` sample bank.

The PRNG state registers reset to their respective seeds on `rst_n_i` deassert. `PRNG_SEED` is a compile-time SV parameter, not a `cfg_t` field. The default value is `32'hDEAD_BEEF`.

### 5.6 Backpressure — single-output stall

The module has one AXI-Stream output (`m_axis_msk`). When `m_axis_msk.tready=0`, the pipeline stalls. Five things must hold during a stall to keep state coherent:

1. **Pipeline registers freeze.** Every `always_ff` pipeline stage is gated by `else if (!pipe_stall)` so values do not advance under a held pixel.
2. **Y input mux holds the last accepted pixel.** `y_in = pipe_stall ? held_tdata_y : s_axis_pix_y`. The upstream is free to present the next pixel immediately after acceptance; `held_tdata` captures the accepted pixel and feeds `rgb2ycrcb` until the stall clears, so the comparator inputs stay stable.
3. **Port-A address holds during stall.** `pix_addr_hold` is a registered copy of `pix_addr` with enable `!pipe_stall`; it drives the Port-A read address during stall, preventing address wrap-around from changing the read result under a stalled pixel.
4. **Port-B self-update write fires only on the actual beat handshake.** `mem_wr_en = pipe_valid && m_axis_msk.tready`. The defer-FIFO push is also gated on `!pipe_stall` — a stall cycle must not double-push an already-queued diffusion write. The defer-FIFO drain fires when the FIFO head's deadline ≤ `pix_count_s2` and Port-B is otherwise idle.
5. **PRNG does not advance during stall.** The PRNG state register is gated on `!pipe_stall` (§5.5). Without this, two stalls of different durations would produce different PRNG sequences for the same pixel index, breaking determinism.

`s_axis_pix.tready` deasserts when the pipeline pending slot is full and will not clear this cycle.

### 5.7 Resource cost

| Resource | K=8 | K=20 |
|----------|-----|------|
| Sample-bank BRAM | ~615 kB (inferred dual-port, 8B wide) | ~1.54 MB (20B wide, cascaded tiles) |
| PRNG state | 96 FFs (32 runtime + 64 init, N=2 streams) | 192 FFs (32 runtime + 160 init, N=5 streams) |
| Comparators | 8 × 8-bit abs-diff | 20 × 8-bit abs-diff |
| Match-count adder tree | 3 levels, 4-bit result | 5 levels, 5-bit result |
| Defer-FIFO | 64 entries × (deadline + addr + slot + data) ≈ 4 Kbit, distributed LUTRAM | same |
| `rgb2ycrcb` | 9 multipliers, 24 FFs | (same) |
| `axis_gauss3x3` (GAUSS_EN=1) | see [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) | (same) |
| Pixel address counter | `$clog2(WIDTH × HEIGHT)` bits | (same) |

The dominant cost is BRAM. At K=8, the 64b-wide BRAM is the same order of magnitude as the scaler's line buffers. At K=20, the BRAM tile count increases proportionally; synthesis must confirm it fits within the target FPGA's block RAM budget before committing.

---

## 6. State / Control Logic

### 6.1 Init-phase flag and self-init byte-enable

The wrapper carries a one-bit `primed` register: 0 during frame 0, latched to 1 on the first end-of-frame beat, and never cleared again. From `primed` the two control signals fall out:

```
init_phase     = !primed && !VIBE_BG_INIT_EXTERNAL  // frame-0 self-init active
init_be_active = init_phase                         // Port-B writes all K slots
```

When `init_be_active=1`, Port-B byte-enable is set to `{K{1'b1}}` (all slots) and Port-B data is the noise-jittered `init_word` from the frame-0 init logic. When `init_be_active=0`, Port-B byte-enable is `(1 << slot_self)` and Port-B data is `{K{y_smooth}}` (replicated; only the enabled byte lands).

`primed` also gates the mask output: when `primed=0`, `mask_bit` is forced to 0 regardless of the comparator result.

A wide `frame_count` register is **not needed** — nothing in the design distinguishes frame 1 from frame 100. A single `primed` flip-flop carries all the state required.

| Signal | Meaning |
|--------|---------|
| `primed` | One-bit "past frame 0"; latches on the first end-of-frame beat. |
| `init_phase` | `!primed && !VIBE_BG_INIT_EXTERNAL`; frame-0 self-init is active. |
| `init_be_active` | Same as `init_phase`; selects all-ones byte-enable and init word. |
| `pipe_stall` | `pipe_valid && !m_axis_msk.tready`; freezes all pipeline registers and PRNG. |
| `pipe_valid` | Output stage (S3) holds a valid pixel. |
| `beat_done` | `pipe_valid && m_axis_msk.tready`; gates Port-B self-update write. |
| `pix_addr` | Frame-relative pixel index; increments on `beat_done`, resets on SOF. |
| `pix_addr_hold` | Stable copy of `pix_addr` during stall; drives Port-A read address. |
| `pixel_count_q` | Monotonic accepted-pixel counter (not reset across frames); drives defer-FIFO deadline computation. |
| `pix_count_s2` | `pixel_count_q` registered to S2; used as the firing pixel's count for FIFO push and drain comparison. |
| `held_tdata` | Last accepted pixel; feeds `rgb2ycrcb` while `pipe_stall=1`. |

There is no non-trivial FSM. All control is combinational from `primed`, `pipe_valid`, and `m_axis_msk.tready`.

### 6.2 External-init elaboration path

When `VIBE_BG_INIT_EXTERNAL=1`, an `initial` block inside a `generate-if` runs `$readmemh(INIT_BANK_FILE, sample_bank)` at elaboration. If `INIT_BANK_FILE` is empty, a `$error` fires at elaboration. The self-init logic (noise-jitter, frame-0 byte-enable) is inactive — `init_phase` is held at 0 by the parameter check — so the preloaded bank is visible from the first cycle of frame 0 without being overwritten. `primed` still latches normally at the end of frame 0 and the mask output is still forced to 0 across frame 0 (matching the EMA convention).

The two init paths are mutually exclusive and selected at elaboration time. There is no runtime switch between them.

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| `rgb2ycrcb` | 1 clock cycle |
| `axis_gauss3x3` (`GAUSS_EN=1`) | H_ACTIVE + 2 clock cycles |
| S0 → S3 (BRAM read + comparators + output register) | 3 clock cycles |
| Total input acceptance → mask output (`GAUSS_EN=0`) | 3 clock cycles |
| Total input acceptance → mask output (`GAUSS_EN=1`) | H_ACTIVE + 5 clock cycles |
| Throughput | 1 pixel / cycle (when `m_axis_msk.tready=1`) |

The 3-cycle S0-to-S3 latency matches `axis_motion_detect`'s latency, making the `bg_model` generate gate timing-neutral. Downstream stages (morph, CCL, overlay) require no adjustment.

Frame 0 (self-init, `VIBE_BG_INIT_EXTERNAL=0`): all H×W pixels write their noise-jittered luma to the BRAM in raster order. `mask_bit` is forced to 0 for all pixels. By the end of frame 0 the BRAM holds a fully initialized sample bank. `primed` latches to 1 on the last beat of frame 0; frame 1's first pixel uses the normal decision rule.

Frame 0 (external init, `VIBE_BG_INIT_EXTERNAL=1`): the BRAM is already initialized at elaboration. Frame 0 still runs normally but `init_phase=0`, so no frame-0 self-write occurs. `mask_bit` is forced to 0 for frame 0 (driven by `primed=0`). `primed` latches on the same end-of-frame beat.

---

## 8. Shared Types

`axis_motion_detect_vibe` is instantiated from `sparevideo_top` and receives parameters unpacked from the active `cfg_t` profile struct. The following `cfg_t` fields are consumed:

| `cfg_t` field | Parameter mapped to | Description |
|---------------|--------------------|----|
| `vibe_K` | `K` | Samples per pixel. |
| `vibe_R` | `R` | Match radius (8-bit absolute difference). |
| `vibe_min_match` | `MIN_MATCH` | Minimum matching samples for background classification. |
| `vibe_phi_update` | `PHI_UPDATE` | Inverse self-update probability. |
| `vibe_phi_diffuse` | `PHI_DIFFUSE` | Inverse spatial-diffusion probability. |
| `vibe_bg_init_external` | `VIBE_BG_INIT_EXTERNAL` | 0 = self-init; 1 = `$readmemh` external init. |
| `gauss_en` | `GAUSS_EN` | Enable optional 3×3 Gaussian pre-filter. |

The following are **SV-parameter-only** — they are not in `cfg_t` (see contract spec §2.3):

| Parameter | How set |
|-----------|---------|
| `PRNG_SEED` | Passed as a named parameter at instantiation (`32'hDEAD_BEEF` by default). |
| `INIT_BANK_FILE` | Set via Verilator `` +define+VIBE_INIT_BANK_FILE=... `` macro in the Makefile when `vibe_bg_init_external=1`. |

EMA-specific `cfg_t` fields (`motion_thresh`, `alpha_shift`, `alpha_shift_slow`, `grace_frames`, `grace_alpha_shift`) are not used by this module; they are consumed only by `axis_motion_detect` in the EMA branch of the `bg_model` generate gate.

---

## 9. Known Limitations

- **K constrained to {8, 20}.** Other values (K=6, K=12, K=16, K=32) are rejected at elaboration by `$error`. Extending to other values is a future phase.
- **Power-of-2 K assumed for slot addressing.** K=20 requires special handling of slot selection (20 is not a power of 2); the impl uses a modulo-reduction scheme for K=20 slot indices. K values other than 8 and 20 may need additional care.
- **External-init requires a `+define+` macro.** When `VIBE_BG_INIT_EXTERNAL=1`, the `INIT_BANK_FILE` path is supplied via Verilator `` +define+VIBE_INIT_BANK_FILE=... ``. This is not an AXIS or runtime-configurable interface — the path is baked in at compile time.
- **AXI4-Lite-mapped runtime BRAM aperture deferred.** There is no mechanism to load or read the sample bank via a control bus at runtime. When `vibe_bg_init_external=1`, the bank is loaded at elaboration only. A future AXI4-Lite CSR plane could map the BRAM for host-write before stream start; this is explicitly out of scope for Phase 2 (see contract spec §5).
- **3×3 diffusion neighborhood only.** Diffusion targets one of the 8 pixels in the 3×3 window excluding center. A 5×5 neighborhood (radius=2) is a known future axis for faster ghost recovery on large ghost regions; not implemented here.
- **Frame-0 ghost not fully suppressed by self-init.** Canonical self-init seeds each pixel's sample bank from its own luma, so a moving object present in frame 0 contaminates those pixels' banks. The diffusion mechanism gradually repairs the ghost over 50–150 frames (§4.3). For stronger suppression, use `VIBE_BG_INIT_EXTERNAL=1` with a temporal-median-based ROM.
- **No mask cleanup.** Like `axis_motion_detect`, this module does not apply morphological post-processing. Cleanup (open + close) is performed by the downstream `axis_morph_clean` stage.
- **Single-buffered BRAM.** No double-buffering. The sample bank is shared across the active frame and any deferred diffusion writes. Port-conflict semantics (§5.2) handle the within-frame cases; cross-frame coherence is guaranteed by the raster-scan cadence.

---

## 10. References

- Master ViBe design: [`docs/plans/2026-05-01-vibe-motion-design.md`](../plans/2026-05-01-vibe-motion-design.md) — algorithm, BRAM layout (§6), PRNG (§7), migration phasing (§9).
- Phase 2 design spec: [`docs/plans/2026-05-06-vibe-phase-2-design.md`](../plans/2026-05-06-vibe-phase-2-design.md) — parametric K, multi-stream PRNG, external-init path, top-level integration.
- `cfg_t` contract: [`docs/plans/2026-05-06-vibe-rtl-cfg-contract-design.md`](../plans/2026-05-06-vibe-rtl-cfg-contract-design.md) — field list trim, Python-only fields, `PRNG_SEED` / `INIT_BANK_FILE` SV-parameter-only rationale.
- EMA peer module: [`docs/specs/axis_motion_detect-arch.md`](axis_motion_detect-arch.md) — structural template; backpressure rules followed here.
- Submodule specs: [`docs/specs/axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md), [`docs/specs/rgb2ycrcb-arch.md`](rgb2ycrcb-arch.md).
- Barnich & Van Droogenbroeck, "ViBe: A Universal Background Subtraction Algorithm for Video Sequences," IEEE TIP 2011.
- Marsaglia, "Xorshift RNGs," Journal of Statistical Software 2003.
