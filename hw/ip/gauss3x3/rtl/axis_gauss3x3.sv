// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// 3x3 Gaussian pre-filter on 8-bit luma (Y channel) -- TRUE CENTERED convolution.
//
// Kernel: [1 2 1; 2 4 2; 1 2 1] / 16
// All multiplications are bit-shifts (wiring only): *1 = identity, *2 = <<1, *4 = <<2.
//
// Architecture:
//   - Two line buffers (simple dual-port, depth = H_ACTIVE, width = 8) hold
//     rows P_r - 1 (LB0) and P_r (LB1) relative to the output pixel P_r. The
//     live input feeds row P_r + 1.
//   - Column shift registers (2 FFs per row, 6 FFs total) provide c-1, c, c+1 taps.
//   - Edge handling: border pixel replication at all 4 borders.
//   - Internal scan extends to [0..V_ACTIVE] x [0..H_ACTIVE]. The extra phantom
//     row (row == V_ACTIVE) and phantom column (col == H_ACTIVE) are used to
//     produce the centered outputs for the last real row and last real column.
//     Phantom cycles self-clock during upstream blanking; if no blanking is
//     available, busy_o asserts to deassert upstream tready.
//
// Spatial semantics: for scan position (row_d1, col_d1) at the shift-register
// stage, the convolution emits centered output for pixel (row_d1 - 1, col_d1 - 1).
// valid_o is suppressed when row_d2 == 0 or col_d2 == 0 -- those scan positions
// correspond to off-frame output coordinates.
//
// References (mainstream streaming 2D-convolution conventions):
//   - MathWorks Vision HDL Toolbox: floor(K_h/2) = 1 line of latency, edge
//     padding with blanking-based drain. Min H-blank = 2*K_w = 6 cycles,
//     min V-blank = K_h = 3 lines.
//   - Xilinx Vitis Vision Filter2D / Window2D: centered SOP with line buffer
//     depth K_v - 1 and a K_v x K_w window buffer.
//
// Latency: H_ACTIVE + 3 cycles from first valid_i to first valid_o. Throughput
// is 1 pixel/cycle after fill. Steady-state phantom drain is 1 cycle per row
// (absorbed in H_BLANK >= 6) plus H_ACTIVE + 1 cycles per frame (absorbed in
// V_BLANK >= 3 lines).
//
// This is a synchronous pipeline element, not a full AXIS stage. The parent
// module (axis_motion_detect) controls handshake via valid_i / stall_i and
// deasserts s_axis_tready_o when busy_o is asserted.

module axis_gauss3x3 #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240
) (
    input  logic       clk_i,
    input  logic       rst_n_i,

    // Control (from axis_motion_detect pipeline logic)
    input  logic       valid_i,     // pixel is valid (tvalid && tready upstream)
    input  logic       sof_i,       // start-of-frame (resets row/col counters)
    input  logic       stall_i,     // pipeline stall -- freeze all state

    // Data
    input  logic [7:0] y_i,         // raw Y from rgb2ycrcb
    output logic [7:0] y_o,         // smoothed Y
    output logic       valid_o,     // output valid
    output logic       busy_o       // asserted when a phantom cycle is needed
                                    // but upstream is presenting valid_i=1;
                                    // parent should deassert s_axis_tready_o
);

    // ---- Row / column counters ----
    // Widened so the counters can represent H_ACTIVE / V_ACTIVE (the phantom
    // positions just past the active region).
    localparam int COL_W = $clog2(H_ACTIVE + 1);
    localparam int ROW_W = $clog2(V_ACTIVE + 1);

    logic [COL_W-1:0] col;
    logic [ROW_W-1:0] row;

    // Combinational current-pixel scan position (this cycle's scan coord).
    // col/row hold the PREVIOUSLY-processed scan position; cur_col/cur_row
    // compute the position being processed now. at_phantom and advance must
    // be evaluated against cur_* -- otherwise the phantom condition lags by
    // one cycle, causing the phantom-col beat to be treated as a real pixel
    // and LB writes to fire at out-of-range addresses.
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

    // Advance decomposition -- see header for semantics.
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

    // busy_o: scan is at a phantom position but upstream is presenting data.
    // Parent must stall upstream so we can self-clock the phantom cycle(s).
    assign busy_o = valid_i && at_phantom;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col <= '0;
            row <= '0;
        end else if (!stall_i) begin
            if (sof_i && valid_i) begin
                // SOF accepts the new frame's first pixel at (0, 0); any
                // in-flight phantom cycles from the previous frame are cancelled.
                col <= '0;
                row <= '0;
            end else if (advance) begin
                col <= cur_col;
                row <= cur_row;
            end
        end
    end

    // ---- Line buffers (simple dual-port BRAM) ----
    // LB0 holds row r-2, LB1 holds row r-1 where r is the current scan row.
    // Reads: on any advance where cur_col is in-range (skip phantom-col).
    // Writes: on real_pixel only (no live y_i on phantom row or phantom col).

    logic [7:0] lb0_mem [H_ACTIVE];
    logic [7:0] lb1_mem [H_ACTIVE];

    logic [7:0] lb0_rd, lb1_rd;

    // cur_col can equal H_ACTIVE on a phantom-col cycle; gate the read to avoid
    // out-of-range addressing. Holding lb0_rd / lb1_rd naturally replicates the
    // right edge (rightmost shift-register slot mirrors the middle one).
    logic lb_active_col;
    assign lb_active_col = (cur_col != (COL_W)'(H_ACTIVE));

    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            if (advance && lb_active_col) begin
                lb0_rd <= lb0_mem[cur_col];
                lb1_rd <= lb1_mem[cur_col];
            end
            if (real_pixel) begin
                lb0_mem[cur_col] <= lb1_mem[cur_col];
                lb1_mem[cur_col] <= y_i;
            end
        end
    end

    // ---- Pipeline stage d1 (after registered LB read) ----
    // y_d1 is captured only on real_pixel -- on phantom cycles it holds the last
    // real value. Combined with the window edge mux, this gives correct edge
    // replication for the right and bottom borders.
    logic [7:0]       y_d1;
    logic [COL_W-1:0] col_d1;
    logic [ROW_W-1:0] row_d1;
    logic             valid_d1;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            valid_d1 <= 1'b0;
        end else if (!stall_i) begin
            if (real_pixel) begin
                y_d1 <= y_i;
            end
            col_d1   <= cur_col;
            row_d1   <= cur_row;
            valid_d1 <= advance;
        end
    end

    // ---- Column shift registers (2 FFs per row) ----
    // Shift register is at the d1 stage. It advances on any valid_d1 (real or
    // phantom). The shift-register data is deliberately NOT reset -- the valid
    // sideband masks stale values, and avoiding the data reset enables SRL
    // inference by synthesis tools (though at 2 deep it's FF-mapped anyway).

    logic [7:0] r2_c0, r2_c1, r2_c2;  // top row: c+1, c, c-1
    logic [7:0] r1_c0, r1_c1, r1_c2;  // middle row
    logic [7:0] r0_c0, r0_c1, r0_c2;  // bottom row (live)

    always_ff @(posedge clk_i) begin
        if (!stall_i && valid_d1) begin
            r2_c2 <= r2_c1; r2_c1 <= lb0_rd;
            r1_c2 <= r1_c1; r1_c1 <= lb1_rd;
            r0_c2 <= r0_c1; r0_c1 <= y_d1;
        end
    end

    assign r2_c0 = lb0_rd;
    assign r1_c0 = lb1_rd;
    assign r0_c0 = y_d1;

    // ---- Edge replication muxing ----
    // Output at scan position (row_d1, col_d1) corresponds to pixel
    // (row_d1 - 1, col_d1 - 1). We need replication for:
    //   - row_d1 == 1          (first real row: top of window is off-frame)
    //   - row_d1 == V_ACTIVE   (phantom row, last real output row: bottom is off-frame)
    //   - col_d1 == 1          (first real col: left of window is off-frame;
    //                           also masks row-transition contamination in r*_c2)
    // col_d1 == H_ACTIVE (phantom col) needs NO mux: lb0_rd/lb1_rd/y_d1 are
    // held from the previous cycle, so r*_c0 already equals r*_c1 (middle).

    logic [7:0] win [3][3];  // win[row][col], [0][0]=top-left

    always_comb begin
        // Default: interior pixel
        win[0][0] = r2_c2; win[0][1] = r2_c1; win[0][2] = r2_c0;
        win[1][0] = r1_c2; win[1][1] = r1_c1; win[1][2] = r1_c0;
        win[2][0] = r0_c2; win[2][1] = r0_c1; win[2][2] = r0_c0;

        // Top edge: row_d1 == 1 -> output row 0 -> replicate middle to top.
        if (row_d1 == (ROW_W)'(1)) begin
            win[0][0] = r1_c2; win[0][1] = r1_c1; win[0][2] = r1_c0;
        end

        // Bottom edge: row_d1 == V_ACTIVE (phantom row) -> output row V-1.
        // Replicate middle row to bottom (bottom is junk from held y_d1).
        if (row_d1 == (ROW_W)'(V_ACTIVE)) begin
            win[2][0] = win[1][0];
            win[2][1] = win[1][1];
            win[2][2] = win[1][2];
        end

        // Left edge: col_d1 == 1 -> output col 0 -> replicate middle-col to left.
        // This also overrides row-transition contamination in the r*_c2 slot.
        if (col_d1 == (COL_W)'(1)) begin
            win[0][0] = win[0][1];
            win[1][0] = win[1][1];
            win[2][0] = win[2][1];
        end
    end

    // ---- Convolution (combinational adder tree) ----
    // Kernel: [1 2 1; 2 4 2; 1 2 1], sum of weights = 16
    // Each input is 8 bits, max shifted is 10 bits (<<2), sum of 9 terms fits in 12 bits.
    logic [11:0] conv_sum;

    always_comb begin
        conv_sum = {4'b0, win[0][0]}       + {3'b0, win[0][1], 1'b0} + {4'b0, win[0][2]}
                 + {3'b0, win[1][0], 1'b0} + {2'b0, win[1][1], 2'b0} + {3'b0, win[1][2], 1'b0}
                 + {4'b0, win[2][0]}       + {3'b0, win[2][1], 1'b0} + {4'b0, win[2][2]};
    end

    // ---- Output register + off-frame suppression ----
    // valid_o fires only when the output coordinate (row_d2 - 1, col_d2 - 1)
    // is in [0..V_ACTIVE-1] x [0..H_ACTIVE-1]. Scan positions with row_d2 == 0
    // or col_d2 == 0 map to row -1 / col -1, which are not real output pixels.
    logic             valid_d2;
    logic [ROW_W-1:0] row_d2;
    logic [COL_W-1:0] col_d2;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            y_o      <= '0;
            valid_d2 <= 1'b0;
        end else if (!stall_i) begin
            y_o      <= conv_sum[11:4];  // >> 4 (divide by 16)
            valid_d2 <= valid_d1;
            row_d2   <= row_d1;
            col_d2   <= col_d1;
        end
    end

    assign valid_o = valid_d2 && (row_d2 != (ROW_W)'(0)) && (col_d2 != (COL_W)'(0));

endmodule
