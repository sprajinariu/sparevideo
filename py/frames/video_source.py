"""Load video frames from various sources.

Supported sources:
  - Path to MP4/AVI video file (requires opencv)
  - Path to directory of PNG/JPG images
  - "synthetic:<pattern>" where pattern is one of:
      color_bars, gradient, checkerboard, moving_box,
      moving_box_h, moving_box_v, moving_box_reverse,
      dark_moving_box, two_boxes, noisy_moving_box,
      lighting_ramp
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
        "moving_box_h": _gen_moving_box_h,
        "moving_box_v": _gen_moving_box_v,
        "moving_box_reverse": _gen_moving_box_reverse,
        "dark_moving_box": _gen_dark_moving_box,
        "two_boxes": _gen_two_boxes,
        "noisy_moving_box": _gen_noisy_moving_box,
        "lighting_ramp": _gen_lighting_ramp,
        "textured_static": _gen_textured_static,
        "entering_object": _gen_entering_object,
        "multi_speed": _gen_multi_speed,
        "stopping_object": _gen_stopping_object,
    }
    if pattern not in generators:
        raise ValueError(
            f"Unknown pattern '{pattern}'. Available: {list(generators.keys())}"
        )
    return generators[pattern](width, height, num_frames)


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


def _add_frame_noise(bg, rng, noise_amp=8):
    """Add integer per-pixel noise in [-noise_amp, +noise_amp] to a uint8 greyscale bg.

    Returns a (H, W) uint8 array clipped to [0, 255]. Takes an explicit
    `rng` so the caller controls per-frame / per-generator determinism.
    """
    h, w = bg.shape
    noise = rng.integers(-noise_amp, noise_amp + 1,
                         size=(h, w), dtype=np.int16)
    return np.clip(bg.astype(np.int16) + noise, 0, 255).astype(np.uint8)


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


def _gen_moving_box_h(width, height, num_frames):
    """A red box moving horizontally (left to right)."""
    box_w, box_h = width // 6, height // 6
    cy = (height - box_h) // 2
    frames = []
    for i in range(num_frames):
        frame = np.zeros((height, width, 3), dtype=np.uint8)
        t = i / max(num_frames - 1, 1)
        cx = int(t * (width - box_w))
        frame[cy : cy + box_h, cx : cx + box_w] = (255, 0, 0)
        frames.append(frame)
    return frames


def _gen_moving_box_v(width, height, num_frames):
    """A green box moving vertically (top to bottom)."""
    box_w, box_h = width // 6, height // 6
    cx = (width - box_w) // 2
    frames = []
    for i in range(num_frames):
        frame = np.zeros((height, width, 3), dtype=np.uint8)
        t = i / max(num_frames - 1, 1)
        cy = int(t * (height - box_h))
        frame[cy : cy + box_h, cx : cx + box_w] = (0, 255, 0)
        frames.append(frame)
    return frames


def _gen_moving_box_reverse(width, height, num_frames):
    """A blue box moving diagonally from bottom-right to top-left."""
    box_w, box_h = width // 4, height // 4
    frames = []
    for i in range(num_frames):
        frame = np.zeros((height, width, 3), dtype=np.uint8)
        t = i / max(num_frames - 1, 1)
        cx = int((1 - t) * (width - box_w))
        cy = int((1 - t) * (height - box_h))
        frame[cy : cy + box_h, cx : cx + box_w] = (0, 0, 255)
        frames.append(frame)
    return frames


def _gen_dark_moving_box(width, height, num_frames):
    """A dark box moving diagonally on a bright background.

    Tests that the polarity-agnostic mask (diff > THRESH only) correctly
    detects motion for dark-on-bright scenes, not just bright-on-dark.
    The bbox should track the object's motion region (arrival + departure).
    """
    box_w, box_h = width // 4, height // 4
    frames = []
    for i in range(num_frames):
        frame = np.full((height, width, 3), 200, dtype=np.uint8)
        t = i / max(num_frames - 1, 1)
        cx = int(t * (width - box_w))
        cy = int(t * (height - box_h))
        frame[cy : cy + box_h, cx : cx + box_w] = (20, 20, 20)
        frames.append(frame)
    return frames


def _gen_two_boxes(width, height, num_frames):
    """Two boxes moving in opposite directions (red horizontal, cyan vertical).

    Tests that the single-bbox reducer produces a bounding box that
    encompasses both objects when both are in motion.
    """
    bw, bh = width // 8, height // 8
    frames = []
    for i in range(num_frames):
        frame = np.zeros((height, width, 3), dtype=np.uint8)
        t = i / max(num_frames - 1, 1)
        # Red box: left to right, upper third
        rx = int(t * (width - bw))
        ry = height // 6
        frame[ry : ry + bh, rx : rx + bw] = (255, 0, 0)
        # Cyan box: right to left, lower third
        cx = int((1 - t) * (width - bw))
        cy = height * 2 // 3
        frame[cy : cy + bh, cx : cx + bw] = (0, 255, 255)
        frames.append(frame)
    return frames


def _gen_noisy_moving_box(width, height, num_frames):
    """A red box moving diagonally on a background with per-frame sensor noise.

    Background pixels jitter +/-10 luma per frame (simulating camera sensor noise).
    With THRESH=16, raw frame differencing (ALPHA_SHIFT=0) produces false positives
    on the background; EMA (ALPHA_SHIFT>=1) suppresses them.
    """
    rng = np.random.default_rng(seed=42)
    box_w, box_h = width // 4, height // 4
    base_bg = 30
    noise_amplitude = 10
    frames = []
    for i in range(num_frames):
        noise = rng.integers(-noise_amplitude, noise_amplitude + 1,
                             size=(height, width), dtype=np.int16)
        bg = np.clip(base_bg + noise, 0, 255).astype(np.uint8)
        frame = np.stack([bg, bg, bg], axis=-1)
        t = i / max(num_frames - 1, 1)
        cx = int(t * (width - box_w))
        cy = int(t * (height - box_h))
        frame[cy : cy + box_h, cx : cx + box_w] = (255, 0, 0)
        frames.append(frame)
    return frames


def _gen_lighting_ramp(width, height, num_frames):
    """Moving box on a background that slowly brightens (+1 luma/frame).

    Tests that EMA tracks gradual lighting changes without producing
    false positives across the entire frame.
    """
    box_w, box_h = width // 4, height // 4
    frames = []
    for i in range(num_frames):
        bg_level = min(100 + i, 255)
        frame = np.full((height, width, 3), bg_level, dtype=np.uint8)
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
