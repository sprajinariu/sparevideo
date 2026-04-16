// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// AXI4-Stream 1-to-2 fork with sideband pipeline.
//
// Accepts a single AXI4-Stream input and broadcasts it to two downstream
// consumers (A and B). Per-output acceptance tracking prevents duplicate
// transfers when only one consumer stalls (pattern from verilog-axis
// axis_broadcast).
//
// The module includes PIPE_STAGES registered pipeline stages for tdata and
// sideband signals (tlast, tuser). Pipeline registers are stall-gated: they
// hold their value when the output is valid but not all consumers have
// accepted.
//
// The two outputs share sideband signals (pipe_tdata_o, pipe_tlast_o,
// pipe_tuser_o) from the pipeline output stage. Each output gets its own
// acceptance-gated tvalid (m_a_tvalid_o, m_b_tvalid_o). The parent module
// is responsible for wiring per-output tdata if the outputs carry different
// data (e.g., passthrough RGB vs. processed mask).
//
// Exported control signals (pipe_stall_o, beat_done_o) allow the parent to
// gate external processing logic (e.g., colour-space converters, memory
// read addresses) in sync with the pipeline.

module axis_fork_pipe #(
    parameter int DATA_WIDTH  = 24,
    parameter int PIPE_STAGES = 1
) (
    input  logic                  clk_i,
    input  logic                  rst_n_i,

    // ---- AXI4-Stream input ------------------------------------------
    input  logic [DATA_WIDTH-1:0] s_axis_tdata_i,
    input  logic                  s_axis_tvalid_i,
    output logic                  s_axis_tready_o,
    input  logic                  s_axis_tlast_i,
    input  logic                  s_axis_tuser_i,

    // ---- Downstream ready (one per fork leg) ------------------------
    input  logic                  m_a_tready_i,
    input  logic                  m_b_tready_i,

    // ---- Pipeline output stage (shared sidebands) -------------------
    output logic [DATA_WIDTH-1:0] pipe_tdata_o,
    output logic                  pipe_tlast_o,
    output logic                  pipe_tuser_o,

    // ---- Per-output acceptance-gated tvalid --------------------------
    output logic                  m_a_tvalid_o,
    output logic                  m_b_tvalid_o,

    // ---- Pipeline control -------------------------------------------
    output logic                  pipe_stall_o,   // pipeline stalled
    output logic                  beat_done_o     // valid beat consumed by both outputs
);

    // ---- Fork acceptance tracking ----
    logic a_accepted, b_accepted;
    logic both_done;

    assign both_done = (a_accepted || m_a_tready_i)
                    && (b_accepted || m_b_tready_i);

    // Pipeline valid at output stage
    logic pipe_valid;

    assign s_axis_tready_o = !pipe_valid || both_done;
    assign pipe_stall_o    = pipe_valid && !both_done;
    assign beat_done_o     = pipe_valid && both_done;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            a_accepted <= 1'b0;
            b_accepted <= 1'b0;
        end else if (beat_done_o) begin
            a_accepted <= 1'b0;
            b_accepted <= 1'b0;
        end else begin
            if (m_a_tvalid_o && m_a_tready_i)
                a_accepted <= 1'b1;
            if (m_b_tvalid_o && m_b_tready_i)
                b_accepted <= 1'b1;
        end
    end

    // ---- Sideband pipeline ----
    logic [DATA_WIDTH-1:0] tdata_pipe  [PIPE_STAGES];
    logic                  tvalid_pipe [PIPE_STAGES];
    logic                  tlast_pipe  [PIPE_STAGES];
    logic                  tuser_pipe  [PIPE_STAGES];

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            for (int i = 0; i < PIPE_STAGES; i++) begin
                tdata_pipe[i]  <= '0;
                tvalid_pipe[i] <= 1'b0;
                tlast_pipe[i]  <= 1'b0;
                tuser_pipe[i]  <= 1'b0;
            end
        end else if (!pipe_stall_o) begin
            tdata_pipe[0]  <= s_axis_tdata_i;
            tvalid_pipe[0] <= s_axis_tvalid_i && s_axis_tready_o;
            tlast_pipe[0]  <= s_axis_tlast_i;
            tuser_pipe[0]  <= s_axis_tuser_i;
            for (int i = 1; i < PIPE_STAGES; i++) begin
                tdata_pipe[i]  <= tdata_pipe[i-1];
                tvalid_pipe[i] <= tvalid_pipe[i-1];
                tlast_pipe[i]  <= tlast_pipe[i-1];
                tuser_pipe[i]  <= tuser_pipe[i-1];
            end
        end
    end

    assign pipe_valid = tvalid_pipe[PIPE_STAGES-1];

    // ---- Pipeline outputs ----
    assign pipe_tdata_o = tdata_pipe[PIPE_STAGES-1];
    assign pipe_tlast_o = tlast_pipe[PIPE_STAGES-1];
    assign pipe_tuser_o = tuser_pipe[PIPE_STAGES-1];

    // ---- Per-output gated tvalid ----
    assign m_a_tvalid_o = pipe_valid && !a_accepted;
    assign m_b_tvalid_o = pipe_valid && !b_accepted;

endmodule
