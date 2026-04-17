// Unit testbench for axis_motion_detect.
//
// Parameterized by GAUSS_EN (default 0). Two Makefile targets compile this TB:
//   test-ip-motion-detect       — GAUSS_EN=0 (raw Y)
//   test-ip-motion-detect-gauss — GAUSS_EN=1 (Gaussian pre-filter on Y)
//
// Tests (in order):
//   Frame 0 — RAM zero-init → golden mask per pixel, RGB passthrough check
//   Frame 1 — same pixels, EMA-updated y_prev → golden mask check, RAM EMA verify
//   Frame 2 — mixed-motion: pixels crafted for threshold boundary vs EMA y_prev
//   Frame 3 — same mixed-motion under consumer stall → verifies stall correctness
//   Frame 4 — asymmetric stall: only vid stalls, msk stays ready → verifies no
//             duplicate transfers on the ready channel (fork desync bug)
//   Frame 5 — asymmetric stall: only msk stalls, vid stays ready → mirror test
//   Frame 6 — bright-block pattern → spatial variation for Gaussian edge smoothing
//   Frame 7 — same bright-block under symmetric stall → Gaussian + stall correctness
//
// When GAUSS_EN=0, the golden model uses raw Y for mask/EMA computation.
// When GAUSS_EN=1, the golden model applies a 3x3 Gaussian with causal streaming
// offset (kernel centered at (r-1, c-1)) before mask/EMA, matching the RTL.
//
// EMA background model: y_prev = y_prev + ((y_cur - y_prev) >>> ALPHA_SHIFT)
//
// Conventions: drv_* intermediaries, posedge register, $display/$fatal.

`timescale 1ns / 1ps

module tb_axis_motion_detect #(
    parameter int GAUSS_EN = 0
);

    localparam int H           = 16;
    localparam int V           = 8;
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
        .GAUSS_EN    (GAUSS_EN),
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
    // frame_pixels: base pixel set (used for frames 0-5)
    logic [23:0] frame_pixels [NUM_PIX];
    // mixed_pixels: crafted for threshold boundary (frames 2-5)
    logic [23:0] mixed_pixels [NUM_PIX];
    // block_pixels: bright block on dark background (frames 6-7)
    logic [23:0] block_pixels [NUM_PIX];
    // y_prev: Y8 values from the previously driven frame (updated by TB).
    // Stored as 1D flat array, but for Gaussian computation we index as [r*H+c].
    logic [7:0]  y_prev [NUM_PIX];

    // ---- Capture arrays ----
    logic [23:0] cap_vid [NUM_PIX];
    logic        cap_msk [NUM_PIX];

    integer num_errors = 0;

    // ---- Gaussian golden model ----
    // 3x3 Gaussian with causal streaming offset: kernel centered at (r-1, c-1).
    // Edge replication (clamp to image bounds). Integer >>4 truncation.
    // When GAUSS_EN=0, returns raw Y unchanged.
    function automatic logic [7:0] gauss_at(
        input logic [7:0] y_flat [NUM_PIX],
        input int r, input int c
    );
        int cr, cc, sum, wr, wc;
        if (GAUSS_EN == 0)
            return y_flat[r * H + c];
        sum = 0;
        for (int dr = 0; dr < 3; dr++) begin
            for (int dc = 0; dc < 3; dc++) begin
                // Window centered at (r-1, c-1): rows r-2..r, cols c-2..c
                cr = r - 2 + dr;
                cc = c - 2 + dc;
                if (cr < 0) cr = 0;
                else if (cr >= V) cr = V - 1;
                if (cc < 0) cc = 0;
                else if (cc >= H) cc = H - 1;
                // Separable kernel: [1,2,1] x [1,2,1]
                wr = (dr == 1) ? 2 : 1;
                wc = (dc == 1) ? 2 : 1;
                sum = sum + wr * wc * int'({24'b0, y_flat[cr * H + cc]});
            end
        end
        return 8'(sum >> 4);
    endfunction

    // Compute effective Y (raw or Gaussian-filtered) for a full frame.
    // Returns result in y_eff[].
    logic [7:0] y_eff [NUM_PIX];

    task automatic compute_y_eff(input logic [23:0] pixels [NUM_PIX]);
        logic [7:0] y_raw [NUM_PIX];
        for (int i = 0; i < NUM_PIX; i++)
            y_raw[i] = y_of(pixels[i]);
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                y_eff[r * H + c] = gauss_at(y_raw, r, c);
    endtask

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
        while ((vid_cap_cnt < NUM_PIX || msk_cap_cnt < NUM_PIX) && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 50000) begin
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

    // Check mask bits against golden model (uses y_eff[] — must call compute_y_eff first).
    task automatic check_mask_golden(input logic [23:0] pixels [NUM_PIX], input string label);
        integer i;
        logic [7:0] yc, diff;
        logic exp_msk;
        compute_y_eff(pixels);
        for (i = 0; i < NUM_PIX; i = i + 1) begin
            yc      = y_eff[i];
            diff    = (yc > y_prev[i]) ? (yc - y_prev[i]) : (y_prev[i] - yc);
            exp_msk = (diff > THRESH[7:0]);
            if (cap_msk[i] !== exp_msk) begin
                $display("FAIL %s msk px%0d (%0d,%0d): got=%0b exp=%0b yeff=%0d yprev=%0d d=%0d",
                         label, i, i/H, i%H, cap_msk[i], exp_msk, yc, y_prev[i], diff);
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

    // Update y_prev[] using EMA on effective Y (raw or Gaussian-filtered).
    // Must call compute_y_eff before this (y_eff[] is used).
    task automatic update_y_prev(input logic [23:0] pixels [NUM_PIX]);
        logic signed [8:0] delta, step;
        compute_y_eff(pixels);
        for (int i = 0; i < NUM_PIX; i++) begin
            delta     = {1'b0, y_eff[i]} - {1'b0, y_prev[i]};
            step      = delta >>> ALPHA_SHIFT;
            y_prev[i] = y_prev[i] + step[7:0];
        end
    endtask

    // Build mixed_pixels relative to current y_prev (EMA state).
    // Pixels are crafted so the effective Y produces a known diff vs y_prev.
    // For GAUSS_EN=0, y_of(gray_pixel) = v exactly (since 77+150+29 = 256).
    // For GAUSS_EN=1, the Gaussian smooths neighbors, so we use a uniform-value
    // frame per row-band where the Gaussian has no spatial effect (all neighbors
    // are identical → Gaussian output = input).
    //
    // Deltas cycle per row: THRESH-1 (mask=0), THRESH (mask=0, strict >),
    //                       THRESH+1 (mask=1), 0 (mask=0).
    task automatic build_mixed_pixels;
        integer i, row;
        logic [7:0] yp_center;
        integer delta, target_y;
        for (i = 0; i < NUM_PIX; i = i + 1) begin
            // Use the center-of-row y_prev as baseline. For GAUSS_EN=1, all pixels
            // in the same row get the same value, so the Gaussian has no spatial
            // effect (uniform row → gauss output = input).
            row = i / H;
            yp_center = y_prev[row * H + H / 2];
            case (row % 4)
                0:       delta = THRESH - 1;  // expect mask=0
                1:       delta = THRESH;       // expect mask=0 (strict >)
                2:       delta = THRESH + 1;   // expect mask=1
                default: delta = 0;            // expect mask=0
            endcase
            target_y = yp_center + delta;
            if (target_y > 255) target_y = 255;
            // Gray pixel R=G=B=v gives Y=v
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
        // Initialise frame_pixels: use varied colors across the 16x8 frame.
        // Row 0-1: reds/greens/blues/yellows (repeating 4-pixel pattern)
        // Row 2-3: grays at different intensities
        // Row 4-5: same as rows 0-1 (tests spatial variation across rows)
        // Row 6-7: bright colors
        for (j = 0; j < NUM_PIX; j = j + 1) begin
            case (j % 8)
                0:       frame_pixels[j] = 24'hFF_00_00;  // red
                1:       frame_pixels[j] = 24'h00_FF_00;  // green
                2:       frame_pixels[j] = 24'h00_00_FF;  // blue
                3:       frame_pixels[j] = 24'hFF_FF_00;  // yellow
                4:       frame_pixels[j] = 24'h80_80_80;  // gray
                5:       frame_pixels[j] = 24'hFF_FF_FF;  // white
                6:       frame_pixels[j] = 24'h40_80_C0;
                default: frame_pixels[j] = 24'hC0_40_80;
            endcase
        end

        // Initialise block_pixels: bright block at rows 2-5, cols 4-11; dark elsewhere.
        // Gray pixels R=G=B=v → Y=v (since 77+150+29 = 256).
        // Provides spatial variation for Gaussian edge smoothing tests.
        for (j = 0; j < NUM_PIX; j = j + 1) begin
            if (j / H >= 2 && j / H <= 5 && j % H >= 4 && j % H <= 11)
                block_pixels[j] = 24'hC8_C8_C8;  // Y=200
            else
                block_pixels[j] = 24'h00_00_00;  // Y=0
        end

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
        check_mask_golden(frame_pixels, "frame0");
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
        check_mask_golden(frame_pixels, "frame1");
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
        check_mask_golden(mixed_pixels, "frame2");
        update_y_prev(mixed_pixels);

        // ================================================================
        // Frame 3: same mixed-motion under consumer stall
        // ================================================================
        $display("=== Frame 3 (mixed-motion + stall) ===");
        build_mixed_pixels();
        reset_capture();
        stall_active = 1'b1;
        fork
            drive_frame(mixed_pixels);
            wait_frame_captured();
        join
        stall_active = 1'b0;
        repeat (5) @(posedge clk);
        check_vid_passthrough(mixed_pixels, "frame3");
        check_mask_golden(mixed_pixels, "frame3");
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
        check_mask_golden(mixed_pixels, "frame4");
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
        check_mask_golden(mixed_pixels, "frame5");
        update_y_prev(mixed_pixels);

        // ================================================================
        // Frame 6: bright block on dark background — spatial variation
        // for Gaussian edge smoothing (mask at block boundaries changes
        // with GAUSS_EN=1 vs 0). No stall.
        // ================================================================
        $display("=== Frame 6 (bright block, spatial Gaussian test) ===");
        reset_capture();
        fork
            drive_frame(block_pixels);
            wait_frame_captured();
        join
        repeat (5) @(posedge clk);
        check_vid_passthrough(block_pixels, "frame6");
        check_mask_golden(block_pixels, "frame6");
        update_y_prev(block_pixels);
        repeat (5) @(posedge clk);
        check_ram_ema("frame6");

        // ================================================================
        // Frame 7: same bright block under symmetric stall — verifies
        // Gaussian + pipeline stall interaction doesn't corrupt data.
        // ================================================================
        $display("=== Frame 7 (bright block + stall) ===");
        reset_capture();
        stall_active = 1'b1;
        fork
            drive_frame(block_pixels);
            wait_frame_captured();
        join
        stall_active = 1'b0;
        repeat (5) @(posedge clk);
        check_vid_passthrough(block_pixels, "frame7");
        check_mask_golden(block_pixels, "frame7");
        update_y_prev(block_pixels);
        repeat (5) @(posedge clk);
        check_ram_ema("frame7");

        // ================================================================
        // Summary
        // ================================================================
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_motion_detect (GAUSS_EN=%0d) FAILED: %0d errors",
                   GAUSS_EN, num_errors);
        end else begin
            $display("tb_axis_motion_detect (GAUSS_EN=%0d) PASSED — 8 frames OK", GAUSS_EN);
            $finish;
        end
    end

endmodule
