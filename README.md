# sparevideo

Video processing pipeline with file-based verification harness.

## Overview

A video passthrough pipeline written in SystemVerilog, verified via Icarus Verilog with a file-based Python harness. The top-level design (`sparesoc_top`) accepts an **AXI4-Stream** video input on a 25 MHz pixel clock, crosses into a 100 MHz DSP clock domain via a vendored `axis_async_fifo`, runs through a 4-stage `axis_register` slice chain (placeholder for real processing), crosses back, and drives the instantiated `vga_controller` to produce RGB + hsync/vsync. The testbench drives AXI4-Stream input and captures the VGA output.

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
dv/sim/
  Makefile             Simulation targets (compiled .vvp lives here)
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
make sw-dry-run    # Bypass RTL — file loopback, zero sim time
make sim-waves      # RTL simulation + open GTKWave
make test-py        # Run Python unit tests
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

Re-run after changes to Python files (frames/frame_io.py, harness.py, etc.).

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
