"""Render input/output frames as a comparison image grid."""

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def render_grid(input_frames, output_frames, path, reference_frames=None,
                label_height=32, min_width=800):
    """Render frames as a PNG grid with labeled rows.

    Rows: INPUT, OUTPUT, and optionally REFERENCE MODEL.
    The grid is scaled up with nearest-neighbor interpolation so that
    small frames are visible, then text labels are drawn at the final
    resolution for crisp rendering.

    Args:
        input_frames: List of numpy arrays (H, W, 3).
        output_frames: List of numpy arrays (H, W, 3).
        path: Output PNG path.
        reference_frames: Optional list of numpy arrays (H, W, 3).
        label_height: Height of label bars in the final image (pixels).
        min_width: Target minimum width for the final image.
    """
    n = max(len(input_frames), len(output_frames))
    h, w = input_frames[0].shape[:2]

    gap = 2  # pixels between frames at native scale
    native_w = n * w + (n - 1) * gap

    # Scale factor: ensure the final image is at least min_width wide
    scale = max(1, min_width // native_w)

    sw, sh = w * scale, h * scale  # scaled frame dimensions (input row)
    sgap = gap * scale

    frames_w = n * sw + (n - 1) * sgap

    # Build row definitions: (label, frames_list)
    rows = [
        ("INPUT", input_frames),
        ("OUTPUT", output_frames),
    ]
    if reference_frames is not None:
        rows.append(("REFERENCE MODEL", reference_frames))

    # Per-row scaled frame dimensions — frames in different rows may have
    # different native dims (e.g. the scaler doubles output but not input).
    # Each row's frames are resized to fit (sw, sh) using nearest-neighbour.
    row_dims = []
    for _, frames_list in rows:
        rh, rw = frames_list[0].shape[:2]
        row_dims.append((rh, rw))

    num_rows = len(rows)
    grid_h = num_rows * (label_height + sh)
    grid_w = frames_w
    grid = np.zeros((grid_h, grid_w, 3), dtype=np.uint8)
    grid[:] = 40  # dark gray background

    # Place label bars and frames for each row
    label_ys = []
    for row_idx, (_, frames_list) in enumerate(rows):
        label_y = row_idx * (label_height + sh)
        frames_y = label_y + label_height
        label_ys.append(label_y)
        rh, rw = row_dims[row_idx]

        # Label bar — slightly lighter background
        grid[label_y : label_y + label_height, :] = 55

        # Place frames; each row resamples to (sw, sh) with nearest-neighbour
        # so rows with differing native dims (scaler) line up.
        for i, frame in enumerate(frames_list[:n]):
            x = i * (sw + sgap)
            # Use PIL for arbitrary nearest-neighbour resize (handles
            # non-integer ratios when row dims differ from (h, w)).
            resized = np.asarray(
                Image.fromarray(frame).resize((sw, sh), Image.NEAREST)
            )
            grid[frames_y : frames_y + sh, x : x + sw] = resized

    # Draw text labels using Pillow
    img = Image.fromarray(grid)
    draw = ImageDraw.Draw(img)

    # Try to load a monospace font; fall back to default bitmap font
    font = None
    font_size = max(label_height - 8, 10)
    for font_name in [
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    ]:
        try:
            font = ImageFont.truetype(font_name, font_size)
            break
        except (OSError, IOError):
            continue
    if font is None:
        font = ImageFont.load_default()

    text_color = (200, 200, 200)
    text_x = 6
    for row_idx, (label, _) in enumerate(rows):
        text_y = label_ys[row_idx] + (label_height - font_size) // 2
        draw.text((text_x, text_y), label, fill=text_color, font=font)

    img.save(str(path))
    return path


def compare_frames(input_frames, output_frames, tolerance=0):
    """Compare input and output frames, return per-frame results.

    Args:
        input_frames: List of numpy arrays (H, W, 3).
        output_frames: List of numpy arrays (H, W, 3).
        tolerance: Max number of differing pixels per frame that still counts
            as a pass. 0 = exact match (default). Use a non-zero value to
            accommodate the bounding-box overlay added by the motion pipeline
            (the first 2 frames are suppressed; subsequent motion frames
            have a bbox slightly larger than the object).

    Returns:
        List of dicts with keys: frame_idx, match, max_diff, mean_diff,
        num_diff_pixels.
    """
    results = []
    for i, (inp, out) in enumerate(zip(input_frames, output_frames)):
        diff = np.abs(inp.astype(int) - out.astype(int))
        num_diff = int(np.any(diff > 0, axis=-1).sum())
        match = num_diff <= tolerance
        results.append({
            "frame_idx": i,
            "match": match,
            "max_diff": int(diff.max()),
            "mean_diff": float(diff.mean()),
            "num_diff_pixels": num_diff,
        })
    return results
