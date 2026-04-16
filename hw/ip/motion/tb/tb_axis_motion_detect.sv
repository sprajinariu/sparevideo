// Unit testbench for axis_motion_detect.
//
// Tests (in order):
//   Frame 0 — RAM zero-init → golden mask per pixel, RGB passthrough check
//   Frame 1 — same pixels, EMA-updated y_prev → golden mask check, RAM EMA verify
//   Frame 2 — mixed-motion: pixels crafted for threshold boundary vs EMA y_prev
//   Frame 3 — same mixed-motion under consumer stall → verifies stall correctness
//   Frame 4 — asymmetric stall: only vid stalls, msk stays ready → verifies no
//             duplicate transfers on the ready channel (fork desync bug)
//   Frame 5 — asymmetric stall: only msk stalls, vid stays ready → mirror test
//
// EMA background model: y_prev = y_prev + ((y_cur - y_prev) >>> ALPHA_SHIFT)
//
// Conventions: drv_* intermediaries, posedge register, $display/$fatal.

`timescale 1ns / 1ps

module tb_axis_motion_detect;

    localparam int H           = 4;
    localparam int V           = 2;
    localparam int THRESH      = 16;
    localparam int ALPHA_SHIFT = 3;
    localparam int NUM_PIX     = H * V;
    localparam int CLK_PERIOD  = 10;

    // ---- Clock / reset ----
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
    logic [23:0] vid_tdata;
    logic        vid_tvalid, vid_tlast, vid_tuser;
    logic        msk_tdata;
    logic        msk_tvalid, msk_tlast, msk_tuser;

    // Consumer ready — driven from test
    logic drv_vid_rdy = 1'b1;
    logic drv_msk_rdy = 1'b1;
    logic vid_tready, msk_tready;
    assign vid_tready = drv_vid_rdy;
    assign msk_tready = drv_msk_rdy;

    // ---- Stall-pattern generator ----
    localparam int STALL_LEN = 10;
    localparam int OPEN_LEN  = 3;

    logic stall_active = 1'b0;
    // Asymmetric stall: only one channel stalls, the other stays ready.
    // 0 = symmetric (both stall), 1 = vid-only stall, 2 = msk-only stall.
    integer stall_mode = 0;
    integer stall_ctr  = 0;

    always_ff @(posedge clk) begin
        if (stall_active) begin
            if (stall_ctr < STALL_LEN - 1) begin
                drv_vid_rdy <= (stall_mode == 2) ? 1'b1 : 1'b0;
                drv_msk_rdy <= (stall_mode == 1) ? 1'b1 : 1'b0;
                stall_ctr   <= stall_ctr + 1;
            end else if (stall_ctr < STALL_LEN + OPEN_LEN - 1) begin
                drv_vid_rdy <= 1'b1;
                drv_msk_rdy <= 1'b1;
                stall_ctr   <= stall_ctr + 1;
            end else begin
                stall_ctr <= 0;
            end
        end else begin
            drv_vid_rdy <= 1'b1;
            drv_msk_rdy <= 1'b1;
            stall_ctr   <= 0;
        end
    end

    // ---- RAM ----
    localparam int RAM_DEPTH = NUM_PIX;
    localparam int ADDR_W    = $clog2(RAM_DEPTH);

    logic [ADDR_W-1:0] a_rd_addr, a_wr_addr;
    logic [7:0]        a_rd_data, a_wr_data;
    logic              a_wr_en;

    // Port B used by TB to read back Y8 values
    logic [ADDR_W-1:0] b_rd_addr = '0;
    logic [7:0]        b_rd_data;

    ram #(.DEPTH(RAM_DEPTH)) u_ram (
        .clk_i       (clk),
        .a_rd_addr_i (a_rd_addr),
        .a_rd_data_o (a_rd_data),
        .a_wr_addr_i (a_wr_addr),
        .a_wr_data_i (a_wr_data),
        .a_wr_en_i   (a_wr_en),
        .b_rd_addr_i (b_rd_addr),
        .b_rd_data_o (b_rd_data),
        .b_wr_addr_i ('0),
        .b_wr_data_i ('0),
        .b_wr_en_i   (1'b0)
    );

    // ---- DUT ----
    axis_motion_detect #(
        .H_ACTIVE    (H),
        .V_ACTIVE    (V),
        .THRESH      (THRESH),
        .ALPHA_SHIFT (ALPHA_SHIFT),
        .RGN_BASE    (0),
        .RGN_SIZE    (NUM_PIX)
    ) u_dut (
        .clk_i               (clk),
        .rst_n_i             (rst_n),
        .s_axis_tdata_i      (s_tdata),
        .s_axis_tvalid_i     (s_tvalid),
        .s_axis_tready_o     (s_tready),
        .s_axis_tlast_i      (s_tlast),
        .s_axis_tuser_i      (s_tuser),
        .m_axis_vid_tdata_o  (vid_tdata),
        .m_axis_vid_tvalid_o (vid_tvalid),
        .m_axis_vid_tready_i (vid_tready),
        .m_axis_vid_tlast_o  (vid_tlast),
        .m_axis_vid_tuser_o  (vid_tuser),
        .m_axis_msk_tdata_o  (msk_tdata),
        .m_axis_msk_tvalid_o (msk_tvalid),
        .m_axis_msk_tready_i (msk_tready),
        .m_axis_msk_tlast_o  (msk_tlast),
        .m_axis_msk_tuser_o  (msk_tuser),
        .mem_rd_addr_o       (a_rd_addr),
        .mem_rd_data_i       (a_rd_data),
        .mem_wr_addr_o       (a_wr_addr),
        .mem_wr_data_o       (a_wr_data),
        .mem_wr_en_o         (a_wr_en)
    );

    // ---- Golden Y8 model ----
    // Matches rgb2ycrcb: y = (77*R + 150*G + 29*B) >> 8
    function automatic logic [7:0] y_of(input logic [23:0] rgb);
        logic [7:0] r, g, b;
        logic [16:0] sum;
        r = rgb[23:16]; g = rgb[15:8]; b = rgb[7:0];
        sum = 17'(77 * r) + 17'(150 * g) + 17'(29 * b);
        return sum[15:8];
    endfunction

    // ---- Pixel arrays ----
    // frame_pixels: base pixel set (used for frames 0 and 1)
    logic [23:0] frame_pixels [NUM_PIX];
    // mixed_pixels: crafted for threshold boundary (frame 2 and 3)
    logic [23:0] mixed_pixels [NUM_PIX];
    // y_prev: Y8 values from the previously driven frame (updated by TB)
    logic [7:0]  y_prev [NUM_PIX];

    // ---- Capture arrays ----
    logic [23:0] cap_vid [NUM_PIX];
    logic        cap_msk [NUM_PIX];

    integer num_errors = 0;

    // ---- Tasks ----

    // Drive one frame; concurrent capture happens in the always block below.
    task automatic drive_frame(input logic [23:0] pixels [NUM_PIX]);
        integer px;
        for (px = 0; px < NUM_PIX; px = px + 1) begin
            drv_tdata  = pixels[px];
            drv_tvalid = 1'b1;
            drv_tlast  = ((px % H) == H - 1) ? 1'b1 : 1'b0;
            drv_tuser  = (px == 0) ? 1'b1 : 1'b0;
            @(posedge clk);
            while (!s_tready) @(posedge clk);
        end
        drv_tvalid = 1'b0;
        drv_tlast  = 1'b0;
        drv_tuser  = 1'b0;
    endtask

    // Wait until NUM_PIX vid and mask outputs have been captured.
    task automatic wait_frame_captured;
        integer timeout;
        timeout = 0;
        while ((vid_cap_cnt < NUM_PIX || msk_cap_cnt < NUM_PIX) && timeout < 10000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 10000) begin
            $display("FAIL: capture timed out (vid=%0d msk=%0d)", vid_cap_cnt, msk_cap_cnt);
            num_errors = num_errors + 1;
        end
    endtask

    // Check video passthrough against expected pixel array.
    task automatic check_vid_passthrough(input logic [23:0] expected [NUM_PIX], input string label);
        integer i;
        for (i = 0; i < NUM_PIX; i = i + 1) begin
            if (cap_vid[i] !== expected[i]) begin
                $display("FAIL %s vid px%0d: got %06h exp %06h",
                         label, i, cap_vid[i], expected[i]);
                num_errors = num_errors + 1;
            end
        end
        $display("%s: vid passthrough check done", label);
    endtask

    // Check mask bits against golden per-pixel expected array.
    task automatic check_mask_golden(input logic [7:0] y_p [NUM_PIX],
                                     input logic [23:0] pixels [NUM_PIX],
                                     input string label);
        integer i;
        logic [7:0] y_c, diff;
        logic exp_msk;
        for (i = 0; i < NUM_PIX; i = i + 1) begin
            y_c     = y_of(pixels[i]);
            diff    = (y_c > y_p[i]) ? (y_c - y_p[i]) : (y_p[i] - y_c);
            exp_msk = (diff > THRESH[7:0]);
            if (cap_msk[i] !== exp_msk) begin
                $display("FAIL %s msk px%0d: got=%0b exp=%0b y_cur=%0d y_prev=%0d diff=%0d",
                         label, i, cap_msk[i], exp_msk, y_c, y_p[i], diff);
                num_errors = num_errors + 1;
            end
        end
        $display("%s: mask golden check done", label);
    endtask

    // Read RAM via port B and compare against expected EMA y_prev array.
    // Must be called AFTER update_y_prev so y_prev holds the expected EMA values.
    task automatic check_ram_ema(input string label);
        integer i;
        logic [7:0] got_y;
        // RAM is registered — need 2 cycles after address to get data
        for (i = 0; i < NUM_PIX; i = i + 1) begin
            b_rd_addr = (ADDR_W)'(i);
            @(posedge clk);
            @(posedge clk);  // wait for registered read
            got_y = b_rd_data;
            if (got_y !== y_prev[i]) begin
                $display("FAIL %s RAM[%0d]: got %0d exp %0d", label, i, got_y, y_prev[i]);
                num_errors = num_errors + 1;
            end
        end
        b_rd_addr = '0;
        $display("%s: RAM EMA check done", label);
    endtask

    // Update y_prev[] using EMA: bg_new = bg + ((y_cur - bg) >>> ALPHA_SHIFT)
    task automatic update_y_prev(input logic [23:0] pixels [NUM_PIX]);
        integer i;
        logic [7:0] y_c;
        logic signed [8:0] delta, step;
        for (i = 0; i < NUM_PIX; i = i + 1) begin
            y_c   = y_of(pixels[i]);
            delta = {1'b0, y_c} - {1'b0, y_prev[i]};
            step  = delta >>> ALPHA_SHIFT;
            y_prev[i] = y_prev[i] + step[7:0];
        end
    endtask

    // Build mixed_pixels relative to current y_prev (EMA state).
    // Pixels are crafted so y_of(mixed_pixels[i]) = y_prev[i] + delta.
    // Deltas cycle: THRESH-1, THRESH, THRESH+1, 0.
    task automatic build_mixed_pixels;
        integer i;
        logic [7:0] yp;
        integer delta, target_y;
        for (i = 0; i < NUM_PIX; i = i + 1) begin
            yp = y_prev[i];
            case (i % 4)
                0:       delta = THRESH - 1;  // expect mask=0
                1:       delta = THRESH;       // expect mask=0 (strict >)
                2:       delta = THRESH + 1;   // expect mask=1
                default: delta = 0;            // expect mask=0
            endcase
            target_y = yp + delta;
            if (target_y > 255) target_y = 255;
            // Gray pixel R=G=B=v gives Y=v (since (77+150+29)*v >> 8 = v)
            mixed_pixels[i] = {8'(target_y), 8'(target_y), 8'(target_y)};
        end
    endtask

    // ---- Concurrent capture ----
    integer vid_cap_cnt = 0;
    integer msk_cap_cnt = 0;

    always @(posedge clk) begin
        if (vid_tvalid && vid_tready && vid_cap_cnt < NUM_PIX) begin
            cap_vid[vid_cap_cnt] = vid_tdata;
            vid_cap_cnt = vid_cap_cnt + 1;
        end
        if (msk_tvalid && msk_tready && msk_cap_cnt < NUM_PIX) begin
            cap_msk[msk_cap_cnt] = msk_tdata;
            msk_cap_cnt = msk_cap_cnt + 1;
        end
    end

    // ---- Reset capture counters before each frame ----
    task automatic reset_capture;
        vid_cap_cnt = 0;
        msk_cap_cnt = 0;
    endtask

    // ---- Main test ----
    integer j;

    initial begin
        // Initialise pixel arrays
        frame_pixels[0] = 24'hFF_00_00;  // red
        frame_pixels[1] = 24'h00_FF_00;  // green
        frame_pixels[2] = 24'h00_00_FF;  // blue
        frame_pixels[3] = 24'hFF_FF_00;  // yellow
        frame_pixels[4] = 24'h80_80_80;  // gray
        frame_pixels[5] = 24'hFF_FF_FF;  // white
        frame_pixels[6] = 24'h40_80_C0;
        frame_pixels[7] = 24'hC0_40_80;

        // y_prev starts at 0 (RAM zero-init)
        for (j = 0; j < NUM_PIX; j = j + 1)
            y_prev[j] = 8'h00;

        // mixed_pixels are built dynamically after frame 1 (see build_mixed below)

        // ---- Reset ----
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ================================================================
        // Frame 0: RAM zero-init → y_prev=0, golden mask per pixel
        // ================================================================
        $display("=== Frame 0 (y_prev=0, golden mask + vid passthrough) ===");
        reset_capture();
        fork
            drive_frame(frame_pixels);
            wait_frame_captured();
        join
        repeat (5) @(posedge clk);
        check_vid_passthrough(frame_pixels, "frame0");
        check_mask_golden(y_prev, frame_pixels, "frame0");
        // y_prev stays 0 for checking frame 0; update after checks
        update_y_prev(frame_pixels);

        // ================================================================
        // Frame 1: same pixels, EMA y_prev from frame 0 → golden mask; RAM EMA check
        // ================================================================
        $display("=== Frame 1 (same pixels, EMA y_prev, RAM EMA check) ===");
        reset_capture();
        fork
            drive_frame(frame_pixels);
            wait_frame_captured();
        join
        repeat (5) @(posedge clk);
        check_vid_passthrough(frame_pixels, "frame1");
        check_mask_golden(y_prev, frame_pixels, "frame1");
        update_y_prev(frame_pixels);
        // Wait a few extra cycles for last RAM write-back to settle
        repeat (5) @(posedge clk);
        check_ram_ema("frame1");

        // Build mixed_pixels now that y_prev reflects EMA state after frame 1
        build_mixed_pixels();

        // ================================================================
        // Frame 2: mixed-motion — threshold boundary vs EMA y_prev
        // ================================================================
        $display("=== Frame 2 (mixed-motion, threshold boundary) ===");
        reset_capture();
        fork
            drive_frame(mixed_pixels);
            wait_frame_captured();
        join
        repeat (5) @(posedge clk);
        check_vid_passthrough(mixed_pixels, "frame2");
        check_mask_golden(y_prev, mixed_pixels, "frame2");
        update_y_prev(mixed_pixels);

        // ================================================================
        // Frame 3: same mixed-motion under consumer stall
        // ================================================================
        $display("=== Frame 3 (mixed-motion + stall) ===");
        reset_capture();
        stall_active = 1'b1;
        fork
            drive_frame(mixed_pixels);
            wait_frame_captured();
        join
        stall_active = 1'b0;
        repeat (5) @(posedge clk);
        check_vid_passthrough(mixed_pixels, "frame3");
        check_mask_golden(y_prev, mixed_pixels, "frame3");
        update_y_prev(mixed_pixels);
        // RAM should now hold EMA-updated values from frame 3
        repeat (5) @(posedge clk);
        check_ram_ema("frame3");

        // ================================================================
        // Frame 4: asymmetric stall — vid stalls, msk stays ready
        // If the fork logic is broken, the msk consumer will re-accept
        // the same pixel during vid stall → msk_cap_cnt > vid_cap_cnt.
        // ================================================================
        $display("=== Frame 4 (asymmetric stall: vid stalls, msk ready) ===");
        // Rebuild mixed_pixels from current y_prev
        build_mixed_pixels();
        reset_capture();
        stall_active = 1'b1;
        stall_mode   = 1;  // vid-only stall
        fork
            drive_frame(mixed_pixels);
            wait_frame_captured();
        join
        stall_active = 1'b0;
        stall_mode   = 0;
        repeat (5) @(posedge clk);
        // Fork desync check: both channels must capture exactly NUM_PIX
        if (vid_cap_cnt !== msk_cap_cnt) begin
            $display("FAIL frame4 fork desync: vid_cap_cnt=%0d msk_cap_cnt=%0d (expected %0d each)",
                     vid_cap_cnt, msk_cap_cnt, NUM_PIX);
            num_errors = num_errors + 1;
        end
        check_vid_passthrough(mixed_pixels, "frame4");
        check_mask_golden(y_prev, mixed_pixels, "frame4");
        update_y_prev(mixed_pixels);

        // ================================================================
        // Frame 5: asymmetric stall — msk stalls, vid stays ready (mirror)
        // ================================================================
        $display("=== Frame 5 (asymmetric stall: msk stalls, vid ready) ===");
        build_mixed_pixels();
        reset_capture();
        stall_active = 1'b1;
        stall_mode   = 2;  // msk-only stall
        fork
            drive_frame(mixed_pixels);
            wait_frame_captured();
        join
        stall_active = 1'b0;
        stall_mode   = 0;
        repeat (5) @(posedge clk);
        if (vid_cap_cnt !== msk_cap_cnt) begin
            $display("FAIL frame5 fork desync: vid_cap_cnt=%0d msk_cap_cnt=%0d (expected %0d each)",
                     vid_cap_cnt, msk_cap_cnt, NUM_PIX);
            num_errors = num_errors + 1;
        end
        check_vid_passthrough(mixed_pixels, "frame5");
        check_mask_golden(y_prev, mixed_pixels, "frame5");
        update_y_prev(mixed_pixels);

        // ================================================================
        // Summary
        // ================================================================
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_motion_detect FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_motion_detect PASSED — 6 frames OK");
            $finish;
        end
    end

endmodule
