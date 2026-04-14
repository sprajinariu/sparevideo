"""Render input/output frames as a comparison image grid."""

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def render_grid(input_frames, output_frames, path, label_height=24):
    """Render input (top row) and output (bottom row) frames as a PNG grid.

    Each row has a text label ("INPUT" / "OUTPUT") on the left.

    Args:
        input_frames: List of numpy arrays (H, W, 3).
        output_frames: List of numpy arrays (H, W, 3).
        path: Output PNG path.
        label_height: Height of label bars.
    """
    n = max(len(input_frames), len(output_frames))
    h, w = input_frames[0].shape[:2]

    gap = 2  # pixels between frames
    frames_w = n * w + (n - 1) * gap
    # Two label bars (one above each row) + two frame rows
    grid_h = 2 * label_height + 2 * h
    grid_w = frames_w
    grid = np.zeros((grid_h, grid_w, 3), dtype=np.uint8)
    grid[:] = 40  # dark gray background

    # Row positions
    input_label_y = 0
    input_frames_y = label_height
    output_label_y = label_height + h
    output_frames_y = 2 * label_height + h

    # Label bars — slightly lighter background
    grid[input_label_y : input_label_y + label_height, :] = 55
    grid[output_label_y : output_label_y + label_height, :] = 55

    # Place frames
    for i, frame in enumerate(input_frames[:n]):
        x = i * (w + gap)
        grid[input_frames_y : input_frames_y + h, x : x + w] = frame

    for i, frame in enumerate(output_frames[:n]):
        x = i * (w + gap)
        grid[output_frames_y : output_frames_y + h, x : x + w] = frame

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
    # Center text vertically in label bar
    text_x = 6
    input_text_y = input_label_y + (label_height - font_size) // 2
    output_text_y = output_label_y + (label_height - font_size) // 2

    draw.text((text_x, input_text_y), "INPUT", fill=text_color, font=font)
    draw.text((text_x, output_text_y), "OUTPUT", fill=text_color, font=font)

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
            (frame 0 always has a full-frame border; motion frames have a bbox).

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
