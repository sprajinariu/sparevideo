// Unit testbench for axis_bbox_reduce.
//
// Tests:
//   T1  — known active region (existing)
//   T2  — all-zero mask (existing)
//   T3  — single-pixel motion
//   T4  — full-frame motion
//   T5  — corner pixels only
//   T6  — single-row motion (row 0)
//   T7  — single-column motion (col H-1)
//   T8  — larger frame (8×8) scattered pattern
//   T9  — SOF resets scratch: two consecutive frames, second must not inherit first bbox

`timescale 1ns / 1ps

module tb_axis_bbox_reduce;

    // Default frame size for most tests
    localparam int H     = 4;
    localparam int V     = 4;
    localparam int NP    = H * V;       // 16 pixels
    localparam int CLK_PERIOD = 10;

    // Larger frame for T8
    localparam int H8    = 8;
    localparam int V8    = 8;
    localparam int NP8   = H8 * V8;    // 64 pixels

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    logic rst_n;

    // ---- Driver intermediaries ----
    logic drv_tdata  = 1'b0;
    logic drv_tvalid = 1'b0;
    logic drv_tlast  = 1'b0;
    logic drv_tuser  = 1'b0;

    logic s_tdata, s_tvalid, s_tready, s_tlast, s_tuser;

    always_ff @(posedge clk) begin
        s_tdata  <= drv_tdata;
        s_tvalid <= drv_tvalid;
        s_tlast  <= drv_tlast;
        s_tuser  <= drv_tuser;
    end

    // ---- DUT outputs (sized for default H/V) ----
    logic [$clog2(H)-1:0] bbox_min_x, bbox_max_x;
    logic [$clog2(V)-1:0] bbox_min_y, bbox_max_y;
    logic                 bbox_valid, bbox_empty;

    axis_bbox_reduce #(.H_ACTIVE(H), .V_ACTIVE(V)) u_dut (
        .clk_i           (clk),
        .rst_n_i         (rst_n),
        .s_axis_tdata_i  (s_tdata),
        .s_axis_tvalid_i (s_tvalid),
        .s_axis_tready_o (s_tready),
        .s_axis_tlast_i  (s_tlast),
        .s_axis_tuser_i  (s_tuser),
        .bbox_min_x_o    (bbox_min_x),
        .bbox_max_x_o    (bbox_max_x),
        .bbox_min_y_o    (bbox_min_y),
        .bbox_max_y_o    (bbox_max_y),
        .bbox_valid_o    (bbox_valid),
        .bbox_empty_o    (bbox_empty)
    );

    // ---- DUT8 for larger frame tests ----
    logic [$clog2(H8)-1:0] bbox8_min_x, bbox8_max_x;
    logic [$clog2(V8)-1:0] bbox8_min_y, bbox8_max_y;
    logic                   bbox8_valid, bbox8_empty;

    axis_bbox_reduce #(.H_ACTIVE(H8), .V_ACTIVE(V8)) u_dut8 (
        .clk_i           (clk),
        .rst_n_i         (rst_n),
        .s_axis_tdata_i  (s_tdata),
        .s_axis_tvalid_i (s_tvalid),
        .s_axis_tready_o (),     // dut8 tready discarded (both always-ready)
        .s_axis_tlast_i  (s_tlast),
        .s_axis_tuser_i  (s_tuser),
        .bbox_min_x_o    (bbox8_min_x),
        .bbox_max_x_o    (bbox8_max_x),
        .bbox_min_y_o    (bbox8_min_y),
        .bbox_max_y_o    (bbox8_max_y),
        .bbox_valid_o    (bbox8_valid),
        .bbox_empty_o    (bbox8_empty)
    );

    integer num_errors = 0;

    // Shared mask data — populated before calling drive_frame4 / drive_frame8.
    logic mask4 [NP];
    logic mask8 [NP8];

    // Drive a 4×4 frame from mask4[].
    task automatic drive_frame4;
        integer r, c, idx;
        for (r = 0; r < V; r = r + 1) begin
            for (c = 0; c < H; c = c + 1) begin
                idx        = r * H + c;
                drv_tdata  = mask4[idx];
                drv_tvalid = 1'b1;
                drv_tlast  = (c == H - 1) ? 1'b1 : 1'b0;
                drv_tuser  = (r == 0 && c == 0) ? 1'b1 : 1'b0;
                @(posedge clk);
            end
        end
        drv_tvalid = 1'b0;
        drv_tlast  = 1'b0;
        drv_tuser  = 1'b0;
    endtask

    // Drive an 8×8 frame from mask8[].
    task automatic drive_frame8;
        integer r, c, idx;
        for (r = 0; r < V8; r = r + 1) begin
            for (c = 0; c < H8; c = c + 1) begin
                idx        = r * H8 + c;
                drv_tdata  = mask8[idx];
                drv_tvalid = 1'b1;
                drv_tlast  = (c == H8 - 1) ? 1'b1 : 1'b0;
                drv_tuser  = (r == 0 && c == 0) ? 1'b1 : 1'b0;
                @(posedge clk);
            end
        end
        drv_tvalid = 1'b0;
        drv_tlast  = 1'b0;
        drv_tuser  = 1'b0;
    endtask

    task automatic wait_bbox_valid4(output logic timed_out);
        integer t;
        t = 0; timed_out = 1'b0;
        while (!bbox_valid && t < 200) begin
            @(posedge clk);
            t = t + 1;
        end
        if (t >= 200) timed_out = 1'b1;
    endtask

    task automatic wait_bbox_valid8(output logic timed_out);
        integer t;
        t = 0; timed_out = 1'b0;
        while (!bbox8_valid && t < 500) begin
            @(posedge clk);
            t = t + 1;
        end
        if (t >= 500) timed_out = 1'b1;
    endtask

    task automatic check4(
        input string  label,
        input logic   exp_empty,
        input integer exp_min_x,
        input integer exp_max_x,
        input integer exp_min_y,
        input integer exp_max_y
    );
        logic to;
        wait_bbox_valid4(to);
        if (to) begin
            $display("FAIL %s: bbox_valid never asserted", label);
            num_errors = num_errors + 1;
            return;
        end
        if (bbox_empty !== exp_empty) begin
            $display("FAIL %s: bbox_empty=%0b exp %0b", label, bbox_empty, exp_empty);
            num_errors = num_errors + 1;
        end
        if (!exp_empty) begin
            if (bbox_min_x !== exp_min_x || bbox_max_x !== exp_max_x ||
                bbox_min_y !== exp_min_y || bbox_max_y !== exp_max_y) begin
                $display("FAIL %s: bbox=(%0d,%0d)-(%0d,%0d) exp (%0d,%0d)-(%0d,%0d)",
                         label,
                         bbox_min_x, bbox_min_y, bbox_max_x, bbox_max_y,
                         exp_min_x,  exp_min_y,  exp_max_x,  exp_max_y);
                num_errors = num_errors + 1;
            end else begin
                $display("PASS %s: bbox=(%0d,%0d)-(%0d,%0d)",
                         label, bbox_min_x, bbox_min_y, bbox_max_x, bbox_max_y);
            end
        end else begin
            $display("PASS %s: bbox_empty=1", label);
        end
    endtask

    task automatic check8(
        input string  label,
        input logic   exp_empty,
        input integer exp_min_x,
        input integer exp_max_x,
        input integer exp_min_y,
        input integer exp_max_y
    );
        logic to;
        wait_bbox_valid8(to);
        if (to) begin
            $display("FAIL %s: bbox8_valid never asserted", label);
            num_errors = num_errors + 1;
            return;
        end
        if (bbox8_empty !== exp_empty) begin
            $display("FAIL %s: bbox8_empty=%0b exp %0b", label, bbox8_empty, exp_empty);
            num_errors = num_errors + 1;
        end
        if (!exp_empty) begin
            if (bbox8_min_x !== exp_min_x || bbox8_max_x !== exp_max_x ||
                bbox8_min_y !== exp_min_y || bbox8_max_y !== exp_max_y) begin
                $display("FAIL %s: bbox=(%0d,%0d)-(%0d,%0d) exp (%0d,%0d)-(%0d,%0d)",
                         label,
                         bbox8_min_x, bbox8_min_y, bbox8_max_x, bbox8_max_y,
                         exp_min_x,   exp_min_y,   exp_max_x,   exp_max_y);
                num_errors = num_errors + 1;
            end else begin
                $display("PASS %s: bbox=(%0d,%0d)-(%0d,%0d)",
                         label, bbox8_min_x, bbox8_min_y, bbox8_max_x, bbox8_max_y);
            end
        end else begin
            $display("PASS %s: bbox_empty=1", label);
        end
    endtask

    integer i;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ==================================================================
        // T1 — known active region
        //   row 0: 0 0 0 0
        //   row 1: 0 1 1 0
        //   row 2: 0 0 1 0
        //   row 3: 0 0 0 0
        //   Expected: min_x=1, max_x=2, min_y=1, max_y=2
        // ==================================================================
        $display("--- T1: known active region ---");
        for (i = 0; i < NP; i = i + 1) mask4[i] = 1'b0;
        mask4[5]  = 1'b1;  // (row=1,col=1)
        mask4[6]  = 1'b1;  // (row=1,col=2)
        mask4[10] = 1'b1;  // (row=2,col=2)
        drive_frame4();
        check4("T1", 1'b0, 1, 2, 1, 2);
        repeat (4) @(posedge clk);

        // ==================================================================
        // T2 — all-zero mask → bbox_empty
        // ==================================================================
        $display("--- T2: all-zero mask ---");
        for (i = 0; i < NP; i = i + 1) mask4[i] = 1'b0;
        drive_frame4();
        check4("T2", 1'b1, 0, 0, 0, 0);
        repeat (4) @(posedge clk);

        // ==================================================================
        // T3 — single-pixel motion at (row=2, col=1)
        //   Expected: min_x=1, max_x=1, min_y=2, max_y=2
        // ==================================================================
        $display("--- T3: single-pixel motion ---");
        for (i = 0; i < NP; i = i + 1) mask4[i] = 1'b0;
        mask4[2*H+1] = 1'b1;  // row=2, col=1
        drive_frame4();
        check4("T3", 1'b0, 1, 1, 2, 2);
        repeat (4) @(posedge clk);

        // ==================================================================
        // T4 — full-frame motion
        //   Expected: min_x=0, max_x=H-1, min_y=0, max_y=V-1
        // ==================================================================
        $display("--- T4: full-frame motion ---");
        for (i = 0; i < NP; i = i + 1) mask4[i] = 1'b1;
        drive_frame4();
        check4("T4", 1'b0, 0, H-1, 0, V-1);
        repeat (4) @(posedge clk);

        // ==================================================================
        // T5 — corners only: (0,0) and (V-1,H-1)
        //   Expected: bbox spans entire frame
        // ==================================================================
        $display("--- T5: corner pixels only ---");
        for (i = 0; i < NP; i = i + 1) mask4[i] = 1'b0;
        mask4[0]          = 1'b1;  // row=0, col=0
        mask4[(V-1)*H+(H-1)] = 1'b1;  // row=V-1, col=H-1
        drive_frame4();
        check4("T5", 1'b0, 0, H-1, 0, V-1);
        repeat (4) @(posedge clk);

        // ==================================================================
        // T6 — single-row motion (all cols in row 0)
        //   Expected: min_y=0, max_y=0, min_x=0, max_x=H-1
        // ==================================================================
        $display("--- T6: single-row motion ---");
        for (i = 0; i < NP; i = i + 1) mask4[i] = 1'b0;
        for (i = 0; i < H; i = i + 1) mask4[i] = 1'b1;  // row=0
        drive_frame4();
        check4("T6", 1'b0, 0, H-1, 0, 0);
        repeat (4) @(posedge clk);

        // ==================================================================
        // T7 — single-column motion (all rows in col H-1)
        //   Expected: min_x=H-1, max_x=H-1, min_y=0, max_y=V-1
        // ==================================================================
        $display("--- T7: single-column motion ---");
        for (i = 0; i < NP; i = i + 1) mask4[i] = 1'b0;
        for (i = 0; i < V; i = i + 1) mask4[i*H + (H-1)] = 1'b1;
        drive_frame4();
        check4("T7", 1'b0, H-1, H-1, 0, V-1);
        repeat (4) @(posedge clk);

        // ==================================================================
        // T8 — 8×8 frame, scattered pattern
        //   Active pixels: (row=1,col=2), (row=4,col=6), (row=6,col=3)
        //   Expected: min_x=2, max_x=6, min_y=1, max_y=6
        // ==================================================================
        $display("--- T8: 8x8 scattered pattern ---");
        for (i = 0; i < NP8; i = i + 1) mask8[i] = 1'b0;
        mask8[1*H8+2] = 1'b1;  // (row=1,col=2)
        mask8[4*H8+6] = 1'b1;  // (row=4,col=6)
        mask8[6*H8+3] = 1'b1;  // (row=6,col=3)
        drive_frame8();
        check8("T8", 1'b0, 2, 6, 1, 6);
        repeat (4) @(posedge clk);

        // ==================================================================
        // T9 — SOF reset: two frames back-to-back on 4x4 DUT
        //   Frame A: motion at (0,0)-(1,1) (rows 0-1, cols 0-1)
        //   Frame B: motion at (3,3) only
        //   Expected after frame B: bbox = (3,3)-(3,3), NOT spanning frame A region
        // ==================================================================
        $display("--- T9: SOF resets scratch between frames ---");
        // Frame A
        for (i = 0; i < NP; i = i + 1) mask4[i] = 1'b0;
        mask4[0*H+0] = 1'b1;
        mask4[0*H+1] = 1'b1;
        mask4[1*H+0] = 1'b1;
        mask4[1*H+1] = 1'b1;
        drive_frame4();
        begin
            logic to;
            wait_bbox_valid4(to);  // consume frame A result
        end
        repeat (2) @(posedge clk);
        // Frame B
        for (i = 0; i < NP; i = i + 1) mask4[i] = 1'b0;
        mask4[3*H+3] = 1'b1;  // (row=3,col=3)
        drive_frame4();
        check4("T9", 1'b0, 3, 3, 3, 3);

        // ==================================================================
        // Summary
        // ==================================================================
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_bbox_reduce FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_bbox_reduce PASSED — all tests OK");
            $finish;
        end
    end

endmodule
