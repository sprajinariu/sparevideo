// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_kernel3x3 -- reusable 3x3 sliding-window primitive.
//
// Owns: row/col counters with phantom-cycle drain, two line buffers
// (depth H_ACTIVE, width DATA_WIDTH), 3-row x 3-col window shift registers,
// and edge replication at all four borders. Emits a combinational 9-tap
// window at the d1 stage + window_valid_o (off-frame-suppressed) + busy_o.
//
// Consumers (axis_gauss3x3, axis_morph_erode, axis_morph_dilate, ...) add
// their own combinational op on the window and a single output register.
//
// Latency: H_ACTIVE + 2 cycles from first valid_i to first window_valid_o
// (one less than gauss3x3 end-to-end because the op register now lives in
// the wrapper). Throughput: 1 pixel/cycle after fill.
//
// Blanking requirements (inherited from the former gauss3x3 internals):
//   - Min H-blank: 1 cycle per row (absorbs the per-row phantom column).
//   - Min V-blank: H_ACTIVE + 1 cycles total (absorbs phantom-row drain).
//   - If blanking is unavailable, busy_o asserts so the parent can deassert
//     upstream tready.

module axis_kernel3x3 #(
    parameter int DATA_WIDTH = 8,
    parameter int H_ACTIVE   = 320,
    parameter int V_ACTIVE   = 240
) (
    input  logic                  clk_i,
    input  logic                  rst_n_i,

    input  logic                  valid_i,
    input  logic                  sof_i,
    input  logic                  stall_i,

    input  logic [DATA_WIDTH-1:0] din_i,

    // 3x3 window, row-major: [0]=TL [1]=TC [2]=TR
    //                         [3]=ML [4]=CC [5]=MR
    //                         [6]=BL [7]=BC [8]=BR
    output logic [DATA_WIDTH-1:0] window_o [9],
    output logic                  window_valid_o,
    output logic                  busy_o
);

    // Placeholder tie-offs so the module elaborates cleanly.
    // Body is added in Task 4; the kernel TB (Task 3) is expected to FAIL
    // against this skeleton -- window_valid_o never asserts so the first
    // cap_valid check fires $fatal.
    assign window_valid_o = 1'b0;
    assign busy_o         = 1'b0;
    assign window_o[0]    = '0;
    assign window_o[1]    = '0;
    assign window_o[2]    = '0;
    assign window_o[3]    = '0;
    assign window_o[4]    = '0;
    assign window_o[5]    = '0;
    assign window_o[6]    = '0;
    assign window_o[7]    = '0;
    assign window_o[8]    = '0;

endmodule
