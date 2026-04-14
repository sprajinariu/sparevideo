// Unit testbench for axis_overlay_bbox.
//
// Statically holds bbox = (1,1)-(2,2) on a 4x4 frame of solid red pixels.
// Checks that the 4 rectangle edges come out as BBOX_COLOR (green) and
// every other pixel is unchanged (red passthrough).

`timescale 1ns / 1ps

module tb_axis_overlay_bbox;

    localparam int H = 4;
    localparam int V = 4;
    localparam int NUM_PIX = H * V;
    localparam int CLK_PERIOD = 10;
    localparam logic [23:0] BG_COLOR   = 24'hFF_00_00; // red
    localparam logic [23:0] BBOX_COLOR = 24'h00_FF_00; // green

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    logic rst_n;

    // ---- Driver intermediaries ----
    logic [23:0] drv_tdata  = '0;
    logic        drv_tvalid = 1'b0;
    logic        drv_tlast  = 1'b0;
    logic        drv_tuser  = 1'b0;

    logic [23:0] s_tdata;
    logic        s_tvalid, s_tready, s_tlast, s_tuser;

    always_ff @(posedge clk) begin
        s_tdata  <= drv_tdata;
        s_tvalid <= drv_tvalid;
        s_tlast  <= drv_tlast;
        s_tuser  <= drv_tuser;
    end

    // ---- DUT outputs ----
    logic [23:0] m_tdata;
    logic        m_tvalid, m_tready, m_tlast, m_tuser;

    assign m_tready = 1'b1;

    axis_overlay_bbox #(
        .H_ACTIVE   (H),
        .V_ACTIVE   (V),
        .BBOX_COLOR (BBOX_COLOR)
    ) u_dut (
        .clk_i           (clk),
        .rst_n_i         (rst_n),
        .s_axis_tdata_i  (s_tdata),
        .s_axis_tvalid_i (s_tvalid),
        .s_axis_tready_o (s_tready),
        .s_axis_tlast_i  (s_tlast),
        .s_axis_tuser_i  (s_tuser),
        .m_axis_tdata_o  (m_tdata),
        .m_axis_tvalid_o (m_tvalid),
        .m_axis_tready_i (m_tready),
        .m_axis_tlast_o  (m_tlast),
        .m_axis_tuser_o  (m_tuser),
        .bbox_min_x_i (2'(1)),
        .bbox_max_x_i (2'(2)),
        .bbox_min_y_i (2'(1)),
        .bbox_max_y_i (2'(2)),
        .bbox_empty_i (1'b0)
    );

    integer num_errors = 0;

    // Expected output per pixel (row-major):
    // Row 0: R R R R        (no overlap)
    // Row 1: R G G R        (top edge of bbox at cols 1-2)
    // Row 2: R G G R        (bottom edge of bbox at cols 1-2)
    // Row 3: R R R R        (no overlap)
    //
    // Note: bbox is (1,1)-(2,2). The rectangle edge pixels are:
    //   top:    row=1, col=1..2
    //   bottom: row=2, col=1..2
    //   left:   col=1, row=1..2 (already covered by top/bottom)
    //   right:  col=2, row=1..2 (already covered by top/bottom)

    logic [23:0] expected [NUM_PIX];
    initial begin
        // Default: all background
        expected[0]  = BG_COLOR;  expected[1]  = BG_COLOR;
        expected[2]  = BG_COLOR;  expected[3]  = BG_COLOR;
        expected[4]  = BG_COLOR;  expected[5]  = BBOX_COLOR;
        expected[6]  = BBOX_COLOR; expected[7]  = BG_COLOR;
        expected[8]  = BG_COLOR;  expected[9]  = BBOX_COLOR;
        expected[10] = BBOX_COLOR; expected[11] = BG_COLOR;
        expected[12] = BG_COLOR;  expected[13] = BG_COLOR;
        expected[14] = BG_COLOR;  expected[15] = BG_COLOR;
    end

    // ---- Capture output ----
    integer out_idx;
    logic [23:0] captured [NUM_PIX];

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Drive a solid red frame
        out_idx = 0;
        begin : drive_frame
            integer r, c;
            for (r = 0; r < V; r = r + 1) begin
                for (c = 0; c < H; c = c + 1) begin
                    drv_tdata  = BG_COLOR;
                    drv_tvalid = 1'b1;
                    drv_tlast  = (c == H - 1) ? 1'b1 : 1'b0;
                    drv_tuser  = (r == 0 && c == 0) ? 1'b1 : 1'b0;
                    @(posedge clk);
                end
            end
        end
        drv_tvalid = 1'b0;

        // Wait for all outputs to appear
        repeat (4) @(posedge clk);

        // Capture happened in the concurrent block below — check now
        begin : check_output
            integer k;
            for (k = 0; k < NUM_PIX; k = k + 1) begin
                if (captured[k] !== expected[k]) begin
                    $display("FAIL pixel %0d: got %06h, expected %06h", k, captured[k], expected[k]);
                    num_errors = num_errors + 1;
                end
            end
        end

        if (num_errors > 0) begin
            $fatal(1, "tb_axis_overlay_bbox FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_overlay_bbox PASSED — all %0d pixels OK", NUM_PIX);
            $finish;
        end
    end

    // ---- Concurrent output capture ----
    integer cap_idx = 0;
    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            captured[cap_idx] = m_tdata;
            cap_idx = cap_idx + 1;
        end
    end

endmodule
