# Digital Design: Video Pipeline Reference

A reference guide covering HDMI, AXI4-Stream video, frame buffers, and video processing pipeline architecture — compiled from design discussion.

---

## 1. Standard Hardware Blocks in Video Stream Processing

### Input / Capture
- MIPI CSI-2 / DSI receivers
- HDMI / DisplayPort receivers
- Analog front-end (AFE) + ADC for legacy analog signals

### Color & Format Conversion
- Demosaic (Bayer-to-RGB)
- Color space converters (RGB↔YCbCr, YUV↔YCbCr)
- Chroma subsampling (4:4:4 → 4:2:2 → 4:2:0)

### Scaling & Geometry
- Line buffers + polyphase scalers
- Crop/pad blocks
- Deinterlacer (1080i → 1080p)
- Geometric distortion correction / dewarp

### Image Quality / ISP
- Black level correction
- Lens shading correction (LSC)
- White balance (AWB gains)
- Gamma / tone mapping (LUT-based)
- Temporal (TNR) and spatial (SNR) noise reduction
- Edge enhancement / sharpening
- Auto-exposure and histogram engines

### Compression / Codec
- JPEG encoder/decoder
- H.264 / H.265 / AV1 encoder-decoder
- VLC (Variable Length Coding)

### Synchronization & Timing
- Sync separator
- Timing controller (TCON)
- Genlock / PLL
- Frame buffer / line buffer management

### Output / Display
- Overlay / OSD compositor
- HDMI / DP / MIPI DSI transmitter
- Gamma LUT (display-side)

### Cross-cutting Infrastructure
- DMA engines
- AXI/AHB interconnect
- Frame sync and flow control (backpressure, FIFO management)
- Metadata sidechannel

---

## 2. Open Source Video Cores (Verilog)

| Block | Repository |
|---|---|
| HDMI TX/RX | `hdl-util/hdmi` |
| AXI Stream infrastructure | `alexforencich/verilog-axi`, `alexforencich/verilog-axis` |
| Demosaic | `amanu/bayer_demosaic` |
| Scaler, display timings | `projf-play` (Project F) |
| MIPI CSI-2 | Antmicro GitHub repos |
| Sync generator | Project F `display_timings` |
| Formally verified video | `ZipCPU/videozip` |
| LiteX video pipeline | `enjoy-digital/litex` (LiteVideo) |

**Notes:**
- H.264/H.265 open Verilog cores are rare and usually incomplete
- OpenCores.org quality varies — some are simulation-only or abandonware
- For a production-quality open foundation: alexforencich (AXI) + hdl-util/hdmi + Project F

---

## 3. HDMI — Digital vs Analog

### Fully Digital Parts
- TMDS 8b/10b encoding/decoding
- Packet framing (video data period, data island period, control period)
- Audio embedding
- HDCP encryption
- AVI / vendor infoframes

### Analog / Mixed-Signal Parts

| Function | Notes |
|---|---|
| High-speed output drivers | Needs LVDS/TMDS I/O primitives in FPGA I/O ring |
| Pre-emphasis | Compensates PCB trace loss |
| Clock Data Recovery (CDR) | PLL-based, not implementable in digital logic alone |
| Equalization | Compensates cable/trace rolloff |
| TMDS termination | 50Ω in I/O cell |

### FPGA Coverage Summary

| Function | Open Verilog covers? |
|---|---|
| TMDS 8b/10b encode/decode | ✅ Yes |
| Packet framing / infoframes | ✅ Yes |
| High-speed serialization | ⚠️ Relies on FPGA SERDES primitives |
| CDR / clock recovery (RX) | ❌ Needs hardened PLL/SERDES |
| Output drive / termination | ❌ Board + I/O cell design |

---

## 4. HDMI in Simulation (PHY-less)

In simulation the analog/physical layer can be entirely skipped:

- **Drop:** CDR, SERDES, termination, differential signaling
- **Work at:** 10-bit TMDS word level (parallel), no serialization
- **Clock:** Drive pixel clock directly as a plain signal

### Simulation Architecture

```
[Stimulus: RGB frames from file or procedural]
        │
        ▼
[HDMI TX DUT — TMDS encoder, packet framing]
        │
  10-bit TMDS words + clock (no serialization)
        │
        ▼
[HDMI RX DUT — TMDS decoder, packet parser]
        │
        ▼
[Scoreboard — compare output vs expected]
```

### Stimulus / Checking Options
- Read raw RGB frames via `$fopen` / `$fread`
- Generate synthetic patterns (color bars, gradients)
- Use cocotb + PIL for Python-based image comparison

---

## 5. HDMI RX to AXI4-Stream

### The Mapping
```
TDATA  = pixel data (RGB or YCbCr)
TVALID = high during active video only
TLAST  = assert on last pixel of each line
TUSER  = start-of-frame (first pixel of frame) — commonly missed
TKEEP  = all-ones for video
```

### Key Challenges

**Sync detection and framing**
- Must correctly identify control periods vs video data periods
- Guardbands mark period boundaries — must detect correctly

**Clock domain crossing**
- HDMI RX runs on recovered pixel clock
- AXI downstream on system clock
- Requires async FIFO or proper CDC

**Backpressure**
- Video is constant-rate — HDMI does not pause
- Go straight into a line/frame buffer FIFO before any backpressuring block

**Blanking stripping**
- Most AXI video pipelines expect active-video-only on the stream
- Timing conveyed via TUSER/TLAST, not blanking pixels

### Sync State Machine
```
CONTROL_PERIOD
  → detect video leading guardband
ACTIVE_VIDEO
  → count pixels, assert TVALID
  → assert TLAST at end of line
  → extract HSync/VSync from control tokens
DATA_ISLAND (optional — for audio/infoframes)
```

---

## 6. HDMI Blanking & Throughput

### Blanking Structure
```
|<-- active video -->|<-- horizontal blanking -->|
|<-- active lines -->|<-- vertical blanking ────>|
```

### 1080p60 Timing Reference

| Parameter | Value |
|---|---|
| Active pixels | 1920 × 1080 |
| Total horizontal | 2200 pixels |
| H blanking | 280 pixels |
| Total vertical | 1125 lines |
| V blanking | 45 lines |
| Pixel clock | 148.5 MHz |

Active video ≈ **83%** of total pixel clock cycles.

### Common Resolutions

| Mode | Active | Pixel Clock | H total | V total |
|---|---|---|---|---|
| 720p60 | 1280×720 | 74.25 MHz | 1650 | 750 |
| 1080p30 | 1920×1080 | 74.25 MHz | 2200 | 1125 |
| 1080p60 | 1920×1080 | 148.5 MHz | 2200 | 1125 |
| 4K30 | 3840×2160 | 297 MHz | 4400 | 2250 |
| 4K60 | 3840×2160 | 594 MHz | 4400 | 2250 |

### Blanking as Processing Time
```
1080p60 H blanking  = 280 pixel clocks  ≈ 1.88 µs
1080p60 V blanking  = 45 lines × 2200  ≈ 666 µs
```
Commonly used for histogram updates, statistics, line buffer management.

---

## 7. Simulation at Reduced Resolution (320×240)

Recommended practice — ~27× fewer pixel clock cycles per frame vs 1080p.

### Parameterize Everything
```verilog
parameter H_ACTIVE = 320,
parameter H_FRONT  = 16,
parameter H_SYNC   = 32,
parameter H_BACK   = 32,
parameter V_ACTIVE = 240,
parameter V_FRONT  = 4,
parameter V_SYNC   = 4,
parameter V_BACK   = 4,
```

Switch to 1080p for final validation by changing parameters only.

### Minimal Blanking for Simulation
- H blanking: 16–32 cycles (vs 280 for real 1080p)
- V blanking: 4–8 lines
- Speeds simulation further, simplifies stimulus

---

## 8. Video Processing Pipeline Architectures

### Pixel-Synchronous Pipeline
```
pixel_clk ──► [block A] ──► [block B] ──► [block C] ──► output
              1 px/clk      1 px/clk      1 px/clk
```
No buffering needed. Suitable for per-pixel operations.

### Buffered + Higher Clock
```
pixel_clk ──► [line/frame buffer] ──► [processing @ fast_clk] ──► [output buffer] ──► pixel_clk
```
Decouples input timing from processing timing.

### When to Use Each

| Buffer type | Use case | Clock implication |
|---|---|---|
| No buffer | Per-pixel ops (gamma, CCM, gain) | Processing = pixel clock |
| Line buffer | Vertical kernels, deinterlace | Can run faster, 1–2 line latency |
| Frame buffer | Scaling, temporal NR, stabilization | Fully decoupled clocks, frame latency |

---

## 9. Frame Buffer — Triple Buffering

### Core Concept
Three physical buffers, each in one state at any time:
- **WRITING** — input currently filling this frame
- **READY** — newest complete frame, waiting to be displayed
- **READING** — output currently consuming this frame

### State Transitions
```
write_frame_done → WRITING becomes READY
                 → old READY (if any) becomes EMPTY
                 → EMPTY becomes new WRITING

read_frame_done  → READING becomes EMPTY
                 → READY becomes READING
                 → if no READY: hold, repeat current frame
```

### Why Not Double Buffering?
Double buffering only works if write rate == read rate exactly. Triple buffering absorbs clock differences — write can always complete without waiting for read and vice versa.

### Pointer Model
```verilog
reg [1:0] wr_ptr;    // buffer being written
reg [1:0] rd_ptr;    // buffer being read
reg [1:0] rdy_ptr;   // newest complete frame
reg       rdy_valid; // valid ready frame exists?
```

### Physical Memory Layout
```
addr = BUF_BASE + N × FRAME_SIZE + (line × H_ACTIVE + pixel) × BYTES_PER_PIXEL
```

For 320×240: frame size = 230,400 bytes. Three buffers ≈ 691 KB — fits in a Verilog array for simulation.

### CDC Handling
`rdy_ptr` and `rdy_valid` cross clock domains. Use:
- **Gray code pointer** — safe single-bit transitions
- **Two-flop synchronizer** on receive side
- **Handshake** — safe but adds latency (acceptable at frame rate)

### Frame Latency
- Best case: ~1 frame latency
- Worst case: ~2 frame latency

---

## 10. Processing Position in Pipeline

```
[Input]──►[Pre-buffer]──►[WRITE]──►[MEMORY]──►[READ]──►[Post-buffer]──►[Output]
                                        ▲
                                [In-between / read-modify-write]
```

### Pre-Buffer
- Per-pixel single-pass operations
- Color space conversion, gain, gamma, black level
- Reduces data size before storage — saves bandwidth
- Must keep up with input pixel clock rate

### Post-Buffer
- Display-driven operations: scaling, rotation
- OSD / graphics compositing
- Output gamma for specific display
- Must keep up with output pixel clock rate

### In-Between (Read-Modify-Write)
- Computationally intensive operations
- Temporal operations: motion estimation, temporal NR, frame blending
- Multi-pass algorithms
- Adds full frame latency per pass

### Decision Guide
```
Needs pixels from other lines?     No  → pixel-synchronous, no buffer
                                   Yes → line buffer minimum

Needs pixels from other frames?    No  → pre or post buffer
                                   Yes → in-between with frame buffer

Changes resolution/frame rate?     Yes → post buffer or in-between
                                   No  → pre or post

>1 cycle/pixel compute?            Yes → in-between, higher clock
                                   No  → pre or post at pixel clock

Needs global stats (histogram)?    Yes → in-between or two-pass
                                   No  → pre or post
```

---

## 11. Read-Fast / Write-Slow Pattern

Read frame buffer at fast clock, process, output at pixel clock rate.

```
[Frame buffer] ──► [READ @ fast_clk] ──► [Processing @ fast_clk] ──► [Async FIFO] ──► [Output @ pixel_clk]
```

### Timing Budget (320×240 example)
```
pixel_clk  = 6.25 MHz
fast_clk   = 25 MHz  (4×)
Frame period at 60fps = 16.67ms

Time to read+process entire frame:
  76,800 pixels / 25 MHz = 3.07ms

Remaining margin: 13.6ms — enormous headroom
```

### Output FIFO Sizing
- Minimum: processing latency × pixel_clock_rate
- Practical: size to one full line (H_ACTIVE entries)
- Absorbs DDR latency and rate mismatch

### FIFO as CDC Boundary
```
fast_clk domain          pixel_clk domain
────────────────         ─────────────────
[Processing]──►[Async FIFO]──►[Output stream]
            wr_clk=fast_clk  rd_clk=pixel_clk
```
Use alexforencich/verilog-axis async FIFO with gray-coded pointers.

---

## 12. Interface Alternatives to HDMI

| Interface | PHY complexity | Open cores | Sim friendly | Notes |
|---|---|---|---|---|
| HDMI | High | Moderate | Yes (skip PHY) | Standard monitor connection |
| DisplayPort | High | Rare | Yes (skip PHY) | Packetized transport |
| VGA | None (analog DAC) | Many | Yes | Good for FPGA bringup |
| MIPI CSI-2 | High | Some | Yes (skip PHY) | Camera input standard |
| Parallel DVP | None | Many | Very easy | OV7670, OV2640 sensors |
| BT.656 / BT.1120 | None | Some | Easy | Broadcast/industrial |
| DVI | High (= HDMI) | Many | Yes (skip PHY) | Simpler protocol than HDMI |
| Raw AXI4-Stream | None | N/A | Trivial | Simulation-only |

**Parallel DVP** is the simplest real interface:
```
PCLK  ─────────────────────────────
HREF  ───┐                    ┌────
VSYNC    └────────────────────┘
D[7:0]   ══════════════════════  pixel data valid when HREF high
```

---

## 13. Motion Detection & Rectangle Drawing

### Rectangle Drawing Alone — No Frame Buffer Needed
```verilog
// Pixel-synchronous OSD overlay
on_border = (on_left || on_right) && (pixel_y >= rect_y0) && (pixel_y <= rect_y1)
         || (on_top  || on_bottom) && (pixel_x >= rect_x0) && (pixel_x <= rect_x1);

pixel_out <= on_border ? RECT_COLOR : pixel_in;
```
Rectangle coordinates just need to be stable registers. No buffering required.

### Motion Detection — Frame Buffer Required
Comparing current frame against previous frame requires storing the reference:
```
Frame N   ──► [compare] ──► motion map
Frame N-1 ──►     ↑
                  │
            frame buffer (reference)
```

### Latency Options

**1-frame latency (simplest):**
- Store Frame N-1 as reference
- Compute rectangle from motion in Frame N
- Draw rectangle on Frame N+1
- Only 1 frame buffer needed

**0-frame latency:**
- Read Frame N twice (detect + draw)
- Needs 2 frame buffers + more bandwidth

### Background Subtraction (No Full Frame Buffer)
```verilog
// Per-pixel background model — array of background values only
diff = abs(pixel_in - background[pixel_addr]);
motion[pixel_addr] = diff > THRESHOLD;

// Slowly update background model
background[pixel_addr] <= background[pixel_addr]
                        + (pixel_in - background[pixel_addr]) >> ALPHA;
```
Needs background model array (same size as frame) but not full video frame buffer.

### Streaming Bounding Box Computation
```verilog
// Reset at frame start, update each pixel
if (frame_start) begin
    min_x <= H_ACTIVE; max_x <= 0;
    min_y <= V_ACTIVE; max_y <= 0;
end else if (motion_detected) begin
    min_x <= min(min_x, pixel_x);
    max_x <= max(max_x, pixel_x);
    min_y <= min(min_y, pixel_y);
    max_y <= max(max_y, pixel_y);
end
// Latch at frame_end → use as rectangle coords next frame
```
Pure streaming logic — no frame buffer needed for this step.

---

## 14. Reference Resources

### FPGA / HDL Focused
- **projectf.io** — video timings, FPGA graphics series, framebuffers in Verilog
- **zipcpu.com** — formally verified AXI stream and video, CDC treatment
- **hamsterworks.co.nz** — practical HDMI and video FPGA examples
- **fpga4fun.com** — clear explanations of HDMI, video timing basics

### Video Standards
- **tinyvga.com/vga-timing** — free timing tables for common resolutions
- **CEA-861 / CTA-861** — HDMI timing standard
- **Intel/Altera Video and Vision Processing Suite** (PG documentation) — reference for standard video IP blocks

### Academic
- *FPGA Prototyping by Verilog Examples* — Pong Chu (VGA/video chapters)
- *Digital Video Processing* — A. Murat Tekalp (algorithm reference)

### Key GitHub Repositories
```
github.com/hdl-util/hdmi              — clean HDMI TX/RX Verilog
github.com/alexforencich/verilog-axi  — AXI4 infrastructure
github.com/alexforencich/verilog-axis — AXI4-Stream, async FIFOs, CDC
github.com/projf/projf-explore        — Project F source
github.com/enjoy-digital/litex        — LiteX + LiteVideo
github.com/ZipCPU/videozip            — formally verified video
```

---

*Generated from design discussion session. Targets simulation-first FPGA video pipeline development.*
