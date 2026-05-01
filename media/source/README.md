# Source clips

Source video used by `make demo-real`. Pre-trimmed, stabilized, and pre-resized
to 320×240 so the existing OpenCV loader can ingest it directly.

## `pexels-pedestrians-320x240.mp4`

- **Description:** Intersection fixed camera (cars + pedestrians).
- **Source:** https://www.pexels.com/video/traffic-flow-in-an-intersection-4791734/
- **License:** Pexels License — free for commercial and non-commercial use,
  modification and redistribution permitted, no attribution required.
  See https://www.pexels.com/license/.
- **Prep command:**
  ```bash
  PYTHONPATH=py python -m demo.stabilize \
      --src ~/Downloads/4791734-hd_1920_1080_30fps.mp4 \
      --dst media/source/pexels-pedestrians-320x240.mp4 \
      --start 0 --duration 3 --width 320 --height 240 --fps 15
  ```
  `demo.stabilize` (see [`py/demo/stabilize.py`](../../py/demo/stabilize.py))
  trims the source window, stabilizes every frame against frame 0 using KLT
  optical-flow + similarity transform (anchor-frame strategy with bounded
  drift), resamples 30 → 15 fps, and resizes to 320×240. Stabilization is
  required because the motion-detection RTL assumes a fixed camera; raw clips
  almost always have sub-pixel tripod sway / autofocus jitter that would
  otherwise produce global motion masks.

## Replacing this clip

If you swap to a different source clip:

1. `git rm media/source/<old>.mp4`
2. Run the stabilizer on the new source, writing to `media/source/<new>.mp4`.
3. Update this README's "Description", "Source", and "Prep command" sections.
4. Run `make demo-real` to regenerate the WebP.
5. Commit all three: source MP4, this README, regenerated demo WebP.
