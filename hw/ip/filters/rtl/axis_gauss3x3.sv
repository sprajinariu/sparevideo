// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// 3x3 Gaussian pre-filter on 8-bit luma, implemented as a thin wrapper
// over axis_window3x3.
//
// Kernel: [1 2 1; 2 4 2; 1 2 1] / 16
// Multiplications are wire shifts only.
//
// Latency: H_ACTIVE + 3 cycles from first valid_i to first valid_o
// (window: H_ACTIVE + 2; wrapper's output register adds 1). Throughput
// is 1 pixel/cycle after fill. External interface is identical to the
// pre-refactor version.

module axis_gauss3x3 #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240
) (
    input  logic       clk_i,
    input  logic       rst_n_i,

    input  logic       valid_i,
    input  logic       sof_i,
    input  logic       stall_i,

    input  logic [7:0] y_i,
    output logic [7:0] y_o,
    output logic       valid_o,
    output logic       busy_o
);

    logic [7:0] window [9];
    logic       window_valid;

    axis_window3x3 #(
        .DATA_WIDTH  (8),
        .H_ACTIVE    (H_ACTIVE),
        .V_ACTIVE    (V_ACTIVE),
        .EDGE_POLICY (0)  // EDGE_REPLICATE
    ) u_window (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),
        .valid_i        (valid_i),
        .sof_i          (sof_i),
        .stall_i        (stall_i),
        .din_i          (y_i),
        .window_o       (window),
        .window_valid_o (window_valid),
        .busy_o         (busy_o)
    );

    // Kernel: [1 2 1; 2 4 2; 1 2 1], sum = 16. Shifts only.
    // Max term = (255 << 2) = 1020; sum of 9 terms = 4080, fits in 12 bits.
    logic [11:0] conv_sum;

    always_comb begin
        conv_sum = {4'b0, window[0]}       + {3'b0, window[1], 1'b0} + {4'b0, window[2]}
                 + {3'b0, window[3], 1'b0} + {2'b0, window[4], 2'b0} + {3'b0, window[5], 1'b0}
                 + {4'b0, window[6]}       + {3'b0, window[7], 1'b0} + {4'b0, window[8]};
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            y_o     <= '0;
            valid_o <= 1'b0;
        end else if (!stall_i) begin
            y_o     <= conv_sum[11:4];  // >> 4
            valid_o <= window_valid;
        end
    end

endmodule
