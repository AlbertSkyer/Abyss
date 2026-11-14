"""Build the app's shared PNG and Windows ICO artwork from a square source image.

Usage:
  python tool/make_app_icons.py <source-image>
"""
import io
import os
import struct
import sys

from PIL import Image

SIZES = (16, 24, 32, 48, 64, 128, 256)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def square(image):
    size = min(image.size)
    left = (image.width - size) // 2
    top = (image.height - size) // 2
    return image.crop((left, top, left + size, top + size)).convert("RGBA")


def encode_png(image, size):
    output = io.BytesIO()
    image.resize((size, size), Image.Resampling.LANCZOS).save(
        output, format="PNG", optimize=True
    )
    return output.getvalue()


def write_ico(image, path):
    frames = [encode_png(image, size) for size in SIZES]
    offset = 6 + 16 * len(frames)
    directory = struct.pack("<HHH", 0, 1, len(frames))
    for size, frame in zip(SIZES, frames):
        directory += struct.pack(
            "<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(frame), offset
        )
        offset += len(frame)
    with open(path, "wb") as output:
        output.write(directory + b"".join(frames))


def main(source):
    image = square(Image.open(source))
    branding = os.path.join(ROOT, "assets", "branding", "app_icon.png")
    image.resize((128, 128), Image.Resampling.LANCZOS).save(branding, format="PNG", optimize=True)
    write_ico(image, os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico"))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python tool/make_app_icons.py <source-image>")
    main(sys.argv[1])
