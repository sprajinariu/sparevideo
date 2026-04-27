// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// 3x3 morphological erosion on a 1-bit mask stream, implemented as a thin
// wrapper over axis_window3x3 (DATA_WIDTH=1, EDGE_REPLICATE).
//
// Reduction: output = AND of all 9 taps of the 3x3 window (foreground only
// when the pixel and every neighbour are 1). Multiplications and adds are
// none -- pure gate tree.
//
// Latency: H_ACTIVE + 3 cycles from first s_axis.tvalid to first
// m_axis.tvalid (window: H_ACTIVE + 2; wrapper's output register adds 1).
// Throughput: 1 pixel/cycle after fill when !stall.
//
// Blanking: defers to axis_window3x3 (min H-blank 1, min V-blank
// H_ACTIVE + 1). Phantom-cycle back-pressure is surfaced via busy_o.
//
// enable_i: when 1, the window-based erode path drives the output. When 0,
// s_axis is forwarded combinatorially to m_axis with zero latency and
// the line buffers are ignored. enable_i must be held frame-stable.

module axis_morph3x3_erode #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240
) (
    // --- Clocks and resets ---
    input  logic clk_i,
    input  logic rst_n_i,

    // --- Sideband ---
    input  logic enable_i,

    // --- AXI4-Stream input (1-bit mask) ---
    axis_if.rx s_axis,

    // --- AXI4-Stream output (1-bit mask) ---
    axis_if.tx m_axis,

    // --- Status ---
    output logic busy_o
);

    // ---- Counter widths (must match axis_window3x3 internal widths) ----
    localparam int COL_W = $clog2(H_ACTIVE + 1);
    localparam int ROW_W = $clog2(V_ACTIVE + 1);

    localparam logic [COL_W-1:0] LAST_COL = (COL_W)'(H_ACTIVE - 1);
    localparam logic [ROW_W-1:0] LAST_ROW = (ROW_W)'(V_ACTIVE - 1);

    // ---- Window primitive signals ----
    logic       window [9];
    logic       window_valid;
    logic       win_busy;

    logic       stall;
    assign      stall = !m_axis.tready;

    axis_window3x3 #(
        .DATA_WIDTH  (1),
        .H_ACTIVE    (H_ACTIVE),
        .V_ACTIVE    (V_ACTIVE),
        .EDGE_POLICY (0)  // EDGE_REPLICATE
    ) u_window (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),
        .valid_i        (s_axis.tvalid),
        .sof_i          (s_axis.tuser),
        .stall_i        (stall),
        .din_i          (s_axis.tdata),
        .window_o       (window),
        .window_valid_o (window_valid),
        .busy_o         (win_busy)
    );

    // ---- 9-way AND reduction (combinational erode) ----
    logic erode_bit;
    always_comb begin
        erode_bit = window[0] & window[1] & window[2]
                  & window[3] & window[4] & window[5]
                  & window[6] & window[7] & window[8];
    end

    // ---- Output pixel counter: regenerates tlast/tuser at window latency ----
    logic [COL_W-1:0] out_col;
    logic [ROW_W-1:0] out_row;
    logic             out_sof;
    logic             out_eol;

    assign out_sof = (out_col == '0) && (out_row == '0);
    assign out_eol = (out_col == LAST_COL);

    // Output counter advances on each window_valid. axis_window3x3 guarantees
    // exactly H_ACTIVE*V_ACTIVE window_valid pulses per frame, so the counter
    // wraps cleanly at frame boundaries without needing a resync on an
    // output-side SOF. Do not relax this invariant without introducing such a
    // resync.
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            out_col <= '0;
            out_row <= '0;
        end else if (!stall && window_valid) begin
            if (out_col == LAST_COL) begin
                out_col <= '0;
                if (out_row == LAST_ROW)
                    out_row <= '0;
                else
                    out_row <= out_row + (ROW_W)'(1);
            end else begin
                out_col <= out_col + (COL_W)'(1);
            end
        end
    end

    // ---- Output register (window path) ----
    logic       win_tdata_q;
    logic       win_tvalid_q;
    logic       win_tlast_q;
    logic       win_tuser_q;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            win_tdata_q  <= 1'b0;
            win_tvalid_q <= 1'b0;
            win_tlast_q  <= 1'b0;
            win_tuser_q  <= 1'b0;
        end else if (!stall) begin
            win_tdata_q  <= erode_bit;
            win_tvalid_q <= window_valid;
            win_tlast_q  <= window_valid && out_eol;
            win_tuser_q  <= window_valid && out_sof;
        end
    end

    // ---- enable_i bypass mux ----
    always_comb begin
        if (enable_i) begin
            m_axis.tdata  = win_tdata_q;
            m_axis.tvalid = win_tvalid_q;
            m_axis.tlast  = win_tlast_q;
            m_axis.tuser  = win_tuser_q;
            s_axis.tready = !stall && !win_busy;
            busy_o        = win_busy;
        end else begin
            m_axis.tdata  = s_axis.tdata;
            m_axis.tvalid = s_axis.tvalid;
            m_axis.tlast  = s_axis.tlast;
            m_axis.tuser  = s_axis.tuser;
            s_axis.tready = m_axis.tready;
            busy_o        = 1'b0;
        end
    end

endmodule
