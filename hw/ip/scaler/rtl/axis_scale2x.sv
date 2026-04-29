// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_scale2x -- 2x bilinear spatial upscaler on a 24-bit RGB AXIS.
//
// Three line buffers in cyclic rotation give "write target" / "anchor" /
// "prev" disjoint at all times, so the input writer and the output emitter
// run as two independent processes with no read/write aliasing.
//
// Per-row schedule (steady state, after row 0):
//   - Input writer: writes one pixel per 4 DSP cycles (under clk_dsp = 4 *
//     clk_pix_in rate balance) into write_buf at column in_col_q.
//   - Output emitter: emits one beat per DSP cycle for 4W cycles, reading
//     anchor_buf during the top phase (out_beat_q in [0, 2W)) and reading
//     anchor_buf + prev_buf during the bot phase ([2W, 4W)).
//   - At input tlast + emit-pair-done, wr_sel_q advances mod 3.
//
// Frame entry: accepted s_axis.tuser re-arms first_pair_q (top-edge
// replicate seed -- writes go to BOTH write_buf AND anchor_buf for the
// first pair of a frame; the seed lands where pair 0's prev_sel will read
// it after the next rotation). wr_sel_q is NOT reset on SOF -- the rotation
// is invariant under starting offset.
//
// Latency: 4W clk_dsp cycles from accepted SOF to first m_axis beat (one
// full input row of 1:4-paced intake before pair 0's bot can read row 0).
// Steady-state output rate: 1.0 beats/cycle sustained, no per-row burst.

module axis_scale2x #(
    parameter int H_ACTIVE_IN = sparevideo_pkg::H_ACTIVE,
    parameter int V_ACTIVE_IN = sparevideo_pkg::V_ACTIVE   // informational
) (
    input  logic clk_i,
    input  logic rst_n_i,
    axis_if.rx   s_axis,                                    // DATA_W=24, USER_W=1
    axis_if.tx   m_axis                                     // DATA_W=24, USER_W=1
);

    localparam int COL_W     = $clog2(H_ACTIVE_IN + 1);
    localparam int OUT_COL_W = $clog2(2*H_ACTIVE_IN + 1);
    localparam int BEAT_W    = $clog2(4*H_ACTIVE_IN + 1);

    // ---- Three line buffers ----
    logic [23:0] buf0 [H_ACTIVE_IN];
    logic [23:0] buf1 [H_ACTIVE_IN];
    logic [23:0] buf2 [H_ACTIVE_IN];

    // ---- Buffer rotation ----
    logic [1:0] wr_sel_q;
    logic [1:0] anchor_sel, prev_sel;
    always_comb begin
        unique case (wr_sel_q)
            2'd0:    begin anchor_sel = 2'd2; prev_sel = 2'd1; end
            2'd1:    begin anchor_sel = 2'd0; prev_sel = 2'd2; end
            default: begin anchor_sel = 2'd1; prev_sel = 2'd0; end
        endcase
    end

    // ---- Counters and flags ----
    logic [COL_W-1:0]  in_col_q;
    logic [BEAT_W-1:0] out_beat_q;
    logic              in_done_q;
    logic              emit_armed_q;
    logic              first_pair_q;
    logic              sof_pending_q;

    // ---- Per-channel 2-tap round-half-up average. avg2(a, a) = a. ----
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [23:0] avg2(input logic [23:0] a,
                                         input logic [23:0] b);
        logic [8:0] r_sum, g_sum, b_sum;
        begin
            r_sum = {1'b0, a[23:16]} + {1'b0, b[23:16]} + 9'd1;
            g_sum = {1'b0, a[15:8]}  + {1'b0, b[15:8]}  + 9'd1;
            b_sum = {1'b0, a[7:0]}   + {1'b0, b[7:0]}   + 9'd1;
            avg2  = {r_sum[8:1], g_sum[8:1], b_sum[8:1]};
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- Beat -> address decode ----
    logic                  in_bot_phase;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [OUT_COL_W-1:0]  phase_col;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [COL_W-1:0]      src_c, src_cp1;
    logic                  beat_is_odd;

    assign in_bot_phase = (out_beat_q >= BEAT_W'(2*H_ACTIVE_IN));
    assign phase_col    = in_bot_phase
                            ? OUT_COL_W'(out_beat_q - BEAT_W'(2*H_ACTIVE_IN))
                            : OUT_COL_W'(out_beat_q);
    assign src_c        = phase_col[OUT_COL_W-1:1];
    assign src_cp1      = (src_c == COL_W'(H_ACTIVE_IN - 1))
                            ? src_c
                            : COL_W'(src_c + COL_W'(1));
    assign beat_is_odd  = out_beat_q[0];

    // ---- Buffer reads (combinational, two reads per buffer) ----
    logic [23:0] anchor_c, anchor_cp1, prev_c, prev_cp1;
    always_comb begin
        unique case (anchor_sel)
            2'd0:    begin anchor_c = buf0[src_c]; anchor_cp1 = buf0[src_cp1]; end
            2'd1:    begin anchor_c = buf1[src_c]; anchor_cp1 = buf1[src_cp1]; end
            default: begin anchor_c = buf2[src_c]; anchor_cp1 = buf2[src_cp1]; end
        endcase
        unique case (prev_sel)
            2'd0:    begin prev_c = buf0[src_c]; prev_cp1 = buf0[src_cp1]; end
            2'd1:    begin prev_c = buf1[src_c]; prev_cp1 = buf1[src_cp1]; end
            default: begin prev_c = buf2[src_c]; prev_cp1 = buf2[src_cp1]; end
        endcase
    end

    // ---- Output beat formatter ----
    logic [23:0] tx_data;
    always_comb begin
        if (!in_bot_phase) begin
            tx_data = beat_is_odd ? avg2(anchor_c, anchor_cp1) : anchor_c;
        end else begin
            tx_data = beat_is_odd
                        ? avg2(avg2(anchor_c, anchor_cp1),
                               avg2(prev_c,   prev_cp1))
                        : avg2(anchor_c, prev_c);
        end
    end

    // ---- SOF same-cycle override ----
    // first_pair_q rearms at the SOF tail of always_ff (NBA), but the
    // seed write needs the post-SOF value in the SAME cycle as the SOF
    // accept. effective_first_pair makes the buffer-write code see
    // first_pair_q=1 on the SOF cycle of every new frame.
    logic do_accept, do_emit;
    logic is_sof_pixel;
    logic effective_first_pair;

    assign do_accept           = s_axis.tvalid && s_axis.tready;
    assign do_emit             = m_axis.tvalid && m_axis.tready;
    assign is_sof_pixel        = do_accept && s_axis.tuser;
    assign effective_first_pair = first_pair_q || is_sof_pixel;

    // ---- AXIS port drives ----
    // tready stalls a SOF input while emit is still in progress (defensive
    // against malformed back-to-back frames; see plan §"SOF stall"). Under
    // nominal V_BLANK it is a no-op.
    assign s_axis.tready = !in_done_q && !(s_axis.tvalid && s_axis.tuser && emit_armed_q);
    assign m_axis.tdata  = tx_data;
    assign m_axis.tvalid = emit_armed_q;
    assign m_axis.tlast  = emit_armed_q && ((out_beat_q == BEAT_W'(2*H_ACTIVE_IN - 1)) ||
                                            (out_beat_q == BEAT_W'(4*H_ACTIVE_IN - 1)));
    assign m_axis.tuser  = emit_armed_q && sof_pending_q && (out_beat_q == '0);

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            wr_sel_q       <= 2'd0;
            in_col_q       <= '0;
            out_beat_q     <= '0;
            in_done_q      <= 1'b0;
            emit_armed_q   <= 1'b0;
            first_pair_q   <= 1'b1;
            sof_pending_q  <= 1'b0;
        end else begin
            // ---- Input writer ----
            if (do_accept) begin
                // Write to write_buf
                unique case (wr_sel_q)
                    2'd0:    buf0[in_col_q] <= s_axis.tdata;
                    2'd1:    buf1[in_col_q] <= s_axis.tdata;
                    default: buf2[in_col_q] <= s_axis.tdata;
                endcase
                // First-pair top-edge replicate seed: also write to anchor_buf
                // (which becomes prev_buf for pair 0 emit after the next
                // rotation; see plan §"Why the seed goes to anchor_sel").
                if (effective_first_pair) begin
                    unique case (anchor_sel)
                        2'd0:    buf0[in_col_q] <= s_axis.tdata;
                        2'd1:    buf1[in_col_q] <= s_axis.tdata;
                        default: buf2[in_col_q] <= s_axis.tdata;
                    endcase
                end
                if (s_axis.tuser)
                    sof_pending_q <= 1'b1;
                if (s_axis.tlast) begin
                    in_col_q  <= '0;
                    in_done_q <= 1'b1;
                end else begin
                    in_col_q <= in_col_q + COL_W'(1);
                end
            end

            // ---- Output emitter ----
            if (do_emit) begin
                if (out_beat_q == BEAT_W'(4*H_ACTIVE_IN - 1)) begin
                    out_beat_q   <= '0;
                    emit_armed_q <= 1'b0;
                end else begin
                    out_beat_q <= out_beat_q + BEAT_W'(1);
                end
                if (sof_pending_q && (out_beat_q == '0))
                    sof_pending_q <= 1'b0;
            end

            // ---- Boundary rotation ----
            // Triggers when input row is done AND emitter is idle. There may
            // be a 1-cycle bubble between consecutive pairs (m_axis.tvalid=0
            // for one cycle while emit_armed_q transitions through 0); this
            // is acceptable and adds 1/(4W) overhead.
            if (in_done_q && !emit_armed_q) begin
                wr_sel_q     <= (wr_sel_q == 2'd2) ? 2'd0 : (wr_sel_q + 2'd1);
                in_done_q    <= 1'b0;
                emit_armed_q <= 1'b1;
                first_pair_q <= 1'b0;
            end

            // ---- SOF re-arm ----
            // Accepted SOF input rearms first_pair_q for the new frame's
            // top-edge replicate seeding. wr_sel_q is NOT reset — the
            // rotation is invariant under starting offset.
            if (is_sof_pixel) begin
                first_pair_q <= 1'b1;
            end
        end
    end

    // V_ACTIVE_IN is informational only; touch to keep Verilator quiet.
    logic _unused;
    assign _unused = &{1'b0, V_ACTIVE_IN[0]};

endmodule
