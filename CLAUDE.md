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

### Workflow

- Always run `make lint` after any RTL change to catch Verilator warnings early.
- After RTL changes, run `make sim-sv` to verify basic timing and pixel correctness before touching cocotb.
- Use `make viz` (or `make viz PATTERN=N`) to visually verify output — it's the fastest feedback loop (~3s/pattern).
- Run `make sim` (cocotb) for final verification — it takes a few minutes, so don't run it on every iteration.

### RTL changes

- All RTL is in `hw/ip/vga/rtl/` and `hw/top/`. Keep modules small and focused.
- Never use `reg`/`wire` — always `logic`. Never use `always` — always `always_ff` or `always_comb`.
- Do not put bit-selects (e.g. `pixel_x[9:2]`) inside `always_comb` blocks — Icarus 12 rejects them. Use intermediate `assign` signals instead.
- Adding a new pattern: edit `pattern_gen.sv` and add a new case in the `always_comb` pattern mux. Update `tb_vga_top.sv` pixel spot-checks, `test_vga.py`, `README.md`, and `CLAUDE.md` timing tables if needed.

### Testbench / verification

- The SV testbench (`dv/sv/tb_vga_top.sv`) uses `$display`/`$error` and `if` checks — no SVA. Do not introduce `assert` statements (Icarus 12 does not support them in this context).
- cocotb tests use edge triggers (`FallingEdge`, `RisingEdge`) for timing and `ClockCycles` for bulk navigation to pixel positions. Avoid per-clock polling loops — they are too slow with Icarus VPI.
- Do not add per-frame pixel capture in cocotb — use `make viz` (SV `$fwrite` path) for visual output instead.

### Visualization

- `make viz` runs two steps: (1) Icarus simulates `tb_vga_viz.sv` and dumps a raw `.bin`, (2) Python `viz.py` converts to PNG. Both must stay consistent with the frame format (3 bytes/pixel, row-major, 640×480).
- Output PNGs go to `dv/cocotb/output/` which is gitignored. Do not commit `.bin` or `.png` files.

### Python environment

- All Python tooling runs from the venv at `.venv/`. Never use system Python directly.
- The root Makefile prepends `.venv/bin` to PATH before invoking cocotb sub-make — don't remove this.
- If adding a new Python dependency, add it to `requirements.txt`.
