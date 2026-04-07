// Sparesoc Top-Level — AXI4-Stream video pipeline.
//
//   s_axis (clk_pix) -> async_fifo -> 4x register slice (clk_dsp)
//                                  -> async_fifo -> vga_controller (clk_pix)
//                                                -> RGB + hsync/vsync
//
// Vendored verilog-axis (MIT) provides the FIFOs and register slices.
// All AXI4-Stream signals carry 24-bit RGB ({R,G,B}), tlast = end-of-line,
// tuser[0] = start-of-frame.

module sparesoc_top #(
    parameter int H_ACTIVE      = 320,
    parameter int H_FRONT_PORCH = 4,
    parameter int H_SYNC_PULSE  = 8,
    parameter int H_BACK_PORCH  = 4,
    parameter int V_ACTIVE      = 240,
    parameter int V_FRONT_PORCH = 2,
    parameter int V_SYNC_PULSE  = 2,
    parameter int V_BACK_PORCH  = 2
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

    // -----------------------------------------------------------------
    // Input async FIFO: clk_pix -> clk_dsp
    // -----------------------------------------------------------------
    logic [23:0] dsp_in_tdata;
    logic        dsp_in_tvalid;
    logic        dsp_in_tready;
    logic        dsp_in_tlast;
    logic        dsp_in_tuser;

    axis_async_fifo #(
        .DEPTH       (32),
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

        .s_status_depth        (),
        .s_status_depth_commit (),
        .s_status_overflow     (),
        .s_status_bad_frame    (),
        .s_status_good_frame   (),
        .m_status_depth        (),
        .m_status_depth_commit (),
        .m_status_overflow     (),
        .m_status_bad_frame    (),
        .m_status_good_frame   ()
    );

    // -----------------------------------------------------------------
    // 4-stage register slice chain on clk_dsp (dummy processing)
    // -----------------------------------------------------------------
    logic [23:0] proc_tdata  [5];
    logic        proc_tvalid [5];
    logic        proc_tready [5];
    logic        proc_tlast  [5];
    logic        proc_tuser  [5];

    assign proc_tdata[0]  = dsp_in_tdata;
    assign proc_tvalid[0] = dsp_in_tvalid;
    assign dsp_in_tready  = proc_tready[0];
    assign proc_tlast[0]  = dsp_in_tlast;
    assign proc_tuser[0]  = dsp_in_tuser;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_proc
            axis_register #(
                .DATA_WIDTH  (24),
                .KEEP_ENABLE (0),
                .LAST_ENABLE (1),
                .ID_ENABLE   (0),
                .DEST_ENABLE (0),
                .USER_ENABLE (1),
                .USER_WIDTH  (1),
                .REG_TYPE    (2)
            ) u_reg (
                .clk           (clk_dsp),
                .rst           (rst_dsp),
                .s_axis_tdata  (proc_tdata[gi]),
                .s_axis_tkeep  (3'b0),
                .s_axis_tvalid (proc_tvalid[gi]),
                .s_axis_tready (proc_tready[gi]),
                .s_axis_tlast  (proc_tlast[gi]),
                .s_axis_tid    (8'b0),
                .s_axis_tdest  (8'b0),
                .s_axis_tuser  (proc_tuser[gi]),
                .m_axis_tdata  (proc_tdata[gi+1]),
                .m_axis_tkeep  (),
                .m_axis_tvalid (proc_tvalid[gi+1]),
                .m_axis_tready (proc_tready[gi+1]),
                .m_axis_tlast  (proc_tlast[gi+1]),
                .m_axis_tid    (),
                .m_axis_tdest  (),
                .m_axis_tuser  (proc_tuser[gi+1])
            );
        end
    endgenerate

    // -----------------------------------------------------------------
    // Output async FIFO: clk_dsp -> clk_pix
    // -----------------------------------------------------------------
    logic [23:0] pix_out_tdata;
    logic        pix_out_tvalid;
    logic        pix_out_tready;
    logic        pix_out_tuser;

    axis_async_fifo #(
        .DEPTH       (32),
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
        .s_axis_tdata     (proc_tdata[4]),
        .s_axis_tkeep     (3'b0),
        .s_axis_tvalid    (proc_tvalid[4]),
        .s_axis_tready    (proc_tready[4]),
        .s_axis_tlast     (proc_tlast[4]),
        .s_axis_tid       (8'b0),
        .s_axis_tdest     (8'b0),
        .s_axis_tuser     (proc_tuser[4]),

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

        .s_status_depth        (),
        .s_status_depth_commit (),
        .s_status_overflow     (),
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
    // The vendored VGA controller starts emitting active pixels on the
    // very first cycle out of reset. To keep passthrough bit-exact, we
    // hold the controller in reset until the output FIFO presents a
    // start-of-frame pixel (tuser[0] = 1). Once released the controller
    // pulls one pixel per active cycle via the standard ready/valid
    // handshake.
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
    // SVA checkers (opt-in: compile with +define+ENABLE_SVA — Icarus 12
    // does not support SVA, so they are disabled by default).
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
`ifdef ENABLE_SVA
    // Test-side hook: the TB drives `tb_sva_drain` high once it has
    // stopped feeding new pixels, so the inevitable end-of-sim underrun
    // is not flagged. Default-tied to 0 if no driver hooks in.
    logic sva_drain_mode;
    initial sva_drain_mode = 1'b0;

    // (1) Input must not be back-pressured.
    assert_no_input_backpressure: assert property (
        @(posedge clk_pix) disable iff (!rst_pix_n)
            s_axis_tvalid |-> s_axis_tready
    ) else $error("sparesoc_top: input s_axis was back-pressured (DSP pipeline stalled)");

    // (2) Once started, no underruns inside the VGA active region.
    assert_no_output_underrun: assert property (
        @(posedge clk_pix) disable iff (!rst_pix_n || sva_drain_mode)
            (vga_started && vga_pixel_ready) |-> pix_out_tvalid
    ) else $error("sparesoc_top: output FIFO underrun during active region (screen tearing)");
`endif

endmodule
