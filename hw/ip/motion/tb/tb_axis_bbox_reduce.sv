// Unit testbench for axis_bbox_reduce.
//
// Test 1: Drives a 4x4 mask frame with known active pixels, checks that
//         the latched bbox matches the expected rectangle.
// Test 2: Drives an all-zero mask frame, checks bbox_empty is asserted.

`timescale 1ns / 1ps

module tb_axis_bbox_reduce;

    localparam int H = 4;
    localparam int V = 4;
    localparam int NUM_PIX = H * V;
    localparam int CLK_PERIOD = 10;

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    logic rst_n;

    // ---- Driver intermediaries ----
    logic drv_tdata  = 1'b0;
    logic drv_tvalid = 1'b0;
    logic drv_tlast  = 1'b0;
    logic drv_tuser  = 1'b0;

    logic s_tdata, s_tvalid, s_tready, s_tlast, s_tuser;

    always_ff @(negedge clk) begin
        s_tdata  <= drv_tdata;
        s_tvalid <= drv_tvalid;
        s_tlast  <= drv_tlast;
        s_tuser  <= drv_tuser;
    end

    // ---- DUT outputs ----
    logic [$clog2(H)-1:0] bbox_min_x, bbox_max_x;
    logic [$clog2(V)-1:0] bbox_min_y, bbox_max_y;
    logic                 bbox_valid, bbox_empty;

    axis_bbox_reduce #(.H_ACTIVE(H), .V_ACTIVE(V)) u_dut (
        .clk   (clk),
        .rst_n (rst_n),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid),
        .s_axis_tready (s_tready),
        .s_axis_tlast  (s_tlast),
        .s_axis_tuser  (s_tuser),
        .bbox_min_x (bbox_min_x),
        .bbox_max_x (bbox_max_x),
        .bbox_min_y (bbox_min_y),
        .bbox_max_y (bbox_max_y),
        .bbox_valid (bbox_valid),
        .bbox_empty (bbox_empty)
    );

    integer num_errors = 0;

    // Shared mask data array — populated before drive_mask_frame is called.
    logic mask_data [NUM_PIX];

    // Drive the frame from mask_data[]
    task automatic drive_mask_frame;
        integer r, c, idx;
        for (r = 0; r < V; r = r + 1) begin
            for (c = 0; c < H; c = c + 1) begin
                idx = r * H + c;
                drv_tdata  = mask_data[idx];
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

    task automatic wait_bbox_valid;
        integer timeout;
        timeout = 0;
        while (!bbox_valid && timeout < 100) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 100) begin
            $display("FAIL: bbox_valid never asserted");
            num_errors = num_errors + 1;
        end
    endtask

    integer i;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- Test 1: mask with known active region ----
        // Layout (4x4):
        //   row 0: 0 0 0 0
        //   row 1: 0 1 1 0
        //   row 2: 0 0 1 0
        //   row 3: 0 0 0 0
        // Expected bbox: min_x=1, max_x=2, min_y=1, max_y=2
        for (i = 0; i < NUM_PIX; i = i + 1) mask_data[i] = 1'b0;
        mask_data[5]  = 1'b1;  // row 1, col 1
        mask_data[6]  = 1'b1;  // row 1, col 2
        mask_data[10] = 1'b1;  // row 2, col 2

        $display("Test 1: mask with known active region...");
        drive_mask_frame();
        wait_bbox_valid();

        if (bbox_empty) begin
            $display("FAIL test 1: bbox_empty=1, expected 0");
            num_errors = num_errors + 1;
        end
        if (bbox_min_x !== 1 || bbox_max_x !== 2 || bbox_min_y !== 1 || bbox_max_y !== 2) begin
            $display("FAIL test 1: bbox=(%0d,%0d)-(%0d,%0d), expected (1,1)-(2,2)",
                     bbox_min_x, bbox_min_y, bbox_max_x, bbox_max_y);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS test 1: bbox=(%0d,%0d)-(%0d,%0d)",
                     bbox_min_x, bbox_min_y, bbox_max_x, bbox_max_y);
        end

        repeat (4) @(posedge clk);

        // ---- Test 2: all-zero mask → bbox_empty ----
        for (i = 0; i < NUM_PIX; i = i + 1) mask_data[i] = 1'b0;

        $display("Test 2: all-zero mask...");
        drive_mask_frame();
        wait_bbox_valid();

        if (!bbox_empty) begin
            $display("FAIL test 2: bbox_empty=0, expected 1");
            num_errors = num_errors + 1;
        end else begin
            $display("PASS test 2: bbox_empty=1");
        end

        // ---- Summary ----
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_bbox_reduce FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_bbox_reduce PASSED — 2 tests OK");
            $finish;
        end
    end

endmodule
