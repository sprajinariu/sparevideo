# File-Based Python Harness for RTL Simulation

Replace cocotb with a lightweight file-based flow: Python harness prepares input frames as files, SV testbench reads them into the RTL, RTL processes and SV testbench writes output frames to files, Python harness reads and verifies the results.

## Goals

- **No cocotb dependency** — Python is a harness around the simulation, not inside it.
- **File-based interface** between Python and SV (text or binary, user-selectable).
- **SV testbench owns timing** — all cycle-level and sanity checks live in SystemVerilog.
- **Python harness owns high-level verification** — e.g. checking that filtering was applied correctly. Initially: verify output frames match input (passthrough).
- **Python renders input/output video** for visual inspection.

## Non-Goals

- Real-time or shared-memory coupling between Python and the simulator.
- Python-level cycle-accurate checks.

---

## Frame Size

Default: **320x240 (QVGA)**.

Rationale: QVGA is a standard video resolution. Many short test clips (Big Buck Bunny, Sintel, etc.) are freely available and easy to downscale to 320x240. Power-of-2 sizes like 256x256 are convenient for hardware but non-standard aspect ratios make it harder to source sample video. Frame size is parameterizable — both the Python harness and SV testbench accept width/height as configuration.

---

## File Format

The user selects **text** or **binary** mode. Multiple frames are stored sequentially in one file.

### Text mode (default, human-readable)

```
# HEADER
WIDTH 320
HEIGHT 240
FRAMES 3
FORMAT RGB888

# FRAME 0
FF 00 00 FF 00 00 ...   (one line per row, space-separated hex bytes R G B R G B ...)
FF 00 00 FF 00 00 ...
...
# FRAME 1
...
```

- One line per pixel row.
- Each line: space-separated 2-digit hex bytes (R G B R G B ...), `WIDTH * 3` bytes per line.
- Blank lines and `#` comment lines are ignored by the SV reader.

### Binary mode (compact)

```
Bytes 0-3:   WIDTH  (32-bit little-endian)
Bytes 4-7:   HEIGHT (32-bit little-endian)
Bytes 8-11:  FRAMES (32-bit little-endian)
Bytes 12+:   raw pixel data, 3 bytes/pixel (R,G,B), row-major, frame after frame
```

Total pixel data size per frame: `WIDTH * HEIGHT * 3` bytes.

---

## Architecture

```
                         input.txt/bin              output.txt/bin
  ┌────────────┐        ┌───────────┐             ┌───────────┐        ┌────────────┐
  │  Python    │ write  │           │  SV TB read │           │ write  │  Python    │
  │  Harness   │───────>│ Input     │────────────>│ Output    │<───────│  SV TB     │
  │ (prepare)  │        │ File      │             │ File      │        │ (RTL sim)  │
  └────────────┘        └───────────┘             └───────────┘        └────────────┘
                                                                              │
  ┌────────────┐                                                              │
  │  Python    │<─────────────────────────────────────────────────────────────┘
  │  Harness   │  read output file, verify, render
  │ (verify)   │
  └────────────┘
```

### Flow

1. **Python harness (prepare)** — loads input video (e.g. MP4/PNG sequence), extracts N frames, resizes to target resolution, writes `input.{txt,bin}`.
2. **SV testbench** — reads `input.{txt,bin}`, feeds pixels into RTL via ready/valid interface, captures RTL output, writes `output.{txt,bin}`. Performs timing checks (hsync/vsync if applicable, backpressure, protocol correctness) and sanity checks (e.g. no X/Z on outputs).
3. **Python harness (verify)** — reads `output.{txt,bin}`, compares against expected (for now: input == output passthrough check), renders input and output as side-by-side image grids or short video clips.

---

## Directory Structure

```
dv/
  harness/
    harness.py          # CLI entry point: prepare / verify / render
    frame_io.py         # Read/write text and binary frame files
    video_source.py     # Load video from MP4/PNG/synthetic, resize, extract frames
    render.py           # Render input/output frames as image grid or video
  sv/
    tb_pipeline.sv      # SV testbench: reads input file, drives RTL, writes output file
    frame_file_reader.sv  # (optional helper) SV module/tasks for reading frame files
    frame_file_writer.sv  # (optional helper) SV module/tasks for writing frame files
  data/
    input.txt           # generated input (gitignored)
    input.bin           # generated input (gitignored)
    output.txt          # simulation output (gitignored)
    output.bin          # simulation output (gitignored)
    renders/            # rendered PNGs/videos (gitignored)
```

---

## Implementation Steps

### Step 1: Frame I/O library (`frame_io.py`)

- `write_frames(path, frames, mode='text')` — write list of numpy arrays (H,W,3 uint8) to text or binary file.
- `read_frames(path, mode='text')` — read file back into list of numpy arrays.
- Unit-testable standalone (round-trip: write then read, compare).

**Done when:** `python -m pytest test_frame_io.py` passes — round-trip test writes 2+ frames in text mode, reads them back, asserts numpy array equality. Manual inspection: open a generated `.txt` file and confirm the header and hex rows look correct.

### Step 2: Video source loader (`video_source.py`)

- `load_frames(source, width=320, height=240, num_frames=4)` — accepts:
  - **Path to MP4/AVI** → extract frames with OpenCV, resize. **This is the primary input mode** — the user will supply sample videos downloaded from the internet (e.g. Big Buck Bunny clips, Sintel, etc.).
  - Path to directory of PNGs → load and resize.
  - `"synthetic:<pattern>"` → generate test pattern (color bars, gradient, checkerboard, moving box) as a fallback for quick testing without external video.
- Returns list of numpy arrays.

**Done when:** `python video_source.py <sample.mp4> --frames 4 --width 320 --height 240` loads frames and writes them via `frame_io`. Verify: output file has correct header (WIDTH/HEIGHT/FRAMES), and re-reading the file back produces arrays with shape `(240, 320, 3)`. Also test with a synthetic pattern and a PNG directory.

### Step 3: SV frame file reader (text mode first)

- SV tasks/module that reads the text-format header, then reads pixel rows line by line.
- Feeds pixels into RTL input port via ready/valid handshake (1 pixel/clk when ready & valid).
- Asserts SOF/EOL framing signals.

**Done when:** A minimal SV testbench instantiates the reader, reads a known input file (e.g. 2 frames of 4x2 pixels), and `$display`s each pixel value. Output matches the input file contents exactly. No `$error` or X/Z values.

### Step 4: SV frame file writer

- Captures RTL output pixels via ready/valid.
- Writes to output file in same format (text or binary).

**Done when:** Wire the reader directly to the writer (loopback, no RTL in between). Run sim, then use Python `frame_io.read_frames()` on the output file and compare against the original input file — arrays must be identical.

### Step 5: SV testbench timing/sanity checks

- Verify correct number of pixels per line and lines per frame.
- Check no X/Z on output data when valid is asserted.
- Check ready/valid protocol (data stable when valid & !ready).
- Check frame count matches expected.
- Report PASS/FAIL with `$display`.

**Done when:** `make sim-pipeline` completes with all checks passing and prints a summary (e.g. `PASS: 4 frames, 0 errors`). Intentionally break something (e.g. corrupt one pixel in the input file) and confirm the SV checks catch it.

### Step 6: Python verify & render (`render.py`)

- Read output file, compare frame-by-frame against input (numpy array equality for passthrough).
- Report per-frame pass/fail and pixel diff stats.
- Render: produce a PNG grid showing input frames (top row) and output frames (bottom row).
- Optional: stitch frames into a short GIF/MP4 for visual inspection.

**Done when:** `python harness.py verify --input dv/data/input.txt --output dv/data/output.txt` prints per-frame PASS/FAIL and exits 0 on success. `python harness.py render ...` produces a PNG grid image that visually shows input vs output frames side by side. Open the PNG and confirm it looks correct.

### Step 7: Makefile integration

```makefile
# Prepare input (from synthetic pattern, default 4 frames)
make prepare
make prepare SOURCE=path/to/video.mp4 FRAMES=8 MODE=binary

# Run SV simulation
make sim-pipeline

# Verify + render output
make verify
make render

# Full flow: prepare → sim → verify → render
make run-pipeline
```

**Done when:** `make run-pipeline` executes the full flow end-to-end (prepare → sim → verify → render) and exits 0. Each individual target also works standalone. `make run-pipeline SOURCE=path/to/video.mp4` works with an external video file.

### Step 8: Binary mode support

- Extend `frame_io.py` to handle binary read/write.
- Extend SV reader/writer to handle binary format (`$fread`/`$fwrite`).
- `MODE=text|binary` flag flows through Makefile → Python → SV (via plusarg).

**Done when:** `make run-pipeline MODE=binary` passes the full flow. Binary output file is significantly smaller than text equivalent. Round-trip test: write binary → read binary → compare arrays matches original.

---

## Configuration & Plusargs

| Parameter | Default | Set via |
|-----------|---------|---------|
| Frame width | 320 | Python CLI arg + SV plusarg `+WIDTH=` |
| Frame height | 240 | Python CLI arg + SV plusarg `+HEIGHT=` |
| Number of frames | 4 | Python CLI arg + SV plusarg `+FRAMES=` |
| File mode | text | Python CLI arg + SV plusarg `+MODE=text` |
| Input file path | `dv/data/input.txt` | Python CLI arg + SV plusarg `+INFILE=` |
| Output file path | `dv/data/output.txt` | Python CLI arg + SV plusarg `+OUTFILE=` |

---

## Python Dependencies

- `numpy` — frame arrays
- `opencv-python` (`cv2`) — video loading, resizing
- `Pillow` — PNG rendering, image grid
- `imageio` (optional) — GIF/MP4 output

---

## Open Questions

- Should the SV testbench support backpressure injection (randomly deasserting ready) to stress-test the pipeline? (Recommended yes, as a plusarg-controlled option.)
- When real processing is added, Python verification will need reference models. Keep the harness extensible for plugging in per-block reference functions.
