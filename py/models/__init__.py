"""Control-flow reference models for pixel-accurate pipeline verification.

Each control flow has its own module with a run() entry point.
Dispatch via run_model() which maps the control flow name to the correct model.

Pipeline-stage flags are applied in this dispatcher so each control-flow model
only needs to know about its own algorithm:
  - hflip_en:  applied at the head (frames mirrored before dispatch).
  - gamma_en:  applied at the tail (sRGB encode on each output frame).
  - scaler_en: applied at the very tail (2x bilinear spatial upscale).
  - hud_en:    applied at the very, very tail (HUD bitmap overlay).
"""

from models.ops.gamma_cor import gamma_cor as _gamma_cor
from models.ops.hflip     import hflip      as _hflip
from models.ops.scale2x   import scale2x    as _scale2x
from models.ops.hud       import hud        as _hud, CTRL_TAG_MAP
from models.ops._hud_metadata import load_latencies as _load_latencies
from models.bbox_counts   import bbox_counts_per_frame as _bbox_counts
from models.passthrough   import run as _run_passthrough
from models.motion        import run as _run_motion
from models.mask          import run as _run_mask
from models.ccl_bbox      import run as _run_ccl_bbox

_MODELS = {
    "passthrough": _run_passthrough,
    "motion":      _run_motion,
    "mask":        _run_mask,
    "ccl_bbox":    _run_ccl_bbox,
}


def run_model(ctrl_flow: str, frames: list, **kwargs) -> list:
    if ctrl_flow not in _MODELS:
        raise ValueError(
            f"Unknown control flow '{ctrl_flow}'. "
            f"Available: {', '.join(sorted(_MODELS))}"
        )
    hflip_en  = kwargs.pop("hflip_en", False)
    gamma_en  = kwargs.pop("gamma_en", False)
    scaler_en = kwargs.pop("scaler_en", False)
    hud_en    = kwargs.pop("hud_en", False)
    in_frames = [_hflip(f) for f in frames] if hflip_en else frames
    out = _MODELS[ctrl_flow](in_frames, **kwargs)
    if gamma_en:
        out = [_gamma_cor(f) for f in out]
    if scaler_en:
        out = [_scale2x(f) for f in out]
    if hud_en:
        n = len(out)
        latencies = _load_latencies(n)
        bbox_kwargs = {k: kwargs[k] for k in
                       ("motion_thresh", "alpha_shift", "alpha_shift_slow",
                        "grace_frames", "grace_alpha_shift", "gauss_en",
                        "morph_en") if k in kwargs}
        bbox_counts = _bbox_counts(ctrl_flow, in_frames, **bbox_kwargs)
        # SV samples u_ccl_bboxes.valid at HUD-input-SOF — at that moment, CCL
        # still holds the previous frame's bboxes (its commit happens at the
        # frame's own EOF, after HUD-SOF). Shift the model's per-frame counts
        # by one position so frame i displays frame i-1's count (zero on frame 0).
        bbox_counts = [0] + bbox_counts[:-1] if bbox_counts else bbox_counts
        tag = CTRL_TAG_MAP.get(ctrl_flow, "???")
        out = [_hud(f, frame_num=i, ctrl_flow_tag=tag,
                    bbox_count=bbox_counts[i], latency_us=latencies[i])
               for i, f in enumerate(out)]
    return out
