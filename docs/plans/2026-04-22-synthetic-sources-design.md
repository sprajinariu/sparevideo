# Synthetic Source Improvements — Design

**Date:** 2026-04-22
**Status:** Approved

## Goal

Replace the six weakest existing synthetic patterns with five higher-quality ones that give the test suite more overall credibility. "More real" means: textured backgrounds with per-frame sensor noise, soft Gaussian-blurred object edges, mid-range luma values, and more than one moving object per pattern.

## Patterns removed (6)

| Pattern | Reason |
|---|---|
| `color_bars` | Static, unrealistic saturated colors, no motion |
| `gradient` | Static, no motion, redundant with `textured_static` |
| `checkerboard` | Static, no motion, redundant with `textured_static` |
| `moving_box_h` | Redundant with `moving_box` (horizontal-only variant) |
| `moving_box_v` | Redundant with `moving_box` (vertical-only variant) |
| `moving_box_reverse` | Redundant with `moving_box` (reversed diagonal variant) |

## Patterns kept (5, unchanged)

`moving_box`, `dark_moving_box`, `two_boxes`, `noisy_moving_box`, `lighting_ramp`

Each of these tests a distinct pipeline behaviour and is referenced by existing tests — no changes.

## Patterns added (5)

### `textured_static`
Static scene with sinusoid texture + per-frame noise. No moving objects. EMA baseline test: after convergence, mask must be all-black. The only negative test in the new set; needed to verify no false positives on a realistic static background.

### `entering_object`
Two soft-edged boxes entering from opposite edges (box A from the left, box B from the right) at the same speed, moving toward the centre and exiting the other side. At any given frame one or both may be partially outside the frame — the generator clips to frame bounds. Textured+noise background.

Test assertion: both boxes produce bboxes once past the priming frames.

### `multi_speed`
Three soft-edged boxes each with a distinct speed **and** direction:
- Box A: left-to-right, fast (crosses full width in `num_frames` frames)
- Box B: top-to-bottom, medium (crosses full height in `2*num_frames` frames)
- Box C: diagonal bottom-left to top-right, slow (crosses full diagonal in `4*num_frames` frames)

Textured+noise background. Tests N-way CCL tracking of spatially-separated blobs moving independently.

Test assertion: all three boxes produce separate bboxes; fast box exits before slow box reaches mid-frame.

### `stopping_object`
Two soft-edged boxes:
- Box A: moves diagonally for the first half of frames, then stops for the second half
- Box B: moves horizontally for all frames

Textured+noise background. Tests selective EMA slow-rate: box A bbox appears while moving and persists briefly after stopping (bg drifts slowly toward stopped-object luma).

Test assertion: box A has bbox in first half; box B has bbox throughout.

### `lit_moving_object`
Two soft-edged boxes on a background whose illumination gradient shifts left-to-right at ~2 luma/frame (one half of the frame slowly brightens while the other dims). Texture and per-frame noise are added on top of the shifting gradient:
- Box A: left-to-right, fast (crosses full width in `num_frames` frames)
- Box B: diagonal top-left to bottom-right, slow (crosses full diagonal in `3*num_frames` frames)

Test assertion: both boxes produce bboxes despite the illumination shift.

## Total: 10 patterns

## Background generation (shared)

All new patterns use a two-layer background:

**Layer 1 — Sinusoid texture (static across frames):**
```
bg_texture[y, x] = base_luma + A * Σ_i sin(f_i * (x*cos(θ_i) + y*sin(θ_i)) + φ_i)
```
Three sine components with different spatial frequencies and orientations. Maps to luma window 60–140. Baked once per generator call.

**Layer 2 — Per-frame sensor noise:**
```
frame[y, x] = clip(bg_texture[y, x] + noise[frame_i, y, x], 0, 255)
noise = rng.integers(-noise_amp, +noise_amp, size=(H, W))  # seeded, per-frame
```
Default `noise_amp=8` (below THRESH=16 to avoid false positives from noise alone). Each generator uses a fixed seed for reproducibility.

For `lit_moving_object`, a time-varying illumination offset (smooth gradient shifting ~2 luma/frame) is added to the texture before adding noise.

## Object generation (shared)

- Size: proportional to frame (W//6 × H//6 default)
- Luma: distinct mid-range values per object (e.g. 180, 160, 200) — above THRESH against background, not saturated
- Edges: Gaussian-blurred (5×5 kernel, σ=2) float mask composited onto background
- Compositing: `frame = bg * (1 - mask) + obj_color * mask`

## Code structure

All changes in `py/frames/video_source.py`:
- Three new private helpers: `_make_bg_texture`, `_add_frame_noise`, `_place_object`
- Six generator functions removed, five added
- `generators` dict and module docstring updated

New tests in `py/tests/test_models.py` under `# ---- New synthetic source tests ----`, one per new pattern, asserting positive detection (bbox present after priming frames).

No Makefile changes needed — `SOURCE=synthetic:<pattern>` is a free-form argument.

## Test impact

No existing tests reference any of the 6 removed pattern names. All existing tests continue to pass unchanged.
