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
  - [4.5 Placement rationale — no incremental RAM for EMA](#45-placement-rationale--no-incremental-ram-for-ema)
  - [4.6 Placement rationale — why the Gaussian is internal, not an external AXIS stage](#46-placement-rationale--why-the-gaussian-is-internal-not-an-external-axis-stage)
  - [4.7 Placement rationale — why spatial filtering must be pre-threshold](#47-placement-rationale--why-spatial-filtering-must-be-pre-threshold)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Per-pixel pipeline (overview)](#51-per-pixel-pipeline-overview)
  - [5.2 Spatial pre-filter implementation — 3x3 Gaussian](#52-spatial-pre-filter-implementation--3x3-gaussian)
  - [5.3 Threshold comparison implementation](#53-threshold-comparison-implementation)
  - [5.4 Temporal background model implementation — EMA](#54-temporal-background-model-implementation--ema)
  - [5.5 Pixel address counter](#55-pixel-address-counter)
  - [5.6 RAM read/write discipline](#56-ram-readwrite-discipline)
  - [5.7 Pipeline stages](#57-pipeline-stages)
  - [5.8 `idx_pipe` — SRL-inferred shift register](#58-idx_pipe--srl-inferred-shift-register)
  - [5.9 Memory read address timing](#59-memory-read-address-timing)
  - [5.10 Backpressure — single-output pipeline stall](#510-backpressure--single-output-pipeline-stall)
  - [5.11 Resource cost](#511-resource-cost)
- [6. State / Control Logic](#6-state--control-logic)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. Follow-Ups / Future Improvements](#10-follow-ups--future-improvements)
  - [10.1 Edge-match ghost detector (Sobel-based)](#101-edge-match-ghost-detector-sobel-based)
  - [10.2 Motion-stuck per-pixel counter (ViBe-style)](#102-motion-stuck-per-pixel-counter-vibe-style)
- [11. References](#11-references)

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
| `THRESH` | 16 | Unsigned luma-difference threshold; motion detected when `diff > THRESH` |
| `ALPHA_SHIFT` | 3 | EMA smoothing factor as a bit-shift: alpha = 1 / (1 << ALPHA_SHIFT). Default 3 → alpha = 1/8. Higher values = slower background adaptation. When 0, the EMA reduces to raw-frame write-back (bg_new = Y_cur) |
| `ALPHA_SHIFT_SLOW` | 6 | EMA smoothing factor applied when the current pixel is flagged as motion (`raw_motion=1`). alpha = 1 / (1 << ALPHA_SHIFT_SLOW). Default 6 → alpha = 1/64. Larger than `ALPHA_SHIFT` so motion pixels barely drift the background estimate, preventing foreground bleed (trails). When a flagged pixel stays flagged (stopped object), this rate governs absorption into the background; with default 6 at 30 fps, a stopped object absorbs in ~2 s. |
| `GAUSS_EN` | 1 | Gaussian pre-filter enable. 1 = instantiate `axis_gauss3x3` (H_ACTIVE + 2 cycle latency from rgb2ycrcb, `PIPE_STAGES = H_ACTIVE + 3`). 0 = bypass (raw Y, `PIPE_STAGES=1`). Compile-time parameter propagated via `-GGAUSS_EN=` |
| `GRACE_FRAMES` | 8 | Number of frames after priming during which bg updates use the fast EMA rate unconditionally (ignoring raw_motion). Suppresses frame-0 hard-init ghosts. Set to 0 to disable (recover pre-grace selective-EMA behavior). |
| `RGN_BASE` | 0 | Base byte-address of the background model region in the shared RAM |
| `RGN_SIZE` | `H_ACTIVE×V_ACTIVE` | Byte size of the background model region (sanity-checked at elaboration) |

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

The ordering is fixed for two reasons:

- **Spatial filtering must precede thresholding.** Spatial smoothing operates on continuous-valued luma; once the signal has been quantised to a 1-bit mask, averaging 0s and 1s is neither a blur nor a morphological op. See §4.7 below.
- **Threshold and EMA update are co-sited, not sequential stages.** Both need `Y_smooth` and `bg` simultaneously, and both fire in the same cycle: the comparison drives the mask output, and the EMA result drives the RAM write-back. See §4.5 below.

The three algorithms address complementary noise and adaptation problems. The Gaussian attacks *spatial* noise (uncorrelated pixel-to-pixel jitter within one frame). The EMA attacks *temporal* noise (uncorrelated frame-to-frame jitter at one pixel) and slow illumination drift. The threshold collapses the analog difference into the binary motion decision that downstream stages consume.

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

The simplest background model would store the previous frame's raw pixel values. However, raw frame differencing is sensitive to sensor noise — random ±2–5 luma jitter between consecutive frames on a static scene triggers false positives when the threshold is set low enough to detect real motion.

This module instead uses an Exponential Moving Average (EMA) as the background model. The EMA updates the background estimate with a weighted blend of the old estimate and the new observation:

```
bg[n] = bg[n-1] + α · (y[n] - bg[n-1])
      = (1 - α) · bg[n-1] + α · y[n]
```

where `α = 1 / (1 << ALPHA_SHIFT)` is the adaptation rate. The EMA acts as a first-order IIR low-pass filter with time constant `τ ≈ 1/α` frames.

#### What the EMA attempts to estimate

The EMA estimates the **long-run mean luma at each pixel** — an approximation of what that pixel looks like when nothing is happening there. "Background" in this module is therefore not a specific past frame; it is a running expectation of each pixel's value under quiescent (motion-free) conditions. Motion is then defined as a short-term deviation from this expectation, rather than a difference between two consecutive frames.

This framing has two consequences that together define what the EMA buys over raw previous-frame differencing:

1. **Fast, zero-mean fluctuations are averaged away (noise suppression).** Sensor noise — thermal jitter, quantization, AGC wiggle of roughly ±2–5 luma levels on a static scene — is uncorrelated frame-to-frame. Its running mean at each pixel is approximately the true static value. A pixel jittering ±5 around 100 settles to `bg ≈ 100`, and `|y − bg|` stays well below the motion threshold. Raw previous-frame differencing is memoryless: every frame-to-frame jitter sample is compared fresh, so the full ±5 range can exceed a low threshold and produce false positives.
2. **Slow, directional changes are tracked (lighting adaptation).** A gradual illumination shift (clouds, time-of-day, AGC settling) moves the long-run mean at many pixels uniformly. The EMA follows the drift smoothly — each frame the background moves `(y − bg) >> ALPHA_SHIFT` toward the new value — so quiescent pixels continue to report no motion during the shift. A sudden illumination jump instead produces a transient of motion that clears within `~1/α` frames as the mean catches up. Raw previous-frame differencing either perfectly tracks slow changes (masking them entirely) or reports a full-frame false positive on any sudden jump.

In short: raw previous-frame differencing treats every frame-to-frame change as signal. The EMA instead builds a per-pixel *model* of "normal" and flags only deviations from that model.

#### Frame-0 hard initialization

The background RAM is zero-initialized on reset, which would produce a multi-frame convergence ramp (and near-full-frame mask=1 on frame 0). Instead, a single-bit `primed` register gates the module into a one-frame priming pass:

- While `primed == 0` (first frame only): every accepted pixel writes its own `Y_smooth` value directly to `bg[addr]`, and `mask_bit` is forced to 0. No EMA is applied.
- `primed` latches to 1 on the last beat of frame 0 (`end_of_row && out_row == V_ACTIVE-1 && beat_done`). Frame 1's very first pixel sees `primed == 1`.
- From frame 1 onward: normal threshold + selective-EMA compute path applies.

An earlier design considered raw first-frame priming (write `y_cur` straight to bg, **but also compute mask**). That was rejected because any foreground object present in frame 0 would be committed to the background and then, when it moved, leave a departure ghost for `~1/alpha` frames. The current design avoids this by **suppressing the mask output during priming** and, more importantly, combining priming with selective EMA (next subsection) so subsequent frames do not keep rewriting the background under moving objects.

#### Selective EMA — two rates

The EMA rate differs based on the current pixel's mask bit:

- **Non-motion pixel** (`raw_motion = 0`) — `alpha = 1 / (1 << ALPHA_SHIFT)`, default 1/8. Tracks slow scene changes (illumination drift, AGC).
- **Motion pixel** (`raw_motion = 1`) — `alpha = 1 / (1 << ALPHA_SHIFT_SLOW)`, default 1/64. Nearly freezes the background under a moving object, which is what prevents trail formation. Also governs absorption of objects that stop moving; at 30 fps and default 6, a stopped object is absorbed in ~2 s.

Both rates share one subtractor; the two shifts are constant fan-outs of the same signed `ema_delta`, so synthesis collapses the cost.

#### Grace window

Frame-0 hard-init seeds bg directly from frame-0 luma. If any pixel is
occupied by a moving object during frame 0, that pixel's bg is contaminated
with foreground luma. In frame 1 the object has moved on, so the pixel
shows true background vs. a foreground-valued bg and is flagged as motion
— a "ghost" at the object's frame-0 location.

Under the plain selective-EMA rule, this ghost updates at the slow rate
(α ≈ 1/64) and persists for ~64 frames.

The grace window overrides the rate selector for the first GRACE_FRAMES
frames after priming completes:

```
  in_grace = primed && (grace_cnt < GRACE_FRAMES)

  bg_next = !primed                      ? y_smooth
          : (in_grace || !raw_motion)    ? ema_update       (fast, α = 1/(1<<ALPHA_SHIFT))
          :                                 ema_update_slow (slow, α = 1/(1<<ALPHA_SHIFT_SLOW))
```

`grace_cnt` is a wrapper-level register, `$clog2(GRACE_FRAMES+1)` bits,
reset to 0 and incremented on every `beat_done` at end-of-frame
(i.e., `beat_done && end_of_row && out_row == V_ACTIVE-1`) while
`primed && grace_cnt < GRACE_FRAMES`. Once `grace_cnt == GRACE_FRAMES` the
counter saturates and the mux reverts to the plain selective-EMA rule.

During the grace window the ghost decays at α ≈ 1/8 — within GRACE_FRAMES=8
frames the bg[P_original] has moved ~66% of the way toward true background,
and `|y_cur - bg| < THRESH` becomes true soon after (exact convergence
depends on luma delta and THRESH). The mask output is NOT gated by grace;
residual ghosts during grace are visible but fade quickly and CCL/bbox
suppression (PRIME_FRAMES=2) already hides the worst of the first two frames.

Setting GRACE_FRAMES=0 disables the override: in_grace is always false, and
behavior reverts to plain selective-EMA (preserved for regression parity).

### 4.5 Placement rationale — no incremental RAM for EMA

The EMA reuses the **same** per-pixel RAM region (`RGN_BASE`, `H_ACTIVE × V_ACTIVE` bytes) that a raw previous-frame buffer would have used. The region still holds one 8-bit value per pixel; only the interpretation of that value changes — it is now a running average rather than the last raw luma. No second region, no second port, no additional BRAM is required. Port A remains a single 1R1W access per pixel, so there is no port contention between reads and writes.

### 4.6 Placement rationale — why the Gaussian is internal, not an external AXIS stage

The Gaussian pre-filter (`axis_gauss3x3`) is instantiated **inside** `axis_motion_detect`, on the internal Y channel between `rgb2ycrcb` and the threshold comparison. It is not a standalone AXIS stage in `sparevideo_top`. This placement is deliberate for three reasons:

1. **Y-only smoothing, not RGB smoothing.** Placing the Gaussian externally on the RGB stream would either require smoothing all three channels (3× the line-buffer cost) or splitting Y out at the top level. Smoothing inside the motion detector operates on the single Y channel after `rgb2ycrcb`, minimizing line-buffer resources.
2. **RGB passthrough stays sharp.** The video path that reaches `axis_overlay_bbox` (via `axis_fork` at the top level) is the *original* RGB stream. Smoothing RGB upstream of the fork would blur the video the user sees on the VGA output. Keeping the Gaussian internal to the motion detector ensures only the mask-decision path is smoothed.
3. **No changes to top-level wiring.** The external AXIS interface of `axis_motion_detect` (RGB in, 1-bit mask out, RAM ports) is unchanged whether `GAUSS_EN=0` or `GAUSS_EN=1`. `sparevideo_top` does not need to know whether spatial smoothing is present.

### 4.7 Placement rationale — why spatial filtering must be pre-threshold

Spatial smoothing must operate on the **continuous-valued** Y signal, not on the binary mask. Once thresholding converts the diff into a 1-bit mask, averaging 0s and 1s is neither Gaussian blur nor morphological filtering — the intensity information has been quantized away. Therefore the Gaussian is placed *before* the threshold comparison. Post-threshold binary cleanup (erode/dilate) is a separate class of operation and, when added, sits downstream of this module on the mask AXIS stream.

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

### 5.2 Spatial pre-filter implementation — 3x3 Gaussian

The Gaussian is instantiated inside a `generate` block gated by `GAUSS_EN`. When `GAUSS_EN = 0` the submodule is elided from elaboration and `y_smooth = y_cur` is wired directly. See [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) for the internal line-buffer/column-shift/adder-tree structure.

`axis_motion_detect` owns the control signals that drive the Gaussian. `gauss_pixel_valid` is a **sticky 1-deep pending flag** registered from the AXIS acceptance handshake: it is set on `s_axis_tvalid_i && s_axis_tready_o`, and cleared when the Gaussian consumes the pending pixel (`gauss_consume`). Sticky behaviour is required because the Gaussian must see `valid_i` held high across its phantom cycles (when `busy_o=1`) — a 1-cycle pulse would be missed.

```
on accept : gauss_pixel_valid <= 1, gauss_sof <= s_axis_tuser_i
on consume: gauss_pixel_valid <= 0, gauss_sof <= 0
gauss_consume = gauss_pixel_valid && !pipe_stall && !gauss_busy
```

The 1-cycle register delay aligns `valid_i`/`sof_i` with `y_cur` emerging from `rgb2ycrcb`. The Gaussian's `stall_i` is wired to the module's `pipe_stall` signal, so the pre-filter's internal line-buffer state freezes during downstream backpressure. `gauss_busy` (from `u_gauss.busy_o`, 1'b0 when `GAUSS_EN=0`) indicates the Gaussian is executing a phantom cycle and cannot accept a real pixel.

### 5.3 Threshold comparison implementation

The threshold comparison lives in `motion_core` (`hw/ip/motion/rtl/`), a pure-combinational module shared with the EMA update. The mask path is three combinational operators:

```systemverilog
// motion_core — mask path (gated by primed_i so frame 0 mask is always 0)
logic [7:0] diff         = abs(y_cur_i - y_bg_i);   // 8-bit subtract + absolute value
logic       raw_motion_o = (diff > THRESH);         // ungated threshold compare
logic       mask_bit_o   = primed_i && raw_motion_o;
```

`y_cur_i` is driven by `y_smooth` (post-Gaussian when `GAUSS_EN=1`, raw `y_cur` otherwise). `y_bg_i` is driven directly from `mem_rd_data_i`. Evaluation happens in the pipeline stage where both values are simultaneously valid; the gated result `mask_bit_o` is registered once more as it leaves the module, aligned with the sideband `tlast`/`tuser` chain so the AXIS output stays well-formed. `raw_motion_o` is also exposed (ungated) so `axis_motion_detect` can drive the 3:1 `bg_next` write-back mux without duplicating the threshold compare.

### 5.4 Temporal background model implementation — EMA

The EMA update shares the same `motion_core` instance as the threshold comparison, using signed arithmetic so the EMA step can go either direction:

```systemverilog
// motion_core — EMA path (shared subtract, two shifts, two adders)
logic signed [8:0] ema_delta       = {1'b0, y_cur_i} - {1'b0, y_bg_i};   // one signed 9-bit subtract
logic signed [8:0] ema_step_fast   = ema_delta >>> ALPHA_SHIFT;          // wire shift, α=1/(1<<ALPHA_SHIFT)
logic signed [8:0] ema_step_slow   = ema_delta >>> ALPHA_SHIFT_SLOW;     // wire shift, α=1/(1<<ALPHA_SHIFT_SLOW)
logic        [7:0] ema_update_o      = y_bg_i + ema_step_fast[7:0];      // non-motion branch
logic        [7:0] ema_update_slow_o = y_bg_i + ema_step_slow[7:0];      // motion branch
```

`axis_motion_detect` selects among three write-back sources per pixel:

```
bg_next = !primed     ? y_smooth          // frame-0 hard init
        :  raw_motion ? ema_update_slow_o // motion pixel → slow rate
        :               ema_update_o      // non-motion pixel → fast rate
```

The selection is driven by one combinational mux feeding `mem_wr_data_o`. `raw_motion` is the unchanged threshold comparison `(|Y_smooth - bg| > THRESH)`. The mask output stream uses `mask_bit_o`, which is gated by `primed_i` inside `motion_core` so the wrapper does not re-implement the gate on the AXIS output.

### 5.5 Pixel address counter

`pix_addr` is a frame-relative counter reset on SOF (`tuser`) and incremented on every accepted pixel (`tvalid && tready`). The physical RAM address is `RGN_BASE + pix_addr`.

`mem_rd_addr_o` is driven combinationally to `RGN_BASE + pix_addr_next` (the address for the *next* pixel), so the read result is available at `mem_rd_data_i` 1 cycle later — exactly when the next pixel is being processed.

### 5.6 RAM read/write discipline

The RAM uses read-first semantics on port A. When motion detect reads and writes the same address in the same cycle (the current pixel's address), port A returns the **old** value (previous frame's background estimate). No external bypass logic is needed.

### 5.7 Pipeline stages

**`GAUSS_EN=0` (PIPE_STAGES=1):**

```
Cycle C   : pixel N accepted; rgb2ycrcb MACs computed combinationally; mem_rd_addr_o issued
Cycle C+1 : y_cur registered; mem_rd_data_i arrives → diff computed → mask registered
```

Total latency: **1 clock cycle**.

**`GAUSS_EN=1` (PIPE_STAGES = H_ACTIVE + 3):**

The centered Gaussian (`axis_gauss3x3`) has H_ACTIVE + 1 cycles of fill latency (1 row + 1 column of spatial offset) plus 2 pipeline cycles, giving a total Gaussian latency of H_ACTIVE + 2 cycles from `rgb2ycrcb` output. The pixel address pipeline (`idx_pipe`) must delay the RAM read address by the same amount so that `y_smooth` and `bg[P]` meet at the comparator for the same pixel P:

```
Cycle C            : pixel N accepted; rgb2ycrcb MACs computed; gauss control signals registered
Cycle C+1          : y_cur registered; Gaussian begins accumulating into line buffers
Cycle C+2          : Gaussian line buffer read + column shift stage 1
...
Cycle C+H_ACTIVE+2 : Gaussian output stage 1 (adder tree)
Cycle C+H_ACTIVE+3 : y_smooth registered; mem_rd_data_i arrives → diff computed → mask registered
```

Total latency: **H_ACTIVE + 3 clock cycles** (323 cycles at 320px).

`PIPE_STAGES` is computed dynamically:

```
GAUSS_LATENCY = (GAUSS_EN != 0) ? (H_ACTIVE + 2) : 0
PIPE_STAGES   = 1 + GAUSS_LATENCY   // 1 at GAUSS_EN=0; H_ACTIVE+3 at GAUSS_EN=1
```

### 5.8 `idx_pipe` — SRL-inferred shift register

`idx_pipe` is a PIPE_STAGES-deep shift register that tracks the pixel address through the pipeline. At GAUSS_EN=1, PIPE_STAGES = H_ACTIVE + 3 = 323 stages × 17 bits. Synthesis tools infer these as SRL32 primitives on Xilinx 7-series (~170 LUTs) or equivalent SHIFTREG on Intel, provided the data path carries **no reset**. Only `valid_pipe`, `tlast_pipe`, and `tuser_pipe` carry a synchronous reset; `idx_pipe` is reset-free so that SRL inference fires.

### 5.9 Memory read address timing

The RAM read address must be issued 1 cycle before the comparison stage. With `GAUSS_EN=1`, the comparison happens at pipeline stage 3, so the read address uses `idx_pipe[PIPE_STAGES-2]` (delayed by 2 cycles from acceptance). With `GAUSS_EN=0`, it uses `pix_addr` (combinational, same cycle). During stall, a registered `pix_addr_hold` keeps the address stable.

### 5.10 Backpressure — single-output pipeline stall

The module has a single AXI4-Stream output (mask). Backpressure is handled by a pipeline stall combined with the sticky 1-deep pending slot described in §5.2:

```
pipe_valid     = valid_pipe[PIPE_STAGES-1]
pipe_stall     = pipe_valid AND NOT m_axis_msk_tready_i
beat_done      = pipe_valid AND m_axis_msk_tready_i
gauss_consume  = gauss_pixel_valid AND NOT pipe_stall AND NOT gauss_busy

s_axis_tready_o = NOT gauss_pixel_valid OR gauss_consume
```

`s_axis_tready_o` accepts a new pixel whenever the pending slot is empty, or will become empty this cycle (`gauss_consume` frees it for a simultaneous accept).

When the mask consumer stalls (`msk_tready=0`) or the Gaussian signals `busy_o=1`:
- All pipeline registers are frozen (gated with `!pipe_stall`); `gauss_pixel_valid` stays set, so `valid_i` to the Gaussian is held high across its phantom cycle as the contract requires.
- `rgb2ycrcb` is fed from `held_tdata` (the last accepted pixel's data, captured on each acceptance) rather than live `s_axis_tdata_i`. The mux selects `held_tdata` whenever no accept occurs this cycle, keeping `y_cur` stable during both stalls and Gaussian phantom cycles.
- `mem_rd_addr_o` is held via a registered hold address (`pix_addr_hold`).
- `mem_wr_en_o` is driven by `beat_done`, ensuring exactly one write per pixel.

### 5.11 Resource cost

The module consumes one `rgb2ycrcb` instance (9 multipliers + 24 FFs), optionally one `axis_gauss3x3` instance when `GAUSS_EN=1` (see [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) §5 for its internal resource breakdown), the `motion_core` combinational logic (one 8-bit subtractor, one absolute-value, one comparator, one 9-bit arithmetic shift, one 8-bit adder), and the sideband pipeline registers (~3 bits × `PIPE_STAGES`). RAM consumption is external (shared `ram` module). The pixel address counter adds `$clog2(H_ACTIVE × V_ACTIVE)` bits of registered state.

---

## 6. State / Control Logic

There is no explicit FSM. Pipeline stall logic is purely combinational from `pipe_valid` and `msk_tready`. `axis_motion_detect` owns the pixel address counter, stall mux, memory address hold, and write-back gating.

| Signal | Location | Meaning |
|--------|----------|---------|
| `pipe_valid` | `axis_motion_detect` | `valid_pipe[PIPE_STAGES-1]` — output stage holds a valid pixel |
| `pipe_stall` | `axis_motion_detect` | `pipe_valid AND NOT msk_tready` — pipeline stalled |
| `beat_done` | `axis_motion_detect` | `pipe_valid AND msk_tready` — beat consumed by downstream |
| `pix_addr` | `axis_motion_detect` | Frame-relative pixel index, 0…`H_ACTIVE×V_ACTIVE−1` |
| `pix_addr_hold` | `axis_motion_detect` | Registered hold address — keeps `mem_rd_addr_o` stable during stall |
| `idx_pipe` | `axis_motion_detect` | Pixel address pipeline — tracks address through stages for write-back |
| `held_tdata` | `axis_motion_detect` | Last accepted pixel data — feeds rgb2ycrcb during stall |
| `primed` | `axis_motion_detect` | 1-bit sticky flag — 0 during frame 0, set to 1 on the last beat of frame 0 and held. Gates the 3:1 `bg_next` mux and the `mask_bit_o` output. |

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

## 10. Follow-Ups / Future Improvements

### 10.1 Edge-match ghost detector (Sobel-based)

If real-scene testing reveals ghosts that survive the grace window — e.g.,
an object that was stationary throughout the first GRACE_FRAMES frames and
then moves, or a grace window too short to let bg converge below THRESH —
the next escalation is an edge-based ghost detector.

#### Motivation

A ghost region is a "phantom motion" blob with no corresponding real object.
The defining property: the edges inside a ghost blob match the background
model's edges (because the ghost is revealed true background), while a real
moving object has edges that do not match the bg model (the foreground
content differs from bg).

#### Technique

1. Apply a cheap edge operator (3x3 Sobel, 8-neighbor gradient magnitude) to
   both `y_cur` and `y_bg` in parallel with the existing threshold path.
2. For each motion pixel (raw_motion=1), compare `edge(y_cur)` and `edge(y_bg)`:
   - If they match (within a small tolerance EDGE_MATCH_TOL), classify the
     pixel as ghost and force `mask_bit=0` and `bg_next=ema_update` (fast
     rate) to accelerate bg self-correction.
   - Otherwise, normal selective-EMA rule applies.
3. Optionally gate the ghost classifier on a blob-level statistic from CCL
   (e.g., reject ghost-only if ≥80% of the CCL component's pixels are
   edge-matching), to avoid false-positive ghost calls on real objects with
   low internal texture.

#### Cost estimate

- One Sobel line buffer (3×H_ACTIVE × 8-bit ≈ 960 B at H=320) per image
  (current and bg) — 2× cost shared with the existing Gaussian filter's
  line buffers. Possibly reusable.
- Two adder trees for gradient magnitude (|Gx| + |Gy|, not sqrt).
- One comparator per output.
- No change to RAM ports or data widths.

#### Trigger condition

Only implement this if real-scene verification reveals residual ghosts that
tuning GRACE_FRAMES (up to ~16) cannot suppress. Synthetic `moving_box` and
`dark_moving_box` are not expected to need it once the grace window is in
place.

#### References

- Cucchiara et al., "Detecting Moving Objects, Ghosts and Shadows in Video
  Streams," IEEE TPAMI 2003 — original object-level ghost/shadow classifier.
- Sehairi et al., "Comparative study of motion detection methods" (arXiv:
  1804.05459) — survey of ghost-suppression approaches.
- MDPI Sensors 2020 — "Ghost Detection and Removal Based on Two-Layer
  Background Model and Histogram Similarity" (more expensive, not proposed
  here).

### 10.2 Motion-stuck per-pixel counter (ViBe-style)

Per-pixel counter that tracks how many consecutive frames a pixel has been
flagged as motion. If it exceeds a threshold (e.g., 2 × GRACE_FRAMES), force
the pixel to the fast EMA rate regardless of `raw_motion`. Cost: `log2(K)`
bits per pixel (~4-6 bits × H×V ≈ 50-100 kbit at 320×240). Targets ghosts
that arrive *after* the grace window. More principled than grace but more
expensive. Consider only if grace + edge-match together still leave residuals.

---

## 11. References

- [Background subtraction — Wikipedia](https://en.wikipedia.org/wiki/Background_subtraction)
- [Exponential moving average — Wikipedia](https://en.wikipedia.org/wiki/Exponential_smoothing)
- [OpenCV Background Subtraction tutorial](https://docs.opencv.org/4.x/d1/dc5/tutorial_background_subtraction.html)
