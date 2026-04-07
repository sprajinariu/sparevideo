# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commits

Do not include `Co-Authored-By` trailers in commit messages.

## Project Overview

sparevideo is a video processing pipeline project. The top-level design (`sparesoc_top`) accepts RGB video input with hsync/vsync and passes it through a registered pipeline stage. The VGA controller and pattern generator IPs are retained under `hw/ip/vga/` but are not instantiated in the current design — timing generation is handled by the testbench.

All RTL is SystemVerilog (.sv files). Use synthesis-style SV only (no SVA assertions, no interfaces/modports, no classes) for Icarus Verilog 12 compatibility.

## Environment

**The user works directly inside a WSL/Ubuntu terminal.** Run all commands directly (e.g. `make lint`) — do NOT wrap with `wsl bash -lc`.

Python packages (Pillow, numpy, opencv) are in a venv at `.venv/`. Activate with:
```bash
source .venv/bin/activate
```

## Build Commands

```bash
# Full pipeline: prepare → sim → verify → render
make run-pipeline
make run-pipeline SOURCE="synthetic:gradient" MODE=binary

# Individual pipeline steps (e.g. re-run sim after RTL change)
make prepare
make sim
make verify
make render

# Other targets
make lint           # Verilator lint
make sw-dry-run    # Bypass RTL (file loopback, zero sim time)
make sim-waves      # RTL simulation + GTKWave
make setup          # One-time setup (install deps)
```

## Project Structure

- `hw/top/sparesoc_top.sv` — Top-level (video passthrough pipeline, 1-clock delay)
- `hw/ip/vga/rtl/` — VGA controller and pattern generator RTL (retained, not used in top)
- `hw/lint/` — Verilator waiver file
- `dv/sv/tb_sparevideo.sv` — Unified testbench (RTL sim + SW dry-run)
- `dv/sim/Makefile` — Simulation Makefile (compiled .vvp lives in dv/sim/)
- `dv/data/` — Generated input/output files and renders (gitignored)
- `py/harness.py` — Pipeline harness CLI (prepare / verify / render)
- `py/frames/frame_io.py` — Read/write text and binary frame files
- `py/frames/video_source.py` — Load video from MP4/PNG/synthetic, resize, extract frames
- `py/viz/render.py` — Render input/output frames as comparison image grid
- `py/tests/test_frame_io.py` — Unit tests for frame I/O round-trips
- `py/tests/test_vga.py` — Cocotb VGA timing tests (requires VGA IP)
- FuseSoC core files: `sparevideo_top.core`, `hw/ip/vga/vga.core`

## RTL Conventions

- All RTL in SystemVerilog, `.sv` extension
- Use `logic` (not `reg`/`wire`), `always_ff`, `always_comb`
- Avoid part-selects inside `always_comb` blocks (Icarus 12 limitation) — use intermediate `assign` signals
- Active-low reset (`rst_n`), active-low sync signals (`hsync`, `vsync`)
- 8-bit per channel RGB (24-bit color)

## Testbench

The single testbench (`dv/sim/tb_sparevideo.sv`) supports two modes:

**RTL simulation** (default): Generates VGA-like timing (hsync, vsync, blanking), reads input frames from file, drives pixels to the DUT during active region, captures DUT output via a concurrent always block (negedge sampling), writes output to file. Wall-clock elapsed time is printed per frame.

**SW dry-run** (`+sw_dry_run`): Bypasses RTL entirely. File loopback at zero sim time — reads input, writes output directly. Useful for testing the Python harness flow without waiting for RTL sim.

Plusargs: `+INFILE=`, `+OUTFILE=`, `+WIDTH=`, `+HEIGHT=`, `+FRAMES=`, `+MODE=text|binary`, `+sw_dry_run`, `+DUMP_VCD`.

TB blanking parameters are small (H: 4+8+4, V: 2+2+2) to minimize sim time.

**Important**: TB drives signals at `@(posedge clk)` using non-blocking assignments (`<=`). NBA scheduling ensures TB drives land after the DUT's `always_ff` has sampled its inputs in the Active region. The output capture always block samples at `@(negedge clk)` to avoid races with the DUT output.

## Pipeline Harness

- Python prepares input, SV simulates, Python verifies and renders.
- Text mode (`.txt`) uses space-separated 6-digit hex pixels (RRGGBB), one row per line. No headers.
- Binary mode uses a 12-byte header (width, height, frames as LE uint32) followed by raw RGB bytes.
- Frame dimensions flow via plusargs (`+WIDTH=`, `+HEIGHT=`, `+FRAMES=`, `+MODE=`).
- Input sources: MP4/AVI (via OpenCV), PNG directory, or `synthetic:<pattern>` (color_bars, gradient, checkerboard, moving_box).

## TODO after each major change

- Keep CLAUDE.md and README.md up-to-date
- Keep makefiles up-to-date
- Keep requirements.txt up-to-date
- Clean up large files (e.g. VCDs, simulation outputs, binaries), don't upload them to git

## General guidelines

### Workflow

- Always run `make lint` after any RTL change to catch Verilator warnings early.
- After RTL changes, run `make sim` to verify the passthrough pipeline.
- Use `make run-pipeline` for full end-to-end testing (prepare → sim → verify → render).
- Use `make sw-dry-run` to quickly test the Python/SV file I/O flow without RTL simulation.

### RTL changes

- All RTL is in `hw/ip/vga/rtl/` and `hw/top/`. Keep modules small and focused.
- Never use `reg`/`wire` — always `logic`. Never use `always` — always `always_ff` or `always_comb`.
- Do not put bit-selects (e.g. `pixel_x[9:2]`) inside `always_comb` blocks — Icarus 12 rejects them. Use intermediate `assign` signals instead.

### Testbench / verification

- The SV testbench uses `$display`/`if` checks — no SVA. Do not introduce `assert` statements (Icarus 12 does not support them).
- Avoid nested automatic tasks with output parameters in Icarus — they silently malfunction. Inline the logic instead.

### Python environment

- All Python tooling runs from the venv at `.venv/`. Never use system Python directly.
- If adding a new Python dependency, add it to `requirements.txt`.
