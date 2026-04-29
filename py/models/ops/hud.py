"""HUD bitmap overlay reference model. Mirrors axis_hud RTL bit-for-bit."""
from __future__ import annotations
import numpy as np
from models.ops.hud_font import FONT_ROM, GLYPH_IDX

FG = np.array([255, 255, 255], dtype=np.uint8)

CTRL_TAG_MAP = {
    "passthrough": "PAS",
    "motion":      "MOT",
    "mask":        "MSK",
    "ccl_bbox":    "CCL",
}


def _decimals(value: int, width: int) -> str:
    """Right-justified zero-padded decimal of `value`, saturated to 10**width-1."""
    cap = 10 ** width - 1
    v = max(0, min(value, cap))
    return f"{v:0{width}d}"


def _layout(frame_num: int, ctrl_flow_tag: str, bbox_count: int, latency_us: int) -> str:
    """30-char layout: 'F:####  T:XXX  N:##  L:#####us'."""
    f = _decimals(frame_num, 4)
    t = ctrl_flow_tag[:3].ljust(3, ' ').upper()
    n = _decimals(bbox_count, 2)
    lat = _decimals(latency_us, 5)
    # Uppercase 'US' suffix — the font ROM only carries uppercase glyphs, and
    # the SV side hard-wires G_U/G_S (also uppercase) into the layout's last two cells.
    s = f"F:{f}  T:{t}  N:{n}  L:{lat}US"
    assert len(s) == 30, f"layout len {len(s)} != 30: {s!r}"
    return s


def hud(frame: np.ndarray, *, frame_num: int, ctrl_flow_tag: str,
        bbox_count: int, latency_us: int,
        hud_x0: int = 8, hud_y0: int = 8, n_chars: int = 30) -> np.ndarray:
    out = frame.copy()
    layout = _layout(frame_num, ctrl_flow_tag, bbox_count, latency_us)
    H, W = frame.shape[:2]
    for c in range(n_chars):
        ch = layout[c]
        gi = GLYPH_IDX.get(ch, GLYPH_IDX[' '])
        rom = FONT_ROM[gi]
        for ry in range(8):
            y = hud_y0 + ry
            if y < 0 or y >= H:
                continue
            row_byte = rom[ry]
            for rx in range(8):
                x = hud_x0 + c * 8 + rx
                if x < 0 or x >= W:
                    continue
                bit = (row_byte >> (7 - rx)) & 1
                if bit:
                    out[y, x] = FG
    return out
