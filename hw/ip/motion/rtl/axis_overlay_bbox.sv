// AXI4-Stream bounding-box overlay.
//
// Draws a 1-pixel-thick rectangle on the RGB video stream using the
// previously latched bbox coordinates from axis_bbox_reduce. This gives
// a 1-frame-latency streaming model — no extra frame buffer needed.
//
// A pixel is "on the rectangle" iff:
//   ((col==min_x || col==max_x) && row in [min_y, max_y]) ||
//   ((row==min_y || row==max_y) && col in [min_x, max_x])
//
// When bbox_empty is asserted, no overlay is drawn (pure passthrough).

module axis_overlay_bbox #(
    parameter int H_ACTIVE   = 320,
    parameter int V_ACTIVE   = 240,
    parameter logic [23:0] BBOX_COLOR = 24'h00_FF_00
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    // AXI4-Stream input — video (RGB888)
    input  logic [23:0] s_axis_tdata_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,
    input  logic        s_axis_tuser_i,

    // AXI4-Stream output — video (RGB888)
    output logic [23:0] m_axis_tdata_o,
    output logic        m_axis_tvalid_o,
    input  logic        m_axis_tready_i,
    output logic        m_axis_tlast_o,
    output logic        m_axis_tuser_o,

    // Sideband input — bbox from axis_bbox_reduce
    input  logic [$clog2(H_ACTIVE)-1:0] bbox_min_x_i,
    input  logic [$clog2(H_ACTIVE)-1:0] bbox_max_x_i,
    input  logic [$clog2(V_ACTIVE)-1:0] bbox_min_y_i,
    input  logic [$clog2(V_ACTIVE)-1:0] bbox_max_y_i,
    input  logic                        bbox_empty_i
);

    // Pass through backpressure
    assign s_axis_tready_o = m_axis_tready_i;

    // ---- Column/row counters ----
    logic [$clog2(H_ACTIVE)-1:0] col;
    logic [$clog2(V_ACTIVE)-1:0] row;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col <= '0;
            row <= '0;
        end else if (s_axis_tvalid_i && s_axis_tready_o) begin
            if (s_axis_tuser_i) begin
                // SOF pixel is at image col=0; advance to 1 so the next pixel
                // (image col=1) sees col=1. The SOF pixel itself already reads
                // col=0 from the registered value set by the previous tlast.
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

    // ---- Rectangle hit test (combinational) ----
    logic on_rect;

    // On the SOF pixel, the registered row still holds V_ACTIVE (from the
    // previous frame's final tlast increment).  Use row=0 combinationally
    // for the SOF pixel so the hit test sees the correct position.
    logic [$clog2(V_ACTIVE)-1:0] row_eff;
    assign row_eff = (s_axis_tvalid_i && s_axis_tuser_i) ? '0 : row;

    // Intermediate signals for Icarus compat (no bit-selects in always_comb)
    logic on_left_or_right;
    logic in_y_range;
    logic on_top_or_bottom;
    logic in_x_range;

    assign on_left_or_right = (col == bbox_min_x_i) || (col == bbox_max_x_i);
    assign in_y_range       = (row_eff >= bbox_min_y_i) && (row_eff <= bbox_max_y_i);
    assign on_top_or_bottom = (row_eff == bbox_min_y_i) || (row_eff == bbox_max_y_i);
    assign in_x_range       = (col >= bbox_min_x_i) && (col <= bbox_max_x_i);

    assign on_rect = !bbox_empty_i &&
                     ((on_left_or_right && in_y_range) ||
                      (on_top_or_bottom && in_x_range));

    // ---- Output mux ----
    assign m_axis_tdata_o  = on_rect ? BBOX_COLOR : s_axis_tdata_i;
    assign m_axis_tvalid_o = s_axis_tvalid_i;
    assign m_axis_tlast_o  = s_axis_tlast_i;
    assign m_axis_tuser_o  = s_axis_tuser_i;

endmodule
