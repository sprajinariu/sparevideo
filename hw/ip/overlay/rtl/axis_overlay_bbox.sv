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

    axis_if.rx  s_axis,
    axis_if.tx  m_axis,

    // Sideband bbox array from axis_ccl.
    bbox_if.rx  bboxes
);

    assign s_axis.tready = m_axis.tready;

    logic [$clog2(H_ACTIVE)-1:0] col;
    logic [$clog2(V_ACTIVE)-1:0] row;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col <= '0;
            row <= '0;
        end else if (s_axis.tvalid && s_axis.tready) begin
            if (s_axis.tuser) begin
                col <= ($bits(col))'(1);
                row <= '0;
            end else if (s_axis.tlast) begin
                col <= '0;
                row <= row + 1;
            end else begin
                col <= col + 1;
            end
        end
    end

    logic [$clog2(V_ACTIVE)-1:0] row_eff;
    assign row_eff = (s_axis.tvalid && s_axis.tuser) ? '0 : row;

    // N-wide hit test: per-slot on_rect, ORed.
    logic [N_OUT-1:0] hit;
    genvar k;
    generate
        for (k = 0; k < N_OUT; k = k + 1) begin : g_hit
            logic on_lr, in_yr, on_tb, in_xr;
            assign on_lr = (col == bboxes.min_x[k]) || (col == bboxes.max_x[k]);
            assign in_yr = (row_eff >= bboxes.min_y[k]) && (row_eff <= bboxes.max_y[k]);
            assign on_tb = (row_eff == bboxes.min_y[k]) || (row_eff == bboxes.max_y[k]);
            assign in_xr = (col >= bboxes.min_x[k]) && (col <= bboxes.max_x[k]);
            assign hit[k] = bboxes.valid[k] && ((on_lr && in_yr) || (on_tb && in_xr));
        end
    endgenerate

    logic on_rect;
    assign on_rect = |hit;

    assign m_axis.tdata  = on_rect ? BBOX_COLOR : s_axis.tdata;
    assign m_axis.tvalid = s_axis.tvalid;
    assign m_axis.tlast  = s_axis.tlast;
    assign m_axis.tuser  = s_axis.tuser;

endmodule
