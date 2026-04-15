// sparevideo_pkg — project-wide parameters and types.
//
// All configuration parameters (video timing defaults, algorithm knobs,
// pipeline constants) and shared typedefs live here. Modules import this
// package and use the constants as parameter defaults or directly.
//
// Migration path: when runtime configurability is added (sparevideo_csr),
// these localparams become the reset-value table for the CSR register file.
// The downstream modules' parameter ports become input ports driven by the
// CSR block instead of by localparams from sparevideo_top.

package sparevideo_pkg;

    // ---------------------------------------------------------------
    // Shared types
    // ---------------------------------------------------------------

    // 24-bit packed RGB pixel {R[7:0], G[7:0], B[7:0]}
    typedef logic [23:0] pixel_t;

    // 8-bit colour component (R, G, B, Y, Cb, Cr)
    typedef logic [7:0]  component_t;

    // ---------------------------------------------------------------
    // Control flow selection (top-level pipeline mode)
    // ---------------------------------------------------------------
    localparam logic CTRL_PASSTHROUGH   = 1'b0;
    localparam logic CTRL_MOTION_DETECT = 1'b1;

    // ---------------------------------------------------------------
    // Default video timing (320x240 — small, fast-to-simulate)
    // Override at sparevideo_top instantiation for other resolutions.
    // ---------------------------------------------------------------
    localparam int H_ACTIVE      = 320;
    localparam int H_FRONT_PORCH = 4;
    localparam int H_SYNC_PULSE  = 8;
    localparam int H_BACK_PORCH  = 4;

    localparam int V_ACTIVE      = 240;
    localparam int V_FRONT_PORCH = 2;
    localparam int V_SYNC_PULSE  = 2;
    localparam int V_BACK_PORCH  = 2;

    // ---------------------------------------------------------------
    // Motion detection and RAM region parameters — added here when
    // the motion pipeline is wired into sparevideo_top:
    //
    //   localparam component_t MOTION_THRESH  = 8'd16;
    //   localparam pixel_t     BBOX_COLOR     = 24'h00_FF_00;
    //   localparam int         RGN_Y_PREV_BASE = 0;
    //   localparam int         RGN_Y_PREV_SIZE = H_ACTIVE * V_ACTIVE;
    //   localparam int         RAM_DEPTH       = RGN_Y_PREV_SIZE;
    //
    // Future: all of the above migrate to sparevideo_csr CSR register
    // file (AXI-Lite slave) for runtime configurability.
    // ---------------------------------------------------------------

endpackage
