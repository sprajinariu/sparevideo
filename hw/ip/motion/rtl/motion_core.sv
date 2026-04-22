// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Motion detection core — pure combinational.
//
// Computes a 1-bit motion mask (abs(y_cur - y_bg) > THRESH) and THREE
// EMA-updated background values (grace / fast / slow rates), so the caller
// can mux between them based on the grace window and mask bit. The mask
// output is gated by `primed_i` so the wrapper does not re-implement the
// frame-0 suppression.
// No clock, no state — instantiated by axis_motion_detect.

module motion_core #(
    parameter int THRESH            = 16,
    parameter int ALPHA_SHIFT       = 3,    // alpha = 1/8  — post-grace non-motion rate
    parameter int ALPHA_SHIFT_SLOW  = 6,    // alpha = 1/64 — post-grace motion rate
    parameter int GRACE_ALPHA_SHIFT = 1     // alpha = 1/2  — grace-window rate (unconditional)
) (
    input  logic [7:0] y_cur_i,            // current-frame luma (post-Gaussian)
    input  logic [7:0] y_bg_i,             // background luma from RAM
    input  logic       primed_i,           // 1 = frame >= 1; 0 = priming frame 0

    output logic       mask_bit_o,         // 1 = motion detected (gated by primed_i)
    output logic       raw_motion_o,       // 1 = motion, NOT gated (for wrapper's bg mux)
    output logic [7:0] ema_update_o,       // bg + (delta >>> ALPHA_SHIFT)       — post-grace non-motion
    output logic [7:0] ema_update_slow_o,  // bg + (delta >>> ALPHA_SHIFT_SLOW)  — post-grace motion
    output logic [7:0] ema_update_grace_o  // bg + (delta >>> GRACE_ALPHA_SHIFT) — grace window (fast)
);

    // ---- Motion comparison (gated by primed_i) ----
    logic [7:0] diff;

    assign diff         = (y_cur_i > y_bg_i) ? (y_cur_i - y_bg_i)
                                              : (y_bg_i - y_cur_i);
    assign raw_motion_o = (diff > THRESH[7:0]);
    assign mask_bit_o   = primed_i && raw_motion_o;

    // ---- EMA background update — shared subtract, three parallel shifts ----
    logic signed [8:0] ema_delta;
    logic signed [8:0] ema_step_fast;
    logic signed [8:0] ema_step_slow;
    logic signed [8:0] ema_step_grace;

    assign ema_delta          = {1'b0, y_cur_i} - {1'b0, y_bg_i};
    assign ema_step_fast      = ema_delta >>> ALPHA_SHIFT;
    assign ema_step_slow      = ema_delta >>> ALPHA_SHIFT_SLOW;
    assign ema_step_grace     = ema_delta >>> GRACE_ALPHA_SHIFT;
    assign ema_update_o       = y_bg_i + ema_step_fast[7:0];
    assign ema_update_slow_o  = y_bg_i + ema_step_slow[7:0];
    assign ema_update_grace_o = y_bg_i + ema_step_grace[7:0];

endmodule
