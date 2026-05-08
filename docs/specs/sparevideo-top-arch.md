# sparevideo Top-Level Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
- [4. Concept Description](#4-concept-description)
  - [4.1 Dual-path pipeline: what is the "mask"?](#41-dual-path-pipeline-what-is-the-mask)
  - [4.2 Mask/video latency independence](#42-maskvideo-latency-independence)
- [5. Design Rationale](#5-design-rationale)
  - [5.1 `u_motion_detect` — which pixels look different?](#51-u_motion_detect--which-pixels-look-different)
  - [5.2 `u_hflip` — present a "selfie-cam" view to the user](#52-u_hflip--present-a-selfie-cam-view-to-the-user)
  - [5.3 `u_morph_clean` — clean up speckle in the mask](#53-u_morph_clean--clean-up-speckle-in-the-mask)
  - [5.4 `u_ccl` — group motion pixels into distinct objects](#54-u_ccl--group-motion-pixels-into-distinct-objects)
  - [5.5 `u_overlay_bbox` — draw rectangles on the video](#55-u_overlay_bbox--draw-rectangles-on-the-video)
  - [5.6 `u_gamma_cor` — sRGB display gamma at the post-mux tail](#56-u_gamma_cor--srgb-display-gamma-at-the-post-mux-tail)
  - [5.7 `u_hud` — bitmap text HUD at the post-scaler tail](#57-u_hud--bitmap-text-hud-at-the-post-scaler-tail)
  - [5.8 `u_vga` — drive the display with proper timing](#58-u_vga--drive-the-display-with-proper-timing)
  - [5.9 1-frame bbox latency](#59-1-frame-bbox-latency)
  - [5.10 Latency and timing budget](#510-latency-and-timing-budget)
- [6. Internal Architecture](#6-internal-architecture)
  - [6.1 Plumbing and glue](#61-plumbing-and-glue)
  - [6.2 AXI4-Stream protocol](#62-axi4-stream-protocol)
- [7. Clock Domains](#7-clock-domains)
- [8. Region Descriptor Model](#8-region-descriptor-model)
  - [8.1 Future CSR register file (deferred)](#81-future-csr-register-file-deferred)
- [9. Assertions](#9-assertions)
- [10. Known Limitations](#10-known-limitations)
- [11. Resources](#11-resources)
- [12. References](#12-references)

---

## 1. Purpose and Scope

`sparevideo_top` is the top-level video processing pipeline. It accepts an AXI4-Stream RGB888 input on `clk_pix_in_i` (nominally 25 MHz), crosses into a 100 MHz DSP clock domain, runs a **control-flow-selectable** processing pipeline, crosses back to `clk_pix_out_i`, and drives a VGA controller. When `CFG.scaler_en=1`, `clk_pix_out_i` runs at 4× `clk_pix_in_i` so VGA can drain the 2×-upscaled output; otherwise the two pixel clocks are tied.

A 2-bit `ctrl_flow_i` sideband selects the path. Motion is the production flow; the others are debug aids:

| `ctrl_flow_i` | Mode | Output |
|---|---|---|
| `2'b00` | Passthrough | Input pixels straight through. |
| `2'b01` (default) | Motion | RGB with bounding-box rectangles. |
| `2'b10` | Mask | Cleaned 1-bit mask expanded to B/W RGB. |
| `2'b11` | CCL bbox | Cleaned mask as grey canvas with bboxes drawn on top. |

Motion, mask, and ccl_bbox all activate the motion-detect + morph + CCL front-end. In passthrough the fork's input `tvalid` is gated to 0 and the overlay output `tready` is tied to 1.

Out of scope: camera input (MIPI CSI-2), AXI-Lite registers, independent `clk_pix` sources, and any processing beyond luma-difference motion detection, 3×3 morphological opening + closing, 8-connected CCL, and N-way bbox overlay.

---

## 2. Module Hierarchy

```
sparevideo_top (top level)
├── axis_async_fifo    (u_fifo_in)       — CDC clk_pix → clk_dsp, vendored verilog-axis
├── ram                (u_ram)           — dual-port byte RAM, Y8 prev-frame buffer
├── axis_hflip         (u_hflip)         — horizontal mirror at the head of the proc_clk pipeline; runtime bypassable
├── axis_fork          (u_fork)          — 1-to-2 broadcast: fork_a → motion detect, fork_b → overlay
├── axis_motion_detect (u_motion_detect) — mask-only producer
│   └── rgb2ycrcb      (u_rgb2ycrcb)    — RGB888 → Y8 (1-cycle pipeline)
├── axis_morph_clean      (u_morph_clean)   — 3×3 opening + parametrizable 3×3/5×5 closing on the mask; runtime bypassable
├── axis_ccl           (u_ccl)           — cleaned mask → N_OUT × {min_x,max_x,min_y,max_y,valid}
├── axis_overlay_bbox  (u_overlay_bbox)  — draw N_OUT-wide bbox rectangles on RGB video
├── axis_gamma_cor     (u_gamma_cor)     — per-channel sRGB gamma correction; runtime bypassable
├── axis_scale2x       (u_scale2x)       — 2x spatial upscaler (NN or bilinear); compile-time gate (CFG.scaler_en)
├── axis_hud           (u_hud)           — 8x8 bitmap text overlay at the post-scaler tail; runtime bypassable (CFG.hud_en)
├── axis_async_fifo    (u_fifo_out)      — CDC clk_dsp → clk_pix_out, vendored verilog-axis
└── vga_controller     (u_vga)          — streaming pixel → VGA timing + RGB output
```

---

## 3. Interface Specification

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| **Clocks and resets** | | | |
| `clk_pix_in_i` | input | 1 | Input pixel clock (nominally 25 MHz) — sensor / input AXIS domain |
| `clk_pix_out_i` | input | 1 | Output pixel clock — VGA output domain. Tied to `clk_pix_in_i` when `CFG.scaler_en=0`; runs at 4x `clk_pix_in_i` when `CFG.scaler_en=1` to drain the 2x-upscaled stream. |
| `clk_dsp_i` | input | 1 | 100 MHz DSP clock — motion / scaler pipeline domain |
| `rst_pix_in_n_i` | input | 1 | Active-low synchronous reset, `clk_pix_in` domain |
| `rst_pix_out_n_i` | input | 1 | Active-low synchronous reset, `clk_pix_out` domain |
| `rst_dsp_n_i` | input | 1 | Active-low synchronous reset, `clk_dsp` domain |
| **AXI4-Stream video input (clk_pix_in domain)** | | | |
| `s_axis` | input | `axis_if.rx` | RGB888 pixel input stream (DATA_W=24, USER_W=1; `tdata={R,G,B}`, tuser=SOF, tlast=EOL). tready back-pressures the TB/source producer. |
| **Control flow** | | | |
| `ctrl_flow_i` | input | 2 | Control flow select: 2'b00 = passthrough, 2'b01 = motion, 2'b10 = mask, 2'b11 = ccl_bbox |
| **VGA output (clk_pix_out domain)** | | | |
| `vga_hsync_o` | output | 1 | Horizontal sync, active-low |
| `vga_vsync_o` | output | 1 | Vertical sync, active-low |
| `vga_r_o` | output | 8 | Red channel (0 during blanking) |
| `vga_g_o` | output | 8 | Green channel (0 during blanking) |
| `vga_b_o` | output | 8 | Blue channel (0 during blanking) |

### 3.1 Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `H_ACTIVE` | `int` | pkg (320) | Active pixels per line (input dims; pipeline / motion / scaler-input all run at this width). |
| `V_ACTIVE` | `int` | pkg (240) | Active lines per frame (input dims). |
| `H_FRONT_PORCH` | `int` | pkg (4) | VGA horizontal front-porch length, in pixel clocks. |
| `H_SYNC_PULSE` | `int` | pkg (8) | VGA horizontal sync-pulse width, in pixel clocks. |
| `H_BACK_PORCH` | `int` | pkg (4) | VGA horizontal back-porch length, in pixel clocks. |
| `V_FRONT_PORCH` | `int` | pkg (2) | VGA vertical front-porch length, in lines. |
| `V_SYNC_PULSE` | `int` | pkg (2) | VGA vertical sync-pulse width, in lines. |
| `V_BACK_PORCH` | `int` | pkg (2) | VGA vertical back-porch length, in lines. |
| **`CFG`** | **`cfg_t`** | **`CFG_DEFAULT`** | **Algorithm tuning bundle (`sparevideo_pkg::cfg_t`). The fields below are members of this struct, addressed in RTL as `CFG.<field>`.** |
| `CFG.motion_thresh` | `component_t` (8-bit) | `16` | Raw `abs(Y_cur − Y_bg)` threshold above which a pixel is flagged as motion. Driven into `u_motion_detect.THRESH`. |
| `CFG.alpha_shift` | `int` | `3` | EMA shift for **non-motion** pixels (`bg ← bg + (Y − bg) >> alpha_shift`); larger value = slower adaptation. Driven into `u_motion_detect.ALPHA_SHIFT`. |
| `CFG.alpha_shift_slow` | `int` | `6` | EMA shift for **motion-flagged** pixels — kept slower to avoid baking foreground into the background. Driven into `u_motion_detect.ALPHA_SHIFT_SLOW`. |
| `CFG.grace_frames` | `int` | `0` | Number of frames after priming during which both EMA rates are forced to `grace_alpha_shift` (faster convergence, suppresses frame-0 ghost). `0` disables the grace window — appropriate for synthetic sources whose frame 0 is bg-only. |
| `CFG.grace_alpha_shift` | `int` | `1` | EMA shift used during the grace window (typically aggressive — `1` means α=1/2). |
| `CFG.gauss_en` | `logic` | `1` | Enable the 3×3 Gaussian pre-filter on the luma stream inside `u_motion_detect`. `0` bypasses the filter. |
| `CFG.morph_open_en` | `logic` | `1` | Enable the 3×3 morphological opening stage in `u_morph_clean`. `0` bypasses (raw mask flows through open stage unchanged). |
| `CFG.morph_close_en` | `logic` | `1` | Enable the morphological closing stage in `u_morph_clean`. `0` bypasses (mask flows through close stage unchanged). |
| `CFG.morph_close_kernel` | `int` | `3` | Closing structuring-element size: `3` for 3×3, `5` for 5×5 (two cascaded 3×3 passes). Compile-time only. |
| `CFG.hflip_en` | `logic` | `0` | Enable the horizontal mirror (`u_hflip`) at the head of the proc-clock pipeline. `0` passes the input through unchanged. |
| `CFG.gamma_en` | `logic` | `1` | Enable the sRGB gamma-correction stage (`u_gamma_cor`) at the post-mux tail. `0` bypasses (linear-light pixels reach the output FIFO). |
| `CFG.scaler_en` | `logic` | `1` | Enable the 2x bilinear spatial upscaler (`u_scale2x`) before the output FIFO. `0` bypasses (output resolution equals input resolution). |
| `CFG.hud_en` | `logic` | `1` | Enable the bitmap text HUD overlay (`u_hud`) at the post-scaler tail. `0` bypasses (data-equivalent passthrough through the same 1-cycle skid). |
| `CFG.bbox_color` | `pixel_t` (24-bit RGB) | `0x00_FF_00` (green) | RGB triple drawn by `u_overlay_bbox` for every bounding-box edge pixel. Driven into `u_overlay_bbox.BBOX_COLOR`. |
| `CCL_N_LABELS_INT` | `int` | pkg (64) | Internal label-table size in `u_ccl`. Cap on the number of distinct provisional labels tracked in one frame before a label-exhaust fallback (merge into label 0). |
| `CCL_N_OUT` | `int` | pkg (8) | Number of per-component bounding-box output slots exposed from `u_ccl` to `u_overlay_bbox`. |
| `CCL_MIN_COMPONENT_PIXELS` | `int` | pkg (16) | Minimum component area (in pixels) to promote into the top-N bbox output — filters sensor-noise specks. |
| `CCL_MAX_CHAIN_DEPTH` | `int` | pkg (8) | Safety cap on parent-pointer chain walks during the EOF fold phase. |
| `CCL_PRIME_FRAMES` | `int` | pkg (0) | Number of frames after reset during which `u_ccl` suppresses all bbox outputs, giving the EMA background model time to converge. |

`H_ACTIVE` and `V_ACTIVE` set the active video region; the eight porch parameters set the surrounding blanking intervals. Together they determine the VGA frame format used by `u_vga` and the timing the input driver must mirror.

`CFG` is resolved at compile time from a `CFG_NAME` string and routed by `sparevideo_top` to the appropriate sub-module ports. Adding a new algorithm knob costs one field in `cfg_t` and one wire in `sparevideo_top` from `CFG.<new_field>` to the consuming module. Named profiles (`default`, `default_hflip`, `no_ema`, `no_morph`, `no_gauss`, `no_gamma_cor`, `no_scaler`, `no_hud`) live in `sparevideo_pkg`.

**Output resolution.** `H_ACTIVE_OUT/V_ACTIVE_OUT` come from `sparevideo_pkg::*_OUT_2X` when `CFG.scaler_en=1`; otherwise they equal the input dims. The VGA controller uses the OUT dims; the input AXIS, motion pipeline, gamma stage, and scaler input all stay at input dims. The TB drives input frames at input dims and captures output at output dims. Rate balance between the input and output sides is enforced by the clock-period ratio: when `CFG.scaler_en=1` the caller drives `clk_pix_in_i` at one-quarter the frequency of `clk_pix_out_i`; when `CFG.scaler_en=0` they're tied to the same clock.

`ctrl_flow_i` is a quasi-static sideband signal (set before the frame, not changed mid-frame).

---

## 4. Concept Description

The pipeline is **dual-clock-domain**: a pixel clock at the VGA timing rate, and a 100 MHz DSP clock with 4× headroom over the pixel rate. The headroom ensures the processing pipeline can sustain 1 pixel per pixel-clock without backpressure even though it operates at DSP-clock granularity. CDC happens at the boundaries through asynchronous FIFOs (`u_fifo_in`, `u_fifo_out`); blanking intervals absorb any short-term mismatch.

A single front-end (motion detect → morph → CCL) is shared across all four control-flow modes. The 2-bit `ctrl_flow_i` sideband picks which intermediate signal reaches the output (RGB+bboxes, mask, mask-as-grey+bboxes, or raw input), so no hardware is duplicated per mode. The processing modules themselves are documented in their per-module specs; this top-level spec covers their interconnection, control-flow muxing, CDC, and timing.

### 4.1 Dual-path pipeline: what is the "mask"?

Before the fork, `axis_hflip` (`u_hflip`) optionally mirrors each input line horizontally. Because `u_hflip` is upstream of `u_fork`, the motion mask and bbox coordinates are computed on the mirrored view. The user-visible RGB and the mask therefore agree by construction — no coordinate-flip is needed in the overlay. `CFG.hflip_en=0` bypasses the stage with a zero-latency combinational path.

In motion/mask modes, the pipeline processes two parallel streams forked from the same input video. A top-level `axis_fork` (`u_fork`) broadcasts the DSP-domain input to two consumers:

1. **Video path (RGB, 24-bit per pixel, `fork_b`):** The original RGB pixels feed directly from the fork to `u_overlay_bbox`, bypassing `u_motion_detect` entirely. They are never modified by the motion-detection logic. The fork ensures the overlay receives the same pixels with no additional latency.
2. **Mask path (1-bit per pixel, `fork_a`):** `u_motion_detect` receives the second fork output, converts each pixel to Y8, compares against the per-pixel background model, and emits a single bit: **"did this pixel change compared to the background?"** A `1` means yes (motion detected at this pixel), a `0` means no (this pixel looks the same as the background model). The raw mask is then passed through `u_morph_clean` for speckle cleanup and gap-closing before it reaches the downstream consumers.

The mask is a binary image the same size as the video (H_ACTIVE × V_ACTIVE), transmitted as an AXI4-Stream of 1-bit values, one per pixel, in the same raster order as the video. Visually, if you could see the mask, it would look like this:

```
Original scene:              Motion mask:

  ┌──────────────────┐        ┌──────────────────┐
  │                  │        │                  │
  │     ██████       │        │     ░░░░░░       │
  │     █ cat █      │        │     ░░░░░░       │   ░ = 1 (motion)
  │     ██████       │        │     ░░░░░░       │   (blank) = 0 (no motion)
  │           moving→│        │     ░░░░░░       │
  │                  │        │                  │
  │  static wall     │        │                  │
  └──────────────────┘        └──────────────────┘
```

In motion mode the mask is **not displayed** to the user. It is an intermediate signal consumed by the downstream stages:

- **`u_ccl`** scans the cleaned mask in raster order, assigns a label to each motion pixel via 8-connected single-pass union-find, accumulates per-label `{min_x, max_x, min_y, max_y, count}` on the fly, and — during the vertical blanking interval after EOF — resolves the equivalence table, discards components below `CCL_MIN_COMPONENT_PIXELS`, and commits the top `CCL_N_OUT` bounding boxes into a front-buffer register bank. The output is `N_OUT` packed sideband arrays of `{min_x, max_x, min_y, max_y}` plus an `N_OUT`-wide `valid` bit vector, held stable for the entire next frame.
- **`u_overlay_bbox`** takes those `N_OUT` bbox slots and, for each pixel streaming past, combinationally ORs an `N_OUT`-wide rectangle-edge hit test: if any valid slot's rectangle edge hits `(col, row)`, the pixel is replaced with `BBOX_COLOR` (bright green); otherwise it passes through unchanged.

So the full pipeline's job is: **video in → detect which pixels changed → clean up speckle → label connected motion blobs → for each blob, compute its bounding box → draw up to `N_OUT` rectangles on the video → video out**. The mask is the intermediate "which pixels changed" answer that connects the detection step to the labeling step; the `N_OUT` bboxes are the "where are the distinct moving objects" answer that connects labeling to the overlay.

In mask mode (`ctrl_flow_i = 2'b10`) the cleaned 1-bit mask is instead expanded to 24-bit black/white and fed directly to the output FIFO for debug visualization — bypassing both `u_ccl` and `u_overlay_bbox`.

In ccl_bbox mode (`ctrl_flow_i = 2'b11`) the cleaned mask is combinationally expanded to a 24-bit grey canvas (mask=1 → `0x808080`, mask=0 → `0x202020`) and routed into `u_overlay_bbox` in place of the RGB video; `u_ccl` still produces the bbox sideband normally, so the output is the mask-as-grey with the CCL bboxes drawn on top. This is the most direct visual diagnostic for the CCL block — if a drawn rectangle does not enclose a grey blob, either CCL or the mask is wrong, and each can be inspected in isolation.

### 4.2 Mask/video latency independence

The mask and video paths are consumed by **different modules that do not synchronize per-pixel** with each other, so adding stages to the mask path does not require compensating delay on the video path. Three invariants make this work:

1. **`u_ccl` is a pure sink on its mask input** — it accepts one mask bit per cycle whenever the upstream strobes valid, and it produces **no mask output stream** at all. It never stalls the mask stream once the upstream broadcast handshake is complete, and it never touches the video stream. All accumulation (per-label min/max/count, union-find) is internal.
2. **Bboxes are committed at end-of-frame, used during the *next* frame.** After EOF, `u_ccl` runs a four-phase resolution FSM inside the vertical blanking interval (path-compress → fold → top-N select → reset) and then performs a `PHASE_SWAP` that atomically promotes the new `N_OUT` bbox slots into the front register bank. These outputs are stable for the entire duration of the next frame. `u_overlay_bbox` reads them as a static sideband while processing that next frame's video.
3. **Adding stages to the mask path (morph, Gaussian, stricter CCL variants) just delays when the EOF resolution happens within the vblank.** As long as the full resolution FSM completes before the next frame's first pixel reaches the overlay, the bbox is ready in time. Vblank headroom must exceed the CCL worst-case EOF-FSM cycle budget plus the latency of any mask-path stages ahead of it; see [axis_ccl-arch.md](axis_ccl-arch.md) §6.7 and [axis_morph_clean-arch.md](axis_morph_clean-arch.md).

`u_morph_clean` is the concrete application of this property — inserted between `u_motion_detect` and `u_ccl` without any compensating delay on the `fork_b` RGB path. Future mask-path stages (additional morphology, stricter thresholding) can slot in the same way.

---

## 5. Design Rationale

This chapter explains what each processing sub-block contributes to the video/mask flow in plain terms. Implementation details live in the per-module specs linked below. CDC FIFOs and the `axis_fork` broadcast are not covered here — they carry data between clock domains and consumers respectively but do not transform the video or mask.

### 5.1 `u_motion_detect` — detect moving pixels

The motion-detect stage is `bg_model`-selectable at elaboration time. `sparevideo_top` uses a `generate` block keyed on `CFG.bg_model`:

- **`BG_MODEL_EMA` (default, `bg_model=0`):** instantiates `axis_motion_detect` (`u_motion_detect_ema`). Produces a 1-bit motion mask by converting RGB → Y8, optionally smoothing with a 3×3 Gaussian (`CFG.gauss_en`), then thresholding `|Y − bg| > CFG.motion_thresh`. The background `bg` is an EMA in shared RAM with two rates — fast (`CFG.alpha_shift`) on non-motion pixels for lighting drift, slow (`CFG.alpha_shift_slow`) on motion pixels to avoid trails — plus a `CFG.grace_frames` window that suppresses frame-0 ghosts. Details: [axis_motion_detect-arch.md](axis_motion_detect-arch.md).
- **`BG_MODEL_VIBE` (`bg_model=1`):** instantiates `axis_motion_detect_vibe` (`u_motion_detect_vibe`). Produces the same 1-bit motion mask using the ViBe background-subtraction algorithm: a per-pixel sample bank of K luma values, each new pixel classified as motion if fewer than `MIN_MATCH` samples are within L1 distance R. Stochastic per-pixel update (probability 1/φ) and neighbor diffusion. Parametric `K∈{8,20}`. External-init path loads a pre-computed lookahead-median bank via `$readmemh`. Details: [axis_motion_detect_vibe-arch.md](axis_motion_detect_vibe-arch.md).

Both variants present an identical AXI4-Stream interface to the rest of the pipeline and are verified bit-exact against their respective Python reference models at TOLERANCE=0.

### 5.2 `u_hflip` — selfie-cam horizontal mirror

Buffers each input line and emits it in reverse column order: 1-line latency, 1 pixel/cycle long-term. Placed before `u_fork`, so the mask and bbox coordinates are computed on the mirrored frame and the overlay needs no axis-flip math. `CFG.hflip_en=0` (the default) is a zero-latency combinational bypass. Details: [axis_hflip-arch.md](axis_hflip-arch.md).

**FIFO sizing.** During hflip's TX phase the upstream is stalled, so the input CDC FIFO must absorb up to one line of write-clock pixels. At a 4:1 dsp/pix ratio and `H_ACTIVE=320`, worst case is ~80 entries — `IN_FIFO_DEPTH=128` covers it. The output side accumulates ~`3·H_ACTIVE/4` entries per line; `OUT_FIFO_DEPTH=256` covers it (and bumps to 1024 with `CFG.scaler_en=1`; see §6.1).

### 5.3 `u_morph_clean` — clean speckle and close gaps in the mask

3×3 morphological opening (erode → dilate) followed by a parametrizable 3×3 or 5×5 closing (dilate → erode) on the 1-bit mask. The open erodes salt noise and features narrower than 3 pixels while the dilation restores survivors to roughly their original shape; without it, each sensor-noise speckle becomes its own component in `u_ccl` and crowds real objects out of the `N_OUT` bbox list. The close bridges small intra-object gaps so a single moving object produces one connected blob rather than fragmented components. `CFG.morph_open_en=0` and `CFG.morph_close_en=0` are each independent zero-latency bypasses. Details: [axis_morph_clean-arch.md](axis_morph_clean-arch.md).

### 5.4 `u_ccl` — group motion pixels into objects

Single-pass 8-connected streaming connected-component labeling. Per-label `{min_x, max_x, min_y, max_y, count}` accumulates as pixels arrive; at end-of-frame, during vblank, the equivalence chains are resolved, components below `CCL_MIN_COMPONENT_PIXELS` are dropped, and the top `CCL_N_OUT` bboxes are committed to a double-buffered sideband that holds for the next frame. Details: [axis_ccl-arch.md](axis_ccl-arch.md).

### 5.5 `u_overlay_bbox` — draw rectangles on the video

For each streaming pixel, combinationally checks whether `(col, row)` lies on any valid bbox slot's rectangle edge and replaces it with `BBOX_COLOR` if so. Zero latency, zero buffering. All detection and grouping is upstream — the overlay just draws what CCL committed. Details: [axis_overlay_bbox-arch.md](axis_overlay_bbox-arch.md).

### 5.6 `u_gamma_cor` — sRGB display gamma

The last AXIS stage on `clk_dsp` before the output CDC FIFO. Per-channel 33-entry sRGB encode LUT with linear interpolation. 1-cycle pipeline. The upstream pipeline runs in linear light; the display expects sRGB-encoded values, so without this stage midtones look muddy. `CFG.gamma_en=0` is a zero-latency bypass. Details: [axis_gamma_cor-arch.md](axis_gamma_cor-arch.md).

### 5.7 `u_hud` — bitmap text HUD

Fixed-layout 8×8 bitmap text overlay at output coordinates `(8, 8)`, sitting between `u_scale2x.m_axis` and `u_fifo_out.s_axis`. Draws `F:####  T:XXX  N:##  L:#####US` — frame number, control-flow tag, bbox count, latency µs. Running post-scaler keeps glyph edges pixel-crisp.

Four sidebands feed the HUD, all sourced in `sparevideo_top` on `clk_dsp`: a 16-bit frame counter incrementing per HUD-input-SOF; a popcount of the CCL `valid` bits (one frame behind the video, matching the rectangles' 1-frame lag); the 2-bit `ctrl_flow_i` decoded to a glyph triple; and a per-frame latency in µs measured from input-SOF at `u_fifo_in.m_axis` to HUD-input-SOF (cycle delta `× 41 >> 12`, saturated to 16 bits).

`CFG.hud_en=0` is a data-equivalent passthrough through the same 1-cycle skid. The caller must place the HUD region inside the active output frame. The displayed `LAT` excludes the output CDC drain and VGA startup hold-off, so true pixel-to-display latency is a few cycles greater. Details: [axis_hud-arch.md](axis_hud-arch.md).

### 5.8 `u_vga` — drive the display with proper timing

Emits the processed RGB stream with VGA timing: hsync, vsync, porches, and blanking with RGB gated to 0. Held in reset until the first SOF pixel arrives from the output FIFO, so the VGA scan always aligns to a frame boundary regardless of pipeline fill time. Details: [vga_controller-arch.md](vga_controller-arch.md).

### 5.9 1-frame bbox latency

The bbox drawn on frame N is computed from motion in frame N−1. The pipeline is streaming raster-order, so the bottommost motion pixel may lie on the last row and the bbox is not known until EOF — but the overlay needs the bbox while emitting pixels at the *top* of the frame. Same-frame overlay would require buffering the full RGB frame (~225 kB, ~3× the current RAM budget). The 16.7 ms lag at 60 fps is imperceptible; one-frame delay is the standard streaming trade-off.

### 5.10 Latency and timing budget

Two distinct latencies:

- **Pixel-path latency** — cycles from input pixel to matching VGA RGB output. Varies by control flow.
- **Bbox latency** — fixed at **1 frame** (§5.9).

Pixel-path totals (steady-state, `CFG_DEFAULT`):

| Control flow | Pixel total (≈) |
|---|---|
| Passthrough | ~9 cycles |
| Motion | ~9 cycles (video takes `fork_b`; mask runs in parallel) |
| Mask display | `3·H_ACTIVE + ~19` cycles |
| CCL bbox | `3·H_ACTIVE + ~19` cycles |

At `H_ACTIVE=320` and 100 MHz the long paths are ≈10 µs — negligible vs. the 16.7 ms frame. Per-stage breakdowns live in the module specs.

**Video/mask asymmetry.** In motion mode the video reaches the overlay in ~5 cycles via `fork_b` while the mask traverses motion_detect → morph → ccl for `3·H_ACTIVE + ~14` cycles. The mask cannot overtake the video — *this* is why the bbox is one frame late (§5.9).

**V-blank budget.** Blanking must absorb the cascading drains of `axis_gauss3x3` + `axis_morph_clean` (each sub-stage ≥ `H_ACTIVE + 1` cycles, drained sequentially) plus the `u_ccl` EOF FSM. Detailed in [`axis_ccl-arch.md`](axis_ccl-arch.md) §6.7.

**4:1 clock ratio.** `clk_dsp` is 4× `clk_pix`, so the pipeline can emit up to 4 output pixels per input pixel; after fill, throughput is 1 pixel/cycle. Both CDC FIFOs stay near empty; SVAs in §9 catch violations.

---

## 6. Internal Architecture

```
                         sparevideo_top
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │                                                                              │
  │  s_axis (axis_if.rx: RGB888 + tlast + tuser)  clk_pix_in domain              │
  │  ─────────────────────────────────────────────────────────                   │
  │           │                                                                  │
  │           ▼                                                                  │
  │    ┌─────────────┐  CDC: clk_pix_in → clk_dsp                                │
  │    │  u_fifo_in  │                                                           │
  │    └──────┬──────┘                                                           │
  │           │  pix_in_to_hflip                                                 |
  │           ▼                                                                  │
  │    ┌─────────────┐                                                           │
  │    │   u_hflip   │                                                           │
  │    └──────┬──────┘                                                           │
  │           │  hflip_to_fork                                                   │
  │           ▼                                                                  │
  │    ┌─────────────┐  1-to-2 broadcast                                         │
  │    │   u_fork    │                                                           │
  │    └──┬───────┬──┘                                                           │
  │       │       └───────────────────────────────────────────┐                  │
  │  fork_a_to_motion                                fork_b_to_overlay           │
  │       │                                                   │                  │
  │       ▼                                                   │                  │
  │    ┌──────────────────┐    ┌───────────┐                  │                  │
  │    │ u_motion_detect  │    │   u_ram   │  BG model        │                  │
  │    │                  │◄──►│  (port A) │  (Y8, H×V bytes) │                  │
  │    │                  │    └───────────┘                  │                  │
  │    └────────┬─────────┘                                   │                  │
  │             │  motion_to_morph (1-bit mask)               │                  │
  │             ▼                                             │                  │
  │    ┌──────────────────┐                                   │                  │
  │    │ u_morph_clean    │                                   │                  │
  │    └────────┬─────────┘                                   │                  │
  │             │  morph_to_ccl                               │                  │
  │             ├───────────────────────────────────┐         │                  │
  │             ▼                                   │         │                  │
  │    ┌──────────────────┐                         │         │                  │
  │    │      u_ccl       │                         │         │                  │
  │    └────────┬─────────┘                         │         │                  │
  │             │  u_ccl_bboxes                     │         │                  │
  │             │                                   │         │                  │
  │             │   ┌───────────────────────────────┘         │                  │
  │             │   │  (ccl_bbox mode) mask → grey mux        │                  │
  │             │   ▼                                         ▼                  │
  │             │  ┌──────────────────────────────────────────────────┐          │
  │             │  │  overlay_in mux:                                 │          │
  │             │  │    motion              → fork_b_to_overlay RGB   │          │
  │             │  │    ccl_bbox            → mask_grey_rgb           │          │
  │             │  └────────────────────┬─────────────────────────────┘          │
  │             ▼                       ▼                                        │
  │    ┌────────────────────────────────────────────────────────────┐            │
  │    │                   u_overlay_bbox                           │            │
  │    └────────────────────┬───────────────────────────────────────┘            │
  │                         │  overlay_to_pix_out                                │
  │                         │                                                    │
  │    ┌────────────────────┴─────────────────────────────┐                      │
  │    │  ctrl_flow mux                                   │                      │
  │    │     passthrough → pix_in_to_hflip                │                      │
  │    │     motion      → overlay_to_pix_out             │                      │
  │    │     mask        → msk_rgb                        │                      │
  │    │     ccl_bbox    → overlay_to_pix_out             │                      │
  │    └────────────────────┬─────────────────────────────┘                      │
  │                         │  proc                                              │
  │                         ▼                                                    │
  │                 ┌──────────────┐                                             │
  │                 │  u_scale2x   │                                             │
  │                 └──────┬───────┘                                             │
  │                        │  scale2x_to_pix_out                                 │
  │                        ▼                                                     │
  │                 ┌──────────────┐                                             │
  │                 │    u_hud     │                                             │
  │                 └──────┬───────┘                                             │
  │                        │  hud_to_pix_out                                     │
  │                        ▼                                                     │
  │                 ┌──────────────┐  CDC: clk_dsp → clk_pix_out                 │
  │                 │  u_fifo_out  │                                             │
  │                 └──────┬───────┘                                             │
  │                        │  pix_out_axis                                       │
  │                        ▼                                                     │
  │                 ┌──────────────┐                                             │
  │                 │    u_vga     │                                             │
  │                 └──────┬───────┘                                             │
  │                        │                                                     |
  | ─────────────────────────────────────────────────────────                    │
  │  VGA pins: hsync, vsync, R[7:0], G[7:0], B[7:0]                              │
  │                                                                              │
  └──────────────────────────────────────────────────────────────────────────────┘
```

The control-flow mux selects between:
- **Passthrough** (`ctrl_flow_i = 2'b00`): `pix_in_to_hflip` feeds directly into `u_fifo_out` (flat-bridge). `u_fork` input `tvalid` is gated to 0; overlay output `tready` is tied to 1.
- **Motion detect** (`ctrl_flow_i = 2'b01`): `overlay_to_pix_out` feeds into `u_fifo_out`. Both fork outputs are active; `fork_b_to_overlay` provides RGB to the overlay while `fork_a_to_motion` feeds `u_motion_detect` → `u_morph_clean` → `u_ccl` for bbox generation via `u_ccl_bboxes`. This is the default path.
- **Mask display** (`ctrl_flow_i = 2'b10`): `msk_rgb` (cleaned 1-bit mask expanded to 24-bit B/W) feeds into `u_fifo_out`. The overlay path is drained (overlay `tready = 1`). Mask `tready` carries output FIFO backpressure; `u_ccl` still receives the cleaned mask via the broadcast handshake but its bboxes are not used.
- **CCL bbox** (`ctrl_flow_i = 2'b11`): `overlay_to_pix_out` feeds into `u_fifo_out`, but the overlay's video input (`overlay_in`) is `mask_grey_rgb` (a combinational grey canvas derived from the cleaned mask) instead of `fork_b_to_overlay`. `fork_b_to_overlay.tready` is tied to 1 so the unused RGB pipe drains. `u_ccl` runs normally and its `u_ccl_bboxes` are drawn on top of the grey canvas — a direct visual readout of the CCL stage.

### 6.1 Plumbing and glue

Per-block roles for the processing stages (`u_motion_detect`, `u_morph_clean`, `u_ccl`, `u_overlay_bbox`, `u_vga`) are covered in §5. The remaining top-level plumbing:

- **u_fifo_in / u_fifo_out**: CDC between the pixel domains (`clk_pix_in` / `clk_pix_out`) and `clk_dsp`; `IN_FIFO_DEPTH = 128`, `OUT_FIFO_DEPTH = 256` (bumps to `1024` when `CFG.scaler_en=1` to absorb the scaler's burst output, since it emits up to 4 beats per input pixel). Overflow detected by SVA (§9).
- **u_scale2x**: 2x bilinear spatial upscaler instantiated under a generate gate when `CFG.scaler_en=1`. When `CFG.scaler_en=0`, the gate produces a zero-latency combinational bridge (`assign` chain from `gamma_to_pix_out` to `scale2x_to_pix_out`) so the path is byte-identical to pre-scaler runs. See [axis_scale2x-arch.md](axis_scale2x-arch.md).
- **u_fork**: zero-latency 1-to-2 broadcast with per-output acceptance tracking, so asymmetric consumer stalls do not corrupt data. Instantiated in the motion pipeline path only; fork input `tvalid` is gated to 0 in passthrough mode.
- **u_ram**: dual-port byte RAM. Port A owned by `u_motion_detect` for the EMA background model; port B reserved for a future host client. Zero-initialized. See [ram-arch.md](ram-arch.md).
- **vga_rst_n gating**: VGA held in reset until the first `tuser=1` pixel exits `u_fifo_out`, aligning the VGA scan to a frame boundary regardless of FIFO fill time.

### 6.2 AXI4-Stream protocol

- `tdata[23:0]` = `{R[7:0], G[7:0], B[7:0]}`, RGB888.
- `tuser[0]` = SOF — asserted only on pixel `(0, 0)` of each frame.
- `tlast` = EOL — asserted on the last pixel of each row.
- A transfer occurs when `tvalid && tready` are both asserted.
- No blanking pixels in the stream — exactly `H_ACTIVE × V_ACTIVE` pixels per frame.
- The motion-mask sideband stream uses the same framing with `tdata[0]` as the 1-bit mask value.

---

## 7. Clock Domains

| Domain | Clock | Modules |
|--------|-------|---------|
| `clk_pix_in` | nominally 25 MHz (1x) | source driver, `u_fifo_in` write side |
| `clk_pix_out` | `CFG.scaler_en=0`: tied to `clk_pix_in`. `CFG.scaler_en=1`: 4x `clk_pix_in` so VGA can drain the 2x-upscaled output. | `u_fifo_out` read side, `u_vga`, VGA reset gating |
| `clk_dsp` | 100 MHz | `u_fifo_in` read side, `u_fork`, `u_motion_detect`, `u_ram`, `u_morph_clean`, `u_ccl`, `u_overlay_bbox`, `u_gamma_cor`, `u_scale2x` (when `CFG.scaler_en=1`), `u_fifo_out` write side |

CDC crossings use vendored `axis_async_fifo` from [alexforencich/verilog-axis](https://github.com/alexforencich/verilog-axis) (MIT). Active-high resets are derived at the top level: `rst_pix_in = ~rst_pix_in_n_i`, `rst_pix_out = ~rst_pix_out_n_i`, `rst_dsp = ~rst_dsp_n_i`.

---

## 8. Region Descriptor Model

The shared RAM is partitioned into named regions with `{BASE, SIZE}` descriptors. Descriptors are compile-time localparams in `sparevideo_top.sv`, structured for future migration to SW-writable CSRs.

```
Region       Owner                Base              Size
─────────    ─────────────        ────              ────
BG_MODEL     axis_motion_detect   RGN_Y_PREV_BASE=0 RGN_Y_PREV_SIZE = H_ACTIVE × V_ACTIVE
(reserved)   (port B, future)     —                 —
```

The BG_MODEL region stores the per-pixel EMA background estimate (8-bit luma). Each pixel is updated on every frame via the EMA formula in `axis_motion_detect`. Zero-initialized, so the first few frames see full-frame motion until the background converges.

A compile-time guard checks that `BASE + SIZE ≤ RAM_DEPTH`. Each client module receives its `RGN_BASE` and `RGN_SIZE` as parameters; it adds `RGN_BASE` to its internal counter to form the physical address, so the RAM module itself has no knowledge of partitions.

### 8.1 Future CSR register file (deferred)

When runtime configurability is needed, the descriptor table and the `CFG` fields (`motion_thresh`, `bbox_color`, EMA rates, stage enables) migrate to a `sparevideo_csr` AXI-Lite slave on a new top-level port. Client module parameters become input ports of the same width; CSR values are latched on SOF to prevent mid-frame glitches.

---

## 9. Assertions

| Assertion | Clock | Description |
|-----------|-------|-------------|
| `assert_no_input_backpressure` | `clk_pix` | Input must not be back-pressured — all pipeline stages must sustain 1 pixel/clk |
| `assert_no_output_underrun` | `clk_pix` | Once VGA is started, `pix_out_tvalid` must be high whenever `pixel_ready_o` is asserted |
| `assert_fifo_in_not_full` | `clk_pix` | Input FIFO depth must stay below `IN_FIFO_DEPTH` |
| `assert_fifo_out_not_full` | `clk_dsp` | Output FIFO depth must stay below `OUT_FIFO_DEPTH` |
| `assert_fifo_in_no_overflow` | `clk_pix` | Sticky overflow flag from input FIFO must not be set |
| `assert_fifo_out_no_overflow` | `clk_dsp` | Sticky overflow flag from output FIFO must not be set |

---

## 10. Known Limitations

- **Simulation-only RAM**: `ram.sv` is a behavioral model. FPGA synthesis requires a vendor BRAM primitive (e.g. Xilinx `xpm_memory_tdpram`).
- **Frame-0 full-frame border**: the zero-initialized RAM means every pixel on frame 0 reads as motion. The bounding box would span the full frame and the overlay would draw a border around the image edge. This is a known cosmetic artifact. `axis_ccl` suppresses bboxes for the first `CCL_PRIME_FRAMES` frames so no rectangle is drawn until the EMA background has converged.
- **1-frame overlay latency**: the bbox drawn on frame N is derived from the motion observed during frame N−1. This is a deliberate architectural choice — see §5.9. Same-frame overlay would cost ~225 KB of frame-buffer RAM for no human-visible improvement at 60 fps.
- **Same-frame bbox**: bbox coordinates are latched at EOF; mid-frame updates are not possible with the current design.
- **Thin-feature deletion under morph**: `u_morph_clean`'s open stage erases foreground features narrower than 3 pixels (single-pixel lines, far-field point targets). Profile `no_morph` (`CFG.morph_open_en=0`) is the escape hatch; see [axis_morph_clean-arch.md](axis_morph_clean-arch.md).
- **No AXI-Lite control**: all algorithm parameters (motion threshold, bbox colour, EMA rates, stage enables) are compile-time fields of `CFG`. Runtime override requires synthesizing a CSR slave (see §8.1).
- **Port B unused**: `u_ram` port B is tied off. A future host client (debug dump, FPN reference, etc.) may connect here, subject to the host-responsibility rule in [ram-arch.md](ram-arch.md).
- **Pixel-clock stability assumption (CFG.scaler_en=1)**: the design assumes the caller provides `clk_pix_out_i` at exactly 4× `clk_pix_in_i` so long-term input/output rates balance through the output FIFO. Real silicon would need either a genlocked PLL pair or a dedicated output-side frame buffer to handle independent source/display clocks. See [axis_scale2x-arch.md](axis_scale2x-arch.md) for the rate-budget detail.

---

## 11. Resources

**Bold** entries exceed 1 kB. CCL defaults: `N_LABELS_INT=64`. Input FIFO depth `IN_FIFO_DEPTH=128`, output FIFO depth `OUT_FIFO_DEPTH=256` (or 1024 when `CFG.scaler_en=1`); 26 bits wide (24 b `tdata` + `tlast` + `tuser`).

| Memory | Module | 320×240 | 640×480 | 1920×1080 | Technology |
|--------|--------|---------|---------|-----------|------------|
| EMA background model | `u_ram` | **75 kB** | **300 kB** | **~1.98 MB** | Behavioral TDPRAM → BRAM on FPGA |
| Gaussian line buffers (×2) | `u_motion_detect` (`gauss_en=1`) | 640 B | **1.25 kB** | **3.75 kB** | Distributed LUT-RAM |
| Mask cleanup line buffers (×8) | `u_morph_clean` (`morph_open_en=1`, `morph_close_kernel=3`) | 320 B | 640 B | 1920 B | Distributed LUT-RAM |
| CCL label line buffer | `u_ccl` | 240 B | 480 B | **1.41 kB** | Distributed LUT-RAM |
| CCL accumulator bank (×5 arrays) | `u_ccl` | 408 B | 456 B | 520 B | Distributed LUT-RAM |
| CCL equivalence table | `u_ccl` | 48 B | 48 B | 48 B | Distributed LUT-RAM |
| CDC FIFOs (×2) | `u_fifo_in`, `u_fifo_out` | ~416 B / ~832 B | ~416 B / ~832 B | ~416 B / ~832 B | axis_async_fifo, `IN_FIFO_DEPTH=128` / `OUT_FIFO_DEPTH=256` |

Sizing formulas (W = H\_ACTIVE, H = V\_ACTIVE):

| Memory | Formula |
|--------|---------|
| EMA background model | W × H bytes |
| Gaussian line buffers | 2 × W bytes |
| Mask cleanup line buffers | 8 × W bits (2 per sub-module × 4 sub-modules for open+close with `CLOSE_KERNEL=3`; 12 × W bits for `CLOSE_KERNEL=5`) |
| CCL label line buffer | W × ⌈log₂(N\_LABELS\_INT)⌉ bits |
| CCL accumulator bank | N\_LABELS\_INT × (2⌈log₂W⌉ + 2⌈log₂H⌉ + ⌈log₂(WH+1)⌉) bits |
| CCL equivalence table | N\_LABELS\_INT × ⌈log₂(N\_LABELS\_INT)⌉ bits |

See [ram-arch.md](ram-arch.md) for port ownership semantics and the behavioral-to-BRAM substitution note.

---

## 12. References

- [AMBA AXI4-Stream Protocol Specification — Arm](https://developer.arm.com/documentation/ihi0051/latest/)
- [alexforencich/verilog-axis — GitHub (MIT)](https://github.com/alexforencich/verilog-axis)
- [VGA signal timing — TinyVGA](http://www.tinyvga.com/vga-timing)
