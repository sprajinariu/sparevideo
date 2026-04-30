# `axis_motion_detect` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
  - [2.1 Datapath overview](#21-datapath-overview)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.1 Algorithms in this module](#41-algorithms-in-this-module)
  - [4.2 Spatial pre-filter — 3x3 Gaussian](#42-spatial-pre-filter--3x3-gaussian)
  - [4.3 Threshold comparison — polarity-agnostic absolute difference](#43-threshold-comparison--polarity-agnostic-absolute-difference)
  - [4.4 Temporal background model — EMA](#44-temporal-background-model--ema)
  - [4.5 Placement rationale](#45-placement-rationale)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Per-pixel pipeline (overview)](#51-per-pixel-pipeline-overview)
  - [5.2 Spatial pre-filter — Gaussian control](#52-spatial-pre-filter--gaussian-control)
  - [5.3 Threshold comparison and EMA — `motion_core`](#53-threshold-comparison-and-ema--motion_core)
  - [5.4 RAM addressing](#54-ram-addressing)
  - [5.5 Pipeline stages](#55-pipeline-stages)
  - [5.6 Backpressure — single-output pipeline stall](#56-backpressure--single-output-pipeline-stall)
  - [5.7 Resource cost](#57-resource-cost)
- [6. State / Control Logic](#6-state--control-logic)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_motion_detect` computes a 1-bit per-pixel motion mask by comparing the current frame's luma (Y8) against a per-pixel background model stored in the shared RAM. The background model is maintained as an exponential moving average (EMA) — each pixel's stored value tracks the temporal mean of that pixel's luma, smoothing out sensor noise and gradual lighting changes. When `GAUSS_EN=1`, a 3x3 Gaussian pre-filter (`axis_gauss3x3`) smooths the luma spatially before the threshold comparison, reducing salt-and-pepper noise in the motion mask.

The mask output is the module's **only** AXI4-Stream output. The RGB video path is handled at the top level via `axis_fork`, fully decoupled from mask processing. The module does **not** perform morphological operations on the binary mask. Color-space conversion is delegated to an instantiated `rgb2ycrcb` submodule; spatial filtering is delegated to `axis_gauss3x3`. The Y8 frame buffer lives in an external shared RAM connected via the module's memory port.

---

## 2. Module Hierarchy

```
axis_motion_detect (u_motion_detect)
├── rgb2ycrcb      (u_rgb2y)   — RGB888 → Y8, 1-cycle pipeline
├── axis_gauss3x3  (u_gauss)   — Optional 3x3 Gaussian pre-filter (GAUSS_EN=1), 2-cycle pipeline
└── motion_core    (u_core)    — Combinational: abs-diff threshold + EMA update
```

`axis_gauss3x3` (in `hw/ip/filters/rtl/`) is a synchronous pipeline element (not a
full AXIS stage). It applies a 3x3 Gaussian blur `[1 2 1; 2 4 2; 1 2 1] / 16` to the
Y channel with a 2-cycle latency. Instantiated inside a `generate` block gated by
`GAUSS_EN`; when `GAUSS_EN=0` the module is not instantiated and `y_smooth = y_cur`
(bypass). See [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) for full details.

`motion_core` (in `hw/ip/motion/rtl/`) is a pure-combinational module with no
clock or state. It takes `y_cur` (or `y_smooth` when Gaussian is enabled) and `y_bg`
as inputs and produces `mask_bit` and `ema_update` as outputs.

`axis_motion_detect` is the glue: it instantiates the three submodules, owns the
pixel address counter, manages the RGB→Y stall mux, derives Gaussian control signals,
and wires the memory ports.

### 2.1 Datapath overview

```
                          axis_motion_detect
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                                                                         │
  │  s_axis (RGB888 + tlast + tuser)  input video stream                    │
  │  ─────────┬────────────────────────────────────────────────────────     │
  │           │                                                             │
  │           │                                                             │
  │           │                                                             │
  │           ▼                                                             │
  │    ┌───────────────┐                                                    │
  │    │  rgb2ycrcb    │                                                    │
  │    │  (u_rgb2y)    │    Y8 extraction                                   │
  │    │  1-cycle pipe │                                                    │
  │    └──────┬────────┘                                                    │
  │           │ y_cur [7:0]                                                 │
  │           ▼                                                             │
  │    ┌──────────────────┐                                                 │
  │    │  axis_gauss3x3   │  Apply Gaussian3x3 blur (spatial filter)        │
  │    │  (u_gauss)       │  Reduces salt-and-pepper noise                  │
  │    └──────┬───────────┘                                                 │
  │           │ y_smooth [7:0]                                              │
  │           │                                                             │
  │           │                                                             │
  │           ▼              Apply EMA (temporal filter)                    │
  │    ┌────────────────────────────┐                                       │
  │    │     motion_core            │                                       │
  │    │     (combinational)        │ rd_data  ┌───────────┐                │
  │    │                            │◄---------│   u_ram   │ BG model       │
  │    │  diff = |y_smooth-bg|      │          | (port A)  | (Y8, H×V bytes)|
  |    |                            |---------►│           │                │
  │    │  mask = diff > THRESH      │ wr_data  └───────────┘                │
  │    │  ema  = bg + Δ>>>α         │   (ema)                               │
  │    └────────────┬───────────────┘                                       │
  │                 │ mask_bit                                              │
  │                 ▼                                                       |
  |  ───────────────┴─────────────────────────────────────────────────      |
  │  m_axis_msk (1-bit + tlast + tuser)                                     |
  |         bit=1 ─► motion pixel                                           |
  |         bit=0 ─► static pixel                                           |
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘
```

The mask output carries the motion decision for each pixel. The RGB passthrough
is handled externally at `sparevideo_top` via `axis_fork`, which routes a copy of
the input to `axis_overlay_bbox` independently of mask processing.

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line |
| `V_ACTIVE` | 240 | Active lines per frame |
| `THRESH` | 16 | Unsigned luma-difference threshold; mask is 1 when `\|Y_smooth − bg\| > THRESH`. |
| `ALPHA_SHIFT` | 3 | Non-motion EMA shift: α = 1/(1<<ALPHA_SHIFT), default 1/8. `0` reduces the EMA to raw-frame write-back. |
| `ALPHA_SHIFT_SLOW` | 6 | Motion-pixel EMA shift, default 1/64. Kept slower than `ALPHA_SHIFT` so the background barely drifts under a moving object (no trails). At 30 fps and default 6, a stopped object absorbs into bg in ~2 s. |
| `GRACE_FRAMES` | 8 | Frames after priming during which bg updates use `GRACE_ALPHA_SHIFT` regardless of `raw_motion`. Suppresses frame-0 hard-init ghosts. `0` disables. |
| `GRACE_ALPHA_SHIFT` | 1 | EMA shift inside the grace window (default α=1/2). |
| `GAUSS_EN` | 1 | `1` = instantiate `axis_gauss3x3` (`PIPE_STAGES = H_ACTIVE + 3`); `0` = bypass (`PIPE_STAGES = 1`). |
| `RGN_BASE` | 0 | Base byte-address of the bg-model region in the shared RAM. |
| `RGN_SIZE` | `H_ACTIVE×V_ACTIVE` | Byte size of the region (sanity-checked at elaboration). |

### 3.2 Ports

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| `clk_i` | input | `logic` | DSP clock (`clk_dsp`) |
| `rst_n_i` | input | `logic` | Active-low synchronous reset |
| `s_axis` | input | `axis_if.rx` | RGB888 input stream (DATA_W=24, USER_W=1; tuser=SOF, tlast=EOL). tready = `NOT pipe_valid OR msk_tready`. |
| `m_axis_msk` | output | `axis_if.tx` | Motion mask output stream (DATA_W=1, USER_W=1). tdata[0]=mask bit; 1=motion, 0=static. |
| **Memory port (to shared RAM port A)** | | | |
| `mem_rd_addr_o` | output | `logic` | RAM read address (`$clog2(RGN_BASE+RGN_SIZE)` bits) |
| `mem_rd_data_i` | input | `logic [7:0]` | RAM read data (valid 1 cycle after address) |
| `mem_wr_addr_o` | output | `logic` | RAM write address (`$clog2(RGN_BASE+RGN_SIZE)` bits) |
| `mem_wr_data_o` | output | `logic [7:0]` | RAM write data (EMA-updated background value) |
| `mem_wr_en_o` | output | `logic` | RAM write enable |

---

## 4. Concept Description

Background subtraction is a fundamental technique in video surveillance and motion detection. It maintains a model of the static background scene and detects motion by comparing each incoming pixel against this model. Pixels that differ significantly from the background are classified as foreground (motion).

### 4.1 Algorithms in this module

Three algorithms are applied in sequence to each incoming pixel, after an initial RGB → Y8 colour-space conversion:

1. **Spatial pre-filter** — 3x3 Gaussian blur on the Y channel (`axis_gauss3x3`, optional via `GAUSS_EN`). Reduces *spatial* noise before any decision is made.
2. **Threshold comparison** — `|Y_smooth − bg| > THRESH`. Produces the 1-bit motion mask. Polarity-agnostic.
3. **EMA background update** — `bg ← bg + α·(Y_smooth − bg)`. Uses the same pixel's value to refine the background model for future frames.

The ordering is fixed: spatial smoothing operates on continuous-valued luma (§4.5), and threshold + EMA update are co-sited rather than sequential — both need `Y_smooth` and `bg` simultaneously, the comparator drives the mask output and the EMA result drives the RAM write-back on the same cycle.

The three algorithms address complementary problems. The Gaussian attacks *spatial* noise (pixel-to-pixel jitter within one frame). The EMA attacks *temporal* noise (frame-to-frame jitter at one pixel) and slow illumination drift. The threshold collapses the analog difference into the binary motion decision.

### 4.2 Spatial pre-filter — 3x3 Gaussian

The Gaussian pre-filter convolves the Y channel with the kernel

```
[1 2 1]
[2 4 2]  / 16
[1 2 1]
```

before the threshold comparison. Its purpose is to suppress *spatial* high-frequency content in the luma signal — salt-and-pepper sensor noise, quantisation artefacts, and single-pixel outliers — which would otherwise produce single-pixel mask sparkle after thresholding. A 3x3 Gaussian attenuates near-Nyquist spatial content substantially while preserving edges better than a box filter of the same support, so real object boundaries remain sharp enough for the bbox reduction to work.

The pre-filter is orthogonal to the EMA. The Gaussian averages over *space* within the current frame; the EMA averages over *time* at a fixed pixel. Both are needed because real sensor noise has energy along both axes, and neither filter attenuates the other's target.

When `GAUSS_EN = 0` this stage is bypassed and `Y_smooth = Y_cur`; the rest of the datapath is identical. See [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) for line-buffer and adder-tree details.

### 4.3 Threshold comparison — polarity-agnostic absolute difference

The motion decision is `mask = (|Y_smooth − bg| > THRESH)`. Using the *absolute* difference rather than a signed difference makes the comparison **polarity-agnostic**: both arrival pixels (where a moving object now is) and departure pixels (where it was) are flagged as motion, regardless of the brightness relationship between object and background (bright-on-dark, dark-on-bright, or colour scenes).

The trade-off is that the downstream bounding box encompasses both old and new object positions, making it slightly larger than the object by approximately one frame of displacement. This oversizing is accepted as the cost of scene-type independence.

### 4.4 Temporal background model — EMA

The simplest background model — the previous raw frame — is sensitive to sensor noise: ±2–5 luma jitter between consecutive frames on a static scene produces false positives at any threshold low enough to catch real motion.

This module instead maintains an Exponential Moving Average per pixel:

```
bg[n] = bg[n-1] + α · (y[n] - bg[n-1])
```

where `α = 1 / (1 << ALPHA_SHIFT)`. This is a first-order IIR low-pass with time constant ~`1/α` frames. The "background" is therefore the long-run mean luma at each pixel — an estimate of what the pixel looks like under motion-free conditions. Motion is a deviation from that mean, not a frame-to-frame delta. Two consequences follow:

- **Sensor noise averages away.** Uncorrelated jitter has mean zero, so `bg` settles on the true static value and `|y − bg|` stays below threshold.
- **Slow lighting drift is tracked.** Gradual illumination shifts move the running mean smoothly; quiescent pixels still report no motion. Sudden jumps produce a transient that clears in ~`1/α` frames.

#### Frame-0 hard initialization

A zero-initialized RAM would produce a near-full-frame mask on frame 0 plus a multi-frame convergence ramp. Instead, frame 0 is a priming pass: every pixel writes its own `Y_smooth` directly to `bg[addr]` and the mask is forced to 0. From frame 1 onward the normal threshold + EMA path applies.

#### Selective EMA — two rates

The EMA rate switches per pixel by mask bit:

- **Non-motion** — α = `1/(1<<ALPHA_SHIFT)`, default 1/8. Tracks lighting drift and AGC.
- **Motion** — α = `1/(1<<ALPHA_SHIFT_SLOW)`, default 1/64. Nearly freezes `bg` under a moving object, preventing trails. Also sets the absorption time for stopped objects (~2 s at 30 fps with the default).

Both rates share one subtractor; the two shifts collapse into wiring at synthesis.

#### Grace window

Hard-init seeds `bg` from frame-0 luma. If a moving object is present in frame 0, its pixels' backgrounds are contaminated with foreground luma — when the object moves on, those pixels read as motion at slow rate and the "ghost" persists for ~`1/α_slow` frames.

The grace window forces the fast rate for the first `GRACE_FRAMES` frames after priming, regardless of the mask:

```
bg_next = !primed                      ? y_smooth         (frame-0 hard init)
        : (in_grace || !raw_motion)    ? ema_update       (fast)
        :                                ema_update_slow  (slow)
```

Ghosts decay at the fast rate during the window. `GRACE_FRAMES=0` disables the override.

### 4.5 Placement rationale

- **EMA reuses the same per-pixel RAM region** that a raw previous-frame buffer would have used (`RGN_BASE`, `H_ACTIVE × V_ACTIVE` bytes); only the interpretation changes (running average vs. last raw luma). No second region or second port.
- **Gaussian is internal, on Y, not an external RGB AXIS stage.** Smoothing only Y avoids 3× the line-buffer cost of an external RGB filter and keeps the video path that reaches `axis_overlay_bbox` (via `axis_fork`) sharp. The module's external interface is unchanged whether `GAUSS_EN=0` or `1`.
- **Spatial filtering must precede thresholding.** Once the diff is quantised to a 1-bit mask, averaging 0s and 1s is neither blur nor morphology — the intensity information is gone. Post-threshold binary cleanup (erode/dilate) is a separate stage downstream.

---

## 5. Internal Architecture

### 5.1 Per-pixel pipeline (overview)

Every accepted pixel flows through the same three-algorithm sequence described in §4, now expressed at the RTL signal level:

```
Y_cur    = rgb2ycrcb(R, G, B).y       // 1-cycle pipeline inside rgb2ycrcb
Y_smooth = gauss3x3(Y_cur)            // 2-cycle pipeline (GAUSS_EN=1) or bypass (GAUSS_EN=0)
bg       = mem_rd_data_i              // RAM read, 1-cycle latency after mem_rd_addr_o
diff     = abs(Y_smooth − bg)
raw_motion = (diff > THRESH)
mask     = primed ? raw_motion : 1'b0 // frame 0 mask suppressed during priming

// Two-rate EMA update — shared subtract, two arithmetic right-shifts
delta             = Y_smooth − bg                   // signed 9-bit
ema_step_fast     = delta >>> ALPHA_SHIFT           // non-motion rate
ema_step_slow     = delta >>> ALPHA_SHIFT_SLOW      // motion rate
ema_update        = bg + ema_step_fast[7:0]
ema_update_slow   = bg + ema_step_slow[7:0]

// 3:1 write-back mux selects source per pixel
bg_next = !primed     ? Y_smooth         // frame-0 hard init
        :  raw_motion ? ema_update_slow  // motion pixel → slow rate
        :               ema_update       // non-motion pixel → fast rate

mem_wr_addr_o = RGN_BASE + pix_addr
mem_wr_data_o = bg_next
mem_wr_en_o   = tvalid && tready         // only on actual acceptance
```

The remainder of this section splits along the same per-algorithm axis as §4, then covers the shared infrastructure (address counter, RAM discipline, pipeline register chain, stall handling, and resource cost).

### 5.2 Spatial pre-filter — Gaussian control

The Gaussian sits inside a `generate` block gated by `GAUSS_EN`; with `GAUSS_EN=0` the submodule is elided and `y_smooth = y_cur`. See [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) for its internal structure.

The wrapper drives the Gaussian's `valid_i`/`sof_i` from a **sticky 1-deep pending flag** that latches on AXIS acceptance and clears on Gaussian consume. The flag is sticky because the Gaussian must see `valid_i` held high across its phantom cycles (`busy_o=1`); a 1-cycle pulse would be lost. The Gaussian's `stall_i` is wired to the wrapper's `pipe_stall`, so its line buffers freeze under downstream backpressure.

### 5.3 Threshold comparison and EMA — `motion_core`

`motion_core` is pure combinational. It outputs:

- `mask_bit` — `primed && (|y − bg| > THRESH)`; gated so frame 0 emits 0.
- `raw_motion` — the ungated threshold, used by the wrapper to pick the EMA rate without re-evaluating the comparator.
- `ema_update`, `ema_update_slow` — the two next-`bg` candidates from a shared signed 9-bit subtract followed by two arithmetic right-shifts and an 8-bit add. No multipliers.

The wrapper picks the write-back source per the §4.4 grace-window formula. `mask_bit` is already `primed`-gated inside `motion_core`.

### 5.4 RAM addressing

A frame-relative `pix_addr` counter resets on SOF and increments on each accepted pixel; physical RAM address is `RGN_BASE + pix_addr`. `mem_rd_addr_o` is driven combinationally to *next* pixel's address so the read returns 1 cycle later, exactly when that pixel is processed. During stall, `pix_addr_hold` keeps the address stable.

The RAM uses **read-first** semantics on port A: a read and write to the same address in the same cycle returns the old value, which is what the EMA needs (`bg + α·(y − bg)`).

### 5.5 Pipeline stages

`PIPE_STAGES = 1 + GAUSS_LATENCY`. `GAUSS_LATENCY = H_ACTIVE + 2` (one row + one column of spatial offset plus two internal pipeline registers) when `GAUSS_EN=1`; `0` when `GAUSS_EN=0`. Total input-to-mask latency: **1 cycle** at `GAUSS_EN=0`, **H_ACTIVE+3** cycles at `GAUSS_EN=1` (323 at 320 px).

A shift register `idx_pipe` carries the pixel address through the same number of stages so `y_smooth` and `bg[P]` meet at the comparator for the same pixel `P`. The data path of `idx_pipe` carries no reset — only the validity-tracking sidebands do — so synthesis can infer SRL32 primitives (~170 LUTs at default geometry) instead of FF-per-stage.

### 5.6 Backpressure — single-output pipeline stall

The module has one AXI-Stream output (mask). On `msk_tready=0` or `gauss_busy=1`, the wrapper holds three pieces of state simultaneously to avoid silent corruption:

- **Pipeline registers freeze** (gated by `!pipe_stall`), and the sticky pending flag stays set so `valid_i` to the Gaussian remains high across its phantom cycle.
- **`rgb2ycrcb` reads from `held_tdata`** — the last accepted pixel — rather than live `s_axis_tdata`, since the upstream is free to change `tdata` after acceptance per AXI-Stream.
- **`mem_rd_addr_o` reads from `pix_addr_hold`** so the address stays put; **`mem_wr_en_o` only fires on the actual handshake** (`beat_done`), so each pixel is written exactly once.

`s_axis_tready_o` accepts a new pixel whenever the pending slot is empty or will empty this cycle.

### 5.7 Resource cost

`rgb2ycrcb` (9 multipliers + 24 FFs), optionally `axis_gauss3x3` when `GAUSS_EN=1` (see its spec for the breakdown), `motion_core` (one 8-bit subtractor, abs, comparator, 9-bit arithmetic shift, 8-bit adder), and ~3 bits × `PIPE_STAGES` of sideband pipeline registers. RAM is external. Pixel-address counter adds `$clog2(H_ACTIVE × V_ACTIVE)` bits of registered state.

---

## 6. State / Control Logic

No explicit FSM. Pipeline stall logic is combinational from `pipe_valid` and `msk_tready`. The wrapper owns the pixel address counter, stall mux, hold registers, and write-back gating.

| Signal | Meaning |
|--------|---------|
| `pipe_valid` | Output stage holds a valid pixel (`valid_pipe[PIPE_STAGES-1]`). |
| `pipe_stall` | `pipe_valid && !msk_tready` — pipeline frozen. |
| `beat_done` | `pipe_valid && msk_tready` — downstream accepted; gates `mem_wr_en_o`. |
| `pix_addr` | Frame-relative pixel index. |
| `pix_addr_hold` | Holds `mem_rd_addr_o` stable during stall. |
| `idx_pipe` | Address shift register so write-back lands at the correct pixel. |
| `held_tdata` | Last accepted pixel; feeds `rgb2ycrcb` when no accept this cycle. |
| `primed` | Latches 1 at end of frame 0; gates the bg-next mux and the mask output. |

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| RGB → Y8 (`rgb2ycrcb`) | 1 clock cycle |
| Gaussian pre-filter (`axis_gauss3x3`, `GAUSS_EN=1`) | 2 clock cycles |
| RAM read | 1 clock cycle |
| Total pixel input → mask output (`GAUSS_EN=0`) | 1 clock cycle |
| Total pixel input → mask output (`GAUSS_EN=1`) | H_ACTIVE + 3 clock cycles (323 at 320px) |
| Throughput | 1 pixel / cycle (when `msk_tready=1`) |

Frame 0 (priming): `primed == 0` for all `H_ACTIVE × V_ACTIVE` beats. Each pixel writes its own `Y_smooth` to `bg[addr]` and emits `mask_bit = 0`. By the end of frame 0 the RAM holds a valid per-pixel background model. `primed` latches to 1 on the last beat; frame 1's first pixel uses normal compare + selective-EMA.

EMA convergence (frame ≥ 1): a pixel whose true scenery value shifts by Δ converges toward the new value at rate α per frame. For non-motion pixels α = 1/8 (full convergence in ~8 frames); for motion pixels α = 1/64 (convergence / absorption in ~64 frames). Once a pixel flagged as motion returns to matching its stored bg (object departure), the mask clears on the very next frame — there is no cleanup phase because the bg was not contaminated in the first place.

---

## 8. Shared Types

None from `sparevideo_pkg` directly. Frame geometry parameters (`H_ACTIVE`, `V_ACTIVE`) match the package values when instantiated from `sparevideo_top`.

---

## 9. Known Limitations

- **No morphological post-filtering**: the binary mask is not cleaned up with erode/dilate. A single noisy pixel that survives the Gaussian pre-filter still produces a mask=1 bit. Morphological opening is deferred.
- **Fixed THRESH**: compile-time parameter. Runtime control requires promoting to an input port and a `sparevideo_csr` AXI-Lite register.
- **Fixed ALPHA_SHIFT / ALPHA_SHIFT_SLOW**: both are compile-time parameters. Different scenes may benefit from different adaptation rates; runtime control would require promotion to input ports driven by a future `sparevideo_csr` AXI-Lite register.
- **`Cr`/`Cb` unused**: `rgb2ycrcb` outputs `cb_o` and `cr_o`; only `y_o` is used. Lint waivers suppress `PINCONNECTEMPTY`/`UNUSEDSIGNAL`.
- **Single-buffered**: no double-buffering. Mid-frame RAM corruption by port B clients accessing the background model region during an active frame will produce incorrect mask bits. See the host-responsibility rule in [ram-arch.md](ram-arch.md).
- **Bbox oversizing**: the polarity-agnostic mask flags both arrival and departure pixels, so the bbox is slightly larger than the object by approximately the per-frame displacement. This is a deliberate trade-off for scene-type independence.
- **EMA rounding bias**: the arithmetic right-shift truncates toward negative infinity, introducing a small systematic bias. For typical video luma values this is negligible (sub-LSB after a few frames).
- **Frame-0 priming assumes a representative bg**: if the very first frame contains a foreground object, that object's luma is committed to the background in that region. Subsequent frames will flag the object as motion (since it still occupies that pixel) and selective EMA (slow rate) will absorb it over ~64 frames. Acceptable for typical scenes where bring-up starts with an empty frame; deliberate deployment with a pre-populated scene may want a reset sequence.

---

## 10. References

- [Background subtraction — Wikipedia](https://en.wikipedia.org/wiki/Background_subtraction)
- [Exponential moving average — Wikipedia](https://en.wikipedia.org/wiki/Exponential_smoothing)
- [OpenCV Background Subtraction tutorial](https://docs.opencv.org/4.x/d1/dc5/tutorial_background_subtraction.html)
