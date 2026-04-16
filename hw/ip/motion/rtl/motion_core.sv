// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Motion detection core — pure combinational.
//
// Computes a 1-bit motion mask (abs(y_cur - y_bg) > THRESH) and an
// EMA-updated background value (y_bg + ((y_cur - y_bg) >>> ALPHA_SHIFT)).
// No clock, no state — instantiated by axis_motion_detect.

module motion_core #(
    parameter int THRESH      = 16,
    parameter int ALPHA_SHIFT = 3
) (
    input  logic [7:0] y_cur_i,       // current-frame luma
    input  logic [7:0] y_bg_i,        // background luma from RAM

    output logic       mask_bit_o,    // 1 = motion detected
    output logic [7:0] ema_update_o   // new background value
);

    // ---- Motion comparison ----
    logic [7:0] diff;

    assign diff       = (y_cur_i > y_bg_i) ? (y_cur_i - y_bg_i)
                                            : (y_bg_i - y_cur_i);
    assign mask_bit_o = (diff > THRESH[7:0]);

    // ---- EMA background update ----
    logic signed [8:0] ema_delta;   // y_cur - bg, signed 9-bit
    logic signed [8:0] ema_step;    // delta >>> ALPHA_SHIFT (arithmetic right-shift)

    assign ema_delta    = {1'b0, y_cur_i} - {1'b0, y_bg_i};
    assign ema_step     = ema_delta >>> ALPHA_SHIFT;
    assign ema_update_o = y_bg_i + ema_step[7:0];

endmodule
