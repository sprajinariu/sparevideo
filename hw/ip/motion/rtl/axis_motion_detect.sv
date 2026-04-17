// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// AXI4-Stream motion detector.
//
// Computes a 1-bit motion mask by comparing the current frame's luma (Y8)
// against a per-pixel EMA background model stored in an external shared RAM
// (port A). Writes an EMA-updated background value back to RAM on acceptance.
// Passes the RGB video stream through unchanged with matched latency.
//
// Architecture:
//   axis_fork_pipe — AXI4-Stream 1-to-2 fork with sideband pipeline
//   rgb2ycrcb      — RGB → luma conversion (1-cycle latency)
//   axis_gauss3x3  — optional 3x3 Gaussian pre-filter (2-cycle latency, GAUSS_EN=1)
//   motion_core    — combinational: abs-diff threshold + EMA update
//
// Pipeline timing (GAUSS_EN=0: 1-cycle, GAUSS_EN=1: 3-cycle total latency):
//   Cycle C  : pixel N accepted → MAC sums computed combinationally in rgb2ycrcb,
//              mem_rd_addr issued combinationally
//   Cycle C+1: y_cur registered (rgb2ycrcb output)
//   [GAUSS_EN=1 only]
//   Cycle C+2: Gaussian line buffer read + column shift stage 1
//   Cycle C+3: Gaussian output registered (y_smooth), mem_rd_data arrives
//              → compare & emit
//
// Mask logic: a pixel is flagged as motion when abs(Y_cur - Y_prev) > THRESH.
// No brightness-polarity filter is applied — both arrival and departure pixels
// are flagged.
//
// The Y8 background model buffer is external — this module exposes a 1R1W
// memory port and connects to the shared `ram` port A at the top level.

module axis_motion_detect #(
    parameter int H_ACTIVE    = 320,
    parameter int V_ACTIVE    = 240,
    parameter int THRESH      = 16,
    parameter int ALPHA_SHIFT = 3,    // EMA alpha = 1 / (1 << ALPHA_SHIFT), default 1/8
    parameter int GAUSS_EN    = 1,    // 1 = Gaussian pre-filter enabled, 0 = bypass (raw Y)
    parameter int RGN_BASE    = 0,
    parameter int RGN_SIZE    = H_ACTIVE * V_ACTIVE
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    // AXI4-Stream input (RGB888)
    input  logic [23:0] s_axis_tdata_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,
    input  logic        s_axis_tuser_i,

    // AXI4-Stream output — video passthrough (RGB888)
    output logic [23:0] m_axis_vid_tdata_o,
    output logic        m_axis_vid_tvalid_o,
    input  logic        m_axis_vid_tready_i,
    output logic        m_axis_vid_tlast_o,
    output logic        m_axis_vid_tuser_o,

    // AXI4-Stream output — mask (1 bit)
    output logic        m_axis_msk_tdata_o,
    output logic        m_axis_msk_tvalid_o,
    input  logic        m_axis_msk_tready_i,
    output logic        m_axis_msk_tlast_o,
    output logic        m_axis_msk_tuser_o,

    // Memory port (to shared RAM port A)
    output logic [$clog2(RGN_BASE + RGN_SIZE)-1:0] mem_rd_addr_o,
    input  logic [7:0]                              mem_rd_data_i,
    output logic [$clog2(RGN_BASE + RGN_SIZE)-1:0] mem_wr_addr_o,
    output logic [7:0]                              mem_wr_data_o,
    output logic                                    mem_wr_en_o
);

    localparam int GAUSS_LATENCY = (GAUSS_EN != 0) ? 2 : 0;
    localparam int PIPE_STAGES   = 1 + GAUSS_LATENCY;  // 1 (rgb2ycrcb) + 2 (gauss) = 3

    // ---- AXI4-Stream 1-to-2 fork + sideband pipeline ----
    logic [23:0] fork_tdata;
    logic        fork_tlast, fork_tuser;
    logic        fork_a_tvalid, fork_b_tvalid;
    logic        fork_stall, fork_beat_done;

    axis_fork_pipe #(
        .DATA_WIDTH  (24),
        .PIPE_STAGES (PIPE_STAGES)
    ) u_fork (
        .clk_i             (clk_i),
        .rst_n_i           (rst_n_i),
        // AXI4-Stream input
        .s_axis_tdata_i    (s_axis_tdata_i),
        .s_axis_tvalid_i   (s_axis_tvalid_i),
        .s_axis_tready_o   (s_axis_tready_o),
        .s_axis_tlast_i    (s_axis_tlast_i),
        .s_axis_tuser_i    (s_axis_tuser_i),
        // Downstream ready (one per fork leg)
        .m_a_tready_i      (m_axis_vid_tready_i),
        .m_b_tready_i      (m_axis_msk_tready_i),
        // Pipeline output stage (shared sidebands)
        .pipe_tdata_o      (fork_tdata),
        .pipe_tlast_o      (fork_tlast),
        .pipe_tuser_o      (fork_tuser),
        // Per-output acceptance-gated tvalid
        .m_a_tvalid_o      (fork_a_tvalid),
        .m_b_tvalid_o      (fork_b_tvalid),
        // Pipeline control
        .pipe_stall_o      (fork_stall),
        .beat_done_o       (fork_beat_done)
    );

    // ---- Pixel address counter ----
    // pix_addr_reg holds the address of the NEXT expected pixel.
    // pix_addr is combinational: reset to 0 on SOF, otherwise use pix_addr_reg.
    logic [$clog2(H_ACTIVE * V_ACTIVE)-1:0] pix_addr_reg;
    logic [$clog2(H_ACTIVE * V_ACTIVE)-1:0] pix_addr;

    assign pix_addr = s_axis_tuser_i ? '0 : pix_addr_reg;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            pix_addr_reg <= '0;
        end else if (s_axis_tvalid_i && s_axis_tready_o) begin
            if (pix_addr == ($bits(pix_addr))'(H_ACTIVE * V_ACTIVE - 1))
                pix_addr_reg <= '0;
            else
                pix_addr_reg <= pix_addr + 1;
        end
    end

    // ---- Pixel address pipeline (track address through stages for write-back) ----
    logic [$clog2(H_ACTIVE * V_ACTIVE)-1:0] idx_pipe [PIPE_STAGES];

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            for (int i = 0; i < PIPE_STAGES; i++)
                idx_pipe[i] <= '0;
        end else if (!fork_stall) begin
            idx_pipe[0] <= pix_addr;
            for (int i = 1; i < PIPE_STAGES; i++)
                idx_pipe[i] <= idx_pipe[i-1];
        end
    end

    // ---- RGB → Y conversion (1-cycle pipeline) ----
    logic [7:0] y_cur;
    logic [7:0] cr_unused;
    logic [7:0] cb_unused;

    // During a stall the upstream source may present the next pixel on
    // s_axis_tdata_i (AXI permits this after tready goes low).  rgb2ycrcb
    // is a registered 1-cycle stage, so if its input changes mid-stall,
    // y_cur will reflect the wrong pixel.  Fix: feed the held pipeline
    // data (fork_tdata, stable during stall) so y_cur stays correct.
    logic [7:0] in_r, in_g, in_b;
    always_comb begin
        if (fork_stall) begin
            in_r = fork_tdata[23:16];
            in_g = fork_tdata[15:8];
            in_b = fork_tdata[7:0];
        end else begin
            in_r = s_axis_tdata_i[23:16];
            in_g = s_axis_tdata_i[15:8];
            in_b = s_axis_tdata_i[7:0];
        end
    end

    rgb2ycrcb u_rgb2y (
        .clk_i   (clk_i),
        .rst_n_i (rst_n_i),
        .r_i     (in_r),
        .g_i     (in_g),
        .b_i     (in_b),
        .y_o     (y_cur),
        .cb_o    (cb_unused),
        .cr_o    (cr_unused)
    );

    // ---- Gaussian control signals (1-cycle delayed acceptance) ----
    logic gauss_pixel_valid;
    logic gauss_sof;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            gauss_pixel_valid <= 1'b0;
            gauss_sof         <= 1'b0;
        end else if (!fork_stall) begin
            gauss_pixel_valid <= s_axis_tvalid_i && s_axis_tready_o;
            gauss_sof         <= s_axis_tuser_i;
        end
    end

    // ---- Optional Gaussian pre-filter on Y channel ----
    logic [7:0] y_smooth;

    generate
        if (GAUSS_EN != 0) begin : gen_gauss
            axis_gauss3x3 #(
                .H_ACTIVE (H_ACTIVE),
                .V_ACTIVE (V_ACTIVE)
            ) u_gauss (
                .clk_i   (clk_i),
                .rst_n_i (rst_n_i),
                .valid_i (gauss_pixel_valid),
                .sof_i   (gauss_sof),
                .stall_i (fork_stall),
                .y_i     (y_cur),
                .y_o     (y_smooth),
                .valid_o ()
            );
        end else begin : gen_no_gauss
            assign y_smooth = y_cur;
        end
    endgenerate

    // ---- Memory read: issue address 1 cycle before data is needed ----
    // RAM has 1-cycle registered read latency. The motion_core comparison
    // happens at pipeline stage PIPE_STAGES (when y_smooth and fork outputs
    // are ready). So the read address must be issued at stage PIPE_STAGES-1:
    //   GAUSS_EN=0 (PIPE_STAGES=1): pix_addr (combinational, same cycle as acceptance)
    //   GAUSS_EN=1 (PIPE_STAGES=3): idx_pipe[PIPE_STAGES-2] (2 cycles after acceptance)
    //
    // During a stall, pix_addr_reg may advance (e.g. wrapping after the last
    // pixel). Register the last non-stall address and re-issue it so
    // mem_rd_data_i stays stable.
    logic [$clog2(H_ACTIVE * V_ACTIVE)-1:0] mem_rd_idx;

    generate
        if (GAUSS_EN != 0) begin : gen_rd_idx
            assign mem_rd_idx = idx_pipe[PIPE_STAGES - 2];
        end else begin : gen_rd_idx_bypass
            assign mem_rd_idx = pix_addr;
        end
    endgenerate

    logic [$clog2(H_ACTIVE * V_ACTIVE)-1:0] pix_addr_hold;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i)
            pix_addr_hold <= '0;
        else if (!fork_stall)
            pix_addr_hold <= mem_rd_idx;
    end

    assign mem_rd_addr_o = ($bits(mem_rd_addr_o))'(RGN_BASE) +
                           (fork_stall ? pix_addr_hold : mem_rd_idx);

    // ---- Motion core (combinational: threshold + EMA) ----
    logic       mask_bit;
    logic [7:0] ema_update;

    motion_core #(
        .THRESH      (THRESH),
        .ALPHA_SHIFT (ALPHA_SHIFT)
    ) u_core (
        .y_cur_i      (y_smooth),   // smoothed Y when GAUSS_EN=1, raw Y when 0
        .y_bg_i       (mem_rd_data_i),
        .mask_bit_o   (mask_bit),
        .ema_update_o (ema_update)
    );

    // ---- Memory write-back: store EMA-updated background ----
    // Gate on beat_done so the write fires exactly once per pixel,
    // on the cycle both downstream consumers have accepted.
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            mem_wr_en_o   <= 1'b0;
            mem_wr_addr_o <= '0;
            mem_wr_data_o <= '0;
        end else begin
            mem_wr_en_o   <= fork_beat_done;
            mem_wr_addr_o <= ($bits(mem_wr_addr_o))'(RGN_BASE) + idx_pipe[PIPE_STAGES-1];
            mem_wr_data_o <= ema_update;
        end
    end

    // ---- Output: video passthrough ----
    assign m_axis_vid_tdata_o  = fork_tdata;
    assign m_axis_vid_tvalid_o = fork_a_tvalid;
    assign m_axis_vid_tlast_o  = fork_tlast;
    assign m_axis_vid_tuser_o  = fork_tuser;

    // ---- Output: mask ----
    assign m_axis_msk_tdata_o  = mask_bit;
    assign m_axis_msk_tvalid_o = fork_b_tvalid;
    assign m_axis_msk_tlast_o  = fork_tlast;
    assign m_axis_msk_tuser_o  = fork_tuser;

endmodule
