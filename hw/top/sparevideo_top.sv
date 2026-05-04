// sparevideo_top — AXI4-Stream video pipeline top level.
//
//   s_axis (axis_if.rx, clk_pix) -> async_fifo -> motion detect pipeline (clk_dsp)
//                                               -> async_fifo -> vga_controller (clk_pix)
//                                                             -> RGB + hsync/vsync
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

module sparevideo_top
#(
    parameter int   H_ACTIVE      = sparevideo_pkg::H_ACTIVE,
    parameter int   H_FRONT_PORCH = sparevideo_pkg::H_FRONT_PORCH,
    parameter int   H_SYNC_PULSE  = sparevideo_pkg::H_SYNC_PULSE,
    parameter int   H_BACK_PORCH  = sparevideo_pkg::H_BACK_PORCH,
    parameter int   V_ACTIVE      = sparevideo_pkg::V_ACTIVE,
    parameter int   V_FRONT_PORCH = sparevideo_pkg::V_FRONT_PORCH,
    parameter int   V_SYNC_PULSE  = sparevideo_pkg::V_SYNC_PULSE,
    parameter int   V_BACK_PORCH  = sparevideo_pkg::V_BACK_PORCH,
    // Single algorithm config bundle. See sparevideo_pkg::cfg_t for fields,
    // and sparevideo_pkg::CFG_* for canonical profiles. The 2x upscaler's
    // structural presence lives here as CFG.scaler_en — no separate
    // top-level parameter.
    parameter sparevideo_pkg::cfg_t CFG = sparevideo_pkg::CFG_DEFAULT
) (
    // ---- Clocks & resets -------------------------------------------
    input  logic        clk_pix_in_i,    // input-rate pixel clock (sensor / source)
    input  logic        clk_pix_out_i,   // output-rate pixel clock (VGA / display)
    input  logic        clk_dsp_i,       // 100 MHz processing clock (CDC FIFOs cross to here)
    input  logic        rst_pix_in_n_i,  // active-low sync reset, clk_pix_in domain
    input  logic        rst_pix_out_n_i, // active-low sync reset, clk_pix_out domain
    input  logic        rst_dsp_n_i,     // active-low sync reset, clk_dsp domain

    // ---- AXI4-Stream video input (clk_pix domain) ------------------
    axis_if.rx          s_axis,           // {tdata[23:0], tvalid, tready, tlast, tuser[0]}

    // ---- Control flow (quasi-static sideband, directly usable in clk_dsp) ---
    input  logic [1:0]  ctrl_flow_i,      // 2'b00 = passthrough, 2'b01 = motion, 2'b10 = mask

    // ---- VGA output (clk_pix domain) -------------------------------
    output logic        vga_hsync_o,    // horizontal sync, active-low
    output logic        vga_vsync_o,    // vertical sync, active-low
    output logic [7:0]  vga_r_o,        // red channel (valid during active region, else 0)
    output logic [7:0]  vga_g_o,        // green channel
    output logic [7:0]  vga_b_o         // blue channel
);

    // Resolve output VGA dims from CFG.scaler_en. Used only for the VGA
    // controller and FIFO sizing; the upstream path is unaffected.
    localparam int H_ACTIVE_OUT      = CFG.scaler_en ? sparevideo_pkg::H_ACTIVE_OUT_2X      : H_ACTIVE;
    localparam int V_ACTIVE_OUT      = CFG.scaler_en ? sparevideo_pkg::V_ACTIVE_OUT_2X      : V_ACTIVE;
    localparam int H_FRONT_PORCH_OUT = CFG.scaler_en ? sparevideo_pkg::H_FRONT_PORCH_OUT_2X : H_FRONT_PORCH;
    localparam int H_SYNC_PULSE_OUT  = CFG.scaler_en ? sparevideo_pkg::H_SYNC_PULSE_OUT_2X  : H_SYNC_PULSE;
    localparam int H_BACK_PORCH_OUT  = CFG.scaler_en ? sparevideo_pkg::H_BACK_PORCH_OUT_2X  : H_BACK_PORCH;
    localparam int V_FRONT_PORCH_OUT = CFG.scaler_en ? sparevideo_pkg::V_FRONT_PORCH_OUT_2X : V_FRONT_PORCH;
    localparam int V_SYNC_PULSE_OUT  = CFG.scaler_en ? sparevideo_pkg::V_SYNC_PULSE_OUT_2X  : V_SYNC_PULSE;
    localparam int V_BACK_PORCH_OUT  = CFG.scaler_en ? sparevideo_pkg::V_BACK_PORCH_OUT_2X  : V_BACK_PORCH;

    // FIFO overflow flags (write-clock domain; sticky until reset).
    // Checked by SVAs below.
    logic fifo_in_overflow;   // clk_pix domain (input FIFO write side)
    logic fifo_out_overflow;  // clk_dsp domain (output FIFO write side)

    // -----------------------------------------------------------------
    // Input async FIFO: clk_pix -> clk_dsp
    // -----------------------------------------------------------------
    // Sized to absorb the axis_hflip RX/TX alternation. While hflip is
    // in TX (320 dsp cycles = ~80 pix_clk cycles), the upstream cannot be
    // accepted; the input CDC FIFO must hold the worst-case ~80 entries.
    // 128 gives ~50% headroom.
    localparam int IN_FIFO_DEPTH = 128;

    logic [$clog2(IN_FIFO_DEPTH):0] fifo_in_depth;   // write-side (clk_pix)

    axis_async_fifo_ifc #(
        .DEPTH  (IN_FIFO_DEPTH),
        .DATA_W (24),
        .USER_W (1)
    ) u_fifo_in (
        .s_clk            (clk_pix_in_i),
        .s_rst_n          (rst_pix_in_n_i),
        .m_clk            (clk_dsp_i),
        .m_rst_n          (rst_dsp_n_i),
        .s_axis           (s_axis),
        .m_axis           (pix_in_to_hflip),
        .s_status_depth   (fifo_in_depth),
        .s_status_overflow(fifo_in_overflow),
        .m_status_depth   ()
    );

    // -----------------------------------------------------------------
    // Motion threshold is CFG.motion_thresh (see sparevideo_pkg::cfg_t).
    // Region descriptor table (future CSR content):
    //   each region = {BASE (byte offset in `ram`), SIZE (bytes)}.
    //   Owners must only touch [BASE, BASE+SIZE). Sum(SIZE) <= RAM_DEPTH.
    // -----------------------------------------------------------------
    localparam int RGN_Y_PREV_BASE = 0;
    localparam int RGN_Y_PREV_SIZE = H_ACTIVE * V_ACTIVE;
    localparam int RAM_DEPTH       = RGN_Y_PREV_SIZE;
    localparam int RAM_ADDR_W      = $clog2(RAM_DEPTH);
    localparam int N_OUT_TOP       = sparevideo_pkg::CCL_N_OUT;


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
    // axis_hflip: horizontal mirror at the head of the proc_clk pipeline.
    //   - Sits before the ctrl_flow mux so motion masks and bbox coords
    //     agree with the user-visible frame.
    //   - enable_i tied to CFG.hflip_en at compile time (CSR-ready).
    // -----------------------------------------------------------------

    // pix_in_to_hflip: input async FIFO m_axis -> u_hflip.s_axis.
    // Connected directly to u_fifo_in.m_axis (interface bundle).
    axis_if #(.DATA_W(24), .USER_W(1)) pix_in_to_hflip ();

    // hflip_to_fork: u_hflip.m_axis -> u_fork.s_axis.
    // u_fork.s_axis.tvalid is gated by fork_s_tvalid (motion_pipe_active guard),
    // so two bridging assigns remain instead of a fully-transparent pass-through
    // (Option A per Task 9 spec).
    axis_if #(.DATA_W(24), .USER_W(1)) hflip_to_fork ();

    axis_hflip #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_hflip (
        .clk_i    (clk_dsp_i),
        .rst_n_i  (rst_dsp_n_i),
        .enable_i (CFG.hflip_en),
        .s_axis   (pix_in_to_hflip),
        .m_axis   (hflip_to_fork)
    );

    // -----------------------------------------------------------------
    // Motion detect pipeline on clk_dsp
    //   axis_fork:          broadcast dsp_in to motion detect (A) and overlay (B)
    //   axis_motion_detect: RGB in → mask stream (mask-only, no vid passthrough)
    //   axis_ccl:           mask → N_OUT per-component bboxes (packed arrays)
    //   axis_overlay_bbox:  fork-B RGB (or grey canvas in CCL_BBOX mode) +
    //                       bbox sideband → overlaid RGB out
    // -----------------------------------------------------------------

    // Top-level fork: broadcasts the gated hflip output to both motion detect (A)
    // and overlay (B). tvalid is gated by motion_pipe_active (passthrough mode
    // sends no data into the motion pipeline). Because u_fork.s_axis.tvalid
    // needs this gate, hflip_to_fork is a shared interface bundle but its
    // tvalid/tready bridging assigns inject the gating (Option A, Task 9 spec).
    logic        fork_s_tvalid;
    logic        fork_s_tready;

    // Gate fork input: passthrough mode sends no data into the motion pipeline.
    // Both motion and mask modes require the motion detect pipeline to run.
    logic motion_pipe_active;
    assign motion_pipe_active = (ctrl_flow_i == sparevideo_pkg::CTRL_MOTION_DETECT)
                             || (ctrl_flow_i == sparevideo_pkg::CTRL_MASK_DISPLAY)
                             || (ctrl_flow_i == sparevideo_pkg::CTRL_CCL_BBOX);
    assign fork_s_tvalid = motion_pipe_active ? hflip_to_fork.tvalid : 1'b0;

    // fork_s_axis: hflip_to_fork -> u_fork.s_axis with gated tvalid.
    // Cannot bind hflip_to_fork directly to u_fork.s_axis because tvalid needs
    // the motion_pipe_active gate; tdata/tlast/tuser pass through unmodified.
    axis_if #(.DATA_W(24), .USER_W(1)) fork_s_axis ();
    assign fork_s_axis.tdata  = hflip_to_fork.tdata;
    assign fork_s_axis.tvalid = fork_s_tvalid;
    assign fork_s_axis.tlast  = hflip_to_fork.tlast;
    assign fork_s_axis.tuser  = hflip_to_fork.tuser;
    assign fork_s_tready      = fork_s_axis.tready;

    // fork_a_to_motion: u_fork.m_a_axis -> u_motion_detect.s_axis (direct pass-through).
    axis_if #(.DATA_W(24), .USER_W(1)) fork_a_to_motion ();

    // fork_b_to_overlay: u_fork.m_b_axis -> u_overlay_bbox.s_axis
    // (via mux for ccl_bbox mode — see overlay input mux below).
    axis_if #(.DATA_W(24), .USER_W(1)) fork_b_to_overlay ();

    axis_fork #(
        .DATA_WIDTH (24),
        .USER_WIDTH (1)
    ) u_fork (
        .clk_i    (clk_dsp_i),
        .rst_n_i  (rst_dsp_n_i),
        .s_axis   (fork_s_axis),
        .m_a_axis (fork_a_to_motion),
        .m_b_axis (fork_b_to_overlay)
    );

    // motion_to_morph: u_motion_detect.m_axis_msk -> u_morph_open.s_axis (direct pass-through).
    axis_if #(.DATA_W(1), .USER_W(1)) motion_to_morph ();

    axis_motion_detect #(
        .H_ACTIVE          (H_ACTIVE),
        .V_ACTIVE          (V_ACTIVE),
        .THRESH            (int'(CFG.motion_thresh)),
        .ALPHA_SHIFT       (CFG.alpha_shift),
        .ALPHA_SHIFT_SLOW  (CFG.alpha_shift_slow),
        .GRACE_FRAMES      (CFG.grace_frames),
        .GRACE_ALPHA_SHIFT (CFG.grace_alpha_shift),
        .GAUSS_EN          (int'(CFG.gauss_en)),
        .RGN_BASE          (RGN_Y_PREV_BASE),
        .RGN_SIZE          (RGN_Y_PREV_SIZE)
    ) u_motion_detect (
        .clk_i         (clk_dsp_i),
        .rst_n_i       (rst_dsp_n_i),
        .s_axis        (fork_a_to_motion),
        .m_axis_msk    (motion_to_morph),
        // Memory port (to shared RAM port A)
        .mem_rd_addr_o (ram_a_rd_addr),
        .mem_rd_data_i (ram_a_rd_data),
        .mem_wr_addr_o (ram_a_wr_addr),
        .mem_wr_data_o (ram_a_wr_data),
        .mem_wr_en_o   (ram_a_wr_en)
    );

    // -----------------------------------------------------------------
    // Morphological clean: open (erode->dilate) + parametrizable close.
    // morph_open_en_i / morph_close_en_i each gate their half independently;
    // both off = zero-latency combinational bypass.
    //
    // morph_to_ccl: u_morph_clean.m_axis -> raw bundle (un-strobed).
    // ccl_s_axis below copies tdata/tlast/tuser and injects ccl_beat_strobe as
    // tvalid, so u_ccl sees one beat per upstream beat-fire (tvalid && tready).
    // -----------------------------------------------------------------

    // morph output — shared interface bundle (tready driven back from ccl gating).
    axis_if #(.DATA_W(1), .USER_W(1)) morph_to_ccl ();

    axis_morph_clean #(
        .H_ACTIVE     (H_ACTIVE),
        .V_ACTIVE     (V_ACTIVE),
        .CLOSE_KERNEL (CFG.morph_close_kernel)
    ) u_morph_clean (
        .clk_i            (clk_dsp_i),
        .rst_n_i          (rst_dsp_n_i),
        .morph_open_en_i  (CFG.morph_open_en),
        .morph_close_en_i (CFG.morph_close_en),
        .s_axis           (motion_to_morph),
        .m_axis           (morph_to_ccl)
    );

    // Mask tready backpressure, re-expressed on the morph-cleaned stream.
    // In mask display and CCL_BBOX modes, the cleaned mask is also consumed
    // by the passthrough-to-output path (mask display) or used as the grey
    // canvas source (ccl_bbox). In motion mode, axis_ccl is the sole
    // consumer and drives bbox_msk_tready.
    logic bbox_msk_tready;
    assign morph_to_ccl.tready = ((ctrl_flow_i == sparevideo_pkg::CTRL_MASK_DISPLAY)
                               || (ctrl_flow_i == sparevideo_pkg::CTRL_CCL_BBOX))
                                  ? (proc_axis.tready && bbox_msk_tready) : bbox_msk_tready;

    // axis_ccl asserts bbox_msk_tready during streaming and deasserts it only
    // while its EOF resolution FSM is active (vblank). In multi-consumer
    // modes the upstream may also hold beats across cycles when proc_axis.tready=0.
    // Feed axis_ccl the global-handshake strobe (tvalid && tready) as its
    // tvalid so it advances exactly once per accepted beat, regardless of
    // which consumer gated the stall.
    logic ccl_beat_strobe;
    assign ccl_beat_strobe = morph_to_ccl.tvalid && morph_to_ccl.tready;

    // ccl_s_axis: morph_to_ccl tdata/tlast/tuser pass-through with
    // ccl_beat_strobe injected as tvalid; bbox_msk_tready back from u_ccl.tready.
    axis_if #(.DATA_W(1), .USER_W(1)) ccl_s_axis ();
    assign ccl_s_axis.tdata    = morph_to_ccl.tdata;
    assign ccl_s_axis.tvalid   = ccl_beat_strobe;
    assign ccl_s_axis.tlast    = morph_to_ccl.tlast;
    assign ccl_s_axis.tuser    = morph_to_ccl.tuser;
    assign bbox_msk_tready     = ccl_s_axis.tready;

    // bbox_if connects u_ccl sideband output directly to u_overlay_bbox.
    bbox_if u_ccl_bboxes ();

    axis_ccl #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE),
        .N_OUT    (N_OUT_TOP)
    ) u_ccl (
        .clk_i        (clk_dsp_i),
        .rst_n_i      (rst_dsp_n_i),
        .s_axis       (ccl_s_axis),
        .bboxes       (u_ccl_bboxes),
        .bbox_swap_o  (),   // unused
        .bbox_empty_o ()    // unused: overlay uses per-slot valids
    );

    // Overlay video input mux: in CTRL_CCL_BBOX mode, the overlay draws bboxes
    // onto a grey canvas derived combinationally from the mask stream; in
    // other modes, the overlay consumes the fork-B RGB stream.
    //
    // overlay_to_pix_out: u_overlay_bbox.m_axis -> output async FIFO s_axis.
    // Connected directly to u_fifo_out.s_axis (interface bundle).
    axis_if #(.DATA_W(24), .USER_W(1)) overlay_in ();
    axis_if #(.DATA_W(24), .USER_W(1)) overlay_to_pix_out ();

    logic [23:0] mask_grey_rgb;
    assign mask_grey_rgb = morph_to_ccl.tdata ? 24'h80_80_80 : 24'h20_20_20;

    always_comb begin
        if (ctrl_flow_i == sparevideo_pkg::CTRL_CCL_BBOX) begin
            overlay_in.tdata  = mask_grey_rgb;
            // Same multi-consumer gating as mask display: bbox_msk_tready=0
            // during ccl's EOF FSM must suppress tvalid so the overlay+FIFO
            // don't duplicate stalled beats.
            overlay_in.tvalid = morph_to_ccl.tvalid && bbox_msk_tready;
            overlay_in.tlast  = morph_to_ccl.tlast;
            overlay_in.tuser  = morph_to_ccl.tuser;
        end else begin
            overlay_in.tdata  = fork_b_to_overlay.tdata;
            overlay_in.tvalid = fork_b_to_overlay.tvalid;
            overlay_in.tlast  = fork_b_to_overlay.tlast;
            overlay_in.tuser  = fork_b_to_overlay.tuser;
        end
    end

    // Fork-B backpressure: in CCL_BBOX mode the fork-B path is unused (drained);
    // in other modes it feeds the overlay video input.
    assign fork_b_to_overlay.tready = (ctrl_flow_i == sparevideo_pkg::CTRL_CCL_BBOX) ? 1'b1 : overlay_in.tready;

    axis_overlay_bbox #(
        .H_ACTIVE   (H_ACTIVE),
        .V_ACTIVE   (V_ACTIVE),
        .N_OUT      (N_OUT_TOP),
        .BBOX_COLOR (CFG.bbox_color)
    ) u_overlay_bbox (
        .clk_i   (clk_dsp_i),
        .rst_n_i (rst_dsp_n_i),
        // AXI4-Stream input — from mux (fork-B RGB, or grey canvas in CCL_BBOX mode)
        .s_axis  (overlay_in),
        // AXI4-Stream output — video with bbox rectangles overlaid (RGB888)
        .m_axis  (overlay_to_pix_out),
        // Sideband input — bbox_if directly from u_ccl
        .bboxes  (u_ccl_bboxes)
    );

    // -----------------------------------------------------------------
    // Control-flow output mux
    //   Passthrough: hflip output -> output FIFO directly; fork inactive (tvalid=0).
    //                (Mirror when CFG.hflip_en=1; raw input when CFG.hflip_en=0.)
    //   Motion:      overlay output -> output FIFO; fork drives both paths.
    //   Mask:        1-bit mask expanded inline to B/W RGB -> output FIFO; overlay drained.
    //   CCL bbox:    overlay on grey canvas -> output FIFO; fork-B drained.
    // -----------------------------------------------------------------
    always_comb begin
        // Defaults
        proc_axis.tdata           = '0;
        proc_axis.tvalid          = 1'b0;
        proc_axis.tlast           = 1'b0;
        proc_axis.tuser           = 1'b0;
        overlay_to_pix_out.tready = 1'b0;
        hflip_to_fork.tready      = fork_s_tready;

        case (ctrl_flow_i)
            sparevideo_pkg::CTRL_PASSTHROUGH: begin
                proc_axis.tdata           = hflip_to_fork.tdata;
                proc_axis.tvalid          = hflip_to_fork.tvalid;
                proc_axis.tlast           = hflip_to_fork.tlast;
                proc_axis.tuser           = hflip_to_fork.tuser;
                hflip_to_fork.tready      = proc_axis.tready;
                overlay_to_pix_out.tready = 1'b1;   // fork inactive, no overlay data
            end
            sparevideo_pkg::CTRL_MASK_DISPLAY: begin
                // Inline 1-bit mask expansion to 24-bit black/white RGB.
                // Gate by bbox_msk_tready so the FIFO only writes when the
                // multi-consumer advance (proc && ccl) actually happens.
                proc_axis.tdata           = morph_to_ccl.tdata? 24'hFF_FF_FF : 24'h00_00_00;
                proc_axis.tvalid          = morph_to_ccl.tvalid && bbox_msk_tready;
                proc_axis.tlast           = morph_to_ccl.tlast;
                proc_axis.tuser           = morph_to_ccl.tuser;
                overlay_to_pix_out.tready = 1'b1;   // overlay path unused, drain
            end
            sparevideo_pkg::CTRL_CCL_BBOX: begin
                // Grey canvas + bboxes from the overlay; fork-B is drained.
                proc_axis.tdata           = overlay_to_pix_out.tdata;
                proc_axis.tvalid          = overlay_to_pix_out.tvalid;
                proc_axis.tlast           = overlay_to_pix_out.tlast;
                proc_axis.tuser           = overlay_to_pix_out.tuser;
                overlay_to_pix_out.tready = proc_axis.tready;
            end
            default: begin // CTRL_MOTION_DETECT
                proc_axis.tdata           = overlay_to_pix_out.tdata;
                proc_axis.tvalid          = overlay_to_pix_out.tvalid;
                proc_axis.tlast           = overlay_to_pix_out.tlast;
                proc_axis.tuser           = overlay_to_pix_out.tuser;
                overlay_to_pix_out.tready = proc_axis.tready;
            end
        endcase
    end

    // -----------------------------------------------------------------
    // Output async FIFO: clk_dsp -> clk_pix
    // -----------------------------------------------------------------
    // Sized to absorb axis_hflip TX bursts. During TX, hflip emits at
    // 1 pix/dsp_clk = 100 MHz while VGA drains at 1 pix/pix_clk = 25 MHz, so
    // the FIFO accumulates ~3*H_ACTIVE/4 entries per line before flow control
    // throttles upstream. At H_ACTIVE=320 that's ~240 entries; 256 covers it
    // with the verilog-axis output pipeline (~16 in-flight) absorbed in the
    // backpressure response.
    //
    // CFG.scaler_en=1: scaler emits 4 output beats per input pixel in bursts at
    // clk_dsp rate, while VGA drains at clk_pix_out (~clk_dsp/4). Per
    // output line of 640 pixels, the FIFO accumulates ~3W ≈ 480 entries
    // at peak. 1024 covers that with the verilog-axis output pipeline
    // (~16 in-flight) plus ~50% headroom.
    localparam int OUT_FIFO_DEPTH = CFG.scaler_en ? 1024 : 256;

    logic [$clog2(OUT_FIFO_DEPTH):0] fifo_out_depth;  // write-side (clk_dsp)

    // proc_axis: driven directly by the ctrl-flow mux below; feeds u_gamma_cor.s_axis.
    // proc_axis.tready (gamma stage's input ready, ultimately the output FIFO
    // write-side ready) is read back by the mux and by morph_to_ccl.tready.
    axis_if #(.DATA_W(24), .USER_W(1)) proc_axis ();

    // gamma_to_pix_out: u_gamma_cor.m_axis -> (scale2x or fifo_out).s_axis.
    axis_if #(.DATA_W(24), .USER_W(1)) gamma_to_pix_out ();

    // scale2x_to_pix_out: drives u_hud.s_axis whether the scaler is
    // present (CFG.scaler_en=1) or bypassed (CFG.scaler_en=0).
    axis_if #(.DATA_W(24), .USER_W(1)) scale2x_to_pix_out ();

    // Tail bundle between u_hud.m_axis and u_fifo_out.s_axis.
    axis_if #(.DATA_W(24), .USER_W(1)) hud_to_pix_out ();

    // ---- HUD sideband sources (clk_dsp domain) --------------------
    // SOF detectors: at the input boundary of the clk_dsp pipeline, and at
    // the input boundary of the HUD itself. The latency measurement uses
    // the former; frame_num counts at the latter so the value latched by
    // axis_hud matches the Python model's 0-based frame index.
    logic in_sof_seen;
    logic hud_in_sof_seen;
    assign in_sof_seen      = pix_in_to_hflip.tvalid && pix_in_to_hflip.tready
                           && pix_in_to_hflip.tuser;
    assign hud_in_sof_seen  = scale2x_to_pix_out.tvalid && scale2x_to_pix_out.tready
                           && scale2x_to_pix_out.tuser;

    // (a) frame_num: 0 on the first HUD-input-SOF after reset; increments
    //     after each HUD-input-SOF beat is accepted. Latched by axis_hud the
    //     same edge — the latch sees the pre-increment value (frame N).
    logic [15:0] hud_frame_num_q;
    always_ff @(posedge clk_dsp_i) begin
        if (!rst_dsp_n_i) hud_frame_num_q <= '0;
        else if (hud_in_sof_seen) hud_frame_num_q <= hud_frame_num_q + 1'b1;
    end

    // (b) bbox_count: popcount over u_ccl_bboxes.valid lanes. axis_hud
    //     saturates to 99 internally before display.
    logic [7:0] hud_bbox_count;
    always_comb begin : p_bbox_popcount
        int unsigned acc;
        acc = 0;
        for (int i = 0; i < N_OUT_TOP; i++)
            if (u_ccl_bboxes.valid[i]) acc = acc + 1;
        hud_bbox_count = 8'(acc);
    end

    // (c) ctrl_flow_tag: ctrl_flow_i is already on clk_dsp domain
    //     (quasi-static input). Pass through directly to u_hud.

    // (d) latency_us: cycles from input-SOF (at u_fifo_in.m_axis) to
    //     HUD-input-SOF (at scale2x_to_pix_out, i.e. u_hud.s_axis), all
    //     on clk_dsp_i. Per-frame measurement; 32-bit counter scaled to
    //     microseconds via `delta * 41 >> 12` ≈ delta / 100. Error <0.4%
    //     for delta <2^16 cycles.
    logic [31:0] cyc_counter;
    always_ff @(posedge clk_dsp_i) begin
        if (!rst_dsp_n_i) cyc_counter <= '0;
        else              cyc_counter <= cyc_counter + 1'b1;
    end

    logic [31:0] t_in_q;
    always_ff @(posedge clk_dsp_i) begin
        if (!rst_dsp_n_i) t_in_q <= '0;
        else if (in_sof_seen) t_in_q <= cyc_counter;
    end

    // hud_in_sof_seen is declared above with the other SOF detectors.
    logic [15:0] hud_latency_us_q;
    always_ff @(posedge clk_dsp_i) begin : p_latency_us
        logic [31:0] delta;
        logic [31:0] us;
        if (!rst_dsp_n_i) begin
            hud_latency_us_q <= '0;
        end else if (hud_in_sof_seen) begin
            // 10 ns per cycle / 1000 = /100 -> approximate by *41>>12.
            // delta < 2^16 cycles keeps the product within 32 bits.
            delta = cyc_counter - t_in_q;
            us    = (delta * 32'd41) >> 12;
            hud_latency_us_q <= (us > 32'd65535) ? 16'hFFFF : us[15:0];
        end
    end

    // sRGB display gamma correction at the post-mux tail. enable_i=0 is a
    // zero-latency combinational passthrough.
    axis_gamma_cor u_gamma_cor (
        .clk_i    (clk_dsp_i),
        .rst_n_i  (rst_dsp_n_i),
        .enable_i (CFG.gamma_en),
        .s_axis   (proc_axis),
        .m_axis   (gamma_to_pix_out)
    );

    generate
        if (CFG.scaler_en) begin : g_scale2x
            axis_scale2x #(
                .H_ACTIVE_IN (H_ACTIVE),
                .V_ACTIVE_IN (V_ACTIVE)
            ) u_scale2x (
                .clk_i   (clk_dsp_i),
                .rst_n_i (rst_dsp_n_i),
                .s_axis  (gamma_to_pix_out),
                .m_axis  (scale2x_to_pix_out)
            );
        end else begin : g_no_scale2x
            // CFG.scaler_en=0: gamma feeds the FIFO directly. Bridge the two
            // interface bundles with explicit assigns so the FIFO sees
            // gamma_to_pix_out's signals on the scale2x_to_pix_out
            // handle (keeps the FIFO instantiation single-form).
            assign scale2x_to_pix_out.tdata    = gamma_to_pix_out.tdata;
            assign scale2x_to_pix_out.tvalid   = gamma_to_pix_out.tvalid;
            assign scale2x_to_pix_out.tlast    = gamma_to_pix_out.tlast;
            assign scale2x_to_pix_out.tuser    = gamma_to_pix_out.tuser;
            assign gamma_to_pix_out.tready     = scale2x_to_pix_out.tready;
        end
    endgenerate

    // pix_out_axis: permanent bridge from output FIFO m_axis to VGA flat ports.
    // VGA controller is outside the AXI-Stream conversion scope and stays flat.
    logic [23:0] pix_out_tdata;
    logic        pix_out_tvalid;
    logic        pix_out_tready;
    logic        pix_out_tuser;
    axis_if #(.DATA_W(24), .USER_W(1)) pix_out_axis ();
    assign pix_out_tdata       = pix_out_axis.tdata;
    assign pix_out_tvalid      = pix_out_axis.tvalid;
    assign pix_out_tuser       = pix_out_axis.tuser;
    assign pix_out_axis.tready = pix_out_tready;
    // pix_out_axis.tlast is not consumed by VGA (m_axis_tlast was unconnected).

    axis_hud #(
        .H_ACTIVE (H_ACTIVE_OUT),
        .V_ACTIVE (V_ACTIVE_OUT),
        .HUD_X0   (8),
        .HUD_Y0   (8),
        .N_CHARS  (30)
    ) u_hud (
        .clk_i           (clk_dsp_i),
        .rst_n_i         (rst_dsp_n_i),
        .enable_i        (CFG.hud_en),
        .frame_num_i     (hud_frame_num_q),
        .bbox_count_i    (hud_bbox_count),
        .ctrl_flow_tag_i (ctrl_flow_i),
        .latency_us_i    (hud_latency_us_q),
        .s_axis          (scale2x_to_pix_out),
        .m_axis          (hud_to_pix_out)
    );

`ifdef VERILATOR
    // Per-frame latency log consumed by py/models/ops/_hud_metadata.py.
    // Written at HUD-input-SOF; one line per frame with the latched µs value.
    int hud_latency_fd;
    initial begin
        // Path relative to the simulator's cwd (dv/sim/) so the resulting
        // file lands at <repo_root>/dv/data/hud_latency.txt — the location
        // py/models/ops/_hud_metadata.py reads from.
        hud_latency_fd = $fopen("../data/hud_latency.txt", "w");
        if (hud_latency_fd == 0)
            $display("WARN: could not open ../data/hud_latency.txt for writing");
    end

    always_ff @(posedge clk_dsp_i) begin
        if (rst_dsp_n_i && hud_in_sof_seen && hud_latency_fd != 0)
            $fwrite(hud_latency_fd, "%0d\n", hud_latency_us_q);
    end

    final if (hud_latency_fd != 0) $fclose(hud_latency_fd);
`endif

    axis_async_fifo_ifc #(
        .DEPTH  (OUT_FIFO_DEPTH),
        .DATA_W (24),
        .USER_W (1)
    ) u_fifo_out (
        .s_clk            (clk_dsp_i),
        .s_rst_n          (rst_dsp_n_i),
        .m_clk            (clk_pix_out_i),
        .m_rst_n          (rst_pix_out_n_i),
        .s_axis           (hud_to_pix_out),
        .m_axis           (pix_out_axis),
        .s_status_depth   (fifo_out_depth),
        .s_status_overflow(fifo_out_overflow),
        .m_status_depth   ()
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

    always_ff @(posedge clk_pix_out_i) begin
        if (!rst_pix_out_n_i) begin
            vga_started <= 1'b0;
        end else if (!vga_started && pix_out_tvalid && pix_out_tuser) begin
            vga_started <= 1'b1;
        end
    end

    assign vga_rst_n      = rst_pix_out_n_i & vga_started;
    assign pix_out_tready = vga_pixel_ready & vga_started;

    vga_controller #(
        .H_ACTIVE      (H_ACTIVE_OUT),
        .H_FRONT_PORCH (H_FRONT_PORCH_OUT),
        .H_SYNC_PULSE  (H_SYNC_PULSE_OUT),
        .H_BACK_PORCH  (H_BACK_PORCH_OUT),
        .V_ACTIVE      (V_ACTIVE_OUT),
        .V_FRONT_PORCH (V_FRONT_PORCH_OUT),
        .V_SYNC_PULSE  (V_SYNC_PULSE_OUT),
        .V_BACK_PORCH  (V_BACK_PORCH_OUT)
    ) u_vga (
        .clk_i         (clk_pix_out_i),   // pixel clock
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
        @(posedge clk_pix_in_i) disable iff (!rst_pix_in_n_i)
            s_axis.tvalid |-> s_axis.tready
    ) else $error("sparevideo_top: input s_axis was back-pressured (DSP pipeline stalled)");

    // (2) Once started, no underruns inside the VGA active region.
    assert_no_output_underrun: assert property (
        @(posedge clk_pix_out_i) disable iff (!rst_pix_out_n_i || sva_drain_mode)
            (vga_started && vga_pixel_ready) |-> pix_out_tvalid
    ) else $error("sparevideo_top: output FIFO underrun during active region (screen tearing)");

    // (3) Input FIFO depth must never reach full capacity.
    assert_fifo_in_not_full: assert property (
        @(posedge clk_pix_in_i) disable iff (!rst_pix_in_n_i)
            fifo_in_depth < ($bits(fifo_in_depth))'(IN_FIFO_DEPTH)
    ) else $error("sparevideo_top: input FIFO full (depth=%0d/%0d) — overflow imminent",
                  fifo_in_depth, IN_FIFO_DEPTH);

    // (4) Output FIFO depth must never reach full capacity (clk_dsp domain).
    assert_fifo_out_not_full: assert property (
        @(posedge clk_dsp_i) disable iff (!rst_dsp_n_i)
            fifo_out_depth < ($bits(fifo_out_depth))'(OUT_FIFO_DEPTH)
    ) else $error("sparevideo_top: output FIFO full (depth=%0d/%0d) — overflow imminent",
                  fifo_out_depth, OUT_FIFO_DEPTH);

    // (5) Input FIFO must never overflow (sticky flag in clk_pix_in domain).
    assert_fifo_in_no_overflow: assert property (
        @(posedge clk_pix_in_i) disable iff (!rst_pix_in_n_i)
            !fifo_in_overflow
    ) else $error("sparevideo_top: input FIFO overflow — pixels lost at CDC crossing");

    // (6) Output FIFO must never overflow (sticky flag in clk_dsp domain).
    assert_fifo_out_no_overflow: assert property (
        @(posedge clk_dsp_i) disable iff (!rst_dsp_n_i)
            !fifo_out_overflow
    ) else $error("sparevideo_top: output FIFO overflow — DSP output rate exceeds VGA drain rate");
`endif

endmodule
