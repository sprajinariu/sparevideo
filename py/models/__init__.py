"""Control-flow reference models for pixel-accurate pipeline verification.

Each control flow has its own module with a run() entry point.
Dispatch via run_model() which maps the control flow name to the correct model.

Pipeline-stage flags (e.g. `hflip_en`) are applied in this dispatcher so each
control-flow model only needs to know about its own algorithm.
"""

from models.ops.hflip   import hflip as _hflip
from models.passthrough import run as _run_passthrough
from models.motion      import run as _run_motion
from models.mask        import run as _run_mask
from models.ccl_bbox    import run as _run_ccl_bbox

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
    # Pre-flip frames once at the head of the pipeline. Mirrors the RTL
    # placement: axis_hflip sits before the ctrl_flow mux, so motion masks
    # and bbox coordinates are computed on the flipped view.
    hflip_en = kwargs.pop("hflip_en", False)
    if hflip_en:
        frames = [_hflip(f) for f in frames]
    return _MODELS[ctrl_flow](frames, **kwargs)
