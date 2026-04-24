// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_window3x3 -- reusable 3x3 sliding-window primitive.
//
// Owns: row/col counters with phantom-cycle drain, two line buffers
// (depth H_ACTIVE, width DATA_WIDTH), 3-row x 3-col window shift registers,
// and edge handling at all four borders. Emits a combinational 9-tap
// window at the d1 stage + window_valid_o (off-frame-suppressed) + busy_o.
//
// Consumers (axis_gauss3x3, axis_sobel, axis_morph_erode / _dilate, ...)
// add their own combinational op on the window and a single output register.
//
// EDGE_POLICY parameter selects how off-frame neighbours are filled when
// the window overlaps a frame border. Currently only EDGE_REPLICATE is
// implemented; other values trigger an elaboration-time $fatal so new
// policies (ZERO, CONSTANT, MIRROR) can be slotted in without breaking
// callers.
//
// Latency: H_ACTIVE + 2 cycles from first valid_i to first window_valid_o
// (one less than gauss3x3 end-to-end because the op register now lives in
// the wrapper). Throughput: 1 pixel/cycle after fill.
//
// Blanking requirements:
//   - Min H-blank: 1 cycle per row (absorbs the per-row phantom column).
//   - Min V-blank: H_ACTIVE + 1 cycles total (absorbs phantom-row drain).
//   - If blanking is unavailable, busy_o asserts so the parent can deassert
//     upstream tready.

// Edge-policy codes. SV has no cross-file enums without a package, so
// callers pass the integer value directly:
//   axis_window3x3 #(.EDGE_POLICY(0 /*EDGE_REPLICATE*/)) ...
// Reserve 1..3 for ZERO / CONSTANT / MIRROR additions.

module axis_window3x3 #(
    parameter int DATA_WIDTH  = 8,
    parameter int H_ACTIVE    = 320,
    parameter int V_ACTIVE    = 240,
    parameter int EDGE_POLICY = 0   // 0 = REPLICATE (only value implemented today)
) (
    input  logic                  clk_i,
    input  logic                  rst_n_i,

    input  logic                  valid_i,
    input  logic                  sof_i,
    input  logic                  stall_i,

    input  logic [DATA_WIDTH-1:0] din_i,

    // 3x3 window, row-major:  [0]=TL [1]=TC [2]=TR
    //                         [3]=ML [4]=CC [5]=MR
    //                         [6]=BL [7]=BC [8]=BR
    output logic [DATA_WIDTH-1:0] window_o [9],
    output logic                  window_valid_o,
    output logic                  busy_o
);

    // ---- Edge policy guard ----
    // Only EDGE_REPLICATE is implemented today. Anything else is a
    // caller bug we want to fail loud on at elaboration.
    localparam int EDGE_REPLICATE = 0;

    initial begin
        if (EDGE_POLICY != EDGE_REPLICATE) begin
            $fatal(1, "axis_window3x3: unsupported EDGE_POLICY=%0d (only EDGE_REPLICATE=0 implemented)", EDGE_POLICY);
        end
    end

    // ---- Row / column counters ----
    localparam int COL_W = $clog2(H_ACTIVE + 1);
    localparam int ROW_W = $clog2(V_ACTIVE + 1);

    logic [COL_W-1:0] col;
    logic [ROW_W-1:0] row;

    logic [COL_W-1:0] cur_col;
    logic [ROW_W-1:0] cur_row;

    always_comb begin
        if (sof_i) begin
            cur_col = '0;
            cur_row = '0;
        end else if (col == (COL_W)'(H_ACTIVE)) begin
            cur_col = '0;
            cur_row = (row == (ROW_W)'(V_ACTIVE)) ? '0 : row + 1;
        end else begin
            cur_col = col + 1;
            cur_row = row;
        end
    end

    logic at_phantom_col;
    logic at_phantom_row;
    logic at_phantom;
    logic real_pixel;
    logic phantom;
    logic advance;

    assign at_phantom_col = (cur_col == (COL_W)'(H_ACTIVE));
    assign at_phantom_row = (cur_row == (ROW_W)'(V_ACTIVE));
    assign at_phantom     = at_phantom_col || at_phantom_row;
    assign real_pixel     = valid_i && !stall_i && !at_phantom;
    assign phantom        = !stall_i && at_phantom;
    assign advance        = real_pixel || phantom;

    assign busy_o = valid_i && at_phantom;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col <= '0;
            row <= '0;
        end else if (!stall_i) begin
            if (sof_i && valid_i) begin
                col <= '0;
                row <= '0;
            end else if (advance) begin
                col <= cur_col;
                row <= cur_row;
            end
        end
    end

    // ---- Line buffers ----
    logic [DATA_WIDTH-1:0] lb_top_mem [H_ACTIVE];
    logic [DATA_WIDTH-1:0] lb_mid_mem [H_ACTIVE];

    logic [DATA_WIDTH-1:0] lb_top_rd, lb_mid_rd;

    logic lb_active_col;
    assign lb_active_col = (cur_col != (COL_W)'(H_ACTIVE));

    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            if (advance && lb_active_col) begin
                lb_top_rd <= lb_top_mem[cur_col];
                lb_mid_rd <= lb_mid_mem[cur_col];
            end
            if (real_pixel) begin
                lb_top_mem[cur_col] <= lb_mid_mem[cur_col];
                lb_mid_mem[cur_col] <= din_i;
            end
        end
    end

    // ---- d1 stage ----
    logic [DATA_WIDTH-1:0] y_d1;
    logic [COL_W-1:0]      col_d1;
    logic [ROW_W-1:0]      row_d1;
    logic                  valid_d1;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            valid_d1 <= 1'b0;
        end else if (!stall_i) begin
            if (real_pixel) begin
                y_d1 <= din_i;
            end
            col_d1   <= cur_col;
            row_d1   <= cur_row;
            valid_d1 <= advance;
        end
    end

    // ---- Column shift registers ----
    logic [DATA_WIDTH-1:0] r2_c0, r2_c1, r2_c2;
    logic [DATA_WIDTH-1:0] r1_c0, r1_c1, r1_c2;
    logic [DATA_WIDTH-1:0] r0_c0, r0_c1, r0_c2;

    always_ff @(posedge clk_i) begin
        if (!stall_i && valid_d1) begin
            r2_c1 <= lb_top_rd; r2_c2 <= r2_c1;
            r1_c1 <= lb_mid_rd; r1_c2 <= r1_c1;
            r0_c1 <= y_d1;      r0_c2 <= r0_c1;
        end
    end

    assign r2_c0 = lb_top_rd;
    assign r1_c0 = lb_mid_rd;
    assign r0_c0 = y_d1;

    // ---- Edge replication mux ----
    logic [DATA_WIDTH-1:0] win [3][3];

    always_comb begin
        win[0][0] = r2_c2; win[0][1] = r2_c1; win[0][2] = r2_c0;
        win[1][0] = r1_c2; win[1][1] = r1_c1; win[1][2] = r1_c0;
        win[2][0] = r0_c2; win[2][1] = r0_c1; win[2][2] = r0_c0;

        if (row_d1 == (ROW_W)'(1)) begin
            win[0][0] = r1_c2; win[0][1] = r1_c1; win[0][2] = r1_c0;
        end

        if (row_d1 == (ROW_W)'(V_ACTIVE)) begin
            win[2][0] = win[1][0];
            win[2][1] = win[1][1];
            win[2][2] = win[1][2];
        end

        if (col_d1 == (COL_W)'(1)) begin
            win[0][0] = win[0][1];
            win[1][0] = win[1][1];
            win[2][0] = win[2][1];
        end
    end

    // ---- Output: flat 9-tap window + off-frame-suppressed valid ----
    // Output pixel coord is (row_d1 - 1, col_d1 - 1). Positions with
    // row_d1 == 0 or col_d1 == 0 map to (-1, *) or (*, -1) and are
    // suppressed.
    assign window_o[0] = win[0][0];
    assign window_o[1] = win[0][1];
    assign window_o[2] = win[0][2];
    assign window_o[3] = win[1][0];
    assign window_o[4] = win[1][1];
    assign window_o[5] = win[1][2];
    assign window_o[6] = win[2][0];
    assign window_o[7] = win[2][1];
    assign window_o[8] = win[2][2];

    assign window_valid_o = valid_d1 && (row_d1 != (ROW_W)'(0)) && (col_d1 != (COL_W)'(0));

endmodule
