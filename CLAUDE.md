# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commits

Do not include `Co-Authored-By` trailers in commit messages.

## Project Overview

sparevideo is a video processing pipeline project. The top-level design (`sparevideo_top`) accepts an AXI4-Stream video input on a 25 MHz pixel clock, crosses into a 100 MHz DSP clock domain via a vendored `axis_async_fifo`, runs through a control-flow-selectable processing pipeline (passthrough, motion detection with bounding-box overlay, or mask display), crosses back to the pixel clock, and drives the instantiated `vga_controller` to produce RGB + hsync/vsync. The VGA controller is now part of the DUT; the testbench drives AXI4-Stream input and captures VGA output. A top-level 2-bit `ctrl_flow_i` sideband signal selects the active processing path; the TB drives it via the `+CTRL_FLOW=` plusarg.

All RTL is SystemVerilog (.sv files). Use synthesis-style SV only (no SVA assertions, no interfaces/modports, no classes) for Icarus Verilog 12 compatibility.

## Environment

**The user works directly inside a WSL/Ubuntu terminal.** Run all commands directly (e.g. `make lint`) — do NOT wrap with `wsl bash -lc`.

Python packages (Pillow, numpy, opencv) are in a venv at `.venv/`. Activate with:
```bash
source .venv/bin/activate
```

## Build Commands

```bash
# Full pipeline: prepare → compile → sim → verify → render
make run-pipeline
make run-pipeline SOURCE="synthetic:gradient" MODE=binary SIMULATOR=verilator

# Control flow selection (default: motion)
make run-pipeline CTRL_FLOW=passthrough TOLERANCE=0   # no processing, exact match
make run-pipeline CTRL_FLOW=motion                    # motion detect + bbox overlay
make run-pipeline CTRL_FLOW=mask                      # raw motion mask, B/W output

# 'make prepare' saves WIDTH/HEIGHT/FRAMES/MODE/CTRL_FLOW/ALPHA_SHIFT to dv/data/config.mk.
# Subsequent steps load it automatically — no need to repeat options.
make prepare SOURCE="synthetic:gradient" WIDTH=640 HEIGHT=480 FRAMES=8 MODE=binary
make sim                     # uses saved options

# EMA background model tuning (ALPHA_SHIFT is a compile-time Verilator parameter)
make run-pipeline SOURCE="synthetic:noisy_moving_box" CTRL_FLOW=mask ALPHA_SHIFT=2 FRAMES=8

# Other targets
make lint                    # Verilator lint
make test-ip                 # Per-block unit testbenches (Verilator)
make sw-dry-run              # Bypass RTL (file loopback, zero sim time)
make sim-waves               # RTL sim + GTKWave
make setup                   # One-time setup (install deps)
```

> **Note:** Verilator simulation previously had a race condition — `tuser` was sampled as 0 on the posedge of `clk_pix` due to INITIALDLY (NBA-in-initial-block treated as blocking). Fixed by introducing `drv_*` intermediary signals written with blocking `=` in the initial block, and an `always_ff @(negedge clk_pix)` as the sole driver of `s_axis_*`. Driving on negedge ensures DUT inputs are stable at the posedge sampling point.

## Project Structure

- `hw/top/sparevideo_pkg.sv` — Project-wide package: parameters, types, region descriptors, control flow constants
- `hw/top/sparevideo_top.sv` — Top-level (AXI4-Stream → CDC → control-flow mux → CDC → vga_controller)
- `hw/ip/axis/rtl/` — Reusable AXI4-Stream utilities (axis_fork_pipe: 1-to-2 fork with sideband pipeline)
- `hw/ip/gauss3x3/rtl/` — 3x3 Gaussian pre-filter on Y channel (axis_gauss3x3: line buffers + adder tree)
- `hw/ip/motion/rtl/` — Motion detection pipeline (axis_motion_detect, motion_core, axis_bbox_reduce, axis_overlay_bbox)
- `hw/ip/vga/rtl/` — VGA controller (instantiated in top) and pattern generator (retained, unused)
- `hw/lint/` — Verilator waiver files (project + third-party)
- `third_party/verilog-axis/` — Vendored alexforencich/verilog-axis (MIT) AXI4-Stream library
- `dv/sv/tb_sparevideo.sv` — Unified testbench (RTL sim + SW dry-run, `ifdef VERILATOR` for DPI-C wall-clock)
- `dv/sv/tb_utils.c` — DPI-C helper: `get_wall_ms()` via `clock_gettime` (used by Verilator path)
- `dv/sim/Makefile` — Simulation Makefile (compiled .vvp lives in dv/sim/)
- `dv/data/` — Generated input/output files and renders (gitignored)
- `py/harness.py` — Pipeline harness CLI (prepare / verify / render)
- `py/frames/frame_io.py` — Read/write text and binary frame files
- `py/frames/video_source.py` — Load video from MP4/PNG/synthetic, resize, extract frames
- `py/models/` — Control-flow reference models for pixel-accurate verification
- `py/models/passthrough.py` — Passthrough model (identity)
- `py/models/motion.py` — Motion pipeline model (luma, mask, bbox, overlay)
- `py/models/mask.py` — Mask display model (luma, mask, B/W expansion)
- `py/viz/render.py` — Render input/output frames as comparison image grid
- `py/tests/test_frame_io.py` — Unit tests for frame I/O round-trips
- `py/tests/test_models.py` — Unit tests for control-flow reference models
- `py/tests/test_vga.py` — Cocotb VGA timing tests (requires VGA IP)
- FuseSoC core files: `sparevideo_top.core`, `hw/ip/axis/axis.core`, `hw/ip/motion/motion.core`, `hw/ip/vga/vga.core`, `verilog-axis.core`

## RTL Conventions

- All RTL in SystemVerilog, `.sv` extension
- Use `logic` (not `reg`/`wire`), `always_ff`, `always_comb`
- Active-low reset (`rst_n`), active-low sync signals (`hsync`, `vsync`)
- 8-bit per channel RGB (24-bit color)
- **All configuration parameters and shared types go in `hw/top/sparevideo_pkg.sv`.** Module parameter defaults reference the package. Do not hardcode constants that belong in the package elsewhere.

## Testbench

The single testbench (`dv/sim/tb_sparevideo.sv`) supports two modes:

**RTL simulation** (default): Generates VGA-like timing (hsync, vsync, blanking), reads input frames from file, drives pixels to the DUT during active region, captures DUT output via a concurrent always block (negedge sampling), writes output to file. Wall-clock elapsed time is printed per frame.

**SW dry-run** (`+sw_dry_run`): Bypasses RTL entirely. File loopback at zero sim time — reads input, writes output directly. Useful for testing the Python harness flow without waiting for RTL sim.

Plusargs: `+INFILE=`, `+OUTFILE=`, `+WIDTH=`, `+HEIGHT=`, `+FRAMES=`, `+MODE=text|binary`, `+CTRL_FLOW=passthrough|motion|mask`, `+sw_dry_run`, `+DUMP_VCD`.

TB blanking parameters are small (H: 4+8+4, V: 2+2+2) to minimize sim time.

**Important**: TB drives signals at `@(posedge clk)` using non-blocking assignments (`<=`). NBA scheduling ensures TB drives land after the DUT's `always_ff` has sampled its inputs in the Active region. The output capture always block samples at `@(negedge clk)` to avoid races with the DUT output.

## Pipeline Harness

- Python prepares input, SV simulates, Python verifies and renders.
- Verification is model-based: `make verify` computes expected output using a Python reference model for the active control flow, then compares RTL output pixel-by-pixel at TOLERANCE=0.
- Each control flow has a reference model in `py/models/` (dispatch via `run_model(ctrl_flow, frames)`). Models are spec-driven — they implement the intended algorithm, not an RTL transcription. If the RTL disagrees with the model, the RTL is wrong.
- Text mode (`.txt`) uses space-separated 6-digit hex pixels (RRGGBB), one row per line. No headers.
- Binary mode uses a 12-byte header (width, height, frames as LE uint32) followed by raw RGB bytes.
- Frame dimensions flow via plusargs (`+WIDTH=`, `+HEIGHT=`, `+FRAMES=`, `+MODE=`).
- Input sources: MP4/AVI (via OpenCV), PNG directory, or `synthetic:<pattern>` (color_bars, gradient, checkerboard, moving_box, moving_box_h, moving_box_v, moving_box_reverse, dark_moving_box, two_boxes, noisy_moving_box, lighting_ramp).

## Skills

Detailed task-specific guidance lives in `.claude/skills/`. Invoke the relevant skill at the start of a task:

| Skill | When to use |
|-------|-------------|
| `rtl-writing` | Writing, editing, or reviewing any `.sv` RTL file — covers file template, signal naming, always block rules, lint |
| `hardware-arch-doc` | Before implementing any new module — produces the arch doc that becomes the contract for the RTL |
| `hardware-testing` | Writing unit testbenches (`hw/ip/*/tb/`) or integration tests (`dv/sv/`) — covers `drv_*` pattern, Makefile wiring, Layer 2 rules |
| `software-testing` | Writing Python reference models (`py/models/`) or model tests — covers model design, bit-accuracy, adding new control flows |

## TODO after each major change

- Keep CLAUDE.md and README.md up-to-date
- Keep makefiles up-to-date
- Keep requirements.txt up-to-date
- Clean up large files (e.g. VCDs, simulation outputs, binaries), don't upload them to git
- After implementing a plan, move it to docs/plans/old/ and put a date timestamp on it to have a history on what has been implemented.

## General guidelines

### Workflow

- Always run `make lint` after any RTL change to catch Verilator warnings early.
- After RTL changes, run `make sim` to verify the passthrough pipeline.
- Use `make run-pipeline` for full end-to-end testing (prepare → sim → verify → render).
- Use `make sw-dry-run` to quickly test the Python/SV file I/O flow without RTL simulation.

### RTL changes

- All RTL is in `hw/ip/vga/rtl/` and `hw/top/`. Keep modules small and focused.
- Never use `reg`/`wire` — always `logic`. Never use `always` — always `always_ff` or `always_comb`.

### Testbench / verification

- The SV testbench uses `$display`/`if` checks — no SVA. `assert` is fine for Verilator but is not used by convention in this repo.
- Simulator: **Verilator only** for all required checks. Icarus commands exist in the Makefile but are not maintained and will likely fail.

### Debugging a failing simulation

Claude can't view GTKWave, but VCD is plain text and fully debuggable from the terminal. Workflow:

1. **Diff the output files first.** `head -1 dv/data/input.txt` vs `head -1 dv/data/output.txt`, or `xxd | head` for binary mode. An off-by-one, a stuck channel, or a wrong polarity is usually obvious from a few pixels.
2. **Reason from the RTL.** Re-read the relevant `always_ff` and check what's combinational vs registered, especially across module boundaries (`pixel_ready` is combinational, `vga_r` is registered → one-cycle skew at capture time).
3. **Scoped VCD dump.** If steps 1–2 don't localize it, narrow `$dumpvars` to the smallest interesting scope (e.g. `$dumpvars(0, tb_sparevideo.u_dut.u_vga)`) so the VCD stays small, then `make sim-waves`.
4. **Read the VCD as text.** VCD is a header (signal declarations with short IDs) followed by `#<time>` markers and value changes. `grep` for a specific signal ID, or write a tiny Python script (use `.venv`) to parse and print a focused table of `(time, signalA, signalB, ...)` around the window of interest. This turns "thousands of cycles" into a 20-row table.
5. **Last resort: open GTKWave locally.** `make sim-waves` opens it for the human; Claude won't see it but can still iterate based on what the user reports.

### AXI4-Stream pipeline stall — known pitfalls

When adding a backpressure (`tready`)-capable pipeline stage, three things must all be held simultaneously during a stall; missing any one corrupts data silently:

**1. Sideband pipeline registers must be gated.**
Add `pipe_stall = tvalid_pipe[PIPE_STAGES-1] && !both_done`. Gate every pipeline `always_ff` with `else if (!pipe_stall)` so the registers don't overwrite valid data when the downstream isn't ready.

**2. Combinational signals fed from the live input must be re-sourced from held registers.**
In `axis_motion_detect`, `rgb2ycrcb` takes `s_axis_tdata` as input (1-cycle latency). The upstream source is free to change `tdata` immediately after acceptance (AXI spec). If the source presents the next pixel before the stall clears, `y_cur` reflects the wrong pixel by the next cycle. Fix: MUX the rgb2ycrcb input — use `tdata_pipe[PIPE_STAGES-1]` (held) when `pipe_stall=1`, and `s_axis_tdata` when `pipe_stall=0`.

**3. RAM read address must be held during stall.**
`pix_addr_reg` advances (and may wrap to 0) as soon as the last pixel of a frame is accepted, even if the pipeline is still stalled on that pixel. The combinational `mem_rd_addr = pix_addr` then reads a different address, changing `mem_rd_data`. Fix: register `pix_addr_hold` with enable `!pipe_stall`; drive `mem_rd_addr` from `pix_addr_hold` when stalled.

**4. Memory write-back must be gated on the actual handshake.**
`mem_wr_en` must be `tvalid_pipe[PIPE_STAGES-1] && both_done` — not just `tvalid_pipe[PIPE_STAGES-1]`. Without the gate, the RAM write fires every cycle a pixel is stalled at the output, duplicating writes (idempotent but incorrect for any non-idempotent future write path).

**5. 1-to-N output forks must use per-output acceptance tracking.**
When a module has multiple AXI4-Stream outputs driven from the same pipeline (e.g. `axis_motion_detect`'s vid + mask), simply ANDing all `tready` signals for `both_ready` is insufficient. If only one consumer stalls, the other sees `tvalid && tready` every cycle and re-accepts the same beat — corrupting data and desyncing position counters. Fix: track per-output acceptance with registered flags (`vid_accepted`, `msk_accepted`), gate each output's `tvalid` with `!accepted`, and advance the pipeline only when all outputs are done. Pattern from verilog-axis `axis_broadcast`. See `axis_motion_detect.sv` for the implementation.

**6. Unit-test consumer stalls explicitly — including asymmetric stalls.**
The default TB wires `vid_tready = 1'b1`. Add test frames that (a) periodically deassert both readies (symmetric stall), and (b) stall only one consumer while the other stays ready (asymmetric stall). Verify data correctness in both cases. Without asymmetric stall tests, fork desync bugs go undetected.

### Input/output rate mismatch — blanking

The VGA controller inserts horizontal and vertical blanking after each active region; during blanking it does not consume pixels from the output FIFO. If the AXI4-Stream input drives pixels continuously at 1 pixel/clk with no blanking gaps, the output FIFO fills faster than the VGA drains it and will eventually overflow.

Fix: the top-level TB input driver must mirror VGA timing — insert `H_BLANK` idle cycles (tvalid=0) after each active row and `V_BLANK × H_TOTAL` idle cycles after the last row of each frame. This keeps the long-term input rate equal to the VGA consumption rate.

The SVAs `assert_fifo_in_not_full` and `assert_fifo_out_not_full` (in `sparevideo_top.sv`) catch this at simulation time before the overflow becomes a silent data-loss bug.

### axis_async_fifo depth signals

`s_status_depth` (write-clock domain) and `m_status_depth` (read-clock domain) do NOT include the internal output-pipeline FIFO (~16 entries with default `RAM_PIPELINE=2`). The reported depth can therefore be 0 while up to 16 entries are in-flight on the read side. Keep this in mind when using depth for flow-control thresholds.

### Motion pipeline — lessons learned

These apply to any future motion pipeline block (Gaussian, morphology, CCL, adaptive threshold).

**No first-frame priming.** Writing raw `y_cur` to RAM on frame 0 causes departure ghosts: foreground objects in frame 0 get committed to the background, and when they move, the ghost persists for `~1/alpha` frames. The EMA starts from zero and converges naturally. The bbox is already suppressed for the first 2 frames, so the convergence cost is acceptable.

**Compile-time RTL parameters must propagate through the full Makefile chain.** Any new `-G` parameter (e.g., KERNEL_SIZE, MAX_LABELS) needs: top Makefile `?=` default → SIM_VARS → dv/sim/Makefile `?=` default → VLT_FLAGS `-G` → tb_sparevideo.sv parameter → DUT. The config stamp in dv/sim/Makefile must include it so parameter changes trigger recompilation.

**Synthetic test patterns must exercise the feature meaningfully.** Rule of thumb for noise patterns: `2 × noise_amplitude > THRESH` for EMA to demonstrate value over raw differencing. The `noisy_moving_box` pattern uses `noise_amplitude=10` vs `THRESH=16`.

**Departure ghosts are inherent to EMA.** When an object moves, pixels at its old position show as motion until the background converges back (~`1/alpha` frames). This is the trade-off for noise suppression, not a bug.

**Verify all control flows × parameter combinations.** After any motion pipeline change, test the matrix: all 3 control flows (passthrough, motion, mask) × multiple ALPHA_SHIFT values (0,1,2,3) × multiple sources at TOLERANCE=0.

### Python environment

- All Python tooling runs from the venv at `.venv/`. Never use system Python directly.
- If adding a new Python dependency, add it to `requirements.txt`.
