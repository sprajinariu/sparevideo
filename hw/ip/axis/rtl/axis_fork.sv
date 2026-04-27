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
// s_axis.tready is asserted only when both consumers have accepted the
// current beat (or are both ready to accept). When tvalid is high and one
// consumer stalls, s_axis.tready stays low and the upstream holds tdata (AXI
// rule), so the combinational pass-through always presents the correct data.

module axis_fork #(
    parameter int DATA_WIDTH = 24,
    parameter int USER_WIDTH = 1
) (
    input  logic clk_i,
    input  logic rst_n_i,

    // ---- AXI4-Stream input ------------------------------------------
    axis_if.rx s_axis,

    // ---- AXI4-Stream output A ----------------------------------------
    axis_if.tx m_a_axis,

    // ---- AXI4-Stream output B ----------------------------------------
    axis_if.tx m_b_axis
);

    // ---- Per-output acceptance tracking ----
    logic a_accepted, b_accepted;
    logic both_done;

    assign both_done = (a_accepted || m_a_axis.tready)
                    && (b_accepted || m_b_axis.tready);

    assign s_axis.tready = both_done;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            a_accepted <= 1'b0;
            b_accepted <= 1'b0;
        end else if (s_axis.tvalid && both_done) begin
            a_accepted <= 1'b0;
            b_accepted <= 1'b0;
        end else begin
            if (m_a_axis.tvalid && m_a_axis.tready)
                a_accepted <= 1'b1;
            if (m_b_axis.tvalid && m_b_axis.tready)
                b_accepted <= 1'b1;
        end
    end

    // ---- Combinational data pass-through ----
    assign m_a_axis.tdata  = s_axis.tdata;
    assign m_a_axis.tlast  = s_axis.tlast;
    assign m_a_axis.tuser  = s_axis.tuser;
    assign m_a_axis.tvalid = s_axis.tvalid && !a_accepted;

    assign m_b_axis.tdata  = s_axis.tdata;
    assign m_b_axis.tlast  = s_axis.tlast;
    assign m_b_axis.tuser  = s_axis.tuser;
    assign m_b_axis.tvalid = s_axis.tvalid && !b_accepted;

endmodule
