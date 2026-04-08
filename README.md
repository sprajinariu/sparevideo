# sparevideo

Video processing pipeline with file-based verification harness.

## Overview

A video passthrough pipeline written in SystemVerilog, verified via Icarus Verilog and Verilator with a file-based Python harness. The top-level design (`sparesoc_top`) accepts an **AXI4-Stream** video input on a 25 MHz pixel clock, crosses into a 100 MHz DSP clock domain via a vendored `axis_async_fifo`, runs through a 4-stage `axis_register` slice chain (placeholder for real processing), crosses back, and drives the instantiated `vga_controller` to produce RGB + hsync/vsync. The testbench drives AXI4-Stream input and captures the VGA output.

## Project Structure

```
hw/top/
  sparesoc_top.sv      Top-level (AXI4-Stream → CDC → 4-stage proc → CDC → VGA)
hw/ip/vga/rtl/
  vga_controller.sv    VGA controller (instantiated in sparesoc_top)
  pattern_gen.sv       Test pattern generator (retained, unused)
hw/lint/
  verilator_waiver.vlt        Project lint waivers
  third_party_waiver.vlt      Lint waivers for vendored third-party RTL
third_party/verilog-axis/
  rtl/                 Vendored alexforencich/verilog-axis (MIT)
  LICENSE README.md COMMIT
dv/sv/
  tb_sparevideo.sv     Unified testbench (RTL sim + SW dry-run)
  tb_utils.c           DPI-C helper: wall-clock time via clock_gettime (Verilator)
dv/sim/
  Makefile             Simulation targets (Icarus and Verilator)
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
plans/
  current.md           Active work items
  prio2_switch_from_icarus_to_verilator.md
```

## Prerequisites

- **Icarus Verilog** 12.0+ (simulation)
- **Verilator** 5.0+ (simulation and linting)
- **GCC** (builds DPI-C shared library for Icarus; Verilator uses it internally)
- **FuseSoC** (build management)
- **Python** 3.10+ with venv
- **GTKWave** (optional, waveform viewer)

## Setup

```bash
# Install Icarus Verilog, Verilator, GCC, and GTKWave
sudo apt install -y iverilog verilator gcc gtkwave

# Install FuseSoC
pip install fusesoc

# Create Python venv and install deps
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# Or use the setup target:
make setup
```

## Usage

```bash
# Run the full pipeline: prepare → sim → verify → render
make run-pipeline

# With custom source and options
make run-pipeline SOURCE="synthetic:gradient" FRAMES=8
make run-pipeline SOURCE=path/to/video.mp4 MODE=binary

# Use Verilator instead of Icarus (~23x faster)
make run-pipeline SIMULATOR=verilator
```

`make run-pipeline` runs these steps in order, passing all options automatically:

```bash
make run-pipeline SOURCE="synthetic:gradient" WIDTH=640 HEIGHT=480 FRAMES=8 MODE=binary
```

| Step | Target | Description |
|------|--------|-------------|
| 1 | `prepare` | Generate input frames — **saves options** to `dv/data/config.mk` |
| 2 | `compile` | Compile RTL + testbench |
| 3 | `sim` | Run RTL simulation |
| 4 | `verify` | Check output matches input (passthrough) |
| 5 | `render` | Save input vs output comparison PNG |

### Running steps individually

`make prepare` saves `WIDTH`, `HEIGHT`, `FRAMES`, and `MODE` to `dv/data/config.mk`. All subsequent steps load that file automatically, so you don't need to repeat options:

```bash
# Prepare once with custom options
make prepare SOURCE="synthetic:gradient" WIDTH=640 HEIGHT=480 FRAMES=8 MODE=binary

# Subsequent steps just work — options are read from config.mk
make sim
make verify
make render

# Re-run sim after an RTL change
make sim

# Override a saved option on the command line (command-line always wins)
make sim SIMULATOR=icarus
```

`SIMULATOR` is not saved — specify it explicitly when needed:

| Option | Saved by `prepare`? | Used by |
|--------|:-------------------:|---------|
| `WIDTH` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run` |
| `HEIGHT` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run` |
| `FRAMES` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run` |
| `MODE` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run`, `verify`, `render` |
| `SIMULATOR` | — | `compile`, `sim`, `sim-waves`, `sw-dry-run` |
| `SOURCE` | ✓ | `prepare` only |

```bash
# Other targets
make lint                           # Verilator lint
make sw-dry-run                     # Bypass RTL — file loopback, zero sim time
make sim-waves                      # RTL sim + open GTKWave
make compile                        # Compile only
make test-py                        # Run Python unit tests
```

## Simulator Comparison

Select with `SIMULATOR=verilator` (default) or `SIMULATOR=icarus`.
Wall-clock comparison for a simple design:

| | Icarus | Verilator |
|---|---|---|
| Wall-clock (4 frames, 320×240) | ~2m 54s | ~7.5s |
| Speedup | 1× | ~23× |
| Per-frame timing | N/A | DPI-C `clock_gettime` |
| 4-state logic (X/Z) | Yes | No (2-state) |

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `SIMULATOR` | `verilator` | Simulator to use: `verilator` or `icarus` |
| `SOURCE` | `synthetic:color_bars` | Input source (only used by `prepare`). Available patterns: `synthetic:color_bars`, `synthetic:gradient`, `synthetic:checkerboard`, `synthetic:moving_box`, **MP4/AVI video files** (extracts and resizes frames via OpenCV), **PNG directory** (loads and resizes images) |
| `WIDTH` | `320` | Frame width in pixels |
| `HEIGHT` | `240` | Frame height in pixels |
| `FRAMES` | `4` | Number of frames |
| `MODE` | `text` | File format: `text` (hex) or `binary` |

### File Formats

**Text mode** (`.txt`): Space-separated 6-digit hex pixels (RRGGBB), one row per line. No header.
```
FF0000 FF0000 00FF00 00FF00
FF0000 FF0000 00FF00 00FF00
```

**Binary mode** (`.bin`): 12-byte header (width, height, frames as LE uint32) + raw RGB bytes (3 bytes/pixel, row-major).

## Running Python Tests

```bash
make test-py
```

## Design Interface

```systemverilog
module sparesoc_top #(
    parameter int H_ACTIVE      = 320,
    parameter int H_FRONT_PORCH = 4,
    parameter int H_SYNC_PULSE  = 8,
    parameter int H_BACK_PORCH  = 4,
    parameter int V_ACTIVE      = 240,
    parameter int V_FRONT_PORCH = 2,
    parameter int V_SYNC_PULSE  = 2,
    parameter int V_BACK_PORCH  = 2
) (
    input  logic        clk_pix,        // 25 MHz pixel clock
    input  logic        clk_dsp,        // 100 MHz DSP clock
    input  logic        rst_pix_n,      // active-low reset, clk_pix domain
    input  logic        rst_dsp_n,      // active-low reset, clk_dsp domain

    // AXI4-Stream video input (clk_pix domain)
    input  logic [23:0] s_axis_tdata,   // {R[7:0], G[7:0], B[7:0]}
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,   // end-of-line
    input  logic        s_axis_tuser,   // start-of-frame

    // VGA output (clk_pix domain)
    output logic        vga_hsync,
    output logic        vga_vsync,
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b
);
```

Currently a pure passthrough. The 4-stage `axis_register` chain on `clk_dsp` is the placeholder for real video processing.

## License

Apache License 2.0
