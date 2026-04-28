// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_scale2x -- 2x spatial upscaler on a 24-bit RGB AXIS.
//
// Compile-time SCALE_FILTER selects nearest-neighbour ("nn") or bilinear
// ("bilinear"). Single line buffer, FSM-driven beat formatter; all
// arithmetic is shift-and-add (no DSPs). Latency: 1 source line.
// Long-term throughput: 4 output beats per input beat (back-pressures
// the upstream to 1/4 the output beat rate).
//
// Edge handling: top-edge row replicate; right-edge pixel replicate.
// H_ACTIVE_IN must be even; the design assumes V_ACTIVE_IN >= 1.
//
// NN datapath (this task):
//   FSM emits two output rows for every input row, in raster order:
//     PHASE_1 (top): for each input pixel at col c, write line_buf[c]
//       and emit two output beats (top[2c], top[2c+1]) = (cur, cur).
//       The input's tlast marks the last source pixel of the row.
//     PHASE_2 (bot): no input accepted; replay line_buf for c=0..last_col,
//       emitting (bot[2c], bot[2c+1]) = (line_buf[c], line_buf[c]).
//   The first source row (after SOF) replays as both output row 0 and
//   output row 1 (NN top-edge replicate).
//   H_ACTIVE_IN sets the line-buffer depth (max supported row width); the
//   actual row width is determined dynamically from the input's tlast.

module axis_scale2x #(
    parameter int    H_ACTIVE_IN  = sparevideo_pkg::H_ACTIVE,
    parameter int    V_ACTIVE_IN  = sparevideo_pkg::V_ACTIVE,    // informational
    parameter string SCALE_FILTER = "bilinear"                   // "nn" | "bilinear"
) (
    input  logic clk_i,
    input  logic rst_n_i,
    axis_if.rx   s_axis,                                          // DATA_W=24, USER_W=1
    axis_if.tx   m_axis                                           // DATA_W=24, USER_W=1
);

    generate
        if (SCALE_FILTER == "nn") begin : g_nn

            // ---- Counter widths ----
            localparam int COL_W = $clog2(H_ACTIVE_IN + 1);

            // ---- FSM ----
            // S_RX     : ready to accept the next input pixel for the top row.
            // S_TOP1/2 : emit the two output beats of the top row pair for the
            //            just-accepted input pixel (cur_pix_q).
            // S_BOT1/2 : after the top row finishes (signalled by input
            //            tlast), replay line_buf to emit the bottom row of the
            //            pair (NN: identical to top).
            typedef enum logic [2:0] {
                S_RX, S_TOP1, S_TOP2, S_BOT1, S_BOT2
            } state_e;
            state_e state_q;

            logic [COL_W-1:0] col_q;          // input col in S_RX/TOP*; output pair col in S_BOT*
            logic [COL_W-1:0] last_col_q;     // captured input col on tlast (= row width - 1)
            logic [23:0]      cur_pix_q;      // last accepted input pixel
            logic             cur_is_last_q;  // last accepted pixel was tlast (end of input row)
            logic             sof_pending_q;  // latched on SOF input; cleared on first emitted beat

            // ---- Line buffer (one source row) ----
            logic [23:0] line_buf [H_ACTIVE_IN];

            // ---- Combinational handshake / output formatting ----
            logic        rx_accept;
            logic [23:0] tx_data;
            logic        tx_valid;
            logic        tx_last;
            logic        tx_user;

            assign rx_accept = (state_q == S_RX) && s_axis.tvalid;

            always_comb begin
                tx_data  = '0;
                tx_valid = 1'b0;
                tx_last  = 1'b0;
                tx_user  = 1'b0;
                unique case (state_q)
                    S_RX: begin
                        // No output during S_RX (registered approach: pixel is
                        // captured first, then emitted across S_TOP1/S_TOP2).
                        tx_valid = 1'b0;
                    end
                    S_TOP1: begin
                        tx_data  = cur_pix_q;
                        tx_valid = 1'b1;
                        tx_user  = sof_pending_q && (col_q == '0);
                        tx_last  = 1'b0;
                    end
                    S_TOP2: begin
                        tx_data  = cur_pix_q;
                        tx_valid = 1'b1;
                        // Last beat of the top output row when this was the
                        // last input pixel of the source row.
                        tx_last  = cur_is_last_q;
                    end
                    S_BOT1: begin
                        tx_data  = line_buf[col_q];
                        tx_valid = 1'b1;
                    end
                    S_BOT2: begin
                        tx_data  = line_buf[col_q];
                        tx_valid = 1'b1;
                        tx_last  = (col_q == last_col_q);
                    end
                    default: begin
                        tx_valid = 1'b0;
                    end
                endcase
            end

            // ---- AXIS port drives ----
            assign s_axis.tready = (state_q == S_RX);
            assign m_axis.tdata  = tx_data;
            assign m_axis.tvalid = tx_valid;
            assign m_axis.tlast  = tx_last;
            assign m_axis.tuser  = tx_user;

            // ---- Sequential ----
            always_ff @(posedge clk_i) begin
                if (!rst_n_i) begin
                    state_q       <= S_RX;
                    col_q         <= '0;
                    last_col_q    <= '0;
                    cur_pix_q     <= '0;
                    cur_is_last_q <= 1'b0;
                    sof_pending_q <= 1'b0;
                end else begin
                    unique case (state_q)
                        S_RX: begin
                            if (rx_accept) begin
                                cur_pix_q       <= s_axis.tdata;
                                cur_is_last_q   <= s_axis.tlast;
                                line_buf[col_q] <= s_axis.tdata;
                                if (s_axis.tuser)
                                    sof_pending_q <= 1'b1;
                                state_q <= S_TOP1;
                            end
                        end
                        S_TOP1: begin
                            if (m_axis.tready) begin
                                // Clear sof_pending after first beat is emitted.
                                if (sof_pending_q && (col_q == '0))
                                    sof_pending_q <= 1'b0;
                                state_q <= S_TOP2;
                            end
                        end
                        S_TOP2: begin
                            if (m_axis.tready) begin
                                if (cur_is_last_q) begin
                                    // Source row complete; capture row width
                                    // and replay buffer as bottom row.
                                    last_col_q <= col_q;
                                    state_q    <= S_BOT1;
                                    col_q      <= '0;
                                end else begin
                                    col_q   <= col_q + (COL_W)'(1);
                                    state_q <= S_RX;
                                end
                            end
                        end
                        S_BOT1: begin
                            if (m_axis.tready)
                                state_q <= S_BOT2;
                        end
                        S_BOT2: begin
                            if (m_axis.tready) begin
                                if (col_q == last_col_q) begin
                                    // Bottom row complete; ready for next input row.
                                    state_q <= S_RX;
                                    col_q   <= '0;
                                end else begin
                                    col_q   <= col_q + (COL_W)'(1);
                                    state_q <= S_BOT1;
                                end
                            end
                        end
                        default: state_q <= S_RX;
                    endcase
                end
            end

            // V_ACTIVE_IN is informational only; touch to keep Verilator quiet.
            logic _unused_nn;
            assign _unused_nn = &{1'b0, V_ACTIVE_IN[0]};

        end else if (SCALE_FILTER == "bilinear") begin : g_bilinear

            // ---- Counter widths ----
            localparam int COL_W      = $clog2(H_ACTIVE_IN + 1);
            localparam int OUT_COL_W  = $clog2(2*H_ACTIVE_IN + 1);

            // ---- FSM ----
            // S_RX_FIRST : accept the first input pixel of a new source row
            //              (no emit yet — need a peeked-ahead pixel for top_odd).
            // S_RX_NEXT  : accept the next input pixel; latch as next_q and
            //              proceed to emit top beats for the *previous* pixel.
            // S_TOP1/2   : emit two top-row output beats for cur_q (using next_q
            //              as the right neighbour for top_odd). Right-edge
            //              replicate is encoded by next_q == cur_q on the final
            //              pair.
            // S_BOT1/2   : after the source row's top beats are emitted, replay
            //              the bot row by reading both the current row buffer
            //              and the previous row buffer (top-edge replicate on
            //              the first row of a frame is provided by writing the
            //              first row into both buffers).
            typedef enum logic [2:0] {
                S_RX_FIRST, S_RX_NEXT, S_TOP1, S_TOP2, S_BOT1, S_BOT2
            } state_e;
            state_e state_q;

            logic [COL_W-1:0]     in_col_q;        // input col where next accept lands
            logic [COL_W-1:0]     pair_col_q;      // src col of cur_q (the pixel being emitted)
            logic [COL_W-1:0]     last_col_q;      // captured src col on tlast (= row width - 1)
            logic [OUT_COL_W-1:0] out_col_q;       // 0..2W-1 during PHASE_2 (bot row)
            logic [23:0]          cur_q;           // current source pixel being emitted
            logic [23:0]          next_q;          // peeked-ahead next source pixel
            logic                 cur_is_last_q;   // cur_q was the source row's last pixel
            logic                 next_is_last_q;  // next_q was the source row's last pixel
            logic                 sof_pending_q;   // latched on SOF input
            logic                 first_row_q;     // 1 while emitting the first row of a frame
            logic                 cur_sel_q;       // 0 or 1: which buffer holds "cur" row

            // ---- Two ping-pong line buffers ----
            // When cur_sel_q==0: buf0 is "cur", buf1 is "prev". And vice versa.
            logic [23:0] buf0 [H_ACTIVE_IN];
            logic [23:0] buf1 [H_ACTIVE_IN];

            // ---- Per-channel arithmetic helpers ----
            // 2-tap round-half-up average per channel.
            // Bit [0] of each per-channel 9-bit sum is intentionally
            // discarded by the >>1 (avg2 takes bits [8:1]). Suppress the
            // UNUSEDSIGNAL warning Verilator raises for that bit.
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

            // ---- PHASE_2 read indexing ----
            // Output column out_col_q in [0, 2W). Source columns:
            //   src_c      = out_col_q >> 1
            //   src_c_next = min(src_c+1, last_col_q)        (right-edge replicate)
            // The "cur" row is read from {buf0|buf1} per cur_sel_q; the "prev"
            // row is read from the opposite buffer.
            logic [COL_W-1:0] src_c, src_c_next;
            logic [23:0]      cur_buf_c, cur_buf_cn, prev_buf_c, prev_buf_cn;
            logic [23:0]      cur_top_even, cur_top_odd;
            logic [23:0]      prev_top_even, prev_top_odd;
            logic [23:0]      bot_even, bot_odd;

            always_comb begin
                src_c      = out_col_q[OUT_COL_W-1:1];
                src_c_next = (src_c == last_col_q) ? src_c
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

                // Sequential 2-tap formulation (matches py/models/ops/scale2x.py):
                //   bot_even = avg2(cur_top_even, prev_top_even)
                //   bot_odd  = avg2(cur_top_odd,  prev_top_odd)
                // where the "top" row is the horizontally-expanded source row.
                cur_top_even  = cur_buf_c;
                cur_top_odd   = avg2(cur_buf_c, cur_buf_cn);
                prev_top_even = prev_buf_c;
                prev_top_odd  = avg2(prev_buf_c, prev_buf_cn);
                bot_even      = avg2(cur_top_even, prev_top_even);
                bot_odd       = avg2(cur_top_odd,  prev_top_odd);
            end

            // ---- Combinational handshake / output formatting ----
            logic        rx_accept;
            logic [23:0] tx_data;
            logic        tx_valid;
            logic        tx_last;
            logic        tx_user;

            assign rx_accept = ((state_q == S_RX_FIRST) || (state_q == S_RX_NEXT))
                               && s_axis.tvalid;

            // ---- SOF-aware combinational overrides ----
            // The always_ff override at the bottom re-arms first_row_q and
            // resets cur_sel_q on the SOF cycle, but those updates only take
            // effect on the *next* cycle. The case-block writing to buf0/buf1
            // runs in the SAME cycle and must therefore see the post-SOF
            // values, not the stale registered ones. Without this override,
            // the first pixel of frame N>=1 lands in only one buffer (chosen
            // by the stale cur_sel_q), and the top-edge replicate write to
            // both buffers is skipped (because first_row_q is still 0 from
            // the previous frame). Symptoms: 2 mismatched pixels on output
            // row 1 (cols 0,1) of every non-zero frame whenever the input
            // pixel value differs across frame boundaries.
            logic is_sof_pixel;
            logic effective_first_row;
            logic effective_cur_sel;
            assign is_sof_pixel        = (state_q == S_RX_FIRST) && rx_accept
                                                                && s_axis.tuser;
            assign effective_first_row = first_row_q || is_sof_pixel;
            assign effective_cur_sel   = is_sof_pixel ? 1'b0 : cur_sel_q;

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
                        tx_last  = 1'b0;
                    end
                    S_TOP2: begin
                        // Right-edge replicate: when cur_is_last_q==1 the FSM
                        // ensures next_q == cur_q, so avg2 returns cur_q.
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
                        tx_last  = (out_col_q == OUT_COL_W'(2*H_ACTIVE_IN - 1))
                                   || (out_col_q == OUT_COL_W'({1'b0, last_col_q, 1'b1}));
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

            // ---- Sequential ----
            always_ff @(posedge clk_i) begin
                if (!rst_n_i) begin
                    state_q        <= S_RX_FIRST;
                    in_col_q       <= '0;
                    pair_col_q     <= '0;
                    last_col_q     <= '0;
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
                            // First pixel of a new source row.
                            if (rx_accept) begin
                                cur_q         <= s_axis.tdata;
                                cur_is_last_q <= s_axis.tlast;
                                pair_col_q    <= '0;
                                // Write to the "cur" buffer (and to "prev" too,
                                // for the first row of a frame: top-edge
                                // replicate). Use SOF-aware effective signals
                                // because the SOF override at the bottom of
                                // this always_ff doesn't take effect until
                                // the next cycle.
                                if (effective_cur_sel == 1'b0) begin
                                    buf0[in_col_q] <= s_axis.tdata;
                                    if (effective_first_row)
                                        buf1[in_col_q] <= s_axis.tdata;
                                end else begin
                                    buf1[in_col_q] <= s_axis.tdata;
                                    if (effective_first_row)
                                        buf0[in_col_q] <= s_axis.tdata;
                                end
                                if (s_axis.tuser)
                                    sof_pending_q <= 1'b1;
                                if (s_axis.tlast) begin
                                    // Single-pixel row (degenerate). Treat next
                                    // as cur for right-edge replicate, emit one
                                    // pair, then go to bot.
                                    next_q         <= s_axis.tdata;
                                    next_is_last_q <= 1'b1;
                                    last_col_q     <= in_col_q;
                                    state_q        <= S_TOP1;
                                end else begin
                                    in_col_q <= in_col_q + (COL_W)'(1);
                                    state_q  <= S_RX_NEXT;
                                end
                            end
                        end
                        S_RX_NEXT: begin
                            if (rx_accept) begin
                                next_q         <= s_axis.tdata;
                                next_is_last_q <= s_axis.tlast;
                                // S_RX_NEXT cannot see SOF (is_sof_pixel is
                                // gated on S_RX_FIRST), so effective_*
                                // equals the registered values here. Using
                                // them keeps the code uniform with S_RX_FIRST.
                                if (effective_cur_sel == 1'b0) begin
                                    buf0[in_col_q] <= s_axis.tdata;
                                    if (effective_first_row)
                                        buf1[in_col_q] <= s_axis.tdata;
                                end else begin
                                    buf1[in_col_q] <= s_axis.tdata;
                                    if (effective_first_row)
                                        buf0[in_col_q] <= s_axis.tdata;
                                end
                                if (s_axis.tlast)
                                    last_col_q <= in_col_q;
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
                                    // Just emitted the right-edge pair.
                                    // Begin bot row.
                                    out_col_q <= '0;
                                    in_col_q  <= '0;
                                    state_q   <= S_BOT1;
                                end else begin
                                    // Shift the peek window: cur ← next.
                                    cur_q         <= next_q;
                                    cur_is_last_q <= next_is_last_q;
                                    pair_col_q    <= pair_col_q + (COL_W)'(1);
                                    if (next_is_last_q) begin
                                        // No more inputs in this row — replicate
                                        // next from cur (right-edge), emit one
                                        // more pair.
                                        next_q  <= next_q;
                                        state_q <= S_TOP1;
                                    end else begin
                                        state_q <= S_RX_NEXT;
                                    end
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
                                if (out_col_q == OUT_COL_W'({1'b0, last_col_q, 1'b1})) begin
                                    // Bot row complete. Flip ping-pong, ready
                                    // for next source row.
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

                    // SOF on a fresh frame re-arms the first-row flag.
                    if (rx_accept && s_axis.tuser) begin
                        first_row_q <= 1'b1;
                        // Reset the ping-pong on a new frame so top-edge
                        // replicate seeds both buffers from row 0.
                        cur_sel_q   <= 1'b0;
                    end
                end
            end

            // V_ACTIVE_IN is informational only; touch to keep Verilator quiet.
            logic _unused_bi;
            assign _unused_bi = &{1'b0, V_ACTIVE_IN[0]};

        end
    endgenerate

endmodule
