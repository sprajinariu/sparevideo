"""Load video frames from various sources.

Supported sources:
  - Path to MP4/AVI video file (requires opencv)
  - Path to directory of PNG/JPG images
  - "synthetic:<pattern>" where pattern is one of:
      color_bars, gradient, checkerboard, moving_box
"""

import sys
from pathlib import Path

import cv2
import numpy as np


def load_frames(source, width=320, height=240, num_frames=4):
    """Load frames from a source, resize to (width, height).

    Args:
        source: File path (video or image dir) or "synthetic:<pattern>".
        width: Target width.
        height: Target height.
        num_frames: Number of frames to extract.

    Returns:
        List of numpy arrays, each (height, width, 3) dtype uint8, RGB order.
    """
    if source.startswith("synthetic:"):
        pattern = source.split(":", 1)[1]
        return _generate_synthetic(pattern, width, height, num_frames)

    path = Path(source)
    if path.is_dir():
        return _load_image_dir(path, width, height, num_frames)
    elif path.is_file():
        return _load_video(path, width, height, num_frames)
    else:
        raise FileNotFoundError(f"Source not found: {source}")


def _load_video(path, width, height, num_frames):
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {path}")

    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if total <= 0:
        total = num_frames  # fallback for streams

    # Sample frames evenly across the video
    indices = np.linspace(0, max(total - 1, 0), num_frames, dtype=int)

    frames = []
    for idx in indices:
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(idx))
        ret, frame = cap.read()
        if not ret:
            break
        # OpenCV reads BGR, convert to RGB
        frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        frame = cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA)
        frames.append(frame.astype(np.uint8))

    cap.release()

    if not frames:
        raise RuntimeError(f"No frames read from {path}")

    # Pad with last frame if we didn't get enough
    while len(frames) < num_frames:
        frames.append(frames[-1].copy())

    return frames


def _load_image_dir(path, width, height, num_frames):
    exts = {".png", ".jpg", ".jpeg", ".bmp"}
    files = sorted(f for f in path.iterdir() if f.suffix.lower() in exts)
    if not files:
        raise RuntimeError(f"No images found in {path}")

    frames = []
    for f in files[:num_frames]:
        img = cv2.imread(str(f))
        if img is None:
            continue
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        img = cv2.resize(img, (width, height), interpolation=cv2.INTER_AREA)
        frames.append(img.astype(np.uint8))

    if not frames:
        raise RuntimeError(f"No valid images in {path}")

    while len(frames) < num_frames:
        frames.append(frames[-1].copy())

    return frames


def _generate_synthetic(pattern, width, height, num_frames):
    generators = {
        "color_bars": _gen_color_bars,
        "gradient": _gen_gradient,
        "checkerboard": _gen_checkerboard,
        "moving_box": _gen_moving_box,
    }
    if pattern not in generators:
        raise ValueError(
            f"Unknown pattern '{pattern}'. Available: {list(generators.keys())}"
        )
    return generators[pattern](width, height, num_frames)


def _gen_color_bars(width, height, num_frames):
    """8 vertical color bars: white, yellow, cyan, green, magenta, red, blue, black."""
    colors = [
        (255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
        (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0),
    ]
    frame = np.zeros((height, width, 3), dtype=np.uint8)
    bar_w = width // 8
    for i, color in enumerate(colors):
        x0 = i * bar_w
        x1 = (i + 1) * bar_w if i < 7 else width
        frame[:, x0:x1] = color
    return [frame.copy() for _ in range(num_frames)]


def _gen_gradient(width, height, num_frames):
    """Red gradient horizontal, green gradient vertical."""
    frame = np.zeros((height, width, 3), dtype=np.uint8)
    for y in range(height):
        for x in range(width):
            frame[y, x, 0] = int(x * 255 / max(width - 1, 1))
            frame[y, x, 1] = int(y * 255 / max(height - 1, 1))
    return [frame.copy() for _ in range(num_frames)]


def _gen_checkerboard(width, height, num_frames):
    """16x16 pixel checkerboard."""
    frame = np.zeros((height, width, 3), dtype=np.uint8)
    for y in range(height):
        for x in range(width):
            if ((x // 16) ^ (y // 16)) & 1:
                frame[y, x] = (255, 255, 255)
    return [frame.copy() for _ in range(num_frames)]


def _gen_moving_box(width, height, num_frames):
    """A red box that moves diagonally across frames."""
    box_w, box_h = width // 4, height // 4
    frames = []
    for i in range(num_frames):
        frame = np.zeros((height, width, 3), dtype=np.uint8)
        # Position cycles through the frame
        t = i / max(num_frames - 1, 1)
        cx = int(t * (width - box_w))
        cy = int(t * (height - box_h))
        frame[cy : cy + box_h, cx : cx + box_w] = (255, 0, 0)
        frames.append(frame)
    return frames


if __name__ == "__main__":
    import argparse

    from frames.frame_io import write_frames

    parser = argparse.ArgumentParser(description="Load video frames and write to file")
    parser.add_argument("source", help="Video file, image dir, or synthetic:<pattern>")
    parser.add_argument("--frames", type=int, default=4)
    parser.add_argument("--width", type=int, default=320)
    parser.add_argument("--height", type=int, default=240)
    parser.add_argument("--output", default="output.txt")
    parser.add_argument("--mode", choices=["text", "binary"], default="text")
    args = parser.parse_args()

    frames = load_frames(args.source, args.width, args.height, args.frames)
    write_frames(args.output, frames, mode=args.mode)
    print(f"Wrote {len(frames)} frames ({args.width}x{args.height}) to {args.output}")
