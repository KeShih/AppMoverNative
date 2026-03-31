#!/usr/bin/env python3

from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
PACKAGING_DIR = ROOT / "Packaging"
MASTER_PNG = PACKAGING_DIR / "AppIcon-1024.png"
ICONSET_DIR = PACKAGING_DIR / "AppIcon.iconset"
SIZE = 1024


def rgba(hex_value: str, alpha: int = 255) -> tuple[int, int, int, int]:
    value = hex_value.lstrip("#")
    return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4)) + (alpha,)


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int, int], bottom: tuple[int, int, int, int]) -> Image.Image:
    width, height = size
    image = Image.new("RGBA", size)
    draw = ImageDraw.Draw(image)
    for y in range(height):
        mix = y / max(height - 1, 1)
        color = tuple(
            round(top[channel] + (bottom[channel] - top[channel]) * mix)
            for channel in range(4)
        )
        draw.line((0, y, width, y), fill=color)
    return image


def add_shadow(
    canvas: Image.Image,
    bbox: tuple[int, int, int, int],
    radius: int,
    fill: tuple[int, int, int, int],
    blur: int,
    offset: tuple[int, int],
) -> None:
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    shifted = (
        bbox[0] + offset[0],
        bbox[1] + offset[1],
        bbox[2] + offset[0],
        bbox[3] + offset[1],
    )
    draw.rounded_rectangle(shifted, radius=radius, fill=fill)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))


def add_polygon_shadow(
    canvas: Image.Image,
    points: list[tuple[int, int]],
    fill: tuple[int, int, int, int],
    blur: int,
    offset: tuple[int, int],
) -> None:
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    shifted = [(x + offset[0], y + offset[1]) for x, y in points]
    draw.polygon(shifted, fill=fill)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))


def rounded_gradient_box(
    canvas: Image.Image,
    bbox: tuple[int, int, int, int],
    radius: int,
    top: tuple[int, int, int, int],
    bottom: tuple[int, int, int, int],
    border: tuple[int, int, int, int] | None = None,
    border_width: int = 2,
) -> None:
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    gradient = vertical_gradient((width, height), top, bottom)
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width, height), radius=radius, fill=255)
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    layer.paste(gradient, bbox[:2], mask)
    canvas.alpha_composite(layer)
    if border:
        ImageDraw.Draw(canvas).rounded_rectangle(bbox, radius=radius, outline=border, width=border_width)


def draw_app_tile(canvas: Image.Image) -> None:
    tile_box = (168, 176, 548, 556)
    add_shadow(canvas, tile_box, radius=100, fill=(45, 58, 78, 56), blur=28, offset=(0, 18))
    rounded_gradient_box(
        canvas,
        tile_box,
        radius=100,
        top=rgba("#FFFFFF", 242),
        bottom=rgba("#E8EEF7", 252),
        border=rgba("#FFFFFF", 210),
        border_width=3,
    )

    top_sheen = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sheen_draw = ImageDraw.Draw(top_sheen)
    sheen_draw.ellipse((126, 112, 520, 320), fill=(255, 255, 255, 72))
    canvas.alpha_composite(top_sheen.filter(ImageFilter.GaussianBlur(12)))

    grid_colors = [
        rgba("#5E84FF"),
        rgba("#6FA4FF"),
        rgba("#60C0B2"),
        rgba("#B8C4D9"),
    ]
    start_x = 242
    start_y = 250
    gap = 28
    cell = 98
    index = 0
    draw = ImageDraw.Draw(canvas)
    for row in range(2):
        for column in range(2):
            x0 = start_x + column * (cell + gap)
            y0 = start_y + row * (cell + gap)
            x1 = x0 + cell
            y1 = y0 + cell
            add_shadow(canvas, (x0, y0, x1, y1), radius=28, fill=(48, 60, 78, 28), blur=10, offset=(0, 6))
            draw.rounded_rectangle((x0, y0, x1, y1), radius=28, fill=grid_colors[index], outline=(255, 255, 255, 52), width=2)
            index += 1


def arrow_head_points(tip: tuple[int, int], angle: float, length: float, width: float) -> list[tuple[int, int]]:
    back_x = tip[0] - math.cos(angle) * length
    back_y = tip[1] - math.sin(angle) * length
    perp_x = math.sin(angle) * width
    perp_y = -math.cos(angle) * width
    return [
        (round(tip[0]), round(tip[1])),
        (round(back_x + perp_x), round(back_y + perp_y)),
        (round(back_x - perp_x), round(back_y - perp_y)),
    ]


def draw_arrow(canvas: Image.Image) -> None:
    points = [(520, 420), (610, 500), (706, 552)]
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_points = [(x, y + 10) for x, y in points]
    shadow_draw.line(shadow_points, fill=(42, 56, 78, 64), width=74, joint="curve")
    shadow_head = arrow_head_points((756, 578), math.radians(27), length=92, width=46)
    shadow_head = [(x, y + 10) for x, y in shadow_head]
    shadow_draw.polygon(shadow_head, fill=(42, 56, 78, 64))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(20)))

    accent = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    accent_draw = ImageDraw.Draw(accent)
    accent_draw.line(points, fill=rgba("#5B86FF"), width=66, joint="curve")
    accent_head = arrow_head_points((756, 578), math.radians(27), length=92, width=46)
    accent_draw.polygon(accent_head, fill=rgba("#5B86FF"))
    accent_draw.line(points, fill=rgba("#AFC5FF", 180), width=22, joint="curve")
    canvas.alpha_composite(accent)


def draw_drive(canvas: Image.Image) -> None:
    drive_box = (492, 612, 874, 790)
    add_shadow(canvas, drive_box, radius=62, fill=(43, 57, 78, 60), blur=30, offset=(0, 18))
    rounded_gradient_box(
        canvas,
        drive_box,
        radius=62,
        top=rgba("#FFFFFF", 248),
        bottom=rgba("#DCE4EF", 252),
        border=rgba("#FFFFFF", 205),
        border_width=3,
    )

    highlight = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    highlight_draw = ImageDraw.Draw(highlight)
    highlight_draw.ellipse((504, 588, 848, 696), fill=(255, 255, 255, 70))
    canvas.alpha_composite(highlight.filter(ImageFilter.GaussianBlur(12)))

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((572, 646, 798, 662), radius=8, fill=rgba("#A7B3C8", 170))
    draw.rounded_rectangle((540, 718, 826, 736), radius=9, fill=rgba("#BAC5D7", 120))
    draw.rounded_rectangle((780, 708, 822, 738), radius=14, fill=rgba("#FF9459"))
    draw.rounded_rectangle((608, 704, 750, 720), radius=8, fill=rgba("#EDF2F8", 210))


def build_master_icon() -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    base_box = (90, 90, 934, 934)
    add_shadow(canvas, base_box, radius=214, fill=(34, 44, 62, 72), blur=40, offset=(0, 24))
    rounded_gradient_box(
        canvas,
        base_box,
        radius=214,
        top=rgba("#F4F7FB"),
        bottom=rgba("#D8E0EB"),
        border=rgba("#FFFFFF", 204),
        border_width=4,
    )

    atmosphere = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    atmosphere_draw = ImageDraw.Draw(atmosphere)
    atmosphere_draw.ellipse((34, -30, 786, 468), fill=(255, 255, 255, 76))
    atmosphere_draw.ellipse((430, 600, 982, 986), fill=(255, 161, 109, 22))
    atmosphere_draw.ellipse((40, 640, 520, 980), fill=(105, 145, 255, 18))
    canvas.alpha_composite(atmosphere.filter(ImageFilter.GaussianBlur(18)))

    draw_app_tile(canvas)
    draw_arrow(canvas)
    draw_drive(canvas)

    inner_border = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(inner_border).rounded_rectangle(base_box, radius=214, outline=(255, 255, 255, 48), width=1)
    canvas.alpha_composite(inner_border)
    return canvas


def save_iconset(master: Image.Image) -> None:
    if ICONSET_DIR.exists():
        shutil.rmtree(ICONSET_DIR)
    ICONSET_DIR.mkdir(parents=True, exist_ok=True)

    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for filename, size in sizes:
        output = ICONSET_DIR / filename
        if size == SIZE:
            shutil.copyfile(MASTER_PNG, output)
            continue
        subprocess.run(
            ["sips", "-z", str(size), str(size), str(MASTER_PNG), "--out", str(output)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def main() -> None:
    PACKAGING_DIR.mkdir(parents=True, exist_ok=True)
    master = build_master_icon()
    master.save(MASTER_PNG)
    save_iconset(master)
    print(f"Generated {MASTER_PNG}")
    print(f"Generated {ICONSET_DIR}")


if __name__ == "__main__":
    main()
