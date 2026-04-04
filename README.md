# sparevideo

VGA display pipeline with cocotb-based verification and display emulation.

## Overview

A VGA controller IP written in SystemVerilog with a streaming ready/valid pixel interface, paired with a test pattern generator. Simulated via Icarus Verilog, verified with a self-checking SV testbench and cocotb, with fast RTL-based frame visualization.

**VGA timing:** 640x480 @ 60Hz, 25 MHz pixel clock, parameterizable blanking/porch values.

## Project Structure

```
hw/ip/vga/rtl/
  vga_controller.sv    VGA controller (streaming pixel input, sync generation)
  pattern_gen.sv       Test pattern generator (color bars, checkerboard, solid, gradient)
hw/top/
  vga_top.sv           Top-level wrapper (pattern_gen → vga_controller)
hw/lint/
  verilator_waiver.vlt Verilator lint waivers
dv/sv/
  tb_vga_top.sv        Self-checking SV testbench (timing + pixel checks)
  tb_vga_viz.sv        Frame dump testbench (writes raw pixel data to file)
dv/cocotb/
  test_vga.py          Cocotb tests (timing verification, pixel spot-checks)
  vga_monitor.py       VGA signal monitor class
  frame_capture.py     PIL-based frame-to-PNG utility
  viz.py               Converts raw binary frame dumps to PNG
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

# Create Python venv and install cocotb + Pillow
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# Or use the setup target (installs iverilog + Python deps):
make setup
```

## Usage

```bash
# Lint all RTL with Verilator
make lint

# Run self-checking SV testbench
make sim-sv

# Run SV testbench with GTKWave waveforms
make sim-sv-waves

# Run cocotb tests (timing + pixel spot-checks)
make sim

# Visualize all 4 patterns — simulates RTL and saves PNGs (~12s)
make viz

# Visualize a single pattern (0-3)
make viz PATTERN=0
```

## Visualization

`make viz` is a two-step pipeline:

1. **Icarus Verilog** compiles and runs `dv/sv/tb_vga_viz.sv` — a dedicated SV testbench that instantiates the actual RTL (`vga_top`), drives the clock, and captures one frame of VGA output by writing raw RGB bytes to a `.bin` file via `$fwrite`. No cocotb/VPI overhead — runs at native simulator speed.

2. **Python (`dv/cocotb/viz.py`)** reads the `.bin` file (921,600 bytes = 640×480×3) and converts it to a PNG using Pillow.

All 4 patterns complete in ~12 seconds. Output PNGs are saved to `dv/cocotb/output/`.

## VGA Controller Interface

The VGA controller accepts pixel data via a streaming ready/valid handshake:

```systemverilog
// Pixel input
input  logic [23:0] pixel_data,    // {R[7:0], G[7:0], B[7:0]}
input  logic        pixel_valid,
output logic        pixel_ready,   // high during active display area

// Sync outputs to upstream
output logic        frame_start,   // pulse at frame start
output logic        line_start,    // pulse at each line start

// VGA output
output logic        vga_hsync,
output logic        vga_vsync,
output logic [7:0]  vga_r, vga_g, vga_b
```

Timing is parameterizable (defaults to 640x480@60Hz):

| Parameter | Default | Description |
|-----------|---------|-------------|
| H_ACTIVE | 640 | Visible pixels per line |
| H_FRONT_PORCH | 16 | Front porch (pixel clocks) |
| H_SYNC_PULSE | 96 | Hsync pulse width |
| H_BACK_PORCH | 48 | Back porch |
| V_ACTIVE | 480 | Visible lines per frame |
| V_FRONT_PORCH | 10 | Front porch (lines) |
| V_SYNC_PULSE | 2 | Vsync pulse width |
| V_BACK_PORCH | 33 | Back porch |

## Test Patterns

Select via `pattern_sel[1:0]`:

| Value | Pattern |
|-------|---------|
| 0 | SMPTE color bars (8 columns) |
| 1 | Checkerboard (8x8 pixel blocks) |
| 2 | Solid red |
| 3 | Red/green gradient |

## License

Apache License 2.0
