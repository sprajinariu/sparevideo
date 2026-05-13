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

    // ---------------------------------------------------------------
    // bg_model selector + ViBe enums.
    //
    // These are plain `int` values inside cfg_t (not enums) so the
    // py/profiles.py parity test (which parses literal SV decimals)
    // can compare bit-for-bit. Use the localparam names everywhere
    // EXCEPT inside the CFG_* assignments — there the literal must
    // appear so test_profiles.py can read it.
    //
    // These constants are referenced by Python profiles and future RTL
    // (Phase 2+); no RTL consumer exists yet — suppress UNUSEDPARAM.
    // ---------------------------------------------------------------
    /* verilator lint_off UNUSEDPARAM */
    localparam int BG_MODEL_EMA  = 0;
    localparam int BG_MODEL_VIBE = 1;
    localparam int BG_MODEL_PBAS = 2;

    localparam int BG_INIT_FRAME0           = 0;
    localparam int BG_INIT_LOOKAHEAD_MEDIAN = 1;
    /* verilator lint_on UNUSEDPARAM */

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
        // ---- bg_model selector (Phase 1: Python-only; RTL still EMA) ----
        int         bg_model;            // 0=EMA, 1=ViBe, 2=PBAS — see BG_MODEL_*
        // ---- ViBe knobs (consumed only when bg_model==BG_MODEL_VIBE) ----
        int         vibe_K;              // sample-bank depth per pixel
        int         vibe_R;              // match radius |x - sample_i| < R
        int         vibe_min_match;      // count<min_match ⇒ motion
        int         vibe_phi_update;     // self-update period (power of 2)
        int         vibe_phi_diffuse;    // diffusion period (power of 2; 0=off)
        logic       vibe_bg_init_external;  // 1=look-ahead median init; 0=frame-0 init
        // ---- PBAS knobs (consumed only when bg_model==BG_MODEL_PBAS) ----
        logic [7:0]  pbas_N;             // sample-bank depth per pixel
        logic [7:0]  pbas_R_lower;       // minimum match-radius floor
        logic [3:0]  pbas_R_scale;       // R adaptation scale factor (Q-point)
        logic [3:0]  pbas_Raute_min;     // min # matches needed (≡ ViBe min_match)
        logic [7:0]  pbas_T_lower;       // minimum decision threshold
        logic [7:0]  pbas_T_upper;       // maximum decision threshold
        logic [7:0]  pbas_T_init;        // initial decision threshold per pixel
        logic [7:0]  pbas_R_incdec_q8;   // R increment/decrement step (Q8 fixed-point)
        logic [15:0] pbas_T_inc_q8;      // T increment step (Q8 fixed-point)
        logic [15:0] pbas_T_dec_q8;      // T decrement step (Q8 fixed-point)
        logic [7:0]  pbas_alpha;         // gradient-feature weight numerator
        logic [7:0]  pbas_beta;          // gradient-feature weight denominator shift
        logic [7:0]  pbas_mean_mag_min;  // floor on running mean gradient magnitude
        logic [0:0]  pbas_bg_init_lookahead; // 1=lookahead-median init; 0=paper init
        logic [31:0] pbas_prng_seed;     // PRNG seed for bank-slot selection
        // Engineering knob — NOT a published PBAS parameter.
        // R_upper=0 disables the cap (sentinel). When non-zero, R(x) is clamped
        // from above at this value after the R regulator step, preventing
        // excessive match-radius growth in ghost / high-d_min regions.
        logic [7:0]  pbas_R_upper;       // R(x) upper cap (0=disabled)
        // ---- ViBe persistence-based FG demotion (Phase 1: Python-only) ----
        // Demote_en=0 → canonical ViBe (bit-exact regression preserved).
        // Demote_en=1 → after demote_K_persist FG-classified frames, if any
        // 3x3 BG-classified neighbor's bank holds a sample within R of the
        // current Y (at >= demote_consistency_thresh slots), force-write the
        // current Y into one slot and OR the demote-fire bit into final_bg.
        logic        vibe_demote_en;
        logic [7:0]  vibe_demote_K_persist;
        logic [3:0]  vibe_demote_kernel;            // 3 or 5 (5 reserved for Phase 2)
        logic [3:0]  vibe_demote_consistency_thresh;
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
        bbox_color:                24'h00_FF_00,
        bg_model:                  0,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_bg_init_external:     1'b1,
        pbas_N:                    8'd0,
        pbas_R_lower:              8'd0,
        pbas_R_scale:              4'd0,
        pbas_Raute_min:            4'd0,
        pbas_T_lower:              8'd0,
        pbas_T_upper:              8'd0,
        pbas_T_init:               8'd0,
        pbas_R_incdec_q8:          8'd0,
        pbas_T_inc_q8:             16'd0,
        pbas_T_dec_q8:             16'd0,
        pbas_alpha:                8'd0,
        pbas_beta:                 8'd0,
        pbas_mean_mag_min:         8'd0,
        pbas_bg_init_lookahead:    1'd0,
        pbas_prng_seed:            32'd0,
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
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
        bbox_color:                24'h00_FF_00,
        bg_model:                  0,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_bg_init_external:     1'b1,
        pbas_N:                    8'd0,
        pbas_R_lower:              8'd0,
        pbas_R_scale:              4'd0,
        pbas_Raute_min:            4'd0,
        pbas_T_lower:              8'd0,
        pbas_T_upper:              8'd0,
        pbas_T_init:               8'd0,
        pbas_R_incdec_q8:          8'd0,
        pbas_T_inc_q8:             16'd0,
        pbas_T_dec_q8:             16'd0,
        pbas_alpha:                8'd0,
        pbas_beta:                 8'd0,
        pbas_mean_mag_min:         8'd0,
        pbas_bg_init_lookahead:    1'd0,
        pbas_prng_seed:            32'd0,
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
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
        bbox_color:                24'h00_FF_00,
        bg_model:                  0,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_bg_init_external:     1'b1,
        pbas_N:                    8'd0,
        pbas_R_lower:              8'd0,
        pbas_R_scale:              4'd0,
        pbas_Raute_min:            4'd0,
        pbas_T_lower:              8'd0,
        pbas_T_upper:              8'd0,
        pbas_T_init:               8'd0,
        pbas_R_incdec_q8:          8'd0,
        pbas_T_inc_q8:             16'd0,
        pbas_T_dec_q8:             16'd0,
        pbas_alpha:                8'd0,
        pbas_beta:                 8'd0,
        pbas_mean_mag_min:         8'd0,
        pbas_bg_init_lookahead:    1'd0,
        pbas_prng_seed:            32'd0,
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
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
        bbox_color:                24'h00_FF_00,
        bg_model:                  0,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_bg_init_external:     1'b1,
        pbas_N:                    8'd0,
        pbas_R_lower:              8'd0,
        pbas_R_scale:              4'd0,
        pbas_Raute_min:            4'd0,
        pbas_T_lower:              8'd0,
        pbas_T_upper:              8'd0,
        pbas_T_init:               8'd0,
        pbas_R_incdec_q8:          8'd0,
        pbas_T_inc_q8:             16'd0,
        pbas_T_dec_q8:             16'd0,
        pbas_alpha:                8'd0,
        pbas_beta:                 8'd0,
        pbas_mean_mag_min:         8'd0,
        pbas_bg_init_lookahead:    1'd0,
        pbas_prng_seed:            32'd0,
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
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
        bbox_color:                24'h00_FF_00,
        bg_model:                  0,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_bg_init_external:     1'b1,
        pbas_N:                    8'd0,
        pbas_R_lower:              8'd0,
        pbas_R_scale:              4'd0,
        pbas_Raute_min:            4'd0,
        pbas_T_lower:              8'd0,
        pbas_T_upper:              8'd0,
        pbas_T_init:               8'd0,
        pbas_R_incdec_q8:          8'd0,
        pbas_T_inc_q8:             16'd0,
        pbas_T_dec_q8:             16'd0,
        pbas_alpha:                8'd0,
        pbas_beta:                 8'd0,
        pbas_mean_mag_min:         8'd0,
        pbas_bg_init_lookahead:    1'd0,
        pbas_prng_seed:            32'd0,
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
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
        bbox_color:                24'h00_FF_00,
        bg_model:                  0,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_bg_init_external:     1'b1,
        pbas_N:                    8'd0,
        pbas_R_lower:              8'd0,
        pbas_R_scale:              4'd0,
        pbas_Raute_min:            4'd0,
        pbas_T_lower:              8'd0,
        pbas_T_upper:              8'd0,
        pbas_T_init:               8'd0,
        pbas_R_incdec_q8:          8'd0,
        pbas_T_inc_q8:             16'd0,
        pbas_T_dec_q8:             16'd0,
        pbas_alpha:                8'd0,
        pbas_beta:                 8'd0,
        pbas_mean_mag_min:         8'd0,
        pbas_bg_init_lookahead:    1'd0,
        pbas_prng_seed:            32'd0,
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
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
        bbox_color:                24'h00_FF_00,
        bg_model:                  0,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_bg_init_external:     1'b1,
        pbas_N:                    8'd0,
        pbas_R_lower:              8'd0,
        pbas_R_scale:              4'd0,
        pbas_Raute_min:            4'd0,
        pbas_T_lower:              8'd0,
        pbas_T_upper:              8'd0,
        pbas_T_init:               8'd0,
        pbas_R_incdec_q8:          8'd0,
        pbas_T_inc_q8:             16'd0,
        pbas_T_dec_q8:             16'd0,
        pbas_alpha:                8'd0,
        pbas_beta:                 8'd0,
        pbas_mean_mag_min:         8'd0,
        pbas_bg_init_lookahead:    1'd0,
        pbas_prng_seed:            32'd0,
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
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
        bbox_color:                24'h00_FF_00,
        bg_model:                  0,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_bg_init_external:     1'b1,
        pbas_N:                    8'd0,
        pbas_R_lower:              8'd0,
        pbas_R_scale:              4'd0,
        pbas_Raute_min:            4'd0,
        pbas_T_lower:              8'd0,
        pbas_T_upper:              8'd0,
        pbas_T_init:               8'd0,
        pbas_R_incdec_q8:          8'd0,
        pbas_T_inc_q8:             16'd0,
        pbas_T_dec_q8:             16'd0,
        pbas_alpha:                8'd0,
        pbas_beta:                 8'd0,
        pbas_mean_mag_min:         8'd0,
        pbas_bg_init_lookahead:    1'd0,
        pbas_prng_seed:            32'd0,
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
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
        bbox_color:                24'h00_FF_00,
        bg_model:                  0,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_bg_init_external:     1'b1,
        pbas_N:                    8'd0,
        pbas_R_lower:              8'd0,
        pbas_R_scale:              4'd0,
        pbas_Raute_min:            4'd0,
        pbas_T_lower:              8'd0,
        pbas_T_upper:              8'd0,
        pbas_T_init:               8'd0,
        pbas_R_incdec_q8:          8'd0,
        pbas_T_inc_q8:             16'd0,
        pbas_T_dec_q8:             16'd0,
        pbas_alpha:                8'd0,
        pbas_beta:                 8'd0,
        pbas_mean_mag_min:         8'd0,
        pbas_bg_init_lookahead:    1'd0,
        pbas_prng_seed:            32'd0,
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // ===== ViBe profiles (Phase 1 — Python-only; RTL still EMA) =====
    // Same DEFAULT cleanup pipeline (gauss + morph_open + morph_close);
    // bg block is ViBe (8-sample bank, R=20) with look-ahead median init.
    // No RTL consumer yet; suppress UNUSEDPARAM for the whole section via .vlt waiver.
    localparam cfg_t CFG_DEFAULT_VIBE = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_bg_init_external:    1'b1,
        pbas_N:                   8'd0,
        pbas_R_lower:             8'd0,
        pbas_R_scale:             4'd0,
        pbas_Raute_min:           4'd0,
        pbas_T_lower:             8'd0,
        pbas_T_upper:             8'd0,
        pbas_T_init:              8'd0,
        pbas_R_incdec_q8:         8'd0,
        pbas_T_inc_q8:            16'd0,
        pbas_T_dec_q8:            16'd0,
        pbas_alpha:               8'd0,
        pbas_beta:                8'd0,
        pbas_mean_mag_min:        8'd0,
        pbas_bg_init_lookahead:   1'd0,
        pbas_prng_seed:           32'd0,
        pbas_R_upper:             8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // ViBe at K=20 (literature-default sample diversity; ~2.5x the on-chip
    // RAM cost of K=8). Stress-tests the upper end of the memory budget
    // discussion in §10.1 of the design doc.
    localparam cfg_t CFG_VIBE_K20 = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   20,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_bg_init_external:    1'b1,
        pbas_N:                   8'd0,
        pbas_R_lower:             8'd0,
        pbas_R_scale:             4'd0,
        pbas_Raute_min:           4'd0,
        pbas_T_lower:             8'd0,
        pbas_T_upper:             8'd0,
        pbas_T_init:              8'd0,
        pbas_R_incdec_q8:         8'd0,
        pbas_T_inc_q8:            16'd0,
        pbas_T_dec_q8:            16'd0,
        pbas_alpha:               8'd0,
        pbas_beta:                8'd0,
        pbas_mean_mag_min:        8'd0,
        pbas_bg_init_lookahead:   1'd0,
        pbas_prng_seed:           32'd0,
        pbas_R_upper:             8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // ViBe with diffusion disabled — negative-control ablation. Validates
    // that diffusion is the mechanism behind frame-0 ghost dissolution
    // (see design doc §8 step 4). Mask should retain the ghost.
    localparam cfg_t CFG_VIBE_NO_DIFFUSE = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         0,
        vibe_bg_init_external:    1'b1,
        pbas_N:                   8'd0,
        pbas_R_lower:             8'd0,
        pbas_R_scale:             4'd0,
        pbas_Raute_min:           4'd0,
        pbas_T_lower:             8'd0,
        pbas_T_upper:             8'd0,
        pbas_T_init:              8'd0,
        pbas_R_incdec_q8:         8'd0,
        pbas_T_inc_q8:            16'd0,
        pbas_T_dec_q8:            16'd0,
        pbas_alpha:               8'd0,
        pbas_beta:                8'd0,
        pbas_mean_mag_min:        8'd0,
        pbas_bg_init_lookahead:   1'd0,
        pbas_prng_seed:           32'd0,
        pbas_R_upper:             8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // ViBe with the 3x3 Gaussian pre-filter bypassed — same role as
    // CFG_NO_GAUSS but for the ViBe pipeline. Useful for isolating the
    // pre-filter's contribution to mask quality under ViBe.
    localparam cfg_t CFG_VIBE_NO_GAUSS = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b0,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_bg_init_external:    1'b1,
        pbas_N:                   8'd0,
        pbas_R_lower:             8'd0,
        pbas_R_scale:             4'd0,
        pbas_Raute_min:           4'd0,
        pbas_T_lower:             8'd0,
        pbas_T_upper:             8'd0,
        pbas_T_init:              8'd0,
        pbas_R_incdec_q8:         8'd0,
        pbas_T_inc_q8:            16'd0,
        pbas_T_dec_q8:            16'd0,
        pbas_alpha:               8'd0,
        pbas_beta:                8'd0,
        pbas_mean_mag_min:        8'd0,
        pbas_bg_init_lookahead:   1'd0,
        pbas_prng_seed:           32'd0,
        pbas_R_upper:             8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // ViBe with the legacy frame-0 init (no look-ahead median). Required
    // for A/B comparison against CFG_DEFAULT_VIBE so the look-ahead-init
    // contribution stays measurable after the new mode becomes default.
    localparam cfg_t CFG_VIBE_INIT_FRAME0 = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_bg_init_external:    1'b0,
        pbas_N:                   8'd0,
        pbas_R_lower:             8'd0,
        pbas_R_scale:             4'd0,
        pbas_Raute_min:           4'd0,
        pbas_T_lower:             8'd0,
        pbas_T_upper:             8'd0,
        pbas_T_init:              8'd0,
        pbas_R_incdec_q8:         8'd0,
        pbas_T_inc_q8:            16'd0,
        pbas_T_dec_q8:            16'd0,
        pbas_alpha:               8'd0,
        pbas_beta:                8'd0,
        pbas_mean_mag_min:        8'd0,
        pbas_bg_init_lookahead:   1'd0,
        pbas_prng_seed:           32'd0,
        pbas_R_upper:             8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // ViBe with external (lookahead-median) ROM init. Named alias for
    // CFG_DEFAULT_VIBE that explicitly targets the $readmemh path.
    // Byte-identical to CFG_DEFAULT_VIBE at the SV level; the distinction
    // (vibe_bg_init_lookahead_n sentinel) lives in the Python profile only
    // and drives ROM-gen behaviour, not a cfg_t field.
    localparam cfg_t CFG_VIBE_INIT_EXTERNAL = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_bg_init_external:    1'b1,
        pbas_N:                   8'd0,
        pbas_R_lower:             8'd0,
        pbas_R_scale:             4'd0,
        pbas_Raute_min:           4'd0,
        pbas_T_lower:             8'd0,
        pbas_T_upper:             8'd0,
        pbas_T_init:              8'd0,
        pbas_R_incdec_q8:         8'd0,
        pbas_T_inc_q8:            16'd0,
        pbas_T_dec_q8:            16'd0,
        pbas_alpha:               8'd0,
        pbas_beta:                8'd0,
        pbas_mean_mag_min:        8'd0,
        pbas_bg_init_lookahead:   1'd0,
        pbas_prng_seed:           32'd0,
        pbas_R_upper:             8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // ViBe + persistence-based FG demotion (Phase 1 candidate). Inherits
    // every CFG_DEFAULT_VIBE field except: frame-0 hard-init (no lookahead),
    // demote enabled with K_persist=30, kernel=3, consistency_thresh=3
    // (thresh=3 promoted from the original 1 after the Phase-1 hollowing
    // analysis — see docs/plans/2026-05-12-vibe-demote-python-results.md).
    localparam cfg_t CFG_VIBE_DEMOTE = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 1,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_bg_init_external:    1'b0,
        pbas_N:                   8'd0,
        pbas_R_lower:             8'd0,
        pbas_R_scale:             4'd0,
        pbas_Raute_min:           4'd0,
        pbas_T_lower:             8'd0,
        pbas_T_upper:             8'd0,
        pbas_T_init:              8'd0,
        pbas_R_incdec_q8:         8'd0,
        pbas_T_inc_q8:            16'd0,
        pbas_T_dec_q8:            16'd0,
        pbas_alpha:               8'd0,
        pbas_beta:                8'd0,
        pbas_mean_mag_min:        8'd0,
        pbas_bg_init_lookahead:   1'd0,
        pbas_prng_seed:           32'd0,
        pbas_R_upper:             8'd0,
        vibe_demote_en:                 1'b1,
        vibe_demote_K_persist:          8'd30,
        vibe_demote_kernel:             4'd3,
        vibe_demote_consistency_thresh: 4'd3
    };

    // Demo-tuned vibe_demote: CFG_DEMO's visual tunings (scaler off, gamma
    // off, EMA alpha overrides) overlaid on vibe_demote's bg model + demote
    // mechanism. Used for `make demo DEMO_CFG=demo_vibe_demote` README WebPs.
    localparam cfg_t CFG_DEMO_VIBE_DEMOTE = '{
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
        bbox_color:                24'h00_FF_00,
        bg_model:                  1,
        vibe_K:                    8,
        vibe_R:                    20,
        vibe_min_match:            2,
        vibe_phi_update:           16,
        vibe_phi_diffuse:          16,
        vibe_bg_init_external:     1'b0,
        pbas_N:                    8'd0,
        pbas_R_lower:              8'd0,
        pbas_R_scale:              4'd0,
        pbas_Raute_min:            4'd0,
        pbas_T_lower:              8'd0,
        pbas_T_upper:              8'd0,
        pbas_T_init:               8'd0,
        pbas_R_incdec_q8:          8'd0,
        pbas_T_inc_q8:             16'd0,
        pbas_T_dec_q8:             16'd0,
        pbas_alpha:                8'd0,
        pbas_beta:                 8'd0,
        pbas_mean_mag_min:         8'd0,
        pbas_bg_init_lookahead:    1'd0,
        pbas_prng_seed:            32'd0,
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b1,
        vibe_demote_K_persist:          8'd30,
        vibe_demote_kernel:             4'd3,
        vibe_demote_consistency_thresh: 4'd3
    };

    // ===== PBAS profiles (Python-only; RTL shadow fields only) =====
    // Hofmann et al. 2012 — Y + gradient features. Defaults verified
    // against the andrewssobral PBAS.cpp reference implementation.

    localparam cfg_t CFG_PBAS_DEFAULT = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 2,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_bg_init_external:    1'b1,
        pbas_N:                   8'd20,
        pbas_R_lower:             8'd18,
        pbas_R_scale:             4'd5,
        pbas_Raute_min:           4'd2,
        pbas_T_lower:             8'd2,
        pbas_T_upper:             8'd200,
        pbas_T_init:              8'd18,
        pbas_R_incdec_q8:         8'd13,
        pbas_T_inc_q8:            16'd256,
        pbas_T_dec_q8:            16'd13,
        pbas_alpha:               8'd7,
        pbas_beta:                8'd1,
        pbas_mean_mag_min:        8'd20,
        pbas_bg_init_lookahead:   1'd0,
        pbas_prng_seed:           32'hDEADBEEF,
        pbas_R_upper:             8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // PBAS + lookahead-median init (replaces the paper's frame-by-frame init).
    localparam cfg_t CFG_PBAS_LOOKAHEAD = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 2,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_bg_init_external:    1'b1,
        pbas_N:                   8'd20,
        pbas_R_lower:             8'd18,
        pbas_R_scale:             4'd5,
        pbas_Raute_min:           4'd2,
        pbas_T_lower:             8'd2,
        pbas_T_upper:             8'd200,
        pbas_T_init:              8'd18,
        pbas_R_incdec_q8:         8'd13,
        pbas_T_inc_q8:            16'd256,
        pbas_T_dec_q8:            16'd13,
        pbas_alpha:               8'd7,
        pbas_beta:                8'd1,
        pbas_mean_mag_min:        8'd20,
        pbas_bg_init_lookahead:   1'd1,
        pbas_prng_seed:           32'hDEADBEEF,
        pbas_R_upper:             8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // PBAS ablation: Raute_min raised from 2 to 4.
    // Follow-up literature (post-Hofmann 2012) commonly uses 3-5 for Raute_min.
    // Higher value → fewer false-bg classifications → tighter motion mask.
    localparam cfg_t CFG_PBAS_DEFAULT_RAUTE4 = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 2,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_bg_init_external:    1'b1,
        pbas_N:                   8'd20,
        pbas_R_lower:             8'd18,
        pbas_R_scale:             4'd5,
        pbas_Raute_min:           4'd4,
        pbas_T_lower:             8'd2,
        pbas_T_upper:             8'd200,
        pbas_T_init:              8'd18,
        pbas_R_incdec_q8:         8'd13,
        pbas_T_inc_q8:            16'd256,
        pbas_T_dec_q8:            16'd13,
        pbas_alpha:               8'd7,
        pbas_beta:                8'd1,
        pbas_mean_mag_min:        8'd20,
        pbas_bg_init_lookahead:   1'd0,
        pbas_prng_seed:           32'hDEADBEEF,
        pbas_R_upper:             8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // PBAS ablation: Raute_min=4 AND R_upper cap at 80.
    // R_upper is an engineering knob (NOT a published PBAS parameter).
    // Caps R(x) from above at 80, preventing excessive match-radius growth
    // in high-d_min (ghost) regions where R would otherwise drift unbounded.
    localparam cfg_t CFG_PBAS_DEFAULT_RAUTE4_RCAP = '{
        motion_thresh:            8'd16,
        alpha_shift:              3,
        alpha_shift_slow:         6,
        grace_frames:             0,
        grace_alpha_shift:        1,
        gauss_en:                 1'b1,
        morph_open_en:            1'b1,
        morph_close_en:           1'b1,
        morph_close_kernel:       3,
        hflip_en:                 1'b0,
        gamma_en:                 1'b1,
        scaler_en:                1'b1,
        hud_en:                   1'b1,
        bbox_color:               24'h00_FF_00,
        bg_model:                 2,
        vibe_K:                   8,
        vibe_R:                   20,
        vibe_min_match:           2,
        vibe_phi_update:          16,
        vibe_phi_diffuse:         16,
        vibe_bg_init_external:    1'b1,
        pbas_N:                   8'd20,
        pbas_R_lower:             8'd18,
        pbas_R_scale:             4'd5,
        pbas_Raute_min:           4'd4,
        pbas_T_lower:             8'd2,
        pbas_T_upper:             8'd200,
        pbas_T_init:              8'd18,
        pbas_R_incdec_q8:         8'd13,
        pbas_T_inc_q8:            16'd256,
        pbas_T_dec_q8:            16'd13,
        pbas_alpha:               8'd7,
        pbas_beta:                8'd1,
        pbas_mean_mag_min:        8'd20,
        pbas_bg_init_lookahead:   1'd0,
        pbas_prng_seed:           32'hDEADBEEF,
        pbas_R_upper:             8'd80,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
    };

    // ---------------------------------------------------------------
    // CCL (Block 4) parameters — defaults; override at instantiation.
    // ---------------------------------------------------------------
    localparam int CCL_N_LABELS_INT        = 64;
    localparam int CCL_N_OUT               = 32;
    localparam int CCL_MIN_COMPONENT_PIXELS = 16;
    localparam int CCL_MAX_CHAIN_DEPTH     = 8;
    // Suppress the first N frames' bboxes so the EMA background has time to
    // converge; during priming the front buffer stays all-invalid. Matches
    // py/models/motion.py PRIME_FRAMES. Default 0 now that synthetic sources
    // render frame 0 as bg-only (no frame-0 foreground-baked-into-bg ghost).
    localparam int CCL_PRIME_FRAMES        = 0;

endpackage
