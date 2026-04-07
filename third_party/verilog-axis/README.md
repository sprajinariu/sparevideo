# verilog-axis (vendored)

Source: https://github.com/alexforencich/verilog-axis
Pinned commit: `48ff7a7e2ef782cf778d47910cf85835c64b1bce` (see `COMMIT`)
License: MIT (see `LICENSE`)

Pure Verilog-2001 AXI4-Stream library. The full `rtl/` folder is vendored
verbatim so we can pick up additional modules later without re-vendoring.

Modules currently instantiated by sparevideo:
- `rtl/axis_async_fifo.v` — clock-domain-crossing FIFO
- `rtl/axis_register.v`   — pipeline register slice
