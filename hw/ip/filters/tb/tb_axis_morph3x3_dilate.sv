// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_morph3x3_dilate.
//
// axis_morph3x3_dilate is a thin wrapper over axis_window3x3<1> that reduces
// the 9-tap window with a 9-way OR. EDGE_REPLICATE at all four borders.
//
// Tests:
//   Test 1 -- All-zeros passthrough: input all 0, output all 0.
//   Test 2 -- All-ones passthrough: input all 1, output all 1.
//   Test 3 -- Isolated pixel (4,4)=1: output has 3x3 block at rows 3..5,
//             cols 3..5 (verified via golden).
//   Test 4 -- Horizontal stripe at row 4: output rows 3,4,5 all 1, rest 0
//             (verified via golden).
//   Test 5 -- Corner pixel (0,0)=1 with EDGE_REPLICATE: golden dilation
//             at (0,0), (0,1), (1,0), (1,1) is 1 (verified via golden).
//   Test 6 -- enable_i=0 passthrough: checker pattern, output == input
//             bit-for-bit with zero additional latency.
//   Test 7 -- Stall behavior: drive_frame_stall under enable_i=1, compare
//             to golden.
//   Test 8 -- Multi-frame SOF reset: frame A = all-ones, then frame B =
//             all-zeros; B must not leak foreground from A.
//   Test 9 -- Framing: tlast = EOL and tuser = SOF assert correctly.
//
// Conventions: drv_* intermediaries, posedge register, $display/$fatal.

`timescale 1ns / 1ps

module tb_axis_morph3x3_dilate;

    localparam int H          = 16;
    localparam int V          = 8;
    localparam int NUM_PIX    = H * V;
    localparam int CLK_PERIOD = 10;

    // Default blanking (matches gauss TB pattern; window needs >=1 H-blank
    // and >=H+1 V-blank cycles for phantom drain).
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
    logic busy_out;

    axis_morph3x3_dilate #(
        .H_ACTIVE (H),
        .V_ACTIVE (V)
    ) u_dut (
        .clk_i    (clk),
        .rst_n_i  (rst_n),
        .enable_i (dut_enable),
        .s_axis   (s_axis),
        .m_axis   (m_axis),
        .busy_o   (busy_out)
    );

    // ---- Golden: 3x3 OR with edge replication ----
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

    // ---- Golden compute ----
    task automatic compute_golden(input logic img [V][H]);
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                golden_out[r][c] = dilate_golden(img, r, c);
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
        // Test 1: All-zeros passthrough
        // ================================================================
        $display("=== Test 1: All-zeros ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        compute_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test1_all_zeros");

        // ================================================================
        // Test 2: All-ones passthrough
        // ================================================================
        $display("=== Test 2: All-ones ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b1;
        compute_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test2_all_ones");

        // ================================================================
        // Test 3: Isolated pixel at (4,4)=1 -> 3x3 block at rows 3..5, cols 3..5
        // ================================================================
        $display("=== Test 3: Isolated pixel expands to 3x3 block ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        frame_img[4][4] = 1'b1;
        compute_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test3_isolated_expands");

        // ================================================================
        // Test 4: 1-row horizontal stripe at row 4 -> rows 3,4,5 all 1
        // ================================================================
        $display("=== Test 4: 1-row stripe thickens to 3 rows ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        for (int c = 0; c < H; c++)
            frame_img[4][c] = 1'b1;
        compute_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test4_stripe_thickens");

        // ================================================================
        // Test 5: Corner pixel (0,0)=1 with EDGE_REPLICATE
        // ================================================================
        $display("=== Test 5: Corner pixel with edge replication ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        frame_img[0][0] = 1'b1;
        compute_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test5_corner_pixel");

        // ================================================================
        // Test 6: enable_i=0 passthrough -- output == input, no latency
        // ================================================================
        $display("=== Test 6: enable_i=0 passthrough ===");
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
            integer t6_errors;
            t6_errors = 0;
            for (int r = 0; r < V; r++) begin
                for (int c = 0; c < H; c++) begin
                    if (captured[r * H + c] !== frame_img[r][c]) begin
                        $display("FAIL test6 px(%0d,%0d): got %0b exp %0b",
                                 r, c, captured[r * H + c], frame_img[r][c]);
                        t6_errors++;
                    end
                end
            end
            num_errors = num_errors + t6_errors;
            if (t6_errors == 0) $display("test6_passthrough: check done");
        end

        // ================================================================
        // Test 7: Stall behaviour with enable_i=1
        // ================================================================
        $display("=== Test 7: Stall behaviour ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        // Create a pattern with some 1s so dilation has meaningful output
        for (int r = 2; r < V - 2; r++)
            for (int c = 2; c < H - 2; c++)
                frame_img[r][c] = 1'b1;
        compute_golden(frame_img);
        reset_dut();
        drv_enable = 1'b1;
        fork
            drive_frame_stall(frame_img, 3, 10);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test7_stall");

        // ================================================================
        // Test 8: Multi-frame SOF reset (A all-ones, B all-zeros -- no leak)
        // ================================================================
        $display("=== Test 8: Multi-frame SOF reset ===");
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
        compute_golden(frame_img);
        fork
            drive_frame(frame_img);
            capture_frame();
        join
        repeat (5) @(posedge clk);
        check_frame("test8_sof_reset");

        // ================================================================
        // Test 9: Framing (tlast = EOL, tuser = SOF)
        // ================================================================
        $display("=== Test 9: Framing (tlast EOL, tuser SOF) ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b1;   // all-ones; data content doesn't matter

        reset_dut();
        drv_enable = 1'b1;

        begin
            int tuser_high_count, tlast_high_count, captured_out;
            tuser_high_count = 0;
            tlast_high_count = 0;
            captured_out = 0;
            fork
                drive_frame(frame_img);
                begin
                    // Monitor output for one frame's worth of valid beats.
                    while (captured_out < V * H) begin
                        @(posedge clk);
                        if (m_axis.tvalid && m_axis.tready) begin
                            if (captured_out == 0) begin
                                if (!m_axis.tuser) begin
                                    $display("FAIL test9: tuser not on first pixel");
                                    num_errors = num_errors + 1;
                                end
                            end else begin
                                if (m_axis.tuser) begin
                                    $display("FAIL test9: tuser on non-first px %0d",
                                             captured_out);
                                    num_errors = num_errors + 1;
                                end
                            end
                            if (m_axis.tlast) tlast_high_count = tlast_high_count + 1;
                            // tlast must assert on the last pixel of each row
                            if (m_axis.tlast && ((captured_out % H) != (H - 1))) begin
                                $display("FAIL test9: tlast at mid-row (idx %0d)",
                                         captured_out);
                                num_errors = num_errors + 1;
                            end
                            if (!m_axis.tlast && ((captured_out % H) == (H - 1))) begin
                                $display("FAIL test9: tlast NOT at row end (idx %0d)",
                                         captured_out);
                                num_errors = num_errors + 1;
                            end
                            captured_out = captured_out + 1;
                        end
                    end
                end
            join
            if (tlast_high_count != V) begin
                $display("FAIL test9: tlast high %0d times, expected %0d (one per row)",
                         tlast_high_count, V);
                num_errors = num_errors + 1;
            end
        end
        $display("Test 9: framing done");

        // ================================================================
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_morph3x3_dilate FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_morph3x3_dilate PASSED -- 9 tests OK");
            $finish;
        end
    end

    initial begin
        #2000000;
        $fatal(1, "tb_axis_morph3x3_dilate TIMEOUT");
    end

endmodule
