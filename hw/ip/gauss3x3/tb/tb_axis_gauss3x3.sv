// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_gauss3x3 (TRUE CENTERED convolution).
//
// Tests:
//   Test 1  -- Uniform image (DC pass-through): all 128 -> all 128
//   Test 2  -- Single bright pixel (centered impulse response)
//   Test 3  -- Horizontal gradient (smoothing verification)
//   Test 4  -- Edge replication (checkerboard pattern, border pixel check)
//   Test 5  -- Stall behavior: output matches no-stall reference
//   Test 6  -- Multi-frame reset via SOF
//   Test 7  -- Impulse alignment (centered check)
//   Test 8  -- Bottom / right edge replication
//   Test 9  -- Latency measurement (expect H_ACTIVE + DEF_HBLANK + 3 cycles)
//   Test 10 -- No-blanking busy_o fallback: busy_o stalls upstream at row ends
//   Test 11 -- Minimum-blanking compliance: MathWorks spec (H>=6, V>=K_h lines)
//
// Conventions: drv_* intermediaries, posedge register, $display/$fatal.
//
// Golden model: standard centered 3x3 Gaussian with edge replication at all
// four borders. drive_frame* tasks insert blanking (H_BLANK cycles per row,
// V_BLANK cycles per frame) so the centered filter has free cycles to drain
// its phantom row / column outputs.

`timescale 1ns / 1ps

module tb_axis_gauss3x3;

    localparam int H          = 16;
    localparam int V          = 8;
    localparam int NUM_PIX    = H * V;
    localparam int CLK_PERIOD = 10;

    // Default blanking used by drive_frame / drive_frame_stall. H_BLANK >= 1
    // covers the per-row phantom column drain; V_BLANK >= H+3 covers the
    // phantom bottom row plus output pipeline flush.
    localparam int DEF_HBLANK = 4;
    localparam int DEF_VBLANK = H + 20;

    // ---- Clock / reset ----
    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    logic rst_n;

    // ---- Driver intermediaries ----
    logic       drv_valid = 1'b0;
    logic       drv_sof   = 1'b0;
    logic       drv_stall = 1'b0;
    logic [7:0] drv_y     = '0;

    logic       dut_valid, dut_sof, dut_stall;
    logic [7:0] dut_y;

    always_ff @(posedge clk) begin
        dut_valid <= drv_valid;
        dut_sof   <= drv_sof;
        dut_stall <= drv_stall;
        dut_y     <= drv_y;
    end

    // ---- DUT ----
    logic [7:0] y_out;
    logic       valid_out;
    logic       busy_out;

    axis_gauss3x3 #(
        .H_ACTIVE (H),
        .V_ACTIVE (V)
    ) u_dut (
        .clk_i   (clk),
        .rst_n_i (rst_n),
        .valid_i (dut_valid),
        .sof_i   (dut_sof),
        .stall_i (dut_stall),
        .y_i     (dut_y),
        .y_o     (y_out),
        .valid_o (valid_out),
        .busy_o  (busy_out)
    );

    // ---- Golden model: CENTERED 3x3 Gaussian with 4-border edge replication ----
    function automatic logic [7:0] gauss_golden(
        input logic [7:0] img [V][H],
        input int r, input int c
    );
        int rr, cc, weight;
        logic [11:0] sum;
        logic [7:0] pix;
        int kernel_r [3] = '{1, 2, 1};
        int kernel_c [3] = '{1, 2, 1};

        sum = 0;
        for (int dr = 0; dr < 3; dr++) begin
            for (int dc = 0; dc < 3; dc++) begin
                rr = r + dr - 1;
                cc = c + dc - 1;
                if (rr < 0) rr = 0;
                if (rr >= V) rr = V - 1;
                if (cc < 0) cc = 0;
                if (cc >= H) cc = H - 1;
                pix = img[rr][cc];
                weight = kernel_r[dr] * kernel_c[dc];
                sum = sum + 12'(weight * pix);
            end
        end
        return sum[11:4]; // >> 4
    endfunction

    // ---- State ----
    logic [7:0] frame_img  [V][H];
    logic [7:0] golden_out [V][H];
    logic [7:0] captured   [NUM_PIX];
    integer     cap_cnt;

    integer num_errors   = 0;
    integer busy_pulses  = 0;   // count of cycles where busy_out was high
    logic   busy_seen    = 1'b0;

    // Track busy_out (combinational) over simulation for monitoring.
    always @(posedge clk) begin
        if (busy_out) begin
            busy_pulses <= busy_pulses + 1;
            busy_seen   <= 1'b1;
        end
    end

    // ---- Drive helpers ----

    // Drive one frame with H_BLANK idle cycles after each row and V_BLANK
    // idle cycles after the last row. Provides the blanking windows the
    // centered filter needs for phantom-cycle drain.
    task automatic drive_frame_blanked(
        input logic [7:0] img [V][H],
        input int h_blank,
        input int v_blank
    );
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                drv_y     = img[r][c];
                drv_valid = 1'b1;
                drv_sof   = (r == 0 && c == 0) ? 1'b1 : 1'b0;
                drv_stall = 1'b0;
                @(posedge clk);
            end
            drv_valid = 1'b0;
            drv_sof   = 1'b0;
            repeat (h_blank) @(posedge clk);
        end
        repeat (v_blank) @(posedge clk);
    endtask

    // Drive with default blanking (enough for centered phantom drain).
    task automatic drive_frame(input logic [7:0] img [V][H]);
        drive_frame_blanked(img, DEF_HBLANK, DEF_VBLANK);
    endtask

    // Drive with periodic stalls AND row-boundary blanking.
    task automatic drive_frame_stall(
        input logic [7:0] img [V][H],
        input int stall_len,
        input int open_len
    );
        integer cyc_in_group;
        integer row_c, r;
        r = 0;
        while (r < V) begin
            row_c = 0;
            cyc_in_group = 0;
            while (row_c < H) begin
                if (cyc_in_group < open_len) begin
                    drv_y     = img[r][row_c];
                    drv_valid = 1'b1;
                    drv_sof   = (r == 0 && row_c == 0) ? 1'b1 : 1'b0;
                    drv_stall = 1'b0;
                    @(posedge clk);
                    row_c = row_c + 1;
                    cyc_in_group = cyc_in_group + 1;
                end else if (cyc_in_group < open_len + stall_len) begin
                    drv_valid = 1'b0;
                    drv_stall = 1'b1;
                    @(posedge clk);
                    cyc_in_group = cyc_in_group + 1;
                end else begin
                    cyc_in_group = 0;
                end
            end
            drv_valid = 1'b0;
            drv_sof   = 1'b0;
            drv_stall = 1'b0;
            repeat (DEF_HBLANK) @(posedge clk);
            r = r + 1;
        end
        repeat (DEF_VBLANK) @(posedge clk);
    endtask

    // Drive with NO row-boundary blanking: continuous valid_i=1. The driver
    // observes busy_out and holds the pixel index when it is high, modelling
    // the parent's s_axis_tready_o deassertion.
    task automatic drive_frame_noblank(input logic [7:0] img [V][H]);
        integer pix_idx;
        pix_idx = 0;
        while (pix_idx < NUM_PIX) begin
            drv_y     = img[pix_idx / H][pix_idx % H];
            drv_valid = 1'b1;
            drv_sof   = (pix_idx == 0) ? 1'b1 : 1'b0;
            drv_stall = 1'b0;
            @(posedge clk);
            // After posedge, busy_out reflects whether the beat was consumed.
            // Hold pix_idx while busy_out is high.
            if (!busy_out)
                pix_idx = pix_idx + 1;
        end
        drv_valid = 1'b0;
        drv_sof   = 1'b0;
        drv_stall = 1'b0;
        repeat (DEF_VBLANK) @(posedge clk);
    endtask

    // ---- Capture ----
    task automatic capture_frame;
        cap_cnt = 0;
        while (cap_cnt < NUM_PIX) begin
            @(posedge clk);
            if (valid_out && !dut_stall) begin
                captured[cap_cnt] = y_out;
                cap_cnt = cap_cnt + 1;
            end
        end
    endtask

    // ---- Golden compute (CENTERED: output at (r,c) uses window at (r,c)) ----
    task automatic compute_golden(input logic [7:0] img [V][H]);
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                golden_out[r][c] = gauss_golden(img, r, c);
    endtask

    task automatic check_frame(input string label);
        integer idx;
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                idx = r * H + c;
                if (captured[idx] !== golden_out[r][c]) begin
                    $display("FAIL %s px(%0d,%0d): got %0d exp %0d",
                             label, r, c, captured[idx], golden_out[r][c]);
                    num_errors = num_errors + 1;
                end
            end
        end
        $display("%s: check done", label);
    endtask

    task automatic reset_dut;
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
    endtask

    // ---- Main test ----
    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ================================================================
        // Test 1: Uniform image
        // ================================================================
        $display("=== Test 1: Uniform image ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd128;
        compute_golden(frame_img);

        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test1_uniform");

        // ================================================================
        // Test 2: Impulse response (centered)
        // ================================================================
        $display("=== Test 2: Impulse response ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd0;
        frame_img[4][4] = 8'd255;
        compute_golden(frame_img);

        reset_dut();

        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test2_impulse");

        // ================================================================
        // Test 3: Horizontal gradient
        // ================================================================
        $display("=== Test 3: Horizontal gradient ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'(c * 16);
        compute_golden(frame_img);

        reset_dut();

        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test3_gradient");

        // ================================================================
        // Test 4: Checkerboard (edge replication)
        // ================================================================
        $display("=== Test 4: Checkerboard ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = ((r + c) % 2 == 0) ? 8'd200 : 8'd50;
        compute_golden(frame_img);

        reset_dut();

        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test4_checker");

        // ================================================================
        // Test 5: Stall behavior
        // ================================================================
        $display("=== Test 5: Stall behavior ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'(c * 16);
        compute_golden(frame_img);

        reset_dut();

        fork
            drive_frame_stall(frame_img, 3, 10);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test5_stall");

        // ================================================================
        // Test 6: Multi-frame SOF reset
        // ================================================================
        $display("=== Test 6: Multi-frame SOF reset ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd200;

        reset_dut();

        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);

        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd50;
        compute_golden(frame_img);

        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test6_sof_reset");

        // ================================================================
        // Test 7: Impulse alignment (centered spatial check)
        //
        // Expected centered kernel weights for impulse=255 at (4,8):
        //   (4,8)  weight 4 -> 4*255>>4 = 63
        //   (3,8),(5,8),(4,7),(4,9)  weight 2 -> 31
        //   (3,7),(3,9),(5,7),(5,9)  weight 1 -> 15
        // Causal implementation would place these at (3,7) instead of (4,8).
        // ================================================================
        $display("=== Test 7: Impulse alignment (centered) ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd0;
        frame_img[4][8] = 8'd255;

        reset_dut();

        fork
            drive_frame_blanked(frame_img, 4, H + 20);
            capture_frame();
        join
        repeat (5) @(posedge clk);

        begin
            int t7_errors; t7_errors = 0;
            if (captured[4*H+8] !== 8'd63) begin
                $display("FAIL test7: center (4,8) got %0d exp 63  [causal center=(3,7) got %0d]",
                         captured[4*H+8], captured[3*H+7]); t7_errors++;
            end
            if (captured[3*H+8] !== 8'd31) begin $display("FAIL test7: (3,8) got %0d exp 31", captured[3*H+8]); t7_errors++; end
            if (captured[5*H+8] !== 8'd31) begin $display("FAIL test7: (5,8) got %0d exp 31", captured[5*H+8]); t7_errors++; end
            if (captured[4*H+7] !== 8'd31) begin $display("FAIL test7: (4,7) got %0d exp 31", captured[4*H+7]); t7_errors++; end
            if (captured[4*H+9] !== 8'd31) begin $display("FAIL test7: (4,9) got %0d exp 31", captured[4*H+9]); t7_errors++; end
            if (captured[3*H+7] !== 8'd15) begin $display("FAIL test7: (3,7) got %0d exp 15", captured[3*H+7]); t7_errors++; end
            if (captured[3*H+9] !== 8'd15) begin $display("FAIL test7: (3,9) got %0d exp 15", captured[3*H+9]); t7_errors++; end
            if (captured[5*H+7] !== 8'd15) begin $display("FAIL test7: (5,7) got %0d exp 15", captured[5*H+7]); t7_errors++; end
            if (captured[5*H+9] !== 8'd15) begin $display("FAIL test7: (5,9) got %0d exp 15", captured[5*H+9]); t7_errors++; end
            if (captured[4*H+6] !== 8'd0) begin
                $display("FAIL test7: outside kernel (4,6) got %0d exp 0", captured[4*H+6]); t7_errors++;
            end
            num_errors = num_errors + t7_errors;
        end
        $display("Test 7: done");

        // ================================================================
        // Test 8: Bottom / right edge replication
        //
        // Frame: all zeros except last real row (row V-1) = 255 and last
        // real column (col H-1) with a distinct value -- verifies the
        // edge replication covers the bottom and right borders exactly.
        // ================================================================
        $display("=== Test 8: Bottom / right edge ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd0;
        for (int c = 0; c < H; c++) frame_img[V-1][c] = 8'd200;  // bottom row
        for (int r = 0; r < V; r++) frame_img[r][H-1] = 8'd100;  // right col
        frame_img[V-1][H-1] = 8'd150;                             // bottom-right
        compute_golden(frame_img);

        reset_dut();

        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test8_bottom_right_edge");

        // ================================================================
        // Test 9: Latency measurement
        //
        // Reset, start driving, and measure cycles from first dut_valid=1
        // to first valid_out=1. With DEF_HBLANK row-blanking, reaching scan
        // position (1,1) requires H + DEF_HBLANK + 1 cycles, plus 2 pipeline
        // stages => H + DEF_HBLANK + 3 cycles total.
        // ================================================================
        $display("=== Test 9: Latency measurement ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd128;
        compute_golden(frame_img);

        reset_dut();

        begin
            int cycles, measured;
            bit out_seen;
            cycles   = 0;
            measured = -1;
            out_seen = 1'b0;
            fork
                drive_frame(frame_img);
                capture_frame();
                // Latency monitor
                begin
                    // Wait for first dut_valid (synchronous to posedge)
                    do @(posedge clk); while (!dut_valid);
                    cycles = 0;
                    while (!out_seen) begin
                        @(posedge clk);
                        cycles++;
                        if (valid_out) begin
                            measured = cycles;
                            out_seen = 1'b1;
                        end
                    end
                end
            join
            repeat (5) @(posedge clk);
            $display("Test 9: measured latency = %0d cycles (expected %0d = H+HBLANK+3)",
                     measured, H + DEF_HBLANK + 3);
            if (measured !== (H + DEF_HBLANK + 3)) begin
                $display("FAIL test9: latency mismatch");
                num_errors = num_errors + 1;
            end
            check_frame("test9_latency");
        end

        // ================================================================
        // Test 10: No-blanking busy_o fallback
        //
        // Drive continuously (no row-end blanking). busy_o should assert at
        // each row boundary; the driver honors it by holding pix_idx. Data
        // integrity must be preserved (output matches centered golden).
        // ================================================================
        $display("=== Test 10: No-blanking busy_o fallback ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'(r * H + c);
        compute_golden(frame_img);

        reset_dut();
        busy_seen   = 1'b0;
        busy_pulses = 0;

        fork
            drive_frame_noblank(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);

        $display("Test 10: busy_pulses = %0d (expect > 0)", busy_pulses);
        if (!busy_seen) begin
            $display("FAIL test10: busy_o never asserted under continuous valid");
            num_errors = num_errors + 1;
        end
        check_frame("test10_noblank");

        // ================================================================
        // Test 11: Minimum-blanking compliance
        //
        // MathWorks spec: min H_BLANK = 2*K_w = 6 cycles, min V_BLANK = K_h
        // lines. With that margin, busy_o must stay low and data must match.
        // ================================================================
        $display("=== Test 11: Minimum-blanking compliance ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'(r * 16 + c);
        compute_golden(frame_img);

        reset_dut();
        busy_seen   = 1'b0;
        busy_pulses = 0;

        fork
            drive_frame_blanked(frame_img, 6, 3 * (H + 6));
            capture_frame();
        join
        repeat (5) @(posedge clk);

        if (busy_seen) begin
            $display("FAIL test11: busy_o asserted under MathWorks min blanking (%0d pulses)",
                     busy_pulses);
            num_errors = num_errors + 1;
        end
        check_frame("test11_min_blank");

        // ================================================================
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_gauss3x3 FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_gauss3x3 PASSED -- 11 tests OK");
            $finish;
        end
    end

    initial begin
        #2000000;
        $fatal(1, "tb_axis_gauss3x3 TIMEOUT");
    end

endmodule
