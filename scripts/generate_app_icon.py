#!/usr/bin/env python3

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
PACKAGING_DIR = ROOT / "Packaging"
SOURCE_PNG = PACKAGING_DIR / "AppIcon-source.png"
MASTER_PNG = PACKAGING_DIR / "AppIcon-1024.png"
ICONSET_DIR = PACKAGING_DIR / "AppIcon.iconset"
SIZE = 1024


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    return mask


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




def red_alpha_mask(image: Image.Image) -> Image.Image:
    rgba_image = image.convert("RGBA")
    width, height = rgba_image.size
    source_pixels = rgba_image.load()
    mask = Image.new("L", rgba_image.size, 0)
    mask_pixels = mask.load()

    for y in range(height):
        for x in range(width):
            r, g, b, a = source_pixels[x, y]
            dominance = r - max(g, b)
            if dominance <= 14 or a == 0:
                continue
            value = max(0, min(255, int((dominance - 14) * 4.4)))
            mask_pixels[x, y] = min(a, value)

    return mask


def inset_bbox(
    bbox: tuple[int, int, int, int],
    image_size: tuple[int, int],
    padding: int,
) -> tuple[int, int, int, int]:
    left, top, right, bottom = bbox
    width, height = image_size
    return (
        max(0, left - padding),
        max(0, top - padding),
        min(width, right + padding),
        min(height, bottom + padding),
    )


def extract_arrow_layer() -> Image.Image:
    with Image.open(SOURCE_PNG) as source_image:
        source = source_image.convert("RGBA")
        mask = red_alpha_mask(source)
        bbox = mask.getbbox()
        if bbox is None:
            raise ValueError("Could not detect red arrow content in source icon.")

        crop_box = inset_bbox(bbox, source.size, padding=22)
        cropped_source = source.crop(crop_box)
        cropped_mask = mask.crop(crop_box)

        arrow = Image.new("RGBA", cropped_source.size, (0, 0, 0, 0))
        arrow.paste(cropped_source, (0, 0), cropped_mask)
        return arrow


def build_master_png() -> Image.Image:
    arrow = extract_arrow_layer()

    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    base_box = (96, 96, 928, 928)
    base_radius = 192
    add_shadow(canvas, base_box, base_radius, fill=(12, 12, 16, 60), blur=34, offset=(0, 22))
    add_shadow(canvas, base_box, base_radius, fill=(255, 255, 255, 18), blur=10, offset=(0, -2))

    box_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(box_layer).rounded_rectangle(base_box, radius=base_radius, fill=(255, 255, 255, 255))
    canvas.alpha_composite(box_layer)

    stroke = ImageDraw.Draw(canvas)
    stroke.rounded_rectangle(base_box, radius=base_radius, outline=(255, 255, 255, 190), width=2)
    stroke.rounded_rectangle(
        (base_box[0] + 2, base_box[1] + 2, base_box[2] - 2, base_box[3] - 2),
        radius=base_radius - 2,
        outline=(228, 230, 234, 255),
        width=1,
    )

    target_width = 740
    scale = target_width / arrow.width
    resized_arrow = arrow.resize(
        (
            max(1, round(arrow.width * scale)),
            max(1, round(arrow.height * scale)),
        ),
        Image.Resampling.LANCZOS,
    )
    arrow_offset = (
        (SIZE - resized_arrow.width) // 2,
        (SIZE - resized_arrow.height) // 2 + 2,
    )

    arrow_shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_body = Image.new("RGBA", resized_arrow.size, (0, 0, 0, 52))
    arrow_shadow.paste(shadow_body, (arrow_offset[0], arrow_offset[1] + 8), resized_arrow.split()[-1])
    canvas.alpha_composite(arrow_shadow.filter(ImageFilter.GaussianBlur(12)))

    canvas.alpha_composite(resized_arrow, arrow_offset)
    return canvas


def ensure_master_png() -> None:
    if not SOURCE_PNG.exists():
        raise FileNotFoundError(f"Missing source icon: {SOURCE_PNG}")

    master = build_master_png()
    master.save(MASTER_PNG)


def save_iconset() -> None:
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
    ensure_master_png()
    save_iconset()
    print(f"Generated {MASTER_PNG}")
    print(f"Generated {ICONSET_DIR}")


if __name__ == "__main__":
    main()
