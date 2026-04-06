"""Read/write frame files in text and binary formats.

Text format (.txt):
    Space-separated hex bytes, one row per line. No header.
    FF 00 00 FF 00 00 ...
    ...

Binary format (.bin):
    Bytes 0-3:   WIDTH  (32-bit little-endian)
    Bytes 4-7:   HEIGHT (32-bit little-endian)
    Bytes 8-11:  FRAMES (32-bit little-endian)
    Bytes 12+:   raw pixel data, 3 bytes/pixel (R,G,B), row-major
"""

import struct
from pathlib import Path

import numpy as np


def write_frames(path, frames, mode="text"):
    """Write a list of numpy arrays (H, W, 3) uint8 to a frame file.

    Args:
        path: Output file path.
        frames: List of numpy arrays, each (H, W, 3) dtype uint8.
        mode: 'text' or 'binary'.
    """
    if not frames:
        raise ValueError("No frames to write")

    h, w, c = frames[0].shape
    if c != 3:
        raise ValueError(f"Expected 3 channels, got {c}")

    path = Path(path)

    if mode == "text":
        _write_text(path, frames, w, h)
    elif mode == "binary":
        _write_binary(path, frames, w, h)
    else:
        raise ValueError(f"Unknown mode: {mode}")


def read_frames(path, mode="text", **kwargs):
    """Read a frame file into a list of numpy arrays (H, W, 3) uint8.

    Args:
        path: Input file path.
        mode: 'text' or 'binary'.
        width: Required for text mode.
        height: Required for text mode.
        num_frames: Required for text mode.

    Returns:
        List of numpy arrays, each (H, W, 3) dtype uint8.
    """
    path = Path(path)

    if mode == "text":
        return _read_text(path, **kwargs)
    elif mode == "binary":
        return _read_binary(path)
    else:
        raise ValueError(f"Unknown mode: {mode}")


def _write_text(path, frames, width, height):
    with open(path, "w") as f:
        for frame in frames:
            for row in range(height):
                hex_bytes = []
                for col in range(width):
                    r, g, b = frame[row, col]
                    hex_bytes.extend([f"{r:02X}", f"{g:02X}", f"{b:02X}"])
                f.write(" ".join(hex_bytes) + "\n")


def _read_text(path, width, height, num_frames):
    with open(path, "r") as f:
        lines = f.readlines()

    data_lines = [l.strip() for l in lines if l.strip()]
    frames = []
    line_idx = 0
    for _ in range(num_frames):
        frame = np.zeros((height, width, 3), dtype=np.uint8)
        for row in range(height):
            tokens = data_lines[line_idx].split()
            line_idx += 1
            for col in range(width):
                frame[row, col, 0] = int(tokens[col * 3], 16)
                frame[row, col, 1] = int(tokens[col * 3 + 1], 16)
                frame[row, col, 2] = int(tokens[col * 3 + 2], 16)
        frames.append(frame)
    return frames


def _write_binary(path, frames, width, height):
    num_frames = len(frames)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", width, height, num_frames))
        for frame in frames:
            f.write(frame.tobytes())


def _read_binary(path):
    with open(path, "rb") as f:
        data = f.read()

    width, height, num_frames = struct.unpack("<III", data[:12])
    frame_size = width * height * 3
    frames = []
    offset = 12
    for _ in range(num_frames):
        if offset + frame_size > len(data):
            raise ValueError("Not enough pixel data")
        frame = np.frombuffer(data[offset : offset + frame_size], dtype=np.uint8)
        frame = frame.reshape((height, width, 3))
        frames.append(frame.copy())  # copy so it's writable
        offset += frame_size

    return frames
