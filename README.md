# sparevideo

Video processing pipeline with motion detection and bounding-box overlay, verified via Verilator with a file-based Python harness.

## Overview

A video processing pipeline written in SystemVerilog. The top-level design (`sparevideo_top`) accepts an **AXI4-Stream** video input on a 25 MHz pixel clock, crosses into a 100 MHz DSP clock domain, runs a **motion detection + bounding-box overlay pipeline**, crosses back to the pixel clock, and drives a VGA controller.

Architecture details, module interfaces, and design decisions are documented in [`docs/specs/`](docs/specs/):

| Document | Module |
|----------|--------|
| [`sparevideo-top-arch.md`](docs/specs/sparevideo-top-arch.md) | Top-level pipeline, clock domains, FIFO sizing, SVAs |
| [`axis_motion_detect-arch.md`](docs/specs/axis_motion_detect-arch.md) | Motion mask generation, RAM port discipline, backpressure |
| [`axis_bbox_reduce-arch.md`](docs/specs/axis_bbox_reduce-arch.md) | Mask → bounding-box reduction |
| [`axis_overlay_bbox-arch.md`](docs/specs/axis_overlay_bbox-arch.md) | Rectangle overlay on RGB video |
| [`rgb2ycrcb-arch.md`](docs/specs/rgb2ycrcb-arch.md) | RGB888 → Y8 color-space converter |
| [`ram-arch.md`](docs/specs/ram-arch.md) | Dual-port byte RAM, region descriptor model |
| [`vga_controller-arch.md`](docs/specs/vga_controller-arch.md) | VGA timing generator |

## Project Structure

```
hw/top/
  sparevideo_top.sv    Top-level (AXI4-Stream → CDC → motion pipeline → CDC → VGA)
  sparevideo_pkg.sv    Package: shared parameters and types
  ram.sv               Generic true-dual-port byte RAM (behavioral, sim-only)
hw/ip/rgb2ycrcb/rtl/
  rgb2ycrcb.sv         RGB888 → YCrCb converter (Rec.601, 8-bit fixed-point, 2-cycle pipeline)
hw/ip/motion/rtl/
  axis_motion_detect.sv  Motion mask generator + RGB passthrough (1-cycle pipeline)
  axis_bbox_reduce.sv    Mask → bounding-box accumulator
  axis_overlay_bbox.sv   Bounding-box rectangle overlay on RGB video
hw/ip/vga/rtl/
  vga_controller.sv    VGA controller (instantiated in sparevideo_top)
  pattern_gen.sv       Test pattern generator (retained, unused)
hw/lint/
  verilator_waiver.vlt        Project lint waivers
  third_party_waiver.vlt      Lint waivers for vendored third-party RTL
third_party/verilog-axis/
  rtl/                 Vendored alexforencich/verilog-axis (MIT)
hw/ip/rgb2ycrcb/tb/
  tb_rgb2ycrcb.sv      Unit TB: RGB→YCrCb corner-case checks
hw/ip/motion/tb/
  tb_axis_motion_detect.sv  Unit TB: motion mask correctness + pipeline stall test
  tb_axis_bbox_reduce.sv    Unit TB: bbox accumulation, bbox_empty
  tb_axis_overlay_bbox.sv   Unit TB: rectangle pixel selection
dv/sv/
  tb_sparevideo.sv     Unified top-level testbench (RTL sim + SW dry-run)
  tb_utils.c           DPI-C helper: wall-clock time via clock_gettime (Verilator)
dv/sim/
  Makefile             Simulation targets
dv/data/               Generated input/output files (gitignored)
py/
  harness.py           Pipeline harness CLI (prepare / verify / render)
  frames/
    frame_io.py        Read/write text and binary frame files
    video_source.py    Load video from MP4/PNG/synthetic sources
  viz/
    render.py          Render input/output comparison image grid
py/tests/
  test_frame_io.py     Unit tests for frame I/O round-trips
plans/old/             Implemented design plans (timestamped)
```

## Prerequisites

- **Verilator** 5.0+ (simulation and linting)
- **GCC** (Verilator uses it internally)
- **Python** 3.10+ with venv
- **GTKWave** (optional, waveform viewer)

## Setup

```bash
# Install Verilator, GCC, and GTKWave
sudo apt install -y verilator gcc gtkwave

# Create Python venv and install deps
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# Or use the setup target:
make setup
```

## Usage

```bash
# Run the full pipeline: prepare → compile → sim → verify → render
make run-pipeline

# With custom source and options
make run-pipeline SOURCE="synthetic:moving_box" FRAMES=8 TOLERANCE=10000
make run-pipeline SOURCE=path/to/video.mp4 MODE=binary

# Run per-block IP unit testbenches (fast, Verilator)
make test-ip

# Lint only
make lint
```

`make run-pipeline` runs these steps in order, passing all options automatically:

| Step | Target | Description |
|------|--------|-------------|
| 1 | `prepare` | Generate input frames — **saves options** to `dv/data/config.mk` |
| 2 | `compile` | Compile RTL + testbench |
| 3 | `sim` | Run RTL simulation |
| 4 | `verify` | Check output against input within tolerance |
| 5 | `render` | Save input vs output comparison PNG |

### Running steps individually

`make prepare` saves `WIDTH`, `HEIGHT`, `FRAMES`, and `MODE` to `dv/data/config.mk`. All subsequent steps load that file automatically:

```bash
make prepare SOURCE="synthetic:moving_box" WIDTH=320 HEIGHT=240 FRAMES=8
make sim
make verify TOLERANCE=10000
make render
```

`SIMULATOR` and `TOLERANCE` are not saved — specify them explicitly when needed:

| Option | Saved by `prepare`? | Used by |
|--------|:-------------------:|---------|
| `WIDTH` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run` |
| `HEIGHT` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run` |
| `FRAMES` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run` |
| `MODE` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run`, `verify`, `render` |
| `SIMULATOR` | — | `compile`, `sim`, `sim-waves`, `sw-dry-run` |
| `TOLERANCE` | — | `verify` |
| `SOURCE` | ✓ | `prepare` only |

```bash
# Other targets
make lint                    # Verilator lint
make test-ip                 # All per-block IP unit testbenches (Verilator)
make test-ip-rgb2ycrcb       # rgb2ycrcb color-space converter
make test-ip-motion-detect   # axis_motion_detect (Y8 diff + backpressure)
make test-ip-bbox-reduce     # axis_bbox_reduce (bounding box accumulator)
make test-ip-overlay-bbox    # axis_overlay_bbox (bbox rect overlay)
make sw-dry-run              # Bypass RTL — file loopback, zero sim time
make sim-waves               # RTL sim + open GTKWave
make compile                 # Compile only
make test-py                 # Run Python unit tests
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `SIMULATOR` | `verilator` | Simulator to use (`verilator` only; Icarus not maintained) |
| `SOURCE` | `synthetic:color_bars` | Input source (only used by `prepare`). Available: `synthetic:color_bars`, `synthetic:gradient`, `synthetic:checkerboard`, `synthetic:moving_box`, MP4/AVI files (OpenCV), PNG directory |
| `WIDTH` | `320` | Frame width in pixels |
| `HEIGHT` | `240` | Frame height in pixels |
| `FRAMES` | `4` | Number of frames |
| `MODE` | `text` | File format: `text` (hex) or `binary` |
| `TOLERANCE` | `2*(W+H)` | Max differing pixels per frame in `verify`. Default accommodates the frame-0 bounding-box border. Use a higher value (e.g. `10000`) for motion-heavy sources. |

### THRESH (motion detection threshold)

The luma-difference threshold `MOTION_THRESH` is a top-level RTL parameter (default `16`, ≈6.25% intensity). Override at compile time via the testbench plusarg:

```bash
make run-pipeline SIMARGS="+THRESH=32"
```

Pixels where `|Y_cur - Y_prev| > THRESH` are classified as motion.

### File Formats

**Text mode** (`.txt`): Space-separated 6-digit hex pixels (RRGGBB), one row per line. No header.
```
FF0000 FF0000 00FF00 00FF00
FF0000 FF0000 00FF00 00FF00
```

**Binary mode** (`.bin`): 12-byte header (width, height, frames as LE uint32) + raw RGB bytes (3 bytes/pixel, row-major).

## License

Apache License 2.0
