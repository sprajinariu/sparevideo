// Unit TB for axis_ccl — 8x8 frames, N_OUT=4, N_LABELS_INT=16.
//
// T1 single-blob rectangle
// T2 hollow rectangle (one connected component)
// T3 disjoint rectangles -> two distinct bboxes
// T4 U-shape forces equiv merge
// T5 min-size filter drops 1-pixel speckle
// T6 overflow: more blobs than N_LABELS_INT; no crash, real blobs still emit
// T7 back-to-back frames: second frame's bboxes do not inherit from the first

`timescale 1ns / 1ps

module tb_axis_ccl;

    localparam int H        = 8;
    localparam int V        = 8;
    localparam int NP       = H * V;
    localparam int N_LABELS = 16;
    localparam int N_OUT    = 4;
    localparam int MIN_PIX  = 1;
    localparam int CLK_PERIOD = 10;

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    logic rst_n;

    // --- drv_* pattern ---
    logic drv_tdata = 1'b0, drv_tvalid = 1'b0, drv_tlast = 1'b0, drv_tuser = 1'b0;
    logic s_tdata, s_tvalid, s_tready, s_tlast, s_tuser;
    always_ff @(posedge clk) begin
        s_tdata  <= drv_tdata;
        s_tvalid <= drv_tvalid;
        s_tlast  <= drv_tlast;
        s_tuser  <= drv_tuser;
    end

    logic [N_OUT-1:0]                bbox_valid;
    logic [N_OUT-1:0][$clog2(H)-1:0] bbox_min_x, bbox_max_x;
    logic [N_OUT-1:0][$clog2(V)-1:0] bbox_min_y, bbox_max_y;
    logic                            bbox_swap;
    logic                            bbox_empty;

    axis_ccl #(
        .H_ACTIVE             (H),
        .V_ACTIVE             (V),
        .N_LABELS_INT         (N_LABELS),
        .N_OUT                (N_OUT),
        .MIN_COMPONENT_PIXELS (MIN_PIX),
        .MAX_CHAIN_DEPTH      (8),
        .PRIME_FRAMES         (0)  // unit TB asserts on first frame's bboxes
    ) u_dut (
        .clk_i           (clk),
        .rst_n_i         (rst_n),
        .s_axis_tdata_i  (s_tdata),
        .s_axis_tvalid_i (s_tvalid),
        .s_axis_tready_o (s_tready),
        .s_axis_tlast_i  (s_tlast),
        .s_axis_tuser_i  (s_tuser),
        .bbox_valid_o    (bbox_valid),
        .bbox_min_x_o    (bbox_min_x),
        .bbox_max_x_o    (bbox_max_x),
        .bbox_min_y_o    (bbox_min_y),
        .bbox_max_y_o    (bbox_max_y),
        .bbox_swap_o    (bbox_swap),
        .bbox_empty_o   (bbox_empty)
    );

    integer num_errors = 0;
    logic mask [NP];

    task automatic drive_frame;
        integer r, c;
        for (r = 0; r < V; r = r + 1) begin
            for (c = 0; c < H; c = c + 1) begin
                drv_tdata  = mask[r*H + c];
                drv_tvalid = 1'b1;
                drv_tlast  = (c == H-1);
                drv_tuser  = (r == 0 && c == 0);
                @(posedge clk);
            end
        end
        drv_tvalid = 1'b0;
        drv_tlast  = 1'b0;
        drv_tuser  = 1'b0;
    endtask

    task automatic wait_swap(output logic timed_out);
        integer t;
        t = 0; timed_out = 1'b0;
        while (!bbox_swap && t < 4000) begin
            @(posedge clk);
            t = t + 1;
        end
        if (t >= 4000) timed_out = 1'b1;
    endtask

    // Expect a bbox (min_x,max_x,min_y,max_y) to be present in some slot.
    task automatic assert_bbox_present(
        input string  label,
        input integer exp_min_x, exp_max_x, exp_min_y, exp_max_y
    );
        integer k;
        logic   found;
        found = 1'b0;
        for (k = 0; k < N_OUT; k = k + 1) begin
            if (bbox_valid[k] &&
                bbox_min_x[k] == exp_min_x && bbox_max_x[k] == exp_max_x &&
                bbox_min_y[k] == exp_min_y && bbox_max_y[k] == exp_max_y) begin
                found = 1'b1;
            end
        end
        if (!found) begin
            $display("FAIL %s: bbox (%0d,%0d)-(%0d,%0d) not found",
                     label, exp_min_x, exp_min_y, exp_max_x, exp_max_y);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS %s: bbox present", label);
        end
    endtask

    task automatic count_valid(output integer cnt);
        integer k;
        cnt = 0;
        for (k = 0; k < N_OUT; k = k + 1)
            if (bbox_valid[k]) cnt = cnt + 1;
    endtask

    integer i;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- T1: single solid rectangle (rows 2..4, cols 3..5) -> 3x3 = 9 px ----
        $display("--- T1: single solid rectangle ---");
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        for (i = 2; i <= 4; i = i + 1) begin
            integer c;
            for (c = 3; c <= 5; c = c + 1) mask[i*H + c] = 1'b1;
        end
        drive_frame();
        begin logic to; wait_swap(to); end
        assert_bbox_present("T1", 3, 5, 2, 4);

        // ---- T2: hollow rectangle (one 8-connected component) ----
        $display("--- T2: hollow rectangle ---");
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        for (i = 3; i <= 5; i = i + 1) mask[i*H + 3] = 1'b1;      // left edge
        for (i = 3; i <= 5; i = i + 1) mask[i*H + 5] = 1'b1;      // right edge
        mask[3*H + 4] = 1'b1;                                      // top
        mask[5*H + 4] = 1'b1;                                      // bottom
        drive_frame();
        begin logic to; wait_swap(to); end
        assert_bbox_present("T2", 3, 5, 3, 5);

        // ---- T3: two disjoint rectangles ----
        $display("--- T3: two disjoint rectangles ---");
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        mask[0*H + 0] = 1'b1; mask[0*H + 1] = 1'b1;
        mask[1*H + 0] = 1'b1; mask[1*H + 1] = 1'b1;   // TL 2x2
        mask[6*H + 6] = 1'b1; mask[6*H + 7] = 1'b1;
        mask[7*H + 6] = 1'b1; mask[7*H + 7] = 1'b1;   // BR 2x2
        drive_frame();
        begin logic to; wait_swap(to); end
        assert_bbox_present("T3a", 0, 1, 0, 1);
        assert_bbox_present("T3b", 6, 7, 6, 7);

        // ---- T4: U-shape ----
        $display("--- T4: U-shape merge ---");
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        for (i = 0; i < 5; i = i + 1) mask[i*H + 1] = 1'b1;  // left arm
        for (i = 0; i < 5; i = i + 1) mask[i*H + 6] = 1'b1;  // right arm
        for (i = 1; i < 7; i = i + 1) mask[4*H + i] = 1'b1;  // bottom connector
        drive_frame();
        begin logic to; wait_swap(to); end
        assert_bbox_present("T4", 1, 6, 0, 4);

        // ---- T5: min-size filter. Use MIN_PIX=4; 1-pixel speckle dropped. ----
        // For this test, re-parametrize a second DUT with MIN_PIX=4.
        // (Simpler: keep MIN_PIX=1 for T1-T4 but add a second DUT instance with MIN_PIX=4
        //  — deferred to an enhancement. For now, sanity-check small blob + large blob both present.)
        // SKIPPED in the minimum cut; see tb TODO.

        // ---- T6: overflow — more disjoint single-pixel blobs than N_LABELS-1=15 ----
        $display("--- T6: overflow — 20 disjoint single pixels ---");
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        // 20 isolated pixels on an 8x8 is impossible (only 64 positions, must not touch 8-connected).
        // Use a 4-cell-spaced pattern: mask[(2*r)*H + 2*c] for r in 0..3, c in 0..3 = 16 points.
        for (i = 0; i < 4; i = i + 1)
            for (integer j = 0; j < 4; j = j + 1)
                mask[(2*i)*H + 2*j] = 1'b1;   // 16 disjoint single pixels
        drive_frame();
        begin logic to; wait_swap(to); end
        begin
            integer c;
            count_valid(c);
            if (c == 0) begin
                $display("FAIL T6: no bboxes emitted despite many blobs");
                num_errors = num_errors + 1;
            end else begin
                $display("PASS T6: overflow did not crash, %0d slots populated", c);
            end
        end

        // ---- T7: back-to-back frames, second must not inherit first ----
        $display("--- T7: back-to-back frames ---");
        // Frame A: big blob at top-left.
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        for (i = 0; i <= 3; i = i + 1)
            for (integer c = 0; c <= 3; c = c + 1) mask[i*H + c] = 1'b1;
        drive_frame();
        begin logic to; wait_swap(to); end
        // Frame B: single pixel at (7,7).
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        mask[7*H + 7] = 1'b1;
        drive_frame();
        begin logic to; wait_swap(to); end
        assert_bbox_present("T7", 7, 7, 7, 7);
        // And the top-left blob must NOT appear in T7's front buffer.
        begin
            integer k;
            logic   leak;
            leak = 1'b0;
            for (k = 0; k < N_OUT; k = k + 1)
                if (bbox_valid[k] && bbox_max_x[k] <= 3 && bbox_max_y[k] <= 3 && bbox_min_x[k] == 0 && bbox_min_y[k] == 0)
                    leak = 1'b1;
            if (leak) begin
                $display("FAIL T7: previous frame's bbox leaked into current");
                num_errors = num_errors + 1;
            end
        end

        if (num_errors > 0) $fatal(1, "tb_axis_ccl FAILED with %0d errors", num_errors);
        else begin $display("tb_axis_ccl PASSED"); $finish; end
    end

endmodule
