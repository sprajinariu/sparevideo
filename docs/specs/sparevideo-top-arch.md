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
- [10. References](#10-references)

---

## 1. Purpose and Scope

`sparevideo_top` is the top-level video processing pipeline. It accepts an AXI4-Stream RGB888 video input on a 25 MHz pixel clock (`clk_pix`), crosses the stream into a 100 MHz DSP clock domain, runs a **control-flow-selectable** processing pipeline, crosses back to the pixel clock, and drives a VGA controller to produce analogue RGB + hsync/vsync output.

A top-level `ctrl_flow_i` sideband signal (2-bit) selects the active processing path:
- **Passthrough** (`ctrl_flow_i = 2'b00`): input pixels pass directly to the output FIFO with no processing.
- **Motion detect** (`ctrl_flow_i = 2'b01`, default): motion-detection and bounding-box overlay pipeline.
- **Mask display** (`ctrl_flow_i = 2'b10`): raw 1-bit motion mask expanded to black/white RGB. Uses the same motion detection front-end but bypasses bbox/overlay, outputting the mask directly for debugging.

When the motion pipeline is bypassed (passthrough), its input `tvalid` is gated to 0 and its output `tready` is tied to 1 to prevent stalling. Both motion and mask modes activate the motion detect pipeline.

The module does **not** include: camera input (MIPI CSI-2), AXI-Lite register access, multi-clock `clk_pix` sources, or any processing beyond luma-difference motion detection and single-object bounding-box overlay.

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
| `ctrl_flow_i` | input | 2 | Control flow select: 2'b00 = passthrough, 2'b01 = motion, 2'b10 = mask |
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

`ctrl_flow_i` is a quasi-static sideband signal (set before simulation, not changed mid-frame). It is driven by the testbench via the `+CTRL_FLOW=passthrough|motion|mask` plusarg. All defaults reference `sparevideo_pkg`.

---

## 4. Concept Description

The sparevideo pipeline implements real-time video processing using a **dual-clock-domain** architecture. The pixel clock (25 MHz) matches the VGA output timing standard (640x480 @ 60 Hz), while the DSP clock (100 MHz) provides 4× computation headroom for the processing pipeline. This clock ratio ensures that the processing pipeline can always sustain 1 pixel per `clk_pix` cycle without backpressure, even though the pipeline operates at `clk_dsp` granularity.

The key architectural concept is **control-flow-selectable processing**: a single pipeline front-end (CDC → motion detection) is shared across multiple output modes, selected at runtime by a 2-bit sideband signal. This avoids duplicating hardware for each mode while allowing the user to switch between:
- **Passthrough**: raw video with no processing — for baseline comparison.
- **Motion overlay**: the full motion detection pipeline with bounding-box overlay — the primary use case.
- **Mask display**: the raw binary motion mask expanded to black/white — for algorithm tuning and debugging.

Clock domain crossing (CDC) is handled by asynchronous FIFOs at the pipeline boundaries (`u_fifo_in` at entry, `u_fifo_out` at exit). This decouples the input pixel rate from the DSP processing rate and the VGA output rate, with the FIFOs absorbing burst mismatches during blanking intervals. The 4:1 clock ratio means the DSP domain processes pixels faster than they arrive, so the input FIFO drains quickly and the output FIFO stays well below capacity during normal operation.

The processing pipeline itself (motion detection → bbox reduction → overlay) is documented in the individual module architecture documents. At the top level, the concern is how these modules are interconnected, how control flow selects between them, and how CDC and timing constraints are satisfied.

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

- **`u_bbox_reduce`** scans the mask and finds the tightest rectangle that encloses all the `1` pixels — the bounding box. It outputs just 4 numbers: `{min_x, max_x, min_y, max_y}`.
- **`u_overlay_bbox`** takes those 4 numbers and draws a green rectangle at those coordinates onto the *video* path. This is what the user actually sees on the VGA output — the original video with a green box around the motion.

So the full pipeline's job is: **video in → detect which pixels changed → find the bounding box of those pixels → draw a rectangle on the video → video out**. The mask is the intermediate "which pixels changed" answer that connects the detection step to the bounding-box step.

In mask mode (`ctrl_flow_i = 2'b10`) the 1-bit mask is instead expanded to 24-bit black/white and fed directly to the output FIFO for debug visualization — bypassing both `u_bbox_reduce` and `u_overlay_bbox`.

### 4.2 Mask/video latency independence

The mask and video paths are consumed by **different modules that do not synchronize per-pixel** with each other, so adding stages to the mask path does not require compensating delay on the video path. Three invariants make this work:

1. **`u_bbox_reduce` is a pure sink** — `tready` is hardwired to 1. It never stalls the mask stream, and it never touches the video stream. It accumulates min/max coordinates internally.
2. **The bbox is latched at end-of-frame, used during the *next* frame.** When EOF arrives, `u_bbox_reduce` snapshots `{min_x, max_x, min_y, max_y}` into its output registers. These are stable for the entire duration of the next frame. `u_overlay_bbox` reads them as a static sideband while processing that next frame's video.
3. **Adding stages to the mask path (Gaussian, future morphology, CCL) just delays when the EOF latch happens within the frame.** Even tens of lines of added latency are well inside the same frame period at 320×240 — the bbox is still ready before the next frame's first pixel reaches the overlay.

As a result, any new mask-path stage between `u_motion_detect` and `u_bbox_reduce` can be inserted without touching the video path.

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
  │             ▼                                             │                  │
  │    ┌──────────────────┐                                   │                  │
  │    │  u_bbox_reduce   │  accumulates min/max; latches     │                  │
  │    │                  │  at EOF                           │                  │
  │    └────────┬─────────┘                                   │                  │
  │             │  bbox {min_x,max_x,min_y,max_y}             │                  │
  │             ▼                                             ▼                  │
  │    ┌────────────────────────────────────────────────────────────┐            │
  │    │                   u_overlay_bbox                           │            │
  │    │   draws green rect on bbox edge; pass-through otherwise    │            │
  │    └────────────────────┬───────────────────────────────────────┘            │
  │                         │  ovl (RGB + tlast + tuser)                         │
  │                         │                                                    │
  │    ┌────────────────────┴─────────────────────────────┐                      │
  │    │  ctrl_flow mux                                   │                      │
  │    │  passthrough → dsp_in                            │                      │
  │    │  motion      → ovl                               │                      │
  │    │  mask        → msk (Output of u_motion_detect)   │                      │
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
- **Motion detect** (`ctrl_flow_i = 2'b01`): `ovl` (overlay output) feeds into `u_fifo_out`. Both fork outputs are active; `u_fork` provides RGB to the overlay while also feeding `u_motion_detect` for mask/bbox. This is the default path.
- **Mask display** (`ctrl_flow_i = 2'b10`): `msk_rgb` (1-bit mask expanded to 24-bit B/W) feeds into `u_fifo_out`. The overlay path is drained (`ovl_tready = 1`). Mask `tready` carries output FIFO backpressure.

### 5.1 Submodule roles

1. **u_fifo_in**: decouples the `clk_pix`-domain source from the DSP pipeline. Depth 32 entries. Overflow detected by SVA.
2. **u_fork**: zero-latency 1-to-2 broadcast fork. Splits the DSP-domain stream so that `fork_b` (RGB) feeds the overlay directly while `fork_a` (RGB) feeds the motion detect mask pipeline. Per-output acceptance tracking prevents duplicate transfers on asymmetric consumer stalls. Instantiated only in the motion pipeline path; the fork input `tvalid` is gated to 0 in passthrough mode.
3. **u_motion_detect**: converts each pixel to Y8 (`u_rgb2ycrcb`), reads the per-pixel background model from `u_ram` port A, computes `|Y_cur − bg|`, and emits a **1-bit motion mask**. The mask condition is `diff > THRESH` (polarity-agnostic — flags both arrival and departure pixels, works for bright-on-dark, dark-on-bright, and colour scenes). Writes an EMA-updated background value back to RAM on acceptance: `bg_new = bg + ((Y_cur - bg) >>> ALPHA_SHIFT)`. This temporally smooths the background model, suppressing sensor noise and adapting to gradual lighting changes. See [axis_motion_detect-arch.md](axis_motion_detect-arch.md) §4 for the EMA algorithm details.
4. **u_ram**: dual-port byte RAM (port A for motion detect background model, port B reserved). Zero-initialized so frame 0 reads all-motion (background starts at 0, converges via EMA over subsequent frames).
5. **u_bbox_reduce**: accumulates `{min_x, max_x, min_y, max_y}` over motion pixels; latches at EOF. The first 2 frames after reset are suppressed (`bbox_empty` forced high) to avoid false full-frame bboxes from zeroed RAM. Drives `msk_tready` tied 1 (always ready).
6. **u_overlay_bbox**: receives RGB pixels from `fork_b` and bbox sideband from `u_bbox_reduce`. For each pixel, checks if `(col, row)` is on the bbox rectangle edge; substitutes `BBOX_COLOR` (bright green) when on the edge and `bbox_empty=0`. Pure pass-through otherwise.
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
| `clk_dsp` | 100 MHz | `u_fifo_in` read side, `u_fork`, `u_motion_detect`, `u_ram`, `u_bbox_reduce`, `u_overlay_bbox`, `u_fifo_out` write side |

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

## 10. References

- [AMBA AXI4-Stream Protocol Specification — Arm](https://developer.arm.com/documentation/ihi0051/latest/)
- [alexforencich/verilog-axis — GitHub (MIT)](https://github.com/alexforencich/verilog-axis)
- [VGA signal timing — TinyVGA](http://www.tinyvga.com/vga-timing)
