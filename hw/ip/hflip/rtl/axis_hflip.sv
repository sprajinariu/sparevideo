// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_hflip -- horizontal mirror stage (selfie-cam) on a 24-bit RGB AXIS.
//
// FSM-driven RECV/XMIT alternation over a single H_ACTIVE x 24-bit line
// buffer. Receive phase fills line_buf[col]; transmit phase reads
// line_buf[H_ACTIVE-1-col]. SOF is latched at write-phase start and
// re-emitted on the first XMIT pixel; EOL emitted on the last XMIT pixel
// of every line. No inter-frame state.
//
// Latency: ~1 line (H_ACTIVE proc_clk cycles).
// Throughput: 1 pixel/cycle long-term; bursty (RECV/XMIT alternation).
//
// Blanking / FIFO sizing requirements:
//   The upstream CDC FIFO must absorb one line of write-clock pixels
//   during XMIT. For pix_clk = 25 MHz, dsp_clk = 100 MHz, H_ACTIVE = 320,
//   that's <= 80 entries. IN_FIFO_DEPTH = 128 in the top is safe.
//
// enable_i: when 1, the FSM-driven mirror path drives the output. When 0,
// s_axis_* is forwarded combinatorially to m_axis_* with zero latency and
// the line buffer is idle. enable_i must be held frame-stable.

module axis_hflip #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240    // informational only
) (
    // --- Clocks and resets ---
    input  logic clk_i,
    input  logic rst_n_i,

    // --- Sideband ---
    input  logic enable_i,

    // --- AXI4-Stream input (24-bit RGB) ---
    input  logic [23:0] s_axis_tdata_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,
    input  logic        s_axis_tuser_i,

    // --- AXI4-Stream output (24-bit RGB) ---
    output logic [23:0] m_axis_tdata_o,
    output logic        m_axis_tvalid_o,
    input  logic        m_axis_tready_i,
    output logic        m_axis_tlast_o,
    output logic        m_axis_tuser_o
);

    // ---- Counter widths ----
    localparam int COL_W = $clog2(H_ACTIVE + 1);

    // ---- FSM ----
    typedef enum logic [0:0] { S_RECV, S_XMIT } state_e;
    state_e state_q;

    logic [COL_W-1:0] wr_col;          // 0..H_ACTIVE-1 during RECV
    logic [COL_W-1:0] rd_col;          // 0..H_ACTIVE-1 during XMIT
    logic             sof_pending_q;   // latched SOF, applied on first XMIT pixel

    // ---- Line buffer ----
    logic [23:0] line_buf [H_ACTIVE];

    // ---- RECV-phase combinational ----
    logic recv_ready;
    logic recv_accept;
    assign recv_ready  = (state_q == S_RECV);
    assign recv_accept = recv_ready && s_axis_tvalid_i && enable_i;

    // ---- XMIT-phase combinational ----
    logic        xmit_active;
    logic [23:0] xmit_data;
    logic        xmit_sof;
    logic        xmit_eol;
    logic        xmit_accept;
    assign xmit_active = (state_q == S_XMIT);
    assign xmit_data   = line_buf[(COL_W)'(H_ACTIVE - 1) - rd_col];
    assign xmit_sof    = sof_pending_q && (rd_col == '0);
    assign xmit_eol    = (rd_col == (COL_W)'(H_ACTIVE - 1));
    assign xmit_accept = xmit_active && m_axis_tready_i;

    // ---- Sequential: state, counters, line buffer write ----
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_q       <= S_RECV;
            wr_col        <= '0;
            rd_col        <= '0;
            sof_pending_q <= 1'b0;
        end else begin
            unique case (state_q)
                S_RECV: begin
                    if (recv_accept) begin
                        // SOF realigns wr_col to 0 (and clears any stale state)
                        if (s_axis_tuser_i)
                            wr_col <= (COL_W)'(1);
                        else
                            wr_col <= wr_col + (COL_W)'(1);
                        line_buf[s_axis_tuser_i ? '0 : wr_col] <= s_axis_tdata_i;
                        // Latch sof for the upcoming XMIT
                        if (s_axis_tuser_i)
                            sof_pending_q <= 1'b1;
                        // EOL terminates the receive phase
                        if (s_axis_tlast_i) begin
                            state_q <= S_XMIT;
                            rd_col  <= '0;
                            wr_col  <= '0;
                        end
                    end
                end
                S_XMIT: begin
                    if (xmit_accept) begin
                        if (xmit_eol) begin
                            state_q       <= S_RECV;
                            rd_col        <= '0;
                            sof_pending_q <= 1'b0;
                        end else begin
                            rd_col <= rd_col + (COL_W)'(1);
                        end
                    end
                end
                default: state_q <= S_RECV;
            endcase
        end
    end

    // ---- enable_i bypass mux ----
    always_comb begin
        if (enable_i) begin
            s_axis_tready_o = recv_ready;
            m_axis_tdata_o  = xmit_data;
            m_axis_tvalid_o = xmit_active;
            m_axis_tlast_o  = xmit_active && xmit_eol;
            m_axis_tuser_o  = xmit_active && xmit_sof;
        end else begin
            s_axis_tready_o = m_axis_tready_i;
            m_axis_tdata_o  = s_axis_tdata_i;
            m_axis_tvalid_o = s_axis_tvalid_i;
            m_axis_tlast_o  = s_axis_tlast_i;
            m_axis_tuser_o  = s_axis_tuser_i;
        end
    end

    // V_ACTIVE is informational only; touch to keep Verilator quiet.
    logic _unused;
    assign _unused = (V_ACTIVE != 0);

endmodule
