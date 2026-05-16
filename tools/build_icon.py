"""Generate Clankpad's Windows app icon as a multi-resolution .ico.

The source is a hand-drawn 32x32 pixel-art grid below. It is upscaled
with nearest-neighbour to the standard Windows icon sizes and packed
into an .ico with PNG-encoded entries (supported by all modern Windows
versions).

Run from repo root:
    python tools/build_icon.py

Output: windows/runner/resources/app_icon.ico
"""

import io
import struct
from pathlib import Path

from PIL import Image

# ---------------------------------------------------------------------------
# Source pixel art (32x32). One character per pixel.
#
#   .  transparent          K  charcoal outline / dark body
#   B  slate body fill      P  cream paper / face screen
#   L  ink-blue text line   A  red LED antenna tip
#
# Design: boxy robot head dominates the canvas. Antenna with red LED on top,
# side bolt-knobs at mid-head, a cream rectangular "face screen" with four
# ragged ink-blue text lines (notepad pattern), short shoulder block below.
# The face IS the pad.
# ---------------------------------------------------------------------------

# 32x32 base grid. Used for all sizes >= 32 via nearest-neighbour upscale,
# and as the source for non-standard intermediate sizes.
GRID = """\
................................
...............AA...............
...............KK...............
...............KK...............
....KKKKKKKKKKKKKKKKKKKKKKKK....
....KBBBBBBBBBBBBBBBBBBBBBBK....
....KBBBBBBBBBBBBBBBBBBBBBBK....
....KBBBBBBBBBBBBBBBBBBBBBBK....
....KBBBKKKKKKKKKKKKKKKKBBBK....
....KBBBKPPPPPPPPPPPPPPKBBBK....
....KBBBKPLLLLLLLLLLLPPKBBBK....
....KBBBKPPPPPPPPPPPPPPKBBBK....
....KBBBKPLLLLLLLLLPPPPKBBBK....
..KKKBBBKPPPPPPPPPPPPPPKBBBKKK..
..KKKBBBKPLLLLLLLLLLLLPKBBBKKK..
....KBBBKPPPPPPPPPPPPPPKBBBK....
....KBBBKPLLLLLLLLPPPPPKBBBK....
....KBBBKPPPPPPPPPPPPPPKBBBK....
....KBBBKPPPPPPPPPPPPPPKBBBK....
....KBBBKKKKKKKKKKKKKKKKBBBK....
....KBBBBBBBBBBBBBBBBBBBBBBK....
....KBBBBBBBBBBBBBBBBBBBBBBK....
....KBBBBBBBBBBBBBBBBBBBBBBK....
....KKKKKKKKKKKKKKKKKKKKKKKK....
..KKKKKKKKKKKKKKKKKKKKKKKKKKKK..
..KBBBBBBBBBBBBBBBBBBBBBBBBBBK..
..KBBBBBBBBBBBBBBBBBBBBBBBBBBK..
..KBBBBBBBBBBBBBBBBBBBBBBBBBBK..
..KBBBBBBBBBBBBBBBBBBBBBBBBBBK..
..KKKKKKKKKKKKKKKKKKKKKKKKKKKK..
................................
................................
"""

PALETTE = {
    ".": (0, 0, 0, 0),
    "K": (0x1E, 0x1E, 0x22, 255),
    "B": (0x2D, 0x2D, 0x34, 255),
    "P": (0xF3, 0xEA, 0xD0, 255),
    "L": (0x2A, 0x5A, 0x87, 255),
    "A": (0xD9, 0x4A, 0x44, 255),
}

# Hand-drawn 16x16 variant. A straight 32->16 nearest-neighbour downscale
# drops every other pixel and destroys the face-screen text lines, which is
# the whole point of the design. This smaller redraw keeps the notepad face
# legible at taskbar-small-mode size by simplifying: no side bolts, fewer
# text lines, single-pixel antenna stem.
GRID_16 = """\
........A.......
........K.......
..KKKKKKKKKKKK..
..KBBBBBBBBBBK..
..KBPPPPPPPPBK..
..KBPLLLLLLPBK..
..KBPPPPPPPPBK..
..KBPLLLLPPPBK..
..KBPPPPPPPPBK..
..KBPLLLLLPPBK..
..KBPPPPPPPPBK..
..KKKKKKKKKKKK..
.KKKKKKKKKKKKKK.
.KBBBBBBBBBBBBK.
.KBBBBBBBBBBBBK.
.KKKKKKKKKKKKKK.
"""

# Standard Windows icon sizes embedded in the .ico.
SIZES = [16, 24, 32, 48, 64, 128, 256]

OUTPUT = Path("windows/runner/resources/app_icon.ico")


def render_grid(grid: str, size: int) -> Image.Image:
    """Materialise an ASCII grid (size x size) into an RGBA image."""
    rows = [line for line in grid.splitlines() if line]
    assert len(rows) == size, f"Expected {size} rows, got {len(rows)}"
    for i, row in enumerate(rows):
        assert len(row) == size, f"Row {i} has {len(row)} cols, expected {size}"
        for ch in row:
            assert ch in PALETTE, f"Unknown char {ch!r} in row {i}"

    img = Image.new("RGBA", (size, size))
    px = img.load()
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            px[x, y] = PALETTE[ch]
    return img


def write_ico(images: list[Image.Image], path: Path) -> None:
    """Pack a list of RGBA PIL images into a multi-resolution .ico file.

    Uses PNG-encoded entries throughout (compact and well-supported).
    """
    images = sorted(images, key=lambda im: im.size[0])
    n = len(images)

    # Encode each frame as PNG bytes.
    png_data: list[bytes] = []
    for im in images:
        buf = io.BytesIO()
        im.save(buf, format="PNG")
        png_data.append(buf.getvalue())

    out = io.BytesIO()
    # ICONDIR: reserved(0) | type(1=ICO) | count
    out.write(struct.pack("<HHH", 0, 1, n))

    # ICONDIRENTRY * n  (16 bytes each)
    offset = 6 + 16 * n
    for im, png in zip(images, png_data):
        w, h = im.size
        out.write(
            struct.pack(
                "<BBBBHHII",
                w if w < 256 else 0,  # width  (0 means 256)
                h if h < 256 else 0,  # height (0 means 256)
                0,                    # palette colour count
                0,                    # reserved
                1,                    # colour planes
                32,                   # bits per pixel
                len(png),             # bytes in image data
                offset,               # absolute offset to image data
            )
        )
        offset += len(png)

    for png in png_data:
        out.write(png)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(out.getvalue())


def main() -> None:
    base_32 = render_grid(GRID, 32)
    base_16 = render_grid(GRID_16, 16)
    images = [
        base_16 if s == 16 else base_32.resize((s, s), Image.NEAREST)
        for s in SIZES
    ]
    write_ico(images, OUTPUT)
    print(f"Wrote {OUTPUT} with sizes {SIZES}")


if __name__ == "__main__":
    main()
