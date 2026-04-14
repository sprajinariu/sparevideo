# AXI4-Stream Video Motion Detection + Bounding Box Overlay

Simulation-only RTL feature: replace the 4-stage `axis_register` placeholder chain inside `sparevideo_top` with a real processing pipeline that detects motion against the previous frame, reduces it to a bounding box, and overlays that box on the outgoing video stream.

## Context

`sparevideo_top` currently runs an `clk_pix` → async FIFO → 4-stage `axis_register` chain → async FIFO → `vga_controller` path. The 4-stage chain was installed as a pipeline-latency placeholder while the surrounding AXI4-Stream plumbing was stabilized (see [plans/old/2026-04-07_prio2_move_to_axi4_stream.md](plans/old/2026-04-07_prio2_move_to_axi4_stream.md)). With the plumbing now stable, the placeholder can be replaced by the first block of real video processing: detect motion, draw a rectangle around it.

End-user outcome: running `make run-pipeline SOURCE=<some_video>.mp4` produces an output video where a green rectangle tracks whatever moved between consecutive frames.

## Goals

- End-to-end **AXI4-Stream video pipeline** with correct `tvalid/tready` behavior.
- **Streaming-first design**: sustain 1 pixel/clk through the whole pipeline, with no backpressure back into the input async FIFO (preserves the existing SVA at [hw/top/sparevideo_top.sv#L287-L290](hw/top/sparevideo_top.sv#L287-L290)).
- Use a **generic top-level dual-port RAM module** (`ram`) that holds the Y8 previous-frame buffer today and is sized/partitioned via **region descriptors** (compile-time parameters now, SW-writable registers later). The motion detect pipeline consumes one region; port B is reserved for future sporadic host access (debug, init, other algorithms).
- Compute the motion bounding box in one pass; overlay that box on the outgoing stream.
- Reuse vendored `alexforencich/verilog-axis` IP wherever possible; only write new RTL where no suitable upstream module exists.

## Non-Goals

- Real camera input path (MIPI CSI-2, RGB565/444) — `synthetic:*` sources and MP4/PNG via the Python harness remain the only stimulus.
- AXI-Lite control path. `THRESH` is a Verilog parameter, not a runtime register.
- Same-frame bounding-box overlay — overlay uses the *previously latched* bbox, adding exactly one frame of overlay latency.
- Multi-object tracking, morphological ops (erode/dilate), background-model motion detection.
- **Double-buffered** RGB frame RAM (diverges from [plans/architecture.md](plans/architecture.md) lines 41–43 intentionally — we only need the previous Y frame, not a full RGB double-buffer). The Y8 RAM is dual-port but single-buffered — prev-frame storage only, no A/B swap.
- **Arbitration of a shared single-port RAM** across clients. `ram` exposes two physically independent ports (A for motion detect, B for sporadic host access); each client owns its port end-to-end, so no arbitration logic is needed.
- Independent input vs output pixel clocks — both still share `clk_pix`.
- Pixel-format changes at the DUT boundary. `s_axis_tdata` / `m_axis_tdata` stay 24-bit RGB888.

## Target Architecture

```
              clk_dsp domain (replaces the 4-stage axis_register chain)
 ┌──────────────────────────────────────────────────────────────────────────┐
 │                                                                          │
 │  s_axis ──► axis_motion_detect ──┬── video ──► axis_overlay_bbox ──► m_axis
 │  (RGB888)        ▲     ▼         │                  ▲               (RGB888)
 │                  │     │         └── mask ──► axis_bbox_reduce ─────┘    │
 │               port A (1R1W)                   (bbox regs, EOF latch)     │
 │                  │     │                                                 │
 │          ┌───────┴─────┴────────────────────────┐                        │
 │          │  ram  (true dual-port, behavioral)   │ ◄── port B  (future)   │
 │          │                                      │                        │
 │          │  ┌─ region Y_PREV ─┐ ┌─ (free) ──┐   │                        │
 │          │  │ base 0x00000    │ │ base ...  │   │                        │
 │          │  │ size H*V bytes  │ │           │   │                        │
 │          │  └─────────────────┘ └───────────┘   │                        │
 │          └──────────────────────────────────────┘                        │
 └──────────────────────────────────────────────────────────────────────────┘
```

The four new modules (three pipeline stages + one generic RAM) sit in the `clk_dsp` domain between the two existing `axis_async_fifo` instances in [hw/top/sparevideo_top.sv](hw/top/sparevideo_top.sv), directly replacing the `genvar gi=0..3` `axis_register` loop at [sparevideo_top.sv:107-155](hw/top/sparevideo_top.sv#L107-L155). The input and output CDC FIFOs are untouched. `ram` is instantiated at the top level alongside the pipeline — not inside `axis_motion_detect` — so its port B is reachable from `sparevideo_top` for future sporadic host clients, and its address space can be re-partitioned across additional clients without touching the motion detect module.

Bounding-box flow: `axis_bbox_reduce` latches a new `{min_x, max_x, min_y, max_y}` tuple at every end-of-frame. `axis_overlay_bbox` always reads the *currently latched* registers, so the box drawn on frame `N` is derived from the motion observed during frame `N-1` — a constant 1-frame overlay latency. This keeps the whole pipeline single-pass and avoids a second frame-sized buffer.

## Video Stream Protocol

Already established by the existing top-level AXI4-Stream interface; no changes here.

- `tdata[23:0]` = `{R[7:0], G[7:0], B[7:0]}`, RGB888.
- `tuser[0]` = **SOF**, asserted on the first pixel of each frame (pixel `(0, 0)`).
- `tlast` = **EOL**, asserted on the last pixel of each row (pixel `(H_ACTIVE-1, y)`).
- No blanking pixels in the stream — exactly `H_ACTIVE × V_ACTIVE` accepted pixels per frame.
- A transfer occurs on cycles where `tvalid && tready`.

The motion-mask sideband stream uses the **same framing** (same `tuser`/`tlast`/`tvalid`) with `tdata[0]` as the 1-bit mask.

## Modules

### 0. `rgb2ycrcb.sv`  *(dependency of `axis_motion_detect`)*

Standalone RGB888 → YCrCb color-space converter. Lives at `hw/ip/rgb2ycrcb/rtl/rgb2ycrcb.sv` with its own FuseSoC core `sparevideo:ip:rgb2ycrcb`. Reusable — motion detect only cares about the Y output today, but the block emits all three components so later pipeline stages (dithering, color correction, YCrCb-space processing) can pick it up for free.

**Interface**

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| `clk`   | in  | 1 | clock |
| `rst_n` | in  | 1 | active-low synchronous reset |
| `r`, `g`, `b` | in  | 8 | unsigned RGB pixel |
| `y`, `cr`, `cb` | out | 8 | YCrCb components, registered, 2-cycle latency vs `r,g,b` |

**Algorithm.** Rec.601-ish, 8-bit fixed-point (Q0.8). Coefficients hand-chosen so every intermediate result is non-negative and exactly fits in the top byte after `>>8`, so **no saturation logic is needed**:

```
Y  = ( 77*R + 150*G +  29*B         ) >> 8   // range [0,   65280] → [0, 255]
Cb = (-43*R -  85*G + 128*B + 32768 ) >> 8   // range [128, 65408] → [0, 255]
Cr = (128*R - 107*G -  21*B + 32768 ) >> 8   // range [128, 65408] → [0, 255]
```

Verified corner cases (hand-checked, same as testbench expectations):

| RGB | Expected Y | Expected Cb | Expected Cr |
|---|---|---|---|
| `(0,0,0)` — black  | 0   | 128 | 128 |
| `(255,255,255)` — white | 255 | 128 | 128 |
| `(128,128,128)` — gray  | 128 | 128 | 128 |
| `(255,0,0)` — red   | 76  | 85  | 255 |
| `(0,255,0)` — green | 149 | 43  | 21  |
| `(0,0,255)` — blue  | 28  | 255 | 107 |

**Pipeline.** 2 stages, both `always_ff`:

1. Stage 1: registered multiply-accumulate sums (`y_sum`, `cb_sum`, `cr_sum` — 17 bits each).
2. Stage 2: take top byte (`y <= y_sum[15:8];` etc.).

Pure SystemVerilog — no vendor primitives, no `*` synthesis pragmas needed. Inspired by the [freecores/video_systems/rgb2ycrcb.v](https://github.com/freecores/video_systems/blob/master/common/color_space%20converters/rgb2ycrcb/rtl/verilog/rgb2ycrcb.v) (Richard Herveille, BSD), adapted to 8-bit and with coefficients retuned to remove the need for saturation.

### 1. `axis_motion_detect.sv`

Computes a 1-bit motion mask against the previous frame and passes the RGB video through unchanged. Instantiates one `rgb2ycrcb` for the RGB→Y conversion; connects the `y` output and leaves `cr`/`cb` unconnected (with explicit Verilator lint waivers for `PINCONNECTEMPTY` + `UNUSEDSIGNAL`).

**Parameters**
- `H_ACTIVE`, `V_ACTIVE` — frame dimensions (propagated from `sparevideo_top`).
- `THRESH` — unsigned 8-bit luma-difference threshold. Default `8'd16` (≈6.25% intensity).
- `RGN_BASE` — base byte-address of the Y_PREV region inside the shared `ram`. Default `0`. Propagated from `sparevideo_top`'s descriptor table.
- `RGN_SIZE` — byte size of the Y_PREV region. Must equal `H_ACTIVE*V_ACTIVE`. Default `H_ACTIVE*V_ACTIVE`. Used only for an `initial`-block sanity assertion — the runtime counter still wraps on the frame geometry, not on `RGN_SIZE`.

**Interface**

| Port group | Signals |
|---|---|
| AXIS in (RGB888) | `s_axis_tdata[23:0]`, `s_axis_tvalid`, `s_axis_tready`, `s_axis_tlast`, `s_axis_tuser` |
| AXIS out — video (RGB888) | `m_axis_vid_tdata[23:0]`, `m_axis_vid_tvalid`, `m_axis_vid_tready`, `m_axis_vid_tlast`, `m_axis_vid_tuser` |
| AXIS out — mask (1 bit) | `m_axis_msk_tdata[0]`, `m_axis_msk_tvalid`, `m_axis_msk_tready`, `m_axis_msk_tlast`, `m_axis_msk_tuser` |
| Memory port (to `ram` port A) | `mem_rd_addr`, `mem_rd_data` (in, 1-cycle latency), `mem_wr_addr`, `mem_wr_data`, `mem_wr_en` |

**Algorithm** (per accepted pixel at row-major pixel index `pix_idx`, reset on SOF):

```
Y_cur  = rgb2ycrcb(R, G, B).y               // external module, 2-cycle pipeline latency
                                            // Cr/Cb outputs left unconnected for now.
Y_prev = mem_rd_data                        // from external RAM, 1-cycle after mem_rd_addr
diff   = (Y_cur > Y_prev) ? Y_cur - Y_prev : Y_prev - Y_cur
mask   = (diff > THRESH)

// Descriptor-based addressing — motion detect never sees raw physical addresses.
// Any byte in the shared `ram` that lies outside [RGN_BASE, RGN_BASE+RGN_SIZE)
// is not touched by this module.
mem_wr_addr  <= RGN_BASE + pix_idx          // write-after-read at same addr
mem_wr_data  <= Y_cur
mem_wr_en    <= (s_axis_tvalid && s_axis_tready)
mem_rd_addr   = RGN_BASE + pix_idx_next     // read for next pixel
pix_idx <= (tlast && row==V_ACTIVE-1) ? 0 : pix_idx+1
```

**Memory port (external, not internal)**

The Y8 frame buffer is **not** internal to `axis_motion_detect`. The module exposes a 1R1W memory port and connects to `ram` port A at the top level (see module 4 below). This keeps the RAM reusable for future clients through port B without having to reach into `axis_motion_detect`, and makes the motion detect module agnostic about where its region lives in the shared address space.

The read-before-write discipline is enforced via `ram`'s read-first port semantics: on the cycle motion detect writes `Y_cur` at `RGN_BASE+pix_idx`, port A returns the old `Y_prev` for that same address (previous-frame value). No external bypass logic needed.

On the first frame after reset, port A reads back `8'h00` (zero-init in `ram`'s `initial` block), so every pixel reads as "motion" and `axis_bbox_reduce` produces a full-frame bbox — the overlay draws a border on frame 0. Accepted cosmetic artifact; frames 1..N-1 are correct.

**Timing / latency**
- 2-cycle `rgb2ycrcb` pipeline + 1-cycle external RAM read = 3 cycles from accepted input pixel to emitted mask bit. The RGB passthrough path is delayed by the matching number of `axis_register` stages (from `third_party/verilog-axis/rtl/axis_register.v`) so the emitted video pixel and the emitted mask bit represent the same source pixel.
- Total throughput: 1 pixel/clk, no `tready` deassertion generated internally.

### 2. `axis_bbox_reduce.sv`

Consumes the mask stream, tracks `{min_x, max_x, min_y, max_y}` over all pixels where `mask==1` in a frame, and latches the result once per frame.

**Parameters**: `H_ACTIVE`, `V_ACTIVE` (for row/col counter widths only).

**Interface**

| Port group | Signals |
|---|---|
| AXIS in (mask 1b) | `s_axis_tdata[0]`, `s_axis_tvalid`, `s_axis_tready` (tied `1`), `s_axis_tlast`, `s_axis_tuser` |
| Sideband out | `bbox_min_x`, `bbox_max_x`, `bbox_min_y`, `bbox_max_y` (all `$clog2(max(H,V))`-bit registered), `bbox_valid` (1 cycle strobe at EOF), `bbox_empty` (no mask pixels seen in the frame) |

**Column/row tracking** reuses the counter pattern already in [hw/ip/vga/rtl/vga_controller.sv](hw/ip/vga/rtl/vga_controller.sv) — `col` increments on every accepted pixel, resets to `0` on `tlast`; `row` increments on `tlast`, resets to `0` on `tuser`.

**Latch condition**: `tlast && row==V_ACTIVE-1 && tvalid`. On the latch cycle, the accumulated min/max registers snap into the output registers and the scratch accumulators reset to sentinel values (`min = H_ACTIVE-1`, `max = 0`, `min_y = V_ACTIVE-1`, `max_y = 0`).

`bbox_empty` is asserted if no mask bit was seen during the frame — this lets the overlay module skip drawing entirely, which is the correct behavior for static frames (color_bars, gradient).

Not an AXIS output — the downstream consumer (`axis_overlay_bbox`) reads the latched registers directly.

### 3. `axis_overlay_bbox.sv`

Draws a 1-pixel-thick rectangle on the RGB passthrough stream using the currently latched bbox from `axis_bbox_reduce`.

**Parameters**
- `H_ACTIVE`, `V_ACTIVE`.
- `BBOX_COLOR` — default `24'h00_FF_00` (bright green).

**Interface**

| Port group | Signals |
|---|---|
| AXIS in (RGB888) | `s_axis_tdata[23:0]`, `s_axis_tvalid`, `s_axis_tready`, `s_axis_tlast`, `s_axis_tuser` |
| AXIS out (RGB888) | `m_axis_tdata[23:0]`, `m_axis_tvalid`, `m_axis_tready`, `m_axis_tlast`, `m_axis_tuser` |
| Sideband in | `bbox_min_x`, `bbox_max_x`, `bbox_min_y`, `bbox_max_y`, `bbox_empty` |

**Algorithm**: same `col`/`row` counter as `axis_bbox_reduce`. A pixel is "on the rectangle" iff

```
on_rect = !bbox_empty && (
    (col==bbox_min_x || col==bbox_max_x) && (row>=bbox_min_y && row<=bbox_max_y) ||
    (row==bbox_min_y || row==bbox_max_y) && (col>=bbox_min_x && col<=bbox_max_x)
);
```

Output pixel is `BBOX_COLOR` when `on_rect`, else the input pixel passes through unchanged. All sideband signals are stable for the duration of a frame (latched once per EOF in `axis_bbox_reduce`), so the overlay logic is purely combinational on top of the registered counters — 1 pixel/clk sustained, no backpressure.

**Latency**: 0 additional cycles vs. the input stream.

### 4. `ram.sv`

Generic top-level shared RAM. True dual-port behavioral byte-addressed memory (2× independent 1R1W ports) clocked on `clk_dsp`. Lives at `hw/top/ram.sv` next to `sparevideo_top.sv` — no new FuseSoC core needed, just added to `sparevideo_top.core`'s RTL fileset. When a second client lands, promote to `hw/ip/mem/` with its own core.

The RAM is intentionally **content-agnostic**: it has no knowledge of "frames", "Y", "regions", or any of its clients' data. Partitioning is handled externally by the region-descriptor table in `sparevideo_top.sv` (see "Region Descriptor Model" below). Today there is one client (`axis_motion_detect`) using one region (`Y_PREV`); tomorrow there can be more without any change to this module.

**Parameters**
- `DEPTH` — total number of bytes. Set by `sparevideo_top` from the sum of all region sizes (today: `H_ACTIVE × V_ACTIVE`, leaving port B free but not yet enlarging the RAM for hypothetical clients).
- `ADDR_W` — `$clog2(DEPTH)`.

**Interface** (A and B are symmetric; `<p>` ∈ `{a, b}`)

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| `clk`          | in  | 1 | shared clock (`clk_dsp`) |
| `<p>_rd_addr`  | in  | `ADDR_W` | read address |
| `<p>_rd_data`  | out | 8 | read data, valid 1 cycle after `rd_addr` |
| `<p>_wr_addr`  | in  | `ADDR_W` | write address |
| `<p>_wr_data`  | in  | 8 | write data |
| `<p>_wr_en`    | in  | 1 | write strobe |

**Behavior.** Single `logic [7:0] mem [0:DEPTH-1]` backing store, zero-initialized in an `initial` block. Two independent `always_ff @(posedge clk)` blocks, one per port, each with **read-first** semantics on the same port: a port reading the same address it is writing *on the same cycle* sees the **old** value (which is exactly what motion detect needs for its read-before-write discipline at the same address).

**Inter-port collision semantics.** The two ports share the backing store but have no inter-port ordering guarantee:

| Scenario | Port A | Port B | Result |
|---|---|---|---|
| Reads only | read `addr_X` | read `addr_Y` | both well-defined |
| A reads, B writes, disjoint addresses | read `addr_X` | write `addr_Y` (X ≠ Y) | both well-defined |
| A reads, B writes, **same address** | read `addr_X` | write `addr_X` | A gets the *old* value (read-first on A) |
| A writes, B reads, **same address** | write `addr_X` | read `addr_X` | B gets the *old* value (read-first on B) |
| Both write same address same cycle | write `addr_X = V_A` | write `addr_X = V_B` | **non-deterministic** — last assignment wins in Verilog, simulator-dependent |

The last row is the only unsafe case. It is managed by a **host-responsibility rule** documented in the bandwidth section below: port B clients must not write the exact address motion detect is actively writing on the same cycle.

**Not synthesizable as-is on FPGA.** The behavioral model is simulation-only. For synthesis, swap in a vendor true-dual-port BRAM primitive (e.g., Xilinx `xpm_memory_tdpram`) — the interface already matches. Out of scope here; the repo is simulation-only.

## Region Descriptor Model

The shared `ram` is partitioned into named regions. Each region has a `{BASE, SIZE}` descriptor and exactly one client module that owns its address range. Descriptors are **compile-time parameters today** and are structured so they can migrate to **SW-writable registers tomorrow** without changing the RAM module or the client modules.

### Descriptor table (today: localparams in `sparevideo_top.sv`)

```systemverilog
// ---- Region descriptor table ---------------------------------------
// Each region = {BASE (byte offset in `ram`), SIZE (bytes)}.
// Owners must only touch addresses in [BASE, BASE+SIZE).
// Sum of all SIZE values must be <= ram.DEPTH.
//
//   Region                Owner                        Base                      Size
//   ------                -----                        ----                      ----
localparam int RGN_Y_PREV_BASE = 0;
localparam int RGN_Y_PREV_SIZE = H_ACTIVE * V_ACTIVE;     // axis_motion_detect
// Reserved for future growth (FPN/PRNU refs, LUTs, scratch, debug capture):
// localparam int RGN_FPN_BASE  = RGN_Y_PREV_BASE + RGN_Y_PREV_SIZE;
// localparam int RGN_FPN_SIZE  = H_ACTIVE * V_ACTIVE;
// ...

localparam int RAM_DEPTH = RGN_Y_PREV_SIZE;               // extend as regions are added
```

Each pipeline module that touches the RAM takes its descriptor fields as parameters (`axis_motion_detect #(.RGN_BASE(RGN_Y_PREV_BASE), .RGN_SIZE(RGN_Y_PREV_SIZE)) u_motion_detect (...)`). The module adds `RGN_BASE` to its internal offset counter to form the physical RAM address. A module never sees any address outside its own region — there is no enforcement, just a convention that falls out of the parameter plumbing.

### `THRESH` is a control parameter, not a descriptor

`THRESH` is a per-algorithm control knob, not a memory partition, so it lives as a separate localparam next to the descriptor table (not inside it):

```systemverilog
localparam logic [7:0] MOTION_THRESH = 8'd16;
```

Both the descriptor table and `MOTION_THRESH` are grouped together in `sparevideo_top.sv` as "the things that would become CSRs" — see the migration path below.

### Future: SW-writable CSR register file

When runtime configurability becomes a requirement, the descriptor table and control knobs migrate to an AXI-Lite slave (tentative name: `sparevideo_csr`) exposed on a new top-level AXI-Lite port. The migration path is deliberately additive:

1. **Add `sparevideo_csr.sv`** — a small AXI-Lite slave with a flat register map. Proposed initial layout:

   | Offset | Name             | Width | Purpose |
   |---|---|---|---|
   | `0x00` | `CTRL`           | 32 | bit 0 = motion_detect_enable, bit 1 = bbox_overlay_enable, … |
   | `0x04` | `MOTION_THRESH`  | 8  | today's `THRESH` localparam |
   | `0x08` | `BBOX_COLOR`     | 24 | today's `BBOX_COLOR` localparam |
   | `0x10` | `RGN_Y_PREV_BASE`| 32 | today's `RGN_Y_PREV_BASE` localparam |
   | `0x14` | `RGN_Y_PREV_SIZE`| 32 | today's `RGN_Y_PREV_SIZE` localparam |
   | `0x20` | `RGN_FPN_BASE`   | 32 | future |
   | …      | …                | …  | … |

2. **Replace the localparams** in `sparevideo_top.sv` with wires driven by the CSR block. The downstream module parameter ports become input ports of the same width — minimal port-list churn because the parameter/port split was designed with this in mind. Motion detect's `RGN_BASE`/`RGN_SIZE` parameters become `rgn_base_i`/`rgn_size_i` inputs, and the same for `THRESH`/`BBOX_COLOR`.

3. **CSR reads are "sampled once per frame"** to avoid mid-frame register-change glitches. The simplest implementation: latch all motion-detect control inputs into the `clk_dsp` domain on SOF. This keeps the semantics identical to the parameter version frame-by-frame.

4. **Descriptor validation** — the CSR block checks `Σ SIZE ≤ RAM_DEPTH` on any descriptor write and ignores (or error-flags) writes that would overflow. With localparams this check is a compile-time `$error` in an `initial` block.

5. **Port B of `ram`** — once CSR exists, port B is the natural landing spot for an AXI-Lite memory bridge (`csr` → `ram` port B) so the host can read/write frame buffers without touching any pipeline module. This slots into the host-responsibility rule from the bandwidth section (read-only, or quiesced-writes, or disjoint-address) with no architectural surprises.

All of the above is **deferred** — it is described here only so the descriptor structure is chosen compatibly today and nothing has to be ripped up later. The current plan ships with localparams only.

## RAM Bandwidth and Sporadic Host Access Evaluation

**Question raised during planning:** does the motion detection pipeline still work if `ram` has to serve sporadic accesses from other (currently hypothetical) clients?

**Short answer:** yes, with no performance impact and a single host-responsibility rule around same-address writes. Port A is only ~25% utilized; port B is 100% free today and reserves full bandwidth for host clients.

### Port ownership

`ram` has **two physically independent ports**. Port A is dedicated to `axis_motion_detect`. Port B is exposed at the top of `sparevideo_top` as the sporadic host port. The two ports never contend for the same port's slots — they can only interact at the address level.

### Bandwidth analysis

| Quantity | Value | Notes |
|---|---|---|
| `clk_dsp` | 100 MHz | processing clock |
| `clk_pix` | 25 MHz | input clock (source of AXIS input via async FIFO) |
| Max pixel arrival rate on port A | ≤ 25 Mpix/s | bounded by `clk_pix` — the input async FIFO cannot deliver faster than its write side |
| Motion detect accesses per pixel | 1 read + 1 write | single 1R1W slot on port A |
| Port A slot utilization | ≤ 25% | `tvalid && tready` is asserted at most 1 in 4 `clk_dsp` cycles |
| Port A idle slots | ≥ 75% | unused by motion detect |
| Port B slot utilization | 0% | no client wired today |
| Total idle port-capacity | 100% of port B + ≥75% of port A | plenty of headroom |

### Throughput conclusion

Motion detect sustains 1 pixel per `clk_dsp` cycle *when `tvalid` is asserted*, independent of whatever port B is doing — ports don't share slots. Any sporadic host activity on port B has **zero impact** on motion detect throughput. The SVA at [sparevideo_top.sv:287-290](hw/top/sparevideo_top.sv#L287-L290) (input FIFO always ready) continues to hold unconditionally, and no new backpressure path is introduced.

Even collapsing to a **single-port** RAM (if we ever decided to simplify), motion detect would only consume ≤ 50% of slots (read + write), leaving ≥ 50% free for a host. Dual-port is chosen for clean decoupling and for natural mapping to FPGA BRAM, not because bandwidth demands it.

### Functional coupling through the shared backing store

The two ports are independent in *timing* but share *state*. How the host uses port B affects what motion detect sees on port A:

1. **Host reads only (debug/snoop/frame dump)** — completely safe. Port A is never perturbed. Expected common case.
2. **Host writes between frames** — safe and potentially useful. If the host writes pixel `addr` while motion detect's `tvalid` is low (e.g., in the gap between frames), motion detect will see the host-written value as `Y_prev` on the next frame at that address. This is the correct semantics and doubles as a **test injection hook** (inject known prev-frame values, verify mask output).
3. **Host writes during the active frame, disjoint address** — safe. Ports are independent; touching a different address than motion detect's current `addr` cannot perturb it.
4. **Host writes during the active frame, same address as motion detect's current write** — *unsafe* without coordination. Behavioral simulator result is non-deterministic (last-write-wins); real dual-port BRAM has cell-specific behavior.

### Host-responsibility rule

Any future port B client must obey **at least one** of the following:

1. **Read-only.** Never drive `b_wr_en`. Always safe.
2. **Quiesced writes.** Only assert `b_wr_en` while `axis_motion_detect`'s AXIS input `tvalid` has been low for more than one frame period (guaranteed inter-frame gap).
3. **Disjoint address ranges.** Write only to addresses the motion detect pipeline will not touch during the current frame (e.g., region outside the active window, or alternate-frame striping).

This rule gets formalized and enforced (optionally via an SVA) when the first port B client lands. Until then, port B is tied off in `sparevideo_top` and the rule is just a comment in `ram.sv`.

### When this analysis breaks

The evaluation above assumes:

- `clk_dsp >= clk_pix` with enough margin that port A utilization stays below 50%. If a future change runs the pipeline at `clk_pix` speed or uses a higher-rate source (e.g., line-rate upscaling), re-run the bandwidth math.
- The host client doesn't issue sustained-rate writes. "Sporadic" is load-bearing — a sustained-rate host client competing for the same port would need arbitration or a second RAM instance, neither of which is in scope.
- The pipeline stays single-buffered. Moving to double-buffered (OPTION 2 in [plans/architecture.md](plans/architecture.md)) would replace this RAM with two instances and a swap mechanism, invalidating the port layout here.

## `sparevideo_top.sv` Changes

The 4-stage `axis_register` genvar loop at [sparevideo_top.sv:107-155](hw/top/sparevideo_top.sv#L107-L155) is replaced by three pipeline modules plus one shared RAM instance, all on `clk_dsp`:

```systemverilog
// ---- Control localparams (future CSR content) -------------------
localparam logic [7:0]  MOTION_THRESH = 8'd16;
localparam logic [23:0] BBOX_COLOR    = 24'h00_FF_00;

// ---- Region descriptor table (future CSR content) --------------
localparam int RGN_Y_PREV_BASE = 0;
localparam int RGN_Y_PREV_SIZE = H_ACTIVE * V_ACTIVE;
localparam int RAM_DEPTH       = RGN_Y_PREV_SIZE;

// ---- Shared RAM -------------------------------------------------
logic [$clog2(RAM_DEPTH)-1:0] a_rd_addr, a_wr_addr;
logic [7:0]                   a_rd_data, a_wr_data;
logic                         a_wr_en;

ram #(.DEPTH(RAM_DEPTH)) u_ram (
    .clk       (clk_dsp),
    .a_rd_addr (a_rd_addr), .a_rd_data (a_rd_data),
    .a_wr_addr (a_wr_addr), .a_wr_data (a_wr_data), .a_wr_en (a_wr_en),
    // Port B: tied off today; future host client lands here.
    .b_rd_addr ('0), .b_rd_data (),
    .b_wr_addr ('0), .b_wr_data ('0), .b_wr_en (1'b0)
);

// ---- Pipeline ---------------------------------------------------
axis_motion_detect #(
    .H_ACTIVE (H_ACTIVE), .V_ACTIVE (V_ACTIVE),
    .THRESH   (MOTION_THRESH),
    .RGN_BASE (RGN_Y_PREV_BASE), .RGN_SIZE (RGN_Y_PREV_SIZE)
) u_motion_detect (
    .clk        (clk_dsp),
    .s_axis_*   (...),                // from input async FIFO
    .m_axis_vid_* (...),               // to u_overlay_bbox
    .m_axis_msk_* (...),               // to u_bbox_reduce
    .mem_rd_addr(a_rd_addr), .mem_rd_data(a_rd_data),
    .mem_wr_addr(a_wr_addr), .mem_wr_data(a_wr_data), .mem_wr_en(a_wr_en)
);

axis_bbox_reduce #(.H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE))
    u_bbox_reduce (...);

axis_overlay_bbox #(.H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .BBOX_COLOR(BBOX_COLOR))
    u_overlay_bbox (...);
```

The existing `H_ACTIVE`/`V_ACTIVE` top-level parameters already propagate correctly. `MOTION_THRESH`, `BBOX_COLOR`, and the descriptor localparams are grouped together as "the set that would migrate to `sparevideo_csr`" — see the Region Descriptor Model section.

The SVA at [sparevideo_top.sv:287-290](hw/top/sparevideo_top.sv#L287-L290) (input FIFO always ready) must continue to hold. It does — every new module sustains 1 pixel/clk and none of them deassert `tready` based on internal state.

A compile-time sanity check is added next to the descriptor table:

```systemverilog
initial begin
    if (RGN_Y_PREV_BASE + RGN_Y_PREV_SIZE > RAM_DEPTH) begin
        $error("ram region table overflows RAM_DEPTH");
    end
end
```

## Testbench Changes

### Per-block unit testbenches

Each new RTL block gets its own standalone testbench under `hw/ip/<block>/tb/tb_<module>.sv`, testing basic functional correctness in isolation (no top-level integration). These run in a few hundred ns each and are compiled/launched via a new top-level `make test-ip` target that iterates through them (Verilator by default, Icarus also supported).

| Block | Testbench | What it covers |
|---|---|---|
| `rgb2ycrcb`          | `hw/ip/rgb2ycrcb/tb/tb_rgb2ycrcb.sv`           | 6 corner RGB inputs (black, white, gray, pure R/G/B); checks Y/Cb/Cr against hand-computed reference with ±1 LSB tolerance after the 2-cycle pipeline. |
| `axis_motion_detect` | `hw/ip/motion/tb/tb_axis_motion_detect.sv`     | Drives 2 small frames (4×2) through the AXIS input with a local `ram` instance on the memory port. Frame 0 should produce all-motion mask (RAM zero-init). Frame 1 should produce motion only on pixels that changed. |
| `axis_bbox_reduce`   | `hw/ip/motion/tb/tb_axis_bbox_reduce.sv`       | Drives a single mask frame with a few known-position mask bits; checks the latched `{min_x,max_x,min_y,max_y}` at EOF. Also checks `bbox_empty` is asserted for an all-zero mask frame. |
| `axis_overlay_bbox`  | `hw/ip/motion/tb/tb_axis_overlay_bbox.sv`      | Statically holds `{min_x,max_x,min_y,max_y}` = a known rectangle; drives a solid-color video frame; checks that only the 4 rectangle edges come out as `BBOX_COLOR` and every other pixel is unchanged. |

Each testbench:
- Generates `clk_dsp` at 100 MHz locally (no `clk_pix` needed — these blocks live entirely in the DSP domain).
- Follows the TB conventions in [CLAUDE.md](CLAUDE.md): `drv_*` intermediaries written with blocking `=` in `initial`, driven to the DUT via `always_ff @(negedge clk)` to avoid the Verilator INITIALDLY race.
- Uses `$display` + `$fatal` for pass/fail reporting (no SVA — Icarus 12 compat).
- Terminates with `$finish` on success, `$fatal(1, ...)` on mismatch so `make test-ip` can detect failures via exit code.

### Top-level testbench updates ([dv/sv/tb_sparevideo.sv](dv/sv/tb_sparevideo.sv))

- Add a new `+THRESH=%d` plusarg next to the existing `$value$plusargs` block. Default `16` if absent. Override `MOTION_THRESH` on the `u_dut` instantiation via SV `defparam` (or, preferred, promote `MOTION_THRESH` to a module parameter of `sparevideo_top` with default `8'd16` so the TB can use ordinary parameter-override syntax). The descriptor localparams (`RGN_*`) are not TB-overridable — they are derived from `H_ACTIVE`/`V_ACTIVE` which the TB already overrides.
- No new stimulus logic needed for `color_bars` / `gradient` — both are static across frames → mask is all zero (except frame 0, which is "everything moved" from the zero-initialized frame buffer; bbox logic handles that as a full-frame box, which the overlay draws as a rectangle around the image border) → remaining frames are bit-exact passthrough except for the outer border on frame 0.
- For motion-bearing stimulus, use the existing `synthetic:moving_box` source listed in the [README.md](README.md) options table at line 154. **Sub-task**: confirm `moving_box` is actually implemented in [py/frames/video_source.py](py/frames/video_source.py); if only documented-but-absent, implement it (a single bright square translating by N pixels/frame on a black background).

## Python Harness Changes

The current `verify` step does a pixel-exact `np.array_equal` check at [py/viz/render.py:83](py/viz/render.py#L83). This no longer holds once the bbox overlay is drawing a border on moving sources (and on frame 0 of every source).

**Recommended approach**: add a `--tolerance PIXELS` flag to `harness.py verify` that counts the number of differing pixels per frame and passes if the count is below `tolerance`. For:

- `color_bars`, `gradient` — tolerance = `2*(H_ACTIVE+V_ACTIVE)` (frame 0 border only, frames 1..N-1 bit-exact).
- `moving_box`, MP4 sources — tolerance higher or a dedicated `--motion` verify mode that locates the bounding-box rectangle and confirms its interior is bit-exact passthrough.

This sub-question is intentionally left half-open (see **Open Questions**); the exact threshold depends on `THRESH` and the content of the motion source, and should be tuned empirically during implementation.

## File Checklist

| Path | Action |
|---|---|
| `hw/ip/rgb2ycrcb/rtl/rgb2ycrcb.sv` | new |
| `hw/ip/rgb2ycrcb/tb/tb_rgb2ycrcb.sv` | new — unit TB |
| `hw/ip/rgb2ycrcb/rgb2ycrcb.core` | new (VLNV `sparevideo:ip:rgb2ycrcb`) |
| `hw/ip/motion/rtl/axis_motion_detect.sv` | new |
| `hw/ip/motion/rtl/axis_bbox_reduce.sv` | new |
| `hw/ip/motion/rtl/axis_overlay_bbox.sv` | new |
| `hw/ip/motion/tb/tb_axis_motion_detect.sv` | new — unit TB |
| `hw/ip/motion/tb/tb_axis_bbox_reduce.sv` | new — unit TB |
| `hw/ip/motion/tb/tb_axis_overlay_bbox.sv` | new — unit TB |
| `hw/ip/motion/motion.core` | new (VLNV `sparevideo:ip:motion`; depends on `sparevideo:ip:rgb2ycrcb`) |
| `hw/top/ram.sv` | new — generic dual-port byte RAM, content-agnostic |
| [hw/top/sparevideo_top.sv](hw/top/sparevideo_top.sv) | modify — replace 4-stage chain with 3 pipeline modules + `u_ram`; add descriptor/control localparams; promote `MOTION_THRESH` to parameter so TB can override |
| [sparevideo_top.core](sparevideo_top.core) | modify — add `sparevideo:ip:motion` dependency and `hw/top/ram.sv` to RTL fileset |
| [dv/sim/Makefile](dv/sim/Makefile) | modify — add motion IP files and `hw/top/ram.sv` to `RTL_SRCS`; add per-block `test-ip-<block>` targets |
| [Makefile](Makefile) | modify — add top-level `test-ip` umbrella target |
| [dv/sv/tb_sparevideo.sv](dv/sv/tb_sparevideo.sv) | modify — `+THRESH=` plusarg + parameter override on `u_dut` |
| [py/harness.py](py/harness.py) or [py/viz/render.py](py/viz/render.py) | modify — `--tolerance` flag on `verify` |
| [py/frames/video_source.py](py/frames/video_source.py) | modify (conditional) — implement `synthetic:moving_box` if missing |
| [.github/workflows/regression.yml](.github/workflows/regression.yml) | modify — add `test-ip` step + `moving_box` run-pipeline step |
| [README.md](README.md) | modify — document `THRESH` option, `test-ip`, and the new pipeline |
| [CLAUDE.md](CLAUDE.md) | modify — update Project Overview |

## Verification

1. `make lint` passes with no new warnings. Motion IP is first-party and must not rely on the `third_party_waiver.vlt` blanket waiver.
2. `make compile SIMULATOR=verilator` and `make compile SIMULATOR=icarus` both succeed.
3. `make run-pipeline` (color_bars, gradient, text + binary) passes with the new `--tolerance` bound. Frames 1..N-1 are still bit-exact; frame 0 is the expected border-only diff.
4. `make run-pipeline SOURCE=synthetic:moving_box` passes verify and the rendered comparison PNG visibly shows a green rectangle tracking the moving box.
5. `make run-pipeline SOURCE=<sample.mp4>` — human eyeball check on `dv/data/renders/comparison.png`.
6. `make test-py` still passes (Python harness changes covered by existing or new unit tests).
7. CI workflow at [.github/workflows/regression.yml](.github/workflows/regression.yml) gains one new step for `synthetic:moving_box`; all other existing steps stay green.

## Risks

- **Frame-buffer read/write alignment.** The 1-cycle RAM read introduces a pipeline bubble relative to the passthrough RGB path. *Mitigation*: one `axis_register` stage inserted on the passthrough path inside `axis_motion_detect` so the emitted mask bit and the emitted RGB pixel represent the same source pixel.
- **SVA violation under backpressure.** If any new module deasserts `tready` while the input FIFO holds data, [sparevideo_top.sv:287-290](hw/top/sparevideo_top.sv#L287-L290) fires. *Mitigation*: every new module is a strict 1 pixel/clk pipeline — no FIFOs, no state-dependent stalls, `tready` tied through or to `m_axis_tready` only.
- **Verify bit-exactness breaks.** The existing `np.array_equal` check at [py/viz/render.py:83](py/viz/render.py#L83) must be replaced before the CI pipeline steps run, otherwise every run-pipeline target fails. *Mitigation*: the `--tolerance` flag and sensible per-source defaults must land in the same PR as the RTL.
- **RGB→Y quantisation flicker.** Tiny inter-frame diffs near the `THRESH` boundary could toggle the mask on/off per frame. *Mitigation*: default `THRESH=16` sits well above the ~4 LSB of noise introduced by the fixed-point Y conversion. Can be tuned via plusarg during bring-up.
- **Zero-initialized frame buffer on frame 0.** The first frame reads back zeros, so every pixel is "motion" and the bbox spans the whole image. *Mitigation*: accept this as a known cosmetic artifact on frame 0, document it, and size the verify tolerance to accommodate a frame-border draw.
- **`synthetic:moving_box` may be documented-only.** README lists it in the options table but it may not be implemented in [py/frames/video_source.py](py/frames/video_source.py). *Mitigation*: confirmed as a sub-task in the File Checklist; implementing it is ~20 lines of numpy.
- **Descriptor table drift vs. RAM layout.** If a future region is added to the descriptor table but `RAM_DEPTH` is not updated, the compile-time `$error` catches it. The opposite failure mode — descriptor table says "region X spans [BASE, BASE+SIZE)" but the owning client module accesses addresses outside that range — is not caught by the descriptor mechanism (the parameters are load-bearing convention, not enforcement). *Mitigation*: as a low-cost debug aid, add an optional `ifdef DESCRIPTOR_BOUNDS_CHECK` SVA in `sparevideo_top.sv` that watches each client's `mem_*_addr` against its region bounds. Off by default, on during bring-up.

## Open Questions

- **Verify-step strictness for motion sources.** Start with `--tolerance PIXELS` and per-source defaults. Revisit if this produces too many false-pass or false-fail results in practice. A second-generation option: explicit "rectangle detector" verify mode that finds the drawn rectangle and confirms its interior matches the input.
- **Frame-buffer storage for future FPGA synthesis.** Behavioral `logic [7:0] mem [...]` is fine for simulation but would need to be swapped for a vendor BRAM IP on real hardware. Out of scope here (simulation-only project); flagged for the eventual synthesis plan.
- **Runtime configuration via `sparevideo_csr`.** An AXI-Lite slave holding `CTRL`, `MOTION_THRESH`, `BBOX_COLOR`, and the region descriptor table — deferred. The current localparam layout in `sparevideo_top.sv` is deliberately structured to migrate directly into this register file (see **Region Descriptor Model → Future: SW-writable CSR register file**). Requires an AXI-Lite IP and a TB path to drive it, neither of which exists yet. Once CSR lands, it is also the natural owner of `ram` port B (host memory bridge).
- **Morphological filtering of the mask.** Erode/dilate passes to stabilize the bbox across frames — deferred. Would need line buffers, which breaks the "no extra frame-sized memory" constraint only slightly.
- **Multi-object tracking.** Multiple bounding boxes — deferred. Would require a per-object state machine and a richer sideband interface.
- **Prior art.** Two open-source repos were evaluated during design:
  - [2cc2ic/Motion-Detection-System-Based-On-Background-Reconstruction](https://github.com/2cc2ic/Motion-Detection-System-Based-On-Background-Reconstruction) (MIT) — Verilog motion detection targeting Xilinx with block-RAM macros and ISE-specific primitives. Useful as an algorithm reference but not vendorable (Xilinx-bound, no AXI4-Stream). Our `axis_motion_detect` follows the same frame-differencing approach but wraps it in a streaming AXIS interface with an external RAM port.
  - [freecores/video_systems — rgb2ycrcb.v](https://github.com/freecores/video_systems) (BSD) — 10-bit pipelined Rec.601 RGB→YCrCb converter. Our `rgb2ycrcb.sv` is inspired by this but retuned to 8-bit coefficients with a +32768 offset term to keep intermediates non-negative, eliminating the saturation/clamping logic the original required.
