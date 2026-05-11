// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// AXI4-Stream motion detector — ViBe sample-based background model.
//
// Drop-in replacement for axis_motion_detect under cfg_t.bg_model=BG_MODEL_VIBE.
// Computes a 1-bit motion mask by comparing the current frame's luma (Y8) against
// a K-sample-per-pixel background model maintained inside motion_core_vibe.
//
// Architecture:
//   rgb2ycrcb        — RGB → luma conversion (1-cycle latency)
//   axis_gauss3x3    — optional true-centred 3x3 Gaussian pre-filter
//                      (H_ACTIVE + 3 cycles latency when GAUSS_EN=1)
//   motion_core_vibe — ViBe K comparators, match counter, update/diffusion logic
//
// The mask output is the module's only AXI4-Stream output. The RGB video path is
// handled at the top level via axis_fork, fully decoupled from mask processing.
//
// The held_tdata pattern mirrors axis_motion_detect: the upstream source may
// present the next pixel immediately after acceptance; held_tdata captures the
// last accepted pixel and keeps rgb2ycrcb input stable while the pipeline is
// stalled (or while gauss phantom cycles are draining).
//
// Gauss generate-if: mirrors axis_motion_detect's GAUSS_EN pattern exactly.
//   GAUSS_EN=1 → axis_gauss3x3 instance; valid/sof/eol propagate from gauss outputs
//               via the 1-deep sticky slot; s_axis_pix.tready gated through gauss.
//   GAUSS_EN=0 → direct bypass; valid/sof/eol come from the 1-deep sticky flag.
//
// Input-side flow control (GAUSS_EN=1):
//   gauss_pixel_valid is a 1-deep sticky flag — set on accept and held until gauss
//   consumes the pixel (gauss_consume). s_axis_pix.tready accepts only when the
//   slot is empty or gauss_consume fires this cycle. Prevents phantom cycles from
//   silently dropping the pending pixel when busy_o=1.
//
// SOF/EOL wiring: m_axis_msk.tuser[0] = u_core.sof_o; m_axis_msk.tlast = u_core.eol_o.
// Frame counter: incremented on each accepted SOF beat; passed to core as frame_count_i.
// Backpressure shell: pipe_stall = m_axis_msk.tvalid && !m_axis_msk.tready.
// held_y captures y_smooth on every non-stalled accepted beat; y_to_core
// is muxed to held_y during stall so the core sees the stable luma value
// of the pixel currently in-flight. pipe_stall is also forwarded to the
// core so it can gate its PRNG, pix_addr_hold, and pipeline registers.

module axis_motion_detect_vibe import sparevideo_pkg::*; #(
    parameter int          WIDTH                 = 320,
    parameter int          HEIGHT                = 240,
    parameter int          K                     = 8,
    parameter int          R                     = 20,
    parameter int          MIN_MATCH             = 2,
    parameter int          PHI_UPDATE            = 16,
    parameter int          PHI_DIFFUSE           = 16,
    parameter logic        GAUSS_EN              = 1'b1,
    parameter logic        VIBE_BG_INIT_EXTERNAL = 1'b0,
    parameter logic [31:0] PRNG_SEED             = 32'hDEADBEEF,
    parameter string       INIT_BANK_FILE        = ""
) (
    // --- Clocks and resets ---
    input  logic   clk_i,
    input  logic   rst_n_i,

    // ---- AXI4-Stream input (RGB888) -----------------------------------------
    axis_if.rx     s_axis_pix,

    // ---- AXI4-Stream output — mask (1-bit) ----------------------------------
    axis_if.tx     m_axis_msk
);

    // ---- Held pixel (stability during stall / gauss phantom cycles) ----
    // Mirror of axis_motion_detect's held_tdata: upstream may present the next
    // pixel immediately after acceptance; feed rgb2ycrcb from held_tdata when
    // the pipeline is busy so y_cur stays stable.
    logic [23:0] held_tdata;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i)
            held_tdata <= '0;
        else if (s_axis_pix.tvalid && s_axis_pix.tready)
            held_tdata <= s_axis_pix.tdata;
    end

    // ---- RGB → Y conversion (1-cycle pipeline) ----
    logic [7:0] y_cur;
    logic [7:0] cb_unused;
    logic [7:0] cr_unused;

    // Use held_tdata when not accepting (stable across stall / phantom cycles).
    logic [7:0] in_r, in_g, in_b;
    always_comb begin
        if (s_axis_pix.tvalid && s_axis_pix.tready) begin
            in_r = s_axis_pix.tdata[23:16];
            in_g = s_axis_pix.tdata[15:8];
            in_b = s_axis_pix.tdata[7:0];
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

    // Sink the unused Cb/Cr and suppress lint.
    logic _unused_cb_cr;
    assign _unused_cb_cr = |{cb_unused, cr_unused};

    // ---- Gaussian pending-pixel state (sticky, 1-deep) ----
    // gauss_pixel_valid is set on accept (aligning with rgb2ycrcb's 1-cycle
    // y_cur latency) and held until gauss consumes the pixel. This is required
    // so that during a gauss phantom cycle (busy_o), the pending valid does
    // not spuriously drop before gauss advances past the phantom and consumes.
    // gauss_consume = gauss_pixel_valid && !pipe_stall && !gauss_busy is the
    // cycle gauss will retire the pending pixel (real_pixel inside gauss).
    logic gauss_pixel_valid;
    logic gauss_sof;
    logic gauss_eol;

    // pipe_stall / gauss_busy — set below in the generate block (GAUSS_EN=0 ties
    // gauss_busy to 0 so these resolve combinationally with no circularity).
    logic pipe_stall;
    logic gauss_busy;
    logic gauss_consume;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            gauss_pixel_valid <= 1'b0;
            gauss_sof         <= 1'b0;
            gauss_eol         <= 1'b0;
        end else if (s_axis_pix.tvalid && s_axis_pix.tready) begin
            // New accept (may coincide with gauss_consume): overwrite slot.
            gauss_pixel_valid <= 1'b1;
            gauss_sof         <= s_axis_pix.tuser[0];
            gauss_eol         <= s_axis_pix.tlast;
        end else if (gauss_consume) begin
            // Consumed without new accept: slot empties.
            gauss_pixel_valid <= 1'b0;
            gauss_sof         <= 1'b0;
            gauss_eol         <= 1'b0;
        end
    end

    // ---- Frame counter ----
    // Counts completed frames: 0 during frame 0, 1 during frame 1, etc.
    // Incremented after the last row of each frame (eol accepted while
    // row_count == HEIGHT-1).
    //
    // frame_count_core is a 1-cycle delayed copy aligned to the core's
    // pixel timeline. The wrapper's 1-deep gauss_pixel_valid sticky slot
    // introduces a 1-cycle delay from wrapper-accept to core-valid_i; the
    // delayed copy ensures frame_count_i==0 for every pixel of frame 0 as
    // seen by the core.
    logic [15:0] frame_count;
    logic [15:0] frame_count_core;  // 1-cycle delayed, wired to core
    logic [15:0] row_count;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            frame_count      <= 16'd0;
            frame_count_core <= 16'd0;
            row_count        <= 16'd0;
        end else begin
            // Delay frame_count by one cycle for the core
            frame_count_core <= frame_count;

            if (s_axis_pix.tvalid && s_axis_pix.tready) begin
                if (s_axis_pix.tuser[0]) begin
                    // SOF: reset row counter for this frame
                    row_count <= 16'd0;
                end else if (s_axis_pix.tlast) begin
                    // EOL: advance row counter
                    row_count <= row_count + 16'd1;
                end
                // Increment frame_count at the last pixel of the last row
                if (s_axis_pix.tlast && (row_count == 16'(HEIGHT - 1)))
                    frame_count <= frame_count + 16'd1;
            end
        end
    end

    // ---- Pipeline back-end: valid_post_gauss + y_smooth ----
    // GAUSS_EN=1: valid / y / sof / eol come from axis_gauss3x3.
    //             Note: axis_gauss3x3 does not expose sof_o / eol_o; those are
    //             carried through the 1-deep sticky (gauss_sof / gauss_eol)
    //             and forwarded when gauss fires valid_o. The gauss block's
    //             SOF tracking resets its internal window; we just pipe the
    //             flag through the same sticky slot.
    // GAUSS_EN=0: valid = gauss_pixel_valid; y = y_cur (already 1-cycle delayed).
    logic [7:0] y_smooth;
    logic       valid_post_gauss;
    logic       sof_post_gauss;
    logic       eol_post_gauss;
    logic       gauss_busy_int;
    logic       pipe_valid;

    // pipe_stall: output stage full but downstream not ready.
    assign pipe_stall = pipe_valid && !m_axis_msk.tready;

    generate
        if (GAUSS_EN != 0) begin : gen_gauss
            // axis_gauss3x3 does not output sof/eol; mirror the sticky sof/eol
            // slot when gauss fires its valid_o — both toggle in lock-step with
            // the pixel stream, so the slot is always coherent.
            logic sof_mirror;
            logic eol_mirror;

            always_ff @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) begin
                    sof_mirror <= 1'b0;
                    eol_mirror <= 1'b0;
                end else if (gauss_consume) begin
                    sof_mirror <= gauss_sof;
                    eol_mirror <= gauss_eol;
                end
            end

            logic gauss_valid_o;
            logic gauss_busy_o;

            axis_gauss3x3 #(
                .H_ACTIVE (WIDTH),
                .V_ACTIVE (HEIGHT)
            ) u_gauss (
                .clk_i   (clk_i),
                .rst_n_i (rst_n_i),
                .valid_i (gauss_pixel_valid),
                .sof_i   (gauss_sof),
                .stall_i (pipe_stall),
                .y_i     (y_cur),
                .y_o     (y_smooth),
                .valid_o (gauss_valid_o),
                .busy_o  (gauss_busy_o)
            );

            assign valid_post_gauss = gauss_valid_o;
            assign sof_post_gauss   = sof_mirror;
            assign eol_post_gauss   = eol_mirror;
            assign gauss_busy_int   = gauss_busy_o;

        end else begin : gen_no_gauss
            assign y_smooth         = y_cur;
            assign valid_post_gauss = gauss_pixel_valid;
            assign sof_post_gauss   = gauss_sof;
            assign eol_post_gauss   = gauss_eol;
            assign gauss_busy_int   = 1'b0;
        end
    endgenerate

    assign pipe_valid    = valid_post_gauss;
    assign gauss_busy    = gauss_busy_int;
    assign gauss_consume = gauss_pixel_valid && !pipe_stall && !gauss_busy;

    // ---- Backpressure shell: held_y + y_to_core mux ----
    // held_y captures y_smooth on every non-stalled beat accepted by the core.
    // During pipe_stall, y_to_core is sourced from held_y so the core's luma
    // input stays stable while the output side is back-pressured.
    logic [7:0] held_y;
    logic [7:0] y_to_core;
    logic       core_ready;
    // core_drain_busy is tied to 0 by motion_core_vibe in the W+1-delay FIFO
    // design (the FIFO drains continuously in the active region); the wire is
    // kept here to satisfy the core port but is no longer used to gate tready.
    logic       core_drain_busy;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i)
            held_y <= 8'd0;
        else if (valid_post_gauss && core_ready && !pipe_stall)
            held_y <= y_smooth;
    end

    assign y_to_core = pipe_stall ? held_y : y_smooth;

    // ---- Core instantiation ----
    logic core_sof_o;

    motion_core_vibe #(
        .WIDTH                 (WIDTH),
        .HEIGHT                (HEIGHT),
        .K                     (K),
        .R                     (R),
        .MIN_MATCH             (MIN_MATCH),
        .PHI_UPDATE            (PHI_UPDATE),
        .PHI_DIFFUSE           (PHI_DIFFUSE),
        .VIBE_BG_INIT_EXTERNAL (VIBE_BG_INIT_EXTERNAL),
        .PRNG_SEED             (PRNG_SEED),
        .INIT_BANK_FILE        (INIT_BANK_FILE)
    ) u_core (
        .clk_i         (clk_i),
        .rst_n_i       (rst_n_i),
        .valid_i       (valid_post_gauss),
        .ready_o       (core_ready),
        .pipe_stall_i  (pipe_stall),
        .sof_i         (sof_post_gauss),
        .eol_i         (eol_post_gauss),
        .y_in_i        (y_to_core),
        .frame_count_i (frame_count_core),
        .valid_o       (m_axis_msk.tvalid),
        .ready_i       (m_axis_msk.tready),
        .sof_o         (core_sof_o),
        .eol_o         (m_axis_msk.tlast),
        .mask_o        (m_axis_msk.tdata[0]),
        .drain_busy_o  (core_drain_busy)
    );

    // SOF wired from core output to mask tuser[0].
    assign m_axis_msk.tuser = {{($bits(m_axis_msk.tuser)-1){1'b0}}, core_sof_o};

    // ---- Input ready ----
    // Accept a new pixel into the 1-deep pending slot when the slot is empty
    // OR the current slot occupant will be consumed this cycle (gauss_consume).
    //
    // The legacy drain-busy gate (V-blank batch FIFO drain) has been removed:
    // motion_core_vibe now uses a W+1-delay FIFO that drains continuously in
    // the active region, so input back-pressure is not needed for write drain.
    assign s_axis_pix.tready = !gauss_pixel_valid || gauss_consume;

    // Sink core_drain_busy (tied to 0 by the core today; kept for waveform/lint).
    logic _unused_core_drain_busy;
    assign _unused_core_drain_busy = core_drain_busy;

endmodule
