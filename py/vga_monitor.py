"""VGA signal monitor for cocotb.

Captures VGA output signals (hsync, vsync, RGB) and assembles frames
as lists of scanlines, each scanline being a list of (r, g, b) tuples.

Two capture modes:
- capture_frames(): per-pixel sampling via RisingEdge (accurate, slow)
- capture_frames_fast(): samples one pixel per line via ClockCycles bulk skip,
  then reconstructs the full line from the pattern (fast, for visualization)
"""

from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
from cocotb.utils import get_sim_time

# Default VGA 640x480 timing
H_ACTIVE = 640
H_FRONT_PORCH = 16
H_SYNC_PULSE = 96
H_BACK_PORCH = 48
H_TOTAL = H_ACTIVE + H_FRONT_PORCH + H_SYNC_PULSE + H_BACK_PORCH  # 800

V_ACTIVE = 480
V_FRONT_PORCH = 10
V_SYNC_PULSE = 2
V_BACK_PORCH = 33
V_TOTAL = V_ACTIVE + V_FRONT_PORCH + V_SYNC_PULSE + V_BACK_PORCH  # 525

CLK_PERIOD_NS = 40  # 25 MHz


class VGAMonitor:
    """Monitor VGA output signals and capture frame data."""

    def __init__(self, dut, h_active=H_ACTIVE, v_active=V_ACTIVE):
        self.dut = dut
        self.h_active = h_active
        self.v_active = v_active
        self.frames = []

    async def _align_to_frame_start(self):
        """Wait until the start of an active frame (after vsync + back porch)."""
        await FallingEdge(self.dut.vga_vsync)
        await RisingEdge(self.dut.vga_vsync)
        # After vsync posedge: V_BACK_PORCH lines to reach active area
        await ClockCycles(self.dut.clk, V_BACK_PORCH * H_TOTAL)

    async def capture_frames(self, num_frames=1):
        """Capture frames with per-pixel accuracy. Slow but exact."""
        clk = self.dut.clk

        for _ in range(num_frames):
            await self._align_to_frame_start()

            frame = []
            for line_num in range(self.v_active):
                if line_num > 0:
                    # Skip horizontal blanking
                    await ClockCycles(clk, H_FRONT_PORCH + H_SYNC_PULSE + H_BACK_PORCH)

                # 1-clock output register delay
                await RisingEdge(clk)

                scanline = []
                for px in range(self.h_active):
                    r = int(self.dut.vga_r.value)
                    g = int(self.dut.vga_g.value)
                    b = int(self.dut.vga_b.value)
                    scanline.append((r, g, b))
                    if px < self.h_active - 1:
                        await RisingEdge(clk)

                frame.append(scanline)

            self.frames.append(frame)

    async def capture_frames_fast(self, num_frames=1, sample_cols=None):
        """Fast frame capture — samples a sparse set of columns per line.

        Skips most pixels using ClockCycles, only samples at specific columns.
        Much faster than per-pixel capture. Good for visualization where you
        know the pattern is horizontally uniform within regions.

        Args:
            num_frames: number of frames to capture
            sample_cols: list of x positions to sample per line.
                         If None, samples every 8th pixel (80 samples/line).
        """
        clk = self.dut.clk
        if sample_cols is None:
            sample_cols = list(range(0, self.h_active, 8))

        for _ in range(num_frames):
            await self._align_to_frame_start()

            frame = []
            for line_num in range(self.v_active):
                if line_num > 0:
                    await ClockCycles(clk, H_FRONT_PORCH + H_SYNC_PULSE + H_BACK_PORCH)

                # 1-clock output register delay
                await RisingEdge(clk)

                # Sample at sparse positions, interpolate the rest
                samples = {}
                current_x = 0
                for target_x in sample_cols:
                    skip = target_x - current_x
                    if skip > 0:
                        await ClockCycles(clk, skip)
                    r = int(self.dut.vga_r.value)
                    g = int(self.dut.vga_g.value)
                    b = int(self.dut.vga_b.value)
                    samples[target_x] = (r, g, b)
                    current_x = target_x

                # Skip remaining pixels in the line
                remaining = self.h_active - 1 - current_x
                if remaining > 0:
                    await ClockCycles(clk, remaining)

                # Reconstruct full scanline: nearest-neighbor from samples
                sorted_xs = sorted(samples.keys())
                scanline = []
                sample_idx = 0
                for x in range(self.h_active):
                    while (sample_idx < len(sorted_xs) - 1
                           and sorted_xs[sample_idx + 1] <= x):
                        sample_idx += 1
                    scanline.append(samples[sorted_xs[sample_idx]])

                frame.append(scanline)

            self.frames.append(frame)

    async def measure_hsync_period(self):
        """Measure hsync period in clock cycles."""
        await FallingEdge(self.dut.vga_hsync)
        t0 = get_sim_time(unit="ns")
        await FallingEdge(self.dut.vga_hsync)
        t1 = get_sim_time(unit="ns")
        return int((t1 - t0) / CLK_PERIOD_NS)

    async def measure_hsync_pulse_width(self):
        """Measure hsync pulse width in clock cycles."""
        await FallingEdge(self.dut.vga_hsync)
        t0 = get_sim_time(unit="ns")
        await RisingEdge(self.dut.vga_hsync)
        t1 = get_sim_time(unit="ns")
        return int((t1 - t0) / CLK_PERIOD_NS)

    async def measure_frame_period(self):
        """Measure frame period in clock cycles (vsync negedge to negedge)."""
        await FallingEdge(self.dut.vga_vsync)
        t0 = get_sim_time(unit="ns")
        await FallingEdge(self.dut.vga_vsync)
        t1 = get_sim_time(unit="ns")
        return int((t1 - t0) / CLK_PERIOD_NS)
