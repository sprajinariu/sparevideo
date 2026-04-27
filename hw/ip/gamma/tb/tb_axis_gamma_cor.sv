// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_gamma_cor.
//
// Tests:
//   T1 -- enable_i=1, endpoint pixels (0, 128, 255) match hand-computed expectations.
//   T2 -- enable_i=1, 16-pixel ramp at p=i*16 (i=0..15) matches per-pixel hand expectations.
//   T3 -- enable_i=1, mid-line m_axis.tready stall; output count + values unchanged.
//   T4 -- enable_i=0, passthrough: output == input (zero added latency).
//
// Expected outputs computed from py/gen_gamma_lut.py + the per-pixel formula
// (LUT[addr]*(8-frac) + LUT[addr+1]*frac) >> 3.

`timescale 1ns / 1ps

module tb_axis_gamma_cor;

    localparam int CLK_PERIOD = 10;

    logic clk = 0;
    logic rst_n = 0;
    logic enable;

    logic [23:0] drv_tdata    = '0;
    logic        drv_tvalid   = 1'b0;
    logic        drv_tlast    = 1'b0;
    logic        drv_tuser    = 1'b0;
    logic        drv_m_tready = 1'b1;

    axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();
    axis_if #(.DATA_W(24), .USER_W(1)) m_axis ();

    always_ff @(negedge clk) begin
        s_axis.tdata  <= drv_tdata;
        s_axis.tvalid <= drv_tvalid;
        s_axis.tlast  <= drv_tlast;
        s_axis.tuser  <= drv_tuser;
    end

    assign m_axis.tready = drv_m_tready;

    axis_gamma_cor dut (
        .clk_i    (clk),
        .rst_n_i  (rst_n),
        .enable_i (enable),
        .s_axis   (s_axis),
        .m_axis   (m_axis)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Capture every accepted output beat
    logic [23:0] cap [256];
    int          cap_n;

    always_ff @(posedge clk) begin
        if (rst_n && m_axis.tvalid && m_axis.tready) begin
            cap[cap_n] <= m_axis.tdata;
            cap_n      <= cap_n + 1;
        end
    end

    task automatic drive_beat(input logic [23:0] data, input logic last, input logic user);
        begin
            drv_tdata  = data;
            drv_tvalid = 1'b1;
            drv_tlast  = last;
            drv_tuser  = user;
            @(posedge clk);
            while (!s_axis.tready) @(posedge clk);
            drv_tvalid = 1'b0;
            drv_tlast  = 1'b0;
            drv_tuser  = 1'b0;
        end
    endtask

    task automatic clear_capture;
        begin
            cap_n = 0;
            for (int i = 0; i < 256; i++) cap[i] = 24'h0;
        end
    endtask

    // Hand-computed expected outputs (see header comment).
    // T1: endpoints
    localparam logic [7:0] EXP_0   = 8'd0;
    localparam logic [7:0] EXP_128 = 8'd188;
    localparam logic [7:0] EXP_255 = 8'd254;
    // T2: ramp at p = i*16 for i=0..15
    localparam logic [7:0] T2_EXP [16] = '{
        8'd  0, 8'd 71, 8'd 99, 8'd120, 8'd137, 8'd152, 8'd165, 8'd177,
        8'd188, 8'd198, 8'd208, 8'd216, 8'd225, 8'd233, 8'd241, 8'd248
    };

    initial begin
        drv_m_tready = 1'b1;
        enable       = 1'b1;
        clear_capture();
        #(CLK_PERIOD*3);
        rst_n = 1'b1;
        #(CLK_PERIOD*2);

        // ---- T1: endpoint pixels ----
        $display("T1: endpoints");
        drive_beat({8'd0,   8'd0,   8'd0  }, 1'b1, 1'b1);
        drive_beat({8'd128, 8'd128, 8'd128}, 1'b1, 1'b0);
        drive_beat({8'd255, 8'd255, 8'd255}, 1'b1, 1'b0);
        for (int i = 0; i < 8; i++) @(posedge clk);
        if (cap_n != 3) $fatal(1, "T1 FAIL: cap_n=%0d (want 3)", cap_n);
        if (cap[0] !== {EXP_0,   EXP_0,   EXP_0  }) $fatal(1, "T1 FAIL [0]: got %06h", cap[0]);
        if (cap[1] !== {EXP_128, EXP_128, EXP_128}) $fatal(1, "T1 FAIL [1]: got %06h", cap[1]);
        if (cap[2] !== {EXP_255, EXP_255, EXP_255}) $fatal(1, "T1 FAIL [2]: got %06h", cap[2]);

        // ---- T2: 16-pixel ramp ----
        $display("T2: ramp p=0,16,...,240");
        clear_capture();
        for (int i = 0; i < 16; i++) begin
            logic [7:0] p = 8'(i * 16);
            drive_beat({p, p, p}, (i == 15), (i == 0));
        end
        for (int i = 0; i < 8; i++) @(posedge clk);
        if (cap_n != 16) $fatal(1, "T2 FAIL: cap_n=%0d (want 16)", cap_n);
        for (int i = 0; i < 16; i++) begin
            if (cap[i] !== {T2_EXP[i], T2_EXP[i], T2_EXP[i]})
                $fatal(1, "T2 FAIL [%0d]: got %06h, want %06h",
                       i, cap[i], {T2_EXP[i], T2_EXP[i], T2_EXP[i]});
        end

        // ---- T3: mid-line m_axis.tready stall ----
        $display("T3: mid-line tready stall");
        clear_capture();
        fork
            begin
                for (int i = 0; i < 16; i++) begin
                    logic [7:0] p = 8'(i * 16);
                    drive_beat({p, p, p}, (i == 15), (i == 0));
                end
            end
            begin
                // Stall the consumer for 5 cycles in the middle of the line.
                // #1 after each posedge so drv_m_tready transitions land
                // strictly between posedges (avoids race with the capture
                // always_ff and the DUT's combinational stage_advance).
                for (int i = 0; i < 8; i++) @(posedge clk);
                #1 drv_m_tready = 1'b0;
                for (int i = 0; i < 5; i++) @(posedge clk);
                #1 drv_m_tready = 1'b1;
            end
        join
        for (int i = 0; i < 8; i++) @(posedge clk);
        if (cap_n != 16) $fatal(1, "T3 FAIL: cap_n=%0d (want 16)", cap_n);
        for (int i = 0; i < 16; i++) begin
            if (cap[i] !== {T2_EXP[i], T2_EXP[i], T2_EXP[i]})
                $fatal(1, "T3 FAIL [%0d]: got %06h, want %06h",
                       i, cap[i], {T2_EXP[i], T2_EXP[i], T2_EXP[i]});
        end

        // ---- T4: enable_i=0 passthrough ----
        $display("T4: enable_i=0 passthrough");
        enable = 1'b0;
        clear_capture();
        drive_beat({8'd17, 8'd34, 8'd51}, 1'b1, 1'b1);
        @(posedge clk);
        if (cap[0] !== {8'd17, 8'd34, 8'd51})
            $fatal(1, "T4 FAIL: got %06h, want 112233", cap[0]);
        enable = 1'b1;

        $display("ALL GAMMA TESTS PASSED");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "FAIL tb_axis_gamma_cor TIMEOUT");
    end

endmodule
