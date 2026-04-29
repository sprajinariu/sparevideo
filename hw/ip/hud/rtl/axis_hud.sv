// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_hud — 8x8 bitmap text overlay on a 24-bit RGB AXIS at the post-scaler tail.
//
// Renders 30 characters at output coordinates (HUD_X0, HUD_Y0):
//   "F:####  T:XXX  N:##  L:#####us"
//
// Datapath: 1-deep skid pipeline (same pattern as axis_gamma_cor). The skid
// latches the input pixel together with its (col, row) position; the render
// mux is then a pure combinational lookup over the latched state, keeping the
// FONT_ROM lookup off the long input-to-output path.
//
// Sideband ports are latched at HUD-input-SOF and held for the whole frame.
// Frame number, bbox count, and latency are decimal-expanded by an iterative
// subtract-10 FSM running once per frame during v-blank.
//
// enable_i = 0: data-equivalent passthrough through the same 1-cycle skid
// (no HUD overlay; framing and latency are identical to the enabled path).

module axis_hud
    import sparevideo_pkg::*;
    import axis_hud_font_pkg::*;
#(
    parameter int H_ACTIVE = sparevideo_pkg::H_ACTIVE_OUT_2X,
    parameter int V_ACTIVE = sparevideo_pkg::V_ACTIVE_OUT_2X,
    parameter int HUD_X0   = 8,
    parameter int HUD_Y0   = 8,
    parameter int N_CHARS  = 30
) (
    input  logic clk_i,
    input  logic rst_n_i,
    input  logic enable_i,

    input  logic [15:0] frame_num_i,
    input  logic [7:0]  bbox_count_i,
    input  logic [1:0]  ctrl_flow_tag_i,
    input  logic [15:0] latency_us_i,

    axis_if.rx s_axis,
    axis_if.tx m_axis
);

    // ---- Counter widths and FSM state type --------------------------
    localparam int COL_W = $clog2(H_ACTIVE + 1);
    localparam int ROW_W = $clog2(V_ACTIVE + 1);

    typedef enum logic [1:0] { D_IDLE, D_FRAME, D_BBOX, D_LAT } d_state_e;

    // ---- Sideband latch (held frame-stable from SOF) ---------------
    logic [15:0]      frame_num_q;
    logic [7:0]       bbox_count_q;
    logic [1:0]       ctrl_flow_tag_q;
    logic [15:0]      latency_us_q;

    // ---- Input-side position counter -------------------------------
    // (col_in_q, row_in_q) holds the position of the pixel CURRENTLY being
    // presented on s_axis. After reset col_in_q=0, so the first SOF pixel is
    // correctly identified at (0,0). On each accepted beat we update lazily
    // to the position of the NEXT input pixel.
    logic [COL_W-1:0] col_in_q;
    logic [ROW_W-1:0] row_in_q;

    // ---- Skid stage (1-deep): pixel data, framing, and position ----
    logic [23:0]      s_axis_data_q;
    logic             tlast_q;
    logic             tuser_q;
    logic             pipe_valid_q;
    logic [COL_W-1:0] col_pipe_q;
    logic [ROW_W-1:0] row_pipe_q;

    // ---- Decimal-expand FSM state ----------------------------------
    d_state_e         d_state;
    logic [3:0]       d_idx;          // digit position within current field
    logic [15:0]      rem;            // working remainder
    // Quotient counter for the subtract-10 step. Must be at least as wide as
    // rem because for a worst-case 16-bit dividend (latency_us=65535) the
    // quotient at the LSD step is 6553 — too wide for 4 bits, which would
    // wrap and silently corrupt the next decade's dividend.
    logic [15:0]      cnt;

    logic [3:0]       dig_frame [4];  // dig_frame[0]=MSD .. dig_frame[3]=LSD
    logic [3:0]       dig_bbox  [2];
    logic [3:0]       dig_lat   [5];

    // ---- Glyph-index table -----------------------------------------
    glyph_idx_t       glyph_table [N_CHARS];
    glyph_idx_t       tag_glyph   [3];

    // ---- Render-path combinational signals (over registered state) -
    logic             beat;
    logic             stage_advance;
    logic             in_band_y;
    logic             in_band_x;
    logic             in_hud_region;
    logic [COL_W-1:0] col_off;        // col_pipe_q - HUD_X0
    logic [ROW_W-1:0] row_off;        // row_pipe_q - HUD_Y0
    logic [4:0]       cell_idx;       // 0..N_CHARS-1
    logic [2:0]       x_in_cell;
    logic [2:0]       y_in_cell;
    logic [7:0]       rom_row;
    logic             fg_bit;

    // ---- Saturated sideband (bbox_count: 8-bit input, 2-digit field) ------
    // latency_us is 16-bit (0..65535) and fits in the 5-digit field already,
    // so no saturation is needed there.
    logic [7:0]       bbox_count_sat;

    assign beat           = s_axis.tvalid && s_axis.tready;
    // Standard 1-deep skid: advance when downstream accepts OR when the stage
    // is empty so a fresh beat can drop in without waiting.
    assign stage_advance  = m_axis.tready || !pipe_valid_q;
    assign bbox_count_sat = (bbox_count_i > 8'd99) ? 8'd99 : bbox_count_i;

    // ---- Input-side position counter -------------------------------
    // Updates after each accepted beat to point at the position of the NEXT
    // input pixel, so col_in_q is always correct for the pixel currently on
    // s_axis (col_in_q=0 at reset matches the first SOF pixel).
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col_in_q <= '0;
            row_in_q <= '0;
        end else if (beat) begin
            if (s_axis.tuser) begin
                col_in_q <= COL_W'(1);
                row_in_q <= '0;
            end else if (s_axis.tlast) begin
                col_in_q <= '0;
                row_in_q <= row_in_q + 1'b1;
            end else begin
                col_in_q <= col_in_q + 1'b1;
            end
        end
    end

    // ---- Skid latch: pixel + framing + position --------------------
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            pipe_valid_q  <= 1'b0;
            tlast_q       <= 1'b0;
            tuser_q       <= 1'b0;
            s_axis_data_q <= '0;
            col_pipe_q    <= '0;
            row_pipe_q    <= '0;
        end else if (stage_advance) begin
            pipe_valid_q  <= s_axis.tvalid;
            tlast_q       <= s_axis.tlast;
            tuser_q       <= s_axis.tuser;
            s_axis_data_q <= s_axis.tdata;
            col_pipe_q    <= col_in_q;
            row_pipe_q    <= row_in_q;
        end
    end

    // ---- Sideband latch on accepted SOF beat -----------------------
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            frame_num_q     <= '0;
            bbox_count_q    <= '0;
            ctrl_flow_tag_q <= '0;
            latency_us_q    <= '0;
        end else if (beat && s_axis.tuser) begin
            frame_num_q     <= frame_num_i;
            bbox_count_q    <= bbox_count_sat;
            ctrl_flow_tag_q <= ctrl_flow_tag_i;
            latency_us_q    <= latency_us_i;
        end
    end

    // ---- Decimal-expand FSM (subtract-10 iteration, runs in v-blank) ----
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            d_state <= D_IDLE;
            d_idx   <= '0;
            rem     <= '0;
            cnt     <= '0;
            for (int i = 0; i < 4; i++) dig_frame[i] <= '0;
            for (int i = 0; i < 2; i++) dig_bbox [i] <= '0;
            for (int i = 0; i < 5; i++) dig_lat  [i] <= '0;
        end else begin
            unique case (d_state)
                D_IDLE: begin
                    if (beat && s_axis.tuser) begin
                        d_state <= D_FRAME;
                        d_idx   <= 4'd3;             // start at LSD
                        rem     <= frame_num_i;      // live input; latch fires same edge
                        cnt     <= '0;
                    end
                end
                D_FRAME: begin
                    if (rem >= 16'd10) begin
                        rem <= rem - 16'd10;
                        cnt <= cnt + 1'b1;
                    end else begin
                        dig_frame[d_idx[1:0]] <= rem[3:0];
                        rem <= cnt;
                        cnt <= '0;
                        if (d_idx == 4'd0) begin
                            d_state <= D_BBOX;
                            d_idx   <= 4'd1;
                            rem     <= {8'd0, bbox_count_q};
                        end else begin
                            d_idx <= d_idx - 1'b1;
                        end
                    end
                end
                D_BBOX: begin
                    if (rem >= 16'd10) begin
                        rem <= rem - 16'd10;
                        cnt <= cnt + 1'b1;
                    end else begin
                        dig_bbox[d_idx[0]] <= rem[3:0];
                        rem <= cnt;
                        cnt <= '0;
                        if (d_idx == 4'd0) begin
                            d_state <= D_LAT;
                            d_idx   <= 4'd4;
                            rem     <= latency_us_q;
                        end else begin
                            d_idx <= d_idx - 1'b1;
                        end
                    end
                end
                D_LAT: begin
                    if (rem >= 16'd10) begin
                        rem <= rem - 16'd10;
                        cnt <= cnt + 1'b1;
                    end else begin
                        dig_lat[d_idx[2:0]] <= rem[3:0];
                        rem <= cnt;
                        cnt <= '0;
                        if (d_idx == 4'd0) d_state <= D_IDLE;
                        else               d_idx   <= d_idx - 1'b1;
                    end
                end
                default: d_state <= D_IDLE;
            endcase
        end
    end

    // ---- Tag-glyph ROM (4 ctrl_flow values -> 3 glyph indices) -----
    always_comb begin
        unique case (ctrl_flow_tag_q)
            sparevideo_pkg::CTRL_PASSTHROUGH:   tag_glyph = '{ G_P, G_A, G_S };
            sparevideo_pkg::CTRL_MOTION_DETECT: tag_glyph = '{ G_M, G_O, G_T };
            sparevideo_pkg::CTRL_MASK_DISPLAY:  tag_glyph = '{ G_M, G_S, G_K };
            sparevideo_pkg::CTRL_CCL_BBOX:      tag_glyph = '{ G_C, G_C, G_L };
            default:                            tag_glyph = '{ G_SPACE, G_SPACE, G_SPACE };
        endcase
    end

    // ---- Example of a Glyph ROM entry and its rendering ----
    // the '0' character:
    // - - 1 1 1 1 - -  // 0x3C
    // - 1 1 - - 1 1 -  // 0x66
    // - 1 1 - 1 1 1 -  // 0x6E
    // - 1 1 1 - 1 1 -  // 0x76
    // - 1 1 - - 1 1 -  // 0x66
    // - 1 1 - - 1 1 -  // 0x66
    // - - 1 1 1 1 - -  // 0x3C
    // - - - - - - - -  // 0x00

    // ---- Glyph-index table assembly: "F:####  T:XXX  N:##  L:#####us" ----
    always_comb begin
        glyph_table[ 0] = G_F;
        glyph_table[ 1] = G_COLON;
        glyph_table[ 2] = glyph_idx_t'(dig_frame[0]);  // MSD..LSD => slots 2..5
        glyph_table[ 3] = glyph_idx_t'(dig_frame[1]);
        glyph_table[ 4] = glyph_idx_t'(dig_frame[2]);
        glyph_table[ 5] = glyph_idx_t'(dig_frame[3]);
        glyph_table[ 6] = G_SPACE;
        glyph_table[ 7] = G_SPACE;
        glyph_table[ 8] = G_T;
        glyph_table[ 9] = G_COLON;
        glyph_table[10] = tag_glyph[0];
        glyph_table[11] = tag_glyph[1];
        glyph_table[12] = tag_glyph[2];
        glyph_table[13] = G_SPACE;
        glyph_table[14] = G_SPACE;
        glyph_table[15] = G_N;
        glyph_table[16] = G_COLON;
        glyph_table[17] = glyph_idx_t'(dig_bbox[0]);
        glyph_table[18] = glyph_idx_t'(dig_bbox[1]);
        glyph_table[19] = G_SPACE;
        glyph_table[20] = G_SPACE;
        glyph_table[21] = G_L;
        glyph_table[22] = G_COLON;
        glyph_table[23] = glyph_idx_t'(dig_lat[0]);
        glyph_table[24] = glyph_idx_t'(dig_lat[1]);
        glyph_table[25] = glyph_idx_t'(dig_lat[2]);
        glyph_table[26] = glyph_idx_t'(dig_lat[3]);
        glyph_table[27] = glyph_idx_t'(dig_lat[4]);
        glyph_table[28] = G_U;
        glyph_table[29] = G_S;
    end

    // ---- Per-pixel render: HUD region check + glyph-bit lookup -----
    // All computed combinationally from the REGISTERED skid-stage position so
    // the FONT_ROM lookup is off the long input-to-output path.
    always_comb begin
        col_off   = col_pipe_q - COL_W'(HUD_X0);
        row_off   = row_pipe_q - ROW_W'(HUD_Y0);
        in_band_y = (row_pipe_q >= ROW_W'(HUD_Y0)) && (row_pipe_q < ROW_W'(HUD_Y0 + 8));
        in_band_x = (col_pipe_q >= COL_W'(HUD_X0)) && (col_pipe_q < COL_W'(HUD_X0 + N_CHARS*8));
        cell_idx  = 5'(col_off >> 3);
        x_in_cell = col_off[2:0];
        y_in_cell = row_off[2:0];
        rom_row   = FONT_ROM[glyph_table[cell_idx]][y_in_cell];
        fg_bit    = rom_row[7 - x_in_cell];
    end

    assign in_hud_region = in_band_y && in_band_x;

    // ---- Output mux: drives m_axis from the registered skid stage --
    // enable_i=0 still goes through the same skid (data-equivalent passthrough,
    // 1-cycle latency); only the per-pixel mux differs.
    always_comb begin
        s_axis.tready = stage_advance;
        m_axis.tvalid = pipe_valid_q;
        m_axis.tlast  = tlast_q;
        m_axis.tuser  = tuser_q;
        if (enable_i) begin
            m_axis.tdata = (in_hud_region && fg_bit) ? 24'hFF_FF_FF
                                                     : s_axis_data_q;
        end else begin
            m_axis.tdata = s_axis_data_q;
        end
    end

endmodule
