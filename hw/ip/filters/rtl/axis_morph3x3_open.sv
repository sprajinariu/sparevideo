// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// 3x3 morphological opening on a 1-bit mask stream, implemented as a pure
// structural composite of axis_morph3x3_erode -> axis_morph3x3_dilate connected
// by an internal AXI4-Stream interface.
//
// Opening = erosion followed by dilation. It removes isolated foreground
// pixels ("salt") and thin structures smaller than the structuring element
// while preserving sufficiently large blobs (idempotent on regions that
// contain a full 3x3 interior).
//
// Latency: 2 * (H_ACTIVE + 3) cycles from first s_axis.tvalid to first
// m_axis.tvalid -- one H_ACTIVE+3 stage per sub-module.
// Throughput: 1 pixel/cycle after fill when !stall.
//
// Blanking: defers to axis_window3x3 (each sub-module needs >=1 H-blank
// and >=H_ACTIVE+1 V-blank cycles for phantom drain). Blanking requirements
// do not compound because the internal link is 1-pixel/cycle with no added
// back-pressure when downstream is ready.
//
// enable_i: forwarded verbatim to both sub-modules. When 0, both bypass
// their window paths and the composite becomes a zero-latency combinational
// passthrough. enable_i must be held frame-stable.

module axis_morph3x3_open #(
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
    axis_if.tx m_axis
);

    // ---- Internal AXIS interface: erode -> dilate ----
    axis_if #(.DATA_W(1), .USER_W(1)) erode_to_dilate ();

    // ---- Stage 1: erosion ----
    axis_morph3x3_erode #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_erode (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .enable_i (enable_i),
        .s_axis   (s_axis),
        .m_axis   (erode_to_dilate),
        .busy_o   ()
    );

    // ---- Stage 2: dilation ----
    axis_morph3x3_dilate #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_dilate (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .enable_i (enable_i),
        .s_axis   (erode_to_dilate),
        .m_axis   (m_axis),
        .busy_o   ()
    );

endmodule
