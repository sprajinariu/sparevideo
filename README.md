# sparevideo

Video processing pipeline with motion detection and bounding-box overlay, verified via Verilator with a file-based Python harness.

## Overview

A video processing pipeline written in SystemVerilog. The top-level design (`sparevideo_top`) accepts an **AXI4-Stream** video input on a 25 MHz pixel clock, crosses into a 100 MHz DSP clock domain, runs a **control-flow-selectable processing pipeline** (passthrough, motion detection + N-way bounding-box overlay via connected-component labeling, mask display, or mask-as-grey + CCL-bbox debug), crosses back to the pixel clock, and drives a VGA controller. A top-level 2-bit `ctrl_flow_i` sideband signal selects the active path.

Architecture details, module interfaces, and design decisions are documented in [`docs/specs/`](docs/specs/):

| Document | Module |
|----------|--------|
| [`sparevideo-top-arch.md`](docs/specs/sparevideo-top-arch.md) | Top-level pipeline, clock domains, FIFO sizing, SVAs |
| [`axis_motion_detect-arch.md`](docs/specs/axis_motion_detect-arch.md) | Motion mask generation, RAM port discipline, backpressure |
| [`axis_gauss3x3-arch.md`](docs/specs/axis_gauss3x3-arch.md) | 3x3 Gaussian pre-filter on Y channel |
| [`axis_ccl-arch.md`](docs/specs/axis_ccl-arch.md) | Streaming 8-connected connected-component labeler + top-N bbox selector |
| [`axis_overlay_bbox-arch.md`](docs/specs/axis_overlay_bbox-arch.md) | `N_OUT`-wide rectangle overlay on RGB video |
| [`rgb2ycrcb-arch.md`](docs/specs/rgb2ycrcb-arch.md) | RGB888 → Y8 color-space converter |
| [`ram-arch.md`](docs/specs/ram-arch.md) | Dual-port byte RAM, region descriptor model |
| [`vga_controller-arch.md`](docs/specs/vga_controller-arch.md) | VGA timing generator |

## Project Structure

### RTL

```
hw/top/
├── sparevideo_top.sv          Top-level: AXI4-Stream → CDC → pipeline mux → CDC → VGA
├── sparevideo_pkg.sv          Package: shared parameters, types, control flow constants
└── ram.sv                     Generic true-dual-port byte RAM (behavioral, sim-only)

hw/ip/rgb2ycrcb/rtl/
└── rgb2ycrcb.sv               RGB888 → YCrCb converter (Rec.601, 8-bit fixed-point)

hw/ip/axis/rtl/
└── axis_fork.sv               Zero-latency AXI4-Stream 1-to-2 broadcast fork with per-output acceptance tracking

hw/ip/gauss3x3/rtl/
└── axis_gauss3x3.sv           3x3 Gaussian pre-filter on Y channel (line buffers + adder tree)

hw/ip/motion/rtl/
├── axis_motion_detect.sv      Motion detector: mask-only producer (rgb2ycrcb + EMA core + memory)
└── motion_core.sv             Pure-combinational: abs-diff threshold + EMA background update

hw/ip/ccl/rtl/
└── axis_ccl.sv                Streaming 8-connected CCL + EOF FSM + top-N bbox double-buffer

hw/ip/overlay/rtl/
└── axis_overlay_bbox.sv       N_OUT-wide bounding-box rectangle overlay on RGB video

hw/ip/vga/rtl/
├── vga_controller.sv          VGA timing generator (instantiated in top)
└── pattern_gen.sv             Test pattern generator (retained, unused)

hw/lint/
├── verilator_waiver.vlt       Project lint waivers
└── third_party_waiver.vlt     Third-party lint waivers

third_party/verilog-axis/rtl/  Vendored alexforencich/verilog-axis (MIT)
```

### Verification — SystemVerilog

```
hw/ip/rgb2ycrcb/tb/
└── tb_rgb2ycrcb.sv            18 vectors, corner cases, exact-match

hw/ip/gauss3x3/tb/
└── tb_axis_gauss3x3.sv        11 tests: uniform/impulse/gradient/checker/stall/SOF + centered alignment, edge replication, latency, busy_o fallback, min-blanking

hw/ip/motion/tb/
└── tb_axis_motion_detect.sv   6-frame golden model, threshold boundary, symmetric + asymmetric stall

hw/ip/ccl/tb/
└── tb_axis_ccl.sv             9 tests: single blob, hollow, disjoint, U-merge, min-size filter, overflow, back-to-back, mid-frame gaps, priming

hw/ip/overlay/tb/
└── tb_axis_overlay_bbox.sv    8 tests: empty/full/single-pixel, backpressure

dv/sv/
├── tb_sparevideo.sv           Unified top-level testbench (RTL sim + SW dry-run)
└── tb_utils.c                 DPI-C wall-clock helper (Verilator)

dv/sim/
└── Makefile                   Simulation and test-ip targets

dv/data/                       Generated simulator input/output scratch files (gitignored)
renders/                       PNG comparison grids from `make render` (gitignored)
```

### Verification — Python

```
py/
├── harness.py                 Pipeline CLI: prepare / verify / render
├── frames/
│   ├── frame_io.py            Read/write text and binary frame files
│   └── video_source.py        Load video from MP4/PNG/synthetic sources
├── models/
│   ├── __init__.py            Model dispatch (run_model → per-control-flow model)
│   ├── passthrough.py         Passthrough model (identity)
│   ├── motion.py              Motion pipeline model (luma, mask, CCL bboxes, overlay)
│   ├── mask.py                Mask display model (luma, mask, B/W expansion)
│   ├── ccl.py                 Streaming CCL reference model (matches RTL bit-for-bit)
│   └── ccl_bbox.py            ccl_bbox debug composition (mask-as-grey + bboxes)
├── viz/
│   └── render.py              Render input/output comparison image grid
└── tests/
    ├── test_frame_io.py       Frame I/O round-trip tests
    └── test_models.py         Reference model unit tests
```

## Prerequisites

- **Verilator** 5.0+ (simulation and linting)
- **GCC** (Verilator uses it internally)
- **Python** 3.10+ with venv
- **GTKWave** (optional, waveform viewer)

## Setup

```bash
# Install Verilator, GCC, and GTKWave
sudo apt install -y verilator gcc gtkwave

# Create Python venv and install deps
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# Or use the setup target:
make setup
```

## Usage

There are three levels of testing:

- **`make run-pipeline`** — End-to-end integration. Python generates input frames, Verilator simulates the full RTL pipeline, then Python compares the RTL output against a reference model pixel-by-pixel. This is the primary way to verify the design.
- **`make test-ip`** — Per-block SV unit testbenches. Each RTL module has its own testbench with known-good vectors and edge cases. Fast, no Python involved.
- **`make test-py`** — Python unit tests. Verifies the reference models and frame I/O independently of RTL simulation.

```bash
# Run the full pipeline: prepare (py) → compile (verilator) → sim (verilator) → verify (py) → render (py)
make run-pipeline

# With custom source and options
make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=motion
make run-pipeline SOURCE=path/to/video.mp4 MODE=binary

# Control flow selection (model-based verification at TOLERANCE=0)
make run-pipeline CTRL_FLOW=passthrough   # identity — exact match
make run-pipeline CTRL_FLOW=motion        # motion detect + N-bbox overlay — pixel-accurate model
make run-pipeline CTRL_FLOW=mask          # raw motion mask — B/W output for debugging
make run-pipeline CTRL_FLOW=ccl_bbox      # mask-as-grey canvas + CCL bboxes (debug CCL directly)

# EMA background model tuning (ALPHA_SHIFT/ALPHA_SHIFT_SLOW are compile-time Verilator parameters)
make run-pipeline SOURCE="synthetic:noisy_moving_box" CTRL_FLOW=mask ALPHA_SHIFT=2 ALPHA_SHIFT_SLOW=6 FRAMES=8

# Grace window tuning — suppress frame-0 hard-init ghosts
make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=mask GRACE_FRAMES=8 FRAMES=12
make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=mask GRACE_FRAMES=16 FRAMES=12
make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=mask GRACE_FRAMES=0 FRAMES=12  # disable grace (regression baseline)

# Run per-block IP unit testbenches (fast, Verilator)
make test-ip

# Lint only
make lint
```

`make run-pipeline` runs these steps in order, passing all options automatically:

| Step | Target | What runs | Description |
|------|--------|-----------|-------------|
| 1 | `prepare` | Python | Generate input frames from source — **saves options** to `dv/data/config.mk` |
| 2 | `compile` | Verilator | Compile RTL + testbench into a binary |
| 3 | `sim` | Verilator | Run RTL simulation, write output frames to file |
| 4 | `verify` | Python | Compare RTL output against reference model (pixel-accurate) |
| 5 | `render` | Python | Save input vs output comparison PNG |

### Running steps individually

`make prepare` saves `WIDTH`, `HEIGHT`, `FRAMES`, and `MODE` to `dv/data/config.mk`. All subsequent steps load that file automatically:

```bash
make prepare SOURCE="synthetic:moving_box" WIDTH=320 HEIGHT=240 FRAMES=8
make sim
make verify   # uses saved CTRL_FLOW to select the reference model
make render
```

`SIMULATOR` and `TOLERANCE` are not saved — specify them explicitly when needed:

| Option | Saved by `prepare`? | Used by |
|--------|:-------------------:|---------|
| `WIDTH` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run` |
| `HEIGHT` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run` |
| `FRAMES` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run` |
| `MODE` | ✓ | `prepare`, `sim`, `sim-waves`, `sw-dry-run`, `verify`, `render` |
| `CTRL_FLOW` | ✓ | `compile`, `sim`, `sim-waves`, `sw-dry-run`, `verify` |
| `ALPHA_SHIFT` | ✓ | `compile`, `sim`, `sim-waves`, `sw-dry-run` |
| `ALPHA_SHIFT_SLOW` | ✓ | `compile`, `sim`, `sim-waves`, `sw-dry-run` |
| `GRACE_FRAMES` | ✓ | `compile`, `sim`, `sim-waves`, `sw-dry-run` |
| `GAUSS_EN` | ✓ | `compile`, `sim`, `sim-waves`, `sw-dry-run`, `verify` |
| `SIMULATOR` | — | `compile`, `sim`, `sim-waves`, `sw-dry-run` |
| `TOLERANCE` | — | `verify` |
| `SOURCE` | ✓ | `prepare` only |

```bash
# Other targets
make lint                    # Verilator lint
make test-ip                 # All per-block IP unit testbenches (Verilator)
make test-ip-rgb2ycrcb       # rgb2ycrcb: 18 vectors, exact-match golden model
make test-ip-gauss3x3        # axis_gauss3x3: 11 tests, centered Gaussian + latency + busy_o fallback
make test-ip-motion-detect   # axis_motion_detect: 6-frame golden model, threshold boundary, symmetric + asymmetric stall
make test-ip-ccl             # axis_ccl: 7 tests, single/hollow/disjoint/U-merge/overflow/back-to-back
make test-ip-overlay-bbox    # axis_overlay_bbox: 8 tests, empty/full/single-pixel/backpressure
make sw-dry-run              # Bypass RTL — file loopback, zero sim time
make sim-waves               # RTL sim + open GTKWave
make compile                 # Compile only
make test-py                 # Python unit tests (frame I/O + reference models)
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `SIMULATOR` | `verilator` | Simulator to use (`verilator` only; Icarus not maintained) |
| `CTRL_FLOW` | `motion` | Control flow: `passthrough` (no processing), `motion` (motion detect + bbox overlay), or `mask` (raw motion mask as B/W image) |
| `SOURCE` | `synthetic:moving_box` | Input source (only used by `prepare`). See table below for available patterns. Also accepts MP4/AVI files (OpenCV) or a PNG directory. |
| `WIDTH` | `320` | Frame width in pixels |
| `HEIGHT` | `240` | Frame height in pixels |
| `FRAMES` | `4` | Number of frames |
| `MODE` | `text` | File format: `text` (hex) or `binary` |
| `TOLERANCE` | `0` | Max differing pixels per frame in `verify`. Default is 0 (pixel-accurate model-based verification). |
| `ALPHA_SHIFT` | `3` | EMA background adaptation rate: `alpha = 1/(1 << N)`. Higher = slower adaptation (more noise suppression, longer departure ghosts). 0 = raw frame differencing (no EMA). Compile-time RTL parameter propagated to Verilator via `-G`. |
| `ALPHA_SHIFT_SLOW` | `6` | EMA background adaptation rate for motion pixels: `alpha = 1/(1 << N)`. Default 6 (α=1/64). Larger than `ALPHA_SHIFT` so motion pixels barely drift bg → no trails. Also governs absorption time of stopped objects. Compile-time RTL parameter propagated via `-G`. |
| `GRACE_FRAMES` | `8` | Frames after priming where bg updates use the fast EMA rate unconditionally. Suppresses frame-0 hard-init ghosts. Set to 0 to disable. |
| `GAUSS_EN` | `1` | Gaussian pre-filter on Y channel: `1` = enabled (3x3 blur before motion threshold), `0` = disabled (raw Y). Reduces salt-and-pepper noise in the motion mask. Compile-time RTL parameter propagated to Verilator via `-G`. |

### Synthetic Sources

| Pattern | Description |
|---------|-------------|
| `synthetic:moving_box` | Red box, diagonal top-left → bottom-right |
| `synthetic:dark_moving_box` | Dark box on bright background (tests polarity-agnostic mask) |
| `synthetic:two_boxes` | Red + cyan boxes moving in opposing directions |
| `synthetic:noisy_moving_box` | Red box on noisy background (±10 luma jitter). Tests EMA noise suppression — `ALPHA_SHIFT=0` produces false positives, `ALPHA_SHIFT>=2` suppresses them. |
| `synthetic:lighting_ramp` | Moving box on slowly brightening background (+1 luma/frame). Tests EMA tracking of gradual lighting changes. |
| `synthetic:textured_static` | Sinusoid-textured static background with per-frame sensor noise. Negative test — mask must be all-black after EMA convergence. |
| `synthetic:entering_object` | Two soft-edged boxes entering from opposite edges, crossing the centre. Textured+noisy bg. |
| `synthetic:multi_speed` | Three soft-edged boxes with distinct speeds and directions (fast L→R, medium T→B, slow diagonal). Textured+noisy bg. Exercises N-way CCL tracking. |
| `synthetic:stopping_object` | Box A stops after half the frames; box B moves throughout. Textured+noisy bg. Exercises selective-EMA slow-rate absorption. |
| `synthetic:lit_moving_object` | Two soft-edged boxes on a bg whose left↔right illumination gradient shifts ~2 luma/frame. Textured+noisy bg. |

Motion patterns are best tested with `FRAMES=8` or higher for meaningful multi-frame tracking. All patterns with moving objects render frame 0 as background-only — objects appear from frame 1 onward, so the EMA hard-init at frame 0 primes bg with clean background (no frame-0 ghost).

### THRESH (motion detection threshold)

The luma-difference threshold `MOTION_THRESH` is a top-level RTL parameter (default `16`, ≈6.25% intensity). Override at compile time via the testbench plusarg:

```bash
make run-pipeline SIMARGS="+THRESH=32"
```

A pixel is classified as motion when `|Y_cur - bg| > THRESH`, where `bg` is the per-pixel EMA background model (see `ALPHA_SHIFT`). The mask is polarity-agnostic — both arrival and departure pixels are flagged, so the bounding box works for bright-on-dark, dark-on-bright, and colour scenes. The bbox is slightly larger than the object by approximately one frame of displacement. Frame 0 is a priming pass (mask forced to 0 while the bg RAM is seeded per-pixel), and the first real detection frame is frame 1. The CCL suppresses bboxes for the first 2 frames as an additional safety margin so any transient on the very first compare cycle cannot produce a spurious bbox.

For the `mask` control flow, the verify step also reports motion pixel counts per frame (`motion=N/total`), which is useful for diagnosing false positives.

### File Formats

Frame data is passed between Python and the SV testbench via files on disk. Python writes input frames before simulation and reads output frames back for verification. The `MODE` option selects the format.

**Text mode** (`.txt`): Space-separated 6-digit hex pixels (RRGGBB), one row per line. No header.
```
FF0000 FF0000 00FF00 00FF00
FF0000 FF0000 00FF00 00FF00
```

**Binary mode** (`.bin`): 12-byte header (width, height, frames as LE uint32) + raw RGB bytes (3 bytes/pixel, row-major).

## License

Apache License 2.0
