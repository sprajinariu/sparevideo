---
name: software-testing
description: Use when writing Python control-flow reference models or model tests for pixel-accurate pipeline verification in the sparevideo project.
---

# Software Testing — Python Reference Models

## Overview

The sparevideo pipeline is verified pixel-accurately by comparing RTL simulation output against Python reference models. Each control flow (`passthrough`, `motion`, etc.) has its own model in `py/models/`. The `make verify` step runs the model on the input frames and diffs the result against the RTL output at TOLERANCE=0.

Models are **spec-driven, not RTL transcriptions**. They implement the intended algorithm from its mathematical specification. If the RTL disagrees with the model, the RTL is wrong.

## File Organization

```
py/models/
  __init__.py          Dispatch: run_model(ctrl_flow, frames, **kwargs)
  passthrough.py       Identity model — output equals input
  motion.py            Motion pipeline: luma extraction, mask, bbox, overlay
py/tests/
  test_models.py       Unit tests for all models
```

## Adding a New Control Flow Model

1. Create `py/models/<name>.py` with a `run(frames, **kwargs)` entry point
2. Register in `py/models/__init__.py`: add import and entry in `_MODELS` dict
3. Add `<name>` to `--ctrl-flow` choices in `py/harness.py` verify subparser
4. Add tests in `py/tests/test_models.py`
5. Add CI step in `.github/workflows/regression.yml`

## Model Design Principles

### Spec-driven, not RTL-driven

Models implement the algorithm from its spec — the fixed-point coefficients, threshold comparisons, priming logic, and overlay hit-test are all derived from the algorithm definition, not copied from the RTL. This ensures the model is an independent verification source.

### Online frame-by-frame processing

Models process frames sequentially with persistent state (e.g., the luma reference buffer in the motion model). This matches the streaming nature of the RTL pipeline. The model's `run()` function takes a list of frames and returns a list of expected output frames.

### Bit-accuracy matters

Where the RTL uses fixed-point arithmetic, the model must match exactly:

- **Coefficients**: `Y = (77*R + 150*G + 29*B) >> 8` — use `uint16` intermediates, `>> 8` truncation (not rounding), result is `uint8`.
- **Threshold**: `|Y_cur - Y_prev| > THRESH` — strict `>`, not `>=`. THRESH=16.
- **Priming**: PrimeFrames=2. Frames 0-1 always produce empty bbox. Frame 2 is first valid bbox. Overlay has 1-frame delay, so first visible rectangle is on frame 3.
- **Bbox overlay**: 1-pixel border. Color `(0, 255, 0)`. Hit test matches `axis_overlay_bbox.sv`.

### numpy idioms

Use numpy vectorized operations — no per-pixel Python loops for mask/luma computation. Use `int16` or `uint16` for intermediate arithmetic to avoid overflow. Use `np.clip` when clamping to `[0, 255]`.

## Test Conventions

- Tests live in `py/tests/test_models.py`
- Standalone script with `if __name__ == "__main__"` runner (no pytest dependency required)
- One section per control flow, plus unit tests for internal functions (`_rgb_to_y`, `_compute_mask`, `_compute_bbox`)
- Use `load_frames("synthetic:<pattern>", ...)` for end-to-end tests with real synthetic sources
- Test threshold boundary conditions explicitly (diff == thresh vs diff == thresh+1)
- Test priming behavior: verify frames 0-2 are passthrough for motion flow

## Verification Flow

```
make run-pipeline CTRL_FLOW=<flow> SOURCE=<source>
```

This runs: `prepare` → `compile` → `sim` → `verify` → `render`

The `verify` step:
1. Loads input frames from file
2. Runs `run_model(ctrl_flow, input_frames)` to get expected output
3. Compares expected vs RTL output pixel-by-pixel via `compare_frames()`
4. Fails if any frame exceeds TOLERANCE (default 0)

## Running Tests

```bash
make test-py              # Runs test_frame_io.py + test_models.py
python py/tests/test_models.py  # Run model tests directly
```
