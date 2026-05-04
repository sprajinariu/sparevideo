"""OpenCV-based prep utility for the README demo's real-video clip.

Trims a window from a source MP4, stabilizes each frame against frame 0
(anchor-frame strategy with KLT optical flow + similarity transform), resamples
to a target frame rate, resizes to a target resolution, and writes the result
as an MP4. Output is intended for direct commit under `media/source/` so the
README demo pipeline can consume it without further preprocessing.

The motion-detection RTL assumes a fixed camera. Real Pexels-style clips have
sub-pixel tripod sway / autofocus jitter that would otherwise produce global
motion masks; this utility removes that.

Two-pass algorithm:
  Pass 1 — compute a warp matrix M_i for every output frame (anchor-frame KLT,
            similarity transform). Matrices only; no output written yet.
  Safe-rect — intersect per-frame valid-pixel masks (BORDER_CONSTANT=0 warp of
              an all-white source) and find the largest axis-aligned rectangle
              that is fully valid in every frame.
  Pass 2 — re-read source, warp each frame with BORDER_CONSTANT(0), crop to
            the safe rect, resize to (target_w, target_h), write output.

Net effect: output looks like the original framing minus a small inset (the
safe-rect zoom), but with no smeared/replicated edge garbage from rotation.

CLI:
    PYTHONPATH=py python -m demo.stabilize \\
        --src ~/Downloads/source.mp4 \\
        --dst media/source/pexels-pedestrians-320x240.mp4 \\
        --start 4.0 --duration 3.0 \\
        --width 320 --height 240 --fps 15
"""

import argparse
from pathlib import Path
from typing import Union

import cv2
import numpy as np


def _max_rect_in_binary(mask: np.ndarray):
    """Largest axis-aligned all-True rectangle in a 2D boolean mask, via the
    classic histogram-stack algorithm. Returns (x0, y0, x1, y1) half-open."""
    h, w = mask.shape
    heights = np.zeros(w, dtype=np.int64)
    best_area = 0
    best = (0, 0, 0, 0)
    for y in range(h):
        for x in range(w):
            heights[x] = heights[x] + 1 if mask[y, x] else 0
        stack = []  # [(start_x, height), ...]
        for x in range(w + 1):
            cur_h = int(heights[x]) if x < w else 0
            start = x
            while stack and stack[-1][1] >= cur_h:
                top_x, top_h = stack.pop()
                area = top_h * (x - top_x)
                if area > best_area:
                    best_area = area
                    best = (top_x, y - top_h + 1, x, y + 1)
                start = top_x
            stack.append((start, cur_h))
    return best


def _compute_safe_rect(matrices, src_w: int, src_h: int):
    """Given a list of 2x3 affine warp matrices (each maps a source-frame's
    coords to anchor-frame coords) and the source dimensions, return the
    largest axis-aligned (x0, y0, x1, y1) rectangle in output space whose
    pixels are filled from valid source pixels in EVERY frame. The returned
    tuple is half-open in pixel coordinates."""
    src_white = np.full((src_h, src_w), 255, dtype=np.uint8)
    valid = np.full((src_h, src_w), 255, dtype=np.uint8)
    for M in matrices:
        warped_mask = cv2.warpAffine(
            src_white, M, (src_w, src_h),
            flags=cv2.INTER_NEAREST,
            borderMode=cv2.BORDER_CONSTANT, borderValue=0,
        )
        valid = np.minimum(valid, warped_mask)
    return _max_rect_in_binary(valid > 0)


def stabilize_clip(
    src: Union[str, Path],
    dst: Union[str, Path],
    start_s: float,
    duration_s: float,
    target_w: int,
    target_h: int,
    target_fps: int = 15,
    max_features: int = 200,
) -> None:
    """Trim, stabilize, and resize a source MP4 to a fixed-camera output MP4.

    Stabilization uses an anchor-frame strategy: the first trimmed frame is the
    reference, and every later frame is warped so its tracked feature points
    align with the anchor's. Drift across frames is bounded since every warp is
    re-estimated against the same anchor (no cumulative error).

    Transform model is `cv2.estimateAffinePartial2D` (similarity: rotation +
    uniform scale + translation, 4 DOF). This handles camera shake — mostly
    translation, occasionally a small rotation — without overfitting.

    A safe-rect crop is applied after warping (two-pass algorithm) to eliminate
    border artifacts from BORDER_REPLICATE when frames have rotation relative to
    the anchor. The crop region is the largest axis-aligned rectangle valid in
    all frames; it is then resized to (target_w, target_h).
    """
    src_path = str(src)
    dst_path = str(dst)
    Path(dst_path).parent.mkdir(parents=True, exist_ok=True)

    # -------------------------------------------------------------------------
    # Pass 1: read source, compute warp matrices (do NOT write output yet)
    # -------------------------------------------------------------------------
    cap = cv2.VideoCapture(src_path)
    if not cap.isOpened():
        raise RuntimeError(f"could not open source video: {src_path}")
    src_fps = cap.get(cv2.CAP_PROP_FPS)
    if src_fps <= 0:
        raise RuntimeError(f"source video reports invalid fps: {src_fps}")

    # Seek to start window (use frame index, not time, for accuracy)
    start_frame_idx = int(round(start_s * src_fps))
    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame_idx)

    ok, anchor_bgr = cap.read()
    if not ok:
        cap.release()
        raise RuntimeError(f"could not read anchor frame at start_s={start_s}")
    src_h, src_w = anchor_bgr.shape[:2]

    anchor_gray = cv2.cvtColor(anchor_bgr, cv2.COLOR_BGR2GRAY)
    anchor_features = cv2.goodFeaturesToTrack(
        anchor_gray,
        maxCorners=max_features,
        qualityLevel=0.01,
        minDistance=10,
        blockSize=7,
    )
    if anchor_features is None or len(anchor_features) < 4:
        cap.release()
        raise RuntimeError("anchor frame has too few trackable features for stabilization")

    target_out_frames = int(round(duration_s * target_fps))
    src_stride = max(1, int(round(src_fps / target_fps)))

    # Anchor's matrix is identity (maps to itself)
    matrices = [np.eye(2, 3, dtype=np.float32)]

    written_count = 1  # anchor counts as one frame
    src_frame_idx = start_frame_idx + 1

    while written_count < target_out_frames:
        # Skip stride-1 src frames to land on the next target-fps sample.
        for _ in range(src_stride - 1):
            cap.grab()
            src_frame_idx += 1
        ok, frame_bgr = cap.read()
        if not ok:
            break
        src_frame_idx += 1

        gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
        next_features, status, _err = cv2.calcOpticalFlowPyrLK(
            anchor_gray, gray, anchor_features, None
        )
        M = None
        if status is not None:
            mask = status.flatten() == 1
            good_anchor = anchor_features[mask]
            good_next = next_features[mask]
            if len(good_anchor) >= 4:
                M, _ = cv2.estimateAffinePartial2D(
                    good_next, good_anchor, method=cv2.RANSAC,
                    ransacReprojThreshold=2.0,
                )

        if M is None:
            print(f"WARNING: KLT/RANSAC failed for source frame {src_frame_idx - 1}; using identity warp")
            M = np.eye(2, 3, dtype=np.float32)

        matrices.append(M)
        written_count += 1

    cap.release()

    frames_collected = len(matrices)
    if frames_collected < target_out_frames:
        raise RuntimeError(
            f"source ran out before target_out_frames={target_out_frames}; "
            f"only collected {frames_collected} (start_s={start_s}, duration_s={duration_s}, "
            f"src_fps={src_fps}, available frames after start={src_frame_idx - start_frame_idx})"
        )

    # -------------------------------------------------------------------------
    # Compute safe rect: largest axis-aligned rect valid in ALL frames
    # -------------------------------------------------------------------------
    x0, y0, x1, y1 = _compute_safe_rect(matrices, src_w, src_h)
    print(f"safe rect: ({x0},{y0})-({x1},{y1}), {x1-x0}x{y1-y0} of {src_w}x{src_h}")

    if x1 - x0 < 8 or y1 - y0 < 8:
        raise RuntimeError(
            f"safe rect too small: {(x0, y0, x1, y1)} — "
            "clip has too much rotation/translation for this duration"
        )

    # -------------------------------------------------------------------------
    # Pass 2: re-read source, warp + crop + resize, write output
    # -------------------------------------------------------------------------
    cap = cv2.VideoCapture(src_path)
    if not cap.isOpened():
        raise RuntimeError(f"could not re-open source video for pass 2: {src_path}")
    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame_idx)

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    out = cv2.VideoWriter(dst_path, fourcc, float(target_fps), (target_w, target_h))
    if not out.isOpened():
        cap.release()
        raise RuntimeError(f"cv2.VideoWriter could not open {dst_path}")

    written = 0
    src_frame_idx2 = start_frame_idx

    for M in matrices:
        if written == 0:
            # First frame is the anchor — read it directly
            ok, frame_bgr = cap.read()
            if not ok:
                cap.release()
                out.release()
                raise RuntimeError("pass 2: could not re-read anchor frame")
            src_frame_idx2 += 1
        else:
            # Skip stride-1 frames then read
            for _ in range(src_stride - 1):
                cap.grab()
                src_frame_idx2 += 1
            ok, frame_bgr = cap.read()
            if not ok:
                cap.release()
                out.release()
                raise RuntimeError(
                    f"pass 2: source ran out at frame {written} "
                    f"(src frame idx {src_frame_idx2})"
                )
            src_frame_idx2 += 1

        warped = cv2.warpAffine(
            frame_bgr, M, (src_w, src_h),
            flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT, borderValue=0,
        )
        cropped = warped[y0:y1, x0:x1]
        resized = cv2.resize(cropped, (target_w, target_h), interpolation=cv2.INTER_AREA)
        out.write(resized)
        written += 1

    cap.release()
    out.release()

    if written < target_out_frames:
        raise RuntimeError(
            f"pass 2 wrote fewer frames than expected: {written} < {target_out_frames}"
        )


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Trim + stabilize + resize a source MP4.")
    p.add_argument("--src",      required=True, help="Path to source MP4")
    p.add_argument("--dst",      required=True, help="Path to write output MP4")
    p.add_argument("--start",    type=float, required=True, help="Trim start time (seconds)")
    p.add_argument("--duration", type=float, required=True, help="Trim duration (seconds)")
    p.add_argument("--width",    type=int, required=True, help="Output width")
    p.add_argument("--height",   type=int, required=True, help="Output height")
    p.add_argument("--fps",      type=int, default=15, help="Output frame rate")
    args = p.parse_args(argv)

    stabilize_clip(
        src=args.src, dst=args.dst,
        start_s=args.start, duration_s=args.duration,
        target_w=args.width, target_h=args.height,
        target_fps=args.fps,
    )
    print(f"Wrote stabilized clip to {args.dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
