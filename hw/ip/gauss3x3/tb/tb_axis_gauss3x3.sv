// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_gauss3x3.
//
// Tests (in order):
//   Test 1  — Uniform image (DC pass-through): all 128 → all 128
//   Test 2  — Single bright pixel (impulse response): verify kernel weights
//   Test 3  — Horizontal gradient (smoothing verification)
//   Test 4  — Edge replication (checkerboard pattern, border pixel check)
//   Test 5  — Stall behavior: output matches no-stall reference
//   Test 6  — Multi-frame reset via SOF
//   Test 7  — Impulse alignment (Phase 0 blocker): verifies CENTERED output;
//             expected to FAIL on causal RTL, must pass after Phase 1 RTL
//   Tests 8-11 added in Phase 3 (bottom/right edge, latency, busy_o, min blanking)
//
// Conventions: drv_* intermediaries, posedge register, $display/$fatal.

`timescale 1ns / 1ps

module tb_axis_gauss3x3;

    localparam int H          = 16;
    localparam int V          = 8;
    localparam int NUM_PIX    = H * V;
    localparam int CLK_PERIOD = 10;

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
        .valid_o (valid_out)
    );

    // ---- Golden model: 3x3 Gaussian with edge replication ----
    // Computes expected output for a full frame given pixel data.
    function automatic logic [7:0] gauss_golden(
        input logic [7:0] img [V][H],
        input int r, input int c
    );
        int rr, cc, wr, wc, weight;
        logic [11:0] sum;
        logic [7:0] pix;
        int kernel_r [3] = '{1, 2, 1};
        int kernel_c [3] = '{1, 2, 1};

        sum = 0;
        for (int dr = 0; dr < 3; dr++) begin
            for (int dc = 0; dc < 3; dc++) begin
                // Edge replication: clamp coordinates
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

    // ---- Pixel arrays ----
    logic [7:0] frame_img  [V][H];
    logic [7:0] golden_out [V][H];
    logic [7:0] captured   [NUM_PIX];
    integer     cap_cnt;

    integer num_errors = 0;

    // ---- Tasks ----

    // Drive one frame of pixels (no stall).
    task automatic drive_frame(input logic [7:0] img [V][H]);
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                drv_y     = img[r][c];
                drv_valid = 1'b1;
                drv_sof   = (r == 0 && c == 0) ? 1'b1 : 1'b0;
                drv_stall = 1'b0;
                @(posedge clk);
            end
        end
        drv_valid = 1'b0;
        drv_sof   = 1'b0;
    endtask

    // Drive one frame with periodic stalls: OPEN_LEN valid, STALL_LEN stall.
    task automatic drive_frame_stall(
        input logic [7:0] img [V][H],
        input int stall_len,
        input int open_len
    );
        integer pix_idx, cyc_in_group;
        pix_idx = 0;
        cyc_in_group = 0;
        while (pix_idx < NUM_PIX) begin
            if (cyc_in_group < open_len) begin
                // Valid pixel
                drv_y     = img[pix_idx / H][pix_idx % H];
                drv_valid = 1'b1;
                drv_sof   = (pix_idx == 0) ? 1'b1 : 1'b0;
                drv_stall = 1'b0;
                @(posedge clk);
                pix_idx = pix_idx + 1;
                cyc_in_group = cyc_in_group + 1;
            end else if (cyc_in_group < open_len + stall_len) begin
                // Stall
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
    endtask

    // Drive one frame with H_BLANK idle cycles after each row and V_BLANK idle
    // cycles after the last row. Provides blanking windows for phantom-cycle
    // drain in the centered Gaussian implementation (Phase 1+).
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

    // Capture NUM_PIX output pixels.
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

    // Compute golden output for a frame image.
    // The causal streaming filter centers the kernel at (r-1, c-1) relative to
    // the scan position (r, c). gauss_golden handles negative coords via clamping.
    task automatic compute_golden(input logic [7:0] img [V][H]);
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                golden_out[r][c] = gauss_golden(img, r - 1, c - 1);
    endtask

    // Check captured output against golden.
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

    // ---- Main test ----
    initial begin
        // ---- Reset ----
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ================================================================
        // Test 1: Uniform image (DC pass-through)
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
        // Test 2: Single bright pixel (impulse response)
        // ================================================================
        $display("=== Test 2: Impulse response ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd0;
        frame_img[4][4] = 8'd255;
        compute_golden(frame_img);

        // Reset to clear line buffer state from previous test
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

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

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test3_gradient");

        // ================================================================
        // Test 4: Checkerboard (edge replication)
        // ================================================================
        $display("=== Test 4: Checkerboard (edge replication) ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = ((r + c) % 2 == 0) ? 8'd200 : 8'd50;
        compute_golden(frame_img);

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test4_checker");

        // ================================================================
        // Test 5: Stall behavior
        // Same horizontal gradient, with periodic stalls.
        // Output should match no-stall reference exactly.
        // ================================================================
        $display("=== Test 5: Stall behavior ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'(c * 16);
        compute_golden(frame_img);  // same golden as test 3

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        fork
            drive_frame_stall(frame_img, 3, 10);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test5_stall");

        // ================================================================
        // Test 6: Multi-frame SOF reset
        // Frame 1: all 200. Frame 2: all 50.
        // The second frame's output should match what it would produce alone.
        // ================================================================
        $display("=== Test 6: Multi-frame SOF reset ===");

        // Drive frame 1 (all 200) — we don't care about this output
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd200;

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Drive frame 1
        fork
            drive_frame(frame_img);
            capture_frame();  // capture and discard
        join
        repeat (5) @(posedge clk);

        // Now drive frame 2 (all 50) — SOF resets counters
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd50;
        compute_golden(frame_img);  // golden for frame 2 standalone

        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);

        // Frame 2 output should match standalone golden (uniform 50 → all 50)
        check_frame("test6_sof_reset");

        // ================================================================
        // Test 7: Impulse alignment — Phase 0 blocker
        //
        // Verifies CENTERED Gaussian output: the kernel center (weight 4)
        // must land at the impulse pixel position, not at the causal
        // offset (row-1, col-1). With the current causal implementation
        // this test is expected to FAIL, confirming the spatial shift.
        // After Phase 1 RTL changes (centered Gaussian) it must pass.
        //
        // H_BLANK=4 and V_BLANK=H+20 give the centered module enough
        // blanking to drain all phantom cycles. With the causal module
        // (no phantom cycles) these blank cycles are inert.
        // ================================================================
        $display("=== Test 7: Impulse alignment (centered Gaussian check) ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 8'd0;
        frame_img[4][8] = 8'd255;  // interior impulse, away from all borders

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        fork
            drive_frame_blanked(frame_img, 4, H + 20);
            capture_frame();
        join
        repeat (5) @(posedge clk);

        // Centered kernel weights for impulse=255:
        //   center  (4,8) = 4*255 >> 4 = 63
        //   edge-adjacent: (3,8),(5,8),(4,7),(4,9) = 2*255 >> 4 = 31
        //   diagonal:      (3,7),(3,9),(5,7),(5,9) = 1*255 >> 4 = 15
        // Causal implementation puts center at (3,7) instead of (4,8).
        begin
            int t7_errors;
            t7_errors = 0;
            if (captured[4*H+8] !== 8'd63) begin
                $display("FAIL test7: center (4,8) got %0d exp 63  [causal center=(3,7) got %0d]",
                         captured[4*H+8], captured[3*H+7]);
                t7_errors++;
            end
            if (captured[3*H+8] !== 8'd31) begin
                $display("FAIL test7: (3,8) got %0d exp 31", captured[3*H+8]); t7_errors++;
            end
            if (captured[5*H+8] !== 8'd31) begin
                $display("FAIL test7: (5,8) got %0d exp 31", captured[5*H+8]); t7_errors++;
            end
            if (captured[4*H+7] !== 8'd31) begin
                $display("FAIL test7: (4,7) got %0d exp 31", captured[4*H+7]); t7_errors++;
            end
            if (captured[4*H+9] !== 8'd31) begin
                $display("FAIL test7: (4,9) got %0d exp 31", captured[4*H+9]); t7_errors++;
            end
            if (captured[3*H+7] !== 8'd15) begin
                $display("FAIL test7: (3,7) got %0d exp 15", captured[3*H+7]); t7_errors++;
            end
            if (captured[3*H+9] !== 8'd15) begin
                $display("FAIL test7: (3,9) got %0d exp 15", captured[3*H+9]); t7_errors++;
            end
            if (captured[5*H+7] !== 8'd15) begin
                $display("FAIL test7: (5,7) got %0d exp 15", captured[5*H+7]); t7_errors++;
            end
            if (captured[5*H+9] !== 8'd15) begin
                $display("FAIL test7: (5,9) got %0d exp 15", captured[5*H+9]); t7_errors++;
            end
            if (captured[4*H+6] !== 8'd0) begin
                $display("FAIL test7: outside kernel (4,6) got %0d exp 0", captured[4*H+6]);
                t7_errors++;
            end
            num_errors = num_errors + t7_errors;
        end
        $display("Test 7: impulse alignment check done");

        // ================================================================
        // Summary
        // ================================================================
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_gauss3x3 FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_gauss3x3 PASSED — 7 tests OK");
            $finish;
        end
    end

endmodule
