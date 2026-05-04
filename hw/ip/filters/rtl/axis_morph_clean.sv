// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_morph_clean — combined 3x3 open + parametrizable 3x3/5x5 close.
//
// Pipeline: erode -> dilate -> [dilate * N] -> [erode * N]
//                   ^^^ open ^^^   ^^^^^^^ close (kernel = 2N+1) ^^^^^^^
//
// N = (CLOSE_KERNEL - 1) / 2:
//   CLOSE_KERNEL=3 -> N=1 -> 1 dilate + 1 erode = 3x3 close
//   CLOSE_KERNEL=5 -> N=2 -> 2 dilates + 2 erodes = 5x5 close
// (Minkowski composition: 3x3 ⊕ 3x3 = 5x5.)
//
// Each sub-stage's enable_i:
//   morph_open_en_i  -> u_open_erode, u_open_dilate
//   morph_close_en_i -> all close-stage erodes and dilates
//
// When a stage's enable_i = 0, the existing axis_morph3x3_{erode,dilate}
// primitive forwards its input combinatorially with zero added latency
// and the line buffers are ignored (zero-latency combinational bypass).
//
// Latency: (2 + 2*N) * (H_ACTIVE + 3) cycles when both gates are enabled.

module axis_morph_clean #(
    parameter int H_ACTIVE     = 320,
    parameter int V_ACTIVE     = 240,
    parameter int CLOSE_KERNEL = 3
) (
    input  logic clk_i,
    input  logic rst_n_i,

    input  logic morph_open_en_i,
    input  logic morph_close_en_i,

    axis_if.rx s_axis,
    axis_if.tx m_axis
);

    initial begin
        if (CLOSE_KERNEL != 3 && CLOSE_KERNEL != 5) begin
            $fatal(1, "axis_morph_clean: CLOSE_KERNEL must be 3 or 5, got %0d",
                   CLOSE_KERNEL);
        end
    end

    localparam int N = (CLOSE_KERNEL - 1) / 2;
    // Total sub-stages: 2 (open: erode + dilate) + 2*N (close: N dilates + N erodes)
    localparam int N_STAGES = 2 + 2 * N;

    // Internal interfaces between sub-stages. Index 0 = output of stage 0,
    // index N_STAGES-1 = output of last stage = m_axis.
    axis_if #(.DATA_W(1), .USER_W(1)) inter [N_STAGES] ();

    // ---- Open stage 1: erode ----------------------------------------
    axis_morph3x3_erode #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_open_erode (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .enable_i (morph_open_en_i),
        .s_axis   (s_axis),
        .m_axis   (inter[0]),
        .busy_o   ()
    );

    // ---- Open stage 2: dilate ---------------------------------------
    axis_morph3x3_dilate #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_open_dilate (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .enable_i (morph_open_en_i),
        .s_axis   (inter[0]),
        .m_axis   (inter[1]),
        .busy_o   ()
    );

    // ---- Close stages: N dilates then N erodes ----------------------
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_close_dilate
            axis_morph3x3_dilate #(
                .H_ACTIVE (H_ACTIVE),
                .V_ACTIVE (V_ACTIVE)
            ) u_d (
                .clk_i    (clk_i),
                .rst_n_i  (rst_n_i),
                .enable_i (morph_close_en_i),
                .s_axis   (inter[1 + i]),
                .m_axis   (inter[2 + i]),
                .busy_o   ()
            );
        end
        for (i = 0; i < N; i++) begin : g_close_erode
            axis_morph3x3_erode #(
                .H_ACTIVE (H_ACTIVE),
                .V_ACTIVE (V_ACTIVE)
            ) u_e (
                .clk_i    (clk_i),
                .rst_n_i  (rst_n_i),
                .enable_i (morph_close_en_i),
                .s_axis   (inter[1 + N + i]),
                .m_axis   (inter[2 + N + i]),
                .busy_o   ()
            );
        end
    endgenerate

    // ---- Tail: connect last interface to m_axis ---------------------
    assign m_axis.tdata  = inter[N_STAGES - 1].tdata;
    assign m_axis.tvalid = inter[N_STAGES - 1].tvalid;
    assign m_axis.tlast  = inter[N_STAGES - 1].tlast;
    assign m_axis.tuser  = inter[N_STAGES - 1].tuser;
    assign inter[N_STAGES - 1].tready = m_axis.tready;

endmodule
