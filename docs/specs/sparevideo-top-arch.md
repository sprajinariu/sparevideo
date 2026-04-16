# sparevideo Top-Level Architecture

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
├── axis_async_fifo  (u_fifo_in)    — CDC clk_pix → clk_dsp, vendored verilog-axis
├── ram              (u_ram)        — dual-port byte RAM, Y8 prev-frame buffer
├── axis_motion_detect (u_motion_detect)
│   └── rgb2ycrcb    (u_rgb2ycrcb)  — RGB888 → Y8 (1-cycle pipeline)
├── axis_bbox_reduce (u_bbox_reduce) — mask → {min_x,max_x,min_y,max_y}
├── axis_overlay_bbox (u_overlay_bbox) — draw bbox rectangle on RGB video
├── axis_async_fifo  (u_fifo_out)   — CDC clk_dsp → clk_pix, vendored verilog-axis
└── vga_controller   (u_vga)        — streaming pixel → VGA timing + RGB output
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

### Parameters

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

---

## 5. Internal Architecture

```
clk_pix domain                   clk_dsp domain                                           clk_pix domain
─────────────────                ──────────────────────────────────────────────────         ─────────────────
                                  ┌─► u_motion_detect ─ vid ─► u_overlay_bbox ─► ovl ─┐
s_axis ──► u_fifo_in ──► dsp_in ─┤                                                    ├─[mux]─► u_fifo_out ──► pix_out ──► u_vga ──► VGA pins
                                  └──────────── (passthrough bypass) ──────────────────┘   ▲
                                         │                                ▲            ctrl_flow_i
                                         └───── msk ──► u_bbox_reduce ───┘ (bbox sideband)
                                         │
                                    u_ram (port A, read/write per pixel)
```

The control-flow mux selects between:
- **Passthrough** (`ctrl_flow_i = 2'b00`): `dsp_in` feeds directly into `u_fifo_out`. Motion pipeline input `tvalid` is gated to 0; output `tready` is tied to 1.
- **Motion detect** (`ctrl_flow_i = 2'b01`): `ovl` (overlay output) feeds into `u_fifo_out`. This is the default path.
- **Mask display** (`ctrl_flow_i = 2'b10`): `msk_rgb` (1-bit mask expanded to 24-bit B/W) feeds into `u_fifo_out`. The overlay path is drained (`ovl_tready = 1`). Mask `tready` carries output FIFO backpressure.

### Submodule roles

1. **u_fifo_in**: decouples the `clk_pix`-domain source from the DSP pipeline. Depth 32 entries. Overflow detected by SVA.
2. **u_motion_detect**: converts each pixel to Y8 (`u_rgb2ycrcb`), reads the per-pixel background model from `u_ram` port A, computes `|Y_cur − bg|`, and emits a 1-bit motion mask plus the original RGB video with matched latency. The mask condition is `diff > THRESH` (polarity-agnostic — flags both arrival and departure pixels, works for bright-on-dark, dark-on-bright, and colour scenes). Writes an EMA-updated background value back to RAM on acceptance: `bg_new = bg + ((Y_cur - bg) >>> ALPHA_SHIFT)`. This temporally smooths the background model, suppressing sensor noise and adapting to gradual lighting changes. See [axis_motion_detect-arch.md](axis_motion_detect-arch.md) §4 for the EMA algorithm details.
3. **u_ram**: dual-port byte RAM (port A for motion detect background model, port B reserved). Zero-initialized so frame 0 reads all-motion (background starts at 0, converges via EMA over subsequent frames).
4. **u_bbox_reduce**: accumulates `{min_x, max_x, min_y, max_y}` over motion pixels; latches at EOF. The first 2 frames after reset are suppressed (`bbox_empty` forced high) to avoid false full-frame bboxes from zeroed RAM. Drives `msk_tready` tied 1 (always ready).
5. **u_overlay_bbox**: for each pixel, checks if `(col, row)` is on the bbox rectangle edge; substitutes `BBOX_COLOR` (bright green) when on the edge and `bbox_empty=0`. Pure pass-through otherwise.
6. **u_fifo_out**: crosses the overlaid RGB stream back to `clk_pix`. Depth 32 entries.
7. **vga_rst_n gating**: the VGA controller is held in reset until the first `tuser=1` pixel exits `u_fifo_out`. This aligns the VGA scan to a frame boundary regardless of FIFO fill time.
8. **u_vga**: drives horizontal/vertical counters, asserts `pixel_ready_o` during the active region, gates RGB output to 0 during blanking.

### AXI4-Stream protocol

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
| `clk_dsp` | 100 MHz | `u_fifo_in` read side, `u_motion_detect`, `u_ram`, `u_bbox_reduce`, `u_overlay_bbox`, `u_fifo_out` write side |

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

### Future CSR register file (deferred)

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
- **Frame-0 full-frame border**: the zero-initialized RAM means every pixel on frame 0 reads as motion. The bounding box spans the full frame and the overlay draws a border around the image edge. This is a known cosmetic artifact. `axis_bbox_reduce` suppresses the bbox for the first 2 frames.
- **1-frame overlay latency**: the bbox drawn on frame N is derived from the motion observed during frame N−1.
- **Same-frame bbox**: bbox coordinates are latched at EOF; mid-frame updates are not possible with the current design.
- **No AXI-Lite control**: `MOTION_THRESH` and `BBOX_COLOR` are compile-time parameters. Runtime override requires a simulation plusarg and recompile for RTL.
- **Port B unused**: `u_ram` port B is tied off. A future host client (debug dump, FPN reference, etc.) may connect here, subject to the host-responsibility rule in [ram-arch.md](ram-arch.md).
- **Single pixel clock**: both the input source and VGA output share `clk_pix`. Independent source/display clocks would need a third clock domain.

---

## 10. References

- [AMBA AXI4-Stream Protocol Specification — Arm](https://developer.arm.com/documentation/ihi0051/latest/)
- [alexforencich/verilog-axis — GitHub (MIT)](https://github.com/alexforencich/verilog-axis)
- [VGA signal timing — TinyVGA](http://www.tinyvga.com/vga-timing)
