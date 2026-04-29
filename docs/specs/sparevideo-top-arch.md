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
  - [5.3 `u_morph_open` — clean up speckle in the mask](#53-u_morph_open--clean-up-speckle-in-the-mask)
  - [5.4 `u_ccl` — group motion pixels into distinct objects](#54-u_ccl--group-motion-pixels-into-distinct-objects)
  - [5.5 `u_overlay_bbox` — draw rectangles on the video](#55-u_overlay_bbox--draw-rectangles-on-the-video)
  - [5.6 `u_gamma_cor` — sRGB display gamma at the post-mux tail](#56-u_gamma_cor--srgb-display-gamma-at-the-post-mux-tail)
  - [5.7 `u_vga` — drive the display with proper timing](#57-u_vga--drive-the-display-with-proper-timing)
  - [5.8 1-frame bbox latency](#58-1-frame-bbox-latency)
  - [5.9 Latency and timing budget](#59-latency-and-timing-budget)
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

`sparevideo_top` is the top-level video processing pipeline. It accepts an AXI4-Stream RGB888 video input on the input pixel clock (`clk_pix_in_i`, nominally 25 MHz), crosses the stream into a 100 MHz DSP clock domain, runs a **control-flow-selectable** processing pipeline, crosses back to the output pixel clock (`clk_pix_out_i`), and drives a VGA controller to produce analogue RGB + hsync/vsync output. When `CFG.scaler_en=0` the two pixel clocks are tied together; when `CFG.scaler_en=1` `clk_pix_out_i` runs at 4x `clk_pix_in_i` so the VGA can drain the 2x-upscaled output stream at full rate.

A top-level `ctrl_flow_i` sideband signal (2-bit) selects the active processing path. **Motion** is the production flow; **passthrough**, **mask display**, and **ccl_bbox** are debug/bring-up aids:
- **Passthrough** (`ctrl_flow_i = 2'b00`): input pixels pass directly to the output FIFO with no processing.
- **Motion detect** (`ctrl_flow_i = 2'b01`, default): motion-detection → morphological opening → streaming CCL → up-to-`N_OUT` per-component bounding-box overlay pipeline.
- **Mask display** (`ctrl_flow_i = 2'b10`, debug): cleaned 1-bit motion mask expanded to black/white RGB. Uses the same motion-detect + morph front-end but bypasses CCL/overlay, outputting the mask directly for tuning and visual inspection.
- **CCL bbox** (`ctrl_flow_i = 2'b11`, debug): the cleaned 1-bit motion mask is combinationally expanded to a grey canvas (mask=1 → light grey, mask=0 → dark grey) and routed into the overlay. Visualizes the CCL bbox output directly on top of the mask, decoupling CCL verification from the overlay's interaction with live RGB.

When the motion pipeline is bypassed (passthrough), the fork input `tvalid` is gated to 0 and the overlay output `tready` is tied to 1 to prevent stalling. Motion, mask, and ccl_bbox modes all activate the motion detect + morph + CCL pipeline.

The module does **not** include: camera input (MIPI CSI-2), AXI-Lite register access, multi-clock `clk_pix` sources, or any processing beyond luma-difference motion detection, 3×3 morphological opening, 8-connected connected-component labeling, and N-way bounding-box overlay.

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
├── axis_morph3x3_open    (u_morph_open)    — 3×3 opening (erode → dilate) on the mask; runtime bypassable
├── axis_ccl           (u_ccl)           — cleaned mask → N_OUT × {min_x,max_x,min_y,max_y,valid}
├── axis_overlay_bbox  (u_overlay_bbox)  — draw N_OUT-wide bbox rectangles on RGB video
├── axis_gamma_cor     (u_gamma_cor)     — per-channel sRGB gamma correction; runtime bypassable
├── axis_scale2x       (u_scale2x)       — 2x spatial upscaler (NN or bilinear); compile-time gate (CFG.scaler_en)
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
| `CFG.morph_en` | `logic` | `1` | Enable the 3×3 morphological opening (`u_morph_open`) on the mask. `0` bypasses (raw mask flows downstream). |
| `CFG.hflip_en` | `logic` | `0` | Enable the horizontal mirror (`u_hflip`) at the head of the proc-clock pipeline. `0` passes the input through unchanged. |
| `CFG.gamma_en` | `logic` | `1` | Enable the sRGB gamma-correction stage (`u_gamma_cor`) at the post-mux tail. `0` bypasses (linear-light pixels reach the output FIFO). |
| `CFG.scaler_en` | `logic` | `1` | Enable the 2x bilinear spatial upscaler (`u_scale2x`) before the output FIFO. `0` bypasses (output resolution equals input resolution). |
| `CFG.bbox_color` | `pixel_t` (24-bit RGB) | `0x00_FF_00` (green) | RGB triple drawn by `u_overlay_bbox` for every bounding-box edge pixel. Driven into `u_overlay_bbox.BBOX_COLOR`. |
| `CCL_N_LABELS_INT` | `int` | pkg (64) | Internal label-table size in `u_ccl`. Cap on the number of distinct provisional labels tracked in one frame before a label-exhaust fallback (merge into label 0). |
| `CCL_N_OUT` | `int` | pkg (8) | Number of per-component bounding-box output slots exposed from `u_ccl` to `u_overlay_bbox`. |
| `CCL_MIN_COMPONENT_PIXELS` | `int` | pkg (16) | Minimum component area (in pixels) to promote into the top-N bbox output — filters sensor-noise specks. |
| `CCL_MAX_CHAIN_DEPTH` | `int` | pkg (8) | Safety cap on parent-pointer chain walks during the EOF fold phase. |
| `CCL_PRIME_FRAMES` | `int` | pkg (0) | Number of frames after reset during which `u_ccl` suppresses all bbox outputs, giving the EMA background model time to converge. |

`H_ACTIVE` and `V_ACTIVE` set the active video region; the eight porch parameters set the surrounding blanking intervals. Together they determine the VGA frame format used by `u_vga` and the timing the input driver must mirror.

`CFG` is resolved at compile time from the `CFG_NAME` string (TB plusarg / Makefile `CFG=` knob) and routed by `sparevideo_top` to the appropriate sub-module ports. The Python reference models in `py/models/` mirror the same fields via `py/profiles.py`; a parity test (`py/tests/test_profiles.py`) guards against drift. Adding a new algorithm knob costs one field in `cfg_t`, one matching key in every profile dict in `py/profiles.py`, and one wire in `sparevideo_top` from `CFG.<new_field>` to the consuming module. The existing profile set is `default`, `default_hflip`, `no_ema`, `no_morph`, `no_gauss`, `no_gamma_cor`, `no_scaler`.

**Output resolution.** `H_ACTIVE_OUT/V_ACTIVE_OUT` come from `sparevideo_pkg::*_OUT_2X` when `CFG.scaler_en=1`; otherwise they equal the input dims. The VGA controller uses the OUT dims; the input AXIS, motion pipeline, gamma stage, and scaler input all stay at input dims. The TB drives input frames at input dims and captures output at output dims. Rate balance between the input and output sides is enforced by the clock-period ratio: when `CFG.scaler_en=1` the caller drives `clk_pix_in_i` at one-quarter the frequency of `clk_pix_out_i`; when `CFG.scaler_en=0` they're tied to the same clock.

`ctrl_flow_i` is a quasi-static sideband signal (set before the frame, not changed mid-frame).

---

## 4. Concept Description

The sparevideo pipeline implements real-time video processing using a **dual-clock-domain** architecture. The pixel clock (25 MHz) matches the VGA output timing standard (640x480 @ 60 Hz), while the DSP clock (100 MHz) provides 4× computation headroom for the processing pipeline. This clock ratio ensures that the processing pipeline can always sustain 1 pixel per `clk_pix` cycle without backpressure, even though the pipeline operates at `clk_dsp` granularity.

The key architectural concept is **control-flow-selectable processing**: a single pipeline front-end (CDC → motion detection → morph → streaming CCL) is shared across multiple output modes, selected at runtime by a 2-bit sideband signal. This avoids duplicating hardware for each mode while allowing the user to switch between:
- **Passthrough**: raw video with no processing — for baseline comparison.
- **Motion overlay**: the full motion detection → morph → CCL → multi-bbox overlay pipeline — the primary use case.
- **Mask display**: the cleaned binary motion mask expanded to black/white — for algorithm tuning and debugging.
- **CCL bbox (debug)**: the cleaned mask rendered as a grey canvas with the CCL bboxes drawn on top — for verifying CCL output independently of the RGB pass-through path.

Clock domain crossing (CDC) is handled by asynchronous FIFOs at the pipeline boundaries (`u_fifo_in` at entry, `u_fifo_out` at exit). This decouples the input pixel rate from the DSP processing rate and the VGA output rate, with the FIFOs absorbing burst mismatches during blanking intervals. The 4:1 clock ratio means the DSP domain processes pixels faster than they arrive, so the input FIFO drains quickly and the output FIFO stays well below capacity during normal operation.

The processing pipeline itself (motion detection → morph → streaming CCL → N-way overlay) is documented in the individual module architecture documents. At the top level, the concern is how these modules are interconnected, how control flow selects between them, and how CDC and timing constraints are satisfied.

### 4.1 Dual-path pipeline: what is the "mask"?

Before the fork, `axis_hflip` (`u_hflip`) optionally mirrors each input line horizontally. Because `u_hflip` is upstream of `u_fork`, the motion mask and bbox coordinates are computed on the mirrored view. The user-visible RGB and the mask therefore agree by construction — no coordinate-flip is needed in the overlay. `CFG.hflip_en=0` bypasses the stage with a zero-latency combinational path.

In motion/mask modes, the pipeline processes two parallel streams forked from the same input video. A top-level `axis_fork` (`u_fork`) broadcasts the DSP-domain input to two consumers:

1. **Video path (RGB, 24-bit per pixel, `fork_b`):** The original RGB pixels feed directly from the fork to `u_overlay_bbox`, bypassing `u_motion_detect` entirely. They are never modified by the motion-detection logic. The fork ensures the overlay receives the same pixels with no additional latency.
2. **Mask path (1-bit per pixel, `fork_a`):** `u_motion_detect` receives the second fork output, converts each pixel to Y8, compares against the per-pixel background model, and emits a single bit: **"did this pixel change compared to the background?"** A `1` means yes (motion detected at this pixel), a `0` means no (this pixel looks the same as the background model). The raw mask is then passed through `u_morph_open` for speckle cleanup before it reaches the downstream consumers.

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
3. **Adding stages to the mask path (morph, Gaussian, stricter CCL variants) just delays when the EOF resolution happens within the vblank.** As long as the full resolution FSM completes before the next frame's first pixel reaches the overlay, the bbox is ready in time. Vblank headroom must exceed the CCL worst-case EOF-FSM cycle budget plus the latency of any mask-path stages ahead of it; see [axis_ccl-arch.md](axis_ccl-arch.md) §6.7 and [axis_morph3x3_open-arch.md](axis_morph3x3_open-arch.md) §7.

`u_morph_open` is the first concrete application of this property — inserted between `u_motion_detect` and `u_ccl` without any compensating delay on the `fork_b` RGB path. Future mask-path stages (additional morphology, stricter thresholding) can slot in the same way.

---

## 5. Design Rationale

This chapter explains what each processing sub-block contributes to the video/mask flow in plain terms. Implementation details live in the per-module specs linked below. CDC FIFOs and the `axis_fork` broadcast are not covered here — they carry data between clock domains and consumers respectively but do not transform the video or mask.

### 5.1 `u_motion_detect` — detects moving pixels

Takes the input RGB stream and produces a 1-bit-per-pixel motion mask: `1` where the current pixel differs from a learned per-pixel background model, `0` elsewhere. Internally it converts RGB → Y8 (luma captures nearly all motion information at 1/3 the bandwidth), optionally smooths the Y8 plane with a 3×3 Gaussian (`CFG.gauss_en=1`) to reject sensor noise spikes, and then thresholds `|Y_current − Y_background|` against `CFG.motion_thresh`. The background model is an exponential moving average (EMA) stored in shared RAM, updated every frame so slow lighting drift is absorbed into the background rather than being reported as motion. A two-rate EMA keeps the background stable even under a moving object — fast on non-motion pixels (`CFG.alpha_shift`), very slow on motion pixels (`CFG.alpha_shift_slow`) — and a short grace window after reset (`CFG.grace_frames`) prevents frame-0 ghosts.

Without this stage there is no mask. Details: [axis_motion_detect-arch.md](axis_motion_detect-arch.md).

### 5.2 `u_hflip` — present a "selfie-cam" view to the user

Reads each input line into a 320-entry RGB line buffer, then emits the line in reverse column order. Latency: 1 line. Throughput: 1 pixel/cycle long-term. The stage sits before `u_fork`, so the motion mask and bbox coordinates downstream are computed on the mirrored frame — overlay rectangles land on top of the same pixels the user sees, with no axis-flip math elsewhere.

Why this matters: the natural front-camera mental model is that the user's right hand should appear on the right of the image. Without this stage, that requires either a host-side flip on every consumer or a bbox-coordinate flip in the overlay. Doing the flip once at the head of the pipeline keeps every downstream stage coordinate-consistent. `CFG.hflip_en=0` (the default in `CFG_DEFAULT`) is a zero-latency combinational bypass for testing and for callers that prefer the raw input. Details: [axis_hflip-arch.md](axis_hflip-arch.md).

**Backpressure note:** `axis_hflip` alternates between RX (asserts `s_axis_tready_o`) and TX (asserts `m_axis_tvalid_o`) phases over a single line buffer. During TX, upstream is stalled; the input CDC FIFO must absorb up to one line of write-clock pixels. `IN_FIFO_DEPTH = 128` is sized for `pix_clk = 25 MHz`, `dsp_clk = 100 MHz`, `H_ACTIVE = 320` (worst case ~80 entries with margin).

The output CDC FIFO mirrors this concern in the opposite direction: hflip emits 320 pixels in 320 dsp_clk cycles during TX, while VGA drains at the slower pix_clk rate, so the FIFO accumulates ~3*H_ACTIVE/4 entries per line until backpressure throttles upstream. `OUT_FIFO_DEPTH = 256` is sized for H_ACTIVE = 320; the `CFG.scaler_en=1` configuration (output H_ACTIVE = 640, scaler emits 4 beats per input pixel in bursts) bumps `OUT_FIFO_DEPTH` to 1024 — see §6.1.

### 5.3 `u_morph_open` — clean up speckle in the mask

Applies a 3×3 square morphological opening (erosion followed by dilation) to the raw 1-bit mask. Erosion deletes isolated foreground pixels and foreground stripes narrower than three pixels; the subsequent dilation restores the surviving blobs to approximately their original shape. The net effect is "erase salt noise and sub-3px features, keep everything else intact".

Why this matters: without opening, each sensor-noise speckle that survives motion detection becomes its own connected component in `u_ccl` — either crowding out real objects from the `N_OUT` bbox list or littering the overlay with tiny rectangles. `CFG.morph_en=0` (profile `no_morph`) is a zero-latency combinational bypass so the raw vs. cleaned mask can be A/B compared. Details: [axis_morph3x3_open-arch.md](axis_morph3x3_open-arch.md).

### 5.4 `u_ccl` — group motion pixels into distinct objects

Takes the cleaned 1-bit mask and, in a single raster-order pass, assigns each foreground pixel to a connected component using 8-connected streaming union-find. For every label it accumulates `{min_x, max_x, min_y, max_y, pixel_count}` on the fly. At end-of-frame — during vertical blanking — it resolves equivalence chains, drops components smaller than `CCL_MIN_COMPONENT_PIXELS`, and commits the top `CCL_N_OUT` bounding boxes into a double-buffered sideband that is stable for the entire next frame.

Why this matters: a binary mask tells you "there is motion somewhere" but not "how many distinct objects, where". Without CCL the overlay would have to choose between drawing one bbox that spans every motion pixel (useless when multiple objects are present) and drawing a bbox per pixel. CCL is the stage that turns a mask into a short, stable list of object bounding boxes. Details: [axis_ccl-arch.md](axis_ccl-arch.md).

### 5.5 `u_overlay_bbox` — draw rectangles on the video

Consumes the `N_OUT` bbox slots as a sideband and the RGB video as an AXIS stream. For each streaming pixel it computes, combinationally, whether `(col, row)` lies on any valid slot's rectangle edge; if so, the pixel is replaced with `BBOX_COLOR`, otherwise it passes through unchanged. Zero added latency, zero frame buffering.

This is purely a rendering step — all detection and grouping happens upstream. The overlay has no memory of past frames and no opinion about which objects are "interesting"; it just draws what CCL committed. Details: [axis_overlay_bbox-arch.md](axis_overlay_bbox-arch.md).

### 5.6 `u_gamma_cor` — sRGB display gamma at the post-mux tail

The last AXIS stage on `clk_dsp` before the output CDC FIFO. Each of the three RGB channels is independently passed through a 33-entry sRGB encode LUT, with linear interpolation across the low 3 bits (`addr = pixel[7:3]`, `frac = pixel[2:0]`, `out = (LUT[addr]*(8-frac) + LUT[addr+1]*frac) >> 3`). 1-cycle pipeline; the LUT is baked into the SV `localparam` and is the single source of truth shared with `py/models/ops/gamma_cor.py` (a parity test guards against drift).

Why this matters: the upstream pipeline operates in linear-light intensity; the display expects sRGB-encoded values. Without this stage the output looks muddy in midtones. `CFG.gamma_en=0` (profile `no_gamma_cor`) is a zero-latency combinational bypass — useful both for verifying that the integration is byte-clean against pre-gamma goldens and for capturing un-encoded RGB for downstream tone-mapping experiments. Details: [axis_gamma_cor-arch.md](axis_gamma_cor-arch.md).

### 5.7 `u_vga` — drive the display with proper timing

Takes the processed RGB stream (after CDC back to `clk_pix`) and emits it with VGA-compliant timing: horizontal and vertical sync pulses, front/back porches, and blanking intervals during which RGB is gated to 0. The controller is held in reset until the first start-of-frame pixel arrives from the output FIFO, so the VGA scan always aligns to a frame boundary regardless of how long the pipeline takes to fill.

Including the VGA controller inside the DUT means end-to-end simulation captures what an actual monitor would see, including blanking — which in turn catches long-term rate mismatches (output FIFO overflow) that are invisible if the downstream timing generator is mocked away. Details: [vga_controller-arch.md](vga_controller-arch.md).

### 5.8 1-frame bbox latency

The bbox drawn on frame N is computed from motion observed during frame N−1. This is a deliberate architectural choice, not an accident of the implementation. A same-frame overlay is technically possible but strictly worse at this resolution:

The pipeline is streaming (raster order). The bottommost motion pixel can lie on the last row, so the bbox is not fully known until EOF. But the overlay needs the bbox *while outputting pixels at the top of the frame* — which have already been streamed out long before EOF. To draw a rectangle on the same frame, the video pixels would have to be **held back** until the bbox is known, which requires a full RGB frame buffer (320×240×24 bits ≈ 225 KB) and a true dual-port RAM — roughly 3× the current total RAM budget.

| | Same-frame bbox | 1-frame delayed bbox (current) |
|---|---|---|
| RAM cost | +225 KB (frame buffer) | 0 |
| Visual latency | 16.7 ms (frame buffer delay) | 16.7 ms (bbox from prev frame) |
| Perceived delay | Identical to human eye at 60 fps | Identical to human eye at 60 fps |
| Pipeline complexity | Significantly higher | Simple streaming |

At 60 fps, one frame is 16.7 ms — imperceptible. The user-visible result is indistinguishable between the two designs. Same-frame overlay would only matter at very low frame rates (e.g., 1 fps security camera) where a 1-second bbox lag would be noticeable. The current 1-frame delay is the standard approach in streaming video pipelines and is the right trade-off here.

### 5.9 Latency and timing budget

Two distinct latencies, not to be conflated:

- **Pixel-pipeline latency** — cycles from input pixel to matching RGB edge at the VGA output, varies by control flow.
- **Bbox latency** — fixed at **1 frame** by design; see §5.7.

End-to-end pixel-path latency per control flow (steady-state fill, `CFG_DEFAULT`: `gauss_en=1`, `morph_en=1`):

| Control flow | Pixel total (≈) |
|---|---|
| Passthrough | `~9` cycles |
| Motion | `~9` cycles (video takes `fork_b` shortcut; mask runs in parallel) |
| Mask display | `3·H_ACTIVE + ~19` cycles |
| CCL bbox | `3·H_ACTIVE + ~19` cycles |

At `H_ACTIVE = 320` the long paths are ~980 cycles at 100 MHz ≈ **10 µs**, negligible vs. a 16.7 ms frame at 60 fps. Per-stage breakdowns live in the per-module specs ([`axis_motion_detect-arch.md`](axis_motion_detect-arch.md), [`axis_morph3x3_open-arch.md`](axis_morph3x3_open-arch.md), [`axis_ccl-arch.md`](axis_ccl-arch.md)).

**Video/mask asymmetry.** In motion mode the video reaches the overlay in ~5 cycles via `fork_b`, while the mask traverses `motion_detect → morph → ccl` for `3·H_ACTIVE + ~14` cycles. The mask cannot overtake the video on the way to the overlay — this is *why* the bbox lands one frame late by construction (§5.7).

**V-blank budget.** Blanking must absorb the cascading drains of `axis_gauss3x3` + `axis_morph3x3_open` (each ≥ `H_ACTIVE + 1` cycles, drains sequentially — does not compound) plus the `u_ccl` EOF FSM. Cycle budget detailed in [`axis_ccl-arch.md`](axis_ccl-arch.md) §6.7. TB uses 16 V-blank lines to cover the worst case at 320×240.

**4:1 clock ratio.** `clk_dsp` (100 MHz) is 4× `clk_pix`, so the DSP pipeline can emit up to 4 output pixels per input pixel arriving. After fill, throughput is 1 pixel/cycle — well above the 1-pixel-per-4-cycles VGA drain. Both CDC FIFOs stay near empty; SVAs in §9 catch violations.

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
  │           │  pix_in_to_hflip (axis_if: RGB + tlast + tuser)  clk_dsp domain  │
  │           │  ──────────────────────────────────────────────                  │
  │           ▼                                                                  │
  │    ┌─────────────┐  optional horizontal mirror (hflip_en)                    │
  │    │   u_hflip   │                                                           │
  │    └──────┬──────┘                                                           │
  │           │  hflip_to_fork / fork_s_axis (axis_if, gated tvalid=0 for pt)    │
  │           ▼                                                                  │
  │    ┌─────────────┐  1-to-2 broadcast with per-output acceptance tracking     │
  │    │   u_fork    │                                                           │
  │    └──┬───────┬──┘                                                           │
  │       │       └───────────────────────────────────────────┐                  │
  │  fork_a_to_motion (axis_if)                    fork_b_to_overlay (axis_if)   │
  │       │                                                   │                  │
  │       ▼                                                   │                  │
  │    ┌──────────────────┐    ┌───────────┐                  │                  │
  │    │ u_motion_detect  │    │   u_ram   │  BG model        │                  │
  │    │  rgb2ycrcb       │◄──►│  (port A) │  (Y8, H×V bytes) │                  │
  │    │  [gauss3x3]      │    └───────────┘                  │                  │
  │    │  motion_core     │                                   │                  │
  │    └────────┬─────────┘                                   │                  │
  │             │  motion_to_morph (axis_if: 1-bit mask)      │                  │
  │             ▼                                             │                  │
  │    ┌──────────────────┐                                   │                  │
  │    │ u_morph_open     │  erode → dilate (3×3), or         │                  │
  │    │  (morph_en=1)    │  zero-latency bypass (morph_en=0) │                  │
  │    └────────┬─────────┘                                   │                  │
  │             │  morph_to_ccl_strobed / ccl_s_axis (axis_if: 1-bit mask)       │
  │             ├───────────────────────────────────┐         │                  │
  │             ▼                                   │         │                  │
  │    ┌──────────────────┐                         │         │                  │
  │    │      u_ccl       │  8-conn union-find;     │         │                  │
  │    │                  │  EOF FSM resolves +     │         │                  │
  │    │                  │  swaps N_OUT bboxes     │         │                  │
  │    └────────┬─────────┘                         │         │                  │
  │             │  u_ccl_bboxes (bbox_if)            │         │                  │
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
  │    │   N_OUT-wide rectangle-edge hit test → BBOX_COLOR,         │            │
  │    │   otherwise pass-through of overlay_in                     │            │
  │    └────────────────────┬───────────────────────────────────────┘            │
  │                         │  overlay_to_pix_out (axis_if: RGB + tlast + tuser) │
  │                         │                                                    │
  │    ┌────────────────────┴─────────────────────────────┐                      │
  │    │  ctrl_flow output mux                            │                      │
  │    │  passthrough → pix_in_to_hflip (flat bridge)     │                      │
  │    │  motion      → overlay_to_pix_out                │                      │
  │    │  mask        → msk_rgb (B/W expansion of morph)  │                      │
  │    │  ccl_bbox    → overlay_to_pix_out (grey canvas)  │                      │
  │    └────────────────────┬─────────────────────────────┘                      │
  │                         │  proc (axis_if: RGB + tlast + tuser)               │
  │                         │  → u_gamma_cor (sRGB encode; CFG.gamma_en bypass)  │
  │                         ▼                                                    │
  │                 ┌──────────────┐  2x upscaler when CFG.scaler_en=1;         │
  │                 │  u_scale2x   │  flat bridge when CFG.scaler_en=0            │
  │                 └──────┬───────┘                                             │
  │                        │  scale2x_to_pix_out (axis_if: RGB + tlast + tuser)  │
  │                        ▼                                                     │
  │                 ┌──────────────┐  CDC: clk_dsp → clk_pix_out                 │
  │                 │  u_fifo_out  │  (DEPTH = 1024 when CFG.scaler_en=1,        │
  │                 │              │   else 256)                                  │
  │                 └──────┬───────┘                                             │
  │                        │  pix_out_axis (flat bridge: RGB + tlast + tuser)    │
  │                        │                            clk_pix_out domain       │
  │                        ▼                                                     │
  │                 ┌──────────────┐  held in reset until first tuser=1          │
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
- **Motion detect** (`ctrl_flow_i = 2'b01`): `overlay_to_pix_out` feeds into `u_fifo_out`. Both fork outputs are active; `fork_b_to_overlay` provides RGB to the overlay while `fork_a_to_motion` feeds `u_motion_detect` → `u_morph_open` → `u_ccl` for bbox generation via `u_ccl_bboxes`. This is the default path.
- **Mask display** (`ctrl_flow_i = 2'b10`): `msk_rgb` (cleaned 1-bit mask expanded to 24-bit B/W) feeds into `u_fifo_out`. The overlay path is drained (overlay `tready = 1`). Mask `tready` carries output FIFO backpressure; `u_ccl` still receives the cleaned mask via the broadcast handshake but its bboxes are not used.
- **CCL bbox** (`ctrl_flow_i = 2'b11`): `overlay_to_pix_out` feeds into `u_fifo_out`, but the overlay's video input (`overlay_in`) is `mask_grey_rgb` (a combinational grey canvas derived from the cleaned mask) instead of `fork_b_to_overlay`. `fork_b_to_overlay.tready` is tied to 1 so the unused RGB pipe drains. `u_ccl` runs normally and its `u_ccl_bboxes` are drawn on top of the grey canvas — a direct visual readout of the CCL stage.

### 6.1 Plumbing and glue

Per-block roles for the processing stages (`u_motion_detect`, `u_morph_open`, `u_ccl`, `u_overlay_bbox`, `u_vga`) are covered in §5. The remaining top-level plumbing:

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
| `clk_dsp` | 100 MHz | `u_fifo_in` read side, `u_fork`, `u_motion_detect`, `u_ram`, `u_morph_open`, `u_ccl`, `u_overlay_bbox`, `u_gamma_cor`, `u_scale2x` (when `CFG.scaler_en=1`), `u_fifo_out` write side |

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
- **1-frame overlay latency**: the bbox drawn on frame N is derived from the motion observed during frame N−1. This is a deliberate architectural choice — see §5.7. Same-frame overlay would cost ~225 KB of frame-buffer RAM for no human-visible improvement at 60 fps.
- **Same-frame bbox**: bbox coordinates are latched at EOF; mid-frame updates are not possible with the current design.
- **Thin-feature deletion under morph**: `u_morph_open` erases foreground features narrower than 3 pixels (single-pixel lines, far-field point targets). Profile `no_morph` (`CFG.morph_en=0`) is the escape hatch; see [axis_morph3x3_open-arch.md](axis_morph3x3_open-arch.md) §4.4.
- **No AXI-Lite control**: all algorithm parameters (motion threshold, bbox colour, EMA rates, stage enables) are compile-time fields of `CFG`. Runtime override requires synthesizing a CSR slave (see §8.1).
- **Port B unused**: `u_ram` port B is tied off. A future host client (debug dump, FPN reference, etc.) may connect here, subject to the host-responsibility rule in [ram-arch.md](ram-arch.md).
- **Pixel-clock stability assumption (CFG.scaler_en=1)**: the design assumes the caller provides `clk_pix_out_i` at exactly 4x `clk_pix_in_i` so long-term input/output rates balance through the output FIFO. Real silicon would need either a genlocked PLL pair or a dedicated frame buffer at the output to handle independent source/display clocks; today's testbench drives the two clocks from a single integer divider, sidestepping the issue. See [axis_scale2x-arch.md](axis_scale2x-arch.md) for the rate-budget detail.

---

## 11. Resources

**Bold** entries exceed 1 kB. CCL defaults: `N_LABELS_INT=64`. Input FIFO depth `IN_FIFO_DEPTH=128`, output FIFO depth `OUT_FIFO_DEPTH=256` (or 1024 when `CFG.scaler_en=1`); 26 bits wide (24 b `tdata` + `tlast` + `tuser`).

| Memory | Module | 320×240 | 640×480 | 1920×1080 | Technology |
|--------|--------|---------|---------|-----------|------------|
| EMA background model | `u_ram` | **75 kB** | **300 kB** | **~1.98 MB** | Behavioral TDPRAM → BRAM on FPGA |
| Gaussian line buffers (×2) | `u_motion_detect` (`gauss_en=1`) | 640 B | **1.25 kB** | **3.75 kB** | Distributed LUT-RAM |
| Morph opening line buffers (×4) | `u_morph_open` (`morph_en=1`) | 160 B | 320 B | 960 B | Distributed LUT-RAM |
| CCL label line buffer | `u_ccl` | 240 B | 480 B | **1.41 kB** | Distributed LUT-RAM |
| CCL accumulator bank (×5 arrays) | `u_ccl` | 408 B | 456 B | 520 B | Distributed LUT-RAM |
| CCL equivalence table | `u_ccl` | 48 B | 48 B | 48 B | Distributed LUT-RAM |
| CDC FIFOs (×2) | `u_fifo_in`, `u_fifo_out` | ~416 B / ~832 B | ~416 B / ~832 B | ~416 B / ~832 B | axis_async_fifo, `IN_FIFO_DEPTH=128` / `OUT_FIFO_DEPTH=256` |

Sizing formulas (W = H\_ACTIVE, H = V\_ACTIVE):

| Memory | Formula |
|--------|---------|
| EMA background model | W × H bytes |
| Gaussian line buffers | 2 × W bytes |
| Morph opening line buffers | 4 × W bits (2 per sub-module × 2 sub-modules) |
| CCL label line buffer | W × ⌈log₂(N\_LABELS\_INT)⌉ bits |
| CCL accumulator bank | N\_LABELS\_INT × (2⌈log₂W⌉ + 2⌈log₂H⌉ + ⌈log₂(WH+1)⌉) bits |
| CCL equivalence table | N\_LABELS\_INT × ⌈log₂(N\_LABELS\_INT)⌉ bits |

See [ram-arch.md](ram-arch.md) for port ownership semantics and the behavioral-to-BRAM substitution note.

---

## 12. References

- [AMBA AXI4-Stream Protocol Specification — Arm](https://developer.arm.com/documentation/ihi0051/latest/)
- [alexforencich/verilog-axis — GitHub (MIT)](https://github.com/alexforencich/verilog-axis)
- [VGA signal timing — TinyVGA](http://www.tinyvga.com/vga-timing)
