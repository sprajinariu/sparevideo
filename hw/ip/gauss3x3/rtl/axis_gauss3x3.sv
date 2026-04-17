// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// 3x3 Gaussian pre-filter on 8-bit luma (Y channel).
//
// Kernel: [1 2 1; 2 4 2; 1 2 1] / 16
// All multiplications are bit-shifts (wiring only): *1 = identity, *2 = <<1, *4 = <<2.
//
// Architecture:
//   - Two line buffers (simple dual-port BRAM, depth = H_ACTIVE, width = 8)
//     hold rows r-2 (oldest) and r-1 (middle). Live input is row r.
//   - Column shift registers (2 FFs per row, 6 FFs total) provide c-2, c-1, c taps.
//   - Edge handling: border pixel replication (clamp at image edges).
//   - Combinational adder tree produces the 12-bit sum; output = sum[11:4].
//
// Spatial offset: this is a causal streaming filter. The 3-tap shift register
// and 2-row line buffer window center the kernel at (row-1, col-1) relative to
// the current scan position (row, col). Edge replication at rows 0-1 and cols
// 0-1 compensates for the top/left border; the bottom/right border is never
// reached because the window center is always one pixel inside.
//
// This is a synchronous pipeline element, not a full AXIS stage. The parent
// module (axis_motion_detect) controls handshake via valid_i / stall_i.
//
// Latency: 2 clock cycles (line buffer read + output register).

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
    output logic       valid_o      // output valid (delayed by fill latency)
);

    // ---- Row / column counters ----
    localparam int COL_W = $clog2(H_ACTIVE);
    localparam int ROW_W = $clog2(V_ACTIVE);

    logic [COL_W-1:0] col;
    logic [ROW_W-1:0] row;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col <= '0;
            row <= '0;
        end else if (!stall_i && valid_i) begin
            if (sof_i) begin
                col <= '0;
                row <= '0;
            end else if (col == (COL_W)'(H_ACTIVE - 1)) begin
                col <= '0;
                if (row == (ROW_W)'(V_ACTIVE - 1))
                    row <= '0;
                else
                    row <= row + 1;
            end else begin
                col <= col + 1;
            end
        end
    end

    // Combinational current-pixel position. The registered counter `col`/`row`
    // reflects the PREVIOUS pixel's position (updated by the same posedge that
    // processes the current pixel). cur_col/cur_row compute the actual position
    // of the pixel being accepted NOW, matching the counter's next-state logic.
    logic [COL_W-1:0] cur_col;
    logic [ROW_W-1:0] cur_row;

    always_comb begin
        if (sof_i) begin
            cur_col = '0;
            cur_row = '0;
        end else if (col == (COL_W)'(H_ACTIVE - 1)) begin
            cur_col = '0;
            cur_row = (row == (ROW_W)'(V_ACTIVE - 1)) ? '0 : row + 1;
        end else begin
            cur_col = col + 1;
            cur_row = row;
        end
    end

    // ---- Line buffers (simple dual-port BRAM) ----
    // LB0 holds row r-2 (oldest), LB1 holds row r-1 (middle).
    // On each valid pixel at column c:
    //   row_r2 = LB0.read(c),  row_r1 = LB1.read(c),  row_r0 = y_i
    //   LB0.write(c, row_r1),  LB1.write(c, row_r0)

    logic [7:0] lb0_mem [H_ACTIVE];
    logic [7:0] lb1_mem [H_ACTIVE];

    logic [7:0] lb0_rd, lb1_rd;

    // Registered read (distributed RAM at 320px width).
    // lb0 cascades from lb1 via direct memory read (lb1_mem[addr]) — NOT via the
    // registered lb1_rd output, which holds the PREVIOUS cycle's column and would
    // create a column-shifted copy.
    always_ff @(posedge clk_i) begin
        if (!stall_i && valid_i) begin
            lb0_rd <= lb0_mem[cur_col];
            lb1_rd <= lb1_mem[cur_col];
            lb0_mem[cur_col] <= lb1_mem[cur_col];
            lb1_mem[cur_col] <= y_i;
        end
    end

    // The line buffer reads are registered (1 cycle latency). We need to track
    // the input pixel alongside, so register y_i and the counter state too.
    logic [7:0]      y_d1;
    logic [COL_W-1:0] col_d1;
    logic [ROW_W-1:0] row_d1;
    logic             valid_d1;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            valid_d1 <= 1'b0;
        end else if (!stall_i) begin
            y_d1     <= y_i;
            col_d1   <= cur_col;
            row_d1   <= cur_row;
            valid_d1 <= valid_i;
        end
    end

    // After the registered line buffer read, we have at d1:
    //   lb0_rd = row r-2 pixel at col_d1
    //   lb1_rd = row r-1 pixel at col_d1
    //   y_d1   = row r   pixel at col_d1

    // On the first frame after reset, lb0/lb1 contain stale data from the previous
    // frame. Edge replication for rows 0-1 hides this; by row 2 the cascade has
    // propagated correct data.

    // ---- Column shift registers (2 FFs per row) ----
    // Each row feeds through a 2-deep shift register for columns c-2, c-1, c.
    // Shift registers are at the d1 stage (after line buffer read).

    logic [7:0] r2_c0, r2_c1, r2_c2;  // top row: c, c-1, c-2
    logic [7:0] r1_c0, r1_c1, r1_c2;  // middle row
    logic [7:0] r0_c0, r0_c1, r0_c2;  // bottom row (live)

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            r2_c1 <= '0; r2_c2 <= '0;
            r1_c1 <= '0; r1_c2 <= '0;
            r0_c1 <= '0; r0_c2 <= '0;
        end else if (!stall_i && valid_d1) begin
            // Shift: c -> c-1 -> c-2
            r2_c2 <= r2_c1; r2_c1 <= lb0_rd;
            r1_c2 <= r1_c1; r1_c1 <= lb1_rd;
            r0_c2 <= r0_c1; r0_c1 <= y_d1;
        end
    end

    // Current column values (c position)
    assign r2_c0 = lb0_rd;
    assign r1_c0 = lb1_rd;
    assign r0_c0 = y_d1;

    // ---- Edge replication muxing ----
    // After shift register stage, we need another registered stage for the output.
    // The window is available at the shift register output (combinational from d1 + FFs).
    // We'll compute the convolution combinationally and register the output.

    logic [7:0] win [3][3];  // win[row][col], [0][0]=top-left

    always_comb begin
        // Default: interior pixel
        win[0][0] = r2_c2; win[0][1] = r2_c1; win[0][2] = r2_c0;
        win[1][0] = r1_c2; win[1][1] = r1_c1; win[1][2] = r1_c0;
        win[2][0] = r0_c2; win[2][1] = r0_c1; win[2][2] = r0_c0;

        // Row edge replication
        if (row_d1 == '0) begin
            // First row: replicate current row upward for all 3 rows
            win[0][0] = r0_c2; win[0][1] = r0_c1; win[0][2] = r0_c0;
            win[1][0] = r0_c2; win[1][1] = r0_c1; win[1][2] = r0_c0;
        end else if (row_d1 == (ROW_W)'(1)) begin
            // Second row: replicate middle row upward for top row
            win[0][0] = r1_c2; win[0][1] = r1_c1; win[0][2] = r1_c0;
        end

        // Column edge replication
        if (col_d1 == '0) begin
            // First column: replicate c value to c-1 and c-2
            win[0][0] = win[0][2]; win[0][1] = win[0][2];
            win[1][0] = win[1][2]; win[1][1] = win[1][2];
            win[2][0] = win[2][2]; win[2][1] = win[2][2];
        end else if (col_d1 == (COL_W)'(1)) begin
            // Second column: replicate c-1 value to c-2
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

    // ---- Output register ----
    // valid_o follows valid_d1 with 1 more cycle delay (total 2 cycles from valid_i).
    logic valid_d2;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            y_o      <= '0;
            valid_d2 <= 1'b0;
        end else if (!stall_i) begin
            y_o      <= conv_sum[11:4];  // >> 4 (divide by 16)
            valid_d2 <= valid_d1;
        end
    end

    assign valid_o = valid_d2;

endmodule
