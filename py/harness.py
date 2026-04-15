#!/usr/bin/env python3
"""Pipeline harness CLI: prepare input, verify output, render comparison."""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

from frames.frame_io import read_frames, write_frames
from frames.video_source import load_frames
from models import run_model
from viz.render import compare_frames, render_grid

META_FILENAME = "meta.json"


def _write_meta(data_dir, width, height, num_frames):
    """Write metadata sidecar so verify/render can auto-detect dimensions."""
    meta = {"width": width, "height": height, "frames": num_frames}
    meta_path = Path(data_dir) / META_FILENAME
    with open(meta_path, "w") as f:
        json.dump(meta, f)


def _read_meta(data_dir):
    """Read metadata sidecar. Returns dict with width, height, frames."""
    meta_path = Path(data_dir) / META_FILENAME
    if not meta_path.exists():
        return None
    with open(meta_path) as f:
        return json.load(f)


def _resolve_dims(args):
    """Resolve width/height/frames: use CLI args if explicitly set, else read meta.json."""
    # Check if the user passed explicit values (argparse defaults are None when
    # we use default=None below, so we can detect "not passed")
    width = args.width
    height = args.height
    frames = args.frames

    if width is None or height is None or frames is None:
        # Try to load from meta.json in the data directory
        data_dir = Path(args.input).parent if hasattr(args, "input") else None
        meta = _read_meta(data_dir) if data_dir else None
        if meta:
            if width is None:
                width = meta["width"]
            if height is None:
                height = meta["height"]
            if frames is None:
                frames = meta["frames"]
        else:
            # Fall back to defaults
            if width is None:
                width = 320
            if height is None:
                height = 240
            if frames is None:
                frames = 4

    return width, height, frames


def _load_input_output(args):
    """Load input and output frames based on mode and resolved dimensions."""
    width, height, frames = _resolve_dims(args)

    if args.mode == "text":
        input_frames = read_frames(
            args.input, mode="text",
            width=width, height=height, num_frames=frames,
        )
        output_frames = read_frames(
            args.output, mode="text",
            width=width, height=height, num_frames=frames,
        )
    else:
        input_frames = read_frames(args.input, mode="binary")
        output_frames = read_frames(args.output, mode="binary")

    return input_frames, output_frames


def cmd_prepare(args):
    """Load frames from source, write input file for SV simulation."""
    width = args.width or 320
    height = args.height or 240
    num_frames = args.frames or 4

    frames = load_frames(args.source, width, height, num_frames)

    output_path = Path(args.output)
    write_frames(args.output, frames, mode=args.mode)

    # Write metadata sidecar
    _write_meta(output_path.parent, width, height, len(frames))

    print(f"Prepared {len(frames)} frames ({width}x{height})")
    print(f"  {args.mode}: {args.output}")


def cmd_verify(args):
    """Compare RTL output against reference model output."""
    input_frames, output_frames = _load_input_output(args)
    ctrl_flow = args.ctrl_flow
    tolerance = args.tolerance

    expected_frames = run_model(ctrl_flow, input_frames)
    results = compare_frames(expected_frames, output_frames, tolerance=tolerance)

    all_pass = True
    for r in results:
        status = "PASS" if r["match"] else "FAIL"
        if not r["match"]:
            all_pass = False
        print(f"Frame {r['frame_idx']}: {status}"
              f"  max_diff={r['max_diff']} mean_diff={r['mean_diff']:.2f}"
              f"  diff_pixels={r['num_diff_pixels']} (tolerance={tolerance})")

    if all_pass:
        print(f"\nPASS: {len(results)} frames verified"
              f" (model={ctrl_flow}, tolerance={tolerance})")
    else:
        print(f"\nFAIL: some frames differ from {ctrl_flow} model"
              f" (tolerance={tolerance} pixels)")
        sys.exit(1)


def cmd_render(args):
    """Render input vs output comparison grid."""
    input_frames, output_frames = _load_input_output(args)
    ctrl_flow = getattr(args, "ctrl_flow", None)
    reference_frames = None
    if ctrl_flow:
        reference_frames = run_model(ctrl_flow, input_frames)
    out_path = render_grid(input_frames, output_frames, args.render_output,
                           reference_frames=reference_frames)
    print(f"Rendered comparison grid to {out_path}")


def main():
    parser = argparse.ArgumentParser(description="Pipeline test harness")
    sub = parser.add_subparsers(dest="command", required=True)

    # Common args — defaults are None so we can detect "not passed" and fall
    # back to meta.json for verify/render.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--width", type=int, default=None)
    common.add_argument("--height", type=int, default=None)
    common.add_argument("--frames", type=int, default=None)
    common.add_argument("--mode", choices=["text", "binary"], default="text")

    # prepare
    p_prep = sub.add_parser("prepare", parents=[common],
                            help="Prepare input frames for simulation")
    p_prep.add_argument("--source", default="synthetic:color_bars",
                        help="Video file, image dir, or synthetic:<pattern>")
    p_prep.add_argument("--output", default="dv/data/input.txt",
                        help="Output file path")

    # verify
    p_ver = sub.add_parser("verify", parents=[common],
                           help="Verify RTL output against reference model")
    p_ver.add_argument("--input", default="dv/data/input.txt",
                       help="Input file (text or binary)")
    p_ver.add_argument("--output", default="dv/data/output.txt",
                       help="Output file (text or binary)")
    p_ver.add_argument("--ctrl-flow", default="passthrough",
                       choices=["passthrough", "motion", "mask"],
                       help="Control flow model to verify against "
                            "(default: passthrough)")
    p_ver.add_argument("--tolerance", type=int, default=0,
                       help="Max differing pixels per frame that still counts "
                            "as PASS (default 0 = exact match).")

    # render
    p_ren = sub.add_parser("render", parents=[common],
                           help="Render input vs output comparison")
    p_ren.add_argument("--input", default="dv/data/input.txt",
                       help="Input file")
    p_ren.add_argument("--output", default="dv/data/output.txt",
                       help="Output file")
    p_ren.add_argument("--ctrl-flow", default=None,
                       choices=["passthrough", "motion", "mask"],
                       help="Control flow model to include as reference row")
    p_ren.add_argument("--render-output", default="dv/data/renders/comparison.png",
                       help="Output PNG path")

    args = parser.parse_args()

    if args.command == "prepare":
        cmd_prepare(args)
    elif args.command == "verify":
        cmd_verify(args)
    elif args.command == "render":
        cmd_render(args)


if __name__ == "__main__":
    main()
