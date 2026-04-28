// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_scale2x -- 2x bilinear spatial upscaler on a 24-bit RGB AXIS.
//
// Each input pixel S[r,c] anchors a 2x2 output block at out coords
// (2r..2r+1, 2c..2c+1). Top output row uses (cur, avg2(cur,next));
// bot output row uses 2x2 averages of the current row and the previous
// source row held in a line buffer. All weights are 1/2 -- shift-and-add,
// no multipliers.
//
// FSM:
//   S_RX_FIRST : accept first source pixel of a new row.
//   S_RX_NEXT  : accept the peeked-ahead next pixel.
//   S_TOP1/2   : emit two top-row beats: cur, then avg2(cur, next).
//   S_BOT1/2   : after the source row's tlast, replay both buffers to
//                emit 2W bot-row beats.
//
// Edge handling:
//   * Top edge: row 0 is written into both line buffers, so its bot-row
//     replay reads prev == cur.
//   * Right edge: at the row's last pixel, next_q is held equal to cur_q
//     so avg2 returns cur_q; src_c_next clamps to W-1 during bot reads.
//
// Latency: 2 clk_dsp cycles from accepted SOF to first m_axis beat.
// Long-term throughput: per source row of W pixels, ~5W cycles produce
// 4W output beats. s_axis is back-pressured during the entire 2W-cycle
// bot-row replay following each source row.

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

    typedef enum logic [2:0] {
        S_RX_FIRST, S_RX_NEXT, S_TOP1, S_TOP2, S_BOT1, S_BOT2
    } state_e;
    state_e state_q;

    logic [COL_W-1:0]     in_col_q;        // src col where the next accept lands
    logic [COL_W-1:0]     pair_col_q;      // src col of cur_q (gates SOF tuser)
    logic [OUT_COL_W-1:0] out_col_q;       // 0..2W-1 during BOT phase
    logic [23:0]          cur_q;
    logic [23:0]          next_q;
    logic                 cur_is_last_q;
    logic                 next_is_last_q;
    logic                 sof_pending_q;
    logic                 first_row_q;     // 1 while emitting the first row of a frame
    logic                 cur_sel_q;       // ping-pong: which buffer is "cur"

    // ---- Two ping-pong line buffers ----
    logic [23:0] buf0 [H_ACTIVE_IN];
    logic [23:0] buf1 [H_ACTIVE_IN];

    // ---- Per-channel 2-tap round-half-up average. avg2(a, a) = a. ----
    // The bot-odd 4-tap is built from two avg2's of avg2's; the LSB rounding
    // matches py/models/ops/scale2x.py.
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

    // ---- SOF same-cycle override ----
    // first_row_q / cur_sel_q re-arm at the SOF tail of always_ff, but the
    // S_RX_FIRST buffer write runs in the SAME cycle and must see the
    // post-SOF values for the top-edge replicate to fire on every frame.
    logic rx_accept;
    logic is_sof_pixel;
    logic effective_first_row;
    logic effective_cur_sel;

    assign rx_accept           = ((state_q == S_RX_FIRST) || (state_q == S_RX_NEXT))
                                 && s_axis.tvalid;
    assign is_sof_pixel        = (state_q == S_RX_FIRST) && rx_accept && s_axis.tuser;
    assign effective_first_row = first_row_q || is_sof_pixel;
    assign effective_cur_sel   = is_sof_pixel ? 1'b0 : cur_sel_q;

    // ---- Line-buffer write helper ----
    // Always writes to "cur" buffer at col; on the first row of a frame,
    // also writes to "prev" buffer (top-edge replicate seed).
    task automatic write_lbufs(input logic [COL_W-1:0] col,
                               input logic [23:0]     data);
        if (effective_cur_sel == 1'b0) begin
            buf0[col] <= data;
            if (effective_first_row)
                buf1[col] <= data;
        end else begin
            buf1[col] <= data;
            if (effective_first_row)
                buf0[col] <= data;
        end
    endtask

    // ---- BOT-phase combinational read path ----
    //   src_c      = out_col_q >> 1
    //   src_c_next = min(src_c + 1, W - 1)        -- right-edge clamp
    logic [COL_W-1:0] src_c, src_c_next;
    logic [23:0]      cur_buf_c, cur_buf_cn, prev_buf_c, prev_buf_cn;
    logic [23:0]      cur_top_odd, prev_top_odd;
    logic [23:0]      bot_even, bot_odd;

    always_comb begin
        src_c      = out_col_q[OUT_COL_W-1:1];
        src_c_next = (src_c == COL_W'(H_ACTIVE_IN - 1)) ? src_c
                                                       : (COL_W'(src_c + (COL_W)'(1)));

        if (cur_sel_q == 1'b0) begin
            cur_buf_c   = buf0[src_c];
            cur_buf_cn  = buf0[src_c_next];
            prev_buf_c  = buf1[src_c];
            prev_buf_cn = buf1[src_c_next];
        end else begin
            cur_buf_c   = buf1[src_c];
            cur_buf_cn  = buf1[src_c_next];
            prev_buf_c  = buf0[src_c];
            prev_buf_cn = buf0[src_c_next];
        end

        cur_top_odd  = avg2(cur_buf_c,   cur_buf_cn);
        prev_top_odd = avg2(prev_buf_c,  prev_buf_cn);
        bot_even     = avg2(cur_buf_c,   prev_buf_c);
        bot_odd      = avg2(cur_top_odd, prev_top_odd);
    end

    // ---- Output beat formatter ----
    logic [23:0] tx_data;
    logic        tx_valid;
    logic        tx_last;
    logic        tx_user;

    always_comb begin
        tx_data  = '0;
        tx_valid = 1'b0;
        tx_last  = 1'b0;
        tx_user  = 1'b0;
        unique case (state_q)
            S_RX_FIRST, S_RX_NEXT: begin
                tx_valid = 1'b0;
            end
            S_TOP1: begin
                tx_data  = cur_q;
                tx_valid = 1'b1;
                tx_user  = sof_pending_q && (pair_col_q == '0);
            end
            S_TOP2: begin
                tx_data  = avg2(cur_q, next_q);
                tx_valid = 1'b1;
                tx_last  = cur_is_last_q;
            end
            S_BOT1: begin
                tx_data  = bot_even;
                tx_valid = 1'b1;
            end
            S_BOT2: begin
                tx_data  = bot_odd;
                tx_valid = 1'b1;
                tx_last  = (out_col_q == OUT_COL_W'(2*H_ACTIVE_IN - 1));
            end
            default: begin
                tx_valid = 1'b0;
            end
        endcase
    end

    // ---- AXIS port drives ----
    assign s_axis.tready = (state_q == S_RX_FIRST) || (state_q == S_RX_NEXT);
    assign m_axis.tdata  = tx_data;
    assign m_axis.tvalid = tx_valid;
    assign m_axis.tlast  = tx_last;
    assign m_axis.tuser  = tx_user;

    // ---- FSM ----
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_q        <= S_RX_FIRST;
            in_col_q       <= '0;
            pair_col_q     <= '0;
            out_col_q      <= '0;
            cur_q          <= '0;
            next_q         <= '0;
            cur_is_last_q  <= 1'b0;
            next_is_last_q <= 1'b0;
            sof_pending_q  <= 1'b0;
            first_row_q    <= 1'b1;
            cur_sel_q      <= 1'b0;
        end else begin
            unique case (state_q)
                S_RX_FIRST: begin
                    if (rx_accept) begin
                        cur_q         <= s_axis.tdata;
                        cur_is_last_q <= s_axis.tlast;
                        pair_col_q    <= '0;
                        write_lbufs(in_col_q, s_axis.tdata);
                        if (s_axis.tuser)
                            sof_pending_q <= 1'b1;
                        in_col_q <= in_col_q + (COL_W)'(1);
                        state_q  <= S_RX_NEXT;
                    end
                end
                S_RX_NEXT: begin
                    if (rx_accept) begin
                        next_q         <= s_axis.tdata;
                        next_is_last_q <= s_axis.tlast;
                        write_lbufs(in_col_q, s_axis.tdata);
                        in_col_q <= in_col_q + (COL_W)'(1);
                        state_q  <= S_TOP1;
                    end
                end
                S_TOP1: begin
                    if (m_axis.tready) begin
                        if (sof_pending_q && (pair_col_q == '0))
                            sof_pending_q <= 1'b0;
                        state_q <= S_TOP2;
                    end
                end
                S_TOP2: begin
                    if (m_axis.tready) begin
                        if (cur_is_last_q) begin
                            // End of source row -> bot-row replay.
                            out_col_q <= '0;
                            in_col_q  <= '0;
                            state_q   <= S_BOT1;
                        end else begin
                            // Shift the peek window: cur <- next.
                            cur_q         <= next_q;
                            cur_is_last_q <= next_is_last_q;
                            pair_col_q    <= pair_col_q + (COL_W)'(1);
                            // Right-edge replicate: when next was the row's
                            // last pixel, hold next == cur for one more pair
                            // (skip RX_NEXT) so avg2 returns cur.
                            state_q <= next_is_last_q ? S_TOP1 : S_RX_NEXT;
                        end
                    end
                end
                S_BOT1: begin
                    if (m_axis.tready) begin
                        out_col_q <= out_col_q + (OUT_COL_W)'(1);
                        state_q   <= S_BOT2;
                    end
                end
                S_BOT2: begin
                    if (m_axis.tready) begin
                        if (out_col_q == OUT_COL_W'(2*H_ACTIVE_IN - 1)) begin
                            state_q     <= S_RX_FIRST;
                            out_col_q   <= '0;
                            pair_col_q  <= '0;
                            cur_sel_q   <= ~cur_sel_q;
                            first_row_q <= 1'b0;
                        end else begin
                            out_col_q <= out_col_q + (OUT_COL_W)'(1);
                            state_q   <= S_BOT1;
                        end
                    end
                end
                default: state_q <= S_RX_FIRST;
            endcase

            // SOF re-arms top-edge replicate and ping-pong on every frame.
            if (rx_accept && s_axis.tuser) begin
                first_row_q <= 1'b1;
                cur_sel_q   <= 1'b0;
            end
        end
    end

    // V_ACTIVE_IN is informational only; touch to keep Verilator quiet.
    logic _unused;
    assign _unused = &{1'b0, V_ACTIVE_IN[0]};

endmodule
