// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_hflip.
//
// Tests:
//   T1 -- enable_i=1, gradient ramp: output is exactly the input mirrored
//         left-to-right, line by line, frame by frame.
//   T2 -- enable_i=1, multi-frame: two distinct frames; second frame's
//         first-line tuser asserts on the first XMIT pixel of frame 2.
//   T3 -- enable_i=1, downstream stall in the middle of XMIT: output is
//         identical to the no-stall reference (golden mirror).
//   T4 -- enable_i=1, mid-RECV upstream pause (tvalid=0): output unchanged.
//   T5 -- enable_i=0 passthrough: input emerges combinationally on the
//         output with zero latency and no mirror.

`timescale 1ns / 1ps

module tb_axis_hflip;

    localparam int H          = 8;
    localparam int V          = 4;
    localparam int CLK_PERIOD = 10;
    localparam int H_BLANK    = 4;
    localparam int V_BLANK    = H + 8;

    logic clk = 0;
    logic rst_n = 0;
    logic enable;

    // drv_* intermediaries (blocking writes from initial)
    logic [23:0] drv_tdata  = '0;
    logic        drv_tvalid = 1'b0;
    logic        drv_tlast  = 1'b0;
    logic        drv_tuser  = 1'b0;

    // DUT inputs (driven on negedge)
    logic [23:0] s_tdata;
    logic        s_tvalid;
    logic        s_tready;
    logic        s_tlast;
    logic        s_tuser;

    always_ff @(negedge clk) begin
        s_tdata  <= drv_tdata;
        s_tvalid <= drv_tvalid;
        s_tlast  <= drv_tlast;
        s_tuser  <= drv_tuser;
    end

    logic [23:0] m_tdata;
    logic        m_tvalid;
    logic        m_tready = 1'b1;
    logic        m_tlast;
    logic        m_tuser;

    axis_hflip #(
        .H_ACTIVE (H),
        .V_ACTIVE (V)
    ) dut (
        .clk_i           (clk),
        .rst_n_i         (rst_n),
        .enable_i        (enable),
        .s_axis_tdata_i  (s_tdata),
        .s_axis_tvalid_i (s_tvalid),
        .s_axis_tready_o (s_tready),
        .s_axis_tlast_i  (s_tlast),
        .s_axis_tuser_i  (s_tuser),
        .m_axis_tdata_o  (m_tdata),
        .m_axis_tvalid_o (m_tvalid),
        .m_axis_tready_i (m_tready),
        .m_axis_tlast_o  (m_tlast),
        .m_axis_tuser_o  (m_tuser)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- Capture: store every accepted output beat in a (V, H) array ----
    logic [23:0] cap_tdata [V][H];
    logic        cap_tlast [V][H];
    logic        cap_tuser [V][H];
    int          cap_row, cap_col;

    task automatic clear_capture;
        begin
            for (int r = 0; r < V; r++)
                for (int c = 0; c < H; c++) begin
                    cap_tdata[r][c] = '0;
                    cap_tlast[r][c] = 1'b0;
                    cap_tuser[r][c] = 1'b0;
                end
            cap_row = 0;
            cap_col = 0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            cap_tdata[cap_row][cap_col] <= m_tdata;
            cap_tlast[cap_row][cap_col] <= m_tlast;
            cap_tuser[cap_row][cap_col] <= m_tuser;
            if (cap_col == H - 1) begin
                cap_col <= 0;
                if (cap_row == V - 1)
                    cap_row <= 0;
                else
                    cap_row <= cap_row + 1;
            end else begin
                cap_col <= cap_col + 1;
            end
        end
    end

    // ---- Helpers ----
    task automatic drive_frame(input logic [23:0] pixels [V][H]);
        begin
            for (int r = 0; r < V; r++) begin
                for (int c = 0; c < H; c++) begin
                    drv_tdata  = pixels[r][c];
                    drv_tvalid = 1'b1;
                    drv_tlast  = (c == H - 1);
                    drv_tuser  = (r == 0) && (c == 0);
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);
                end
                drv_tvalid = 1'b0;
                drv_tlast  = 1'b0;
                drv_tuser  = 1'b0;
                for (int b = 0; b < H_BLANK; b++) @(posedge clk);
            end
            for (int b = 0; b < V_BLANK; b++) @(posedge clk);
        end
    endtask

    task automatic check_mirror(input logic [23:0] pixels [V][H], input string label);
        begin
            for (int r = 0; r < V; r++) begin
                for (int c = 0; c < H; c++) begin
                    if (cap_tdata[r][c] !== pixels[r][H-1-c]) begin
                        $display("FAIL %s @(r=%0d, c=%0d): got %06h, want %06h",
                                 label, r, c, cap_tdata[r][c], pixels[r][H-1-c]);
                        $fatal(1);
                    end
                end
                if (!cap_tlast[r][H-1]) begin
                    $display("FAIL %s: missing tlast at r=%0d c=%0d", label, r, H-1);
                    $fatal(1);
                end
            end
            if (!cap_tuser[0][0]) begin
                $display("FAIL %s: missing tuser at output (0,0)", label);
                $fatal(1);
            end
        end
    endtask

    // ---- Stimulus ----
    initial begin
        logic [23:0] frame_a [V][H];
        logic [23:0] frame_b [V][H];

        m_tready = 1'b1;
        enable   = 1'b1;
        #(CLK_PERIOD*3);
        rst_n = 1'b1;
        #(CLK_PERIOD*2);

        // T1: gradient ramp
        $display("T1: gradient mirror");
        clear_capture();
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_a[r][c] = 24'(r * 32 + c * 4);
        drive_frame(frame_a);
        check_mirror(frame_a, "T1");

        // T2: multi-frame -- second frame must produce its own SOF
        $display("T2: two distinct frames, SOF at frame boundary");
        clear_capture();
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_b[r][c] = 24'hAA0000 | 24'(r * 16 + c);
        drive_frame(frame_a);
        // After frame A drains, capture buffers reset implicitly by overwrite
        clear_capture();
        drive_frame(frame_b);
        check_mirror(frame_b, "T2");

        // T3: downstream stall mid-XMIT
        $display("T3: downstream stall mid-XMIT");
        clear_capture();
        fork
            drive_frame(frame_a);
            begin
                // Hold m_tready low for a brief window in the middle of the
                // first XMIT phase, then release. Output count must remain V*H.
                for (int b = 0; b < H * 3; b++) @(posedge clk);
                m_tready = 1'b0;
                for (int b = 0; b < 5; b++)         @(posedge clk);
                m_tready = 1'b1;
            end
        join
        check_mirror(frame_a, "T3");

        // T4: mid-RECV upstream pause -- TB drops drv_tvalid for a few cycles
        // mid-line (drive_frame already does this implicitly between rows; here
        // we additionally insert a single in-row pause).
        $display("T4: in-row upstream tvalid bubble");
        clear_capture();
        begin
            for (int r = 0; r < V; r++) begin
                for (int c = 0; c < H; c++) begin
                    drv_tdata  = frame_a[r][c];
                    drv_tvalid = 1'b1;
                    drv_tlast  = (c == H - 1);
                    drv_tuser  = (r == 0) && (c == 0);
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);
                    // Insert a 1-cycle bubble after each accepted mid-row pixel
                    if (c == H/2) begin
                        drv_tvalid = 1'b0;
                        @(posedge clk);
                    end
                end
                drv_tvalid = 1'b0;
                drv_tlast  = 1'b0;
                drv_tuser  = 1'b0;
                for (int b = 0; b < H_BLANK; b++) @(posedge clk);
            end
            for (int b = 0; b < V_BLANK; b++) @(posedge clk);
        end
        check_mirror(frame_a, "T4");

        // T5: enable_i = 0 passthrough -- output equals input, no mirror.
        $display("T5: enable_i=0 passthrough");
        enable = 1'b0;
        clear_capture();
        drive_frame(frame_a);
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                if (cap_tdata[r][c] !== frame_a[r][c]) begin
                    $display("FAIL T5 @(r=%0d, c=%0d): got %06h, want %06h",
                             r, c, cap_tdata[r][c], frame_a[r][c]);
                    $fatal(1);
                end
            end
        end
        enable = 1'b1;

        $display("ALL HFLIP TESTS PASSED");
        $finish;
    end

    // Timeout watchdog: catches skeleton tie-off (s_tready=0 → drive_frame hangs)
    initial begin
        #2000000;
        $fatal(1, "FAIL tb_axis_hflip TIMEOUT");
    end

endmodule
