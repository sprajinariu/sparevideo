// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Project-wide SystemVerilog interfaces.
//
// Two top-level interface declarations live in this single file, mirroring the
// one-file pattern of sparevideo_pkg.sv. Both interfaces follow a uniform
// modport convention:
//
//   tx  — produces the bundle (drives data, reads back-pressure where present)
//   rx  — consumes the bundle (reads data, drives back-pressure where present)
//   mon — passive observer (all signals input); for testbench monitors
//
// Convention: clk/rst_n are NOT carried inside the interface. They remain
// explicit clk_i/rst_n_i ports on every module so that
//   (a) the project's existing port-naming convention is preserved, and
//   (b) a single interface bundle can cross a clock domain (e.g. the producer
//       is in clk_pix and the consumer in clk_proc, with axis_async_fifo_ifc
//       between them) without ambiguity about which clock owns the interface.

// AXI4-Stream — minimal subset used by this project (tdata, tvalid, tready,
// tlast, tuser). Add tkeep / tdest / tid here when an actual consumer needs
// them; do not pre-add. USER_W defaults to 1 to match the SOF semantics used
// by every current AXI-Stream stage in the pipeline.
interface axis_if #(
    parameter int DATA_W = 24,
    parameter int USER_W = 1
);
    logic [DATA_W-1:0] tdata;
    logic              tvalid;
    logic              tready;
    logic              tlast;
    logic [USER_W-1:0] tuser;

    modport tx  (output tdata, tvalid, tlast, tuser, input  tready);
    modport rx  (input  tdata, tvalid, tlast, tuser, output tready);
    modport mon (input  tdata, tvalid, tready, tlast, tuser);
endinterface

// Sideband bbox bundle from axis_ccl to axis_overlay_bbox. N_OUT slots, each
// with a valid bit and four coordinates. Latched per-frame, not per-beat —
// hence no handshake signals on this interface.
interface bbox_if #(
    parameter int N_OUT = sparevideo_pkg::CCL_N_OUT,
    parameter int H_W   = $clog2(sparevideo_pkg::H_ACTIVE),
    parameter int V_W   = $clog2(sparevideo_pkg::V_ACTIVE)
);
    logic [N_OUT-1:0]           valid;
    logic [N_OUT-1:0][H_W-1:0]  min_x;
    logic [N_OUT-1:0][H_W-1:0]  max_x;
    logic [N_OUT-1:0][V_W-1:0]  min_y;
    logic [N_OUT-1:0][V_W-1:0]  max_y;

    modport tx  (output valid, min_x, max_x, min_y, max_y);
    modport rx  (input  valid, min_x, max_x, min_y, max_y);
    modport mon (input  valid, min_x, max_x, min_y, max_y);
endinterface
