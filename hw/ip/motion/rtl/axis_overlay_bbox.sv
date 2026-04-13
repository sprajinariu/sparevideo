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
    input  logic        clk,
    input  logic        rst_n,

    // AXI4-Stream input — video (RGB888)
    input  logic [23:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic        s_axis_tuser,

    // AXI4-Stream output — video (RGB888)
    output logic [23:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,
    output logic        m_axis_tuser,

    // Sideband input — bbox from axis_bbox_reduce
    input  logic [$clog2(H_ACTIVE)-1:0] bbox_min_x,
    input  logic [$clog2(H_ACTIVE)-1:0] bbox_max_x,
    input  logic [$clog2(V_ACTIVE)-1:0] bbox_min_y,
    input  logic [$clog2(V_ACTIVE)-1:0] bbox_max_y,
    input  logic                        bbox_empty
);

    // Pass through backpressure
    assign s_axis_tready = m_axis_tready;

    // ---- Column/row counters ----
    logic [$clog2(H_ACTIVE)-1:0] col;
    logic [$clog2(V_ACTIVE)-1:0] row;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            col <= '0;
            row <= '0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            if (s_axis_tuser) begin
                col <= '0;
                row <= '0;
            end else if (s_axis_tlast) begin
                col <= '0;
                row <= row + 1;
            end else begin
                col <= col + 1;
            end
        end
    end

    // ---- Rectangle hit test (combinational) ----
    logic on_rect;

    // Intermediate signals for Icarus compat (no bit-selects in always_comb)
    logic on_left_or_right;
    logic in_y_range;
    logic on_top_or_bottom;
    logic in_x_range;

    assign on_left_or_right = (col == bbox_min_x) || (col == bbox_max_x);
    assign in_y_range       = (row >= bbox_min_y) && (row <= bbox_max_y);
    assign on_top_or_bottom = (row == bbox_min_y) || (row == bbox_max_y);
    assign in_x_range       = (col >= bbox_min_x) && (col <= bbox_max_x);

    assign on_rect = !bbox_empty &&
                     ((on_left_or_right && in_y_range) ||
                      (on_top_or_bottom && in_x_range));

    // ---- Output mux ----
    assign m_axis_tdata  = on_rect ? BBOX_COLOR : s_axis_tdata;
    assign m_axis_tvalid = s_axis_tvalid;
    assign m_axis_tlast  = s_axis_tlast;
    assign m_axis_tuser  = s_axis_tuser;

endmodule
