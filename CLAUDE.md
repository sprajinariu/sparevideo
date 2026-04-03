# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commits

Do not include `Co-Authored-By` trailers in commit messages.

## Project Overview

sparevideo is a VGA display pipeline project. The VGA controller IP accepts pixel data via a streaming ready/valid interface and outputs standard VGA signals (hsync, vsync, RGB). A test pattern generator provides pixel data for verification.

All RTL is SystemVerilog (.sv files). Use synthesis-style SV only (no SVA assertions, no interfaces/modports, no classes) for Icarus Verilog 12 compatibility.

## Environment

**The user works directly inside a WSL/Ubuntu terminal.** Run all commands directly (e.g. `make lint`) — do NOT wrap with `wsl bash -lc`.

Python packages (cocotb, Pillow) are in a venv at `.venv/`. For cocotb simulation, the venv must be on PATH:
```bash
export PATH=$(pwd)/.venv/bin:$PATH
```

## Build Commands

```bash
# Verilator lint
make lint

# Self-checking SV testbench (Icarus Verilog)
make sim-sv

# SV testbench with GTKWave waveforms
make sim-sv-waves

# Cocotb tests — timing verification + pixel spot-checks (~4 min)
make sim

# Visualize all 4 patterns — RTL sim + PNG output (~12s)
make viz

# Visualize a single pattern
make viz PATTERN=0

# One-time setup
make setup
```

## Project Structure

- `hw/ip/vga/rtl/` — VGA controller and pattern generator RTL
- `hw/top/` — Top-level wrapper
- `hw/lint/` — Verilator waiver file
- `dv/sv/tb_vga_top.sv` — Self-checking SV testbench (timing + pixel checks)
- `dv/sv/tb_vga_viz.sv` — Frame dump testbench (raw pixel data to binary file)
- `dv/cocotb/test_vga.py` — Cocotb tests (timing + pixel spot-checks via edge triggers)
- `dv/cocotb/vga_monitor.py` — VGA signal monitor (edge-trigger based, no per-clock polling)
- `dv/cocotb/viz.py` — Converts raw binary frame dumps (.bin) to PNG
- `dv/cocotb/output/` — Generated PNGs (gitignored)
- FuseSoC core files: `sparevideo_top.core`, `hw/ip/vga/vga.core`

## RTL Conventions

- All RTL in SystemVerilog, `.sv` extension
- Use `logic` (not `reg`/`wire`), `always_ff`, `always_comb`
- Avoid part-selects inside `always_comb` blocks (Icarus 12 limitation) — use intermediate `assign` signals
- Active-low reset (`rst_n`), active-low sync signals (`vga_hsync`, `vga_vsync`)
- 8-bit per channel RGB (24-bit color)
- Streaming interfaces use ready/valid handshake

## VGA Timing (640x480@60Hz defaults)

- Pixel clock: 25 MHz (40ns period)
- H total: 800 clocks (640 + 16 + 96 + 48)
- V total: 525 lines (480 + 10 + 2 + 33)
- Frame period: 420,000 clocks

## Testing

SV testbench (`dv/sv/tb_vga_top.sv`):
- Self-checking: verifies hsync/vsync timing and color bar pixel values
- Uses `$display`/`if` checks (no SVA — Icarus compatibility)
- VCD dump via `+DUMP_VCD` plusarg

Cocotb tests (`dv/cocotb/test_vga.py`):
- Timing verification via edge triggers and `get_sim_time()` (fast)
- Pixel spot-checks via `ClockCycles` bulk navigation (fast)
- No per-pixel frame capture in cocotb — too slow with Icarus VPI

## Visualization

`make viz` uses a dedicated SV testbench (`tb_vga_viz.sv`) that runs the RTL at native Icarus speed and dumps raw RGB bytes to a `.bin` file via `$fwrite`. Python (`viz.py`) then converts to PNG. This avoids cocotb/VPI overhead entirely.

- Frame dump format: raw bytes, 3 bytes per pixel (R, G, B), row-major, 640x480
- Plusargs: `+PATTERN=<0-3>`, `+OUTFILE=<path>`, `+FRAMES=<n>`

## TODO after each major change

- Keep CLAUDE.md and README.md up-to-date
- Keep makefiles up-to-date
- Keep requirements.txt up-to-date
- clean-up large files (e.g. VCDs, simulation outputs, binaries), don't upload them to git

## General guidelines
