// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// AXI4-Stream 1-to-2 zero-latency broadcast fork.
//
// Accepts a single AXI4-Stream input and broadcasts it to two downstream
// consumers (A and B). Per-output acceptance tracking prevents duplicate
// transfers when only one consumer stalls (pattern from verilog-axis
// axis_broadcast).
//
// Data, tlast, and tuser are combinational pass-through to both outputs.
// s_axis_tready_o is asserted only when both consumers have accepted the
// current beat (or are both ready to accept). When tvalid is high and one
// consumer stalls, s_tready stays low and the upstream holds tdata (AXI
// rule), so the combinational pass-through always presents the correct data.

module axis_fork #(
    parameter int DATA_WIDTH = 24
) (
    input  logic                  clk_i,
    input  logic                  rst_n_i,

    // ---- AXI4-Stream input ------------------------------------------
    input  logic [DATA_WIDTH-1:0] s_axis_tdata_i,
    input  logic                  s_axis_tvalid_i,
    output logic                  s_axis_tready_o,
    input  logic                  s_axis_tlast_i,
    input  logic                  s_axis_tuser_i,

    // ---- AXI4-Stream output A ----------------------------------------
    output logic [DATA_WIDTH-1:0] m_a_axis_tdata_o,
    output logic                  m_a_axis_tvalid_o,
    input  logic                  m_a_axis_tready_i,
    output logic                  m_a_axis_tlast_o,
    output logic                  m_a_axis_tuser_o,

    // ---- AXI4-Stream output B ----------------------------------------
    output logic [DATA_WIDTH-1:0] m_b_axis_tdata_o,
    output logic                  m_b_axis_tvalid_o,
    input  logic                  m_b_axis_tready_i,
    output logic                  m_b_axis_tlast_o,
    output logic                  m_b_axis_tuser_o
);

    // ---- Per-output acceptance tracking ----
    logic a_accepted, b_accepted;
    logic both_done;

    assign both_done = (a_accepted || m_a_axis_tready_i)
                    && (b_accepted || m_b_axis_tready_i);

    assign s_axis_tready_o = both_done;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            a_accepted <= 1'b0;
            b_accepted <= 1'b0;
        end else if (s_axis_tvalid_i && both_done) begin
            a_accepted <= 1'b0;
            b_accepted <= 1'b0;
        end else begin
            if (m_a_axis_tvalid_o && m_a_axis_tready_i)
                a_accepted <= 1'b1;
            if (m_b_axis_tvalid_o && m_b_axis_tready_i)
                b_accepted <= 1'b1;
        end
    end

    // ---- Combinational data pass-through ----
    assign m_a_axis_tdata_o  = s_axis_tdata_i;
    assign m_a_axis_tlast_o  = s_axis_tlast_i;
    assign m_a_axis_tuser_o  = s_axis_tuser_i;
    assign m_a_axis_tvalid_o = s_axis_tvalid_i && !a_accepted;

    assign m_b_axis_tdata_o  = s_axis_tdata_i;
    assign m_b_axis_tlast_o  = s_axis_tlast_i;
    assign m_b_axis_tuser_o  = s_axis_tuser_i;
    assign m_b_axis_tvalid_o = s_axis_tvalid_i && !b_accepted;

endmodule
