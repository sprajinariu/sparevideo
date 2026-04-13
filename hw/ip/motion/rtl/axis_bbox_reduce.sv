// AXI4-Stream bounding-box reducer.
//
// Consumes a 1-bit mask stream and tracks {min_x, max_x, min_y, max_y}
// over all pixels where mask==1 within each frame. At EOF (last pixel of
// the frame), the accumulated bbox is latched into output registers and
// the scratch counters are reset for the next frame.
//
// Output is a sideband interface (not AXIS) — 4 registered coordinates
// plus bbox_valid (1-cycle strobe on latch) and bbox_empty (no motion
// pixels in the completed frame).

module axis_bbox_reduce #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240
) (
    input  logic        clk,
    input  logic        rst_n,

    // AXI4-Stream input — mask (1 bit)
    input  logic        s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic        s_axis_tuser,

    // Sideband output — latched bbox
    output logic [$clog2(H_ACTIVE)-1:0] bbox_min_x,
    output logic [$clog2(H_ACTIVE)-1:0] bbox_max_x,
    output logic [$clog2(V_ACTIVE)-1:0] bbox_min_y,
    output logic [$clog2(V_ACTIVE)-1:0] bbox_max_y,
    output logic                        bbox_valid,
    output logic                        bbox_empty
);

    // Always ready — pure sink, no backpressure.
    assign s_axis_tready = 1'b1;

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

    // ---- Scratch accumulators ----
    logic [$clog2(H_ACTIVE)-1:0] sc_min_x, sc_max_x;
    logic [$clog2(V_ACTIVE)-1:0] sc_min_y, sc_max_y;
    logic                        sc_any;  // at least one mask=1 seen

    // EOF detection: last pixel of frame = tlast on the last row.
    logic is_eof;
    assign is_eof = s_axis_tvalid && s_axis_tready && s_axis_tlast
                    && (row == ($bits(row))'(V_ACTIVE - 1));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sc_min_x <= '1;  // max value = "not yet set"
            sc_max_x <= '0;
            sc_min_y <= '1;
            sc_max_y <= '0;
            sc_any   <= 1'b0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            if (s_axis_tuser) begin
                // SOF: reset scratch for new frame
                sc_min_x <= '1;
                sc_max_x <= '0;
                sc_min_y <= '1;
                sc_max_y <= '0;
                sc_any   <= 1'b0;
            end

            if (s_axis_tdata) begin
                // Mask pixel is active — update bbox
                sc_any <= 1'b1;
                if (col < sc_min_x) sc_min_x <= col;
                if (col > sc_max_x) sc_max_x <= col;
                if (row < sc_min_y) sc_min_y <= row;
                if (row > sc_max_y) sc_max_y <= row;
            end
        end
    end

    // ---- Latch output at EOF ----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bbox_min_x <= '0;
            bbox_max_x <= '0;
            bbox_min_y <= '0;
            bbox_max_y <= '0;
            bbox_valid <= 1'b0;
            bbox_empty <= 1'b1;
        end else begin
            bbox_valid <= 1'b0;  // default: strobe off

            if (is_eof) begin
                bbox_valid <= 1'b1;
                bbox_empty <= ~sc_any;
                if (sc_any) begin
                    bbox_min_x <= sc_min_x;
                    bbox_max_x <= sc_max_x;
                    bbox_min_y <= sc_min_y;
                    bbox_max_y <= sc_max_y;
                end else begin
                    bbox_min_x <= '0;
                    bbox_max_x <= '0;
                    bbox_min_y <= '0;
                    bbox_max_y <= '0;
                end
            end
        end
    end

endmodule
