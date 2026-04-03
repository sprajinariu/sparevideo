
Cocotb is not a good approach.
Best (minimal sim slowdown): Shared memory (shm) ring buffer
Why it’s fast
No kernel networking stack, no disk I/O
One bulk copy per frame (or per line)
Python reads asynchronously; simulator never blocks (drop frames if viewer is behind)
Architecture
Producer (sim): when a frame completes, copy packed pixels into a shared buffer slot; increment write_idx.
Consumer (python): poll write_idx, read the latest complete slot, show it.
Implementation choices
SystemVerilog DPI-C to call small C functions:
shm_init(width,height,format,num_buffers)
shm_write_frame(ptr_to_pixels, frame_id, timestamp) (bulk copy)
Or if you’re using Verilator: a C++ harness can write directly to shared memory.
Pixel format
Pick a format that matches your pipeline and Python display with minimal conversion:

Prefer RGB888 (or BGR888 for OpenCV) to avoid extra conversion.
If your DUT is YUV (e.g., NV12/YUY2), either:
Send YUV and convert in Python (often fast using OpenCV), or
Convert once in C on the producer side if that’s cheaper overall.
Avoid stalls
Make the ring buffer N-deep (e.g., 3–8 frames).
If full, overwrite/drop oldest (viewer will skip frames; sim stays fast).


1) Decouple visualization rate from simulation rate
Even if the DUT runs “millions of frames” logically, only display:

30–60 FPS max (or “every Nth frame”)
In sim: only publish a frame when frame_id % N == 0

2) Do bulk transfers, not per-pixel callbacks
Avoid:

DPI call per pixel
VPI scanning large arrays every cycle
Instead:
Pack pixels into a contiguous buffer in sim
One DPI call per frame (or per line)
3) Don’t block the simulator
Producer should never wait for Python.
Use ring buffer + drop policy.

4) Prefer C/C++ boundary, not Python boundary
Simulator ↔ C via DPI is cheap relative to simulator ↔ Python.
Python just maps memory and displays.