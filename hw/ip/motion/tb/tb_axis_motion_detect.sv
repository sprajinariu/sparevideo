// Unit testbench for axis_motion_detect.
//
// Tests:
//   Frame 0 — RAM zero-init, non-black input → all mask bits 1 (motion on every pixel)
//   Frame 1 — identical pixels → diff 0 → all mask bits 0
//   Frame 2 — identical pixels again, but consumer deasserts ready for long stretches
//             → verifies pipeline stall logic holds data without dropping pixels
//
// Conventions: drv_* intermediaries, posedge register, $display/$fatal.

`timescale 1ns / 1ps

module tb_axis_motion_detect;

    localparam int H = 4;
    localparam int V = 2;
    localparam int THRESH = 16;
    localparam int NUM_PIX = H * V;
    localparam int CLK_PERIOD = 10;

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    logic rst_n;

    // ---- Driver intermediaries ----
    logic [23:0] drv_tdata  = '0;
    logic        drv_tvalid = 1'b0;
    logic        drv_tlast  = 1'b0;
    logic        drv_tuser  = 1'b0;

    logic [23:0] s_tdata;
    logic        s_tvalid;
    logic        s_tready;
    logic        s_tlast;
    logic        s_tuser;

    always_ff @(posedge clk) begin
        s_tdata  <= drv_tdata;
        s_tvalid <= drv_tvalid;
        s_tlast  <= drv_tlast;
        s_tuser  <= drv_tuser;
    end

    // ---- DUT outputs ----
    logic [23:0] vid_tdata;
    logic        vid_tvalid;
    logic        vid_tlast;
    logic        vid_tuser;

    logic        msk_tdata;
    logic        msk_tvalid;
    logic        msk_tlast;
    logic        msk_tuser;

    // Ready signals — driven by the test (not hardwired).
    logic drv_vid_rdy = 1'b1;
    logic drv_msk_rdy = 1'b1;
    logic vid_tready;
    logic msk_tready;
    assign vid_tready = drv_vid_rdy;
    assign msk_tready = drv_msk_rdy;

    // ---- Stall-pattern generator ----
    // When stall_active=1 the consumer deasserts ready for STALL_LEN cycles,
    // then reasserts for OPEN_LEN cycles, repeating indefinitely.
    // Controlled from the initial block via blocking assignment.
    localparam int STALL_LEN = 10;
    localparam int OPEN_LEN  = 3;

    logic stall_active = 1'b0;
    integer stall_ctr  = 0;

    always_ff @(posedge clk) begin
        if (stall_active) begin
            if (stall_ctr < STALL_LEN - 1) begin
                drv_vid_rdy <= 1'b0;
                drv_msk_rdy <= 1'b0;
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

    // ---- RAM instance ----
    localparam int RAM_DEPTH = NUM_PIX;
    localparam int ADDR_W = $clog2(RAM_DEPTH);

    logic [ADDR_W-1:0] a_rd_addr, a_wr_addr;
    logic [7:0]        a_rd_data, a_wr_data;
    logic              a_wr_en;

    ram #(.DEPTH(RAM_DEPTH)) u_ram (
        .clk_i       (clk),
        .a_rd_addr_i (a_rd_addr),
        .a_rd_data_o (a_rd_data),
        .a_wr_addr_i (a_wr_addr),
        .a_wr_data_i (a_wr_data),
        .a_wr_en_i   (a_wr_en),
        .b_rd_addr_i ('0),
        .b_rd_data_o (),
        .b_wr_addr_i ('0),
        .b_wr_data_i ('0),
        .b_wr_en_i   (1'b0)
    );

    // ---- DUT ----
    axis_motion_detect #(
        .H_ACTIVE (H),
        .V_ACTIVE (V),
        .THRESH   (THRESH),
        .RGN_BASE (0),
        .RGN_SIZE (NUM_PIX)
    ) u_dut (
        .clk_i                (clk),
        .rst_n_i              (rst_n),
        .s_axis_tdata_i       (s_tdata),
        .s_axis_tvalid_i      (s_tvalid),
        .s_axis_tready_o      (s_tready),
        .s_axis_tlast_i       (s_tlast),
        .s_axis_tuser_i       (s_tuser),
        .m_axis_vid_tdata_o   (vid_tdata),
        .m_axis_vid_tvalid_o  (vid_tvalid),
        .m_axis_vid_tready_i  (vid_tready),
        .m_axis_vid_tlast_o   (vid_tlast),
        .m_axis_vid_tuser_o   (vid_tuser),
        .m_axis_msk_tdata_o   (msk_tdata),
        .m_axis_msk_tvalid_o  (msk_tvalid),
        .m_axis_msk_tready_i  (msk_tready),
        .m_axis_msk_tlast_o   (msk_tlast),
        .m_axis_msk_tuser_o   (msk_tuser),
        .mem_rd_addr_o        (a_rd_addr),
        .mem_rd_data_i        (a_rd_data),
        .mem_wr_addr_o        (a_wr_addr),
        .mem_wr_data_o        (a_wr_data),
        .mem_wr_en_o          (a_wr_en)
    );

    // ---- Test pixel data ----
    logic [23:0] frame_pixels [NUM_PIX];
    initial begin
        frame_pixels[0] = 24'hFF_00_00;
        frame_pixels[1] = 24'h00_FF_00;
        frame_pixels[2] = 24'h00_00_FF;
        frame_pixels[3] = 24'hFF_FF_00;
        frame_pixels[4] = 24'h80_80_80;
        frame_pixels[5] = 24'hFF_FF_FF;
        frame_pixels[6] = 24'h40_80_C0;
        frame_pixels[7] = 24'hC0_40_80;
    end

    integer num_errors = 0;

    // ---- Capture mask outputs ----
    // Only capture when both valid AND ready are asserted (actual handshake).
    integer msk_count;
    logic mask_results [NUM_PIX];

    task automatic capture_frame_mask;
        msk_count = 0;
        while (msk_count < NUM_PIX) begin
            @(posedge clk);
            if (msk_tvalid && msk_tready) begin
                mask_results[msk_count] = msk_tdata;
                msk_count = msk_count + 1;
            end
        end
    endtask

    // ---- Drive one frame ----
    task automatic drive_frame;
        integer px;
        for (px = 0; px < NUM_PIX; px = px + 1) begin
            drv_tdata  = frame_pixels[px];
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

    // ---- Check helper ----
    task automatic check_mask(input logic expected, input string label);
        integer i;
        for (i = 0; i < NUM_PIX; i = i + 1) begin
            if (mask_results[i] !== expected) begin
                $display("FAIL %s pixel %0d: mask=%0b, expected %0b",
                         label, i, mask_results[i], expected);
                num_errors = num_errors + 1;
            end
        end
        $display("%s check done", label);
    endtask

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- Frame 0: RAM is zero → all pixels should produce motion ----
        $display("Driving frame 0 (expect all mask=1)...");
        fork
            drive_frame();
            capture_frame_mask();
        join
        repeat (10) @(posedge clk);
        check_mask(1'b1, "frame 0");

        // ---- Frame 1: same pixels → diff 0 → mask all 0 ----
        $display("Driving frame 1 (expect all mask=0)...");
        fork
            drive_frame();
            capture_frame_mask();
        join
        repeat (10) @(posedge clk);
        check_mask(1'b0, "frame 1");

        // ---- Frame 2: stall test ----
        // Same pixels as frame 1 → diff still 0 → mask still all 0.
        // Consumer deasserts ready for STALL_LEN cycles every OPEN_LEN cycles.
        // Verifies that the pipeline stall logic holds pixels without dropping them.
        $display("Driving frame 2 (stall test, expect all mask=0)...");
        stall_active = 1'b1;
        fork
            drive_frame();
            capture_frame_mask();
        join
        stall_active = 1'b0;
        repeat (10) @(posedge clk);
        check_mask(1'b0, "frame 2 (stall test)");

        // ---- Summary ----
        if (num_errors > 0) begin
            $fatal(1, "tb_axis_motion_detect FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_axis_motion_detect PASSED — 3 frames OK (incl. stall test)");
            $finish;
        end
    end

endmodule
