// Unit testbench for axis_overlay_bbox.
//
// Tests:
//   T1  — original: bbox=(1,1)-(2,2) on solid-red 4×4, tready always high
//   T2  — empty bbox (bbox_empty=1): every output pixel must match input
//   T3  — full-frame bbox (0,0)-(H-1,V-1): border pixels=BBOX_COLOR, interior=input
//   T4  — single-pixel bbox (2,2)-(2,2): only (2,2) gets BBOX_COLOR
//   T5  — edge-aligned bbox at origin (0,0)-(1,1)
//   T6  — edge-aligned bbox at far corner (H-2,V-2)-(H-1,V-1)
//   T7  — varied input pixel colors: non-bbox pixels pass through unchanged
//   T8  — backpressure: consumer stall; data must be correct despite stalls

`timescale 1ns / 1ps

module tb_axis_overlay_bbox;

    localparam int H = 4;
    localparam int V = 4;
    localparam int NUM_PIX = H * V;
    localparam int CLK_PERIOD = 10;
    localparam int N_OUT_TB = 1;
    localparam logic [23:0] BBOX_COLOR = 24'h00_FF_00; // green

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    logic rst_n;

    // ---- Driver intermediaries ----
    logic [23:0] drv_tdata  = '0;
    logic        drv_tvalid = 1'b0;
    logic        drv_tlast  = 1'b0;
    logic        drv_tuser  = 1'b0;

    // ---- AXI4-Stream interfaces ----
    axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();
    axis_if #(.DATA_W(24), .USER_W(1)) m_axis ();

    always_ff @(negedge clk) begin
        s_axis.tdata  <= drv_tdata;
        s_axis.tvalid <= drv_tvalid;
        s_axis.tlast  <= drv_tlast;
        s_axis.tuser  <= drv_tuser;
    end

    // Consumer ready — controlled per test
    logic drv_rdy = 1'b1;
    assign m_axis.tready = drv_rdy;

    // ---- Bbox sideband — driven from test via assign ----
    logic [N_OUT_TB-1:0]                drv_valid = '0;
    logic [N_OUT_TB-1:0][$clog2(H)-1:0] drv_min_x = '0, drv_max_x = '0;
    logic [N_OUT_TB-1:0][$clog2(V)-1:0] drv_min_y = '0, drv_max_y = '0;

    bbox_if #(.N_OUT(N_OUT_TB), .H_W($clog2(H)), .V_W($clog2(V))) bboxes ();
    assign bboxes.valid = drv_valid;
    assign bboxes.min_x = drv_min_x;
    assign bboxes.max_x = drv_max_x;
    assign bboxes.min_y = drv_min_y;
    assign bboxes.max_y = drv_max_y;

    axis_overlay_bbox #(
        .H_ACTIVE   (H),
        .V_ACTIVE   (V),
        .N_OUT      (N_OUT_TB),
        .BBOX_COLOR (BBOX_COLOR)
    ) u_dut (
        .clk_i   (clk),
        .rst_n_i (rst_n),
        .s_axis  (s_axis),
        .m_axis  (m_axis),
        .bboxes  (bboxes)
    );

    integer num_errors = 0;

    // ---- Input and expected arrays ----
    logic [23:0] input_pixels [NUM_PIX];
    logic [23:0] expected     [NUM_PIX];
    logic [23:0] captured     [NUM_PIX];

    // ---- Stall generator ----
    localparam int STALL_LEN = 8;
    localparam int OPEN_LEN  = 3;
    logic stall_active = 1'b0;
    integer stall_ctr  = 0;

    always_ff @(posedge clk) begin
        if (stall_active) begin
            if (stall_ctr < STALL_LEN - 1) begin
                drv_rdy   <= 1'b0;
                stall_ctr <= stall_ctr + 1;
            end else if (stall_ctr < STALL_LEN + OPEN_LEN - 1) begin
                drv_rdy   <= 1'b1;
                stall_ctr <= stall_ctr + 1;
            end else begin
                stall_ctr <= 0;
            end
        end else begin
            drv_rdy   <= 1'b1;
            stall_ctr <= 0;
        end
    end

    // ---- Concurrent output capture ----
    integer cap_idx = 0;

    always @(posedge clk) begin
        if (m_axis.tvalid && m_axis.tready) begin
            if (cap_idx < NUM_PIX) begin
                captured[cap_idx] = m_axis.tdata;
                cap_idx = cap_idx + 1;
            end
        end
    end

    // ---- Helper: on_rect golden model ----
    function automatic logic on_rect_golden(
        input integer px_col,
        input integer px_row,
        input integer min_x,
        input integer max_x,
        input integer min_y,
        input integer max_y,
        input logic   empty
    );
        logic on_lr, in_yr, on_tb, in_xr;
        if (empty) return 1'b0;
        on_lr = (px_col == min_x) || (px_col == max_x);
        in_yr = (px_row >= min_y) && (px_row <= max_y);
        on_tb = (px_row == min_y) || (px_row == max_y);
        in_xr = (px_col >= min_x) && (px_col <= max_x);
        return (on_lr && in_yr) || (on_tb && in_xr);
    endfunction

    // ---- Build expected[] from current drv_* bbox and input_pixels[] ----
    task automatic build_expected;
        integer r, c, idx;
        for (r = 0; r < V; r = r + 1) begin
            for (c = 0; c < H; c = c + 1) begin
                idx = r * H + c;
                if (on_rect_golden(c, r,
                        drv_min_x[0], drv_max_x[0],
                        drv_min_y[0], drv_max_y[0], !drv_valid[0]))
                    expected[idx] = BBOX_COLOR;
                else
                    expected[idx] = input_pixels[idx];
            end
        end
    endtask

    // ---- Drive a frame and capture NUM_PIX outputs ----
    // Uses input_pixels[]. Waits for capture to finish.
    task automatic run_frame;
        integer px, timeout;
        cap_idx = 0;
        // Drive pixels through drv_* → register chain
        for (px = 0; px < NUM_PIX; px = px + 1) begin
            drv_tdata  = input_pixels[px];
            drv_tvalid = 1'b1;
            drv_tlast  = ((px % H) == H - 1) ? 1'b1 : 1'b0;
            drv_tuser  = (px == 0) ? 1'b1 : 1'b0;
            @(posedge clk);
            while (!s_axis.tready) @(posedge clk);
        end
        drv_tvalid = 1'b0;
        drv_tlast  = 1'b0;
        drv_tuser  = 1'b0;
        // Wait for all outputs to be captured
        timeout = 0;
        while (cap_idx < NUM_PIX && timeout < 5000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 5000) begin
            $display("FAIL: capture timed out (%0d/%0d pixels)", cap_idx, NUM_PIX);
            num_errors = num_errors + 1;
        end
    endtask

    // ---- Check captured vs expected ----
    task automatic check_frame(input string label);
        integer k;
        for (k = 0; k < NUM_PIX; k = k + 1) begin
            if (captured[k] !== expected[k]) begin
                $display("FAIL %s px%0d: got %06h exp %06h",
                         label, k, captured[k], expected[k]);
                num_errors = num_errors + 1;
            end
        end
        $display("%s: all %0d pixels checked", label, NUM_PIX);
    endtask

    integer i;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Default input: solid red
        for (i = 0; i < NUM_PIX; i = i + 1)
            input_pixels[i] = 24'hFF_00_00;

        // ==================================================================
        // T1 — original test: bbox=(1,1)-(2,2) on solid red
        // ==================================================================
        $display("--- T1: bbox=(1,1)-(2,2) solid red ---");
        drv_min_x[0] = 2'(1); drv_max_x[0] = 2'(2);
        drv_min_y[0] = 2'(1); drv_max_y[0] = 2'(2);
        drv_valid[0] = 1'b1;
        build_expected();
        run_frame();
        check_frame("T1");
        repeat (4) @(posedge clk);

        // ==================================================================
        // T2 — empty bbox: passthrough of every pixel
        // ==================================================================
        $display("--- T2: bbox_empty=1 passthrough ---");
        drv_valid[0] = 1'b0;
        build_expected();  // all pixels pass through
        run_frame();
        check_frame("T2");
        repeat (4) @(posedge clk);

        // ==================================================================
        // T3 — full-frame bbox: (0,0)-(H-1,V-1)
        //   Interior pixels (if any) should pass through; all border = BBOX_COLOR
        // ==================================================================
        $display("--- T3: full-frame bbox (0,0)-(3,3) ---");
        drv_min_x[0] = '0; drv_max_x[0] = ($bits(drv_max_x[0]))'(H-1);
        drv_min_y[0] = '0; drv_max_y[0] = ($bits(drv_max_y[0]))'(V-1);
        drv_valid[0] = 1'b1;
        build_expected();
        run_frame();
        check_frame("T3");
        repeat (4) @(posedge clk);

        // ==================================================================
        // T4 — single-pixel bbox: (2,2)-(2,2)
        // ==================================================================
        $display("--- T4: single-pixel bbox (2,2)-(2,2) ---");
        drv_min_x[0] = 2'(2); drv_max_x[0] = 2'(2);
        drv_min_y[0] = 2'(2); drv_max_y[0] = 2'(2);
        drv_valid[0] = 1'b1;
        build_expected();
        run_frame();
        check_frame("T4");
        repeat (4) @(posedge clk);

        // ==================================================================
        // T5 — edge-aligned bbox at origin: (0,0)-(1,1)
        // ==================================================================
        $display("--- T5: edge-aligned bbox at origin (0,0)-(1,1) ---");
        drv_min_x[0] = '0; drv_max_x[0] = 2'(1);
        drv_min_y[0] = '0; drv_max_y[0] = 2'(1);
        drv_valid[0] = 1'b1;
        build_expected();
        run_frame();
        check_frame("T5");
        repeat (4) @(posedge clk);

        // ==================================================================
        // T6 — edge-aligned bbox at far corner: (H-2,V-2)-(H-1,V-1)
        // ==================================================================
        $display("--- T6: edge-aligned bbox at far corner (2,2)-(3,3) ---");
        drv_min_x[0] = 2'(H-2); drv_max_x[0] = ($bits(drv_max_x[0]))'(H-1);
        drv_min_y[0] = 2'(V-2); drv_max_y[0] = ($bits(drv_max_y[0]))'(V-1);
        drv_valid[0] = 1'b1;
        build_expected();
        run_frame();
        check_frame("T6");
        repeat (4) @(posedge clk);

        // ==================================================================
        // T7 — varied input pixel colors: non-bbox pixels pass through
        // ==================================================================
        $display("--- T7: varied pixel colors, bbox=(1,0)-(2,2) ---");
        begin
            integer r, c;
            for (r = 0; r < V; r = r + 1)
                for (c = 0; c < H; c = c + 1)
                    input_pixels[r*H+c] = {8'(r*16 + c), 8'(c*64), 8'(r*64)};
        end
        drv_min_x[0] = 2'(1); drv_max_x[0] = 2'(2);
        drv_min_y[0] = '0;    drv_max_y[0] = 2'(2);
        drv_valid[0] = 1'b1;
        build_expected();
        run_frame();
        check_frame("T7");
        repeat (4) @(posedge clk);

        // ==================================================================
        // T8 — backpressure: stall + data integrity
        // ==================================================================
        $display("--- T8: backpressure, bbox=(1,1)-(2,2) ---");
        for (i = 0; i < NUM_PIX; i = i + 1)
            input_pixels[i] = 24'hFF_00_00;
        drv_min_x[0] = 2'(1); drv_max_x[0] = 2'(2);
        drv_min_y[0] = 2'(1); drv_max_y[0] = 2'(2);
        drv_valid[0] = 1'b1;
        build_expected();
        stall_active = 1'b1;
        run_frame();
        stall_active = 1'b0;
        drv_rdy = 1'b1;
        repeat (4) @(posedge clk);
        check_frame("T8");

        // ==================================================================
        // Summary
        // ==================================================================
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_overlay_bbox FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_overlay_bbox PASSED — all tests OK");
            $finish;
        end
    end

endmodule
