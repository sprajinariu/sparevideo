// sparevideo_top — AXI4-Stream video pipeline top level.
//
//   s_axis (clk_pix) -> async_fifo -> motion detect pipeline (clk_dsp)
//                                  -> async_fifo -> vga_controller (clk_pix)
//                                                -> RGB + hsync/vsync
//
// Motion detect pipeline (clk_dsp domain):
//   axis_motion_detect -> axis_overlay_bbox -> output async FIFO
//   axis_motion_detect -> axis_bbox_reduce  -> sideband bbox -> axis_overlay_bbox
//   axis_motion_detect <-> ram port A (Y8 prev-frame buffer)
//
// Vendored verilog-axis (MIT) provides the async FIFOs.
// All AXI4-Stream signals carry 24-bit RGB ({R,G,B}), tlast = end-of-line,
// tuser[0] = start-of-frame.
//
// Configuration parameters default to sparevideo_pkg values. Override at
// instantiation for different resolutions or algorithm settings.

module sparevideo_top #(
    parameter int H_ACTIVE      = sparevideo_pkg::H_ACTIVE,
    parameter int H_FRONT_PORCH = sparevideo_pkg::H_FRONT_PORCH,
    parameter int H_SYNC_PULSE  = sparevideo_pkg::H_SYNC_PULSE,
    parameter int H_BACK_PORCH  = sparevideo_pkg::H_BACK_PORCH,
    parameter int V_ACTIVE      = sparevideo_pkg::V_ACTIVE,
    parameter int V_FRONT_PORCH = sparevideo_pkg::V_FRONT_PORCH,
    parameter int V_SYNC_PULSE  = sparevideo_pkg::V_SYNC_PULSE,
    parameter int V_BACK_PORCH  = sparevideo_pkg::V_BACK_PORCH,
    // Motion detect threshold — override at instantiation or compile time.
    // Pixels with abs(Y_cur - Y_prev) > MOTION_THRESH are flagged as motion.
    parameter int MOTION_THRESH = 16
) (
    // ---- Clocks & resets -------------------------------------------
    input  logic        clk_pix,        // 25 MHz pixel clock (input + VGA output domain)
    input  logic        clk_dsp,        // 100 MHz processing clock (CDC FIFOs cross to here)
    input  logic        rst_pix_n,      // active-low synchronous reset, clk_pix domain
    input  logic        rst_dsp_n,      // active-low synchronous reset, clk_dsp domain

    // ---- AXI4-Stream video input (clk_pix domain) ------------------
    input  logic [23:0] s_axis_tdata,   // pixel payload, packed {R[7:0], G[7:0], B[7:0]}
    input  logic        s_axis_tvalid,  // producer asserts when tdata is valid
    output logic        s_axis_tready,  // sink ready; back-pressures producer when low
    input  logic        s_axis_tlast,   // end-of-line marker (asserted on last pixel of each row)
    input  logic        s_axis_tuser,   // start-of-frame marker (asserted on first pixel of frame)

    // ---- VGA output (clk_pix domain) -------------------------------
    output logic        vga_hsync,      // horizontal sync, active-low
    output logic        vga_vsync,      // vertical sync, active-low
    output logic [7:0]  vga_r,          // red channel (valid during active region, else 0)
    output logic [7:0]  vga_g,          // green channel
    output logic [7:0]  vga_b           // blue channel
);

    // verilog-axis modules use active-high resets internally.
    logic rst_pix;
    logic rst_dsp;
    assign rst_pix = ~rst_pix_n;
    assign rst_dsp = ~rst_dsp_n;

    // FIFO overflow flags (write-clock domain; sticky until reset).
    // Checked by SVAs below.
    logic fifo_in_overflow;   // clk_pix domain (input FIFO write side)
    logic fifo_out_overflow;  // clk_dsp domain (output FIFO write side)

    // -----------------------------------------------------------------
    // Input async FIFO: clk_pix -> clk_dsp
    // -----------------------------------------------------------------
    localparam int IN_FIFO_DEPTH = 32;

    logic [23:0] dsp_in_tdata;
    logic        dsp_in_tvalid;
    logic        dsp_in_tready;
    logic        dsp_in_tlast;
    logic        dsp_in_tuser;

    logic [$clog2(IN_FIFO_DEPTH):0] fifo_in_depth;   // write-side (clk_pix)

    axis_async_fifo #(
        .DEPTH       (IN_FIFO_DEPTH),
        .DATA_WIDTH  (24),
        .KEEP_ENABLE (0),
        .LAST_ENABLE (1),
        .ID_ENABLE   (0),
        .DEST_ENABLE (0),
        .USER_ENABLE (1),
        .USER_WIDTH  (1),
        .FRAME_FIFO  (0)
    ) u_fifo_in (
        .s_clk            (clk_pix),
        .s_rst            (rst_pix),
        .s_axis_tdata     (s_axis_tdata),
        .s_axis_tkeep     (3'b0),
        .s_axis_tvalid    (s_axis_tvalid),
        .s_axis_tready    (s_axis_tready),
        .s_axis_tlast     (s_axis_tlast),
        .s_axis_tid       (8'b0),
        .s_axis_tdest     (8'b0),
        .s_axis_tuser     (s_axis_tuser),

        .m_clk            (clk_dsp),
        .m_rst            (rst_dsp),
        .m_axis_tdata     (dsp_in_tdata),
        .m_axis_tkeep     (),
        .m_axis_tvalid    (dsp_in_tvalid),
        .m_axis_tready    (dsp_in_tready),
        .m_axis_tlast     (dsp_in_tlast),
        .m_axis_tid       (),
        .m_axis_tdest     (),
        .m_axis_tuser     (dsp_in_tuser),

        .s_pause_req      (1'b0),
        .s_pause_ack      (),
        .m_pause_req      (1'b0),
        .m_pause_ack      (),

        .s_status_depth        (fifo_in_depth),
        .s_status_depth_commit (),
        .s_status_overflow     (fifo_in_overflow),
        .s_status_bad_frame    (),
        .s_status_good_frame   (),
        .m_status_depth        (),
        .m_status_depth_commit (),
        .m_status_overflow     (),
        .m_status_bad_frame    (),
        .m_status_good_frame   ()
    );

    // -----------------------------------------------------------------
    // Control parameter — MOTION_THRESH is a module parameter (see above).
    // Region descriptor table (future CSR content):
    //   each region = {BASE (byte offset in `ram`), SIZE (bytes)}.
    //   Owners must only touch [BASE, BASE+SIZE). Sum(SIZE) <= RAM_DEPTH.
    // -----------------------------------------------------------------
    localparam int RGN_Y_PREV_BASE = 0;
    localparam int RGN_Y_PREV_SIZE = H_ACTIVE * V_ACTIVE;
    localparam int RAM_DEPTH       = RGN_Y_PREV_SIZE;
    localparam int RAM_ADDR_W      = $clog2(RAM_DEPTH);

    localparam logic [23:0] BBOX_COLOR = 24'h00_FF_00;  // bright green

    initial begin
        if (RGN_Y_PREV_BASE + RGN_Y_PREV_SIZE > RAM_DEPTH)
            $error("ram region table overflows RAM_DEPTH");
    end

    // -----------------------------------------------------------------
    // Shared RAM (port A: motion detect; port B: reserved for future host)
    // -----------------------------------------------------------------
    logic [RAM_ADDR_W-1:0] ram_a_rd_addr, ram_a_wr_addr;
    logic [7:0]            ram_a_rd_data, ram_a_wr_data;
    logic                  ram_a_wr_en;

    ram #(.DEPTH(RAM_DEPTH)) u_ram (
        .clk       (clk_dsp),
        .a_rd_addr (ram_a_rd_addr),
        .a_rd_data (ram_a_rd_data),
        .a_wr_addr (ram_a_wr_addr),
        .a_wr_data (ram_a_wr_data),
        .a_wr_en   (ram_a_wr_en),
        // Port B: tied off — future host client lands here.
        .b_rd_addr ('0),
        .b_rd_data (),
        .b_wr_addr ('0),
        .b_wr_data ('0),
        .b_wr_en   (1'b0)
    );

    // -----------------------------------------------------------------
    // Motion detect pipeline on clk_dsp
    //   axis_motion_detect: RGB in → vid passthrough + mask stream
    //   axis_bbox_reduce:   mask → latched {min_x,max_x,min_y,max_y}
    //   axis_overlay_bbox:  vid + bbox sideband → overlaid RGB out
    // -----------------------------------------------------------------

    // Video passthrough from motion detect (RGB, latency-matched)
    logic [23:0] vid_tdata;
    logic        vid_tvalid;
    logic        vid_tready;
    logic        vid_tlast;
    logic        vid_tuser;

    // Motion mask stream (1-bit per pixel)
    logic        msk_tdata;
    logic        msk_tvalid;
    logic        msk_tready;
    logic        msk_tlast;
    logic        msk_tuser;

    // Bbox sideband (latched once per frame by bbox_reduce)
    logic [$clog2(H_ACTIVE)-1:0] bbox_min_x, bbox_max_x;
    logic [$clog2(V_ACTIVE)-1:0] bbox_min_y, bbox_max_y;
    logic                        bbox_empty;

    // Overlay output (to output async FIFO)
    logic [23:0] ovl_tdata;
    logic        ovl_tvalid;
    logic        ovl_tready;
    logic        ovl_tlast;
    logic        ovl_tuser;

    axis_motion_detect #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE),
        .THRESH   (MOTION_THRESH),
        .RGN_BASE (RGN_Y_PREV_BASE),
        .RGN_SIZE (RGN_Y_PREV_SIZE)
    ) u_motion_detect (
        .clk                (clk_dsp),
        .rst_n              (rst_dsp_n),
        .s_axis_tdata       (dsp_in_tdata),
        .s_axis_tvalid      (dsp_in_tvalid),
        .s_axis_tready      (dsp_in_tready),
        .s_axis_tlast       (dsp_in_tlast),
        .s_axis_tuser       (dsp_in_tuser),
        .m_axis_vid_tdata   (vid_tdata),
        .m_axis_vid_tvalid  (vid_tvalid),
        .m_axis_vid_tready  (vid_tready),
        .m_axis_vid_tlast   (vid_tlast),
        .m_axis_vid_tuser   (vid_tuser),
        .m_axis_msk_tdata   (msk_tdata),
        .m_axis_msk_tvalid  (msk_tvalid),
        .m_axis_msk_tready  (msk_tready),
        .m_axis_msk_tlast   (msk_tlast),
        .m_axis_msk_tuser   (msk_tuser),
        .mem_rd_addr        (ram_a_rd_addr),
        .mem_rd_data        (ram_a_rd_data),
        .mem_wr_addr        (ram_a_wr_addr),
        .mem_wr_data        (ram_a_wr_data),
        .mem_wr_en          (ram_a_wr_en)
    );

    // axis_bbox_reduce is always ready — its tready output drives msk_tready.
    axis_bbox_reduce #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_bbox_reduce (
        .clk            (clk_dsp),
        .rst_n          (rst_dsp_n),
        .s_axis_tdata   (msk_tdata),
        .s_axis_tvalid  (msk_tvalid),
        .s_axis_tready  (msk_tready),  // driven to 1'b1 internally
        .s_axis_tlast   (msk_tlast),
        .s_axis_tuser   (msk_tuser),
        .bbox_min_x     (bbox_min_x),
        .bbox_max_x     (bbox_max_x),
        .bbox_min_y     (bbox_min_y),
        .bbox_max_y     (bbox_max_y),
        .bbox_valid     (),             // strobe — unused at this level
        .bbox_empty     (bbox_empty)
    );

    axis_overlay_bbox #(
        .H_ACTIVE   (H_ACTIVE),
        .V_ACTIVE   (V_ACTIVE),
        .BBOX_COLOR (BBOX_COLOR)
    ) u_overlay_bbox (
        .clk            (clk_dsp),
        .rst_n          (rst_dsp_n),
        .s_axis_tdata   (vid_tdata),
        .s_axis_tvalid  (vid_tvalid),
        .s_axis_tready  (vid_tready),
        .s_axis_tlast   (vid_tlast),
        .s_axis_tuser   (vid_tuser),
        .m_axis_tdata   (ovl_tdata),
        .m_axis_tvalid  (ovl_tvalid),
        .m_axis_tready  (ovl_tready),
        .m_axis_tlast   (ovl_tlast),
        .m_axis_tuser   (ovl_tuser),
        .bbox_min_x     (bbox_min_x),
        .bbox_max_x     (bbox_max_x),
        .bbox_min_y     (bbox_min_y),
        .bbox_max_y     (bbox_max_y),
        .bbox_empty     (bbox_empty)
    );

    // -----------------------------------------------------------------
    // Output async FIFO: clk_dsp -> clk_pix
    // -----------------------------------------------------------------
    localparam int OUT_FIFO_DEPTH = 32;

    logic [23:0] pix_out_tdata;
    logic        pix_out_tvalid;
    logic        pix_out_tready;
    logic        pix_out_tuser;
    logic [$clog2(OUT_FIFO_DEPTH):0] fifo_out_depth;  // write-side (clk_dsp)

    axis_async_fifo #(
        .DEPTH       (OUT_FIFO_DEPTH),
        .DATA_WIDTH  (24),
        .KEEP_ENABLE (0),
        .LAST_ENABLE (1),
        .ID_ENABLE   (0),
        .DEST_ENABLE (0),
        .USER_ENABLE (1),
        .USER_WIDTH  (1),
        .FRAME_FIFO  (0)
    ) u_fifo_out (
        .s_clk            (clk_dsp),
        .s_rst            (rst_dsp),
        .s_axis_tdata     (ovl_tdata),
        .s_axis_tkeep     (3'b0),
        .s_axis_tvalid    (ovl_tvalid),
        .s_axis_tready    (ovl_tready),
        .s_axis_tlast     (ovl_tlast),
        .s_axis_tid       (8'b0),
        .s_axis_tdest     (8'b0),
        .s_axis_tuser     (ovl_tuser),

        .m_clk            (clk_pix),
        .m_rst            (rst_pix),
        .m_axis_tdata     (pix_out_tdata),
        .m_axis_tkeep     (),
        .m_axis_tvalid    (pix_out_tvalid),
        .m_axis_tready    (pix_out_tready),
        .m_axis_tlast     (),
        .m_axis_tid       (),
        .m_axis_tdest     (),
        .m_axis_tuser     (pix_out_tuser),

        .s_pause_req      (1'b0),
        .s_pause_ack      (),
        .m_pause_req      (1'b0),
        .m_pause_ack      (),

        .s_status_depth        (fifo_out_depth),
        .s_status_depth_commit (),
        .s_status_overflow     (fifo_out_overflow),
        .s_status_bad_frame    (),
        .s_status_good_frame   (),
        .m_status_depth        (),
        .m_status_depth_commit (),
        .m_status_overflow     (),
        .m_status_bad_frame    (),
        .m_status_good_frame   ()
    );

    // -----------------------------------------------------------------
    // axis-to-pixel shim + VGA-controller reset gating.
    //
    // Hold the VGA controller in reset until a start-of-frame pixel
    // arrives at the FIFO output (tuser=1). This ensures the VGA
    // begins on a frame boundary.
    // -----------------------------------------------------------------
    logic vga_rst_n;
    logic vga_started;
    logic vga_pixel_ready;

    always_ff @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            vga_started <= 1'b0;
        end else if (!vga_started && pix_out_tvalid && pix_out_tuser) begin
            vga_started <= 1'b1;
        end
    end

    assign vga_rst_n      = rst_pix_n & vga_started;
    assign pix_out_tready = vga_pixel_ready & vga_started;

    vga_controller #(
        .H_ACTIVE      (H_ACTIVE),
        .H_FRONT_PORCH (H_FRONT_PORCH),
        .H_SYNC_PULSE  (H_SYNC_PULSE),
        .H_BACK_PORCH  (H_BACK_PORCH),
        .V_ACTIVE      (V_ACTIVE),
        .V_FRONT_PORCH (V_FRONT_PORCH),
        .V_SYNC_PULSE  (V_SYNC_PULSE),
        .V_BACK_PORCH  (V_BACK_PORCH)
    ) u_vga (
        .clk         (clk_pix),
        .rst_n       (vga_rst_n),
        .pixel_data  (pix_out_tdata),
        .pixel_valid (pix_out_tvalid),
        .pixel_ready (vga_pixel_ready),
        .frame_start (),
        .line_start  (),
        .vga_hsync   (vga_hsync),
        .vga_vsync   (vga_vsync),
        .vga_r       (vga_r),
        .vga_g       (vga_g),
        .vga_b       (vga_b)
    );

    // -----------------------------------------------------------------
    // SVA checkers (Verilator only)
    //
    // 1) The DSP-side pipeline must never back-pressure the input
    //    stream: whenever the producer asserts s_axis_tvalid, the input
    //    FIFO must already be ready to accept the beat.
    // 2) Once the VGA controller has started consuming pixels (i.e.
    //    vga_started == 1), the output FIFO must present a valid pixel
    //    every cycle the controller is in its active region. An
    //    underrun anywhere in the active window causes screen tearing.
    //    The assertion is auto-disabled near end-of-simulation via
    //    `sva_drain_mode`, which the testbench raises once it has
    //    finished pushing the last frame.
    // -----------------------------------------------------------------
`ifdef VERILATOR
    // Test-side hook: the TB drives `tb_sva_drain` high once it has
    // stopped feeding new pixels, so the inevitable end-of-sim underrun
    // is not flagged. Default-tied to 0 if no driver hooks in.
    logic sva_drain_mode;
    initial sva_drain_mode = 1'b0;

    // (1) Input must not be back-pressured.
    assert_no_input_backpressure: assert property (
        @(posedge clk_pix) disable iff (!rst_pix_n)
            s_axis_tvalid |-> s_axis_tready
    ) else $error("sparevideo_top: input s_axis was back-pressured (DSP pipeline stalled)");

    // (2) Once started, no underruns inside the VGA active region.
    assert_no_output_underrun: assert property (
        @(posedge clk_pix) disable iff (!rst_pix_n || sva_drain_mode)
            (vga_started && vga_pixel_ready) |-> pix_out_tvalid
    ) else $error("sparevideo_top: output FIFO underrun during active region (screen tearing)");

    // (3) Input FIFO depth must never reach full capacity.
    // s_status_depth is in the write-clock (clk_pix) domain and counts
    // entries currently in the FIFO.  Reaching IN_FIFO_DEPTH means the next
    // push would overflow.  Catching it one step early gives a clearer signal.
    assert_fifo_in_not_full: assert property (
        @(posedge clk_pix) disable iff (!rst_pix_n)
            fifo_in_depth < ($bits(fifo_in_depth))'(IN_FIFO_DEPTH)
    ) else $error("sparevideo_top: input FIFO full (depth=%0d/%0d) — overflow imminent",
                  fifo_in_depth, IN_FIFO_DEPTH);

    // (4) Output FIFO depth must never reach full capacity (clk_dsp domain).
    assert_fifo_out_not_full: assert property (
        @(posedge clk_dsp) disable iff (!rst_dsp_n)
            fifo_out_depth < ($bits(fifo_out_depth))'(OUT_FIFO_DEPTH)
    ) else $error("sparevideo_top: output FIFO full (depth=%0d/%0d) — overflow imminent",
                  fifo_out_depth, OUT_FIFO_DEPTH);

    // (5) Input FIFO must never overflow (sticky flag in clk_pix domain).
    assert_fifo_in_no_overflow: assert property (
        @(posedge clk_pix) disable iff (!rst_pix_n)
            !fifo_in_overflow
    ) else $error("sparevideo_top: input FIFO overflow — pixels lost at CDC crossing");

    // (6) Output FIFO must never overflow (sticky flag in clk_dsp domain).
    assert_fifo_out_no_overflow: assert property (
        @(posedge clk_dsp) disable iff (!rst_dsp_n)
            !fifo_out_overflow
    ) else $error("sparevideo_top: output FIFO overflow — DSP output rate exceeds VGA drain rate");
`endif

endmodule
