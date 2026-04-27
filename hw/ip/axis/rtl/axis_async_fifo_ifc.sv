// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Interface-port wrapper around the vendored verilog-axis axis_async_fifo.
// The vendored core uses flat ports and active-high reset; this wrapper
// adapts both to the project conventions (interface bundles + active-low
// rst_n) without modifying the vendored source.
//
// Disabled-feature parameters are hardcoded to match project usage:
//   KEEP_ENABLE=0, LAST_ENABLE=1, ID_ENABLE=0, DEST_ENABLE=0.
// USER_ENABLE=1 and USER_WIDTH=USER_W are always enabled.

module axis_async_fifo_ifc #(
    parameter int DEPTH          = 1024,
    parameter int DATA_W         = 24,
    parameter int USER_W         = 1,
    parameter int RAM_PIPELINE   = 2,
    parameter bit FRAME_FIFO     = 1'b0,
    parameter bit DROP_BAD_FRAME = 1'b0,
    parameter bit DROP_WHEN_FULL = 1'b0
) (
    input  logic                       s_clk,
    input  logic                       s_rst_n,
    input  logic                       m_clk,
    input  logic                       m_rst_n,

    axis_if.rx                         s_axis,
    axis_if.tx                         m_axis,

    // Status / occupancy. Width follows the vendored core ($clog2(DEPTH)+1).
    // Note (per CLAUDE.md): these depths do NOT include the internal output
    // pipeline FIFO (~16 entries with default RAM_PIPELINE=2). Do not use
    // them as the sole signal for tight back-pressure thresholds.
    output logic [$clog2(DEPTH):0]     s_status_depth,
    output logic                       s_status_overflow,
    output logic [$clog2(DEPTH):0]     m_status_depth
);

    // Adapt project-convention active-low reset to the vendored active-high.
    logic s_rst, m_rst;
    assign s_rst = ~s_rst_n;
    assign m_rst = ~m_rst_n;

    axis_async_fifo #(
        .DEPTH         (DEPTH),
        .DATA_WIDTH    (DATA_W),
        .KEEP_ENABLE   (0),
        .LAST_ENABLE   (1),
        .ID_ENABLE     (0),
        .DEST_ENABLE   (0),
        .USER_ENABLE   (1),
        .USER_WIDTH    (USER_W),
        .RAM_PIPELINE  (RAM_PIPELINE),
        .FRAME_FIFO    (FRAME_FIFO),
        .DROP_BAD_FRAME(DROP_BAD_FRAME),
        .DROP_WHEN_FULL(DROP_WHEN_FULL)
    ) u_fifo (
        .s_clk          (s_clk),
        .s_rst          (s_rst),
        .s_axis_tdata   (s_axis.tdata),
        .s_axis_tkeep   (3'b0),
        .s_axis_tvalid  (s_axis.tvalid),
        .s_axis_tready  (s_axis.tready),
        .s_axis_tlast   (s_axis.tlast),
        .s_axis_tid     (8'b0),
        .s_axis_tdest   (8'b0),
        .s_axis_tuser   (s_axis.tuser),

        .m_clk          (m_clk),
        .m_rst          (m_rst),
        .m_axis_tdata   (m_axis.tdata),
        .m_axis_tkeep   (),
        .m_axis_tvalid  (m_axis.tvalid),
        .m_axis_tready  (m_axis.tready),
        .m_axis_tlast   (m_axis.tlast),
        .m_axis_tid     (),
        .m_axis_tdest   (),
        .m_axis_tuser   (m_axis.tuser),

        .s_pause_req    (1'b0),
        .s_pause_ack    (),
        .m_pause_req    (1'b0),
        .m_pause_ack    (),

        .s_status_depth        (s_status_depth),
        .s_status_depth_commit (),
        .s_status_overflow     (s_status_overflow),
        .s_status_bad_frame    (),
        .s_status_good_frame   (),

        .m_status_depth        (m_status_depth),
        .m_status_depth_commit (),
        .m_status_overflow     (),
        .m_status_bad_frame    (),
        .m_status_good_frame   ()
    );

endmodule
