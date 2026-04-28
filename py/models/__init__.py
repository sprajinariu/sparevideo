"""Control-flow reference models for pixel-accurate pipeline verification.

Each control flow has its own module with a run() entry point.
Dispatch via run_model() which maps the control flow name to the correct model.

Pipeline-stage flags are applied in this dispatcher so each control-flow model
only needs to know about its own algorithm:
  - hflip_en: applied at the head (frames mirrored before dispatch).
  - gamma_en: applied at the tail (sRGB encode on each output frame).
  - scaler:   applied at the very tail (2x spatial upscale, nn|bilinear).
"""

from models.ops.gamma_cor import gamma_cor as _gamma_cor
from models.ops.hflip     import hflip      as _hflip
from models.ops.scale2x   import scale2x    as _scale2x
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
    hflip_en     = kwargs.pop("hflip_en", False)
    gamma_en     = kwargs.pop("gamma_en", False)
    scaler       = kwargs.pop("scaler", False)
    scale_filter = kwargs.pop("scale_filter", "bilinear")
    if hflip_en:
        frames = [_hflip(f) for f in frames]
    out = _MODELS[ctrl_flow](frames, **kwargs)
    if gamma_en:
        out = [_gamma_cor(f) for f in out]
    if scaler:
        out = [_scale2x(f, mode=scale_filter) for f in out]
    return out
