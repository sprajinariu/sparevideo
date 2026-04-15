# Plan: Python Golden Models for Pixel-Accurate Pipeline Verification

## Context

`make verify` for `CTRL_FLOW=motion` currently uses a loose tolerance (2*(W+H) or even TOLERANCE=10000 in CI), which doesn't actually verify that the RTL output is correct — only that it's "not too different" from the input. This plan adds Python reference models that implement the pipeline algorithms from their specifications, so verification can compare RTL output against a known-correct reference at TOLERANCE=0.

The models are **spec-driven, not RTL-driven**. They implement the intended behavior from the algorithmic definition (e.g. "Rec.601 luma extraction", "frame-difference motion mask", "bounding box of motion region"). If the RTL disagrees with the model, the RTL is wrong.

## New Files

### `py/models/__init__.py` — package init with dispatch

```python
def run_model(ctrl_flow: str, frames: list, **kwargs) -> list:
    """Dispatch to the correct control-flow model."""
```

Maps `"passthrough"` → `passthrough.run()`, `"motion"` → `motion.run()`. Single entry point for harness.py.

### `py/models/passthrough.py` — passthrough control flow model

```python
def run(frames):  # identity — returns copies of input frames
```

### `py/models/motion.py` — motion detection control flow model

Implements the motion detection pipeline from the algorithm spec. Written using natural numpy operations.

**Algorithm (online, frame-by-frame with state):**

1. **Luma extraction** — Rec.601 Y component with project coefficients:
   `Y = (77*R + 150*G + 29*B) >> 8`
   These coefficients and the >>8 truncation are the *specification*.

2. **Frame-difference motion mask:**
   - Maintain a luma reference buffer (initially zeros)
   - `mask[y,x] = |Y_cur[y,x] - Y_ref[y,x]| > threshold` (threshold=16)
   - Update reference: `Y_ref = Y_cur`

3. **Bounding box of motion region:**
   - Tightest axis-aligned rectangle enclosing all motion pixels
   - Priming: first 2 frames produce no valid bbox (reference buffer not yet meaningful)
   - No motion → no bbox

4. **Rectangle overlay with 1-frame delay:**
   - Bbox from frame N drawn on frame N+1 (not known until frame ends)
   - Frame 0 has no prior bbox → pure passthrough
   - Border pixels → green (0x00FF00); all others → passthrough
   - No bbox → pure passthrough

```python
def run(frames, thresh=16):
    """Motion pipeline reference model. Processes frames online with state."""
```

### `py/tests/test_models.py` — tests for control-flow models

**Passthrough:** static frames → output == input

**Motion end-to-end:**
- Identical frames → output == input (no motion, no overlay)
- `moving_box` source → green pixels at expected bbox border on correct frames
- `dark_moving_box` → dark-on-bright detection
- `color_bars` (static) → output == input after priming
- Threshold boundary: diffs at threshold (no motion) vs threshold+1 (motion)
- Priming: frames 0-2 passthrough; frame 3 first with potential overlay

Standalone script with `if __name__ == "__main__"`.

## Modified Files

### `py/harness.py`

- Add `--ctrl-flow` argument to `verify` subparser (choices: `passthrough`, `motion`)
- In `cmd_verify`: compute `expected = run_model(ctrl_flow, input_frames)`, compare `expected` vs `output_frames`

### `Makefile`

- Pass `--ctrl-flow $(CTRL_FLOW)` to the verify target
- Change TOLERANCE default to `0` for all control flows (remove the `ifeq` conditional on lines 19-23)

### `.github/workflows/regression.yml`

Current CI runs motion pipeline with `TOLERANCE=10000` (line 72) and passthrough pipelines without `--ctrl-flow`. After the model is working:

- Update existing passthrough pipeline steps to pass `CTRL_FLOW=passthrough` explicitly (they already default correctly, but explicit is clearer)
- Change the `moving_box` step from `TOLERANCE=10000` to `TOLERANCE=0` (model-based verify makes this possible)
- Add new CI steps for additional motion sources:

```yaml
- name: Pipeline — moving_box (motion, pixel-accurate)
  run: make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=motion

- name: Pipeline — dark_moving_box (motion)
  run: make run-pipeline SOURCE="synthetic:dark_moving_box" CTRL_FLOW=motion

- name: Pipeline — two_boxes (motion)
  run: make run-pipeline SOURCE="synthetic:two_boxes" CTRL_FLOW=motion

- name: Pipeline — color_bars (motion, static scene)
  run: make run-pipeline SOURCE="synthetic:color_bars" CTRL_FLOW=motion
```

Also update import check to include the new models package:
```yaml
- name: Import check
  run: |
    cd py && ../.venv/bin/python -c \
      "import frames.frame_io, frames.video_source, viz.render, models"
```

### `README.md`

- Update Usage examples: remove `TOLERANCE=10000`, show model-based verify (TOLERANCE=0 is now default for all flows)
- Update Options table: TOLERANCE default changes from `2*(W+H)` to `0`, description updated to explain model-based comparison
- Add `py/models/` to Project Structure tree

### `CLAUDE.md`

- Add `py/models/` to project structure
- Document that each control flow has a reference model
- Update verify docs

### `sparevideo/.claude/skills/software-testing/SKILL.md` — new skill

A skill for writing Python control-flow models and tests. Covers:

- How models are organized: one file per control flow in `py/models/`, dispatch via `run_model()` in `__init__.py`
- How to add a new control flow model (create `py/models/<name>.py` with a `run(frames, **kwargs)` entry point, register in `__init__.py`, add `--ctrl-flow` choice to harness.py, add CI step)
- Model design principles: spec-driven (not RTL-transcription), online frame-by-frame processing, numpy idioms
- Where bit-accuracy matters: fixed-point coefficients, truncation vs rounding, strict `>` vs `>=`
- Test conventions: standalone scripts with `if __name__ == "__main__"`, test per control flow not per block
- Verification flow: model produces expected output, `compare_frames()` diffs expected vs RTL output at TOLERANCE=0

## Implementation Order

1. `py/models/__init__.py` — dispatch
2. `py/models/passthrough.py` — identity model
3. `py/models/motion.py` — full motion pipeline reference
4. `py/tests/test_models.py`
5. `py/harness.py` edits
6. `Makefile` edits
7. Local verification (steps below)
8. `.github/workflows/regression.yml` updates
9. `README.md` updates
10. `CLAUDE.md` update
11. `sparevideo/.claude/skills/software-testing/SKILL.md` — new skill

## Verification

Run locally in order:

1. `make test-py` — model unit tests pass
2. `make run-pipeline CTRL_FLOW=passthrough` — no regression, TOLERANCE=0
3. `make run-pipeline CTRL_FLOW=motion SOURCE=synthetic:moving_box` — pixel-accurate, TOLERANCE=0
4. `make run-pipeline CTRL_FLOW=motion SOURCE=synthetic:two_boxes`
5. `make run-pipeline CTRL_FLOW=motion SOURCE=synthetic:dark_moving_box`
6. `make run-pipeline CTRL_FLOW=motion SOURCE=synthetic:color_bars`

Then update CI to run these same checks on every PR.

## Key Design Decisions

- **Spec-driven, not RTL-driven**: Models implement the algorithm from its mathematical definition. The model is the source of truth.
- **Online processing**: Frame-by-frame with state, matching the streaming nature.
- **One file per control flow**: `passthrough.py`, `motion.py`. Future modes get their own file.
- **No new dependencies**: numpy is sufficient.
