// Unit TB for axis_ccl — 8x8 frames, N_OUT=4, N_LABELS_INT=16.
//
// T1 single-blob rectangle
// T2 hollow rectangle (one connected component)
// T3 disjoint rectangles -> two distinct bboxes
// T4 U-shape forces equiv merge
// T5 min-size filter drops small blobs (separate DUT with MIN_PIX=4)
// T6 overflow: large blob + many single-pixel blobs; large blob survives
// T7 back-to-back frames: second frame's bboxes do not inherit from the first
// T8 mid-frame strobe gaps: deasserting tvalid mid-frame preserves labeling
// T9 priming: PRIME_FRAMES=1 suppresses front buffer for 1 frame (separate DUT)

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
    // Separate reset for the priming DUT so T9 sees frame 0 after reset, not
    // after the 8+ frames the other tests already drove through it.
    logic pf_rst_n;

    // --- drv_* pattern ---
    logic drv_tdata = 1'b0, drv_tvalid = 1'b0, drv_tlast = 1'b0, drv_tuser = 1'b0;

    // Each DUT gets its own axis_if and bbox_if pair.
    // All three share the same driven stimulus (drv_*), latched at negedge.
    axis_if #(.DATA_W(1), .USER_W(1)) s_axis_default ();
    axis_if #(.DATA_W(1), .USER_W(1)) s_axis_mp4     ();
    axis_if #(.DATA_W(1), .USER_W(1)) s_axis_pf      ();

    bbox_if #(.N_OUT(N_OUT), .H_W($clog2(H)), .V_W($clog2(V))) bboxes_default ();
    bbox_if #(.N_OUT(N_OUT), .H_W($clog2(H)), .V_W($clog2(V))) bboxes_mp4     ();
    bbox_if #(.N_OUT(N_OUT), .H_W($clog2(H)), .V_W($clog2(V))) bboxes_pf      ();

    // Negedge driver ensures DUT inputs are stable at posedge sampling.
    always_ff @(negedge clk) begin
        s_axis_default.tdata  <= drv_tdata;
        s_axis_default.tvalid <= drv_tvalid;
        s_axis_default.tlast  <= drv_tlast;
        s_axis_default.tuser  <= drv_tuser;

        s_axis_mp4.tdata  <= drv_tdata;
        s_axis_mp4.tvalid <= drv_tvalid;
        s_axis_mp4.tlast  <= drv_tlast;
        s_axis_mp4.tuser  <= drv_tuser;

        s_axis_pf.tdata  <= drv_tdata;
        s_axis_pf.tvalid <= drv_tvalid;
        s_axis_pf.tlast  <= drv_tlast;
        s_axis_pf.tuser  <= drv_tuser;
    end

    // Flat sideband outputs for tasks (read bbox_valid/min_x/etc from default DUT)
    logic [N_OUT-1:0]                bbox_valid;
    logic [N_OUT-1:0][$clog2(H)-1:0] bbox_min_x, bbox_max_x;
    logic [N_OUT-1:0][$clog2(V)-1:0] bbox_min_y, bbox_max_y;
    assign bbox_valid = bboxes_default.valid;
    assign bbox_min_x = bboxes_default.min_x;
    assign bbox_max_x = bboxes_default.max_x;
    assign bbox_min_y = bboxes_default.min_y;
    assign bbox_max_y = bboxes_default.max_y;

    logic bbox_swap;
    logic bbox_empty;

    // mp4 DUT sideband aliases
    logic [N_OUT-1:0]                mp4_bbox_valid;
    logic [N_OUT-1:0][$clog2(H)-1:0] mp4_bbox_min_x, mp4_bbox_max_x;
    logic [N_OUT-1:0][$clog2(V)-1:0] mp4_bbox_min_y, mp4_bbox_max_y;
    logic                            mp4_bbox_swap;
    assign mp4_bbox_valid = bboxes_mp4.valid;
    assign mp4_bbox_min_x = bboxes_mp4.min_x;
    assign mp4_bbox_max_x = bboxes_mp4.max_x;
    assign mp4_bbox_min_y = bboxes_mp4.min_y;
    assign mp4_bbox_max_y = bboxes_mp4.max_y;

    // pf DUT sideband aliases
    logic [N_OUT-1:0]                pf_bbox_valid;
    logic [N_OUT-1:0][$clog2(H)-1:0] pf_bbox_min_x, pf_bbox_max_x;
    logic [N_OUT-1:0][$clog2(V)-1:0] pf_bbox_min_y, pf_bbox_max_y;
    logic                            pf_bbox_swap;
    logic                            pf_bbox_empty;
    assign pf_bbox_valid = bboxes_pf.valid;
    assign pf_bbox_min_x = bboxes_pf.min_x;
    assign pf_bbox_max_x = bboxes_pf.max_x;
    assign pf_bbox_min_y = bboxes_pf.min_y;
    assign pf_bbox_max_y = bboxes_pf.max_y;

    axis_ccl #(
        .H_ACTIVE             (H),
        .V_ACTIVE             (V),
        .N_LABELS_INT         (N_LABELS),
        .N_OUT                (N_OUT),
        .MIN_COMPONENT_PIXELS (MIN_PIX),
        .MAX_CHAIN_DEPTH      (8),
        .PRIME_FRAMES         (0)  // unit TB asserts on first frame's bboxes
    ) u_dut (
        .clk_i        (clk),
        .rst_n_i      (rst_n),
        .s_axis       (s_axis_default),
        .bboxes       (bboxes_default),
        .bbox_swap_o  (bbox_swap),
        .bbox_empty_o (bbox_empty)
    );

    // Second DUT: MIN_COMPONENT_PIXELS=4 — exercises the size filter.
    axis_ccl #(
        .H_ACTIVE             (H),
        .V_ACTIVE             (V),
        .N_LABELS_INT         (N_LABELS),
        .N_OUT                (N_OUT),
        .MIN_COMPONENT_PIXELS (4),
        .MAX_CHAIN_DEPTH      (8),
        .PRIME_FRAMES         (0)
    ) u_dut_minpix4 (
        .clk_i        (clk),
        .rst_n_i      (rst_n),
        .s_axis       (s_axis_mp4),
        .bboxes       (bboxes_mp4),
        .bbox_swap_o  (mp4_bbox_swap),
        .bbox_empty_o ()
    );

    // Third DUT: PRIME_FRAMES=1 — exercises the priming skip on frame 0.
    axis_ccl #(
        .H_ACTIVE             (H),
        .V_ACTIVE             (V),
        .N_LABELS_INT         (N_LABELS),
        .N_OUT                (N_OUT),
        .MIN_COMPONENT_PIXELS (MIN_PIX),
        .MAX_CHAIN_DEPTH      (8),
        .PRIME_FRAMES         (1)
    ) u_dut_prime1 (
        .clk_i        (clk),
        .rst_n_i      (pf_rst_n),
        .s_axis       (s_axis_pf),
        .bboxes       (bboxes_pf),
        .bbox_swap_o  (pf_bbox_swap),
        .bbox_empty_o (pf_bbox_empty)
    );

    integer num_errors = 0;
    logic mask [NP];

    task automatic drive_frame;
        drive_frame_gated(1'b0);
    endtask

    // Drive a frame optionally inserting a 1-cycle tvalid=0 gap every other
    // accepted pixel. Exercises the shift-chain/accept_d1 invariants under
    // mid-frame stalls.
    task automatic drive_frame_gated(input logic insert_gaps);
        integer r, c, pix_idx;
        pix_idx = 0;
        for (r = 0; r < V; r = r + 1) begin
            for (c = 0; c < H; c = c + 1) begin
                drv_tdata  = mask[r*H + c];
                drv_tvalid = 1'b1;
                drv_tlast  = (c == H-1);
                drv_tuser  = (r == 0 && c == 0);
                @(posedge clk);
                if (insert_gaps && (pix_idx % 2 == 0)) begin
                    drv_tvalid = 1'b0;
                    drv_tlast  = 1'b0;
                    drv_tuser  = 1'b0;
                    @(posedge clk);
                end
                pix_idx = pix_idx + 1;
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

    // Assert that `bbox_valid` does NOT contain a matching bbox in any slot.
    task automatic assert_bbox_absent(
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
        if (found) begin
            $display("FAIL %s: bbox (%0d,%0d)-(%0d,%0d) should not be present",
                     label, exp_min_x, exp_min_y, exp_max_x, exp_max_y);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS %s: filtered bbox absent", label);
        end
    endtask

    // Check a specific bbox exists in the MIN_PIX=4 DUT's front buffer.
    task automatic assert_mp4_bbox_present(
        input string  label,
        input integer exp_min_x, exp_max_x, exp_min_y, exp_max_y
    );
        integer k;
        logic   found;
        found = 1'b0;
        for (k = 0; k < N_OUT; k = k + 1) begin
            if (mp4_bbox_valid[k] &&
                mp4_bbox_min_x[k] == exp_min_x && mp4_bbox_max_x[k] == exp_max_x &&
                mp4_bbox_min_y[k] == exp_min_y && mp4_bbox_max_y[k] == exp_max_y) begin
                found = 1'b1;
            end
        end
        if (!found) begin
            $display("FAIL %s: MIN_PIX=4 bbox (%0d,%0d)-(%0d,%0d) not found",
                     label, exp_min_x, exp_min_y, exp_max_x, exp_max_y);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS %s: MIN_PIX=4 bbox present", label);
        end
    endtask

    task automatic assert_mp4_bbox_absent(
        input string  label,
        input integer exp_min_x, exp_max_x, exp_min_y, exp_max_y
    );
        integer k;
        logic   found;
        found = 1'b0;
        for (k = 0; k < N_OUT; k = k + 1) begin
            if (mp4_bbox_valid[k] &&
                mp4_bbox_min_x[k] == exp_min_x && mp4_bbox_max_x[k] == exp_max_x &&
                mp4_bbox_min_y[k] == exp_min_y && mp4_bbox_max_y[k] == exp_max_y) begin
                found = 1'b1;
            end
        end
        if (found) begin
            $display("FAIL %s: MIN_PIX=4 bbox (%0d,%0d)-(%0d,%0d) should be filtered out",
                     label, exp_min_x, exp_min_y, exp_max_x, exp_max_y);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS %s: MIN_PIX=4 bbox correctly filtered", label);
        end
    endtask

    integer i;

    initial begin
        rst_n    = 0;
        pf_rst_n = 0;  // hold priming DUT in reset until T9
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

        // ---- T5: min-size filter — MIN_COMPONENT_PIXELS=4 DUT. ----
        // 1-pixel speckle at (0,0) dropped; 2x2 blob at (5,5)-(6,6) survives.
        $display("--- T5: min-size filter (MIN_PIX=4) ---");
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        mask[0*H + 0] = 1'b1;                                     // 1-px speckle
        mask[5*H + 5] = 1'b1; mask[5*H + 6] = 1'b1;
        mask[6*H + 5] = 1'b1; mask[6*H + 6] = 1'b1;               // 2x2 blob (4 px)
        drive_frame();
        begin logic to; wait_swap(to); end  // both DUTs' FSMs complete together
        assert_mp4_bbox_present("T5 keep",   5, 6, 5, 6);
        assert_mp4_bbox_absent ("T5 drop",   0, 0, 0, 0);

        // ---- T6: top-K by count — one large blob plus many single pixels ----
        // The large blob has count=9; singles have count=1. Top-K (N_OUT=4)
        // must include the large blob. Singles are 2-cell-spaced and
        // non-adjacent (8-connectivity) to each other or to the big blob.
        $display("--- T6: 1 large blob + 8 single pixels ---");
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        // Large 3x3 blob (9 px) at (5,5)-(7,7).
        for (i = 5; i <= 7; i = i + 1) begin
            integer c;
            for (c = 5; c <= 7; c = c + 1) mask[i*H + c] = 1'b1;
        end
        // 8 disjoint single pixels in the top-left.
        mask[0*H + 0] = 1'b1; mask[0*H + 2] = 1'b1; mask[0*H + 4] = 1'b1;
        mask[2*H + 0] = 1'b1; mask[2*H + 2] = 1'b1; mask[2*H + 4] = 1'b1;
        mask[4*H + 0] = 1'b1; mask[4*H + 2] = 1'b1;
        drive_frame();
        begin logic to; wait_swap(to); end
        begin
            integer c;
            count_valid(c);
            if (c == 0) begin
                $display("FAIL T6: no bboxes emitted despite many blobs");
                num_errors = num_errors + 1;
            end else begin
                $display("T6: %0d slots populated", c);
            end
        end
        assert_bbox_present("T6 large survives", 5, 7, 5, 7);

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

        // ---- T8: mid-frame tvalid gaps must not corrupt labeling ----
        $display("--- T8: mid-frame strobe gaps ---");
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        // Same pattern as T1: 3x3 rectangle at rows 2..4, cols 3..5.
        for (i = 2; i <= 4; i = i + 1) begin
            integer c;
            for (c = 3; c <= 5; c = c + 1) mask[i*H + c] = 1'b1;
        end
        drive_frame_gated(1'b1);
        begin logic to; wait_swap(to); end
        assert_bbox_present("T8 gated", 3, 5, 2, 4);

        // ---- T9: priming — PRIME_FRAMES=1 DUT ----
        // u_dut_prime1 has been held in reset so frame 0 after pf_rst_n rises
        // is the first frame it sees. Frame 0 PHASE_SWAP must skip the front
        // update; frame 1 must commit.
        $display("--- T9: PRIME_FRAMES=1 suppresses first frame ---");
        pf_rst_n = 1'b1;
        repeat (2) @(posedge clk);
        for (i = 0; i < NP; i = i + 1) mask[i] = 1'b0;
        for (i = 1; i <= 3; i = i + 1) begin
            integer c;
            for (c = 1; c <= 3; c = c + 1) mask[i*H + c] = 1'b1;  // 3x3 blob
        end
        drive_frame();                          // frame A (frame 0 for all DUTs)
        begin logic to; wait_swap(to); end      // wait for first swap pulse
        // After frame 0 swap: main DUT (PRIME_FRAMES=0) has bbox; priming DUT does not.
        if (pf_bbox_valid != '0) begin
            $display("FAIL T9a: priming DUT emitted bbox on frame 0 (valid=%b)", pf_bbox_valid);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS T9a: priming DUT front buffer empty on frame 0");
        end
        // Second frame, same mask. Priming DUT should now emit the bbox.
        drive_frame();
        begin logic to; wait_swap(to); end
        begin
            integer k;
            logic   found;
            found = 1'b0;
            for (k = 0; k < N_OUT; k = k + 1) begin
                if (pf_bbox_valid[k] &&
                    pf_bbox_min_x[k] == 1 && pf_bbox_max_x[k] == 3 &&
                    pf_bbox_min_y[k] == 1 && pf_bbox_max_y[k] == 3)
                    found = 1'b1;
            end
            if (!found) begin
                $display("FAIL T9b: priming DUT did not emit real bbox on frame 1");
                num_errors = num_errors + 1;
            end else begin
                $display("PASS T9b: priming DUT emits real bbox after priming");
            end
        end

        if (num_errors > 0) $fatal(1, "tb_axis_ccl FAILED with %0d errors", num_errors);
        else begin $display("tb_axis_ccl PASSED"); $finish; end
    end

endmodule
