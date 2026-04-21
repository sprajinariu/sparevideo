# sparevideo Top-Level Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
- [4. Concept Description](#4-concept-description)
  - [4.1 Dual-path pipeline: what is the "mask"?](#41-dual-path-pipeline-what-is-the-mask)
  - [4.2 Mask/video latency independence](#42-maskvideo-latency-independence)
  - [4.3 Design rationale: 1-frame bbox latency](#43-design-rationale-1-frame-bbox-latency)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Submodule roles](#51-submodule-roles)
  - [5.2 AXI4-Stream protocol](#52-axi4-stream-protocol)
- [6. Clock Domains](#6-clock-domains)
- [7. Region Descriptor Model](#7-region-descriptor-model)
  - [7.1 Future CSR register file (deferred)](#71-future-csr-register-file-deferred)
- [8. Assertions (SVA, Verilator only)](#8-assertions-sva-verilator-only)
- [9. Known Limitations](#9-known-limitations)
- [10. Resources](#10-resources)
- [11. References](#11-references)

---

## 1. Purpose and Scope

`sparevideo_top` is the top-level video processing pipeline. It accepts an AXI4-Stream RGB888 video input on a 25 MHz pixel clock (`clk_pix`), crosses the stream into a 100 MHz DSP clock domain, runs a **control-flow-selectable** processing pipeline, crosses back to the pixel clock, and drives a VGA controller to produce analogue RGB + hsync/vsync output.

A top-level `ctrl_flow_i` sideband signal (2-bit) selects the active processing path:
- **Passthrough** (`ctrl_flow_i = 2'b00`): input pixels pass directly to the output FIFO with no processing.
- **Motion detect** (`ctrl_flow_i = 2'b01`, default): motion-detection → streaming CCL → up-to-`N_OUT` per-component bounding-box overlay pipeline.
- **Mask display** (`ctrl_flow_i = 2'b10`): raw 1-bit motion mask expanded to black/white RGB. Uses the same motion detection front-end but bypasses CCL/overlay, outputting the mask directly for debugging.
- **CCL bbox** (`ctrl_flow_i = 2'b11`): debug mode — the 1-bit motion mask is combinationally expanded to a grey canvas (mask=1 → light grey, mask=0 → dark grey) and routed into the overlay. This visualizes the CCL bbox output directly on top of the mask, decoupling CCL verification from the overlay's interaction with live RGB.

When the motion pipeline is bypassed (passthrough), the fork input `tvalid` is gated to 0 and the overlay output `tready` is tied to 1 to prevent stalling. Motion, mask, and ccl_bbox modes all activate the motion detect + CCL pipeline.

The module does **not** include: camera input (MIPI CSI-2), AXI-Lite register access, multi-clock `clk_pix` sources, or any processing beyond luma-difference motion detection, 8-connected connected-component labeling, and N-way bounding-box overlay.

---

## 2. Module Hierarchy

```
sparevideo_top (top level)
├── axis_async_fifo    (u_fifo_in)       — CDC clk_pix → clk_dsp, vendored verilog-axis
├── ram                (u_ram)           — dual-port byte RAM, Y8 prev-frame buffer
├── axis_fork          (u_fork)          — 1-to-2 broadcast: fork_a → motion detect, fork_b → overlay
├── axis_motion_detect (u_motion_detect) — mask-only producer
│   └── rgb2ycrcb      (u_rgb2ycrcb)    — RGB888 → Y8 (1-cycle pipeline)
├── axis_ccl           (u_ccl)           — mask → N_OUT × {min_x,max_x,min_y,max_y,valid}
├── axis_overlay_bbox  (u_overlay_bbox)  — draw N_OUT-wide bbox rectangles on RGB video
├── axis_async_fifo    (u_fifo_out)      — CDC clk_dsp → clk_pix, vendored verilog-axis
└── vga_controller     (u_vga)          — streaming pixel → VGA timing + RGB output
```

---

## 3. Interface Specification

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| **Clocks and resets** | | | |
| `clk_pix_i` | input | 1 | 25 MHz pixel clock — input path and VGA output domain |
| `clk_dsp_i` | input | 1 | 100 MHz DSP clock — motion pipeline domain |
| `rst_pix_n_i` | input | 1 | Active-low synchronous reset, `clk_pix` domain |
| `rst_dsp_n_i` | input | 1 | Active-low synchronous reset, `clk_dsp` domain |
| **AXI4-Stream video input (clk_pix domain)** | | | |
| `s_axis_tdata_i` | input | 24 | AXI4-Stream pixel payload `{R[7:0], G[7:0], B[7:0]}` |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream producer valid |
| `s_axis_tready_o` | output | 1 | AXI4-Stream sink ready (back-pressures producer) |
| `s_axis_tlast_i` | input | 1 | End-of-line marker (last pixel of each row) |
| `s_axis_tuser_i` | input | 1 | Start-of-frame marker (first pixel of frame) |
| **Control flow** | | | |
| `ctrl_flow_i` | input | 2 | Control flow select: 2'b00 = passthrough, 2'b01 = motion, 2'b10 = mask, 2'b11 = ccl_bbox |
| **VGA output (clk_pix domain)** | | | |
| `vga_hsync_o` | output | 1 | Horizontal sync, active-low |
| `vga_vsync_o` | output | 1 | Vertical sync, active-low |
| `vga_r_o` | output | 8 | Red channel (0 during blanking) |
| `vga_g_o` | output | 8 | Green channel (0 during blanking) |
| `vga_b_o` | output | 8 | Blue channel (0 during blanking) |

### 3.1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | pkg | Active pixels per line |
| `H_FRONT_PORCH` | pkg | Horizontal front porch |
| `H_SYNC_PULSE` | pkg | Horizontal sync pulse width |
| `H_BACK_PORCH` | pkg | Horizontal back porch |
| `V_ACTIVE` | pkg | Active lines per frame |
| `V_FRONT_PORCH` | pkg | Vertical front porch |
| `V_SYNC_PULSE` | pkg | Vertical sync pulse height |
| `V_BACK_PORCH` | pkg | Vertical back porch |
| `MOTION_THRESH` | 16 | Luma-difference threshold for motion (≈6.25% intensity) |
| `ALPHA_SHIFT` | 3 | EMA background adaptation rate: alpha = 1/(1 << ALPHA_SHIFT). Propagated to `u_motion_detect`. Default 3 → alpha=1/8 |
| `GAUSS_EN` | 1 | Enable the 3×3 Gaussian pre-filter inside `u_motion_detect` (0 disables; handy for comparing with/without smoothing) |
| `CCL_N_LABELS_INT` | pkg (64) | Internal label-table size in `u_ccl`. Cap on the number of distinct provisional labels tracked in one frame before a label-exhaust fallback (merge into label 0) |
| `CCL_N_OUT` | pkg (8) | Number of per-component bounding-box output slots exposed from `u_ccl` to `u_overlay_bbox` |
| `CCL_MIN_COMPONENT_PIXELS` | pkg (16) | Minimum component area (in pixels) to promote into the top-N bbox output — filters sensor-noise specks |
| `CCL_MAX_CHAIN_DEPTH` | pkg (8) | Safety cap on parent-pointer chain walks during the EOF fold phase |
| `CCL_PRIME_FRAMES` | pkg (2) | Number of frames after reset during which `u_ccl` suppresses all bbox outputs, giving the EMA background model time to converge |

`ctrl_flow_i` is a quasi-static sideband signal (set before simulation, not changed mid-frame). It is driven by the testbench via the `+CTRL_FLOW=passthrough|motion|mask|ccl_bbox` plusarg. All defaults reference `sparevideo_pkg`.

---

## 4. Concept Description

The sparevideo pipeline implements real-time video processing using a **dual-clock-domain** architecture. The pixel clock (25 MHz) matches the VGA output timing standard (640x480 @ 60 Hz), while the DSP clock (100 MHz) provides 4× computation headroom for the processing pipeline. This clock ratio ensures that the processing pipeline can always sustain 1 pixel per `clk_pix` cycle without backpressure, even though the pipeline operates at `clk_dsp` granularity.

The key architectural concept is **control-flow-selectable processing**: a single pipeline front-end (CDC → motion detection → streaming CCL) is shared across multiple output modes, selected at runtime by a 2-bit sideband signal. This avoids duplicating hardware for each mode while allowing the user to switch between:
- **Passthrough**: raw video with no processing — for baseline comparison.
- **Motion overlay**: the full motion detection → CCL → multi-bbox overlay pipeline — the primary use case.
- **Mask display**: the raw binary motion mask expanded to black/white — for algorithm tuning and debugging.
- **CCL bbox (debug)**: the mask rendered as a grey canvas with the CCL bboxes drawn on top — for verifying CCL output independently of the RGB pass-through path.

Clock domain crossing (CDC) is handled by asynchronous FIFOs at the pipeline boundaries (`u_fifo_in` at entry, `u_fifo_out` at exit). This decouples the input pixel rate from the DSP processing rate and the VGA output rate, with the FIFOs absorbing burst mismatches during blanking intervals. The 4:1 clock ratio means the DSP domain processes pixels faster than they arrive, so the input FIFO drains quickly and the output FIFO stays well below capacity during normal operation.

The processing pipeline itself (motion detection → streaming CCL → N-way overlay) is documented in the individual module architecture documents. At the top level, the concern is how these modules are interconnected, how control flow selects between them, and how CDC and timing constraints are satisfied.

### 4.1 Dual-path pipeline: what is the "mask"?

In motion/mask modes, the pipeline processes two parallel streams forked from the same input video. A top-level `axis_fork` (`u_fork`) broadcasts the DSP-domain input to two consumers:

1. **Video path (RGB, 24-bit per pixel, `fork_b`):** The original RGB pixels feed directly from the fork to `u_overlay_bbox`, bypassing `u_motion_detect` entirely. They are never modified by the motion-detection logic. The fork ensures the overlay receives the same pixels with no additional latency.
2. **Mask path (1-bit per pixel, `fork_a`):** `u_motion_detect` receives the second fork output, converts each pixel to Y8, compares against the per-pixel background model, and emits a single bit: **"did this pixel change compared to the background?"** A `1` means yes (motion detected at this pixel), a `0` means no (this pixel looks the same as the background model).

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

- **`u_ccl`** scans the mask in raster order, assigns a label to each motion pixel via 8-connected single-pass union-find, accumulates per-label `{min_x, max_x, min_y, max_y, count}` on the fly, and — during the vertical blanking interval after EOF — resolves the equivalence table, discards components below `CCL_MIN_COMPONENT_PIXELS`, and commits the top `CCL_N_OUT` bounding boxes into a front-buffer register bank. The output is `N_OUT` packed sideband arrays of `{min_x, max_x, min_y, max_y}` plus an `N_OUT`-wide `valid` bit vector, held stable for the entire next frame.
- **`u_overlay_bbox`** takes those `N_OUT` bbox slots and, for each pixel streaming past, combinationally ORs an `N_OUT`-wide rectangle-edge hit test: if any valid slot's rectangle edge hits `(col, row)`, the pixel is replaced with `BBOX_COLOR` (bright green); otherwise it passes through unchanged.

So the full pipeline's job is: **video in → detect which pixels changed → label connected motion blobs → for each blob, compute its bounding box → draw up to `N_OUT` rectangles on the video → video out**. The mask is the intermediate "which pixels changed" answer that connects the detection step to the labeling step; the `N_OUT` bboxes are the "where are the distinct moving objects" answer that connects labeling to the overlay.

In mask mode (`ctrl_flow_i = 2'b10`) the 1-bit mask is instead expanded to 24-bit black/white and fed directly to the output FIFO for debug visualization — bypassing both `u_ccl` and `u_overlay_bbox`.

In ccl_bbox mode (`ctrl_flow_i = 2'b11`) the mask is combinationally expanded to a 24-bit grey canvas (mask=1 → `0x808080`, mask=0 → `0x202020`) and routed into `u_overlay_bbox` in place of the RGB video; `u_ccl` still produces the bbox sideband normally, so the output is the mask-as-grey with the CCL bboxes drawn on top. This is the most direct visual diagnostic for the CCL block — if a drawn rectangle does not enclose a grey blob, either CCL or the mask is wrong, and each can be inspected in isolation.

### 4.2 Mask/video latency independence

The mask and video paths are consumed by **different modules that do not synchronize per-pixel** with each other, so adding stages to the mask path does not require compensating delay on the video path. Three invariants make this work:

1. **`u_ccl` is a pure sink on its mask input** — it accepts one mask bit per cycle whenever the upstream strobes valid, and it produces **no mask output stream** at all. It never stalls the mask stream once the upstream broadcast handshake is complete, and it never touches the video stream. All accumulation (per-label min/max/count, union-find) is internal.
2. **Bboxes are committed at end-of-frame, used during the *next* frame.** After EOF, `u_ccl` runs a four-phase resolution FSM inside the vertical blanking interval (path-compress → fold → top-N select → reset) and then performs a `PHASE_SWAP` that atomically promotes the new `N_OUT` bbox slots into the front register bank. These outputs are stable for the entire duration of the next frame. `u_overlay_bbox` reads them as a static sideband while processing that next frame's video.
3. **Adding stages to the mask path (Gaussian, future morphology, stricter CCL variants) just delays when the EOF resolution happens within the vblank.** As long as the full resolution FSM completes before the next frame's first pixel reaches the overlay, the bbox is ready in time. The testbench's V_BLANK (2+2+16 lines) is sized to cover the worst-case cycle budget at 320×240.

As a result, any new mask-path stage between `u_motion_detect` and `u_ccl` can be inserted without touching the video path.

### 4.3 Design rationale: 1-frame bbox latency

The bbox drawn on frame N is computed from motion observed during frame N−1. This is a deliberate architectural choice, not an accident of the implementation. A same-frame overlay is technically possible but strictly worse at this resolution:

The pipeline is streaming (raster order). The bottommost motion pixel can lie on the last row, so the bbox is not fully known until EOF. But the overlay needs the bbox *while outputting pixels at the top of the frame* — which have already been streamed out long before EOF. To draw a rectangle on the same frame, the video pixels would have to be **held back** until the bbox is known, which requires a full RGB frame buffer (320×240×24 bits ≈ 225 KB) and a true dual-port RAM — roughly 3× the current total RAM budget.

| | Same-frame bbox | 1-frame delayed bbox (current) |
|---|---|---|
| RAM cost | +225 KB (frame buffer) | 0 |
| Visual latency | 16.7 ms (frame buffer delay) | 16.7 ms (bbox from prev frame) |
| Perceived delay | Identical to human eye at 60 fps | Identical to human eye at 60 fps |
| Pipeline complexity | Significantly higher | Simple streaming |

At 60 fps, one frame is 16.7 ms — imperceptible. The user-visible result is indistinguishable between the two designs. Same-frame overlay would only matter at very low frame rates (e.g., 1 fps security camera) where a 1-second bbox lag would be noticeable. The current 1-frame delay is the standard approach in streaming video pipelines and is the right trade-off here.

---

## 5. Internal Architecture

```
                         sparevideo_top
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │                                                                              │
  │  s_axis (RGB888 + tlast + tuser)          clk_pix domain                     │
  │  ─────────────────────────────────────────────────────────                   │
  │           │                                                                  │
  │           ▼                                                                  │
  │    ┌─────────────┐  CDC: clk_pix → clk_dsp                                   │
  │    │  u_fifo_in  │                                                           │
  │    └──────┬──────┘                                                           │
  │           │  dsp_in (RGB + tlast + tuser)   clk_dsp domain                   │
  │           │  ──────────────────────────────────────────────                  │
  │           ▼                                                                  │
  │    ┌─────────────┐  1-to-2 broadcast (gated tvalid=0 for passthrough)        │
  │    │   u_fork    │                                                           │
  │    └──┬───────┬──┘                                                           │
  │       │       └───────────────────────────────────────────┐                  │
  │  fork_a (Mask pipe)                                 fork_b (RGB pipe)        │
  │       │                                                   │                  │
  │       ▼                                                   │                  │
  │    ┌──────────────────┐    ┌───────────┐                  │                  │
  │    │ u_motion_detect  │    │   u_ram   │  BG model        │                  │
  │    │  rgb2ycrcb       │◄──►│  (port A) │  (Y8, H×V bytes) │                  │
  │    │  [gauss3x3]      │    └───────────┘                  │                  │
  │    │  motion_core     │                                   │                  │
  │    └────────┬─────────┘                                   │                  │
  │             │  msk (1-bit + tlast + tuser)                │                  │
  │             ├───────────────────────────────────┐         │                  │
  │             ▼                                   │         │                  │
  │    ┌──────────────────┐                         │         │                  │
  │    │      u_ccl       │  8-conn union-find;     │         │                  │
  │    │                  │  EOF FSM resolves +     │         │                  │
  │    │                  │  swaps N_OUT bboxes     │         │                  │
  │    └────────┬─────────┘                         │         │                  │
  │             │  N_OUT × {min_x,max_x,min_y,max_y,valid}    │                  │
  │             │                                   │         │                  │
  │             │   ┌───────────────────────────────┘         │                  │
  │             │   │  (ccl_bbox mode) mask → grey canvas mux │                  │
  │             │   ▼                                         ▼                  │
  │             │  ┌──────────────────────────────────────────────────┐          │
  │             │  │  ovl_in mux:                                     │          │
  │             │  │    motion              → fork_b RGB              │          │
  │             │  │    ccl_bbox            → mask_grey_rgb           │          │
  │             │  └────────────────────┬─────────────────────────────┘          │
  │             ▼                       ▼                                        │
  │    ┌────────────────────────────────────────────────────────────┐            │
  │    │                   u_overlay_bbox                           │            │
  │    │   N_OUT-wide rectangle-edge hit test → BBOX_COLOR,         │            │
  │    │   otherwise pass-through of ovl_in                         │            │
  │    └────────────────────┬───────────────────────────────────────┘            │
  │                         │  ovl (RGB + tlast + tuser)                         │
  │                         │                                                    │
  │    ┌────────────────────┴─────────────────────────────┐                      │
  │    │  ctrl_flow output mux                            │                      │
  │    │  passthrough → dsp_in                            │                      │
  │    │  motion      → ovl                               │                      │
  │    │  mask        → msk_rgb (B/W expansion of msk)    │                      │
  │    │  ccl_bbox    → ovl (grey canvas + CCL bboxes)    │                      │
  │    └────────────────────┬─────────────────────────────┘                      │
  │                         │  proc (RGB + tlast + tuser)                        │
  │                         ▼                                                    │
  │                 ┌──────────────┐  CDC: clk_dsp → clk_pix                     │
  │                 │  u_fifo_out  │                                             │
  │                 └──────┬───────┘                                             │
  │                        │  pix_out (RGB + tlast + tuser)    clk_pix domain    │
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
- **Passthrough** (`ctrl_flow_i = 2'b00`): `dsp_in` feeds directly into `u_fifo_out`. `u_fork` input `tvalid` is gated to 0; overlay output `tready` is tied to 1.
- **Motion detect** (`ctrl_flow_i = 2'b01`): `ovl` (overlay output) feeds into `u_fifo_out`. Both fork outputs are active; `u_fork` provides RGB to the overlay (via `ovl_in mux` = `fork_b`) while also feeding `u_motion_detect` → `u_ccl` for bbox generation. This is the default path.
- **Mask display** (`ctrl_flow_i = 2'b10`): `msk_rgb` (1-bit mask expanded to 24-bit B/W) feeds into `u_fifo_out`. The overlay path is drained (`ovl_tready = 1`). Mask `tready` carries output FIFO backpressure; `u_ccl` still receives the mask via the broadcast handshake but its bboxes are not used.
- **CCL bbox** (`ctrl_flow_i = 2'b11`): `ovl` (overlay output) feeds into `u_fifo_out`, but the overlay's video input is `mask_grey_rgb` (a combinational grey canvas derived from the mask) instead of `fork_b`. `fork_b_tready` is tied to 1 so the unused RGB pipe drains. `u_ccl` runs normally and its bboxes are drawn on top of the grey canvas — a direct visual readout of the CCL stage.

### 5.1 Submodule roles

1. **u_fifo_in**: decouples the `clk_pix`-domain source from the DSP pipeline. Depth 32 entries. Overflow detected by SVA.
2. **u_fork**: zero-latency 1-to-2 broadcast fork. Splits the DSP-domain stream so that `fork_b` (RGB) feeds the overlay directly while `fork_a` (RGB) feeds the motion detect mask pipeline. Per-output acceptance tracking prevents duplicate transfers on asymmetric consumer stalls. Instantiated only in the motion pipeline path; the fork input `tvalid` is gated to 0 in passthrough mode.
3. **u_motion_detect**: converts each pixel to Y8 (`u_rgb2ycrcb`), reads the per-pixel background model from `u_ram` port A, computes `|Y_cur − bg|`, and emits a **1-bit motion mask**. The mask condition is `diff > THRESH` (polarity-agnostic — flags both arrival and departure pixels, works for bright-on-dark, dark-on-bright, and colour scenes). Writes an EMA-updated background value back to RAM on acceptance: `bg_new = bg + ((Y_cur - bg) >>> ALPHA_SHIFT)`. This temporally smooths the background model, suppressing sensor noise and adapting to gradual lighting changes. See [axis_motion_detect-arch.md](axis_motion_detect-arch.md) §4 for the EMA algorithm details.
4. **u_ram**: dual-port byte RAM (port A for motion detect background model, port B reserved). Zero-initialized so frame 0 reads all-motion (background starts at 0, converges via EMA over subsequent frames).
5. **u_ccl**: single-pass 8-connected streaming connected-component labeler. Walks the mask in raster order, assigns provisional labels with a 2-row neighbour window, maintains a union-find equivalence table (with a single equiv-write per pixel), and accumulates per-label bounding-box and area statistics in a label-indexed bank RAM. After EOF, a four-phase FSM (`PHASE_A` path-compression → `PHASE_B` fold statistics into roots → `PHASE_C` select top-`CCL_N_OUT` by area, filtering below `CCL_MIN_COMPONENT_PIXELS` → `PHASE_D` reset) runs inside the vertical blanking interval, followed by `PHASE_SWAP` which atomically promotes the resolved bbox set into a front register bank. The first `CCL_PRIME_FRAMES` frames after reset are suppressed (all `valid` bits forced 0) so the EMA background model has time to converge. `msk_tready` is beat-strobe gated (`msk_tvalid && msk_tready_final`) inside the multi-consumer broadcast. See [axis_ccl-arch.md](axis_ccl-arch.md).
6. **u_overlay_bbox**: receives RGB pixels on its AXI4-Stream input (`ovl_in` = `fork_b` in motion mode, or `mask_grey_rgb` in ccl_bbox mode) and an `N_OUT`-wide packed-array bbox sideband from `u_ccl`. For each pixel, combinationally ORs an `N_OUT`-wide rectangle-edge hit test across all valid slots; on a hit, the pixel is replaced with `BBOX_COLOR` (bright green), otherwise pass-through. Zero added latency on the data path.
7. **u_fifo_out**: crosses the overlaid RGB stream back to `clk_pix`. Depth 32 entries.
8. **vga_rst_n gating**: the VGA controller is held in reset until the first `tuser=1` pixel exits `u_fifo_out`. This aligns the VGA scan to a frame boundary regardless of FIFO fill time.
9. **u_vga**: drives horizontal/vertical counters, asserts `pixel_ready_o` during the active region, gates RGB output to 0 during blanking.

### 5.2 AXI4-Stream protocol

- `tdata[23:0]` = `{R[7:0], G[7:0], B[7:0]}`, RGB888.
- `tuser[0]` = SOF — asserted only on pixel `(0, 0)` of each frame.
- `tlast` = EOL — asserted on the last pixel of each row.
- A transfer occurs when `tvalid && tready` are both asserted.
- No blanking pixels in the stream — exactly `H_ACTIVE × V_ACTIVE` pixels per frame.
- The motion-mask sideband stream uses the same framing with `tdata[0]` as the 1-bit mask value.

---

## 6. Clock Domains

| Domain | Clock | Modules |
|--------|-------|---------|
| `clk_pix` | 25 MHz | source driver, `u_fifo_in` write side, `u_fifo_out` read side, `u_vga`, VGA reset gating |
| `clk_dsp` | 100 MHz | `u_fifo_in` read side, `u_fork`, `u_motion_detect`, `u_ram`, `u_ccl`, `u_overlay_bbox`, `u_fifo_out` write side |

CDC crossings use vendored `axis_async_fifo` from [alexforencich/verilog-axis](https://github.com/alexforencich/verilog-axis) (MIT). Active-high resets are derived at the top level: `rst_pix = ~rst_pix_n_i`, `rst_dsp = ~rst_dsp_n_i`.

---

## 7. Region Descriptor Model

The shared RAM is partitioned into named regions with `{BASE, SIZE}` descriptors. Descriptors are compile-time localparams in `sparevideo_top.sv`, structured for future migration to SW-writable CSRs.

```
Region       Owner                Base              Size
─────────    ─────────────        ────              ────
BG_MODEL     axis_motion_detect   RGN_Y_PREV_BASE=0 RGN_Y_PREV_SIZE = H_ACTIVE × V_ACTIVE
(reserved)   (port B, future)     —                 —
```

The BG_MODEL region stores the per-pixel EMA background estimate (8-bit luma). Each pixel is updated on every frame via the EMA formula in `axis_motion_detect`. Zero-initialized, so the first few frames see full-frame motion until the background converges.

A compile-time guard checks that `BASE + SIZE ≤ RAM_DEPTH`. Each client module receives its `RGN_BASE` and `RGN_SIZE` as parameters; it adds `RGN_BASE` to its internal counter to form the physical address, so the RAM module itself has no knowledge of partitions.

### 7.1 Future CSR register file (deferred)

When runtime configurability is needed, the descriptor table and control knobs (`MOTION_THRESH`, `BBOX_COLOR`) migrate to a `sparevideo_csr` AXI-Lite slave on a new top-level port. Client module parameters become input ports of the same width; CSR values are latched on SOF to prevent mid-frame glitches.

---

## 8. Assertions (SVA, Verilator only)

| Assertion | Clock | Description |
|-----------|-------|-------------|
| `assert_no_input_backpressure` | `clk_pix` | Input must not be back-pressured — all pipeline stages must sustain 1 pixel/clk |
| `assert_no_output_underrun` | `clk_pix` | Once VGA is started, `pix_out_tvalid` must be high whenever `pixel_ready_o` is asserted |
| `assert_fifo_in_not_full` | `clk_pix` | Input FIFO depth must stay below `IN_FIFO_DEPTH` |
| `assert_fifo_out_not_full` | `clk_dsp` | Output FIFO depth must stay below `OUT_FIFO_DEPTH` |
| `assert_fifo_in_no_overflow` | `clk_pix` | Sticky overflow flag from input FIFO must not be set |
| `assert_fifo_out_no_overflow` | `clk_dsp` | Sticky overflow flag from output FIFO must not be set |

`sva_drain_mode` (default 0) disables the underrun assertion after the testbench stops feeding pixels.

---

## 9. Known Limitations

- **Simulation-only RAM**: `ram.sv` is a behavioral model. FPGA synthesis requires a vendor BRAM primitive (e.g. Xilinx `xpm_memory_tdpram`).
- **Frame-0 full-frame border**: the zero-initialized RAM means every pixel on frame 0 reads as motion. The bounding box would span the full frame and the overlay would draw a border around the image edge. This is a known cosmetic artifact. `axis_ccl` suppresses bboxes for the first 2 frames (`PRIME_FRAMES`), matching the Python motion model, so no rectangle is drawn during EMA convergence.
- **1-frame overlay latency**: the bbox drawn on frame N is derived from the motion observed during frame N−1. This is a deliberate architectural choice — see §4.3 "Design rationale: 1-frame bbox latency". Same-frame overlay would cost ~225 KB of frame-buffer RAM for no human-visible improvement at 60 fps.
- **Same-frame bbox**: bbox coordinates are latched at EOF; mid-frame updates are not possible with the current design.
- **No AXI-Lite control**: `MOTION_THRESH` and `BBOX_COLOR` are compile-time parameters. Runtime override requires a simulation plusarg and recompile for RTL.
- **Port B unused**: `u_ram` port B is tied off. A future host client (debug dump, FPN reference, etc.) may connect here, subject to the host-responsibility rule in [ram-arch.md](ram-arch.md).
- **Single pixel clock**: both the input source and VGA output share `clk_pix`. Independent source/display clocks would need a third clock domain.

---

## 10. Resources

At the default 320×240 resolution, one on-chip memory exceeds 1 kB:

| Memory | Module | Size | Technology |
|--------|--------|------|------------|
| EMA background model | `u_ram` | **75 kB** (320×240 × 8 b) | Behavioral TDPRAM → BRAM on FPGA |

All other memories are below 1 kB:

| Memory | Module | Size | Technology |
|--------|--------|------|------------|
| Gaussian line buffers (×2) | `u_motion_detect` (`GAUSS_EN=1`) | 640 B (2 × 320 × 8 b) | Distributed LUT-RAM |
| CCL label line buffer | `u_ccl` | 240 B (320 × 6 b) | Distributed LUT-RAM |
| CCL accumulator bank (×5 arrays) | `u_ccl` | 408 B (64 × 51 b) | Distributed LUT-RAM |
| CCL equivalence table | `u_ccl` | 48 B (64 × 6 b) | Distributed LUT-RAM |
| CDC FIFO (×2) | `u_fifo_in`, `u_fifo_out` | ~104 B each (32 × 26 b) | Vendored axis_async_fifo, depth 32 |

CCL sizes use defaults: `N_LABELS_INT=64`, `H_ACTIVE=320`, `V_ACTIVE=240`. Per-label accumulator width is 9+9+8+8+17 = 51 bits (`min_x`, `max_x`, `min_y`, `max_y`, `count`). FIFO entry width is 26 bits (24 b `tdata` + `tlast` + `tuser`).

### `u_ram` — EMA background model (75 kB)

`u_ram` is a dual-port byte RAM parameterized to `DEPTH = H_ACTIVE × V_ACTIVE` (76,800 bytes at 320×240). It is the dominant on-chip memory in the pipeline and the only component that would map to BRAM on an FPGA.

Port A is exclusively owned by `axis_motion_detect` for per-pixel EMA background storage (one read + one conditional write per accepted pixel). At `clk_dsp = 100 MHz`, port A is occupied ≤ 25% of cycles, bounded by the 25 MHz input pixel rate via the input FIFO. Port B is reserved for future host clients.

FPGA mapping at 320×240: approximately **19 Xilinx 7-series BRAM36K blocks** (each provides 4 KB in 8-bit-wide true-dual-port mode). The behavioral `ram.sv` requires substitution with a vendor true-dual-port BRAM primitive (`xpm_memory_tdpram`) for synthesis. See [ram-arch.md](ram-arch.md) §5.4.

Scaling: RAM cost is linear in frame area. At 640×480 the background model grows to 300 kB (≈75 BRAM36K); at 1920×1080 it reaches ~2 MB (≈512 BRAM36K).

---

## 11. References

- [AMBA AXI4-Stream Protocol Specification — Arm](https://developer.arm.com/documentation/ihi0051/latest/)
- [alexforencich/verilog-axis — GitHub (MIT)](https://github.com/alexforencich/verilog-axis)
- [VGA signal timing — TinyVGA](http://www.tinyvga.com/vga-timing)
