# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commits

Do not include `Co-Authored-By` trailers in commit messages.

**One branch per plan.** Every plan from `docs/plans/` gets its own fresh branch, created from `origin/main` (after a fetch). Do NOT reuse the branch of a previous plan to start a new one, even if that branch has not yet been merged — start a new branch. Naming: `feat/<topic>`, `refactor/<topic>`, `fix/<topic>`, matching the plan's scope. Never commit plan-related work directly to `main`. If a new plan genuinely depends on an unmerged predecessor branch, create the new branch from that predecessor (not from the main branch) and note the dependency in the PR description.

**Squash at plan completion.** Once a plan is fully implemented and its tests pass, squash all of the plan's commits into a single commit before opening the PR. Before squashing, verify every commit on the branch belongs to the plan being closed — if unrelated commits (adjacent fixes, tangential refactors) have slipped in during execution, move them to their own branch + PR first, then squash only the plan-scoped commits. The squashed commit message should stand on its own as a description of the plan's outcome.

**Exceptions — allowed on any branch, not required to split out.** These kinds of changes may ride along with plan commits and do not need to be moved to their own branch before squashing:

- `README.md` updates
- `CLAUDE.md` updates
- Small general fixes (typos, minor formatting, one-line bug fixes, adjacent `.gitignore` tweaks)

Anything larger than a "small general fix" — or any tangential refactor, unrelated feature work, or structural change — still belongs on its own branch per the rule above.

## Documentation Conventions

All design specs, architecture docs, and implementation plans live under `docs/plans/` — **never** under `docs/superpowers/specs/` or any other skill-default location. Brainstorming specs go to `docs/plans/YYYY-MM-DD-<topic>-design.md`. Implementation plans follow the same `docs/plans/` prefix.

## Project Overview

sparevideo is a video processing pipeline project. The top-level design (`sparevideo_top`) accepts an AXI4-Stream video input, crosses into a 100 MHz DSP clock domain via a vendored `axis_async_fifo`, runs through a control-flow-selectable processing pipeline (passthrough, motion detection with CCL-driven N-way bounding-box overlay, mask display, or a `ccl_bbox` debug mode that shows the mask as a grey canvas under the CCL bboxes), crosses back to the output pixel clock, and drives the instantiated `vga_controller` to produce RGB + hsync/vsync. There are two pixel clock domains: `clk_pix_in_i` (input AXIS, sensor rate) and `clk_pix_out_i` (VGA, display rate); the shared 100 MHz `clk_dsp_i` carries the pipeline. With `SCALER=0` the two pixel clocks are tied together; with `SCALER=1` `clk_pix_out_i` runs at 4x `clk_pix_in_i` so VGA can drain the 2x-scaled output at full rate. The VGA controller is part of the DUT; the testbench drives AXI4-Stream input and captures VGA output. A top-level 2-bit `ctrl_flow_i` sideband signal selects the active processing path; the TB drives it via the `+CTRL_FLOW=` plusarg.

All RTL is SystemVerilog (.sv files). Use synthesis-style SV only (no SVA assertions, no classes) — the project targets Verilator and uses SV interfaces (`axis_if`, `bbox_if`) for AXI-Stream and bbox sideband bundles.

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
make run-pipeline SOURCE="synthetic:moving_box" MODE=binary SIMULATOR=verilator

# Control flow selection (default: motion)
make run-pipeline CTRL_FLOW=passthrough TOLERANCE=0   # no processing, exact match
make run-pipeline CTRL_FLOW=motion                    # motion detect + N-way CCL bbox overlay
make run-pipeline CTRL_FLOW=mask                      # raw motion mask, B/W output
make run-pipeline CTRL_FLOW=ccl_bbox                  # mask-as-grey + CCL bboxes (debug CCL directly)

# Algorithm profile selection (default: default; mirror is OFF in default)
make run-pipeline CFG=default
make run-pipeline CFG=default_hflip          # selfie-cam mirror enabled
make run-pipeline CFG=no_ema                 # alpha=1 → raw frame differencing
make run-pipeline CFG=no_morph               # 3x3 mask opening bypassed
make run-pipeline CFG=no_gauss               # 3x3 Gaussian pre-filter bypassed
make run-pipeline CFG=no_gamma_cor           # sRGB gamma correction bypassed

# 2x output upscaler (compile-time)
make run-pipeline SCALER=0                          # 320x240 output (default, byte-identical to pre-scaler runs)
make run-pipeline SCALER=1 SCALE_FILTER=nn          # 640x480 output, pixel-doubled
make run-pipeline SCALER=1 SCALE_FILTER=bilinear    # 640x480 output, bilinear

# 'make prepare' saves WIDTH/HEIGHT/FRAMES/MODE/CTRL_FLOW/CFG to dv/data/config.mk.
# Subsequent steps load it automatically — no need to repeat options.
make prepare SOURCE="synthetic:moving_box" WIDTH=640 HEIGHT=480 FRAMES=8 MODE=binary
make sim                     # uses saved options

# Other targets
make lint                    # Verilator lint
make test-ip                 # Per-block unit testbenches (Verilator)
make sw-dry-run              # Bypass RTL (file loopback, zero sim time)
make sim-waves               # RTL sim + GTKWave
make setup                   # One-time setup (install deps)
```

> **Adding a tuning knob.** New tunable algorithm parameter? Add a field to `cfg_t` in `hw/top/sparevideo_pkg.sv` and a matching key in every dict in `py/profiles.py`. The TB and Makefiles do not change. The parity test (`py/tests/test_profiles.py`) catches drift between SV and Python.

> **Note:** Verilator simulation previously had a race condition — `tuser` was sampled as 0 on the posedge of `clk_pix` due to INITIALDLY (NBA-in-initial-block treated as blocking). Fixed by introducing `drv_*` intermediary signals written with blocking `=` in the initial block, and an `always_ff @(negedge clk_pix)` as the sole driver of `s_axis_*`. Driving on negedge ensures DUT inputs are stable at the posedge sampling point.

## Project Structure

- `hw/top/sparevideo_pkg.sv` — Project-wide package: parameters, types, region descriptors, control flow constants
- `hw/top/sparevideo_if.sv` — Project-wide SV interfaces: `axis_if` (AXI4-Stream) and `bbox_if` (bbox sideband). Modports: `tx`/`rx`/`mon`.
- `hw/top/sparevideo_top.sv` — Top-level (AXI4-Stream → CDC → control-flow mux → CDC → vga_controller)
- `hw/ip/axis/rtl/` — Reusable AXI4-Stream utilities (axis_fork: zero-latency 1-to-2 broadcast fork with per-output acceptance tracking; axis_async_fifo_ifc: interface-port wrapper around the vendored axis_async_fifo, adapts active-high reset to project rst_n_i convention)
- `hw/ip/hflip/rtl/` — Horizontal mirror (axis_hflip: single line buffer + RECV/XMIT FSM + enable_i bypass; enabled via `hflip_en` field of `cfg_t`)
- `hw/ip/window/rtl/` — Reusable 3x3 sliding-window primitive (axis_window3x3: line buffers + window regs + edge handling; `EDGE_POLICY` parameter, today only `EDGE_REPLICATE=0`). Wrapped by every filter module.
- `hw/ip/filters/rtl/` — Spatial filters over axis_window3x3 (axis_gauss3x3, axis_morph3x3_erode, axis_morph3x3_dilate, axis_morph3x3_open; future: axis_sobel — all land here as peer `.sv` files under one `filters.core`)
- `hw/ip/motion/rtl/` — Motion detection (axis_motion_detect, motion_core)
- `hw/ip/ccl/rtl/` — Streaming connected-components labeling (axis_ccl)
- `hw/ip/overlay/rtl/` — Generic rectangle overlay on RGB video (axis_overlay_bbox)
- `hw/ip/gamma/rtl/` — Per-channel sRGB gamma correction at output tail (axis_gamma_cor: 33-entry LUT + linear interp, 1-cycle skid, enable_i bypass; enabled via `gamma_en` field of `cfg_t`)
- `hw/ip/scaler/rtl/` — 2x spatial upscaler (axis_scale2x: NN + bilinear modes; instantiated under SCALER=1 generate gate; OUT_FIFO_DEPTH bumps to 1024 in scaled mode)
- `hw/ip/vga/rtl/` — VGA controller (instantiated in top) and pattern generator (retained, unused)
- `hw/lint/` — Verilator waiver files (project + third-party)
- `third_party/verilog-axis/` — Vendored alexforencich/verilog-axis (MIT) AXI4-Stream library
- `dv/sv/tb_sparevideo.sv` — Unified testbench (RTL sim + SW dry-run, `ifdef VERILATOR` for DPI-C wall-clock)
- `dv/sv/tb_utils.c` — DPI-C helper: `get_wall_ms()` via `clock_gettime` (used by Verilator path)
- `dv/sim/Makefile` — Simulation Makefile (compiled .vvp lives in dv/sim/)
- `dv/data/` — Generated simulator input/output scratch files (gitignored)
- `renders/` — PNG comparison grids produced by `make render` (gitignored)
- `py/harness.py` — Pipeline harness CLI (prepare / verify / render)
- `py/profiles.py` — Algorithm profile definitions (Python mirror of `cfg_t` and named profiles in `sparevideo_pkg.sv`)
- `py/frames/frame_io.py` — Read/write text and binary frame files
- `py/frames/video_source.py` — Load video from MP4/PNG/synthetic, resize, extract frames
- `py/models/` — Control-flow reference models for pixel-accurate verification
- `py/models/passthrough.py` — Passthrough model (identity)
- `py/models/motion.py` — Motion pipeline model (luma, mask, CCL bboxes, overlay)
- `py/models/mask.py` — Mask display model (luma, mask, B/W expansion)
- `py/models/ccl.py` — Streaming CCL reference model (spec-matched to axis_ccl RTL)
- `py/models/ccl_bbox.py` — ccl_bbox render model (mask-as-grey + CCL bbox overlay)
- `py/viz/render.py` — Render input/output frames as comparison image grid
- `py/tests/test_frame_io.py` — Unit tests for frame I/O round-trips
- `py/tests/test_models.py` — Unit tests for control-flow reference models
- `py/tests/test_profiles.py` — Parity test: verifies Python profile dicts match `cfg_t` field names in `sparevideo_pkg.sv`
- `py/tests/test_vga.py` — Cocotb VGA timing tests (requires VGA IP)
- FuseSoC core files: `sparevideo_top.core`, `hw/ip/axis/axis.core`, `hw/ip/motion/motion.core`, `hw/ip/vga/vga.core`, `verilog-axis.core`

## RTL Conventions

- All RTL in SystemVerilog, `.sv` extension
- Use `logic` (not `reg`/`wire`), `always_ff`, `always_comb`
- Active-low reset (`rst_n`), active-low sync signals (`hsync`, `vsync`)
- 8-bit per channel RGB (24-bit color)
- **All configuration parameters and shared types go in `hw/top/sparevideo_pkg.sv`.** Module parameter defaults reference the package. Do not hardcode constants that belong in the package elsewhere.
- AXI-Stream ports use the `axis_if` interface with modports `tx`/`rx`/`mon`. The bbox sideband from `axis_ccl` to `axis_overlay_bbox` uses `bbox_if`. `clk_i`/`rst_n_i` stay as separate scalar ports on every module — the interface bundle does NOT carry them.
- `axis_window3x3` and `axis_gauss3x3` keep an internal window-style protocol (`valid_i`/`stall_i`/`sof_i`/`busy_o`) — the `axis_` prefix is historical and does NOT mean AXI-Stream. Wrappers (e.g. `axis_morph3x3_*`) use real AXI-Stream and translate at the boundary.

## Testbench

The single testbench (`dv/sim/tb_sparevideo.sv`) supports two modes:

**RTL simulation** (default): Generates VGA-like timing (hsync, vsync, blanking), reads input frames from file, drives pixels to the DUT during active region, captures DUT output via a concurrent always block (negedge sampling), writes output to file. Wall-clock elapsed time is printed per frame.

**SW dry-run** (`+sw_dry_run`): Bypasses RTL entirely. File loopback at zero sim time — reads input, writes output directly. Useful for testing the Python harness flow without waiting for RTL sim.

Plusargs: `+INFILE=`, `+OUTFILE=`, `+WIDTH=`, `+HEIGHT=`, `+FRAMES=`, `+MODE=text|binary`, `+CTRL_FLOW=passthrough|motion|mask|ccl_bbox`, `+CFG_NAME=default|default_hflip|no_ema|no_morph|no_gauss`, `+sw_dry_run`, `+DUMP_VCD`.

TB blanking parameters: H: 4+8+4, V: 2+2+16 (the 16-line V_BLANK absorbs the axis_ccl EOF FSM's worst-case cycle budget).

**Important**: TB drives signals at `@(posedge clk)` using non-blocking assignments (`<=`). NBA scheduling ensures TB drives land after the DUT's `always_ff` has sampled its inputs in the Active region. The output capture always block samples at `@(negedge clk)` to avoid races with the DUT output.

## Pipeline Harness

- Python prepares input, SV simulates, Python verifies and renders.
- Verification is model-based: `make verify` computes expected output using a Python reference model for the active control flow, then compares RTL output pixel-by-pixel at TOLERANCE=0.
- Each control flow has a reference model in `py/models/` (dispatch via `run_model(ctrl_flow, frames)`). Models are spec-driven — they implement the intended algorithm, not an RTL transcription. If the RTL disagrees with the model, the RTL is wrong.
- Text mode (`.txt`) uses space-separated 6-digit hex pixels (RRGGBB), one row per line. No headers.
- Binary mode uses a 12-byte header (width, height, frames as LE uint32) followed by raw RGB bytes.
- Frame dimensions flow via plusargs (`+WIDTH=`, `+HEIGHT=`, `+FRAMES=`, `+MODE=`).
- Input sources: MP4/AVI (via OpenCV), PNG directory, or `synthetic:<pattern>` (moving_box, dark_moving_box, two_boxes, noisy_moving_box, lighting_ramp, textured_static, entering_object, multi_speed, stopping_object, lit_moving_object). All synthetic patterns with moving objects render frame 0 as background-only; objects appear from frame 1 onward to avoid baking foreground into the EMA hard-init bg.

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
- Keep relevant plans/docs/*.md architecture specs up-to-date
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
- Simulator: **Verilator only**.

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
In `axis_motion_detect`, `rgb2ycrcb` takes `s_axis_tdata` as input (1-cycle latency). The upstream source is free to change `tdata` immediately after acceptance (AXI spec). If the source presents the next pixel before the stall clears, `y_cur` reflects the wrong pixel by the next cycle. Fix: capture the last-accepted pixel in a `held_tdata` register; MUX the rgb2ycrcb input — use `held_tdata` when `pipe_stall=1`, and `s_axis_tdata` when `pipe_stall=0`.

**3. RAM read address must be held during stall.**
`pix_addr_reg` advances (and may wrap to 0) as soon as the last pixel of a frame is accepted, even if the pipeline is still stalled on that pixel. The combinational `mem_rd_addr = pix_addr` then reads a different address, changing `mem_rd_data`. Fix: register `pix_addr_hold` with enable `!pipe_stall`; drive `mem_rd_addr` from `pix_addr_hold` when stalled.

**4. Memory write-back must be gated on the actual handshake.**
`mem_wr_en` must be `pipe_valid && m_axis_msk_tready_i` (the real beat-done condition) — not just `pipe_valid`. Without the gate, the RAM write fires every cycle a pixel is stalled at the output, duplicating writes (idempotent but incorrect for any non-idempotent future write path).

**5. 1-to-N output forks at the top level must use per-output acceptance tracking.**
`axis_fork` (`u_fork` in `sparevideo_top`) handles broadcast with registered `a_accepted`/`b_accepted` flags. Simply ANDing all `tready` signals is insufficient — if only one consumer stalls, the other re-accepts the same beat every cycle, corrupting data. `axis_fork` already implements this correctly. When writing a new broadcast module, follow the same pattern.

**6. Unit-test fork consumer stalls explicitly — including asymmetric stalls.**
The default TB wires both readies to `1'b1`. Add test frames that (a) periodically deassert both readies (symmetric stall), and (b) stall only one consumer while the other stays ready (asymmetric stall). Verify data correctness in both cases. Without asymmetric stall tests, fork desync bugs go undetected.

### Input/output rate mismatch — blanking

The VGA controller inserts horizontal and vertical blanking after each active region; during blanking it does not consume pixels from the output FIFO. If the AXI4-Stream input drives pixels continuously at 1 pixel/clk with no blanking gaps, the output FIFO fills faster than the VGA drains it and will eventually overflow.

Fix: the top-level TB input driver must mirror VGA timing — insert `H_BLANK` idle cycles (tvalid=0) after each active row and `V_BLANK × H_TOTAL` idle cycles after the last row of each frame. This keeps the long-term input rate equal to the VGA consumption rate.

The SVAs `assert_fifo_in_not_full` and `assert_fifo_out_not_full` (in `sparevideo_top.sv`) catch this at simulation time before the overflow becomes a silent data-loss bug.

### axis_async_fifo depth signals

`s_status_depth` (write-clock domain) and `m_status_depth` (read-clock domain) do NOT include the internal output-pipeline FIFO (~16 entries with default `RAM_PIPELINE=2`). The reported depth can therefore be 0 while up to 16 entries are in-flight on the read side. Keep this in mind when using depth for flow-control thresholds.

### Motion pipeline — lessons learned

These apply to any future motion pipeline block (Gaussian, morphology, CCL, adaptive threshold).

**Frame-0 hard-init + selective EMA.** The background RAM is primed in frame 0 by writing `y_smooth` directly (mask forced to 0 for that frame), then from frame 1 onward the EMA rate is selected per pixel: `cfg_t.alpha_shift` (fast, α=1/8) when the pixel is *not* flagged as motion, `cfg_t.alpha_shift_slow` (slow, α=1/64) when it *is*. The slow rate on motion pixels prevents foreground contamination (trails) while still absorbing stopped objects over ~1/α_slow frames. This combination supersedes the earlier "no first-frame priming" rule, whose failure mode (departure ghosts from frame-0 foreground) is prevented by the selective rate, not by avoiding priming.

**Grace window prevents frame-0 ghosts.** Hard-init seeds bg from frame 0, so any object present in frame 0 contaminates bg[P_original]. When the object moves in frame 1, raw_motion latches at P_original and the slow selective-EMA rate keeps that ghost alive for ~1/α_slow frames. The `grace_frames` field of `cfg_t` (default 8) forces the fast rate unconditionally for the first K frames after priming — the ghost decays at α=1/8 within K frames, after which the normal selective-EMA rule resumes. Set `grace_frames=0` to disable (recovers pre-grace behavior for regression parity).

**Compile-time RTL parameters are propagated from `CFG.<field>` at the top level.** Algorithm fields (e.g., `alpha_shift`, `alpha_shift_slow`, `grace_frames`, `gauss_en`, `morph_en`, `hflip_en`) are packed into a `cfg_t` struct and driven from the active profile selected by `CFG_NAME`. Inside `axis_motion_detect` they are still compile-time `-G` parameters; the top level unpacks the struct and passes each field as a named parameter. The config stamp in dv/sim/Makefile must include the `CFG` name so profile changes trigger recompilation.

**Synthetic test patterns must exercise the feature meaningfully.** Rule of thumb for noise patterns: `2 × noise_amplitude > THRESH` for EMA to demonstrate value over raw differencing. The `noisy_moving_box` pattern uses `noise_amplitude=10` vs `THRESH=16`.

**Departure ghosts under selective EMA.** With the two-rate rule, motion pixels drift at `cfg_t.alpha_shift_slow` (default α=1/64), so the bg is barely contaminated under a normal-speed moving object. When the object leaves, `raw_motion` drops to 0 on the very next frame and the pixel immediately reverts to the fast rate — no multi-frame ghost. A ghost only appears if an object lingered long enough for the slow EMA to partially absorb it into bg; that window is ~`1/α_slow` frames (≈64 frames at default). Under the old single-rate EMA, departure ghosts lasted ~`1/alpha` frames on every departure; selective EMA suppresses this by design.

**Verify all control flows × profile combinations.** After any motion pipeline change, test the matrix: all 4 control flows (passthrough, motion, mask, ccl_bbox) × the named profiles (default, no_ema, no_morph, no_gauss, default_hflip) × multiple sources at TOLERANCE=0.

**Vblank FSM modules must deassert tready for the full FSM duration.** `axis_ccl` deasserts `tready` during PHASE_A..PHASE_SWAP (the EOF resolution FSM) so pixels cannot arrive while internal state is exclusively owned by the FSM. Per-pixel writes are additionally gated on `PHASE_IDLE`, but those gates alone are not sufficient — without the tready deassert, the FIFO upstream can push pixels that advance `line_buf` and `col`/`row` without updating `equiv[]` or `acc_*[]`, silently corrupting the labeling state. Vblank timing must exceed the worst-case FSM cycle budget; see `axis_ccl-arch.md §6.7`.

**Beat-strobe pattern for multi-consumer mask broadcast.** `axis_ccl` is fed `ccl_beat_strobe = msk_tvalid && msk_tready` as its `tvalid`, not raw `msk_tvalid`. In mask-display and ccl_bbox modes, the mask is consumed by two paths simultaneously; in those modes `msk_tready` is the AND of both consumers' readies. If one consumer stalls, the upstream stalls too and `msk_tvalid && msk_tready` goes low — so `axis_ccl` does not advance its internal `col`/`row` counters on the stalled cycle. Using raw `msk_tvalid` instead would cause the counters to race ahead, producing wrong neighbour reads and corrupted labels.

**Multi-consumer FIFO-write gating.** Companion rule to the beat-strobe above: when a mask stream feeds both a passthrough-to-output FIFO *and* `axis_ccl`, the FIFO's `tvalid` input must also be gated by `bbox_msk_tready`. Without the gate, the FIFO sees `proc_tvalid=1 && proc_tready=1` and writes the same beat every cycle while `axis_ccl`'s EOF FSM holds `bbox_msk_tready` low — duplicating beats and eventually deadlocking when the FIFO fills. Pre-morph this was dormant because `msk_tvalid=0` during v-blank; it fires once morph's phantom drain keeps emitting during the FSM. In `sparevideo_top` today: `msk_rgb_tvalid = msk_clean_tvalid && bbox_msk_tready` (mask display), and the ccl_bbox branch of `ovl_in_tvalid` has the same gate.

**AXI-Stream sof/tuser gating in sliding-window primitives.** `axis_window3x3`'s `cur_col/cur_row` combinational must gate its `sof_i` check with `valid_i`. Per AXI-Stream, sideband signals (tuser/sof) are only meaningful when tvalid=1. Producers (including `axis_motion_detect`) may leave `msk_tuser=1` asserted during the end-of-frame idle window (tvalid=0). Without the gate, the primitive resets `cur_col/cur_row` to 0 during that idle, breaking `at_phantom` and stalling the phantom row/column drain — losing H+1 output beats per frame per primitive instance. The always_ff for col/row already has this gate (`sof_i && valid_i`); the always_comb must match.

**Mask cleanup via `axis_morph3x3_open`.** A 3×3 square opening (erode → dilate) sits between `axis_motion_detect` and the downstream mask consumers (CCL, overlay, mask display). Removes single-pixel salt noise and features < 3 px wide. Runtime gate: the `morph_en` field of `cfg_t` (set to `1` in `CFG_DEFAULT`) enables the stage; `morph_en=0` (e.g. profile `no_morph`) is a zero-latency combinational bypass. Consequence: thin features (far-field targets, 1-px lines) are erased — use the `thin_moving_line` synthetic source to exercise this. Python reference model composes `scipy.ndimage.grey_erosion`/`grey_dilation` with `mode='nearest'` when `morph_en=True`, keeping RTL and model in agreement at `TOLERANCE=0` for both values. In motion.py/ccl_bbox.py, the EMA background update uses the **raw** (pre-morph) mask — matches the RTL where motion_detect drives EMA internally before morph is applied.

### Python environment

- All Python tooling runs from the venv at `.venv/`. Never use system Python directly.
- If adding a new Python dependency, add it to `requirements.txt`.
