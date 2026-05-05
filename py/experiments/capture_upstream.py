"""Capture upstream PyTorch ViBe masks for each Phase-0 source.

Run this from the upstream venv (NOT the project venv) — upstream has a
PyTorch dependency that must not bleed into the project's .venv.

Usage from outside this repo:
    cd ~/work/sparevideo
    source ~/eval/vibe-upstream/.venv/bin/activate
    python py/experiments/capture_upstream.py
    deactivate

The captured masks land in py/experiments/upstream_baseline_outputs/<source>/
mask_NNNNN.png. The directory is gitignored (it can be regenerated, and it's
arguably derivative of the eval-licensed software).
"""

import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# Add upstream src to sys.path
UPSTREAM_SRC = Path.home() / "eval/vibe-upstream/Python/src"
sys.path.insert(0, str(UPSTREAM_SRC))

# Add our py/ to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from frames.video_source import load_frames

import torch
from model import ViBe as UpstreamViBe


SOURCES = [
    "synthetic:moving_box",
    "synthetic:dark_moving_box",
    "synthetic:noisy_moving_box",
    "synthetic:textured_static",
    "synthetic:lighting_ramp",
    "synthetic:ghost_box_disappear",
    "synthetic:ghost_box_moving",
    "media/source/birdseye-320x240.mp4",
    "media/source/people-320x240.mp4",
    "media/source/intersection-320x240.mp4",
]

OUT_ROOT = Path("py/experiments/upstream_baseline_outputs")
NUM_FRAMES = 200  # 200 frames so frame-0 ghost has time to fully decay (or persistently fail)
DEVICE = torch.device("cpu")


def _rgb_to_y(frame: np.ndarray) -> np.ndarray:
    r = frame[:, :, 0].astype(np.uint16)
    g = frame[:, :, 1].astype(np.uint16)
    b = frame[:, :, 2].astype(np.uint16)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def capture_one(source: str):
    out_dir = OUT_ROOT / source.replace(":", "_").replace("/", "_")
    out_dir.mkdir(parents=True, exist_ok=True)

    frames_rgb = load_frames(source, width=320, height=240, num_frames=NUM_FRAMES)
    frames_y = [_rgb_to_y(f) for f in frames_rgb]

    # Upstream expects (C, H, W) tensor with C=1 grayscale
    H, W = frames_y[0].shape

    # Parameters MATCH our re-impl's defaults for fair cross-check:
    #   K=20 (upstream's typical), R=20 effective, min_match=2, phi=16.
    #
    # Note on matchingThreshold: upstream's segmentation_() hardcodes
    # `matchingThreshold = 4.5 * self.matchingThreshold` (a 3-channel L1-distance
    # scaling that's applied unconditionally even for 1-channel input). To get
    # effective R=20 in their compare, we must pass matchingThreshold = 20/4.5.
    # The C reference doesn't have this 4.5× factor; this is a Python-port-only
    # quirk. Without this compensation, upstream effectively uses R=4.5*passed,
    # which produced upstream_avg≈0 on synthetic:moving_box (everything as bg).
    R_TARGET = 20.0
    UPSTREAM_PY_SCALE = 4.5
    model = UpstreamViBe(
        DEVICE,
        numberOfSamples=20,                              # K=20
        matchingThreshold=R_TARGET / UPSTREAM_PY_SCALE,  # → effective R=20 in compare
        matchingNumber=2,                                # min_match=2
        updateFactor=16.0,                               # phi=16
        neighborhoodRadius=1,
    )
    first = torch.from_numpy(frames_y[0][None, :, :].astype(np.float32))  # (1,H,W)
    model.initialize(first)

    for i, f in enumerate(frames_y):
        t = torch.from_numpy(f[None, :, :].astype(np.float32))
        mask = model.segment(t)  # (H, W) float, 0=bg 1=fg
        mask_u8 = (mask.cpu().numpy() > 0.5).astype(np.uint8) * 255
        Image.fromarray(mask_u8).save(out_dir / f"mask_{i:05d}.png")

    print(f"  captured {NUM_FRAMES} masks → {out_dir}")


if __name__ == "__main__":
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    for s in SOURCES:
        print(f"=== {s} ===")
        capture_one(s)
    print("Done. Masks captured under", OUT_ROOT)
