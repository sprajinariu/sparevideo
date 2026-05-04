# README Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two animated WebP triptychs (synthetic + real) to the project README, regenerable from `make demo`, so visitors immediately see the motion-detection pipeline working.

**Architecture:** Each demo runs the existing `prepare → compile → sim` chain twice (once with `CTRL_FLOW=ccl_bbox`, once with `CTRL_FLOW=motion`) on the same source frames at 320×240 native (scaler off via a new `demo` profile). A new Python module `py/demo/` composes the three streams (Input | CCL BBOX | MOTION) into 960×240 frames per timestep and encodes them as animated WebP. Source MP4 and rendered WebPs are committed.

**Tech Stack:** Python 3 + Pillow (already in `requirements.txt`) for composition + WebP encoding; existing OpenCV loader for the real clip; existing Verilator + Python harness for the rest.

**Spec:** `docs/plans/2026-04-30-readme-demo-design.md`.

---

## Preamble — Branch creation

Per CLAUDE.md, every plan gets its own fresh branch off `origin/main`. Before starting Task 1, run:

```bash
git fetch origin
git checkout -b feat/readme-demo origin/main
```

If you are currently on a non-`main` branch with uncommitted work, stash or commit it on that branch first. Do not start this plan on `refactor/spec-cleanup` or any other in-flight branch.

**Font label note (referenced throughout):** the existing 8×8 bitmap font in `py/models/ops/hud_font.py` only contains `0-9`, `A-Z`, `:`, and space. There is no underscore glyph. Panel labels in this plan therefore use `CCL BBOX` (with a space) instead of `CCL_BBOX`. The design spec was written before this constraint was checked.

---

## Task 1: Scaffolding — directories and empty modules

**Files:**
- Create: `py/demo/__init__.py`
- Create: `py/demo/compose.py`
- Create: `py/demo/encode.py`
- Create: `media/source/.gitkeep`
- Create: `media/demo/.gitkeep`

- [ ] **Step 1: Create the `py/demo/` package skeleton**

```bash
mkdir -p py/demo media/source media/demo
```

Create `py/demo/__init__.py` with placeholder content:

```python
"""Demo asset generation: compose triptychs and encode animated WebP for the README."""
```

Create `py/demo/compose.py` and `py/demo/encode.py` as empty files (`touch` is fine; tasks below add content).

- [ ] **Step 2: Create `.gitkeep` placeholders so git tracks the empty media dirs**

```bash
touch media/source/.gitkeep media/demo/.gitkeep
```

(These get deleted in later tasks once real content lands.)

- [ ] **Step 3: Verify scaffolding**

```bash
ls py/demo/ media/source/ media/demo/
```

Expected: `py/demo/` lists `__init__.py compose.py encode.py`; the media dirs each list `.gitkeep`.

- [ ] **Step 4: Commit**

```bash
git add py/demo/ media/source/.gitkeep media/demo/.gitkeep
git commit -m "demo: scaffold py/demo package and media/ directories"
```

---

## Task 2: Extend `_place_object` to support RGB foreground

The existing helper renders greyscale boxes only (single `luma` int → R=G=B). Add an optional `rgb=(R,G,B)` parameter that overrides the greyscale path when provided. All existing call sites continue to work unchanged.

**Files:**
- Modify: `py/frames/video_source.py:164-194`
- Create: `py/tests/test_video_source_helpers.py`

- [ ] **Step 1: Write the failing tests**

Create `py/tests/test_video_source_helpers.py`:

```python
"""Unit tests for video_source helpers — alpha-blended object placement and bg texture."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np

from frames.video_source import _make_bg_texture, _place_object


def test_place_object_greyscale_unchanged():
    """Existing call sites pass `luma` and expect R=G=B output."""
    frame = np.zeros((20, 20, 3), dtype=np.uint8)
    _place_object(frame, 5, 5, 10, 10, luma=200)
    # Pixel near box centre should be near-uniform grey
    cx, cy = 10, 10
    assert frame[cy, cx, 0] == frame[cy, cx, 1] == frame[cy, cx, 2]
    assert frame[cy, cx, 0] > 100  # blurred but well into the bright range


def test_place_object_rgb_overrides_luma():
    """When rgb=(R,G,B) is provided, the box renders that color."""
    frame = np.zeros((20, 20, 3), dtype=np.uint8)
    _place_object(frame, 5, 5, 10, 10, luma=0, rgb=(255, 80, 80))
    cx, cy = 10, 10
    # Centre pixel should be dominated by red
    assert frame[cy, cx, 0] > frame[cy, cx, 1]
    assert frame[cy, cx, 0] > frame[cy, cx, 2]
    assert frame[cy, cx, 1] < 120
    assert frame[cy, cx, 2] < 120


def test_place_object_rgb_alpha_falloff():
    """RGB rendering still has a soft Gaussian edge."""
    frame = np.zeros((40, 40, 3), dtype=np.uint8)
    _place_object(frame, 15, 15, 10, 10, luma=0, rgb=(255, 0, 0))
    # Far from the box: zero. Inside: red. Near edge: intermediate.
    assert frame[5, 5, 0] == 0
    assert frame[20, 20, 0] > 200
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
source .venv/bin/activate
pytest py/tests/test_video_source_helpers.py -v
```

Expected: `test_place_object_rgb_overrides_luma` and `test_place_object_rgb_alpha_falloff` FAIL with `TypeError: _place_object() got an unexpected keyword argument 'rgb'`. The greyscale-unchanged test passes.

- [ ] **Step 3: Implement the `rgb=` parameter**

In `py/frames/video_source.py`, replace the existing `_place_object` (currently at lines 164-194) with:

```python
def _place_object(rgb_frame, x0, y0, box_w, box_h, luma,
                  sigma=2.0, kernel=5, rgb=None):
    """Composite a Gaussian-blurred soft-edged box at (x0, y0) onto rgb_frame, in-place.

    By default the object is greyscale (R=G=B=luma). If `rgb=(R,G,B)` is provided,
    it overrides the greyscale path and the box renders in that color. Box regions
    partially outside the frame are clipped cleanly; the function is a no-op if the
    box is fully off-screen.
    """
    H, W = rgb_frame.shape[:2]
    pad = kernel  # margin so the blur kernel never reads outside the padded canvas

    # Draw a binary mask on a padded canvas so the Gaussian blur can handle
    # boxes that touch or cross the frame edge without edge artefacts.
    canvas_h = H + 2 * pad
    canvas_w = W + 2 * pad
    hard = np.zeros((canvas_h, canvas_w), dtype=np.float32)
    y1p = max(y0 + pad, 0)
    y2p = min(y0 + pad + box_h, canvas_h)
    x1p = max(x0 + pad, 0)
    x2p = min(x0 + pad + box_w, canvas_w)
    if y1p >= y2p or x1p >= x2p:
        return  # fully off-screen
    hard[y1p:y2p, x1p:x2p] = 1.0

    blurred = cv2.GaussianBlur(hard, (kernel, kernel), sigma)
    soft = blurred[pad:pad + H, pad:pad + W]     # crop back to the frame

    alpha = soft[..., None]                      # (H, W, 1)
    if rgb is None:
        fg = np.full_like(rgb_frame, luma)
    else:
        fg = np.zeros_like(rgb_frame)
        fg[..., 0] = rgb[0]
        fg[..., 1] = rgb[1]
        fg[..., 2] = rgb[2]
    out = rgb_frame.astype(np.float32) * (1.0 - alpha) + fg.astype(np.float32) * alpha
    rgb_frame[:] = np.clip(out, 0, 255).astype(np.uint8)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest py/tests/test_video_source_helpers.py -v
```

Expected: all three tests PASS.

- [ ] **Step 5: Run the full Python test suite to confirm no regressions**

```bash
make test-py
```

Expected: every test passes (no existing test calls `_place_object` with `rgb=`).

- [ ] **Step 6: Commit**

```bash
git add py/frames/video_source.py py/tests/test_video_source_helpers.py
git commit -m "demo: extend _place_object with optional rgb= parameter"
```

---

## Task 3: Extend `_make_bg_texture` to support a tint

The existing helper returns a 2-D greyscale array. Add an optional `tint=(R,G,B)` parameter that produces a 3-D RGB output by per-channel scaling. When `tint` is `None`, the function returns the existing 2-D greyscale array unchanged.

**Files:**
- Modify: `py/frames/video_source.py:131-150` (the `_make_bg_texture` body)
- Modify: `py/tests/test_video_source_helpers.py` (add tests)

- [ ] **Step 1: Add the failing tests**

Append to `py/tests/test_video_source_helpers.py`:

```python
def test_make_bg_texture_greyscale_unchanged():
    """Default call returns 2-D greyscale array (existing behavior)."""
    tex = _make_bg_texture(width=64, height=48)
    assert tex.ndim == 2
    assert tex.shape == (48, 64)
    assert tex.dtype == np.uint8


def test_make_bg_texture_tint_returns_rgb():
    """When tint=(R,G,B) is provided, returns a 3-D RGB array tinted accordingly."""
    tex = _make_bg_texture(width=64, height=48, tint=(255, 100, 100))
    assert tex.ndim == 3
    assert tex.shape == (48, 64, 3)
    assert tex.dtype == np.uint8
    # Red channel mean should clearly exceed green and blue means
    assert tex[..., 0].mean() > tex[..., 1].mean()
    assert tex[..., 0].mean() > tex[..., 2].mean()


def test_make_bg_texture_tint_preserves_variation():
    """Tinted output still has spatial variation (it's a textured bg, not flat color)."""
    tex = _make_bg_texture(width=64, height=48, tint=(200, 200, 200))
    # std-dev across the red channel should be nonzero (sinusoid + noise survives)
    assert tex[..., 0].std() > 1.0
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pytest py/tests/test_video_source_helpers.py -v
```

Expected: the three new `_make_bg_texture` tests FAIL with `TypeError: _make_bg_texture() got an unexpected keyword argument 'tint'`. The greyscale-unchanged test passes.

- [ ] **Step 3: Implement the `tint=` parameter**

In `py/frames/video_source.py`, replace the existing `_make_bg_texture` body (currently at line 131) with:

```python
def _make_bg_texture(width, height, base_luma=100, amp=20, seed=0xBE1F, tint=None):
    """Sinusoid-textured background.

    Returns a 2-D (H, W) uint8 array by default. If `tint=(R,G,B)` is provided,
    returns a 3-D (H, W, 3) uint8 RGB array where each channel is scaled by
    `tint[c] / 255.0` relative to the greyscale texture.
    """
    rng = np.random.default_rng(seed)
    yy, xx = np.meshgrid(np.arange(height), np.arange(width), indexing="ij")
    pattern = (
        np.sin(2 * np.pi * xx / max(width, 1) * 3)
        + np.sin(2 * np.pi * yy / max(height, 1) * 2)
    )
    pattern = (pattern + 2.0) / 4.0  # normalize to [0, 1]
    grey = (base_luma + amp * (pattern - 0.5) * 2.0).clip(0, 255).astype(np.uint8)
    grey = (grey + rng.integers(-2, 3, size=grey.shape)).clip(0, 255).astype(np.uint8)
    if tint is None:
        return grey
    rgb = np.zeros((height, width, 3), dtype=np.uint8)
    for c in range(3):
        rgb[..., c] = (grey.astype(np.float32) * (tint[c] / 255.0)).clip(0, 255).astype(np.uint8)
    return rgb
```

(Preserve whatever the existing greyscale body does — the snippet above mirrors the existing sinusoid + noise structure. If your local copy of `_make_bg_texture` differs from the snippet's first half, keep its existing greyscale logic and add only the `tint` branch at the end.)

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest py/tests/test_video_source_helpers.py -v
```

Expected: all six tests PASS.

- [ ] **Step 5: Full Python test suite**

```bash
make test-py
```

Expected: all tests pass — no existing call site passes `tint=`.

- [ ] **Step 6: Commit**

```bash
git add py/frames/video_source.py py/tests/test_video_source_helpers.py
git commit -m "demo: extend _make_bg_texture with optional tint= parameter"
```

---

## Task 4: New synthetic source `multi_speed_color`

Three soft-edged colored boxes (red / green / cyan) on a tinted RGB textured background. Same speed/direction layout as the existing greyscale `multi_speed`. Frame 0 is bg-only.

**Files:**
- Modify: `py/frames/video_source.py` (add `_gen_multi_speed_color` function and register in dispatch dict; update module docstring/source list)
- Modify: `py/tests/test_video_source_helpers.py` (add tests)
- Modify: `README.md` (add row to synthetic-sources table)

- [ ] **Step 1: Write the failing tests**

Append to `py/tests/test_video_source_helpers.py`:

```python
from frames.video_source import generate_synthetic


def test_multi_speed_color_frame_count_and_shape():
    frames = generate_synthetic("multi_speed_color", width=64, height=48, num_frames=8)
    assert len(frames) == 8
    for f in frames:
        assert f.shape == (48, 64, 3)
        assert f.dtype == np.uint8


def test_multi_speed_color_frame0_is_bg_only():
    """Frame 0 has no foreground objects — only the tinted textured bg."""
    frames = generate_synthetic("multi_speed_color", width=64, height=48, num_frames=8)
    f0 = frames[0]
    f1 = frames[1]
    # Frame 1 contains object pixels; frame 0 does not. So per-pixel diff must be
    # nonzero in at least one location.
    diff = np.abs(f0.astype(int) - f1.astype(int)).sum(axis=-1)
    assert diff.max() > 50, "Frame 1 should differ from frame 0 at object locations"


def test_multi_speed_color_has_rgb_objects():
    """Frame 4 (mid-clip) must contain pixels dominated by red, green, and cyan respectively."""
    frames = generate_synthetic("multi_speed_color", width=64, height=48, num_frames=8)
    mid = frames[4].astype(int)
    R, G, B = mid[..., 0], mid[..., 1], mid[..., 2]
    # Strong red: R >> G, R >> B somewhere
    has_red   = ((R - G > 60) & (R - B > 60)).any()
    # Strong green: G >> R, G >> B somewhere
    has_green = ((G - R > 60) & (G - B > 60)).any()
    # Strong cyan: G >> R, B >> R somewhere
    has_cyan  = ((G - R > 60) & (B - R > 60)).any()
    assert has_red,   "no red-dominated pixel found"
    assert has_green, "no green-dominated pixel found"
    assert has_cyan,  "no cyan-dominated pixel found"


def test_multi_speed_color_deterministic():
    """Same seed → same frames (regression-friendly)."""
    a = generate_synthetic("multi_speed_color", width=64, height=48, num_frames=4)
    b = generate_synthetic("multi_speed_color", width=64, height=48, num_frames=4)
    for fa, fb in zip(a, b):
        np.testing.assert_array_equal(fa, fb)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pytest py/tests/test_video_source_helpers.py -v
```

Expected: the four new `multi_speed_color` tests FAIL with a `KeyError` or "unknown synthetic pattern" error from `generate_synthetic`.

- [ ] **Step 3: Implement `_gen_multi_speed_color`**

In `py/frames/video_source.py`, immediately after the existing `_gen_multi_speed` function (around line 274), add:

```python
def _gen_multi_speed_color(width, height, num_frames):
    """Three colored soft-edged boxes with distinct speeds and directions.

    Box A (fast, L→R, red): crosses width in num_frames frames.
    Box B (medium, T→B, green): crosses height in 2*num_frames frames.
    Box C (slow, BL→TR diagonal, cyan): crosses diagonal in 4*num_frames frames.

    Background is a tinted RGB textured field. Frame 0 is bg-only — objects appear
    from frame 1 onward, matching the convention of every other moving-object
    synthetic source so the EMA hard-init at frame 0 sees clean bg.
    """
    bg = _make_bg_texture(width, height, tint=(180, 200, 180))
    rng = np.random.default_rng(seed=11)
    box_w, box_h = max(width // 6, 1), max(height // 6, 1)
    frames = []
    for i in range(num_frames):
        rgb = bg.copy()
        # Per-frame additive noise on each channel (independent)
        noise = rng.integers(-4, 5, size=rgb.shape, dtype=np.int16)
        rgb = np.clip(rgb.astype(np.int16) + noise, 0, 255).astype(np.uint8)

        if i > 0:
            # Box A: fast L→R, top band, red
            t_a = i / max(num_frames - 1, 1)
            ax = int(t_a * (width - box_w))
            ay = height // 8
            _place_object(rgb, ax, ay, box_w, box_h, luma=0, rgb=(255, 80, 80))

            # Box B: medium T→B, vertical centreline, green
            t_b = i / max(2 * num_frames - 1, 1)
            bx = (width - box_w) // 2
            by = int(t_b * (height - box_h))
            _place_object(rgb, bx, by, box_w, box_h, luma=0, rgb=(80, 220, 80))

            # Box C: slow diagonal BL→TR, cyan
            t_c = i / max(4 * num_frames - 1, 1)
            cx = int(t_c * (width - box_w))
            cy = int((1.0 - t_c) * (height - box_h))
            _place_object(rgb, cx, cy, box_w, box_h, luma=0, rgb=(80, 220, 220))

        frames.append(rgb)
    return frames
```

Then register it in the dispatch dict. Find the existing dict around line 110 of `video_source.py` and add the new key — the key order should match the dict entry for `multi_speed`:

```python
        "multi_speed":       _gen_multi_speed,
        "multi_speed_color": _gen_multi_speed_color,   # ← add this line
        "stopping_object":   _gen_stopping_object,
```

Also extend the module docstring's source list (around line 7):

```python
      moving_box, dark_moving_box, two_boxes, noisy_moving_box,
      lighting_ramp, textured_static, entering_object, multi_speed,
      multi_speed_color, stopping_object, lit_moving_object, thin_moving_line
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest py/tests/test_video_source_helpers.py -v
```

Expected: all tests PASS, including the four new `multi_speed_color` tests.

- [ ] **Step 5: Add the README synthetic-source table row**

In `README.md`, in the "Synthetic Sources" table (around line 180-195), add a row immediately after `multi_speed`:

```markdown
| `synthetic:multi_speed_color` | Colored variant of `multi_speed`: red / green / cyan soft-edged boxes on a tinted RGB textured bg. Used for the README demo (`make demo-synthetic`). |
```

- [ ] **Step 6: Commit**

```bash
git add py/frames/video_source.py py/tests/test_video_source_helpers.py README.md
git commit -m "demo: add multi_speed_color synthetic source"
```

---

## ★ HUMAN-REVIEW CHECKPOINT CP-1 — synthetic source visual sanity

**STOP. Run the following and ask the human to visually verify before proceeding:**

```bash
source .venv/bin/activate
make prepare SOURCE=synthetic:multi_speed_color WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary CFG=default
make sw-dry-run                  # bypasses RTL — input file looped to output
make render
ls -lh renders/synthetic-multi-speed-color__*.png
```

The human opens the rendered PNG and confirms:

1. Three distinct colored boxes (red, green, cyan) are clearly visible in frames 1+.
2. Background is a soft tinted texture, not flat.
3. Frame 0 panel is bg-only (no boxes).
4. Box trajectories make sense (red moves L→R top, green moves T→B middle, cyan moves diagonally bottom-left to top-right).

If any of those fail, fix the generator and re-run before continuing. **Do not proceed to Task 5 without sign-off.**

---

## Task 5: New `demo` algorithm profile

Add `CFG_DEMO` in SystemVerilog and `DEMO` in Python. Identical to `default` except `scaler_en=0` and the resulting profile name is `demo`.

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv` (add `CFG_DEMO` after the existing `CFG_NO_SCALER`)
- Modify: `py/profiles.py` (add `DEMO` and entry in the named-profiles dict)

- [ ] **Step 1: Add `CFG_DEMO` in `sparevideo_pkg.sv`**

Find the existing `CFG_NO_SCALER` definition (search for `scaler_en:         1'b0` block; it lives roughly mid-file). Immediately after the closing `};` of `CFG_NO_SCALER`, add:

```systemverilog
    // CFG_DEMO: identical to CFG_DEFAULT but with scaler_en=0 so the README demo
    // composes 320x240 panels directly without 2x upscaling. All other stages on.
    localparam cfg_t CFG_DEMO = '{
        alpha_shift:       3,
        alpha_shift_slow:  6,
        grace_frames:      0,
        grace_alpha_shift: 1,
        gauss_en:          1'b1,
        morph_en:          1'b1,
        hflip_en:          1'b0,
        gamma_en:          1'b1,
        scaler_en:         1'b0,
        hud_en:            1'b1
    };
```

(If your local file's `cfg_t` field set has additional fields — `alpha_shift_slow` evolved over time — copy the field list verbatim from the existing `CFG_DEFAULT` block and only flip `scaler_en` to `1'b0`. The parity test catches any missed field.)

- [ ] **Step 2: Wire `CFG_DEMO` into the profile selector**

In `sparevideo_pkg.sv`, find the `select_cfg(CFG_NAME)` (or equivalent string→struct dispatch) function. Add a branch for `"demo"`:

```systemverilog
        end else if (CFG_NAME == "demo") begin
            return CFG_DEMO;
```

Place it adjacent to the existing `"no_scaler"` branch. Confirm the function returns `CFG_DEFAULT` as the fallback so a typo doesn't silently pick the wrong profile.

- [ ] **Step 3: Add `DEMO` in `py/profiles.py`**

In `py/profiles.py`, immediately after the existing `NO_SCALER` definition, add:

```python
DEMO: ProfileT = dict(DEFAULT, scaler_en=False)
```

Then add `"demo": DEMO` to the named-profiles dict, adjacent to `"no_scaler"`:

```python
    "no_scaler":     NO_SCALER,
    "demo":          DEMO,
    "no_hud":        NO_HUD,
```

- [ ] **Step 4: Run the profile parity test**

```bash
pytest py/tests/test_profiles.py -v
```

Expected: PASS. (This test verifies that every Python profile dict has the same key set as the SV `cfg_t` struct.)

- [ ] **Step 5: Run a smoke pipeline with `CFG=demo`**

```bash
make run-pipeline SOURCE=synthetic:moving_box CTRL_FLOW=motion CFG=demo FRAMES=4
```

Expected: pipeline completes successfully. Output should be 320×240 (scaler off), with HUD overlay visible.

- [ ] **Step 6: Commit**

```bash
git add hw/top/sparevideo_pkg.sv py/profiles.py
git commit -m "demo: add 'demo' algorithm profile (default with scaler_en=0)"
```

---

## ★ HUMAN-REVIEW CHECKPOINT CP-2 — `demo` profile end-to-end

**STOP. Run the following and ask the human to verify before proceeding:**

```bash
make run-pipeline SOURCE=synthetic:multi_speed_color CTRL_FLOW=motion CFG=demo FRAMES=8
ls -lh renders/synthetic-multi-speed-color__*motion__cfg=demo.png
```

The human opens the comparison PNG and confirms:

1. Output panel is 320×240 (matching input — no scaler-induced 2x growth).
2. HUD text is legible at 320×240 (not cut off, not tiny).
3. Motion bboxes are drawn around the colored boxes from frame 1 onward.
4. No regression — all `make test-py` and `make test-ip` pass.

```bash
make test-py && make test-ip
```

Expected: all green. **Do not proceed to Task 6 without sign-off.**

---

## Task 6: Implement `compose_triptych` core (no labels yet)

A pure function that takes three lists of 320×240 RGB ndarrays and returns a list of 960×240 PIL Images. Panel labels are added in Task 7.

**Files:**
- Modify: `py/demo/compose.py` (replace empty file with the core function)
- Create: `py/tests/test_demo_compose.py`

- [ ] **Step 1: Write the failing test**

Create `py/tests/test_demo_compose.py`:

```python
"""Unit tests for py/demo/compose.py — triptych assembly."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np
from PIL import Image

from demo.compose import compose_triptych


def _solid_frames(color, count, w, h):
    return [np.full((h, w, 3), color, dtype=np.uint8) for _ in range(count)]


def test_compose_dimensions():
    inp = _solid_frames((255, 0, 0), 3, 8, 4)
    ccl = _solid_frames((0, 255, 0), 3, 8, 4)
    mot = _solid_frames((0, 0, 255), 3, 8, 4)
    out = compose_triptych(inp, ccl, mot)
    assert len(out) == 3
    for img in out:
        assert isinstance(img, Image.Image)
        assert img.size == (24, 4)  # 3 panels × 8 wide, 4 tall
        assert img.mode == "RGB"


def test_compose_panel_content():
    """Each panel reflects the corresponding source stream's pixel content."""
    inp = _solid_frames((255, 0, 0), 1, 8, 4)
    ccl = _solid_frames((0, 255, 0), 1, 8, 4)
    mot = _solid_frames((0, 0, 255), 1, 8, 4)
    img = np.array(compose_triptych(inp, ccl, mot)[0])
    # Panel 0: x ∈ [0..7] should be all red
    assert (img[:, 0:8] == [255, 0, 0]).all()
    # Panel 1: x ∈ [8..15] should be all green
    assert (img[:, 8:16] == [0, 255, 0]).all()
    # Panel 2: x ∈ [16..23] should be all blue
    assert (img[:, 16:24] == [0, 0, 255]).all()


def test_compose_frame_count_mismatch_raises():
    inp = _solid_frames((255, 0, 0), 3, 8, 4)
    ccl = _solid_frames((0, 255, 0), 2, 8, 4)
    mot = _solid_frames((0, 0, 255), 3, 8, 4)
    import pytest
    with pytest.raises(AssertionError):
        compose_triptych(inp, ccl, mot)


def test_compose_dimension_mismatch_raises():
    inp = _solid_frames((255, 0, 0), 1, 8, 4)
    ccl = _solid_frames((0, 255, 0), 1, 8, 4)
    mot = _solid_frames((0, 0, 255), 1, 16, 4)   # different width
    import pytest
    with pytest.raises(AssertionError):
        compose_triptych(inp, ccl, mot)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_demo_compose.py -v
```

Expected: all four tests FAIL with `ImportError: cannot import name 'compose_triptych'`.

- [ ] **Step 3: Implement `compose_triptych`**

Replace the contents of `py/demo/compose.py` with:

```python
"""Triptych composition for the README demo: Input | CCL BBOX | MOTION."""

from typing import List
import numpy as np
from PIL import Image


def compose_triptych(
    input_frames:  List[np.ndarray],
    ccl_frames:    List[np.ndarray],
    motion_frames: List[np.ndarray],
) -> List[Image.Image]:
    """Build per-frame side-by-side triptychs.

    All three input streams must be RGB888 ndarrays with identical shape
    (H, W, 3) and identical frame counts. Output frames are PIL RGB Images of
    size (3*W, H). Panels abut directly with no separator column.
    """
    n = len(input_frames)
    assert len(ccl_frames) == n and len(motion_frames) == n, \
        f"frame count mismatch: input={n} ccl={len(ccl_frames)} motion={len(motion_frames)}"
    assert n > 0, "at least one frame required"

    h, w, _ = input_frames[0].shape
    for f in input_frames + ccl_frames + motion_frames:
        assert f.shape == (h, w, 3), f"shape mismatch: expected ({h}, {w}, 3), got {f.shape}"
        assert f.dtype == np.uint8, f"dtype must be uint8, got {f.dtype}"

    out: List[Image.Image] = []
    for i in range(n):
        canvas = np.zeros((h, 3 * w, 3), dtype=np.uint8)
        canvas[:, 0:w]         = input_frames[i]
        canvas[:, w:2*w]       = ccl_frames[i]
        canvas[:, 2*w:3*w]     = motion_frames[i]
        out.append(Image.fromarray(canvas, mode="RGB"))
    return out
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest py/tests/test_demo_compose.py -v
```

Expected: all four tests PASS.

- [ ] **Step 5: Commit**

```bash
git add py/demo/compose.py py/tests/test_demo_compose.py
git commit -m "demo: implement compose_triptych core (panels-only, no labels)"
```

---

## Task 7: Add panel labels using the existing 8×8 bitmap font

Renders `INPUT` / `CCL BBOX` / `MOTION` in the top-right corner of each panel, white-on-black, using the existing font ROM. Labels avoid colliding with the HUD (top-left, coord 8,8).

**Files:**
- Modify: `py/demo/compose.py` (add `_draw_label` helper and call sites)
- Modify: `py/tests/test_demo_compose.py` (add label-placement test)

- [ ] **Step 1: Add the failing test**

Append to `py/tests/test_demo_compose.py`:

```python
def test_compose_labels_are_drawn_top_right():
    """A small rectangular region in each panel's top-right contains label pixels (non-zero)."""
    inp = _solid_frames((0, 0, 0), 1, 320, 240)
    ccl = _solid_frames((0, 0, 0), 1, 320, 240)
    mot = _solid_frames((0, 0, 0), 1, 320, 240)
    img = np.array(compose_triptych(inp, ccl, mot)[0])
    # All-black panels → only label pixels can be non-zero. Probe each panel's
    # top-right region (last 80 px of width × first 16 px of height).
    for panel_idx in range(3):
        x0 = panel_idx * 320 + 240   # right 80 px of the panel
        x1 = (panel_idx + 1) * 320
        region = img[0:16, x0:x1]
        assert region.sum() > 0, f"panel {panel_idx}: no label pixels found in top-right"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_demo_compose.py::test_compose_labels_are_drawn_top_right -v
```

Expected: FAIL — no labels yet, regions are all-zero.

- [ ] **Step 3: Implement label rendering**

Replace `py/demo/compose.py` with the full version (label helper + call sites):

```python
"""Triptych composition for the README demo: Input | CCL BBOX | MOTION."""

from typing import List, Tuple
import numpy as np
from PIL import Image

# Font ROM lives next to the existing HUD model mirror.
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from models.ops.hud_font import FONT_ROM, GLYPH_IDX

PANEL_LABELS = ("INPUT", "CCL BBOX", "MOTION")
LABEL_PAD_TOP = 8
LABEL_PAD_RIGHT = 8
GLYPH_W = 8
GLYPH_H = 8


def _draw_label(canvas: np.ndarray, text: str, x: int, y: int,
                color: Tuple[int, int, int] = (255, 255, 255)) -> None:
    """Stamp `text` onto `canvas` at top-left coord (x, y) using the 8x8 font.

    Unknown glyphs (any char not in GLYPH_IDX) render as a blank space — silent
    fallback rather than raising, since labels are author-controlled.
    """
    H, W, _ = canvas.shape
    for ch_i, ch in enumerate(text):
        gx = x + ch_i * GLYPH_W
        if gx + GLYPH_W > W:
            break
        if ch not in GLYPH_IDX:
            continue
        rom_row = FONT_ROM[GLYPH_IDX[ch]]
        for py_off in range(GLYPH_H):
            row_bits = rom_row[py_off]
            cy = y + py_off
            if cy < 0 or cy >= H:
                continue
            for bit in range(GLYPH_W):
                if row_bits & (0x80 >> bit):
                    cx = gx + bit
                    if 0 <= cx < W:
                        canvas[cy, cx] = color


def compose_triptych(
    input_frames:  List[np.ndarray],
    ccl_frames:    List[np.ndarray],
    motion_frames: List[np.ndarray],
) -> List[Image.Image]:
    """Build per-frame side-by-side triptychs (Input | CCL BBOX | MOTION).

    All three input streams must be RGB888 ndarrays with identical shape
    (H, W, 3) and identical frame counts. Output frames are PIL RGB Images of
    size (3*W, H). Panels abut directly. Panel labels render in the top-right
    of each panel using the existing 8x8 HUD font.
    """
    n = len(input_frames)
    assert len(ccl_frames) == n and len(motion_frames) == n, \
        f"frame count mismatch: input={n} ccl={len(ccl_frames)} motion={len(motion_frames)}"
    assert n > 0, "at least one frame required"

    h, w, _ = input_frames[0].shape
    for f in input_frames + ccl_frames + motion_frames:
        assert f.shape == (h, w, 3), f"shape mismatch: expected ({h}, {w}, 3), got {f.shape}"
        assert f.dtype == np.uint8, f"dtype must be uint8, got {f.dtype}"

    out: List[Image.Image] = []
    for i in range(n):
        canvas = np.zeros((h, 3 * w, 3), dtype=np.uint8)
        canvas[:, 0:w]     = input_frames[i]
        canvas[:, w:2*w]   = ccl_frames[i]
        canvas[:, 2*w:3*w] = motion_frames[i]

        for panel_idx, label in enumerate(PANEL_LABELS):
            label_w = len(label) * GLYPH_W
            panel_right = (panel_idx + 1) * w
            x = panel_right - label_w - LABEL_PAD_RIGHT
            y = LABEL_PAD_TOP
            _draw_label(canvas, label, x, y)

        out.append(Image.fromarray(canvas, mode="RGB"))
    return out
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest py/tests/test_demo_compose.py -v
```

Expected: all five tests PASS.

- [ ] **Step 5: Generate a single-frame debug PNG for visual inspection**

This serves CP-3. Run:

```bash
source .venv/bin/activate
python -c "
import sys, numpy as np
sys.path.insert(0, 'py')
from demo.compose import compose_triptych
from PIL import Image

# Three solid panels with distinct colors so you can see panel boundaries
H, W = 240, 320
inp = [np.full((H, W, 3), (40, 40, 80), dtype=np.uint8)]   # dark blue-grey
ccl = [np.full((H, W, 3), (60, 60, 60), dtype=np.uint8)]   # mid grey
mot = [np.full((H, W, 3), (80, 40, 40), dtype=np.uint8)]   # dark red-grey

img = compose_triptych(inp, ccl, mot)[0]
img.save('/tmp/triptych_smoke.png')
print(f'Saved {img.size[0]}x{img.size[1]} preview to /tmp/triptych_smoke.png')
"
```

Expected: prints `Saved 960x240 preview to /tmp/triptych_smoke.png`.

- [ ] **Step 6: Commit**

```bash
git add py/demo/compose.py py/tests/test_demo_compose.py
git commit -m "demo: render INPUT/CCL BBOX/MOTION labels in panel top-right"
```

---

## ★ HUMAN-REVIEW CHECKPOINT CP-3 — first composed triptych frame

**STOP. Ask the human to open `/tmp/triptych_smoke.png` and verify before proceeding:**

1. Image is 960×240, three colored panels abut at x=320 and x=640.
2. Each panel has its label visible in the top-right corner: `INPUT`, `CCL BBOX`, `MOTION`.
3. Label text is legible (white-on-dark, 8×8 font).
4. Labels do not collide with where the RTL HUD would render (top-left at 8,8 within each panel).

```bash
wslview /tmp/triptych_smoke.png
```

If labels are mispositioned, off-by-one, or unreadable, fix Task 7 before continuing. **Do not proceed to Task 8 without sign-off.**

---

## Task 8: Implement `write_webp` encoder

**Files:**
- Modify: `py/demo/encode.py` (replace empty file)
- Create: `py/tests/test_demo_encode.py`

- [ ] **Step 1: Write the failing test**

Create `py/tests/test_demo_encode.py`:

```python
"""Unit tests for py/demo/encode.py — animated WebP round-trip."""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PIL import Image

from demo.encode import write_webp


def _solid_frames(color, count, w, h):
    return [Image.new("RGB", (w, h), color) for _ in range(count)]


def test_write_webp_creates_file():
    frames = _solid_frames((128, 0, 0), 3, 16, 8)
    with tempfile.NamedTemporaryFile(suffix=".webp", delete=False) as f:
        path = f.name
    write_webp(frames, path, fps=15)
    assert Path(path).exists()
    assert Path(path).stat().st_size > 0


def test_write_webp_round_trip_frame_count():
    frames = _solid_frames((0, 128, 0), 5, 16, 8)
    with tempfile.NamedTemporaryFile(suffix=".webp", delete=False) as f:
        path = f.name
    write_webp(frames, path, fps=15)
    decoded = Image.open(path)
    # Animated WebP exposes n_frames
    assert getattr(decoded, "n_frames", 1) == 5


def test_write_webp_round_trip_dimensions():
    frames = _solid_frames((0, 0, 128), 2, 32, 16)
    with tempfile.NamedTemporaryFile(suffix=".webp", delete=False) as f:
        path = f.name
    write_webp(frames, path, fps=15)
    decoded = Image.open(path)
    assert decoded.size == (32, 16)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest py/tests/test_demo_encode.py -v
```

Expected: all three tests FAIL with `ImportError: cannot import name 'write_webp'`.

- [ ] **Step 3: Implement `write_webp`**

Replace the contents of `py/demo/encode.py` with:

```python
"""Animated WebP encoder for the README demo."""

from pathlib import Path
from typing import List, Union
from PIL import Image


def write_webp(
    frames: List[Image.Image],
    path: Union[str, Path],
    fps: int = 15,
    quality: int = 80,
) -> None:
    """Write `frames` as an animated WebP that loops forever.

    All frames must be the same size and mode. `fps` controls per-frame display
    duration; `quality` is Pillow's WebP quality knob (0–100, higher = bigger).
    """
    assert len(frames) > 0, "at least one frame required"
    duration_ms = max(int(round(1000 / fps)), 1)
    frames[0].save(
        str(path),
        save_all=True,
        append_images=frames[1:],
        duration=duration_ms,
        loop=0,                # 0 = infinite
        lossless=False,
        quality=quality,
        method=6,              # slowest/best encoder method
    )
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest py/tests/test_demo_encode.py -v
```

Expected: all three tests PASS.

- [ ] **Step 5: Commit**

```bash
git add py/demo/encode.py py/tests/test_demo_encode.py
git commit -m "demo: implement write_webp animated encoder"
```

---

## Task 9: CLI entry point + `make demo-synthetic` target

Wires the composer + encoder behind `python -m py.demo` and a Makefile target that runs the full chain.

**Files:**
- Modify: `py/demo/__init__.py` (add `main()` invoked via `python -m py.demo`)
- Create: `py/demo/__main__.py` (thin wrapper that calls `main()`)
- Modify: `dv/sim/Makefile` (add `demo-synthetic` and aggregate `demo` targets)

- [ ] **Step 1: Implement the CLI**

Replace the contents of `py/demo/__init__.py` with:

```python
"""Demo asset generation: compose triptychs and encode animated WebP for the README.

Invoked as:
    python -m py.demo --input <input.bin> --ccl <ccl.bin> --motion <motion.bin> \
                      --out <out.webp> [--fps 15]
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from frames.frame_io import read_frames
from demo.compose import compose_triptych
from demo.encode import write_webp


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Compose + encode the README demo WebP.")
    p.add_argument("--input",  required=True, help="Path to input frames (.bin)")
    p.add_argument("--ccl",    required=True, help="Path to ccl_bbox sim output (.bin)")
    p.add_argument("--motion", required=True, help="Path to motion sim output (.bin)")
    p.add_argument("--out",    required=True, help="Output animated WebP path")
    p.add_argument("--width",  type=int, required=True)
    p.add_argument("--height", type=int, required=True)
    p.add_argument("--frames", type=int, required=True)
    p.add_argument("--fps",    type=int, default=15)
    args = p.parse_args(argv)

    inp = read_frames(args.input,  mode="binary",
                      width=args.width, height=args.height, num_frames=args.frames)
    ccl = read_frames(args.ccl,    mode="binary",
                      width=args.width, height=args.height, num_frames=args.frames)
    mot = read_frames(args.motion, mode="binary",
                      width=args.width, height=args.height, num_frames=args.frames)

    triptych = compose_triptych(inp, ccl, mot)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    write_webp(triptych, args.out, fps=args.fps)
    print(f"Wrote {args.out} ({len(triptych)} frames @ {args.fps} fps)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Create `py/demo/__main__.py`:

```python
"""Allow invocation as `python -m py.demo`."""
from demo import main

if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Smoke-test the CLI with hand-picked args**

Generate dummy bin files via the existing sim chain and run the CLI:

```bash
make prepare SOURCE=synthetic:multi_speed_color WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary CFG=demo
make compile CTRL_FLOW=ccl_bbox CFG=demo
make sim     CTRL_FLOW=ccl_bbox CFG=demo
cp dv/data/output.bin /tmp/output_ccl_bbox.bin
make compile CTRL_FLOW=motion CFG=demo
make sim     CTRL_FLOW=motion CFG=demo
cp dv/data/output.bin /tmp/output_motion.bin

source .venv/bin/activate
PYTHONPATH=py python -m demo \
    --input  dv/data/input.bin \
    --ccl    /tmp/output_ccl_bbox.bin \
    --motion /tmp/output_motion.bin \
    --out    /tmp/synthetic_smoke.webp \
    --width 320 --height 240 --frames 8 --fps 15
```

Expected: prints `Wrote /tmp/synthetic_smoke.webp (8 frames @ 15 fps)` and the file exists.

- [ ] **Step 3: Add make targets**

In `dv/sim/Makefile`, append (or place adjacent to existing `run-pipeline`):

```make
# README demo — synthetic + real animated WebP triptychs.
DEMO_FRAMES ?= 45
DEMO_WIDTH  ?= 320
DEMO_HEIGHT ?= 240
DEMO_FPS    ?= 15

demo: demo-synthetic demo-real

demo-synthetic:
	$(MAKE) prepare SOURCE=synthetic:multi_speed_color \
	    WIDTH=$(DEMO_WIDTH) HEIGHT=$(DEMO_HEIGHT) FRAMES=$(DEMO_FRAMES) MODE=binary CFG=demo
	$(MAKE) compile CTRL_FLOW=ccl_bbox CFG=demo
	$(MAKE) sim     CTRL_FLOW=ccl_bbox CFG=demo
	cp dv/data/output.bin dv/data/output_ccl_bbox.bin
	$(MAKE) compile CTRL_FLOW=motion CFG=demo
	$(MAKE) sim     CTRL_FLOW=motion CFG=demo
	cp dv/data/output.bin dv/data/output_motion.bin
	cd $(REPO_ROOT) && PYTHONPATH=py .venv/bin/python -m demo \
	    --input  dv/data/input.bin \
	    --ccl    dv/data/output_ccl_bbox.bin \
	    --motion dv/data/output_motion.bin \
	    --out    media/demo/synthetic.webp \
	    --width $(DEMO_WIDTH) --height $(DEMO_HEIGHT) --frames $(DEMO_FRAMES) \
	    --fps   $(DEMO_FPS)

demo-real:
	@echo "demo-real is implemented in Task 11 (depends on committed Pexels source clip)."
	@false
```

The `demo-real` target is a stub that errors out — it gets filled in Task 11 once the source clip is committed. This keeps `make demo-synthetic` runnable now without forcing the real-clip work first.

(`REPO_ROOT` is already defined elsewhere in the existing Makefile. If not, use `$(CURDIR)/..` or whatever pattern the existing targets use to escape `dv/sim/`.)

- [ ] **Step 4: Run `make demo-synthetic`**

```bash
make demo-synthetic
ls -lh media/demo/synthetic.webp
du -h media/demo/synthetic.webp
```

Expected: completes successfully (~2 min sim wall time), produces `media/demo/synthetic.webp` of size <5 MB.

- [ ] **Step 5: Delete the `media/demo/.gitkeep` placeholder**

Now that `synthetic.webp` lives there, the `.gitkeep` is no longer needed.

```bash
git rm media/demo/.gitkeep
```

- [ ] **Step 6: Commit**

```bash
git add py/demo/__init__.py py/demo/__main__.py dv/sim/Makefile media/demo/synthetic.webp
git commit -m "demo: add make demo-synthetic target + ship synthetic WebP"
```

---

## ★ HUMAN-REVIEW CHECKPOINT CP-4 — first synthetic WebP

**STOP. Ask the human to verify before proceeding:**

```bash
wslview media/demo/synthetic.webp
du -h media/demo/synthetic.webp
```

The human confirms in the browser:

1. The WebP autoplays and loops smoothly.
2. ~3 seconds per loop.
3. Three panels visible left-to-right: INPUT, CCL BBOX, MOTION (labels readable in top-right of each panel).
4. Bboxes track the colored objects across the right two panels; the input panel shows the raw colored boxes only.
5. File size is <5 MB.

If file is too large, drop `quality` from 80 to 70 in `py/demo/encode.py` and rerun. If labels are wrong / panels misordered, fix and rerun. **Do not proceed to Task 10 without sign-off.**

---

## Task 10: Pexels source clip prep + commit

This is a **manual** task — it is not regenerable from `make`. The output is one committed MP4 file, plus a small README in `media/source/` documenting the source URL, license, and ffmpeg command.

**Files:**
- Create: `media/source/pexels-pedestrians-320x240.mp4`
- Create: `media/source/README.md`
- Delete: `media/source/.gitkeep`

- [ ] **Step 1: Pick a clip on Pexels**

Browse https://www.pexels.com/videos/ for a clip matching:

- Fixed camera (no panning/zooming).
- Top-down or wide-fixed view of pedestrians or traffic.
- ~5–10 s long (we'll trim to 3 s).
- Clear, well-lit, low-noise.
- Multiple visible moving subjects (helps demo the N=4 CCL ranking).

Download the smallest available resolution that's still ≥ 720p (we're going to scale to 320×240 anyway).

Suggested search terms: `top down pedestrian crossing`, `pedestrians from above fixed`, `traffic intersection static`.

- [ ] **Step 2: Trim and resize with ffmpeg**

Pick a 3-second window with continuous motion. Run:

```bash
ffmpeg -ss <start_s> -t 3 -i ~/Downloads/<original>.mp4 \
       -vf "crop=<crop_expr>,scale=320:240" -r 15 -c:v libx264 -an -y \
       media/source/pexels-pedestrians-320x240.mp4
```

`<crop_expr>` should letterbox the source to 4:3 if it's 16:9. Example for 1920×1080 → 4:3:
```
crop=1440:1080:240:0
```
That crops a 1440×1080 4:3 region from the centre of a 1920×1080 frame. Adjust the X offset to centre the action.

- [ ] **Step 3: Verify the output**

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,nb_frames \
        -of default=nw=1 media/source/pexels-pedestrians-320x240.mp4
du -h media/source/pexels-pedestrians-320x240.mp4
```

Expected: `width=320`, `height=240`, `r_frame_rate=15/1`, `nb_frames=45`, file size <5 MB. If the clip has audio (`-an` should remove it), re-run with `-an`.

- [ ] **Step 4: Create `media/source/README.md`**

```markdown
# Source clips

Source video used by `make demo-real`. Pre-trimmed to ~3 s and pre-resized to
320×240 so the existing OpenCV loader can ingest it directly.

## `pexels-pedestrians-320x240.mp4`

- **Source:** https://www.pexels.com/video/<actual-pexels-url>
- **License:** Pexels License — free for commercial and non-commercial use,
  modification and redistribution permitted, no attribution required.
  See https://www.pexels.com/license/.
- **Prep command:**
  ```bash
  ffmpeg -ss <start> -t 3 -i <original>.mp4 \
         -vf "crop=<expr>,scale=320:240" -r 15 -c:v libx264 -an \
         media/source/pexels-pedestrians-320x240.mp4
  ```

## Replacing this clip

If you swap to a different source clip:

1. `git rm media/source/<old>.mp4`
2. Drop the new pre-prepped clip in `media/source/`.
3. Update this README's "Source" / "Prep command" lines.
4. Run `make demo-real` to regenerate the WebP.
5. Commit all three: source MP4, this README, regenerated demo WebP.
```

(Replace `<actual-pexels-url>` with the real Pexels page URL of the clip you picked.)

- [ ] **Step 5: Remove the placeholder and commit**

```bash
git rm media/source/.gitkeep
git add media/source/pexels-pedestrians-320x240.mp4 media/source/README.md
git commit -m "demo: commit Pexels pedestrian source clip + provenance README"
```

---

## ★ HUMAN-REVIEW CHECKPOINT CP-5 — committed source clip plays correctly

**STOP. Ask the human to verify before proceeding:**

```bash
wslview media/source/pexels-pedestrians-320x240.mp4
```

The human confirms:

1. Clip plays at ~15 fps for ~3 s.
2. Resolution looks correct (320×240, 4:3).
3. Camera is static (no panning).
4. Moving subjects are visible at this resolution — they're not too small to detect.
5. No audio.

If the clip has issues, redo Task 10 with a different start time, crop, or different source clip. **Do not proceed to Task 11 without sign-off.**

---

## Task 11: Implement `make demo-real`

Replaces the stub from Task 9.

**Files:**
- Modify: `dv/sim/Makefile` (replace the `demo-real` stub with the real chain)

- [ ] **Step 1: Replace the stub**

In `dv/sim/Makefile`, replace the existing `demo-real` rule with:

```make
demo-real:
	$(MAKE) prepare SOURCE=$(REPO_ROOT)/media/source/pexels-pedestrians-320x240.mp4 \
	    WIDTH=$(DEMO_WIDTH) HEIGHT=$(DEMO_HEIGHT) FRAMES=$(DEMO_FRAMES) MODE=binary CFG=demo
	$(MAKE) compile CTRL_FLOW=ccl_bbox CFG=demo
	$(MAKE) sim     CTRL_FLOW=ccl_bbox CFG=demo
	cp dv/data/output.bin dv/data/output_ccl_bbox.bin
	$(MAKE) compile CTRL_FLOW=motion CFG=demo
	$(MAKE) sim     CTRL_FLOW=motion CFG=demo
	cp dv/data/output.bin dv/data/output_motion.bin
	cd $(REPO_ROOT) && PYTHONPATH=py .venv/bin/python -m demo \
	    --input  dv/data/input.bin \
	    --ccl    dv/data/output_ccl_bbox.bin \
	    --motion dv/data/output_motion.bin \
	    --out    media/demo/real.webp \
	    --width $(DEMO_WIDTH) --height $(DEMO_HEIGHT) --frames $(DEMO_FRAMES) \
	    --fps   $(DEMO_FPS)
```

- [ ] **Step 2: Run `make demo-real`**

```bash
make demo-real
ls -lh media/demo/real.webp
du -h media/demo/real.webp
```

Expected: completes successfully (~2 min wall time), produces `media/demo/real.webp` of size <5 MB.

- [ ] **Step 3: Run `make demo` (aggregate target) to confirm both build cleanly**

```bash
make demo
ls -lh media/demo/
```

Expected: both `synthetic.webp` and `real.webp` exist and are nonzero. (Aggregate is just `synthetic + real`; running it overwrites the previously committed synthetic with the same content.)

- [ ] **Step 4: Commit**

```bash
git add dv/sim/Makefile media/demo/real.webp
git commit -m "demo: implement make demo-real and ship real-video WebP"
```

---

## Task 12: README + CLAUDE.md integration

Add the Demo section, the Regenerating subsection, the synthetic-source table row (if not already done in Task 4), and the CLAUDE.md TODO entry.

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Insert the Demo section near the top of README.md**

Open `README.md`. Find the line ending the project-description paragraph (around line 7, immediately before `## Overview`). Insert:

```markdown
## Demo

### Synthetic input (`multi_speed_color`)

![Synthetic demo](media/demo/synthetic.webp)

Three colored objects with distinct speeds and trajectories. Left to right:
input frames, `ccl_bbox` (mask-as-grey + CCL bboxes), `motion` (full overlay).

### Real video (Pexels pedestrians)

![Real demo](media/demo/real.webp)

Top-down pedestrian crossing, 3 s clip from Pexels (Pexels License — free use,
modification, and redistribution; no attribution required). Source:
[`media/source/pexels-pedestrians-320x240.mp4`](media/source/pexels-pedestrians-320x240.mp4).

```

- [ ] **Step 2: Add a "Regenerating the demo" subsection under "Usage"**

Find the `## Usage` section in `README.md`. After the existing usage examples (just before "## Options"), add:

````markdown
### Regenerating the demo

After RTL changes that affect visual output, rebuild the demo WebPs and commit them with the change:

```bash
make demo                           # regenerates both WebPs
wslview media/demo/synthetic.webp   # preview in default browser (WSL via WSLg)
grip README.md                      # preview README at GitHub fidelity
```

`grip` is an optional dev tool (`pip install grip`) that renders local markdown using GitHub's API, useful for confirming the README looks right before pushing.

To swap the real-video source clip, see [`media/source/README.md`](media/source/README.md).
````

- [ ] **Step 3: Add the CLAUDE.md TODO entry**

Open `CLAUDE.md`. Find the section `## TODO after each major change` (or however it's headed in the current file — the bullet list of post-change checks). Add this bullet:

```markdown
- Regenerate demo WebPs (`make demo`) if RTL changes affected the visual output, and commit the regenerated `media/demo/*.webp` with the change.
```

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "demo: add Demo section + regenerating workflow to README + CLAUDE.md"
```

---

## ★ HUMAN-REVIEW CHECKPOINT CP-6 — README rendering

**STOP. Ask the human to verify before proceeding:**

```bash
pip install grip          # if not already installed
grip README.md            # opens http://localhost:6419
```

The human opens http://localhost:6419 in a browser and confirms:

1. The Demo section appears near the top of the README, before the architecture-spec table.
2. Both `synthetic.webp` and `real.webp` autoplay and loop in the rendered README.
3. Captions read sensibly.
4. The "Regenerating the demo" subsection appears under "Usage" with correct code formatting.
5. No broken image links.

If any image fails to render, check that the file path in the README matches the actual on-disk path (case-sensitive). **Do not proceed to Task 13 without sign-off.**

---

## Task 13: Final regression sweep + squash + PR

**Files:** none modified — verification + git operations only.

- [ ] **Step 1: Run the full Python test suite**

```bash
make test-py
```

Expected: every test passes.

- [ ] **Step 2: Run all per-IP unit testbenches**

```bash
make test-ip
```

Expected: every IP test passes.

- [ ] **Step 3: Run a sanity end-to-end with the default profile**

```bash
make run-pipeline SOURCE=synthetic:moving_box CTRL_FLOW=motion CFG=default FRAMES=4
```

Expected: full pipeline completes; `make verify` returns pixel-accurate match (TOLERANCE=0). Confirms no regression to existing flows from the helper extensions or the new profile.

- [ ] **Step 4: Run lint**

```bash
make lint
```

Expected: no Verilator warnings (the only RTL change in this plan is the new `CFG_DEMO` localparam, which should not introduce any).

- [ ] **Step 5: Inspect commits on the branch**

```bash
git log --oneline origin/main..HEAD
```

Expected: 11 or 12 commits, all scoped to this plan (no tangential refactors). If any commit is off-topic per the CLAUDE.md "one branch per plan" rule, move it to a separate branch + PR before squashing.

- [ ] **Step 6: Squash all commits into one**

```bash
git reset --soft origin/main
git commit -m "$(cat <<'EOF'
demo: add animated WebP triptychs to the README

Add `make demo-synthetic` and `make demo-real` targets that run the existing
prepare → compile → sim chain twice (CTRL_FLOW=ccl_bbox, then CTRL_FLOW=motion)
on the same source frames, then compose Input | CCL BBOX | MOTION triptychs and
encode them as animated WebP for embed in the README.

- New `multi_speed_color` synthetic source (red / green / cyan boxes on tinted
  textured bg) for the synthetic demo.
- New `demo` algorithm profile (default with scaler_en=0) so panels compose
  cleanly at 320×240 native.
- New `py/demo/` module: compose_triptych + write_webp + CLI.
- Pexels pedestrian clip pre-trimmed to 320×240, committed under media/source/
  with a provenance README.
- README Demo section + Regenerating subsection.
- CLAUDE.md TODO entry to keep demo WebPs fresh on RTL changes.
EOF
)"
```

- [ ] **Step 7: Push and open PR**

```bash
git push -u origin feat/readme-demo
gh pr create --title "demo: animated WebP triptychs in README" --body "$(cat <<'EOF'
## Summary

- Adds `make demo-synthetic` / `make demo-real` / `make demo` targets that produce
  Input | CCL BBOX | MOTION animated WebP triptychs for embed in the README.
- Implements `multi_speed_color` synthetic source and `demo` algorithm profile
  (default with scaler_en=0).
- New `py/demo/` package: composer + WebP encoder + CLI entry.
- Commits a 320×240 trimmed Pexels pedestrian clip as the real-video source.
- README and CLAUDE.md updated.

Spec: `docs/plans/2026-04-30-readme-demo-design.md`
Plan: `docs/plans/2026-04-30-readme-demo-plan.md`

## Test plan

- [x] `make test-py` passes (new compose / encode / video-source tests + existing).
- [x] `make test-ip` passes (no RTL behavioral change).
- [x] `make lint` clean (only addition is `CFG_DEMO` localparam).
- [x] `make run-pipeline CFG=default CTRL_FLOW=motion` regression — pixel-accurate.
- [x] `make demo` produces both WebPs <5 MB each; both autoplay in the rendered README.
- [x] All six human-review checkpoints (CP-1 through CP-6) signed off during execution.
EOF
)"
```

- [ ] **Step 8: Move the design doc to `docs/plans/old/` per CLAUDE.md**

CLAUDE.md says "After implementing a plan, move it to docs/plans/old/ and put a date timestamp on it." This applies to both the design and the plan once the PR is open and ready to merge.

```bash
mkdir -p docs/plans/old
git mv docs/plans/2026-04-30-readme-demo-design.md docs/plans/old/
git mv docs/plans/2026-04-30-readme-demo-plan.md   docs/plans/old/
git commit --amend --no-edit         # roll into the squashed commit
git push --force-with-lease
```

(The filename already carries the timestamp `2026-04-30`, so no rename is needed.)

---

## Self-review notes (post-write)

**Spec coverage check** — every section of the design spec maps to a task:

| Spec section | Task |
|---|---|
| §3 Repo layout | Tasks 1, 9, 10 (creates the directories) |
| §4 New synthetic source | Tasks 2, 3, 4 (helper extensions + new generator) |
| §5 New demo profile | Task 5 |
| §6 Triptych composer | Tasks 6, 7 |
| §7 WebP encoder | Task 8 |
| §8 CLI entry point | Task 9 |
| §9 Make targets | Tasks 9, 11 |
| §10 Real-clip preprocessing | Task 10 |
| §11 README integration | Task 12 |
| §12 CLAUDE.md addition | Task 12 |
| §13 Tests | Tasks 2–8 (each has its own tests) |
| §14 Preview workflow | CP-4 / CP-6 (uses `wslview` and `grip`) |
| §15 File-size budget | CP-4 / Task 11 enforce <5 MB at the checkpoints |
| §16 Checkpoints | All six baked in as ★ HUMAN-REVIEW CHECKPOINT blocks |
| §17 Out of scope | Honored — plan does not touch GitHub Pages, MP4 fallback, etc. |

**Label change vs spec** — design spec says `INPUT / CCL_BBOX / MOTION`; plan uses `INPUT / CCL BBOX / MOTION` because the existing 8×8 font has no underscore glyph. Documented in the plan preamble.

**Type / signature consistency** — `compose_triptych(input_frames, ccl_frames, motion_frames)` used identically across Tasks 6, 7, 9. `write_webp(frames, path, fps, quality)` used identically across Tasks 8, 9.
