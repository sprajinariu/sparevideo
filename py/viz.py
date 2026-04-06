#!/usr/bin/env python3
"""Convert raw VGA frame dump(s) to PNG images.

Reads a binary file produced by tb_vga_viz.sv (3 bytes per pixel, R-G-B,
row-major, 640x480 per frame) and saves as PNG.

Usage:
    python3 viz.py <input.bin> [output.png]
    python3 viz.py <input.bin> --multi <num_frames> [output_dir]
"""

import sys
import os
from PIL import Image

WIDTH = 640
HEIGHT = 480
FRAME_BYTES = WIDTH * HEIGHT * 3  # 921,600


def raw_to_image(data, width=WIDTH, height=HEIGHT):
    """Convert raw RGB byte data to a PIL Image."""
    img = Image.frombytes("RGB", (width, height), data)
    return img


def convert_single(bin_path, png_path):
    """Convert a single-frame binary dump to PNG."""
    with open(bin_path, "rb") as f:
        data = f.read(FRAME_BYTES)
    if len(data) < FRAME_BYTES:
        print(f"Warning: expected {FRAME_BYTES} bytes, got {len(data)}", file=sys.stderr)
    img = raw_to_image(data)
    img.save(png_path)
    print(f"  {os.path.basename(png_path)} ({WIDTH}x{HEIGHT})")


def convert_multi(bin_path, num_frames, output_dir):
    """Convert a multi-frame binary dump to numbered PNGs."""
    os.makedirs(output_dir, exist_ok=True)
    with open(bin_path, "rb") as f:
        for i in range(num_frames):
            data = f.read(FRAME_BYTES)
            if len(data) < FRAME_BYTES:
                print(f"Warning: frame {i} truncated ({len(data)} bytes)", file=sys.stderr)
                if len(data) == 0:
                    break
            png_path = os.path.join(output_dir, f"frame_{i:04d}.png")
            img = raw_to_image(data)
            img.save(png_path)
            print(f"  frame_{i:04d}.png")


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input.bin> [output.png]")
        print(f"       {sys.argv[0]} <input.bin> --multi <num_frames> [output_dir]")
        sys.exit(1)

    bin_path = sys.argv[1]

    if "--multi" in sys.argv:
        idx = sys.argv.index("--multi")
        num_frames = int(sys.argv[idx + 1])
        output_dir = sys.argv[idx + 2] if idx + 2 < len(sys.argv) else "output"
        convert_multi(bin_path, num_frames, output_dir)
    else:
        png_path = sys.argv[2] if len(sys.argv) > 2 else bin_path.replace(".bin", ".png")
        convert_single(bin_path, png_path)


if __name__ == "__main__":
    main()
