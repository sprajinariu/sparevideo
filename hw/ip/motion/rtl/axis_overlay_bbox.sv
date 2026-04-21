// AXI4-Stream bounding-box overlay (N-wide).
//
// Draws 1-pixel-thick rectangles on the RGB video stream using N_OUT
// per-slot bbox coordinates (from axis_ccl). A pixel is coloured BBOX_COLOR
// when ANY valid slot's rectangle hits it.

module axis_overlay_bbox #(
    parameter int  H_ACTIVE   = 320,
    parameter int  V_ACTIVE   = 240,
    parameter int  N_OUT      = sparevideo_pkg::CCL_N_OUT,
    parameter logic [23:0] BBOX_COLOR = 24'h00_FF_00
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    input  logic [23:0] s_axis_tdata_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,
    input  logic        s_axis_tuser_i,

    output logic [23:0] m_axis_tdata_o,
    output logic        m_axis_tvalid_o,
    input  logic        m_axis_tready_i,
    output logic        m_axis_tlast_o,
    output logic        m_axis_tuser_o,

    // Sideband bbox array from axis_ccl.
    input  logic [N_OUT-1:0]                       bbox_valid_i,
    input  logic [N_OUT-1:0][$clog2(H_ACTIVE)-1:0] bbox_min_x_i,
    input  logic [N_OUT-1:0][$clog2(H_ACTIVE)-1:0] bbox_max_x_i,
    input  logic [N_OUT-1:0][$clog2(V_ACTIVE)-1:0] bbox_min_y_i,
    input  logic [N_OUT-1:0][$clog2(V_ACTIVE)-1:0] bbox_max_y_i
);

    assign s_axis_tready_o = m_axis_tready_i;

    logic [$clog2(H_ACTIVE)-1:0] col;
    logic [$clog2(V_ACTIVE)-1:0] row;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col <= '0;
            row <= '0;
        end else if (s_axis_tvalid_i && s_axis_tready_o) begin
            if (s_axis_tuser_i) begin
                col <= ($bits(col))'(1);
                row <= '0;
            end else if (s_axis_tlast_i) begin
                col <= '0;
                row <= row + 1;
            end else begin
                col <= col + 1;
            end
        end
    end

    logic [$clog2(V_ACTIVE)-1:0] row_eff;
    assign row_eff = (s_axis_tvalid_i && s_axis_tuser_i) ? '0 : row;

    // N-wide hit test: per-slot on_rect, ORed.
    logic [N_OUT-1:0] hit;
    genvar k;
    generate
        for (k = 0; k < N_OUT; k = k + 1) begin : g_hit
            logic on_lr, in_yr, on_tb, in_xr;
            assign on_lr = (col == bbox_min_x_i[k]) || (col == bbox_max_x_i[k]);
            assign in_yr = (row_eff >= bbox_min_y_i[k]) && (row_eff <= bbox_max_y_i[k]);
            assign on_tb = (row_eff == bbox_min_y_i[k]) || (row_eff == bbox_max_y_i[k]);
            assign in_xr = (col >= bbox_min_x_i[k]) && (col <= bbox_max_x_i[k]);
            assign hit[k] = bbox_valid_i[k] && ((on_lr && in_yr) || (on_tb && in_xr));
        end
    endgenerate

    logic on_rect;
    assign on_rect = |hit;

    assign m_axis_tdata_o  = on_rect ? BBOX_COLOR : s_axis_tdata_i;
    assign m_axis_tvalid_o = s_axis_tvalid_i;
    assign m_axis_tlast_o  = s_axis_tlast_i;
    assign m_axis_tuser_o  = s_axis_tuser_i;

endmodule
