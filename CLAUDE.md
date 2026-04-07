# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commits

Do not include `Co-Authored-By` trailers in commit messages.

## Project Overview

sparevideo is a video processing pipeline project. The top-level design (`sparesoc_top`) accepts an AXI4-Stream video input on a 25 MHz pixel clock, crosses into a 100 MHz DSP clock domain via a vendored `axis_async_fifo`, runs through a 4-stage `axis_register` slice chain (placeholder for real processing), crosses back to the pixel clock, and drives the instantiated `vga_controller` to produce RGB + hsync/vsync. The VGA controller is now part of the DUT; the testbench drives AXI4-Stream input and captures VGA output.

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

- `hw/top/sparesoc_top.sv` — Top-level (AXI4-Stream → CDC → 4-stage proc → CDC → vga_controller)
- `hw/ip/vga/rtl/` — VGA controller (instantiated in top) and pattern generator (retained, unused)
- `hw/lint/` — Verilator waiver files (project + third-party)
- `third_party/verilog-axis/` — Vendored alexforencich/verilog-axis (MIT) AXI4-Stream library
- `dv/sv/tb_sparevideo.sv` — Unified testbench (RTL sim + SW dry-run)
- `dv/sim/Makefile` — Simulation Makefile (compiled .vvp lives in dv/sim/)
- `dv/data/` — Generated input/output files and renders (gitignored)
- `py/harness.py` — Pipeline harness CLI (prepare / verify / render)
- `py/frames/frame_io.py` — Read/write text and binary frame files
- `py/frames/video_source.py` — Load video from MP4/PNG/synthetic, resize, extract frames
- `py/viz/render.py` — Render input/output frames as comparison image grid
- `py/tests/test_frame_io.py` — Unit tests for frame I/O round-trips
- `py/tests/test_vga.py` — Cocotb VGA timing tests (requires VGA IP)
- FuseSoC core files: `sparevideo_top.core`, `hw/ip/vga/vga.core`, `verilog-axis.core`

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
- After implementing a plan, move it to plans/old/ and put a date timestamp on it to have a history on what has been implemented.

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

### Debugging a failing simulation

Claude can't view GTKWave, but VCD is plain text and fully debuggable from the terminal. Workflow:

1. **Diff the output files first.** `head -1 dv/data/input.txt` vs `head -1 dv/data/output.txt`, or `xxd | head` for binary mode. An off-by-one, a stuck channel, or a wrong polarity is usually obvious from a few pixels.
2. **Reason from the RTL.** Re-read the relevant `always_ff` and check what's combinational vs registered, especially across module boundaries (`pixel_ready` is combinational, `vga_r` is registered → one-cycle skew at capture time).
3. **Scoped VCD dump.** If steps 1–2 don't localize it, narrow `$dumpvars` to the smallest interesting scope (e.g. `$dumpvars(0, tb_sparevideo.u_dut.u_vga)`) so the VCD stays small, then `make sim-waves`.
4. **Read the VCD as text.** VCD is a header (signal declarations with short IDs) followed by `#<time>` markers and value changes. `grep` for a specific signal ID, or write a tiny Python script (use `.venv`) to parse and print a focused table of `(time, signalA, signalB, ...)` around the window of interest. This turns "thousands of cycles" into a 20-row table.
5. **Last resort: open GTKWave locally.** `make sim-waves` opens it for the human; Claude won't see it but can still iterate based on what the user reports.

### Python environment

- All Python tooling runs from the venv at `.venv/`. Never use system Python directly.
- If adding a new Python dependency, add it to `requirements.txt`.
