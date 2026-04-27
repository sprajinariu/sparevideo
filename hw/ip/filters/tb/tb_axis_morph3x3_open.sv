// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_morph3x3_open.
//
// axis_morph3x3_open is a pure structural composite of axis_morph3x3_erode feeding
// axis_morph3x3_dilate on an internal AXI4-Stream interface. The combined operation
// is morphological opening: erosion followed by dilation. EDGE_REPLICATE at
// all four borders is inherited from both sub-modules.
//
// Tests:
//   Test 1  -- All-zeros: output all 0.
//   Test 2  -- All-ones: output all 1.
//   Test 3  -- Isolated single pixel at (4,4)=1: output all 0 (salt removal,
//              the defining opening property).
//   Test 4  -- 3x3 solid block at rows 3..5, cols 3..5: output is the same
//              block (golden match).
//   Test 5  -- 1-px-tall horizontal stripe at row 4: output all 0
//              (thin-feature removal; Risk D1 evidence).
//   Test 6  -- 5x5 solid block at rows 1..5, cols 1..5: output == input
//              (opening is idempotent on sufficiently large blobs).
//   Test 7  -- enable_i=0 passthrough: checker pattern, output == input
//              bit-for-bit with zero additional latency.
//   Test 8  -- Downstream stall: drive_frame_stall under enable_i=1,
//              golden match. Single-output module, so downstream-only
//              stall is sufficient.
//   Test 9  -- Multi-frame SOF reset: frame A all-ones, frame B all-zeros;
//              B must not leak foreground from A.
//   Test 10 -- Latency measurement: first valid_o arrives at
//              2 * (H + DEF_HBLANK + 3) cycles after the first valid_i.
//
// Conventions: drv_* intermediaries, posedge register, $display/$fatal.

`timescale 1ns / 1ps

module tb_axis_morph3x3_open;

    localparam int H          = 16;
    localparam int V          = 8;
    localparam int NUM_PIX    = H * V;
    localparam int CLK_PERIOD = 10;

    // Default blanking (matches erode/dilate TB pattern; each sub-module's
    // window needs >=1 H-blank and >=H+1 V-blank cycles for phantom drain).
    localparam int DEF_HBLANK = 4;
    localparam int DEF_VBLANK = H + 20;

    // ---- Clock / reset ----
    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    logic rst_n;

    // ---- Driver intermediaries ----
    logic drv_tvalid = 1'b0;
    logic drv_tlast  = 1'b0;
    logic drv_tuser  = 1'b0;
    logic drv_tdata  = 1'b0;
    logic drv_tready = 1'b1;
    logic drv_enable = 1'b1;

    logic dut_tready, dut_enable;

    always_ff @(posedge clk) begin
        dut_tready <= drv_tready;
        dut_enable <= drv_enable;
    end

    // ---- AXI4-Stream interfaces ----
    axis_if #(.DATA_W(1), .USER_W(1)) s_axis ();
    axis_if #(.DATA_W(1), .USER_W(1)) m_axis ();

    always_ff @(posedge clk) begin
        s_axis.tdata  <= drv_tdata;
        s_axis.tvalid <= drv_tvalid;
        s_axis.tlast  <= drv_tlast;
        s_axis.tuser  <= drv_tuser;
    end

    assign m_axis.tready = dut_tready;

    // ---- DUT ----
    axis_morph3x3_open #(
        .H_ACTIVE (H),
        .V_ACTIVE (V)
    ) u_dut (
        .clk_i    (clk),
        .rst_n_i  (rst_n),
        .enable_i (dut_enable),
        .s_axis   (s_axis),
        .m_axis   (m_axis)
    );

    // ---- Golden: 3x3 AND (erode) with edge replication ----
    function automatic logic erode_golden(
        input logic img [V][H],
        input int r, input int c
    );
        int rr, cc;
        logic out;
        out = 1'b1;
        for (int dr = 0; dr < 3; dr++) begin
            for (int dc = 0; dc < 3; dc++) begin
                rr = r + dr - 1;
                cc = c + dc - 1;
                if (rr < 0)  rr = 0;
                if (rr >= V) rr = V - 1;
                if (cc < 0)  cc = 0;
                if (cc >= H) cc = H - 1;
                out = out & img[rr][cc];
            end
        end
        return out;
    endfunction

    // ---- Golden: 3x3 OR (dilate) with edge replication ----
    function automatic logic dilate_golden(
        input logic img [V][H],
        input int r, input int c
    );
        int rr, cc;
        logic out;
        out = 1'b0;
        for (int dr = 0; dr < 3; dr++) begin
            for (int dc = 0; dc < 3; dc++) begin
                rr = r + dr - 1;
                cc = c + dc - 1;
                if (rr < 0)  rr = 0;
                if (rr >= V) rr = V - 1;
                if (cc < 0)  cc = 0;
                if (cc >= H) cc = H - 1;
                out = out | img[rr][cc];
            end
        end
        return out;
    endfunction

    // ---- State ----
    logic frame_img  [V][H];
    logic golden_out [V][H];
    logic captured   [NUM_PIX];
    integer cap_cnt;

    integer num_errors = 0;

    // ---- Composite golden (erode -> dilate) ----
    task automatic compute_open_golden(input logic img [V][H]);
        logic eroded [V][H];
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                eroded[r][c] = erode_golden(img, r, c);
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                golden_out[r][c] = dilate_golden(eroded, r, c);
    endtask

    // ---- Drive helpers ----
    task automatic drive_frame_blanked(
        input logic img [V][H],
        input int h_blank,
        input int v_blank
    );
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                drv_tdata  = img[r][c];
                drv_tvalid = 1'b1;
                drv_tuser  = (r == 0 && c == 0) ? 1'b1 : 1'b0;
                drv_tlast  = (c == H - 1) ? 1'b1 : 1'b0;
                drv_tready = 1'b1;
                @(posedge clk);
            end
            drv_tvalid = 1'b0;
            drv_tuser  = 1'b0;
            drv_tlast  = 1'b0;
            repeat (h_blank) @(posedge clk);
        end
        repeat (v_blank) @(posedge clk);
    endtask

    task automatic drive_frame(input logic img [V][H]);
        drive_frame_blanked(img, DEF_HBLANK, DEF_VBLANK);
    endtask

    // Drive with periodic downstream stalls (tready deassertion). Stalls
    // occur in fixed cadence groups of (open_len transfers, stall_len
    // stalled cycles). H-blanking is still inserted at each row end.
    task automatic drive_frame_stall(
        input logic img [V][H],
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
                    drv_tdata  = img[r][row_c];
                    drv_tvalid = 1'b1;
                    drv_tuser  = (r == 0 && row_c == 0) ? 1'b1 : 1'b0;
                    drv_tlast  = (row_c == H - 1) ? 1'b1 : 1'b0;
                    drv_tready = 1'b1;
                    @(posedge clk);
                    row_c = row_c + 1;
                    cyc_in_group = cyc_in_group + 1;
                end else if (cyc_in_group < open_len + stall_len) begin
                    // Deassert downstream tready (stall)
                    drv_tvalid = 1'b0;
                    drv_tready = 1'b0;
                    @(posedge clk);
                    cyc_in_group = cyc_in_group + 1;
                end else begin
                    cyc_in_group = 0;
                end
            end
            drv_tvalid = 1'b0;
            drv_tuser  = 1'b0;
            drv_tlast  = 1'b0;
            drv_tready = 1'b1;
            repeat (DEF_HBLANK) @(posedge clk);
            r = r + 1;
        end
        repeat (DEF_VBLANK) @(posedge clk);
    endtask

    // ---- Capture ----
    task automatic capture_frame;
        cap_cnt = 0;
        while (cap_cnt < NUM_PIX) begin
            @(posedge clk);
            if (m_axis.tvalid && m_axis.tready) begin
                captured[cap_cnt] = m_axis.tdata;
                cap_cnt = cap_cnt + 1;
            end
        end
    endtask

    task automatic check_frame(input string label);
        integer idx;
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                idx = r * H + c;
                if (captured[idx] !== golden_out[r][c]) begin
                    $display("FAIL %s px(%0d,%0d): got %0b exp %0b",
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


    // ---- Main ----
    initial begin
        rst_n = 0;
        drv_enable = 1'b1;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ================================================================
        // Test 1: All-zeros
        // ================================================================
        $display("=== Test 1: All-zeros ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        compute_open_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test1_all_zeros");

        // ================================================================
        // Test 2: All-ones
        // ================================================================
        $display("=== Test 2: All-ones ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b1;
        compute_open_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test2_all_ones");

        // ================================================================
        // Test 3: Isolated pixel -> all zeros (salt removal)
        // ================================================================
        $display("=== Test 3: Isolated pixel removed ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        frame_img[4][4] = 1'b1;
        compute_open_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test3_isolated_removed");

        // ================================================================
        // Test 4: 3x3 block at rows 3..5, cols 3..5 -> preserved
        // ================================================================
        $display("=== Test 4: 3x3 block preserved ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        for (int r = 3; r <= 5; r++)
            for (int c = 3; c <= 5; c++)
                frame_img[r][c] = 1'b1;
        compute_open_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test4_3x3_block");

        // ================================================================
        // Test 5: 1-px-tall horizontal stripe -> all zeros
        // ================================================================
        $display("=== Test 5: Thin stripe removed ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        for (int c = 0; c < H; c++)
            frame_img[4][c] = 1'b1;
        compute_open_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test5_thin_stripe");

        // ================================================================
        // Test 6: 5x5 solid block at rows 1..5, cols 1..5 -> output == input
        // ================================================================
        $display("=== Test 6: 5x5 block idempotent ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        for (int r = 1; r <= 5; r++)
            for (int c = 1; c <= 5; c++)
                frame_img[r][c] = 1'b1;
        compute_open_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test6_5x5_block");
        // Also assert idempotence explicitly against input:
        begin
            integer t6_idem_errors;
            t6_idem_errors = 0;
            for (int r = 0; r < V; r++) begin
                for (int c = 0; c < H; c++) begin
                    if (golden_out[r][c] !== frame_img[r][c]) begin
                        $display("FAIL test6_idempotent px(%0d,%0d): golden %0b input %0b",
                                 r, c, golden_out[r][c], frame_img[r][c]);
                        t6_idem_errors++;
                    end
                end
            end
            num_errors = num_errors + t6_idem_errors;
            if (t6_idem_errors == 0) $display("test6_idempotent: golden == input");
        end

        // ================================================================
        // Test 7: enable_i=0 passthrough -- output == input, no latency
        // ================================================================
        $display("=== Test 7: enable_i=0 passthrough ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = ((r + c) % 2 == 0) ? 1'b1 : 1'b0;
        reset_dut();
        drv_enable = 1'b0;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        begin
            integer t7_errors;
            t7_errors = 0;
            for (int r = 0; r < V; r++) begin
                for (int c = 0; c < H; c++) begin
                    if (captured[r * H + c] !== frame_img[r][c]) begin
                        $display("FAIL test7 px(%0d,%0d): got %0b exp %0b",
                                 r, c, captured[r * H + c], frame_img[r][c]);
                        t7_errors++;
                    end
                end
            end
            num_errors = num_errors + t7_errors;
            if (t7_errors == 0) $display("test7_passthrough: check done");
        end

        // ================================================================
        // Test 8: Downstream stall with enable_i=1
        // ================================================================
        $display("=== Test 8: Downstream stall ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        // Interior region of 1s so opening has meaningful output
        for (int r = 2; r < V - 2; r++)
            for (int c = 2; c < H - 2; c++)
                frame_img[r][c] = 1'b1;
        compute_open_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame_stall(frame_img, 3, 10);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test8_stall");

        // ================================================================
        // Test 9: Multi-frame SOF reset (A all-ones, B all-zeros -- no leak)
        // ================================================================
        $display("=== Test 9: Multi-frame SOF reset ===");
        // Frame A: all-ones
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b1;
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);

        // Frame B: all-zeros -- output must be all-zeros (no leak from A)
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        compute_open_golden(frame_img);
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test9_sof_reset");

        // ================================================================
        // Test 10: Latency measurement -- first valid_o at
        //          2 * (H + DEF_HBLANK + 3) cycles after first valid_i
        // ================================================================
        $display("=== Test 10: Latency measurement ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b1;
        reset_dut();
        drv_enable = 1'b1;
        begin
            integer expected_latency;
            integer first_valid_in_cyc;
            integer first_valid_out_cyc;
            integer measured_latency;
            integer cyc;
            integer saw_valid_in;
            integer saw_valid_out;

            expected_latency    = 2 * (H + DEF_HBLANK + 3);
            first_valid_in_cyc  = 0;
            first_valid_out_cyc = 0;
            cyc                 = 0;
            saw_valid_in        = 0;
            saw_valid_out       = 0;

            fork
                drive_frame(frame_img);
                // Timing monitor: count cycles and record first valid_i and
                // first valid_o timestamps.
                begin : timing_monitor
                    while (saw_valid_out == 0) begin
                        @(posedge clk);
                        cyc = cyc + 1;
                        if (saw_valid_in == 0 && s_axis.tvalid && s_axis.tready) begin
                            first_valid_in_cyc = cyc;
                            saw_valid_in = 1;
                        end
                        if (saw_valid_out == 0 && m_axis.tvalid && m_axis.tready) begin
                            first_valid_out_cyc = cyc;
                            saw_valid_out = 1;
                        end
                    end
                end
                capture_frame();
            join
            repeat (5) @(posedge clk);

            if (saw_valid_in == 0 || saw_valid_out == 0) begin
                $display("FAIL test10: did not observe valid_i (%0d) or valid_o (%0d)",
                         saw_valid_in, saw_valid_out);
                num_errors = num_errors + 1;
            end else begin
                measured_latency = first_valid_out_cyc - first_valid_in_cyc;
                $display("Test 10: in @%0d out @%0d latency %0d (exp %0d)",
                         first_valid_in_cyc, first_valid_out_cyc,
                         measured_latency, expected_latency);
                if (measured_latency != expected_latency) begin
                    $display("FAIL test10: latency mismatch got %0d expected %0d",
                             measured_latency, expected_latency);
                    num_errors = num_errors + 1;
                end
            end
        end

        // ================================================================
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_morph3x3_open FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_morph3x3_open PASSED -- 10 tests OK");
            $finish;
        end
    end

    initial begin
        #4000000;
        $fatal(1, "tb_axis_morph3x3_open TIMEOUT");
    end

endmodule
