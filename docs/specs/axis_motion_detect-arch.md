# `axis_motion_detect` Architecture

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

`axis_gauss3x3` (in `hw/ip/gauss3x3/rtl/`) is a synchronous pipeline element (not a
full AXIS stage). It applies a 3x3 Gaussian blur `[1 2 1; 2 4 2; 1 2 1] / 16` to the
Y channel using two line buffers and column shift registers. Instantiated inside a
`generate` block gated by `GAUSS_EN`; when `GAUSS_EN=0` the module is not instantiated
and `y_smooth = y_cur` (bypass). See [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md)
for full details.

`motion_core` (in `hw/ip/motion/rtl/`) is a pure-combinational module with no
clock or state. It takes `y_cur` (or `y_smooth` when Gaussian is enabled) and `y_bg`
as inputs and produces `mask_bit` and `ema_update` as outputs.

`axis_motion_detect` is the glue: it instantiates the three submodules, owns the
pixel address counter, manages the RGB→Y stall mux, derives Gaussian control signals,
and wires the memory ports.

### Datapath overview

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

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line |
| `V_ACTIVE` | 240 | Active lines per frame |
| `THRESH` | 16 | Unsigned luma-difference threshold; motion detected when `diff > THRESH` |
| `ALPHA_SHIFT` | 3 | EMA smoothing factor as a bit-shift: alpha = 1 / (1 << ALPHA_SHIFT). Default 3 → alpha = 1/8. Higher values = slower background adaptation. When 0, the EMA reduces to raw-frame write-back (bg_new = Y_cur) |
| `GAUSS_EN` | 1 | Gaussian pre-filter enable. 1 = instantiate `axis_gauss3x3` (2-cycle latency, `PIPE_STAGES=3`). 0 = bypass (raw Y, `PIPE_STAGES=1`). Compile-time parameter propagated via `-GGAUSS_EN=` |
| `RGN_BASE` | 0 | Base byte-address of the background model region in the shared RAM |
| `RGN_SIZE` | `H_ACTIVE×V_ACTIVE` | Byte size of the background model region (sanity-checked at elaboration) |

### Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk_i` | input | 1 | DSP clock (`clk_dsp`) |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| **AXI4-Stream input (RGB888)** | | | |
| `s_axis_tdata_i` | input | 24 | RGB888 pixel input |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | AXI4-Stream ready (= `NOT pipe_valid OR msk_tready`) |
| `s_axis_tlast_i` | input | 1 | End-of-line |
| `s_axis_tuser_i` | input | 1 | Start-of-frame |
| **AXI4-Stream output — mask (1 bit)** | | | |
| `m_axis_msk_tdata_o` | output | 1 | Motion mask bit |
| `m_axis_msk_tvalid_o` | output | 1 | Mask stream valid |
| `m_axis_msk_tready_i` | input | 1 | Mask stream ready |
| `m_axis_msk_tlast_o` | output | 1 | Mask end-of-line |
| `m_axis_msk_tuser_o` | output | 1 | Mask start-of-frame |
| **Memory port (to shared RAM port A)** | | | |
| `mem_rd_addr_o` | output | `$clog2(RGN_BASE+RGN_SIZE)` | RAM read address |
| `mem_rd_data_i` | input | 8 | RAM read data (valid 1 cycle after address) |
| `mem_wr_addr_o` | output | `$clog2(RGN_BASE+RGN_SIZE)` | RAM write address |
| `mem_wr_data_o` | output | 8 | RAM write data (EMA-updated background value) |
| `mem_wr_en_o` | output | 1 | RAM write enable |

---

## 4. Concept Description

Background subtraction is a fundamental technique in video surveillance and motion detection. It maintains a model of the static background scene and detects motion by comparing each incoming pixel against this model. Pixels that differ significantly from the background are classified as foreground (motion).

### Algorithms in this module

Three algorithms are applied in sequence to each incoming pixel, after an initial RGB → Y8 colour-space conversion:

1. **Spatial pre-filter** — 3x3 Gaussian blur on the Y channel (`axis_gauss3x3`, optional via `GAUSS_EN`). Reduces *spatial* noise before any decision is made.
2. **Threshold comparison** — `|Y_smooth − bg| > THRESH`. Produces the 1-bit motion mask. Polarity-agnostic.
3. **EMA background update** — `bg ← bg + α·(Y_smooth − bg)`. Uses the same pixel's value to refine the background model for future frames.

The ordering is fixed for two reasons:

- **Spatial filtering must precede thresholding.** Spatial smoothing operates on continuous-valued luma; once the signal has been quantised to a 1-bit mask, averaging 0s and 1s is neither a blur nor a morphological op. See "Placement rationale — why spatial filtering must be pre-threshold" below.
- **Threshold and EMA update are co-sited, not sequential stages.** Both need `Y_smooth` and `bg` simultaneously, and both fire in the same cycle: the comparison drives the mask output, and the EMA result drives the RAM write-back. See "Placement rationale — why the EMA lives in the write-back path" below.

The three algorithms address complementary noise and adaptation problems. The Gaussian attacks *spatial* noise (uncorrelated pixel-to-pixel jitter within one frame). The EMA attacks *temporal* noise (uncorrelated frame-to-frame jitter at one pixel) and slow illumination drift. The threshold collapses the analog difference into the binary motion decision that downstream stages consume.

### Spatial pre-filter — 3x3 Gaussian

The Gaussian pre-filter convolves the Y channel with the kernel

```
[1 2 1]
[2 4 2]  / 16
[1 2 1]
```

before the threshold comparison. Its purpose is to suppress *spatial* high-frequency content in the luma signal — salt-and-pepper sensor noise, quantisation artefacts, and single-pixel outliers — which would otherwise produce single-pixel mask sparkle after thresholding. A 3x3 Gaussian attenuates near-Nyquist spatial content substantially while preserving edges better than a box filter of the same support, so real object boundaries remain sharp enough for the bbox reduction to work.

The pre-filter is orthogonal to the EMA. The Gaussian averages over *space* within the current frame; the EMA averages over *time* at a fixed pixel. Both are needed because real sensor noise has energy along both axes, and neither filter attenuates the other's target.

When `GAUSS_EN = 0` this stage is bypassed and `Y_smooth = Y_cur`; the rest of the datapath is identical. See [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) for line-buffer and adder-tree details.

### Threshold comparison — polarity-agnostic absolute difference

The motion decision is `mask = (|Y_smooth − bg| > THRESH)`. Using the *absolute* difference rather than a signed difference makes the comparison **polarity-agnostic**: both arrival pixels (where a moving object now is) and departure pixels (where it was) are flagged as motion, regardless of the brightness relationship between object and background (bright-on-dark, dark-on-bright, or colour scenes).

The trade-off is that the downstream bounding box encompasses both old and new object positions, making it slightly larger than the object by approximately one frame of displacement. This oversizing is accepted as the cost of scene-type independence.

### Temporal background model — EMA

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

**Why not raw-frame priming?** Writing raw `y_cur` to RAM on frame 0 was evaluated but rejected. While it fills the background model instantly, any foreground object present in frame 0 gets its luma committed to the background. When the object moves, the departure ghost persists for `~1/alpha` frames — much worse than the EMA warm-up from zero. With EMA from zero, the background only moves `y_cur >> ALPHA_SHIFT` toward the object per frame, so departure ghosts from the initial convergence clear quickly.

### Placement rationale — no incremental RAM for EMA

The EMA reuses the **same** per-pixel RAM region (`RGN_BASE`, `H_ACTIVE × V_ACTIVE` bytes) that a raw previous-frame buffer would have used. The region still holds one 8-bit value per pixel; only the interpretation of that value changes — it is now a running average rather than the last raw luma. No second region, no second port, no additional BRAM is required. Port A remains a single 1R1W access per pixel, so there is no port contention between reads and writes.

### Placement rationale — why the Gaussian is internal, not an external AXIS stage

The Gaussian pre-filter (`axis_gauss3x3`) is instantiated **inside** `axis_motion_detect`, on the internal Y channel between `rgb2ycrcb` and the threshold comparison. It is not a standalone AXIS stage in `sparevideo_top`. This placement is deliberate for three reasons:

1. **Y-only smoothing, not RGB smoothing.** Placing the Gaussian externally on the RGB stream would either require smoothing all three channels (3× the line-buffer cost) or splitting Y out at the top level. Smoothing inside the motion detector operates on the single Y channel after `rgb2ycrcb`, minimizing line-buffer resources.
2. **RGB passthrough stays sharp.** The video path that reaches `axis_overlay_bbox` (via `axis_fork` at the top level) is the *original* RGB stream. Smoothing RGB upstream of the fork would blur the video the user sees on the VGA output. Keeping the Gaussian internal to the motion detector ensures only the mask-decision path is smoothed.
3. **No changes to top-level wiring.** The external AXIS interface of `axis_motion_detect` (RGB in, 1-bit mask out, RAM ports) is unchanged whether `GAUSS_EN=0` or `GAUSS_EN=1`. `sparevideo_top` does not need to know whether spatial smoothing is present.

### Placement rationale — why spatial filtering must be pre-threshold

Spatial smoothing must operate on the **continuous-valued** Y signal, not on the binary mask. Once thresholding converts the diff into a 1-bit mask, averaging 0s and 1s is neither Gaussian blur nor morphological filtering — the intensity information has been quantized away. Therefore the Gaussian is placed *before* the threshold comparison. Post-threshold binary cleanup (erode/dilate) is a separate class of operation and, when added, sits downstream of this module on the mask AXIS stream.

---

## 5. Internal Architecture

### Per-pixel pipeline (overview)

Every accepted pixel flows through the same three-algorithm sequence described in §4, now expressed at the RTL signal level:

```
Y_cur    = rgb2ycrcb(R, G, B).y       // 1-cycle pipeline inside rgb2ycrcb
Y_smooth = gauss3x3(Y_cur)            // 2-cycle pipeline (GAUSS_EN=1) or bypass (GAUSS_EN=0)
bg       = mem_rd_data_i              // RAM read, 1-cycle latency after mem_rd_addr_o
diff     = abs(Y_smooth − bg)
mask     = (diff > THRESH)

// EMA background update — write smoothed estimate back to RAM
delta      = Y_smooth − bg            // signed 9-bit
ema_step   = delta >>> ALPHA_SHIFT    // arithmetic right-shift (sign-preserving)
ema_update = bg + ema_step[7:0]       // new background value

mem_wr_addr_o = RGN_BASE + pix_addr
mem_wr_data_o = ema_update            // EMA-smoothed background, not raw Y_cur
mem_wr_en_o   = tvalid && tready      // only on actual acceptance
```

When `ALPHA_SHIFT = 0`, `ema_step = delta` and `ema_update = Y_cur`, so the module reduces to raw previous-frame write-back.

The remainder of this section splits along the same per-algorithm axis as §4, then covers the shared infrastructure (address counter, RAM discipline, pipeline register chain, stall handling, and resource cost).

### Spatial pre-filter implementation — 3x3 Gaussian

The Gaussian is instantiated inside a `generate` block gated by `GAUSS_EN`. When `GAUSS_EN = 0` the submodule is elided from elaboration and `y_smooth = y_cur` is wired directly. See [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md) for the internal line-buffer/column-shift/adder-tree structure.

`axis_motion_detect` owns the control signals that drive the Gaussian. Two registered signals derive the submodule's `valid_i` and `sof_i` from the AXIS acceptance handshake:

```
gauss_pixel_valid <= s_axis_tvalid_i && s_axis_tready_o   (gated by !pipe_stall)
gauss_sof         <= s_axis_tuser_i                        (gated by !pipe_stall)
```

They are 1-cycle delayed so that they align with `y_cur` emerging from `rgb2ycrcb`. The Gaussian's `stall_i` is wired to the module's `pipe_stall` signal, so the pre-filter's internal line-buffer state freezes during downstream backpressure just like the rest of the pipeline.

### Threshold comparison implementation

The threshold comparison lives in `motion_core` (`hw/ip/motion/rtl/`), a pure-combinational module shared with the EMA update. The mask path is three combinational operators:

```systemverilog
// motion_core — mask path
logic [7:0] diff       = abs(y_cur_i - y_bg_i);   // 8-bit subtract + absolute value
logic       mask_bit_o = (diff > THRESH);         // 8-bit unsigned compare
```

`y_cur_i` is driven by `y_smooth` (post-Gaussian when `GAUSS_EN=1`, raw `y_cur` otherwise). `y_bg_i` is driven directly from `mem_rd_data_i`. Evaluation happens in the pipeline stage where both values are simultaneously valid; the result `mask_bit_o` is registered once more as it leaves the module, aligned with the sideband `tlast`/`tuser` chain so the AXIS output stays well-formed.

### Temporal background model implementation — EMA

The EMA update shares the same `motion_core` instance as the threshold comparison, using signed arithmetic so the EMA step can go either direction:

```systemverilog
// motion_core — EMA path
logic signed [8:0] ema_delta    = {1'b0, y_cur_i} - {1'b0, y_bg_i};  // signed 9-bit
logic signed [8:0] ema_step     = ema_delta >>> ALPHA_SHIFT;         // arithmetic right-shift
logic        [7:0] ema_update_o = y_bg_i + ema_step[7:0];            // new bg value
```

The EMA multiplication by `α = 1/(1 << ALPHA_SHIFT)` is implemented as an arithmetic right-shift, requiring no multiplier. When `ALPHA_SHIFT = 0`, the EMA degenerates to raw frame write-back (`bg_new = y_cur`), which matches the pre-EMA behaviour bit-for-bit and is useful for bring-up comparisons.

The arithmetic right-shift (`>>>`) preserves the sign of `ema_delta`, so `bg` can move down as well as up when `y_cur < bg`. The shift count is the `ALPHA_SHIFT` compile-time parameter, so no multiplier or runtime shifter is synthesised; Yosys/Verilator infers a fixed wire routing. When `ALPHA_SHIFT = 0` the shift is a no-op, `ema_step = ema_delta`, and `ema_update_o = y_cur_i` — bit-for-bit raw write-back.

The write-back port assignment is `mem_wr_data_o <= ema_update_o`. This is the only change the EMA introduces versus a raw previous-frame buffer; the RAM region, addressing, read path, and comparison path are untouched (see §4 "Placement rationale — why the EMA lives in the write-back path").

### Pixel address counter

`pix_addr` is a frame-relative counter reset on SOF (`tuser`) and incremented on every accepted pixel (`tvalid && tready`). The physical RAM address is `RGN_BASE + pix_addr`.

`mem_rd_addr_o` is driven combinationally to `RGN_BASE + pix_addr_next` (the address for the *next* pixel), so the read result is available at `mem_rd_data_i` 1 cycle later — exactly when the next pixel is being processed.

### RAM read/write discipline

The RAM uses read-first semantics on port A. When motion detect reads and writes the same address in the same cycle (the current pixel's address), port A returns the **old** value (previous frame's background estimate). No external bypass logic is needed.

### Pipeline stages

**`GAUSS_EN=0` (PIPE_STAGES=1):**

```
Cycle C   : pixel N accepted; rgb2ycrcb MACs computed combinationally; mem_rd_addr_o issued
Cycle C+1 : y_cur registered; mem_rd_data_i arrives → diff computed → mask registered
```

Total latency: **1 clock cycle**.

**`GAUSS_EN=1` (PIPE_STAGES=3):**

```
Cycle C   : pixel N accepted; rgb2ycrcb MACs computed; gauss control signals registered
Cycle C+1 : y_cur registered; Gaussian line buffer read + column shift stage 1
Cycle C+2 : Gaussian column shift stage 2 + adder tree (combinational)
Cycle C+3 : y_smooth registered; mem_rd_data_i arrives → diff computed → mask registered
```

Total latency: **3 clock cycles**.

`PIPE_STAGES` is computed dynamically:

```
GAUSS_LATENCY = (GAUSS_EN != 0) ? 2 : 0
PIPE_STAGES   = 1 + GAUSS_LATENCY
```

### Memory read address timing

The RAM read address must be issued 1 cycle before the comparison stage. With `GAUSS_EN=1`, the comparison happens at pipeline stage 3, so the read address uses `idx_pipe[PIPE_STAGES-2]` (delayed by 2 cycles from acceptance). With `GAUSS_EN=0`, it uses `pix_addr` (combinational, same cycle). During stall, a registered `pix_addr_hold` keeps the address stable.

### Backpressure — single-output pipeline stall

The module has a single AXI4-Stream output (mask). Backpressure is handled by a simple pipeline stall:

```
pipe_valid     = valid_pipe[PIPE_STAGES-1]
pipe_stall     = pipe_valid AND NOT m_axis_msk_tready_i
beat_done      = pipe_valid AND m_axis_msk_tready_i

s_axis_tready_o = NOT pipe_valid OR m_axis_msk_tready_i
```

When the mask consumer stalls (`msk_tready=0`):
- All pipeline registers are frozen (gated with `!pipe_stall`).
- `rgb2ycrcb` is fed from `held_tdata` (the last accepted pixel's data, captured on each acceptance) rather than live `s_axis_tdata_i`.
- `mem_rd_addr_o` is held via a registered hold address (`pix_addr_hold`).
- `mem_wr_en_o` is driven by `beat_done`, ensuring exactly one write per pixel.

### Resource cost

The module consumes one `rgb2ycrcb` instance (9 multipliers + 24 FFs), optionally one `axis_gauss3x3` instance when `GAUSS_EN=1` (2 line buffers of `H_ACTIVE` x 8 bits + 6 column shift FFs + 8-adder tree — see [`axis_gauss3x3-arch.md`](axis_gauss3x3-arch.md)), the `motion_core` combinational logic (one 8-bit subtractor, one absolute-value, one comparator, one 9-bit arithmetic shift, one 8-bit adder), and the sideband pipeline registers (~3 bits × `PIPE_STAGES`). RAM consumption is external (shared `ram` module). The pixel address counter adds `$clog2(H_ACTIVE × V_ACTIVE)` bits of registered state.

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

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| RGB → Y8 (`rgb2ycrcb`) | 1 clock cycle |
| Gaussian pre-filter (`axis_gauss3x3`, `GAUSS_EN=1`) | 2 clock cycles |
| RAM read | 1 clock cycle |
| Total pixel input → mask output (`GAUSS_EN=0`) | 1 clock cycle |
| Total pixel input → mask output (`GAUSS_EN=1`) | 3 clock cycles |
| Throughput | 1 pixel / cycle (when `msk_tready=1`) |

Frame 0: RAM is zero-initialized → all pixels read `bg=0` → mask=1 for every non-black pixel → near-full-frame bbox. `axis_bbox_reduce` suppresses bbox output for the first 2 frames (priming period) to avoid this artifact. The EMA converges from zero toward the actual scene luma over `~1/alpha` frames.

EMA convergence: After a step change in a pixel's value, the background converges toward the new value over approximately `1/alpha = 1 << ALPHA_SHIFT` frames. With the default `ALPHA_SHIFT=3` (alpha=1/8), a pixel that steps from 100 to 200 will have its background reach ~200 after ~16 frames. Motion is detected (mask=1) for the first several frames until `|Y_cur - bg|` drops below `THRESH`. This is the intended behavior — transient objects are detected, then absorbed into the background.

---

## 8. Shared Types

None from `sparevideo_pkg` directly. Frame geometry parameters (`H_ACTIVE`, `V_ACTIVE`) match the package values when instantiated from `sparevideo_top`.

---

## 9. Known Limitations

- **No morphological post-filtering**: the binary mask is not cleaned up with erode/dilate. A single noisy pixel that survives the Gaussian pre-filter still produces a mask=1 bit. Morphological opening is deferred.
- **Fixed THRESH**: compile-time parameter. Runtime control requires promoting to an input port and a `sparevideo_csr` AXI-Lite register.
- **Fixed ALPHA_SHIFT**: compile-time parameter. Different scenes may benefit from different adaptation rates; runtime control would require the same CSR promotion as THRESH.
- **`Cr`/`Cb` unused**: `rgb2ycrcb` outputs `cb_o` and `cr_o`; only `y_o` is used. Lint waivers suppress `PINCONNECTEMPTY`/`UNUSEDSIGNAL`.
- **Single-buffered**: no double-buffering. Mid-frame RAM corruption by port B clients accessing the background model region during an active frame will produce incorrect mask bits. See the host-responsibility rule in [ram-arch.md](ram-arch.md).
- **Bbox oversizing**: the polarity-agnostic mask flags both arrival and departure pixels, so the bbox is slightly larger than the object by approximately the per-frame displacement. This is a deliberate trade-off for scene-type independence.
- **EMA rounding bias**: the arithmetic right-shift truncates toward negative infinity, introducing a small systematic bias. For typical video luma values this is negligible (sub-LSB after a few frames).

---

## 10. References

- [Background subtraction — Wikipedia](https://en.wikipedia.org/wiki/Background_subtraction)
- [Exponential moving average — Wikipedia](https://en.wikipedia.org/wiki/Exponential_smoothing)
- [OpenCV Background Subtraction tutorial](https://docs.opencv.org/4.x/d1/dc5/tutorial_background_subtraction.html)
