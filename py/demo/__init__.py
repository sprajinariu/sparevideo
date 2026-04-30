"""Demo asset generation: compose triptychs and encode animated WebP for the README.

Invoked as:
    PYTHONPATH=py python -m demo --input <input.bin> --ccl <ccl.bin> \\
                                  --motion <motion.bin> --out <out.webp> \\
                                  --width W --height H --frames N [--fps 15]
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from frames.frame_io import read_frames
from demo.compose import compose_triptych
from demo.encode import write_webp


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Compose + encode the README demo WebP.")
    p.add_argument("--input",  required=True, help="Path to input frames (.bin)")
    p.add_argument("--ccl",    required=True, help="Path to ccl_bbox sim output (.bin)")
    p.add_argument("--motion", required=True, help="Path to motion sim output (.bin)")
    p.add_argument("--out",    required=True, help="Output animated WebP path")
    p.add_argument("--width",  type=int, required=True)
    p.add_argument("--height", type=int, required=True)
    p.add_argument("--frames", type=int, required=True)
    p.add_argument("--fps",    type=int, default=15)
    args = p.parse_args(argv)

    inp = read_frames(args.input,  mode="binary",
                      width=args.width, height=args.height, num_frames=args.frames)
    ccl = read_frames(args.ccl,    mode="binary",
                      width=args.width, height=args.height, num_frames=args.frames)
    mot = read_frames(args.motion, mode="binary",
                      width=args.width, height=args.height, num_frames=args.frames)

    triptych = compose_triptych(inp, ccl, mot)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    write_webp(triptych, args.out, fps=args.fps)
    print(f"Wrote {args.out} ({len(triptych)} frames @ {args.fps} fps)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
