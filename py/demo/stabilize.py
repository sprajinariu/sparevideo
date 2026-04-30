"""OpenCV-based prep utility for the README demo's real-video clip.

Trims a window from a source MP4, stabilizes each frame against frame 0
(anchor-frame strategy with KLT optical flow + similarity transform), resamples
to a target frame rate, resizes to a target resolution, and writes the result
as an MP4. Output is intended for direct commit under `media/source/` so the
README demo pipeline can consume it without further preprocessing.

The motion-detection RTL assumes a fixed camera. Real Pexels-style clips have
sub-pixel tripod sway / autofocus jitter that would otherwise produce global
motion masks; this utility removes that.

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
    """
    src_path = str(src)
    dst_path = str(dst)
    Path(dst_path).parent.mkdir(parents=True, exist_ok=True)

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

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    out = cv2.VideoWriter(dst_path, fourcc, float(target_fps), (target_w, target_h))
    if not out.isOpened():
        cap.release()
        raise RuntimeError(f"cv2.VideoWriter could not open {dst_path}")

    target_out_frames = int(round(duration_s * target_fps))
    src_stride = max(1, int(round(src_fps / target_fps)))

    def _resize(frame_bgr: np.ndarray) -> np.ndarray:
        return cv2.resize(frame_bgr, (target_w, target_h), interpolation=cv2.INTER_AREA)

    # Anchor goes through unchanged (it's already aligned with itself).
    out.write(_resize(anchor_bgr))
    written = 1
    src_frame_idx = start_frame_idx + 1

    while written < target_out_frames:
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
        if status is None:
            stabilized = frame_bgr
        else:
            mask = status.flatten() == 1
            good_anchor = anchor_features[mask]
            good_next = next_features[mask]
            if len(good_anchor) < 4:
                stabilized = frame_bgr
            else:
                # Solve: warp next->anchor. Using estimateAffinePartial2D for
                # similarity transform (4 DOF — translation + rotation + uniform scale).
                M, _ = cv2.estimateAffinePartial2D(
                    good_next, good_anchor, method=cv2.RANSAC,
                    ransacReprojThreshold=2.0,
                )
                if M is None:
                    stabilized = frame_bgr
                else:
                    stabilized = cv2.warpAffine(
                        frame_bgr, M, (src_w, src_h),
                        flags=cv2.INTER_LINEAR,
                        borderMode=cv2.BORDER_REPLICATE,
                    )

        out.write(_resize(stabilized))
        written += 1

    cap.release()
    out.release()

    if written < target_out_frames:
        raise RuntimeError(
            f"source ran out before target_out_frames={target_out_frames}; "
            f"only wrote {written} (start_s={start_s}, duration_s={duration_s}, "
            f"src_fps={src_fps}, available frames after start={src_frame_idx - start_frame_idx})"
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
