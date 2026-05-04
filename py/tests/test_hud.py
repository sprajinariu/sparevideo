import numpy as np
from models.ops.hud import hud, FG


def test_hud_outside_region_is_passthrough():
    # 64x64 RGB frame of solid grey
    frame = np.full((64, 64, 3), 100, dtype=np.uint8)
    out = hud(frame, frame_num=0, ctrl_flow_tag="MOT", bbox_count=0, latency_us=0,
              hud_x0=8, hud_y0=8, n_chars=30)
    # The HUD region (rows 8..15, cols 8..247) extends past the 64-wide frame,
    # but the visible pixels outside that region in this 64x64 frame are:
    #   rows 0..7 (above HUD), rows 16..63 (below HUD), and cols 0..7 of rows 8..15.
    # All three must be unchanged from the grey-100 input.
    assert (out[0:8, :] == 100).all()
    assert (out[16:, :] == 100).all()
    assert (out[8:16, 0:8] == 100).all()


def test_hud_renders_F_glyph_at_origin():
    # Make a 32x32 black frame; ask the HUD to render only the 'F' digit at (8,8).
    frame = np.zeros((32, 32, 3), dtype=np.uint8)
    out = hud(frame, frame_num=0, ctrl_flow_tag="MOT", bbox_count=0, latency_us=0,
              hud_x0=8, hud_y0=8, n_chars=1)
    # First glyph in layout is 'F'. The 'F' bitmap row 0 is 0x7E = 0b01111110.
    # That means cols (8..14) are FG, col 15 is BG. Row 7 of 'F' is 0x00 (all BG).
    cell = out[8:16, 8:16]
    # Row 0: cols 1..6 white, others black.
    assert (cell[0, 1:7] == FG).all()
    assert (cell[0, 0] == 0).all()
    assert (cell[0, 7] == 0).all()
    # Row 7: all black.
    assert (cell[7] == 0).all()


def test_hud_layout_string_format():
    from models.ops.hud import _layout
    assert _layout(42, "MOT", 5, 1234) == "F:0042  T:MOT  N:05  L:01234US"
    # Saturation
    assert _layout(99999, "PAS", 200, 999999) == "F:9999  T:PAS  N:99  L:99999US"
    # Truncated tag
    assert _layout(0, "MASK", 0, 0)[:14] == "F:0000  T:MAS "


def test_dispatcher_applies_hud_when_enabled(monkeypatch, tmp_path):
    # Force the latency file to a deterministic stub.
    lat_file = tmp_path / "hud_latency.txt"
    lat_file.write_text("100\n200\n")
    monkeypatch.setenv("HUD_LATENCY_FILE", str(lat_file))

    from models import run_model
    frames = [np.zeros((32, 32, 3), dtype=np.uint8) for _ in range(2)]
    out = run_model("passthrough", frames,
                    motion_thresh=16, alpha_shift=3, alpha_shift_slow=6,
                    grace_frames=0, grace_alpha_shift=1,
                    gauss_en=True, morph_open_en=True, morph_close_en=False,
                    morph_close_kernel=3, hflip_en=False,
                    gamma_en=False, scaler_en=False, hud_en=True,
                    bbox_color=0x00FF00)
    # HUD region (rows 8..15) must contain at least one white pixel from the 'F' glyph.
    assert (out[0][8:16, 8:16] == 255).any()
    # Outside, still black.
    assert (out[0][:8, :] == 0).all()
