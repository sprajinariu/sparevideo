// sparevideo_top — AXI4-Stream video pipeline top level.
//
//   s_axis (clk_pix) -> async_fifo -> motion detect pipeline (clk_dsp)
//                                  -> async_fifo -> vga_controller (clk_pix)
//                                                -> RGB + hsync/vsync
//
// Motion detect pipeline (clk_dsp domain):
//   axis_fork -> axis_motion_detect (mask-only) -> axis_ccl -> bbox sideband (N_OUT-wide)
//   axis_fork -> axis_overlay_bbox <- bbox sideband -> output async FIFO
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
    // Pixels with abs(Y_cur - Y_prev) > MOTION_THRESH are flagged as motion
    // (polarity-agnostic — both arrival and departure pixels are flagged).
    parameter int MOTION_THRESH = 16,
    // EMA background adaptation rate: alpha = 1 / (1 << ALPHA_SHIFT).
    // Default 3 → alpha = 1/8. Higher = slower adaptation.
    parameter int ALPHA_SHIFT   = 3,
    // EMA background adaptation rate on MOTION pixels: alpha = 1 / (1 << ALPHA_SHIFT_SLOW).
    // Default 6 → alpha = 1/64. Larger than ALPHA_SHIFT so moving objects barely drift bg.
    parameter int ALPHA_SHIFT_SLOW = 6,
    // Gaussian pre-filter: 1 = enabled (3x3 Gaussian on Y before motion compare),
    // 0 = bypass (raw Y). Default enabled.
    parameter int GAUSS_EN      = 1
) (
    // ---- Clocks & resets -------------------------------------------
    input  logic        clk_pix_i,      // 25 MHz pixel clock (input + VGA output domain)
    input  logic        clk_dsp_i,      // 100 MHz processing clock (CDC FIFOs cross to here)
    input  logic        rst_pix_n_i,    // active-low synchronous reset, clk_pix domain
    input  logic        rst_dsp_n_i,    // active-low synchronous reset, clk_dsp domain

    // ---- AXI4-Stream video input (clk_pix domain) ------------------
    input  logic [23:0] s_axis_tdata_i,   // pixel payload, packed {R[7:0], G[7:0], B[7:0]}
    input  logic        s_axis_tvalid_i,  // producer asserts when tdata is valid
    output logic        s_axis_tready_o,  // sink ready; back-pressures producer when low
    input  logic        s_axis_tlast_i,   // end-of-line marker (asserted on last pixel of each row)
    input  logic        s_axis_tuser_i,   // start-of-frame marker (asserted on first pixel of frame)

    // ---- Control flow (quasi-static sideband, directly usable in clk_dsp) ---
    input  logic [1:0]  ctrl_flow_i,      // 2'b00 = passthrough, 2'b01 = motion, 2'b10 = mask

    // ---- VGA output (clk_pix domain) -------------------------------
    output logic        vga_hsync_o,    // horizontal sync, active-low
    output logic        vga_vsync_o,    // vertical sync, active-low
    output logic [7:0]  vga_r_o,        // red channel (valid during active region, else 0)
    output logic [7:0]  vga_g_o,        // green channel
    output logic [7:0]  vga_b_o         // blue channel
);

    // verilog-axis modules use active-high resets internally.
    logic rst_pix;
    logic rst_dsp;
    assign rst_pix = ~rst_pix_n_i;
    assign rst_dsp = ~rst_dsp_n_i;

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
        .s_clk            (clk_pix_i),
        .s_rst            (rst_pix),
        .s_axis_tdata     (s_axis_tdata_i),
        .s_axis_tkeep     (3'b0),
        .s_axis_tvalid    (s_axis_tvalid_i),
        .s_axis_tready    (s_axis_tready_o),
        .s_axis_tlast     (s_axis_tlast_i),
        .s_axis_tid       (8'b0),
        .s_axis_tdest     (8'b0),
        .s_axis_tuser     (s_axis_tuser_i),

        .m_clk            (clk_dsp_i),
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
        .clk_i       (clk_dsp_i),
        .a_rd_addr_i (ram_a_rd_addr),
        .a_rd_data_o (ram_a_rd_data),
        .a_wr_addr_i (ram_a_wr_addr),
        .a_wr_data_i (ram_a_wr_data),
        .a_wr_en_i   (ram_a_wr_en),
        // Port B: tied off — future host client lands here.
        .b_rd_addr_i ('0),
        .b_rd_data_o (),
        .b_wr_addr_i ('0),
        .b_wr_data_i ('0),
        .b_wr_en_i   (1'b0)
    );

    // -----------------------------------------------------------------
    // Motion detect pipeline on clk_dsp
    //   axis_fork:          broadcast dsp_in to motion detect (A) and overlay (B)
    //   axis_motion_detect: RGB in → mask stream (mask-only, no vid passthrough)
    //   axis_ccl:           mask → N_OUT per-component bboxes (packed arrays)
    //   axis_overlay_bbox:  fork-B RGB (or grey canvas in CCL_BBOX mode) +
    //                       bbox sideband → overlaid RGB out
    // -----------------------------------------------------------------

    // Top-level fork: broadcasts the gated dsp_in to both motion detect and overlay
    logic        fork_s_tvalid;
    logic        fork_s_tready;
    logic [23:0] fork_a_tdata;
    logic        fork_a_tvalid;
    logic        fork_a_tready;
    logic        fork_a_tlast;
    logic        fork_a_tuser;
    logic [23:0] fork_b_tdata;
    logic        fork_b_tvalid;
    logic        fork_b_tready;
    logic        fork_b_tlast;
    logic        fork_b_tuser;

    // Motion mask stream (1-bit per pixel)
    logic        msk_tdata;
    logic        msk_tvalid;
    logic        msk_tready;
    logic        msk_tlast;
    logic        msk_tuser;

    // Mask display: expand 1-bit mask to 24-bit RGB for VGA output
    logic [23:0] msk_rgb_tdata;
    logic        msk_rgb_tvalid;
    logic        msk_rgb_tlast;
    logic        msk_rgb_tuser;

    assign msk_rgb_tdata  = msk_tdata ? 24'hFF_FF_FF : 24'h00_00_00;
    assign msk_rgb_tvalid = msk_tvalid;
    assign msk_rgb_tlast  = msk_tlast;
    assign msk_rgb_tuser  = msk_tuser;

    // Bbox sideband: N_OUT-wide arrays latched by axis_ccl and held for next frame.
    localparam int N_OUT_TOP = sparevideo_pkg::CCL_N_OUT;
    logic [N_OUT_TOP-1:0]                       ccl_bbox_valid;
    logic [N_OUT_TOP-1:0][$clog2(H_ACTIVE)-1:0] ccl_bbox_min_x, ccl_bbox_max_x;
    logic [N_OUT_TOP-1:0][$clog2(V_ACTIVE)-1:0] ccl_bbox_min_y, ccl_bbox_max_y;

    // Overlay output (to output async FIFO via control-flow mux)
    logic [23:0] ovl_tdata;
    logic        ovl_tvalid;
    logic        ovl_tready;
    logic        ovl_tlast;
    logic        ovl_tuser;

    // Processing output mux (feeds u_fifo_out)
    logic [23:0] proc_tdata;
    logic        proc_tvalid;
    logic        proc_tready;   // driven by u_fifo_out write-side tready
    logic        proc_tlast;
    logic        proc_tuser;

    // Gate fork input: passthrough mode sends no data into the motion pipeline.
    // Both motion and mask modes require the motion detect pipeline to run.
    logic motion_pipe_active;
    assign motion_pipe_active = (ctrl_flow_i == sparevideo_pkg::CTRL_MOTION_DETECT)
                             || (ctrl_flow_i == sparevideo_pkg::CTRL_MASK_DISPLAY)
                             || (ctrl_flow_i == sparevideo_pkg::CTRL_CCL_BBOX);
    assign fork_s_tvalid = motion_pipe_active ? dsp_in_tvalid : 1'b0;

    axis_fork #(
        .DATA_WIDTH (24)
    ) u_fork (
        .clk_i             (clk_dsp_i),
        .rst_n_i           (rst_dsp_n_i),
        // Input: gated dsp_in
        .s_axis_tdata_i    (dsp_in_tdata),
        .s_axis_tvalid_i   (fork_s_tvalid),
        .s_axis_tready_o   (fork_s_tready),
        .s_axis_tlast_i    (dsp_in_tlast),
        .s_axis_tuser_i    (dsp_in_tuser),
        // Output A: to axis_motion_detect (mask-only)
        .m_a_axis_tdata_o  (fork_a_tdata),
        .m_a_axis_tvalid_o (fork_a_tvalid),
        .m_a_axis_tready_i (fork_a_tready),
        .m_a_axis_tlast_o  (fork_a_tlast),
        .m_a_axis_tuser_o  (fork_a_tuser),
        // Output B: to axis_overlay_bbox
        .m_b_axis_tdata_o  (fork_b_tdata),
        .m_b_axis_tvalid_o (fork_b_tvalid),
        .m_b_axis_tready_i (fork_b_tready),
        .m_b_axis_tlast_o  (fork_b_tlast),
        .m_b_axis_tuser_o  (fork_b_tuser)
    );

    axis_motion_detect #(
        .H_ACTIVE         (H_ACTIVE),
        .V_ACTIVE         (V_ACTIVE),
        .THRESH           (MOTION_THRESH),
        .ALPHA_SHIFT      (ALPHA_SHIFT),
        .ALPHA_SHIFT_SLOW (ALPHA_SHIFT_SLOW),
        .GAUSS_EN         (GAUSS_EN),
        .RGN_BASE    (RGN_Y_PREV_BASE),
        .RGN_SIZE    (RGN_Y_PREV_SIZE)
    ) u_motion_detect (
        .clk_i               (clk_dsp_i),
        .rst_n_i             (rst_dsp_n_i),
        // AXI4-Stream input (from fork output A)
        .s_axis_tdata_i      (fork_a_tdata),
        .s_axis_tvalid_i     (fork_a_tvalid),
        .s_axis_tready_o     (fork_a_tready),
        .s_axis_tlast_i      (fork_a_tlast),
        .s_axis_tuser_i      (fork_a_tuser),
        // AXI4-Stream output — mask (1 bit)
        .m_axis_msk_tdata_o  (msk_tdata),
        .m_axis_msk_tvalid_o (msk_tvalid),
        .m_axis_msk_tready_i (msk_tready),
        .m_axis_msk_tlast_o  (msk_tlast),
        .m_axis_msk_tuser_o  (msk_tuser),
        // Memory port (to shared RAM port A)
        .mem_rd_addr_o       (ram_a_rd_addr),
        .mem_rd_data_i       (ram_a_rd_data),
        .mem_wr_addr_o       (ram_a_wr_addr),
        .mem_wr_data_o       (ram_a_wr_data),
        .mem_wr_en_o         (ram_a_wr_en)
    );

    // Mask tready backpressure: in mask display and CCL_BBOX modes, the mask
    // stream is also consumed by the passthrough-to-output path (mask display)
    // or used as the grey canvas source (ccl_bbox). In motion mode, axis_ccl
    // is the sole consumer and drives bbox_msk_tready.
    logic bbox_msk_tready;
    assign msk_tready = ((ctrl_flow_i == sparevideo_pkg::CTRL_MASK_DISPLAY)
                      || (ctrl_flow_i == sparevideo_pkg::CTRL_CCL_BBOX))
                      ? (proc_tready && bbox_msk_tready)
                      : bbox_msk_tready;

    // axis_ccl asserts bbox_msk_tready during streaming and deasserts it only
    // while its EOF resolution FSM is active (vblank). In multi-consumer
    // modes the upstream may also hold beats across cycles when proc_tready=0.
    // Feed axis_ccl the global-handshake strobe (tvalid && tready) as its
    // tvalid so it advances exactly once per accepted beat, regardless of
    // which consumer gated the stall.
    logic ccl_beat_strobe;
    assign ccl_beat_strobe = msk_tvalid && msk_tready;

    axis_ccl #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE),
        .N_OUT    (N_OUT_TOP)
    ) u_ccl (
        .clk_i           (clk_dsp_i),
        .rst_n_i         (rst_dsp_n_i),
        // AXI4-Stream input — mask (1 bit per pixel)
        .s_axis_tdata_i  (msk_tdata),
        .s_axis_tvalid_i (ccl_beat_strobe),
        .s_axis_tready_o (bbox_msk_tready),
        .s_axis_tlast_i  (msk_tlast),
        .s_axis_tuser_i  (msk_tuser),
        // Sideband output — packed arrays, one slot per output bbox.
        .bbox_valid_o    (ccl_bbox_valid),
        .bbox_min_x_o    (ccl_bbox_min_x),
        .bbox_max_x_o    (ccl_bbox_max_x),
        .bbox_min_y_o    (ccl_bbox_min_y),
        .bbox_max_y_o    (ccl_bbox_max_y),
        .bbox_swap_o     (),                // unused
        .bbox_empty_o    ()                 // unused: overlay uses per-slot valids
    );

    // Overlay video input mux: in CTRL_CCL_BBOX mode, the overlay draws bboxes
    // onto a grey canvas derived combinationally from the mask stream; in
    // other modes, the overlay consumes the fork-B RGB stream.
    logic [23:0] ovl_in_tdata;
    logic        ovl_in_tvalid;
    logic        ovl_in_tready;
    logic        ovl_in_tlast;
    logic        ovl_in_tuser;

    logic [23:0] mask_grey_rgb;
    assign mask_grey_rgb = msk_tdata ? 24'h80_80_80 : 24'h20_20_20;

    always_comb begin
        if (ctrl_flow_i == sparevideo_pkg::CTRL_CCL_BBOX) begin
            ovl_in_tdata  = mask_grey_rgb;
            ovl_in_tvalid = msk_tvalid;
            ovl_in_tlast  = msk_tlast;
            ovl_in_tuser  = msk_tuser;
        end else begin
            ovl_in_tdata  = fork_b_tdata;
            ovl_in_tvalid = fork_b_tvalid;
            ovl_in_tlast  = fork_b_tlast;
            ovl_in_tuser  = fork_b_tuser;
        end
    end

    // Fork-B backpressure: in CCL_BBOX mode the fork-B path is unused (drained);
    // in other modes it feeds the overlay video input.
    assign fork_b_tready = (ctrl_flow_i == sparevideo_pkg::CTRL_CCL_BBOX) ? 1'b1
                                                                         : ovl_in_tready;

    axis_overlay_bbox #(
        .H_ACTIVE   (H_ACTIVE),
        .V_ACTIVE   (V_ACTIVE),
        .N_OUT      (N_OUT_TOP),
        .BBOX_COLOR (BBOX_COLOR)
    ) u_overlay_bbox (
        .clk_i           (clk_dsp_i),
        .rst_n_i         (rst_dsp_n_i),
        // AXI4-Stream input — from mux (fork-B RGB, or grey canvas in CCL_BBOX mode)
        .s_axis_tdata_i  (ovl_in_tdata),
        .s_axis_tvalid_i (ovl_in_tvalid),
        .s_axis_tready_o (ovl_in_tready),
        .s_axis_tlast_i  (ovl_in_tlast),
        .s_axis_tuser_i  (ovl_in_tuser),
        // AXI4-Stream output — video with bbox rectangles overlaid (RGB888)
        .m_axis_tdata_o  (ovl_tdata),
        .m_axis_tvalid_o (ovl_tvalid),
        .m_axis_tready_i (ovl_tready),
        .m_axis_tlast_o  (ovl_tlast),
        .m_axis_tuser_o  (ovl_tuser),
        // Sideband input — packed-array bboxes from axis_ccl
        .bbox_valid_i    (ccl_bbox_valid),
        .bbox_min_x_i    (ccl_bbox_min_x),
        .bbox_max_x_i    (ccl_bbox_max_x),
        .bbox_min_y_i    (ccl_bbox_min_y),
        .bbox_max_y_i    (ccl_bbox_max_y)
    );

    // -----------------------------------------------------------------
    // Control-flow output mux
    //   Passthrough: dsp_in (raw input) → output FIFO; fork inactive (tvalid=0).
    //   Motion:      ovl (overlay output) → output FIFO; fork drives both paths.
    //   Mask:        msk_rgb (B/W mask) → output FIFO; overlay path drained.
    //   CCL bbox:    ovl (overlay on grey canvas) → output FIFO; fork-B drained.
    // -----------------------------------------------------------------
    always_comb begin
        case (ctrl_flow_i)
            sparevideo_pkg::CTRL_PASSTHROUGH: begin
                proc_tdata    = dsp_in_tdata;
                proc_tvalid   = dsp_in_tvalid;
                proc_tlast    = dsp_in_tlast;
                proc_tuser    = dsp_in_tuser;
                dsp_in_tready = proc_tready;
                ovl_tready    = 1'b1;       // fork inactive, no overlay data
            end
            sparevideo_pkg::CTRL_MASK_DISPLAY: begin
                proc_tdata    = msk_rgb_tdata;
                proc_tvalid   = msk_rgb_tvalid;
                proc_tlast    = msk_rgb_tlast;
                proc_tuser    = msk_rgb_tuser;
                dsp_in_tready = fork_s_tready;
                ovl_tready    = 1'b1;       // overlay path unused, drain
            end
            sparevideo_pkg::CTRL_CCL_BBOX: begin
                // Grey canvas + bboxes from the overlay; fork-B is drained.
                proc_tdata    = ovl_tdata;
                proc_tvalid   = ovl_tvalid;
                proc_tlast    = ovl_tlast;
                proc_tuser    = ovl_tuser;
                dsp_in_tready = fork_s_tready;
                ovl_tready    = proc_tready;
            end
            default: begin // CTRL_MOTION_DETECT
                proc_tdata    = ovl_tdata;
                proc_tvalid   = ovl_tvalid;
                proc_tlast    = ovl_tlast;
                proc_tuser    = ovl_tuser;
                dsp_in_tready = fork_s_tready;
                ovl_tready    = proc_tready;
            end
        endcase
    end

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
        .s_clk            (clk_dsp_i),
        .s_rst            (rst_dsp),
        .s_axis_tdata     (proc_tdata),
        .s_axis_tkeep     (3'b0),
        .s_axis_tvalid    (proc_tvalid),
        .s_axis_tready    (proc_tready),
        .s_axis_tlast     (proc_tlast),
        .s_axis_tid       (8'b0),
        .s_axis_tdest     (8'b0),
        .s_axis_tuser     (proc_tuser),

        .m_clk            (clk_pix_i),
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

    always_ff @(posedge clk_pix_i) begin
        if (!rst_pix_n_i) begin
            vga_started <= 1'b0;
        end else if (!vga_started && pix_out_tvalid && pix_out_tuser) begin
            vga_started <= 1'b1;
        end
    end

    assign vga_rst_n      = rst_pix_n_i & vga_started;
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
        .clk_i         (clk_pix_i),   // pixel clock
        .rst_n_i       (vga_rst_n),   // active-low synchronous reset; held until first SOF
        // Streaming pixel input (from output async FIFO, clk_pix domain)
        .pixel_data_i  (pix_out_tdata),   // {R[7:0], G[7:0], B[7:0]}
        .pixel_valid_i (pix_out_tvalid),  // upstream has pixel data
        .pixel_ready_o (vga_pixel_ready), // controller accepting pixels (active area only)
        // Synchronization outputs to upstream
        .frame_start_o (),   // pulse at first active pixel of frame — unused here
        .line_start_o  (),   // pulse at first active pixel of each line — unused here
        // VGA output
        .vga_hsync_o   (vga_hsync_o),  // horizontal sync (active-low)
        .vga_vsync_o   (vga_vsync_o),  // vertical sync (active-low)
        .vga_r_o       (vga_r_o),      // red channel (0 during blanking)
        .vga_g_o       (vga_g_o),      // green channel (0 during blanking)
        .vga_b_o       (vga_b_o)       // blue channel (0 during blanking)
    );

    // -----------------------------------------------------------------
    // SVA checkers (Verilator only)
    // -----------------------------------------------------------------
`ifdef VERILATOR
    // Test-side hook: the TB drives `tb_sva_drain` high once it has
    // stopped feeding new pixels, so the inevitable end-of-sim underrun
    // is not flagged. Default-tied to 0 if no driver hooks in.
    logic sva_drain_mode;
    initial sva_drain_mode = 1'b0;

    // (1) Input must not be back-pressured.
    assert_no_input_backpressure: assert property (
        @(posedge clk_pix_i) disable iff (!rst_pix_n_i)
            s_axis_tvalid_i |-> s_axis_tready_o
    ) else $error("sparevideo_top: input s_axis was back-pressured (DSP pipeline stalled)");

    // (2) Once started, no underruns inside the VGA active region.
    assert_no_output_underrun: assert property (
        @(posedge clk_pix_i) disable iff (!rst_pix_n_i || sva_drain_mode)
            (vga_started && vga_pixel_ready) |-> pix_out_tvalid
    ) else $error("sparevideo_top: output FIFO underrun during active region (screen tearing)");

    // (3) Input FIFO depth must never reach full capacity.
    assert_fifo_in_not_full: assert property (
        @(posedge clk_pix_i) disable iff (!rst_pix_n_i)
            fifo_in_depth < ($bits(fifo_in_depth))'(IN_FIFO_DEPTH)
    ) else $error("sparevideo_top: input FIFO full (depth=%0d/%0d) — overflow imminent",
                  fifo_in_depth, IN_FIFO_DEPTH);

    // (4) Output FIFO depth must never reach full capacity (clk_dsp domain).
    assert_fifo_out_not_full: assert property (
        @(posedge clk_dsp_i) disable iff (!rst_dsp_n_i)
            fifo_out_depth < ($bits(fifo_out_depth))'(OUT_FIFO_DEPTH)
    ) else $error("sparevideo_top: output FIFO full (depth=%0d/%0d) — overflow imminent",
                  fifo_out_depth, OUT_FIFO_DEPTH);

    // (5) Input FIFO must never overflow (sticky flag in clk_pix domain).
    assert_fifo_in_no_overflow: assert property (
        @(posedge clk_pix_i) disable iff (!rst_pix_n_i)
            !fifo_in_overflow
    ) else $error("sparevideo_top: input FIFO overflow — pixels lost at CDC crossing");

    // (6) Output FIFO must never overflow (sticky flag in clk_dsp domain).
    assert_fifo_out_no_overflow: assert property (
        @(posedge clk_dsp_i) disable iff (!rst_dsp_n_i)
            !fifo_out_overflow
    ) else $error("sparevideo_top: output FIFO overflow — DSP output rate exceeds VGA drain rate");
`endif

endmodule
