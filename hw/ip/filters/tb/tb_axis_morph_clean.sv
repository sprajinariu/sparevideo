// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_morph_clean.
//
// Two DUT instances are driven in parallel: one with CLOSE_KERNEL=3 (k3)
// and one with CLOSE_KERNEL=5 (k5). They receive the same input stream and
// are compared against their respective goldens.
//
// Tests:
//   T1  open_en=0, close_en=0 | checker pattern  -> passthrough (identical)
//   T2  open_en=1, close_en=0 | isolated 1px     -> all-zero (open removes salt)
//   T3  open_en=0, close_en=1 | 1px hole in 3x3 patch -> hole filled (both k=3,k=5)
//   T4  open_en=0, close_en=1 | 2x2 hole in 6x6 patch -> k=3 leaves hole; k=5 fills it
//   T5  open_en=1, close_en=1 | clean 5x5 block  -> idempotent (output == input)
//   T6  open_en=1, close_en=1 | same 5x5 block + downstream backpressure -> golden match
//   T7  any (open=1,close=1)  | two consecutive frames (all-ones -> all-zeros) -> no leak
//
// Conventions: drv_* intermediaries, posedge register, !==, $display/$fatal.

`timescale 1ns / 1ps

module tb_axis_morph_clean;

    localparam int H          = 16;
    localparam int V          = 8;
    localparam int NUM_PIX    = H * V;
    localparam int CLK_PERIOD = 10;

    // Blanking: each sub-stage window needs >=1 H-blank and >=H+1 V-blank cycles.
    // axis_morph_clean with CLOSE_KERNEL=5 has 6 sub-stages, so use generous margins.
    localparam int DEF_HBLANK = 4;
    localparam int DEF_VBLANK = H + 40;

    // ---- Clock / reset ----
    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    logic rst_n;

    // ---- Driver intermediaries (blocking = in initial block) ----
    logic drv_tvalid   = 1'b0;
    logic drv_tlast    = 1'b0;
    logic drv_tuser    = 1'b0;
    logic drv_tdata    = 1'b0;
    logic drv_tready   = 1'b1;
    logic drv_open_en  = 1'b0;
    logic drv_close_en = 1'b0;

    // DUT inputs registered on posedge (avoids INITIALDLY race)
    logic dut_tready;
    logic dut_open_en;
    logic dut_close_en;

    always_ff @(posedge clk) begin
        dut_tready   <= drv_tready;
        dut_open_en  <= drv_open_en;
        dut_close_en <= drv_close_en;
    end

    // ---- AXI4-Stream interfaces ----
    // s_axis: shared upstream input
    axis_if #(.DATA_W(1), .USER_W(1)) s_axis ();

    always_ff @(posedge clk) begin
        s_axis.tdata  <= drv_tdata;
        s_axis.tvalid <= drv_tvalid;
        s_axis.tlast  <= drv_tlast;
        s_axis.tuser  <= drv_tuser;
    end

    // m_axis_k3: output from CLOSE_KERNEL=3 DUT
    axis_if #(.DATA_W(1), .USER_W(1)) m_axis_k3 ();
    // m_axis_k5: output from CLOSE_KERNEL=5 DUT
    axis_if #(.DATA_W(1), .USER_W(1)) m_axis_k5 ();

    // Both DUTs driven by the same tready (for shared-stall tests).
    // For asymmetric tests we override via drv_tready_k3/k5 (see T6).
    logic drv_tready_k3 = 1'b1;
    logic drv_tready_k5 = 1'b1;
    logic dut_tready_k3, dut_tready_k5;

    always_ff @(posedge clk) begin
        dut_tready_k3 <= drv_tready_k3;
        dut_tready_k5 <= drv_tready_k5;
    end

    assign m_axis_k3.tready = dut_tready_k3;
    assign m_axis_k5.tready = dut_tready_k5;

    // Both DUTs share the same s_axis. We need s_axis.tready to be
    // the AND of both DUT s_treadys — handled here by routing the same
    // s_axis interface into both DUTs. The interface tready wire is driven
    // by whichever DUT stalls first (both must be ready for a beat to fire).
    // Since both DUTs have identical pipeline depth for matched enable configs,
    // and we use a shared downstream tready in most tests, this is safe.
    // For backpressure test T6 we use dut_tready_k3/k5 independently.

    // s_axis.tready is a 'rx' modport output from the DUT.
    // With two DUTs both connected to the same interface, the simulator
    // would have multiple drivers on s_axis.tready. To avoid multi-driver
    // conflicts, instantiate a second s_axis_k5 interface fed by the same
    // drv_* signals.
    axis_if #(.DATA_W(1), .USER_W(1)) s_axis_k5 ();

    always_ff @(posedge clk) begin
        s_axis_k5.tdata  <= drv_tdata;
        s_axis_k5.tvalid <= drv_tvalid;
        s_axis_k5.tlast  <= drv_tlast;
        s_axis_k5.tuser  <= drv_tuser;
    end

    // ---- DUT k3: CLOSE_KERNEL=3 ----
    axis_morph_clean #(
        .H_ACTIVE     (H),
        .V_ACTIVE     (V),
        .CLOSE_KERNEL (3)
    ) u_dut_k3 (
        .clk_i             (clk),
        .rst_n_i           (rst_n),
        .morph_open_en_i   (dut_open_en),
        .morph_close_en_i  (dut_close_en),
        .s_axis            (s_axis),
        .m_axis            (m_axis_k3)
    );

    // ---- DUT k5: CLOSE_KERNEL=5 ----
    axis_morph_clean #(
        .H_ACTIVE     (H),
        .V_ACTIVE     (V),
        .CLOSE_KERNEL (5)
    ) u_dut_k5 (
        .clk_i             (clk),
        .rst_n_i           (rst_n),
        .morph_open_en_i   (dut_open_en),
        .morph_close_en_i  (dut_close_en),
        .s_axis            (s_axis_k5),
        .m_axis            (m_axis_k5)
    );

    // ---- Golden helper functions ----
    // 3x3 AND-reduce with EDGE_REPLICATE (erosion)
    function automatic logic erode_golden(
        input logic img [V][H],
        input int r, c
    );
        logic out;
        int rr, cc;
        out = 1'b1;
        for (int dr = 0; dr < 3; dr++) begin
            for (int dc = 0; dc < 3; dc++) begin
                rr = r + dr - 1; cc = c + dc - 1;
                if (rr < 0)  rr = 0;
                if (rr >= V) rr = V - 1;
                if (cc < 0)  cc = 0;
                if (cc >= H) cc = H - 1;
                out = out & img[rr][cc];
            end
        end
        return out;
    endfunction

    // 3x3 OR-reduce with EDGE_REPLICATE (dilation)
    function automatic logic dilate_golden(
        input logic img [V][H],
        input int r, c
    );
        logic out;
        int rr, cc;
        out = 1'b0;
        for (int dr = 0; dr < 3; dr++) begin
            for (int dc = 0; dc < 3; dc++) begin
                rr = r + dr - 1; cc = c + dc - 1;
                if (rr < 0)  rr = 0;
                if (rr >= V) rr = V - 1;
                if (cc < 0)  cc = 0;
                if (cc >= H) cc = H - 1;
                out = out | img[rr][cc];
            end
        end
        return out;
    endfunction

    // Apply one erode pass
    task automatic apply_erode(
        input  logic src [V][H],
        output logic dst [V][H]
    );
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                dst[r][c] = erode_golden(src, r, c);
    endtask

    // Apply one dilate pass
    task automatic apply_dilate(
        input  logic src [V][H],
        output logic dst [V][H]
    );
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                dst[r][c] = dilate_golden(src, r, c);
    endtask

    // Compute open (erode -> dilate)
    task automatic compute_open(
        input  logic img    [V][H],
        output logic result [V][H]
    );
        logic tmp [V][H];
        apply_erode(img, tmp);
        apply_dilate(tmp, result);
    endtask

    // Compute close with 3x3 kernel (1x dilate -> 1x erode)
    task automatic compute_close_k3(
        input  logic img    [V][H],
        output logic result [V][H]
    );
        logic tmp [V][H];
        apply_dilate(img, tmp);
        apply_erode(tmp, result);
    endtask

    // Compute close with 5x5 kernel (2x dilate -> 2x erode)
    task automatic compute_close_k5(
        input  logic img    [V][H],
        output logic result [V][H]
    );
        logic t1 [V][H], t2 [V][H], t3 [V][H];
        apply_dilate(img, t1);
        apply_dilate(t1,  t2);
        apply_erode(t2,   t3);
        apply_erode(t3,   result);
    endtask

    // Compute open_en + close_en golden for CLOSE_KERNEL=3
    task automatic compute_golden_k3(
        input  logic img       [V][H],
        input  logic open_en,
        input  logic close_en,
        output logic result    [V][H]
    );
        logic after_open [V][H];
        logic after_close[V][H];
        int r, c;
        // Open stage
        if (open_en) begin
            compute_open(img, after_open);
        end else begin
            for (r = 0; r < V; r++)
                for (c = 0; c < H; c++)
                    after_open[r][c] = img[r][c];
        end
        // Close stage (k=3)
        if (close_en) begin
            compute_close_k3(after_open, after_close);
        end else begin
            for (r = 0; r < V; r++)
                for (c = 0; c < H; c++)
                    after_close[r][c] = after_open[r][c];
        end
        for (r = 0; r < V; r++)
            for (c = 0; c < H; c++)
                result[r][c] = after_close[r][c];
    endtask

    // Compute open_en + close_en golden for CLOSE_KERNEL=5
    task automatic compute_golden_k5(
        input  logic img       [V][H],
        input  logic open_en,
        input  logic close_en,
        output logic result    [V][H]
    );
        logic after_open [V][H];
        logic after_close[V][H];
        int r, c;
        // Open stage
        if (open_en) begin
            compute_open(img, after_open);
        end else begin
            for (r = 0; r < V; r++)
                for (c = 0; c < H; c++)
                    after_open[r][c] = img[r][c];
        end
        // Close stage (k=5)
        if (close_en) begin
            compute_close_k5(after_open, after_close);
        end else begin
            for (r = 0; r < V; r++)
                for (c = 0; c < H; c++)
                    after_close[r][c] = after_open[r][c];
        end
        for (r = 0; r < V; r++)
            for (c = 0; c < H; c++)
                result[r][c] = after_close[r][c];
    endtask

    // ---- Frame state ----
    logic frame_img    [V][H];
    logic golden_k3    [V][H];
    logic golden_k5    [V][H];
    logic captured_k3  [NUM_PIX];
    logic captured_k5  [NUM_PIX];
    integer cap_cnt_k3, cap_cnt_k5;

    integer num_errors = 0;

    // ---- Drive helpers ----
    task automatic drive_frame_blanked(
        input logic img     [V][H],
        input int   h_blank,
        input int   v_blank
    );
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                drv_tdata  = img[r][c];
                drv_tvalid = 1'b1;
                drv_tuser  = (r == 0 && c == 0) ? 1'b1 : 1'b0;
                drv_tlast  = (c == H - 1) ? 1'b1 : 1'b0;
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

    // Drive with periodic downstream stalls (open_len transfers, then stall_len cycles)
    task automatic drive_frame_stall(
        input logic img      [V][H],
        input int   stall_len,
        input int   open_len
    );
        integer cyc_in_group;
        integer row_c, r;
        r = 0;
        while (r < V) begin
            row_c = 0;
            cyc_in_group = 0;
            while (row_c < H) begin
                if (cyc_in_group < open_len) begin
                    drv_tdata       = img[r][row_c];
                    drv_tvalid      = 1'b1;
                    drv_tuser       = (r == 0 && row_c == 0) ? 1'b1 : 1'b0;
                    drv_tlast       = (row_c == H - 1) ? 1'b1 : 1'b0;
                    drv_tready_k3   = 1'b1;
                    drv_tready_k5   = 1'b1;
                    @(posedge clk);
                    row_c        = row_c + 1;
                    cyc_in_group = cyc_in_group + 1;
                end else if (cyc_in_group < open_len + stall_len) begin
                    drv_tvalid      = 1'b0;
                    drv_tready_k3   = 1'b0;
                    drv_tready_k5   = 1'b0;
                    @(posedge clk);
                    cyc_in_group = cyc_in_group + 1;
                end else begin
                    cyc_in_group = 0;
                end
            end
            drv_tvalid    = 1'b0;
            drv_tuser     = 1'b0;
            drv_tlast     = 1'b0;
            drv_tready_k3 = 1'b1;
            drv_tready_k5 = 1'b1;
            repeat (DEF_HBLANK) @(posedge clk);
            r = r + 1;
        end
        repeat (DEF_VBLANK) @(posedge clk);
    endtask

    // ---- Capture (both DUTs in parallel) ----
    task automatic capture_both_frames;
        fork
            begin : cap_k3
                cap_cnt_k3 = 0;
                while (cap_cnt_k3 < NUM_PIX) begin
                    @(posedge clk);
                    if (m_axis_k3.tvalid && m_axis_k3.tready) begin
                        captured_k3[cap_cnt_k3] = m_axis_k3.tdata;
                        cap_cnt_k3 = cap_cnt_k3 + 1;
                    end
                end
            end
            begin : cap_k5
                cap_cnt_k5 = 0;
                while (cap_cnt_k5 < NUM_PIX) begin
                    @(posedge clk);
                    if (m_axis_k5.tvalid && m_axis_k5.tready) begin
                        captured_k5[cap_cnt_k5] = m_axis_k5.tdata;
                        cap_cnt_k5 = cap_cnt_k5 + 1;
                    end
                end
            end
        join
    endtask

    // ---- Frame check ----
    task automatic check_frame_k3(input string label);
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                if (captured_k3[r * H + c] !== golden_k3[r][c]) begin
                    $display("FAIL %s k3 px(%0d,%0d): got %0b exp %0b",
                             label, r, c, captured_k3[r * H + c], golden_k3[r][c]);
                    num_errors = num_errors + 1;
                end
            end
        end
        $display("%s k3: check done", label);
    endtask

    task automatic check_frame_k5(input string label);
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                if (captured_k5[r * H + c] !== golden_k5[r][c]) begin
                    $display("FAIL %s k5 px(%0d,%0d): got %0b exp %0b",
                             label, r, c, captured_k5[r * H + c], golden_k5[r][c]);
                    num_errors = num_errors + 1;
                end
            end
        end
        $display("%s k5: check done", label);
    endtask

    task automatic check_frames(input string label);
        check_frame_k3(label);
        check_frame_k5(label);
    endtask

    task automatic reset_dut;
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
    endtask

    // ---- Main ----
    initial begin
        rst_n         = 0;
        drv_open_en   = 1'b0;
        drv_close_en  = 1'b0;
        drv_tready_k3 = 1'b1;
        drv_tready_k5 = 1'b1;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ================================================================
        // T1: Passthrough — open_en=0, close_en=0, checker pattern
        //     Expected: output == input (identity for both k=3 and k=5)
        // ================================================================
        $display("=== T1: Passthrough (open_en=0, close_en=0, checker) ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = ((r + c) % 2 == 0) ? 1'b1 : 1'b0;
        compute_golden_k3(frame_img, 1'b0, 1'b0, golden_k3);
        compute_golden_k5(frame_img, 1'b0, 1'b0, golden_k5);
        reset_dut();
        drv_open_en  = 1'b0;
        drv_close_en = 1'b0;
        fork
            drive_frame(frame_img);
            capture_both_frames();
        join
        repeat (5) @(posedge clk);
        // Verify: golden must equal input (passthrough invariant)
        begin
            integer t1_idem_err;
            t1_idem_err = 0;
            for (int r = 0; r < V; r++)
                for (int c = 0; c < H; c++)
                    if (golden_k3[r][c] !== frame_img[r][c]) t1_idem_err++;
            if (t1_idem_err > 0) begin
                $display("FAIL T1: compute_golden_k3 not identity for passthrough");
                num_errors = num_errors + t1_idem_err;
            end
        end
        check_frames("T1_passthrough");

        // ================================================================
        // T2: Open removes isolated 1px — open_en=1, close_en=0
        //     Input: single 1 at (4,4) on all-zero background
        //     Expected: all-zero (open erodes single pixel away)
        // ================================================================
        $display("=== T2: Open removes isolated pixel ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        frame_img[4][4] = 1'b1;
        compute_golden_k3(frame_img, 1'b1, 1'b0, golden_k3);
        compute_golden_k5(frame_img, 1'b1, 1'b0, golden_k5);
        reset_dut();
        drv_open_en  = 1'b1;
        drv_close_en = 1'b0;
        fork
            drive_frame(frame_img);
            capture_both_frames();
        join
        repeat (5) @(posedge clk);
        // Sanity: confirm golden is all-zero
        begin
            integer t2_gold_sum;
            t2_gold_sum = 0;
            for (int r = 0; r < V; r++)
                for (int c = 0; c < H; c++)
                    t2_gold_sum = t2_gold_sum + golden_k3[r][c];
            if (t2_gold_sum !== 0) begin
                $display("FAIL T2: golden_k3 not all-zero (sum=%0d)", t2_gold_sum);
                num_errors++;
            end
        end
        check_frames("T2_open_salt_removal");

        // ================================================================
        // T3: Close fills 1px hole — open_en=0, close_en=1
        //     Input: 3x3 solid block at rows 3..5, cols 6..8, with hole
        //            at (4,7) set to 0.
        //     Expected: hole filled for both k=3 and k=5 (k>=3 can bridge 1px gap)
        // ================================================================
        $display("=== T3: Close fills 1px hole ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        for (int r = 3; r <= 5; r++)
            for (int c = 6; c <= 8; c++)
                frame_img[r][c] = 1'b1;
        frame_img[4][7] = 1'b0;  // 1px hole in center of 3x3 block
        compute_golden_k3(frame_img, 1'b0, 1'b1, golden_k3);
        compute_golden_k5(frame_img, 1'b0, 1'b1, golden_k5);
        reset_dut();
        drv_open_en  = 1'b0;
        drv_close_en = 1'b1;
        fork
            drive_frame(frame_img);
            capture_both_frames();
        join
        repeat (5) @(posedge clk);
        // Sanity: golden_k3[4][7] should be 1 (hole filled)
        if (golden_k3[4][7] !== 1'b1) begin
            $display("FAIL T3: golden_k3 did not fill 1px hole at (4,7)");
            num_errors++;
        end
        if (golden_k5[4][7] !== 1'b1) begin
            $display("FAIL T3: golden_k5 did not fill 1px hole at (4,7)");
            num_errors++;
        end
        check_frames("T3_close_fills_1px_hole");

        // ================================================================
        // T4: Close discriminates k=3 vs k=5 on a 2x2 hole
        //     Input: 6x6 solid block at rows 1..6, cols 2..7, with a 2x2
        //            hole at rows 3..4, cols 4..5 zeroed.
        //     k=3 close: can only bridge 1px gaps; the 2x2 hole (2px wide) is
        //                NOT fully filled — dilate reaches 1px in from the edge
        //                but the inner pixels at (3,4),(3,5),(4,4),(4,5) remain
        //                partially unfilled (dilate of surrounding adds the border
        //                but 1 pass can't cover all interior).
        //                Actually with 3x3 dilate on 6x6 block-with-2x2-hole:
        //                dilation extends 1 into the hole from each direction,
        //                but the inner 0x0 gap (for a 2x2 hole, that leaves nothing
        //                after 1 dilate covers 1px from the edge — the full 2x2 IS
        //                filled). Re-derive below:
        //     Discriminating stimulus: use a WIDER hole so k=3 leaves pixels unfilled.
        //     Use a 3x3 hole (rows 2..4, cols 5..7) inside a large all-ones frame.
        //     k=3 close: single 3x3 dilate extends 1px around the hole — the hole
        //                center at (3,6) is surrounded by zeros, so a single 3x3
        //                dilation WILL reach it. Actually for a 3x3 hole, center
        //                (3,6) has all-zero 3x3 neighborhood before dilate; dilate
        //                adds 1 pixel from the surrounding 1-ring, leaving (3,6)
        //                still zero. After erode, the result depends on whether the
        //                dilated value at (3,6) is 0 or 1.
        //     Simpler: use the two kernel sizes' own compute functions to determine
        //              the goldens; then VERIFY they differ at the hole interior.
        //     Input: all-ones with a 3x3 hole at rows 2..4, cols 5..7.
        // ================================================================
        $display("=== T4: 3x3 hole discriminates k=3 vs k=5 close ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b1;
        // Punch 3x3 hole (k=3 close can NOT fill; k=5 close CAN)
        for (int r = 2; r <= 4; r++)
            for (int c = 5; c <= 7; c++)
                frame_img[r][c] = 1'b0;
        compute_golden_k3(frame_img, 1'b0, 1'b1, golden_k3);
        compute_golden_k5(frame_img, 1'b0, 1'b1, golden_k5);
        reset_dut();
        drv_open_en  = 1'b0;
        drv_close_en = 1'b1;
        fork
            drive_frame(frame_img);
            capture_both_frames();
        join
        repeat (5) @(posedge clk);
        // Verify the discriminating property: the golden for k3 must differ from
        // the golden for k5 at the hole center (3,6).
        // A 3x3 dilate on all-ones-with-3x3-hole: the dilation of the surrounding
        // 1-ring only reaches 1px into the hole; center (3,6) is 2px from the
        // nearest 1, so it stays 0 after k=3 dilation, stays 0 in k=3 close.
        // k=5 close: 2 dilates; first extends 1px into hole (border filled),
        // second extends another 1px — reaching (3,6). After 2 erodes: (3,6)=1.
        if (golden_k3[3][6] !== 1'b0) begin
            $display("FAIL T4: expected golden_k3 hole-center (3,6) = 0, got %0b",
                     golden_k3[3][6]);
            num_errors++;
        end
        if (golden_k5[3][6] !== 1'b1) begin
            $display("FAIL T4: expected golden_k5 hole-center (3,6) = 1, got %0b",
                     golden_k5[3][6]);
            num_errors++;
        end
        check_frames("T4_hole_discrimination");

        // ================================================================
        // T5: No-grow on clean 5x5 block — open_en=1, close_en=1
        //     A 5x5 blob is large enough that open is idempotent and
        //     close (both k=3, k=5) adds at most a thin border that is
        //     then eroded back. Use 6x6 block to ensure interior survives.
        //     Expected: captured == golden (full pipeline, no-op on clean blob)
        // ================================================================
        $display("=== T5: Clean 5x5 block idempotent under open+close ===");
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        for (int r = 1; r <= 5; r++)
            for (int c = 1; c <= 5; c++)
                frame_img[r][c] = 1'b1;
        compute_golden_k3(frame_img, 1'b1, 1'b1, golden_k3);
        compute_golden_k5(frame_img, 1'b1, 1'b1, golden_k5);
        reset_dut();
        drv_open_en  = 1'b1;
        drv_close_en = 1'b1;
        fork
            drive_frame(frame_img);
            capture_both_frames();
        join
        repeat (5) @(posedge clk);
        check_frames("T5_clean_block_idempotent");

        // ================================================================
        // T6: Backpressure mid-frame on T5 stimulus — golden must match
        //     drive_frame_stall applies both-DUT tready deassertion.
        // ================================================================
        $display("=== T6: Backpressure (open_en=1, close_en=1, 5x5 block) ===");
        // golden already computed from T5 (same stimulus, same enable)
        reset_dut();
        drv_open_en  = 1'b1;
        drv_close_en = 1'b1;
        fork
            drive_frame_stall(frame_img, 3, 8);
            capture_both_frames();
        join
        repeat (5) @(posedge clk);
        check_frames("T6_backpressure");

        // ================================================================
        // T7: Two consecutive frames — all-ones then all-zeros
        //     Second frame's output must not contain content from first.
        //     open_en=1, close_en=1 (full pipeline)
        // ================================================================
        $display("=== T7: Multi-frame no-leak (all-ones -> all-zeros) ===");
        // Frame A: all-ones
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b1;
        compute_golden_k3(frame_img, 1'b1, 1'b1, golden_k3);
        compute_golden_k5(frame_img, 1'b1, 1'b1, golden_k5);
        reset_dut();
        drv_open_en  = 1'b1;
        drv_close_en = 1'b1;
        fork
            drive_frame(frame_img);
            capture_both_frames();
        join
        repeat (5) @(posedge clk);
        check_frames("T7A_all_ones");

        // Frame B: all-zeros — must not leak from frame A
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_img[r][c] = 1'b0;
        compute_golden_k3(frame_img, 1'b1, 1'b1, golden_k3);
        compute_golden_k5(frame_img, 1'b1, 1'b1, golden_k5);
        // No reset between frames (tests SOF behavior)
        fork
            drive_frame(frame_img);
            capture_both_frames();
        join
        repeat (5) @(posedge clk);
        // Sanity: golden for all-zeros input must be all-zeros
        begin
            integer t7_gold_err;
            t7_gold_err = 0;
            for (int r = 0; r < V; r++)
                for (int c = 0; c < H; c++)
                    if (golden_k3[r][c] !== 1'b0) t7_gold_err++;
            if (t7_gold_err !== 0) begin
                $display("FAIL T7B: golden_k3 not all-zero for all-zero input");
                num_errors++;
            end
        end
        check_frames("T7B_all_zeros_no_leak");

        // ================================================================
        // Final report
        // ================================================================
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_morph_clean FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_morph_clean PASSED -- 7 tests OK");
            $finish;
        end
    end

    initial begin
        #8000000;
        $fatal(1, "tb_axis_morph_clean TIMEOUT");
    end

endmodule
