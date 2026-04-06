# sparevideo

Video processing pipeline with file-based verification harness.

## Overview

A video passthrough pipeline written in SystemVerilog, verified via Icarus Verilog with a file-based Python harness. The top-level design (`sparesoc_top`) accepts RGB video input with hsync/vsync sync signals and passes it through a registered pipeline stage (1-clock delay). The testbench generates VGA-like timing and handles file I/O.

## Project Structure

```
hw/top/
  sparesoc_top.sv      Top-level (video passthrough pipeline)
hw/ip/vga/rtl/
  vga_controller.sv    VGA controller (retained, not used in top)
  pattern_gen.sv       Test pattern generator (retained, not used in top)
hw/lint/
  verilator_waiver.vlt Verilator lint waivers
dv/sim/
  tb_sparevideo.sv     Unified testbench (RTL sim + SW dry-run)
  Makefile             Simulation targets
dv/data/               Generated input/output files (gitignored)
py/
  harness.py           Pipeline harness CLI (prepare / verify / render)
  frame_io.py          Read/write text and binary frame files
  video_source.py      Load video from MP4/PNG/synthetic sources
  render.py            Render input/output comparison image grid
  viz.py               Converts raw binary frame dumps to PNG
  test_frame_io.py     Unit tests for frame I/O round-trips
```

## Prerequisites

- **Icarus Verilog** 12.0+ (simulation)
- **Verilator** 5.x+ (linting)
- **FuseSoC** (build management)
- **Python** 3.10+ with venv
- **GTKWave** (optional, waveform viewer)

## Setup

```bash
# Install Icarus Verilog, Verilator, and GTKWave
sudo apt install -y iverilog verilator gtkwave

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
```

`make run-pipeline` runs these steps in order:

| Step | Target | Description |
|------|--------|-------------|
| 1 | `make prepare` | Generate input frames from SOURCE |
| 2 | `make sim` | Run RTL simulation (feed input → DUT → capture output) |
| 3 | `make verify` | Check output matches input (passthrough) |
| 4 | `make render` | Save input vs output comparison PNG |

Each step can also be run individually (e.g. re-run `make sim` after an RTL change without re-preparing input).

```bash
# Other targets
make lint           # Verilator lint
make sim-dry-run    # Bypass RTL — file loopback, zero sim time
make sim-waves      # RTL simulation + open GTKWave
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `SOURCE` | `synthetic:color_bars` | Input source |
| `WIDTH` | `320` | Frame width |
| `HEIGHT` | `240` | Frame height |
| `FRAMES` | `4` | Number of frames |
| `MODE` | `text` | File format (`text` or `binary`) |

### Input Sources

- **Synthetic patterns** — `synthetic:color_bars`, `synthetic:gradient`, `synthetic:checkerboard`, `synthetic:moving_box`
- **MP4/AVI video** — extracts and resizes frames via OpenCV
- **PNG directory** — loads and resizes images

### File Formats

**Text mode** (`.dat`): Raw hex bytes, space-separated, one row per line. No header.
```
FF 00 00 FF 00 00 00 FF 00 00 FF 00
FF 00 00 FF 00 00 00 FF 00 00 FF 00
```

**Binary mode** (`.bin`): 12-byte header (width, height, frames as LE uint32) + raw RGB bytes (3 bytes/pixel, row-major).

## Design Interface

```systemverilog
module sparesoc_top (
    input  logic        clk,
    input  logic        rst_n,
    // Video input
    input  logic [23:0] vid_i_data,     // {R[7:0], G[7:0], B[7:0]}
    input  logic        vid_i_valid,
    input  logic        vid_i_hsync,
    input  logic        vid_i_vsync,
    // Video output (1-clock pipeline delay)
    output logic [23:0] vid_o_data,
    output logic        vid_o_valid,
    output logic        vid_o_hsync,
    output logic        vid_o_vsync
);
```

Currently a pure passthrough with a single registered pipeline stage. The design will be extended with video processing in future iterations.

## License

Apache License 2.0
