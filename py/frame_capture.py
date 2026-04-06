"""Frame capture utilities for VGA display emulation.

Converts captured VGA frame data to PNG images using Pillow.
"""

from PIL import Image


def save_frame(scanlines, filename, width=640, height=480):
    """Save a captured frame as a PNG image.

    Args:
        scanlines: list of height lists, each containing width (r, g, b) tuples
        filename: output PNG file path
        width: expected frame width
        height: expected frame height
    """
    img = Image.new("RGB", (width, height))
    for y, line in enumerate(scanlines[:height]):
        for x, (r, g, b) in enumerate(line[:width]):
            img.putpixel((x, y), (r, g, b))
    img.save(filename)


# Expected color bar values: 8 columns of 80 pixels
COLOR_BARS = [
    (0xFF, 0xFF, 0xFF),  # White
    (0xFF, 0xFF, 0x00),  # Yellow
    (0x00, 0xFF, 0xFF),  # Cyan
    (0x00, 0xFF, 0x00),  # Green
    (0xFF, 0x00, 0xFF),  # Magenta
    (0xFF, 0x00, 0x00),  # Red
    (0x00, 0x00, 0xFF),  # Blue
    (0x00, 0x00, 0x00),  # Black
]


def verify_color_bars(scanlines, width=640):
    """Verify that captured frame contains correct SMPTE color bars.

    Spot-checks the center pixel of each color bar column at a few scanlines.

    Returns:
        (pass_count, fail_count, errors) tuple
    """
    col_width = width // 8
    errors = []
    pass_count = 0
    fail_count = 0

    check_lines = [0, 100, 240, 479]  # sample a few rows

    for y in check_lines:
        if y >= len(scanlines):
            errors.append(f"Missing scanline {y}")
            fail_count += 1
            continue

        for col_idx, expected in enumerate(COLOR_BARS):
            x = col_idx * col_width + col_width // 2  # center of column
            if x >= len(scanlines[y]):
                errors.append(f"Missing pixel ({x}, {y})")
                fail_count += 1
                continue

            got = scanlines[y][x]
            if got != expected:
                errors.append(
                    f"Pixel ({x},{y}): got {got}, expected {expected} "
                    f"(bar {col_idx})"
                )
                fail_count += 1
            else:
                pass_count += 1

    return pass_count, fail_count, errors


def verify_checkerboard(scanlines, block_size=8):
    """Verify checkerboard pattern at a few spot-check positions.

    Returns:
        (pass_count, fail_count, errors) tuple
    """
    errors = []
    pass_count = 0
    fail_count = 0

    check_positions = [
        (4, 4),    # inside block (0,0) — should be black (0^0=0)
        (12, 4),   # inside block (1,0) — should be white (1^0=1)
        (4, 12),   # inside block (0,1) — should be white (0^1=1)
        (12, 12),  # inside block (1,1) — should be black (1^1=0)
        (100, 200),
        (104, 200),
    ]

    for x, y in check_positions:
        if y >= len(scanlines) or x >= len(scanlines[y]):
            errors.append(f"Missing pixel ({x}, {y})")
            fail_count += 1
            continue

        block_x = (x // block_size) & 1
        block_y = (y // block_size) & 1
        expected = (0xFF, 0xFF, 0xFF) if (block_x ^ block_y) else (0x00, 0x00, 0x00)

        got = scanlines[y][x]
        if got != expected:
            errors.append(
                f"Pixel ({x},{y}): got {got}, expected {expected} "
                f"(block {block_x},{block_y})"
            )
            fail_count += 1
        else:
            pass_count += 1

    return pass_count, fail_count, errors
