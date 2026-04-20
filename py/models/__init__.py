"""Control-flow reference models for pixel-accurate pipeline verification.

Each control flow has its own module with a run() entry point.
Dispatch via run_model() which maps the control flow name to the correct model.
"""

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
    return _MODELS[ctrl_flow](frames, **kwargs)
