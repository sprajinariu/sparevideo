"""Cocotb tests for VGA top-level.

Focused on timing verification and quick pixel spot-checks.
For full frame visualization, use 'make viz' (runs viz.py, no simulator).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from vga_monitor import VGAMonitor, H_TOTAL, V_TOTAL, H_SYNC_PULSE, \
    H_ACTIVE, H_FRONT_PORCH, H_BACK_PORCH, V_BACK_PORCH


async def reset_dut(dut, pattern=0):
    """Apply reset and set pattern."""
    dut.rst_n.value = 0
    dut.pattern_sel.value = pattern
    await ClockCycles(dut.clk, 20)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_vga_timing(dut):
    """Verify VGA hsync and vsync timing parameters."""
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    monitor = VGAMonitor(dut)

    period = await monitor.measure_hsync_period()
    assert period == H_TOTAL, f"Hsync period: got {period}, expected {H_TOTAL}"
    dut._log.info(f"Hsync period = {period} clocks")

    pulse = await monitor.measure_hsync_pulse_width()
    assert pulse == H_SYNC_PULSE, f"Hsync pulse width: got {pulse}, expected {H_SYNC_PULSE}"
    dut._log.info(f"Hsync pulse width = {pulse} clocks")


@cocotb.test()
async def test_frame_timing(dut):
    """Verify full frame period is H_TOTAL * V_TOTAL clocks."""
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    monitor = VGAMonitor(dut)
    frame_period = await monitor.measure_frame_period()
    expected = H_TOTAL * V_TOTAL

    assert frame_period == expected, \
        f"Frame period: got {frame_period}, expected {expected}"
    dut._log.info(f"Frame period = {frame_period} clocks")


@cocotb.test()
async def test_color_bar_spot_check(dut):
    """Quick spot-check of a few color bar pixels without full frame capture.

    Navigates to known pixel positions using bulk ClockCycles + edge triggers,
    then reads RGB values. Much faster than full frame capture.
    """
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut, pattern=0)

    # Navigate to a known pixel position:
    # 1. Align to vsync falling edge (start of vsync pulse)
    await FallingEdge(dut.vga_vsync)
    # 2. Wait for vsync to end + back porch
    await RisingEdge(dut.vga_vsync)
    await ClockCycles(dut.clk, V_BACK_PORCH * H_TOTAL)
    # 3. Now at h=0, v=0 (first active pixel). Skip to the hsync region
    #    and back to align precisely.
    await FallingEdge(dut.vga_hsync)
    await RisingEdge(dut.vga_hsync)
    await ClockCycles(dut.clk, H_BACK_PORCH)
    # 4. Now at h=0 of an active line. Output register has 1 clock delay.

    # Check color bars at specific x positions (center of each bar)
    # Bars are 80px wide. Centers at x=40, 120, 200, 280, 360, 440, 520, 600
    expected_bars = [
        (40,  0xFF, 0xFF, 0xFF, "white"),
        (120, 0xFF, 0xFF, 0x00, "yellow"),
        (200, 0x00, 0xFF, 0xFF, "cyan"),
        (280, 0x00, 0xFF, 0x00, "green"),
        (360, 0xFF, 0x00, 0xFF, "magenta"),
        (440, 0xFF, 0x00, 0x00, "red"),
        (520, 0x00, 0x00, 0xFF, "blue"),
        (600, 0x00, 0x00, 0x00, "black"),
    ]

    current_x = 0
    for target_x, exp_r, exp_g, exp_b, name in expected_bars:
        # +1 for the register delay on the first pixel
        skip = target_x - current_x + (1 if current_x == 0 else 0)
        await ClockCycles(dut.clk, skip)
        current_x = target_x

        r = int(dut.vga_r.value)
        g = int(dut.vga_g.value)
        b = int(dut.vga_b.value)

        assert r == exp_r and g == exp_g and b == exp_b, \
            f"Bar '{name}' at x={target_x}: got ({r:02x},{g:02x},{b:02x}), " \
            f"expected ({exp_r:02x},{exp_g:02x},{exp_b:02x})"
        dut._log.info(f"  {name}: OK ({r:02x} {g:02x} {b:02x})")

    dut._log.info("All color bar spot checks passed")
