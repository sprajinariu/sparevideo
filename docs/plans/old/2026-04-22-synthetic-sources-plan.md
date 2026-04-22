# Synthetic Source Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace six weak synthetic test patterns with five higher-quality ones (textured + noisy backgrounds, soft-edged multi-object motion) and add tests that verify the motion pipeline's positive/negative detection behaviour on each.

**Architecture:** All pattern generation lives in `py/frames/video_source.py`. Three new private helpers (`_make_bg_texture`, `_add_frame_noise`, `_place_object`) factor out the shared "sinusoid texture + per-frame sensor noise + soft-edged object" machinery. Five generators are deleted, five are added. One existing test that referenced the removed `color_bars` pattern is deleted (the identical-output invariant is already covered by `test_motion_static_scene`).

**Tech Stack:** Python 3, numpy, OpenCV (already a dependency, used for `cv2.GaussianBlur`).

---

## Reference design

All five new generators follow the same recipe from `docs/plans/2026-04-22-synthetic-sources-design.md`:

1. Compute a static sinusoid luma texture in the range `[base_luma-amp, base_luma+amp]` (default 80..120 with `base_luma=100, amp=20`).
2. For each frame, add per-frame integer noise in `[-noise_amp, +noise_amp]` (default 8, below `THRESH=16`).
3. Stack the greyscale result into an RGB frame.
4. Composite each soft-edged object via `frame = bg * (1 - alpha) + luma * alpha`, where `alpha` is the 5×5/σ=2 Gaussian-blurred binary box mask.

All randomness is seeded per generator so results are reproducible.

## File structure

- Modify: `py/frames/video_source.py` — module docstring, `_generate_synthetic` dict, remove six `_gen_*` functions, add three helpers + five `_gen_*` functions.
- Modify: `py/tests/test_models.py` — delete one test that references a removed pattern, add helper-level tests for each new helper, add one pattern-level test per new generator.
- Modify: `README.md` — default `SOURCE` and synthetic-source table.
- Modify: `Makefile` — default `SOURCE` and `help` source list.
- Modify: `CLAUDE.md` — command example and `Input sources:` pattern list.
- Modify: `py/harness.py` — `--source` default.

No RTL, Makefile target, or testbench changes. Synthetic source names flow through as free-form strings.

## Shared snippets

Several steps reuse the same file-top import line for `test_models.py`. The project uses the top-of-file imports at lines 1–13 of `py/tests/test_models.py`; no new imports are needed for the tests in this plan.

---

### Task 1: Add `_make_bg_texture` helper

**Files:**
- Modify: `py/frames/video_source.py` (append helper above `_gen_*` block, below line 122)
- Modify: `py/tests/test_models.py` (append to the end of the file, after `# ---- Grace-window tests ----`)

- [ ] **Step 1: Write the failing tests**

Append to `py/tests/test_models.py` (before the `if __name__ == "__main__":` block at line 741):

```python
# ---- New synthetic source helpers ----

from frames.video_source import _make_bg_texture, _add_frame_noise, _place_object


def test_make_bg_texture_shape_and_range():
    """Texture is (H, W) uint8 with values inside the configured luma window."""
    tex = _make_bg_texture(width=64, height=32, base_luma=100, amp=20)
    assert tex.shape == (32, 64)
    assert tex.dtype == np.uint8
    # Guard against off-by-one in the normalisation — allow ±2 luma slack.
    assert tex.min() >= 100 - 20 - 2
    assert tex.max() <= 100 + 20 + 2


def test_make_bg_texture_is_deterministic():
    """Same seed → identical output; different seed → non-identical output."""
    a = _make_bg_texture(width=32, height=16, seed=1)
    b = _make_bg_texture(width=32, height=16, seed=1)
    c = _make_bg_texture(width=32, height=16, seed=2)
    np.testing.assert_array_equal(a, b)
    assert not np.array_equal(a, c)


def test_make_bg_texture_not_flat():
    """Texture actually has spatial variation (not a constant field)."""
    tex = _make_bg_texture(width=64, height=32, base_luma=100, amp=20)
    assert int(tex.max()) - int(tex.min()) >= 10
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k make_bg_texture -v`
Expected: three FAILURES with `ImportError: cannot import name '_make_bg_texture'`.

- [ ] **Step 3: Implement the helper**

Insert the following block in `py/frames/video_source.py` immediately after line 122 (end of `_generate_synthetic`, before `def _gen_color_bars`):

```python
# ---- Shared helpers for textured/noisy synthetic patterns ----

def _make_bg_texture(width, height, base_luma=100, amp=20, seed=0xBE1F):
    """Static multi-frequency sinusoid luma texture clipped to ~[base-amp, base+amp].

    Returns a (height, width) uint8 array. Deterministic given `seed`.
    """
    rng = np.random.default_rng(seed)
    yy, xx = np.meshgrid(np.arange(height), np.arange(width), indexing="ij")
    components = [
        (0.05, 0.0),
        (0.09, np.pi / 3.0),
        (0.13, 2.0 * np.pi / 3.0),
    ]
    phases = rng.uniform(0.0, 2.0 * np.pi, size=len(components))
    tex = np.zeros((height, width), dtype=np.float32)
    for (freq, angle), phi in zip(components, phases):
        tex += np.sin(freq * (xx * np.cos(angle) + yy * np.sin(angle)) + phi)
    tex /= len(components)                       # normalise to ~[-1, 1]
    tex = base_luma + amp * tex                  # shift into luma window
    return np.clip(tex, 0, 255).astype(np.uint8)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k make_bg_texture -v`
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add py/frames/video_source.py py/tests/test_models.py
git commit -m "feat(py-frames): add _make_bg_texture helper for synthetic bg"
```

---

### Task 2: Add `_add_frame_noise` helper

**Files:**
- Modify: `py/frames/video_source.py` (append helper next to `_make_bg_texture`)
- Modify: `py/tests/test_models.py` (append to helper tests from Task 1)

- [ ] **Step 1: Write the failing tests**

Append to `py/tests/test_models.py` under `# ---- New synthetic source helpers ----`:

```python
def test_add_frame_noise_shape_dtype():
    """Noise output is (H, W) uint8 — same shape and dtype as input bg."""
    bg = np.full((16, 32), 100, dtype=np.uint8)
    rng = np.random.default_rng(0)
    out = _add_frame_noise(bg, rng, noise_amp=8)
    assert out.shape == bg.shape
    assert out.dtype == np.uint8


def test_add_frame_noise_bounded():
    """All output pixels are within ±noise_amp of the input bg."""
    bg = np.full((16, 32), 100, dtype=np.uint8)
    rng = np.random.default_rng(1)
    out = _add_frame_noise(bg, rng, noise_amp=8)
    diff = out.astype(np.int16) - bg.astype(np.int16)
    assert diff.min() >= -8
    assert diff.max() <= 8


def test_add_frame_noise_clipping():
    """Near 0 / 255 edges, output is clipped and never wraps."""
    dark = np.zeros((4, 4), dtype=np.uint8)
    bright = np.full((4, 4), 255, dtype=np.uint8)
    rng = np.random.default_rng(2)
    assert _add_frame_noise(dark, rng, noise_amp=8).min() >= 0
    assert _add_frame_noise(bright, rng, noise_amp=8).max() <= 255


def test_add_frame_noise_varies_frame_to_frame():
    """Successive calls on the same rng yield different noise fields."""
    bg = np.full((16, 32), 100, dtype=np.uint8)
    rng = np.random.default_rng(3)
    a = _add_frame_noise(bg, rng, noise_amp=8)
    b = _add_frame_noise(bg, rng, noise_amp=8)
    assert not np.array_equal(a, b)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k add_frame_noise -v`
Expected: 4 FAILURES with `ImportError: cannot import name '_add_frame_noise'`.

- [ ] **Step 3: Implement the helper**

Append to `py/frames/video_source.py` immediately after `_make_bg_texture`:

```python
def _add_frame_noise(bg, rng, noise_amp=8):
    """Add integer per-pixel noise in [-noise_amp, +noise_amp] to a uint8 greyscale bg.

    Returns a (H, W) uint8 array clipped to [0, 255]. Takes an explicit
    `rng` so the caller controls per-frame / per-generator determinism.
    """
    h, w = bg.shape
    noise = rng.integers(-noise_amp, noise_amp + 1,
                         size=(h, w), dtype=np.int16)
    return np.clip(bg.astype(np.int16) + noise, 0, 255).astype(np.uint8)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k add_frame_noise -v`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add py/frames/video_source.py py/tests/test_models.py
git commit -m "feat(py-frames): add _add_frame_noise helper"
```

---

### Task 3: Add `_place_object` helper

**Files:**
- Modify: `py/frames/video_source.py` (append helper next to `_add_frame_noise`)
- Modify: `py/tests/test_models.py` (append to helper tests)

- [ ] **Step 1: Write the failing tests**

Append to `py/tests/test_models.py` under `# ---- New synthetic source helpers ----`:

```python
def test_place_object_center_near_target_luma():
    """Interior of a large box has luma close to the object's target luma."""
    rgb = np.zeros((32, 32, 3), dtype=np.uint8)
    _place_object(rgb, x0=8, y0=8, box_w=16, box_h=16, luma=200)
    # Deep inside the box, the blurred alpha ≈ 1 → output ≈ luma on all channels.
    px = rgb[16, 16]
    assert abs(int(px[0]) - 200) <= 2
    assert abs(int(px[1]) - 200) <= 2
    assert abs(int(px[2]) - 200) <= 2


def test_place_object_far_outside_untouched():
    """Pixels far from the object retain their original bg value."""
    rgb = np.full((32, 32, 3), 50, dtype=np.uint8)
    _place_object(rgb, x0=8, y0=8, box_w=4, box_h=4, luma=200)
    # Pixels in the far corner should be well outside the 5x5 kernel's reach.
    np.testing.assert_array_equal(rgb[28, 28], [50, 50, 50])
    np.testing.assert_array_equal(rgb[0, 28], [50, 50, 50])
    np.testing.assert_array_equal(rgb[28, 0], [50, 50, 50])


def test_place_object_soft_edge_transition():
    """Along an edge, intermediate pixels fall between bg and object luma."""
    rgb = np.zeros((32, 32, 3), dtype=np.uint8)
    _place_object(rgb, x0=8, y0=8, box_w=16, box_h=16, luma=200)
    # Move along a horizontal line just inside the top edge: transition from 0 → ~200.
    # At least one pixel on that line should be strictly between (0, 200).
    row = rgb[8, :, 0].astype(int)
    assert np.any((row > 10) & (row < 190)), f"no soft-edge pixel found: {row}"


def test_place_object_clips_partial_offscreen():
    """Object partially outside the frame renders its visible portion and does not raise."""
    rgb = np.zeros((32, 32, 3), dtype=np.uint8)
    _place_object(rgb, x0=-4, y0=10, box_w=12, box_h=8, luma=180)
    # Pixels inside the visible slice should be brighter than bg.
    assert rgb[14, 2, 0] > 50, f"expected visible portion, got {rgb[14, 2, 0]}"
    # Pixels far from the visible slice should be untouched.
    np.testing.assert_array_equal(rgb[14, 28], [0, 0, 0])
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k place_object -v`
Expected: 4 FAILURES with `ImportError: cannot import name '_place_object'`.

- [ ] **Step 3: Implement the helper**

Append to `py/frames/video_source.py` immediately after `_add_frame_noise`:

```python
def _place_object(rgb_frame, x0, y0, box_w, box_h, luma,
                  sigma=2.0, kernel=5):
    """Composite a Gaussian-blurred soft-edged box at (x0, y0) onto rgb_frame, in-place.

    The object is greyscale (R=G=B=luma). Box regions partially outside the
    frame are clipped cleanly; the function is a no-op if the box is fully
    off-screen.
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
    fg = np.full_like(rgb_frame, luma)
    out = rgb_frame.astype(np.float32) * (1.0 - alpha) + fg.astype(np.float32) * alpha
    rgb_frame[:] = np.clip(out, 0, 255).astype(np.uint8)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k place_object -v`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add py/frames/video_source.py py/tests/test_models.py
git commit -m "feat(py-frames): add _place_object helper for soft-edged compositing"
```

---

### Task 4: Add `textured_static` generator

**Files:**
- Modify: `py/frames/video_source.py` (append new generator; register in `_generate_synthetic`)
- Modify: `py/tests/test_models.py` (append pattern test under `# ---- New synthetic source tests ----`)

- [ ] **Step 1: Write the failing test**

Append to `py/tests/test_models.py`, creating a new section at the end (still before `if __name__ == "__main__":`):

```python
# ---- New synthetic source tests ----

def test_textured_static_no_motion_after_convergence():
    """textured_static: after EMA converges, mask is all-black (no false positives).

    This is the only negative test in the new set — verifies that the
    sinusoid+noise background does not itself produce motion.
    """
    frames = load_frames("synthetic:textured_static",
                         width=64, height=48, num_frames=60)
    out = run_model("mask", frames)
    for i in range(55, 60):
        assert not out[i].any(), (
            f"frame {i} should be all-black after EMA convergence on static bg")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k textured_static_no_motion -v`
Expected: FAIL with `ValueError: Unknown pattern 'textured_static'`.

- [ ] **Step 3: Implement the generator and register it**

Append to `py/frames/video_source.py` after the `_place_object` helper:

```python
def _gen_textured_static(width, height, num_frames):
    """Sinusoid-textured background with per-frame sensor noise. No moving objects.

    Negative test: after EMA converges, mask must be all-black.
    """
    tex = _make_bg_texture(width, height)
    rng = np.random.default_rng(seed=1)
    frames = []
    for _ in range(num_frames):
        grey = _add_frame_noise(tex, rng)
        frames.append(np.stack([grey, grey, grey], axis=-1))
    return frames
```

In the `generators` dict inside `_generate_synthetic` (around line 105–117), add a new entry — keep the existing entries in place for now (they are removed in Task 9):

```python
        "textured_static": _gen_textured_static,
```

Place it immediately after the `"lighting_ramp"` entry so the dict stays grouped.

- [ ] **Step 4: Run the test to verify it passes**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k textured_static_no_motion -v`
Expected: 1 passed (may take ~10 s due to 60-frame model run).

- [ ] **Step 5: Commit**

```bash
git add py/frames/video_source.py py/tests/test_models.py
git commit -m "feat(py-frames): add synthetic:textured_static pattern"
```

---

### Task 5: Add `entering_object` generator

**Files:**
- Modify: `py/frames/video_source.py`
- Modify: `py/tests/test_models.py`

- [ ] **Step 1: Write the failing test**

Append to `py/tests/test_models.py` under `# ---- New synthetic source tests ----`:

```python
def test_entering_object_produces_bboxes_on_both_halves():
    """entering_object: boxes from opposite edges both produce bbox overlays past priming."""
    frames = load_frames("synthetic:entering_object",
                         width=64, height=48, num_frames=8)
    out = run_model("motion", frames)
    # Accumulate green-bbox presence across all post-priming frames.
    total = np.zeros(out[0].shape[:2], dtype=bool)
    for i in range(3, 8):
        total |= np.all(out[i] == BBOX_COLOR, axis=-1)
    left  = total[:, :32].any()
    right = total[:, 32:].any()
    assert left and right, (
        f"bboxes should appear on both halves: left={left}, right={right}")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k entering_object -v`
Expected: FAIL with `ValueError: Unknown pattern 'entering_object'`.

- [ ] **Step 3: Implement the generator and register it**

Append to `py/frames/video_source.py`:

```python
def _gen_entering_object(width, height, num_frames):
    """Two soft-edged boxes entering from opposite edges, crossing the centre.

    Box A sweeps left → right, box B sweeps right → left, both at the same
    speed. Both start (and end) mostly outside the frame; _place_object clips
    the off-frame portion cleanly.
    """
    tex = _make_bg_texture(width, height)
    rng = np.random.default_rng(seed=2)
    box_w, box_h = max(width // 6, 1), max(height // 6, 1)
    cy = (height - box_h) // 2
    span = width + box_w       # full travel: from -box_w to width
    frames = []
    for i in range(num_frames):
        grey = _add_frame_noise(tex, rng)
        rgb = np.stack([grey, grey, grey], axis=-1)
        t = i / max(num_frames - 1, 1)
        ax = int(-box_w + t * span)             # A: left-to-right
        bx = int(width - t * span)              # B: right-to-left
        _place_object(rgb, ax, cy, box_w, box_h, luma=180)
        _place_object(rgb, bx, cy, box_w, box_h, luma=160)
        frames.append(rgb)
    return frames
```

Register in the `generators` dict inside `_generate_synthetic`, after `textured_static`:

```python
        "entering_object": _gen_entering_object,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k entering_object -v`
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add py/frames/video_source.py py/tests/test_models.py
git commit -m "feat(py-frames): add synthetic:entering_object pattern"
```

---

### Task 6: Add `multi_speed` generator

**Files:**
- Modify: `py/frames/video_source.py`
- Modify: `py/tests/test_models.py`

- [ ] **Step 1: Write the failing test**

Append to `py/tests/test_models.py` under `# ---- New synthetic source tests ----`:

```python
def test_multi_speed_produces_three_bbox_bands():
    """multi_speed: three spatially-separated boxes produce bboxes in three horizontal bands.

    Box A (fast, top band), Box B (medium, middle band), Box C (slow, crosses
    diagonal). Accumulating across post-priming frames, bbox pixels must appear
    in the top third, middle third, and bottom third of the frame.
    """
    H, W = 72, 96
    frames = load_frames("synthetic:multi_speed",
                         width=W, height=H, num_frames=8)
    out = run_model("motion", frames)
    total = np.zeros((H, W), dtype=bool)
    for i in range(3, 8):
        total |= np.all(out[i] == BBOX_COLOR, axis=-1)
    top    = total[: H // 3].any()
    middle = total[H // 3 : 2 * H // 3].any()
    bottom = total[2 * H // 3 :].any()
    assert top and middle and bottom, (
        f"bboxes expected in three bands: top={top}, middle={middle}, bottom={bottom}")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k multi_speed -v`
Expected: FAIL with `ValueError: Unknown pattern 'multi_speed'`.

- [ ] **Step 3: Implement the generator and register it**

Append to `py/frames/video_source.py`:

```python
def _gen_multi_speed(width, height, num_frames):
    """Three soft-edged boxes, each with a distinct speed and direction.

    Box A (fast, L→R): crosses the full width in num_frames frames.
    Box B (medium, T→B): crosses the full height in 2*num_frames frames.
    Box C (slow, BL→TR diagonal): crosses the full diagonal in 4*num_frames frames.

    Exercises N-way CCL tracking of spatially-separated blobs moving independently.
    """
    tex = _make_bg_texture(width, height)
    rng = np.random.default_rng(seed=3)
    box_w, box_h = max(width // 6, 1), max(height // 6, 1)
    frames = []
    for i in range(num_frames):
        grey = _add_frame_noise(tex, rng)
        rgb = np.stack([grey, grey, grey], axis=-1)

        # Box A: fast L→R along the top band.
        t_a = i / max(num_frames - 1, 1)
        ax = int(t_a * (width - box_w))
        ay = height // 8
        _place_object(rgb, ax, ay, box_w, box_h, luma=180)

        # Box B: medium T→B along the vertical centreline.
        t_b = i / max(2 * num_frames - 1, 1)
        bx = (width - box_w) // 2
        by = int(t_b * (height - box_h))
        _place_object(rgb, bx, by, box_w, box_h, luma=160)

        # Box C: slow diagonal BL→TR.
        t_c = i / max(4 * num_frames - 1, 1)
        cx = int(t_c * (width - box_w))
        cy = int((1.0 - t_c) * (height - box_h))
        _place_object(rgb, cx, cy, box_w, box_h, luma=200)

        frames.append(rgb)
    return frames
```

Register in the `generators` dict after `entering_object`:

```python
        "multi_speed": _gen_multi_speed,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k multi_speed -v`
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add py/frames/video_source.py py/tests/test_models.py
git commit -m "feat(py-frames): add synthetic:multi_speed pattern"
```

---

### Task 7: Add `stopping_object` generator

**Files:**
- Modify: `py/frames/video_source.py`
- Modify: `py/tests/test_models.py`

- [ ] **Step 1: Write the failing test**

Append to `py/tests/test_models.py` under `# ---- New synthetic source tests ----`:

```python
def test_stopping_object_has_bbox_while_both_move():
    """stopping_object: first post-priming frame has bbox overlay while both boxes move.

    Full stopped-box absorption behaviour depends on alpha_shift_slow and
    would take 1/α_slow ≈ 64 frames to verify — out of scope for this unit
    test. We verify only the early-frame positive case here.
    """
    frames = load_frames("synthetic:stopping_object",
                         width=64, height=64, num_frames=8)
    out = run_model("motion", frames)
    green = np.all(out[3] == BBOX_COLOR, axis=-1)
    assert green.any(), "frame 3 should have bbox overlay while both boxes are moving"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k stopping_object -v`
Expected: FAIL with `ValueError: Unknown pattern 'stopping_object'`.

- [ ] **Step 3: Implement the generator and register it**

Append to `py/frames/video_source.py`:

```python
def _gen_stopping_object(width, height, num_frames):
    """Two soft-edged boxes: box A moves for the first half then stops; box B moves throughout.

    Tests selective EMA slow-rate: box A's bbox persists briefly after it
    stops while the slow EMA drifts toward the stopped luma; box B continues
    to produce a bbox on every frame.
    """
    tex = _make_bg_texture(width, height)
    rng = np.random.default_rng(seed=4)
    box_w, box_h = max(width // 6, 1), max(height // 6, 1)
    half = max(num_frames // 2, 1)
    frames = []
    for i in range(num_frames):
        grey = _add_frame_noise(tex, rng)
        rgb = np.stack([grey, grey, grey], axis=-1)

        # Box A: diagonal motion for frames [0, half); frozen afterwards.
        i_a = i if i < half else half - 1
        t_a = i_a / max(num_frames - 1, 1)
        ax = int(t_a * (width - box_w))
        ay = int(t_a * (height - box_h))
        _place_object(rgb, ax, ay, box_w, box_h, luma=180)

        # Box B: horizontal L→R for every frame, along the lower band.
        t_b = i / max(num_frames - 1, 1)
        bx = int(t_b * (width - box_w))
        by = height - box_h - height // 8
        _place_object(rgb, bx, by, box_w, box_h, luma=160)

        frames.append(rgb)
    return frames
```

Register in the `generators` dict after `multi_speed`:

```python
        "stopping_object": _gen_stopping_object,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k stopping_object -v`
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add py/frames/video_source.py py/tests/test_models.py
git commit -m "feat(py-frames): add synthetic:stopping_object pattern"
```

---

### Task 8: Add `lit_moving_object` generator

**Files:**
- Modify: `py/frames/video_source.py`
- Modify: `py/tests/test_models.py`

- [ ] **Step 1: Write the failing test**

Append to `py/tests/test_models.py` under `# ---- New synthetic source tests ----`:

```python
def test_lit_moving_object_bboxes_under_illumination_shift():
    """lit_moving_object: both boxes still produce bboxes despite the time-varying lighting gradient."""
    frames = load_frames("synthetic:lit_moving_object",
                         width=64, height=48, num_frames=8)
    out = run_model("motion", frames)
    green = np.all(out[5] == BBOX_COLOR, axis=-1)
    assert green.any(), "bbox should appear at frame 5 despite lighting shift"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k lit_moving_object -v`
Expected: FAIL with `ValueError: Unknown pattern 'lit_moving_object'`.

- [ ] **Step 3: Implement the generator and register it**

Append to `py/frames/video_source.py`:

```python
def _gen_lit_moving_object(width, height, num_frames):
    """Two soft-edged boxes on a bg whose L↔R illumination gradient shifts ~2 luma/frame.

    One half of the frame slowly brightens while the other dims. Tests that
    the EMA (via selective rate + grace window) can still flag moving objects
    under a gradual illumination change.
    """
    tex = _make_bg_texture(width, height)
    rng = np.random.default_rng(seed=5)
    box_w, box_h = max(width // 6, 1), max(height // 6, 1)
    # Per-column ramp in [-1, +1]: scaled by shift_per_frame*i for frame i.
    ramp = (np.arange(width) - width / 2.0) / max(width / 2.0, 1.0)
    shift_per_frame = 2.0
    frames = []
    for i in range(num_frames):
        shift = ramp * shift_per_frame * i                        # (W,)
        shifted = np.clip(tex.astype(np.float32) + shift[None, :], 0, 255).astype(np.uint8)
        grey = _add_frame_noise(shifted, rng)
        rgb = np.stack([grey, grey, grey], axis=-1)

        # Box A: fast L→R across the full width in num_frames frames.
        t_a = i / max(num_frames - 1, 1)
        ax = int(t_a * (width - box_w))
        ay = height // 4
        _place_object(rgb, ax, ay, box_w, box_h, luma=180)

        # Box B: slow diagonal TL→BR across the diagonal in 3*num_frames frames.
        t_b = i / max(3 * num_frames - 1, 1)
        bx = int(t_b * (width - box_w))
        by = int(t_b * (height - box_h))
        _place_object(rgb, bx, by, box_w, box_h, luma=200)

        frames.append(rgb)
    return frames
```

Register in the `generators` dict after `stopping_object`:

```python
        "lit_moving_object": _gen_lit_moving_object,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -k lit_moving_object -v`
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add py/frames/video_source.py py/tests/test_models.py
git commit -m "feat(py-frames): add synthetic:lit_moving_object pattern"
```

---

### Task 9: Remove obsolete generators and broken test

**Files:**
- Modify: `py/frames/video_source.py`
- Modify: `py/tests/test_models.py`

- [ ] **Step 1: Delete the broken test**

In `py/tests/test_models.py`, delete lines 115–126 (the `test_motion_color_bars_static` function, including its docstring and blank line after). The replacement coverage already exists as `test_motion_static_scene` (identical-scene → passthrough after EMA convergence) and the new `test_textured_static_no_motion_after_convergence` from Task 4.

- [ ] **Step 2: Remove generators from the dispatch dict**

In `py/frames/video_source.py`, edit the `generators` dict inside `_generate_synthetic` (currently lines 105–117). Delete these six entries:

```python
        "color_bars": _gen_color_bars,
        "gradient": _gen_gradient,
        "checkerboard": _gen_checkerboard,
        "moving_box_h": _gen_moving_box_h,
        "moving_box_v": _gen_moving_box_v,
        "moving_box_reverse": _gen_moving_box_reverse,
```

After this step, the `generators` dict should contain exactly ten entries (in any stable order): `moving_box`, `dark_moving_box`, `two_boxes`, `noisy_moving_box`, `lighting_ramp`, `textured_static`, `entering_object`, `multi_speed`, `stopping_object`, `lit_moving_object`.

- [ ] **Step 3: Delete the six unused generator functions**

In `py/frames/video_source.py`, delete these six functions entirely (including their docstrings and trailing blank lines):

- `_gen_color_bars` (currently lines 125–137)
- `_gen_gradient` (lines 140–147)
- `_gen_checkerboard` (lines 150–157)
- `_gen_moving_box_h` (lines 175–186)
- `_gen_moving_box_v` (lines 189–200)
- `_gen_moving_box_reverse` (lines 203–214)

Keep `_gen_moving_box`, `_gen_dark_moving_box`, `_gen_two_boxes`, `_gen_noisy_moving_box`, `_gen_lighting_ramp` untouched.

- [ ] **Step 4: Update the module docstring**

Replace the module docstring at the top of `py/frames/video_source.py` (currently lines 1–11) with:

```python
"""Load video frames from various sources.

Supported sources:
  - Path to MP4/AVI video file (requires opencv)
  - Path to directory of PNG/JPG images
  - "synthetic:<pattern>" where pattern is one of:
      moving_box, dark_moving_box, two_boxes, noisy_moving_box,
      lighting_ramp, textured_static, entering_object, multi_speed,
      stopping_object, lit_moving_object
"""
```

- [ ] **Step 5: Run the full model test suite**

Run: `source .venv/bin/activate && pytest py/tests/test_models.py -v`
Expected: all tests pass. No references to `color_bars`, `gradient`, `checkerboard`, `moving_box_h`, `moving_box_v`, or `moving_box_reverse` remain.

Sanity-check:
```bash
grep -nE "color_bars|\"gradient\"|checkerboard|moving_box_h|moving_box_v|moving_box_reverse" py/frames/video_source.py py/tests/test_models.py
```
Expected: no matches.

- [ ] **Step 6: Commit**

```bash
git add py/frames/video_source.py py/tests/test_models.py
git commit -m "refactor(py-frames): remove obsolete synthetic patterns"
```

---

### Task 10: Update user-facing docs and defaults

**Files:**
- Modify: `py/harness.py:179`
- Modify: `Makefile` (two `SOURCE=synthetic:color_bars` occurrences at lines 9 and 76, plus the six-line pattern list in `help` at lines 88–94)
- Modify: `README.md` (line 220 `SOURCE` default, lines 235–241 pattern rows)
- Modify: `CLAUDE.md` (lines 33, 43, 118 — synthetic-pattern mentions)

The new default pattern is `synthetic:moving_box` — a retained pattern that visibly exercises the motion pipeline.

- [ ] **Step 1: Update `py/harness.py` default**

Change line 179 from:

```python
    p_prep.add_argument("--source", default="synthetic:color_bars",
```

to:

```python
    p_prep.add_argument("--source", default="synthetic:moving_box",
```

- [ ] **Step 2: Update `Makefile` default and help**

Change line 9 from:

```makefile
SOURCE    ?= synthetic:color_bars
```

to:

```makefile
SOURCE    ?= synthetic:moving_box
```

Change line 76 from:

```
	@echo "    SOURCE=synthetic:color_bars      Input source (prepare only). See sources below."
```

to:

```
	@echo "    SOURCE=synthetic:moving_box      Input source (prepare only). See sources below."
```

Replace the block at lines 88–94 (the six `@echo "    synthetic:..."` lines for the removed patterns) with new entries for the five added patterns. The final pattern list under `Sources (SOURCE=):` should read (preserving the alignment used by surrounding lines):

```
	@echo "    synthetic:moving_box       Red box, diagonal top-left → bottom-right"
	@echo "    synthetic:dark_moving_box  Dark box on bright background"
	@echo "    synthetic:two_boxes        Red + cyan boxes, opposing directions"
	@echo "    synthetic:noisy_moving_box Red box on noisy background (EMA test)"
	@echo "    synthetic:lighting_ramp    Moving box on slowly brightening background"
	@echo "    synthetic:textured_static  Sinusoid-textured static bg + noise (negative test)"
	@echo "    synthetic:entering_object  Two soft-edged boxes entering from opposite edges"
	@echo "    synthetic:multi_speed      Three soft-edged boxes with distinct speeds and directions"
	@echo "    synthetic:stopping_object  Box stops after half the frames + box always moving"
	@echo "    synthetic:lit_moving_object Two soft-edged boxes under shifting L↔R lighting"
```

- [ ] **Step 3: Update `README.md` default and pattern table**

Change line 220 from:

```
| `SOURCE` | `synthetic:color_bars` | Input source (only used by `prepare`). See table below for available patterns. Also accepts MP4/AVI files (OpenCV) or a PNG directory. |
```

to:

```
| `SOURCE` | `synthetic:moving_box` | Input source (only used by `prepare`). See table below for available patterns. Also accepts MP4/AVI files (OpenCV) or a PNG directory. |
```

Replace the `### Synthetic Sources` table body (currently lines 235–241 plus the retained patterns already on the next lines) so it lists exactly the ten supported patterns:

```markdown
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
```

- [ ] **Step 4: Update `CLAUDE.md`**

Change line 33 from:

```
make run-pipeline SOURCE="synthetic:gradient" MODE=binary SIMULATOR=verilator
```

to:

```
make run-pipeline SOURCE="synthetic:moving_box" MODE=binary SIMULATOR=verilator
```

Change line 43 from:

```
make prepare SOURCE="synthetic:gradient" WIDTH=640 HEIGHT=480 FRAMES=8 MODE=binary
```

to:

```
make prepare SOURCE="synthetic:moving_box" WIDTH=640 HEIGHT=480 FRAMES=8 MODE=binary
```

Replace line 118:

```
- Input sources: MP4/AVI (via OpenCV), PNG directory, or `synthetic:<pattern>` (color_bars, gradient, checkerboard, moving_box, moving_box_h, moving_box_v, moving_box_reverse, dark_moving_box, two_boxes, noisy_moving_box, lighting_ramp).
```

with:

```
- Input sources: MP4/AVI (via OpenCV), PNG directory, or `synthetic:<pattern>` (moving_box, dark_moving_box, two_boxes, noisy_moving_box, lighting_ramp, textured_static, entering_object, multi_speed, stopping_object, lit_moving_object).
```

- [ ] **Step 5: End-to-end smoke test of a new pattern**

Run the full pipeline on one of the new patterns to verify the generator integrates with the harness and RTL sim:

```bash
make run-pipeline SOURCE="synthetic:multi_speed" CTRL_FLOW=motion WIDTH=96 HEIGHT=72 FRAMES=8
```

Expected: the run completes, `make verify` prints `VERIFY: PASS`, and a comparison image is rendered to `dv/data/`.

- [ ] **Step 6: Final sweep — no dangling references**

Run:

```bash
grep -rnE "color_bars|checkerboard|moving_box_h|moving_box_v|moving_box_reverse" \
     --include='*.py' --include='*.md' --include='Makefile' \
     . | grep -v '.venv' | grep -v 'docs/plans/old' | grep -v 'docs/plans/2026-04-22-synthetic-sources'
```

Expected output: only matches inside `hw/ip/vga/` (the unrelated VGA pattern generator) and testbench test-name strings inside `hw/ip/gauss3x3/tb/` (the Gaussian TB's internal "gradient"/"checker" test names are hardware-level tests, not synthetic sources). No hits in `py/`, `Makefile`, `CLAUDE.md`, or the top-level `README.md`.

Then also confirm no `synthetic:gradient` anywhere:

```bash
grep -rnE 'synthetic:(gradient|color_bars|checkerboard|moving_box_h|moving_box_v|moving_box_reverse)' \
     --include='*.py' --include='*.md' --include='Makefile' . \
  | grep -v '.venv' | grep -v 'docs/plans/old' \
  | grep -v 'docs/plans/2026-04-22-synthetic-sources-design.md' \
  | grep -v 'docs/plans/2026-04-22-synthetic-sources-plan.md'
```

Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add py/harness.py Makefile README.md CLAUDE.md
git commit -m "docs: refresh synthetic source list after pattern overhaul"
```

- [ ] **Step 8: Archive the design and plan**

Per project convention (`CLAUDE.md`: "After implementing a plan, move it to docs/plans/old/ and put a date timestamp"):

```bash
mkdir -p docs/plans/old
git mv docs/plans/2026-04-22-synthetic-sources-design.md docs/plans/old/2026-04-22-synthetic-sources-design.md
git mv docs/plans/2026-04-22-synthetic-sources-plan.md   docs/plans/old/2026-04-22-synthetic-sources-plan.md
git commit -m "docs(plans): archive synthetic-source overhaul design and plan"
```

---

## Self-review checklist (completed)

- **Spec coverage.** Every section in the design doc maps to a task:
  - 6 patterns removed → Task 9 (dict entry removal + function deletion).
  - 5 patterns kept unchanged → no task needed; verified via the `generators` dict ending at exactly 10 entries after Task 9.
  - 5 patterns added (`textured_static`, `entering_object`, `multi_speed`, `stopping_object`, `lit_moving_object`) → Tasks 4–8, one per pattern, each with its assertion from the design.
  - Background generation recipe (sinusoid + noise) → Tasks 1–2 helpers.
  - Object generation (mid-range luma, 5×5/σ=2 Gaussian-blurred edges, alpha composite) → Task 3 helper.
  - Code structure (three private helpers, dict/docstring update) → Tasks 1–3 + Task 9.
  - Test impact note ("No existing tests reference any of the 6 removed pattern names") — found one exception: `test_motion_color_bars_static` at `py/tests/test_models.py:115`. Handled in Task 9 Step 1.
- **Placeholder scan.** No `TBD`, `TODO`, `similar to Task N`, or vague "add appropriate X" steps. All code blocks are concrete and complete.
- **Type consistency.** Helper signatures are identical everywhere they appear (`_make_bg_texture(width, height, base_luma=100, amp=20, seed=...)`, `_add_frame_noise(bg, rng, noise_amp=8)`, `_place_object(rgb_frame, x0, y0, box_w, box_h, luma, sigma=2.0, kernel=5)`). Generator names and their dict keys match. Test names correspond to the patterns they verify.
