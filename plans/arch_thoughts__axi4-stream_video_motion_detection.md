
Start with this as a base and Develop this Plan further before implementing!
This plan was written down on an old architecture that used cocotb, parts are no longer valid

# AXI4-Stream Video Motion Detection + Bounding Box Overlay (Simulation Project)

Simulation-only RTL project that generates a synthetic “camera” video stream (AXI4-Stream), performs motion detection against the previous frame, extracts a bounding box around motion, overlays the box on the video, and outputs frames for inspection via cocotb (optionally through a VGA-style output stage).

## Goals

- End-to-end **AXI4-Stream video pipeline** with correct `tvalid/tready` behavior.
- **Streaming-first design**: process 1 pixel/clk with minimal buffering.
- Use **only one frame buffer** (previous-frame grayscale) for motion detection.
- Compute motion bounding box in one pass; overlay bbox on the outgoing video.
- Provide cocotb-based capture to save frames (PNG) and/or video (MP4).

## Non-Goals (initially)

- Real camera sensor protocols (MIPI CSI-2, parallel DVP with blanking).
- Full VGA blanking-accurate timing (unless needed for debugging).
- Sophisticated background modeling (running average, optical flow, etc.).

---

## Proposed Architecture
+-------------------+ +---------------------+ +-------------------+
| axis_synth_cam |--> | axis_motion_detect |--> | axis_overlay_bbox |--> (to sink)
| (Y8 or RGB888) | | (prev-frame RAM) | | (draw rectangle) |
+-------------------+ +----------+----------+ +-------------------+
|
v
+-------------------+
| axis_bbox_reduce |
| (min/max tracker) |
+-------------------+


**Notes**
- `axis_motion_detect` outputs:
  - passthrough video stream (for display)
  - a 1-bit motion mask stream (same framing)
- `axis_bbox_reduce` consumes the motion mask stream and produces bbox registers latched once per frame.
- `axis_overlay_bbox` overlays the *previously latched* bbox onto the current video stream (1-frame bbox latency). This keeps the system streaming without storing an entire motion mask frame.

---

## Video Stream Protocol (AXI4-Stream Video-Style)

### Mandatory signals
- `aclk`, `aresetn`
- `tvalid`, `tready`
- `tdata` (pixel)
- `tuser[0]` = **SOF** (start-of-frame, asserted for first pixel of frame)
- `tlast` = **EOL** (end-of-line, asserted for last pixel in each line)

### Transfer rule
A pixel is accepted on a cycle where `tvalid && tready`.

### Framing rules (fixed resolution)
For a frame of size `HRES x VRES`, the stream contains exactly `HRES*VRES` accepted pixels per frame:
- SOF: `tuser[0]=1` on pixel `(0,0)`
- EOL: `tlast=1` on pixels `(HRES-1, y)` for each `y`

No blanking pixels are transmitted.

### Pixel format (choose one)
- **Option A (recommended initially): Y8 grayscale**
  - `tdata[7:0] = Y`
- **Option B: RGB888**
  - `tdata[23:0] = {R[7:0], G[7:0], B[7:0]}`
  - Motion detect converts RGB→Y internally.

---

## Modules (Implementation Plan)

### 1) `axis_synth_cam.sv`
Generates a synthetic camera stream in raster order.

**Features**
- Configurable resolution: `HRES`, `VRES`
- Generates a moving object (e.g., white square on dark background)
- Outputs AXIS framing (`SOF`, `EOL`)
- Supports backpressure: holds pixel stable when `tready=0`

**Deliverables**
- Deterministic pattern (same seed produces same frames)
- Parameters for object speed/size

---

### 2) `axis_motion_detect.sv`
Computes motion mask using previous-frame grayscale stored in a frame buffer.

**Algorithm**
- `prevY = RAM[addr]`
- `diff = abs(curY - prevY)`
- `motion = (diff > THRESH)`
- `RAM[addr] <= curY` (write current pixel for next frame)

**Interface**
- AXIS video input (Y8 or RGB888)
- AXIS video output (pass-through, typically RGB888 or Y8)
- AXIS mask output (1-bit packed into `tdata[0]`, with same `tuser/tlast`)

**Memory**
- Single-port or simple 1R1W model (implementation-defined)
- Size: `HRES*VRES` bytes for Y8

**Timing**
- Pipeline to sustain 1 pixel/clk (may require 1-cycle latency for RAM read).

---

### 3) `axis_bbox_reduce.sv`
Consumes the motion mask stream and computes bounding box for all `motion==1` pixels in a frame.


rtl/
axis_synth_cam.sv
axis_motion_detect.sv
axis_bbox_reduce.sv
axis_overlay_bbox.sv
axis_defs.svh
(optional) axis_to_vga.sv

third_party/
verilog-axis/ (submodule)

sim/
cocotb/
test_video_pipeline.py
axis_monitor.py
frame_writer.py

Makefile (or nox/tox)
README.md


---

## Open Questions / Future Extensions

- Same-frame bbox overlay (requires buffering mask or two-pass processing)
- Background model (running average) to reduce false positives
- Morphological ops on mask (erode/dilate) to stabilize bbox
- Multi-object tracking (multiple bboxes)
- AXI-Lite control registers (THRESH, enable/disable blocks)