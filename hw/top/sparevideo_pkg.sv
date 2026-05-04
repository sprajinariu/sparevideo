// sparevideo_pkg — project-wide parameters and types.
//
// All configuration parameters (video timing defaults, algorithm knobs,
// pipeline constants) and shared typedefs live here. Modules import this
// package and use the constants as parameter defaults or directly.
//
// Migration path: when runtime configurability is added (sparevideo_csr),
// these localparams become the reset-value table for the CSR register file.
// The downstream modules' parameter ports become input ports driven by the
// CSR block instead of by localparams from sparevideo_top.

package sparevideo_pkg;

    // ---------------------------------------------------------------
    // Shared types
    // ---------------------------------------------------------------

    // 24-bit packed RGB pixel {R[7:0], G[7:0], B[7:0]}
    typedef logic [23:0] pixel_t;

    // 8-bit colour component (R, G, B, Y, Cb, Cr)
    typedef logic [7:0]  component_t;

    // ---------------------------------------------------------------
    // Control flow selection (top-level pipeline mode)
    // ---------------------------------------------------------------
    localparam logic [1:0] CTRL_PASSTHROUGH   = 2'b00;
    localparam logic [1:0] CTRL_MOTION_DETECT = 2'b01;
    localparam logic [1:0] CTRL_MASK_DISPLAY  = 2'b10;
    localparam logic [1:0] CTRL_CCL_BBOX      = 2'b11;

    // ---------------------------------------------------------------
    // Default video timing (320x240 — small, fast-to-simulate)
    // Override at sparevideo_top instantiation for other resolutions.
    // ---------------------------------------------------------------
    localparam int H_ACTIVE      = 320;
    localparam int H_FRONT_PORCH = 4;
    localparam int H_SYNC_PULSE  = 8;
    localparam int H_BACK_PORCH  = 4;

    localparam int V_ACTIVE      = 240;
    localparam int V_FRONT_PORCH = 2;
    localparam int V_SYNC_PULSE  = 2;
    localparam int V_BACK_PORCH  = 2;

    // ---------------------------------------------------------------
    // Output VGA timing — selected by the top-level SCALER parameter.
    //
    // SCALER=0 (default): output dims == input dims (the existing
    // path). SCALER=1: 2x upscale → 640x480.
    //
    // Both H and V porches double in the SCALER=1 case so that the
    // OUTPUT-frame wall-clock matches 4x the INPUT-frame wall-clock
    // exactly. With clk_pix_in : clk_pix_out = 1:4 (the two-pix-clk
    // model in axis_scale2x-arch.md §7a), this gives sustained
    // rate balance over an arbitrary frame count. Concretely:
    //   T_in_frame  = (H_in + ph_in) × (V_in + pv_in) × T_pix_in
    //   T_out_frame = (2H_in + 2ph_in) × (2V_in + 2pv_in) × T_pix_out
    //               = 4 × (H_in + ph_in)(V_in + pv_in) × T_pix_out
    //               = T_in_frame   when T_pix_in = 4·T_pix_out
    // The rate-balance assumption is documented per-block in
    // axis_scale2x-arch.md §7a; real silicon still needs genlock or a
    // frame buffer to absorb crystal tolerances.
    // ---------------------------------------------------------------
    localparam int H_ACTIVE_OUT_2X      = 2 * H_ACTIVE;
    localparam int H_FRONT_PORCH_OUT_2X = 2 * H_FRONT_PORCH;
    localparam int H_SYNC_PULSE_OUT_2X  = 2 * H_SYNC_PULSE;
    localparam int H_BACK_PORCH_OUT_2X  = 2 * H_BACK_PORCH;

    localparam int V_ACTIVE_OUT_2X      = 2 * V_ACTIVE;
    localparam int V_FRONT_PORCH_OUT_2X = 2 * V_FRONT_PORCH;
    localparam int V_SYNC_PULSE_OUT_2X  = 2 * V_SYNC_PULSE;
    localparam int V_BACK_PORCH_OUT_2X  = 2 * V_BACK_PORCH;

    // ---------------------------------------------------------------
    // Algorithm tuning bundle — one struct, named profiles.
    //
    // Resolution (H_ACTIVE/V_ACTIVE/porches) and sim-only knobs (FRAMES)
    // stay outside this bundle; they have different lifecycles
    // (resolution = structural, FRAMES = sim length).
    //
    // Future runtime CSR will use the active profile as the reset-value
    // table; the same field set carries over.
    // ---------------------------------------------------------------
    typedef struct packed {
        component_t motion_thresh;       // raw |Y_cur - Y_prev| threshold
        int         alpha_shift;         // EMA rate, non-motion pixels
        int         alpha_shift_slow;    // EMA rate, motion pixels
        int         grace_frames;        // aggressive-EMA grace after priming
        int         grace_alpha_shift;   // EMA rate during grace window
        logic       gauss_en;            // 3x3 Gaussian pre-filter on Y
        logic       morph_open_en;       // 3x3 opening on mask
        logic       morph_close_en;      // 3x3 or 5x5 closing on mask
        int         morph_close_kernel;  // 3 or 5; selects close kernel size
        logic       hflip_en;            // horizontal mirror on input
        logic       gamma_en;            // sRGB display gamma at output tail
        logic       scaler_en;           // 2x bilinear upscaler at output tail
        logic       hud_en;              // 8x8 bitmap HUD overlay at post-scaler tail
        pixel_t     bbox_color;          // overlay colour
    } cfg_t;

    // Default: all cleanup stages on, mirror OFF. Use CFG_DEFAULT_HFLIP if
    // you want the selfie-cam mirror enabled. The four CFG_NO_* profiles
    // each disable exactly one stage relative to CFG_DEFAULT, for A/B
    // comparisons of that stage's contribution.
    localparam cfg_t CFG_DEFAULT = '{
        // grace_frames=0: intentional — synthetic sources render frame 0 as
        // background-only, so the frame-0 ghost that the grace window suppresses
        // does not arise. Real-video deployments should override with a higher value.
        // hflip_en=0: intentional — mirror is deliberately OFF in the project
        // default. Use CFG_DEFAULT_HFLIP for selfie-cam / mirrored-sensor setups.
        // scaler_en=1: 2x upscaler ON by default → 640x480 VGA output.
        // Use CFG_NO_SCALER for the legacy 320x240 native-resolution path.
        motion_thresh:      8'd16,
        alpha_shift:        3,
        alpha_shift_slow:   6,
        grace_frames:       0,
        grace_alpha_shift:  1,
        gauss_en:           1'b1,
        morph_open_en:      1'b1,
        morph_close_en:     1'b1,
        morph_close_kernel: 3,
        hflip_en:           1'b0,
        gamma_en:           1'b1,
        scaler_en:          1'b1,
        hud_en:             1'b1,
        bbox_color:         24'h00_FF_00
    };

    // Default + horizontal mirror (selfie-cam).
    localparam cfg_t CFG_DEFAULT_HFLIP = '{
        motion_thresh:      8'd16,
        alpha_shift:        3,
        alpha_shift_slow:   6,
        grace_frames:       0,
        grace_alpha_shift:  1,
        gauss_en:           1'b1,
        morph_open_en:      1'b1,
        morph_close_en:     1'b1,
        morph_close_kernel: 3,
        hflip_en:           1'b1,
        gamma_en:           1'b1,
        scaler_en:          1'b1,
        hud_en:             1'b1,
        bbox_color:         24'h00_FF_00
    };

    // EMA disabled — alpha=1 on both rates means bg follows the current
    // frame exactly, so the motion test reduces to raw frame-to-frame
    // differencing. Useful as a baseline against the smoothed default.
    localparam cfg_t CFG_NO_EMA = '{
        motion_thresh:      8'd16,
        alpha_shift:        0,
        alpha_shift_slow:   0,
        grace_frames:       0,
        grace_alpha_shift:  1,
        gauss_en:           1'b1,
        morph_open_en:      1'b1,
        morph_close_en:     1'b1,
        morph_close_kernel: 3,
        hflip_en:           1'b0,
        gamma_en:           1'b1,
        scaler_en:          1'b1,
        hud_en:             1'b1,
        bbox_color:         24'h00_FF_00
    };

    // 3x3 mask opening AND closing bypassed.
    localparam cfg_t CFG_NO_MORPH = '{
        motion_thresh:      8'd16,
        alpha_shift:        3,
        alpha_shift_slow:   6,
        grace_frames:       0,
        grace_alpha_shift:  1,
        gauss_en:           1'b1,
        morph_open_en:      1'b0,
        morph_close_en:     1'b0,
        morph_close_kernel: 3,
        hflip_en:           1'b0,
        gamma_en:           1'b1,
        scaler_en:          1'b1,
        hud_en:             1'b1,
        bbox_color:         24'h00_FF_00
    };

    // 3x3 Gaussian pre-filter bypassed.
    localparam cfg_t CFG_NO_GAUSS = '{
        motion_thresh:      8'd16,
        alpha_shift:        3,
        alpha_shift_slow:   6,
        grace_frames:       0,
        grace_alpha_shift:  1,
        gauss_en:           1'b0,
        morph_open_en:      1'b1,
        morph_close_en:     1'b1,
        morph_close_kernel: 3,
        hflip_en:           1'b0,
        gamma_en:           1'b1,
        scaler_en:          1'b1,
        hud_en:             1'b1,
        bbox_color:         24'h00_FF_00
    };

    // sRGB gamma correction bypassed (linear passthrough at output tail).
    localparam cfg_t CFG_NO_GAMMA_COR = '{
        motion_thresh:      8'd16,
        alpha_shift:        3,
        alpha_shift_slow:   6,
        grace_frames:       0,
        grace_alpha_shift:  1,
        gauss_en:           1'b1,
        morph_open_en:      1'b1,
        morph_close_en:     1'b1,
        morph_close_kernel: 3,
        hflip_en:           1'b0,
        gamma_en:           1'b0,
        scaler_en:          1'b1,
        hud_en:             1'b1,
        bbox_color:         24'h00_FF_00
    };

    // 2x scaler bypassed — output stays at native 320x240. The upstream
    // pipeline is unchanged; this profile is byte-identical to the
    // pre-scaler design's CFG_DEFAULT for SCALER=0.
    localparam cfg_t CFG_NO_SCALER = '{
        motion_thresh:      8'd16,
        alpha_shift:        3,
        alpha_shift_slow:   6,
        grace_frames:       0,
        grace_alpha_shift:  1,
        gauss_en:           1'b1,
        morph_open_en:      1'b1,
        morph_close_en:     1'b1,
        morph_close_kernel: 3,
        hflip_en:           1'b0,
        gamma_en:           1'b1,
        scaler_en:          1'b0,
        hud_en:             1'b1,
        bbox_color:         24'h00_FF_00
    };

    // CFG_DEMO: tuned for the README demo. Differences from CFG_DEFAULT:
    //   scaler_en=0          — 320x240 panels for the triptych
    //   gamma_en=0           — sources are already sRGB-encoded
    //   alpha_shift=2        — faster fast-EMA (~4-frame recovery)
    //   alpha_shift_slow=8   — bg barely drifts under sustained motion (~1/256
    //                          per frame) so slow objects don't accumulate
    //                          enough bg contamination to leave a trailing
    //                          mask after the trailing edge passes (safe here:
    //                          the 3 s demo has no stationary objects long
    //                          enough to need bg-absorption protection)
    //   grace_frames=0       — synthetic source renders frame 0 as bg-only
    //                          (boxes start off-frame), so EMA hard-init has
    //                          no foreground to bake in; the real clip relies
    //                          on PRIME_FRAMES + the EMA's natural convergence
    //                          rather than a forced grace window.
    localparam cfg_t CFG_DEMO = '{
        motion_thresh:      8'd16,
        alpha_shift:        2,
        alpha_shift_slow:   8,
        grace_frames:       0,
        grace_alpha_shift:  1,
        gauss_en:           1'b1,
        morph_open_en:      1'b1,
        morph_close_en:     1'b1,
        morph_close_kernel: 3,
        hflip_en:           1'b0,
        gamma_en:           1'b0,
        scaler_en:          1'b0,
        hud_en:             1'b1,
        bbox_color:         24'h00_FF_00
    };

    // HUD bitmap overlay bypassed (post-scaler tail is identity passthrough).
    // Byte-identical to CFG_DEFAULT for every pixel outside the HUD region.
    localparam cfg_t CFG_NO_HUD = '{
        motion_thresh:      8'd16,
        alpha_shift:        3,
        alpha_shift_slow:   6,
        grace_frames:       0,
        grace_alpha_shift:  1,
        gauss_en:           1'b1,
        morph_open_en:      1'b1,
        morph_close_en:     1'b1,
        morph_close_kernel: 3,
        hflip_en:           1'b0,
        gamma_en:           1'b1,
        scaler_en:          1'b1,
        hud_en:             1'b0,
        bbox_color:         24'h00_FF_00
    };

    // ---------------------------------------------------------------
    // CCL (Block 4) parameters — defaults; override at instantiation.
    // ---------------------------------------------------------------
    localparam int CCL_N_LABELS_INT        = 64;
    localparam int CCL_N_OUT               = 8;
    localparam int CCL_MIN_COMPONENT_PIXELS = 16;
    localparam int CCL_MAX_CHAIN_DEPTH     = 8;
    // Suppress the first N frames' bboxes so the EMA background has time to
    // converge; during priming the front buffer stays all-invalid. Matches
    // py/models/motion.py PRIME_FRAMES. Default 0 now that synthetic sources
    // render frame 0 as bg-only (no frame-0 foreground-baked-into-bg ghost).
    localparam int CCL_PRIME_FRAMES        = 0;

endpackage
