// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// AXI4-Stream motion detector — single-input, single-output mask producer.
//
// Computes a 1-bit motion mask by comparing the current frame's luma (Y8)
// against a per-pixel EMA background model stored in an external shared RAM
// (port A). Writes an EMA-updated background value back to RAM on acceptance.
//
// Architecture:
//   rgb2ycrcb      — RGB → luma conversion (1-cycle latency)
//   axis_gauss3x3  — optional true centered 3x3 Gaussian pre-filter
//                    (H_ACTIVE + 3 cycles latency, GAUSS_EN=1)
//   motion_core    — combinational: abs-diff threshold + EMA update
//
// The mask output is the module's only AXI4-Stream output. The RGB video path
// is handled at the top level via axis_fork, fully decoupled from mask
// processing.
//
// Pipeline timing:
//   GAUSS_EN=0: 1 cycle (rgb2ycrcb only) → pipe_valid follows gauss_pixel_valid
//               (the 1-deep sticky pending flag).
//   GAUSS_EN=1: pipe_valid is driven directly by axis_gauss3x3.valid_o; this
//               avoids the need to mirror gauss's variable-latency pipeline
//               (phantom cycles) with a fixed-depth sideband shift register.
//
// Addressing: the output pixel address is reconstructed from counters
// (out_row, out_col) that advance on each accepted output beat, rather than
// being carried forward from input. This decouples write-back addressing
// from the gauss phantom-cycle bookkeeping.
//
// Input-side flow control (required to satisfy gauss's valid-hold contract):
//   gauss_pixel_valid is a 1-deep sticky flag — set on accept and held until
//   gauss's real_pixel consumes it (gauss_consume). s_tready accepts only
//   when the slot is empty or gauss_consume is firing this cycle. This keeps
//   valid_i / y_i stable across gauss's phantom cycles (busy_o=1 → no
//   accept, rgb2ycrcb input held from held_tdata, y_cur stays stable). On
//   the next !busy cycle gauss consumes the still-pending pixel.
//   Without the sticky behaviour a phantom cycle would "eat" the pending
//   pixel: busy_o forces s_tready=0, the non-sticky valid would drop, and
//   gauss would never see the pixel again.
//
// Mask logic: a pixel is flagged as motion when abs(Y_cur - Y_prev) > THRESH.
// No brightness-polarity filter is applied — both arrival and departure pixels
// are flagged.
//
// The Y8 background model buffer is external — this module exposes a 1R1W
// memory port and connects to the shared `ram` port A at the top level.

module axis_motion_detect #(
    parameter int H_ACTIVE         = 320,
    parameter int V_ACTIVE         = 240,
    parameter int THRESH           = 16,
    parameter int ALPHA_SHIFT      = 3,    // alpha = 1/(1 << ALPHA_SHIFT), default 1/8 — non-motion rate
    parameter int ALPHA_SHIFT_SLOW = 6,    // alpha = 1/(1 << ALPHA_SHIFT_SLOW), default 1/64 — motion rate
    parameter int GRACE_FRAMES     = 8,    // fast-EMA grace frames after priming; 0 disables
    parameter int GAUSS_EN         = 1,    // 1 = Gaussian pre-filter enabled, 0 = bypass (raw Y)
    parameter int RGN_BASE         = 0,
    parameter int RGN_SIZE         = H_ACTIVE * V_ACTIVE
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    // AXI4-Stream input (RGB888)
    input  logic [23:0] s_axis_tdata_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,
    input  logic        s_axis_tuser_i,

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

    localparam int IDX_W       = $clog2(H_ACTIVE * V_ACTIVE);
    localparam int GRACE_CNT_W = (GRACE_FRAMES > 0) ? $clog2(GRACE_FRAMES + 1) : 1;

    // s_axis_tlast_i is kept for AXIS port symmetry but not consumed here —
    // output tlast is regenerated from out_col/out_row counters. Sink it into
    // an unused net so lint stays clean without a waiver.
    logic _unused_tlast;
    assign _unused_tlast = s_axis_tlast_i;

    // ---- Single-output pipeline control ----
    // The output valid signal comes directly from the Gaussian pre-filter's
    // valid_o (GAUSS_EN=1) or from a 1-cycle delayed accept (GAUSS_EN=0).
    // This avoids any attempt to mirror the gauss pipeline via a shift
    // register, which would desync across phantom cycles and busy stalls.
    logic pipe_valid;
    logic pipe_stall;    // output stage full and downstream not ready
    logic beat_done;     // output stage consumed by downstream
    logic gauss_busy;    // gauss needs a phantom cycle (busy_o)
    logic gauss_consume; // gauss consumes the pending pixel this cycle

    assign pipe_stall = pipe_valid && !m_axis_msk_tready_i;
    assign beat_done  = pipe_valid && m_axis_msk_tready_i;

    // Input ready: accept into the 1-deep pending slot whenever it is empty,
    // or whenever gauss will consume the current pending pixel this cycle
    // (freeing the slot for a simultaneous new accept).
    assign s_axis_tready_o = !gauss_pixel_valid || gauss_consume;

    // ---- RGB → Y conversion (1-cycle pipeline) ----
    logic [7:0] y_cur;
    logic [7:0] cr_unused;
    logic [7:0] cb_unused;

    // During a stall, the upstream source may present the next pixel on
    // s_axis_tdata_i (AXI permits this after tready goes low). rgb2ycrcb
    // is a registered 1-cycle stage, so if its input changes mid-stall,
    // y_cur will reflect the wrong pixel. Fix: feed held_tdata (the last
    // accepted pixel, stable during stall) so y_cur stays correct.
    logic [23:0] held_tdata;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i)
            held_tdata <= '0;
        else if (s_axis_tvalid_i && s_axis_tready_o)
            held_tdata <= s_axis_tdata_i;
    end

    // Feed rgb2ycrcb from the live bus on accept, else from held_tdata so the
    // last-accepted pixel stays at the input across gauss phantom cycles and
    // downstream stalls (keeps y_cur stable while gauss_pixel_valid is held).
    logic [7:0] in_r, in_g, in_b;
    always_comb begin
        if (s_axis_tvalid_i && s_axis_tready_o) begin
            in_r = s_axis_tdata_i[23:16];
            in_g = s_axis_tdata_i[15:8];
            in_b = s_axis_tdata_i[7:0];
        end else begin
            in_r = held_tdata[23:16];
            in_g = held_tdata[15:8];
            in_b = held_tdata[7:0];
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

    // ---- Gaussian pending-pixel state (sticky, 1-deep) ----
    // gauss_pixel_valid is set on accept (aligning with rgb2ycrcb's 1-cycle
    // y_cur latency) and held until gauss consumes the pixel. This is required
    // so that during a gauss phantom cycle (busy_o), the pending valid does
    // not spuriously drop before gauss advances past the phantom and consumes.
    // gauss_consume = gauss_pixel_valid && !pipe_stall && !gauss_busy is the
    // cycle gauss will retire the pending pixel (real_pixel inside gauss).
    logic gauss_pixel_valid;
    logic gauss_sof;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            gauss_pixel_valid <= 1'b0;
            gauss_sof         <= 1'b0;
        end else if (s_axis_tvalid_i && s_axis_tready_o) begin
            // New accept (may coincide with gauss_consume): overwrite slot.
            gauss_pixel_valid <= 1'b1;
            gauss_sof         <= s_axis_tuser_i;
        end else if (gauss_consume) begin
            // Consumed without new accept: slot empties.
            gauss_pixel_valid <= 1'b0;
            gauss_sof         <= 1'b0;
        end
    end

    // ---- Pipeline back-end: valid_o + y_smooth ----
    // GAUSS_EN=1: valid_o / y_o come from axis_gauss3x3.
    // GAUSS_EN=0: valid_o = gauss_pixel_valid (1-cycle delay of acceptance);
    //             y_smooth = y_cur (already 1-cycle delayed in rgb2ycrcb).
    logic [7:0] y_smooth;
    logic       pipe_valid_out;
    logic       gauss_busy_int;

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
                .stall_i (pipe_stall),
                .y_i     (y_cur),
                .y_o     (y_smooth),
                .valid_o (pipe_valid_out),
                .busy_o  (gauss_busy_int)
            );
        end else begin : gen_no_gauss
            assign y_smooth       = y_cur;
            assign pipe_valid_out = gauss_pixel_valid;
            assign gauss_busy_int = 1'b0;
        end
    endgenerate

    assign pipe_valid    = pipe_valid_out;
    assign gauss_busy    = gauss_busy_int;
    assign gauss_consume = gauss_pixel_valid && !pipe_stall && !gauss_busy;

    // ---- Output-side address counters ----
    // Reconstruct output pixel address from valid_o events. This avoids any
    // need to forward pix_addr through the gauss pipeline, which would desync
    // across phantom cycles. Counters wrap at frame boundaries and are reset
    // at motion_detect reset.
    logic [$clog2(H_ACTIVE)-1:0] out_col;
    logic [$clog2(V_ACTIVE)-1:0] out_row;
    logic [IDX_W-1:0]            out_addr;
    logic                        end_of_row;
    logic                        end_of_frame;

    assign end_of_row   = (out_col == ($bits(out_col))'(H_ACTIVE - 1));
    assign end_of_frame = end_of_row && (out_row == ($bits(out_row))'(V_ACTIVE - 1));
    assign out_addr     = (IDX_W)'(out_row) * (IDX_W)'(H_ACTIVE) + (IDX_W)'(out_col);

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            out_col <= '0;
            out_row <= '0;
        end else if (pipe_valid && !pipe_stall) begin
            if (end_of_row) begin
                out_col <= '0;
                out_row <= end_of_frame ? '0 : (out_row + 1);
            end else begin
                out_col <= out_col + 1;
            end
        end
    end

    // ---- Memory read: issue next-cycle address combinationally ----
    // RAM has 1-cycle registered read latency. To get RAM[out_addr_next] on
    // the cycle the corresponding valid_o fires, issue rd_addr one cycle
    // earlier. When valid_o is currently high (and not stalled), out_addr
    // will increment next cycle, so rd_addr = out_addr + 1 (with wrap);
    // otherwise rd_addr = out_addr.
    logic [IDX_W-1:0] rd_addr_next;
    always_comb begin
        if (pipe_valid && !pipe_stall) begin
            rd_addr_next = end_of_frame ? '0 : (out_addr + 1);
        end else begin
            rd_addr_next = out_addr;
        end
    end

    assign mem_rd_addr_o = ($bits(mem_rd_addr_o))'(RGN_BASE) + rd_addr_next;

    // ---- Priming flag: latches on end_of_frame of frame 0, held thereafter. ----
    // While primed==0, the write-back path stores y_smooth directly (hard-init)
    // and mask_bit is forced to 0 inside motion_core.
    logic primed;
    logic beat_done_eof;

    assign beat_done_eof = pipe_valid && !pipe_stall && end_of_frame;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i)
            primed <= 1'b0;
        else if (beat_done_eof)
            primed <= 1'b1;
    end

    // ---- Grace-window counter: fast-EMA override for first GRACE_FRAMES frames after priming. ----
    // While `in_grace == 1`, bg_next always uses ema_update (fast rate), regardless of raw_motion.
    // This suppresses the frame-0 hard-init ghost (any object present in frame 0 contaminates
    // bg[P_original]; without grace, the slow EMA keeps that ghost alive for ~1/α_slow frames).
    logic [GRACE_CNT_W-1:0] grace_cnt;
    logic                   in_grace;

    /* verilator lint_off UNSIGNED */
    assign in_grace = primed && (grace_cnt < (GRACE_CNT_W)'(GRACE_FRAMES));
    /* verilator lint_on UNSIGNED */

    always_ff @(posedge clk_i) begin
        if (!rst_n_i)
            grace_cnt <= '0;
        else if (beat_done_eof && in_grace)
            grace_cnt <= grace_cnt + 1'b1;
    end

    // ---- Motion core (combinational: threshold + EMA, two rates) ----
    logic       mask_bit;
    logic       raw_motion;
    logic [7:0] ema_update;
    logic [7:0] ema_update_slow;

    motion_core #(
        .THRESH           (THRESH),
        .ALPHA_SHIFT      (ALPHA_SHIFT),
        .ALPHA_SHIFT_SLOW (ALPHA_SHIFT_SLOW)
    ) u_core (
        .y_cur_i            (y_smooth),
        .y_bg_i             (mem_rd_data_i),
        .primed_i           (primed),
        .mask_bit_o         (mask_bit),
        .raw_motion_o       (raw_motion),
        .ema_update_o       (ema_update),
        .ema_update_slow_o  (ema_update_slow)
    );

    // ---- Memory write-back: priming (hard-init) / grace (fast EMA) / motion (slow EMA) / non-motion (fast EMA) ----
    // Fire on beat_done so each accepted output writes exactly once.
    logic [7:0] bg_next;
    always_comb begin
        if (!primed)
            bg_next = y_smooth;        // frame-0 hard-init
        else if (in_grace || !raw_motion)
            bg_next = ema_update;      // grace-window or non-motion pixel → fast rate
        else
            bg_next = ema_update_slow; // motion pixel (post-grace) → slow rate
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            mem_wr_en_o   <= 1'b0;
            mem_wr_addr_o <= '0;
            mem_wr_data_o <= '0;
        end else begin
            mem_wr_en_o   <= beat_done;
            mem_wr_addr_o <= ($bits(mem_wr_addr_o))'(RGN_BASE) + out_addr;
            mem_wr_data_o <= bg_next;
        end
    end

    // ---- Output: mask ----
    assign m_axis_msk_tdata_o  = mask_bit;
    assign m_axis_msk_tvalid_o = pipe_valid;
    assign m_axis_msk_tlast_o  = end_of_row;
    assign m_axis_msk_tuser_o  = (out_col == '0) && (out_row == '0);

endmodule
