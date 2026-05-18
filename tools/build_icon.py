"""Generate Clankpad's app icon for Windows (.ico) and macOS (PNG set).

The source is a hand-drawn 32x32 pixel-art grid below (with a separate
16x16 redraw for the smallest taskbar size). Each rendered base size is
post-processed with a 1px white outline, then upscaled with nearest-
neighbour to all required target sizes, then either packed into a multi-
resolution .ico for Windows or written out as PNGs for the macOS asset
catalog.

Run from repo root:
    python tools/build_icon.py

Outputs:
    windows/runner/resources/app_icon.ico
    macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png
"""

import io
import struct
from pathlib import Path

from PIL import Image

# ---------------------------------------------------------------------------
# Source pixel art. One character per pixel.
#
#   .  transparent          K  charcoal outline / dark body
#   B  slate body fill      P  cream paper
#   L  ink-blue text line   A  mint-green LED antenna tip
#   E  pale cyan eye glow
#
# Concept: a notepad with a small bot head emerging from the top edge like
# a bookmark tab. The pad dominates the silhouette; the bot is a personality
# cue, not the subject. Three ink-blue text strokes on the cream paper
# (long / medium / short, ragged-right) suggest writing in progress. The
# head's bottom edge is the pad's top edge — one shared K row, not two
# parallel ones — so the bot reads as perched on the pad, not stacked on it.
# A 1px white halo is added at render time (see add_outline) so the icon
# pops off dark backgrounds like the Windows taskbar.
# ---------------------------------------------------------------------------

# 32x32 base grid. Used for every size >= 24 via nearest-neighbour upscale.
GRID = """\
................................
................................
...............AA...............
...............KK...............
...............KK...............
.........KKKKKKKKKKKKKK.........
.........KBBBBBBBBBBBBK.........
.........KBBBEEBBEEBBBK.........
.........KBBBEEBBEEBBBK.........
.........KBBBBBBBBBBBBK.........
..KKKKKKKKKKKKKKKKKKKKKKKKKKKK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KPPLLLLLLLLLLLLLLLLLLLLLPPPK..
..KPPLLLLLLLLLLLLLLLLLLLLLPPPK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KPPLLLLLLLLLLLLLLLLLLLPPPPPK..
..KPPLLLLLLLLLLLLLLLLLLLPPPPPK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KPPLLLLLLLLLLLLPPPPPPPPPPPPK..
..KPPLLLLLLLLLLLLPPPPPPPPPPPPK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KPPPPPPPPPPPPPPPPPPPPPPPPPPK..
..KKKKKKKKKKKKKKKKKKKKKKKKKKKK..
................................
................................
................................
"""

PALETTE = {
    ".": (0, 0, 0, 0),  # transparent
    "K": (0x1E, 0x1E, 0x22, 255),  # charcoal: outline + dark body
    "B": (0x2D, 0x2D, 0x34, 255),  # slate: body fill (slight depth)
    "P": (0xF3, 0xEA, 0xD0, 255),  # cream: pad paper
    "L": (0x2A, 0x5A, 0x87, 255),  # ink blue: text strokes
    "A": (0x7D, 0xD8, 0x7A, 255),  # mint green: antenna LED
    "E": (0x9B, 0xD6, 0xE1, 255),  # pale cyan: eye glow
}

# Hand-drawn 16x16 variant. A 32->16 nearest-neighbour downscale would lose
# eye separation (the two 2x2 eyes collapse into one bar) and drop the text
# strokes to single-pixel fragments. This smaller redraw keeps the design
# intent at taskbar-small-mode size: pad still dominates, bot head still
# pokes up as a tab, but everything is reduced to the essentials — single
# pixel eyes, single pixel antenna, two text strokes instead of three.
GRID_16 = """\
................
.......A........
.......K........
....KKKKKKK.....
....KEBBBEK.....
..KKKKKKKKKKKK..
..KPPPPPPPPPPK..
..KPLLLLLLLLPK..
..KPLLLLLLLLPK..
..KPPPPPPPPPPK..
..KPLLLLLPPPPK..
..KPLLLLLPPPPK..
..KPPPPPPPPPPK..
..KPPPPPPPPPPK..
..KKKKKKKKKKKK..
................
"""

# Windows .ico embeds these sizes. macOS asset catalog wants a slightly
# different set (no 24 / 48, adds 512 / 1024). Both share 16, 32, 64, 128,
# 256, so we render each size once and reuse where possible.
WIN_SIZES = [16, 24, 32, 48, 64, 128, 256]
MAC_SIZES = [16, 32, 64, 128, 256, 512, 1024]

WIN_OUTPUT = Path("windows/runner/resources/app_icon.ico")
MAC_OUTPUT_DIR = Path("macos/Runner/Assets.xcassets/AppIcon.appiconset")


def add_outline(
    img: Image.Image, color: tuple[int, int, int, int] = (255, 255, 255, 255)
) -> Image.Image:
    """Paint every transparent pixel adjacent (8-neighbour) to an opaque
    pixel with the given colour. Non-transparent pixels are not touched.

    Applied to the hand-drawn base sizes (16 and 32) before upscaling, so
    the white halo scales with the rest of the design under nearest-
    neighbour resize — 1 base pixel → 1 base pixel wide at every output
    size, matching the pixel-art aesthetic.
    """
    src = img.load()
    out = img.copy()
    dst = out.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            if src[x, y][3] != 0:
                continue
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and src[nx, ny][3] != 0:
                        dst[x, y] = color
    return out


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
                0,  # palette colour count
                0,  # reserved
                1,  # colour planes
                32,  # bits per pixel
                len(png),  # bytes in image data
                offset,  # absolute offset to image data
            )
        )
        offset += len(png)

    for png in png_data:
        out.write(png)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(out.getvalue())


def main() -> None:
    # Render and outline the two hand-drawn base sizes once.
    base_32 = add_outline(render_grid(GRID, 32))
    base_16 = add_outline(render_grid(GRID_16, 16))

    def at(size: int) -> Image.Image:
        if size == 16:
            return base_16
        return base_32.resize((size, size), Image.NEAREST)

    write_ico([at(s) for s in WIN_SIZES], WIN_OUTPUT)
    print(f"Wrote {WIN_OUTPUT} with sizes {WIN_SIZES}")

    MAC_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for s in MAC_SIZES:
        at(s).save(MAC_OUTPUT_DIR / f"app_icon_{s}.png")
    print(f"Wrote {len(MAC_SIZES)} macOS PNGs to {MAC_OUTPUT_DIR}")


if __name__ == "__main__":
    main()
