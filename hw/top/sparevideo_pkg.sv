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
        logic       morph_en;            // 3x3 opening on mask
        logic       hflip_en;            // horizontal mirror on input
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
        motion_thresh:     8'd16,
        alpha_shift:       3,
        alpha_shift_slow:  6,
        grace_frames:      0,
        grace_alpha_shift: 1,
        gauss_en:          1'b1,
        morph_en:          1'b1,
        hflip_en:          1'b0,
        bbox_color:        24'h00_FF_00
    };

    // Default + horizontal mirror (selfie-cam).
    localparam cfg_t CFG_DEFAULT_HFLIP = '{
        motion_thresh:     8'd16,
        alpha_shift:       3,
        alpha_shift_slow:  6,
        grace_frames:      0,
        grace_alpha_shift: 1,
        gauss_en:          1'b1,
        morph_en:          1'b1,
        hflip_en:          1'b1,
        bbox_color:        24'h00_FF_00
    };

    // EMA disabled — alpha=1 on both rates means bg follows the current
    // frame exactly, so the motion test reduces to raw frame-to-frame
    // differencing. Useful as a baseline against the smoothed default.
    localparam cfg_t CFG_NO_EMA = '{
        motion_thresh:     8'd16,
        alpha_shift:       0,
        alpha_shift_slow:  0,
        grace_frames:      0,
        grace_alpha_shift: 1,
        gauss_en:          1'b1,
        morph_en:          1'b1,
        hflip_en:          1'b0,
        bbox_color:        24'h00_FF_00
    };

    // 3x3 mask opening bypassed.
    localparam cfg_t CFG_NO_MORPH = '{
        motion_thresh:     8'd16,
        alpha_shift:       3,
        alpha_shift_slow:  6,
        grace_frames:      0,
        grace_alpha_shift: 1,
        gauss_en:          1'b1,
        morph_en:          1'b0,
        hflip_en:          1'b0,
        bbox_color:        24'h00_FF_00
    };

    // 3x3 Gaussian pre-filter bypassed.
    localparam cfg_t CFG_NO_GAUSS = '{
        motion_thresh:     8'd16,
        alpha_shift:       3,
        alpha_shift_slow:  6,
        grace_frames:      0,
        grace_alpha_shift: 1,
        gauss_en:          1'b0,
        morph_en:          1'b1,
        hflip_en:          1'b0,
        bbox_color:        24'h00_FF_00
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
