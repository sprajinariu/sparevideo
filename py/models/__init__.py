"""Control-flow reference models for pixel-accurate pipeline verification.

Each control flow has its own module with a run() entry point.
Dispatch via run_model() which maps the control flow name to the correct model.
"""

from models.passthrough import run as _run_passthrough
from models.motion import run as _run_motion
from models.mask import run as _run_mask

_MODELS = {
    "passthrough": _run_passthrough,
    "motion": _run_motion,
    "mask": _run_mask,
}


def run_model(ctrl_flow: str, frames: list, **kwargs) -> list:
    """Run the reference model for a control flow.

    Args:
        ctrl_flow: Control flow name ("passthrough", "motion", "mask").
        frames: List of numpy arrays (H, W, 3), dtype uint8, RGB order.
        **kwargs: Passed through to the model's run() function.

    Returns:
        List of numpy arrays — the expected output frames.
    """
    if ctrl_flow not in _MODELS:
        raise ValueError(
            f"Unknown control flow '{ctrl_flow}'. "
            f"Available: {', '.join(sorted(_MODELS))}"
        )
    return _MODELS[ctrl_flow](frames, **kwargs)
