#!/usr/bin/env python3
"""Writes every FPRemote icon the FashionPoint builds ship, from mark.svg (Vesko's mark, 14.10.2026).

Needs cairosvg and Pillow (pip install cairosvg pillow). Run from anywhere:
    python3 res/fashionpoint/icon/make-icons.py
For a new version of the mark, replace mark.svg, run this again and commit what it writes.

The mark is a ring with a dot. Where it stands on whatever background the system has (Windows taskbar and
tray, the app's own windows), the inside of the ring is white, so a dark taskbar does not swallow it. On
macOS and Android it sits on a white plate. The macOS menu bar template and the Android notification icon
take ring and dot as one silhouette. Sizes and margins follow the RustDesk icons these files replace.
"""
import io
import math
import re
import struct
import xml.etree.ElementTree as ET
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SVG = "{http://www.w3.org/2000/svg}"
ANDROID = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
WINDOWS_SIZES = [16, 20, 24, 32, 40, 48, 64, 256]
ON_PLATE = 0.77  # ring / plate, as on Vesko's 1024 px PNG (790 px)
MAC_PLATE = 824 / 1024  # Apple's icon grid
FOREGROUND = ON_PLATE * 72 / 108  # Android adaptive icon: a launcher shows the inner 72dp of the 108dp layer


def read_mark():
    root = ET.parse(HERE / "mark.svg").getroot()
    styles = "".join(s.text or "" for s in root.iter(f"{SVG}style"))
    classes = dict(re.findall(r"\.([\w-]+)\s*\{[^}]*?fill:\s*(#[0-9a-fA-F]{3,8})", styles))
    paths = [(p.get("d"), p.get("fill") or classes[p.get("class")]) for p in root.iter(f"{SVG}path")]
    return [float(v) for v in root.get("viewBox").split()], paths


VIEWBOX, PATHS = read_mark()


def document(parts, viewbox):
    box = " ".join(f"{v:.3f}" for v in viewbox)
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{box}">{"".join(parts)}</svg>'


def render(parts, size, viewbox=VIEWBOX):
    data = cairosvg.svg2png(bytestring=document(parts, viewbox).encode(), output_width=size, output_height=size)
    return Image.open(io.BytesIO(data)).convert("RGBA")


def path(d, fill):
    return f'<path d="{d}" fill="{fill}"/>'


def ring_geometry(px=2048):
    """Centre and outer/inner radius of the ring (the largest path), in mark units."""
    scale = VIEWBOX[2] / px
    best = None
    for d, _ in PATHS:
        alpha = render([path(d, "#000")], px).getchannel("A")
        left, top, right, bottom = alpha.point(lambda a: 255 if a > 127 else 0).getbbox()
        if best is None or right - left > best[1][2] - best[1][0]:
            best = (alpha, (left, top, right, bottom))
    alpha, (left, top, right, bottom) = best
    cx, cy = (left + right) // 2, (top + bottom) // 2
    x = cx
    while alpha.getpixel((x, cy)) < 128:  # from the centre to the inner edge of the ring
        x -= 1
    to_units = lambda v, origin: origin + v * scale
    return (to_units((left + right) / 2, VIEWBOX[0]), to_units((top + bottom) / 2, VIEWBOX[1]),
            (right - left) / 2 * scale, (cx - x) * scale)


CX, CY, R_OUT, R_IN = ring_geometry()
COLOUR = [path(d, fill) for d, fill in PATHS]
# White inside the ring; the disc ends in the middle of the ring, so its edge stays under the black.
FILLED = [f'<circle cx="{CX:.2f}" cy="{CY:.2f}" r="{(R_IN + R_OUT) / 2:.2f}" fill="#ffffff"/>'] + COLOUR


def silhouette(colour):
    return [path(d, colour) for d, _ in PATHS]


def mark(parts, size, fraction):
    """The mark centred on a transparent square of `size` px, the ring `fraction` of its width."""
    side = 2 * R_OUT / fraction
    return render(parts, size, (CX - side / 2, CY - side / 2, side, side))


def superellipse(draw, centre, half, n=5.0, steps=2048):
    points = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        points.append((centre + half * math.copysign(abs(c) ** (2 / n), c),
                       centre + half * math.copysign(abs(s) ** (2 / n), s)))
    draw.polygon(points, fill=255)


def plate(size, shape, plate_fraction, mark_fraction, shadow):
    """The mark on a white plate (squircle or circle) with a soft shadow, on a transparent square."""
    big = size * 4
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    half = plate_fraction * big / 2
    if shape == "circle":
        draw.ellipse((big / 2 - half, big / 2 - half, big / 2 + half, big / 2 + half), fill=255)
    else:
        superellipse(draw, big / 2, half)
    mask = mask.resize((size, size), Image.LANCZOS)
    offset, blur, opacity = shadow  # fractions of size, opacity 0..1
    shade = Image.new("L", (size, size), 0)
    shade.paste(mask, (0, round(offset * size)))
    shade = shade.filter(ImageFilter.GaussianBlur(blur * size)).point(lambda v: round(v * opacity))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.putalpha(shade)
    light = Image.linear_gradient("L").resize((size, size)).point(lambda v: 255 - v * 10 // 255)
    out = Image.alpha_composite(out, Image.merge("RGBA", (light, light, light, mask)))
    return Image.alpha_composite(out, mark(COLOUR, size, mark_fraction * plate_fraction))


def shrink(image, size):
    return image.convert("RGBa").resize((size, size), Image.LANCZOS).convert("RGBA")


def png_bytes(image):
    buf = io.BytesIO()
    image.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def bmp32(image):
    """An ICO entry as 32 bpp BMP (XOR pixels bottom-up, then the AND mask), as in RustDesk's icons."""
    w, h = image.size
    flipped = image.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    row = (w + 31) // 32 * 4
    mask = bytearray(row * h)
    alpha = flipped.getchannel("A").load()
    for y in range(h):
        for x in range(w):
            if alpha[x, y] == 0:
                mask[y * row + x // 8] |= 0x80 >> (x % 8)
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    return header + flipped.tobytes("raw", "BGRA") + bytes(mask)


def write_ico(rel, images):
    blobs = [png_bytes(im) if im.width >= 256 else bmp32(im) for im in images]
    out = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    for im, blob in zip(images, blobs):
        out += struct.pack("<BBBBHHII", im.width % 256, im.height % 256, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    write(rel, out + b"".join(blobs))


def write_icns(rel, master):
    entries = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256),
               ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
    body = b""
    for kind, size in entries:
        blob = png_bytes(master if size == master.width else shrink(master, size))
        body += kind.encode() + struct.pack(">I", len(blob) + 8) + blob
    write(rel, b"icns" + struct.pack(">I", len(body) + 8) + body)


def write(rel, data):
    (ROOT / rel).write_bytes(data)
    print(f"{len(data):>8}  {rel}")


def main():
    windows = [mark(FILLED, size, 1.0) for size in WINDOWS_SIZES]
    write_ico("flutter/windows/runner/resources/app_icon.ico", windows)  # FPRemote.exe: taskbar, windows, shortcuts
    write_ico("res/icon.ico", windows)  # the installer exe (libs/portable/build.rs); librustdesk.dll has none
    write_ico("res/tray-icon.ico", [mark(FILLED, 32, 1.0)])  # tray; the image crate reads one entry
    write("flutter/assets/icon.svg", (document(FILLED, VIEWBOX) + "\n").encode())  # in the app, e.g. the panel
    write("res/icon.png", png_bytes(mark(FILLED, 1024, 1.0)))  # flutter_launcher_icons source (pubspec)

    mac = plate(1024, "squircle", MAC_PLATE, ON_PLATE, (10 / 1024, 12 / 1024, 0.30))
    write_icns("flutter/macos/Runner/AppIcon.icns", mac)
    write("res/mac-icon.png", png_bytes(mac))  # flutter_launcher_icons source for macOS
    # Menu bar, used as a template (only alpha counts); sizes and margins as RustDesk's.
    write("res/mac-tray-dark-x2.png", png_bytes(mark(silhouette("#000000"), 60, 48 / 60)))
    write("res/mac-tray-light-x2.png", png_bytes(mark(silhouette("#000000"), 48, 1.0)))

    for density, k in ANDROID.items():
        folder = f"flutter/android/app/src/main/res/mipmap-{density}/"
        write(folder + "ic_launcher_foreground.png", png_bytes(mark(COLOUR, round(108 * k), FOREGROUND)))
        write(folder + "ic_launcher.png",
              png_bytes(plate(round(48 * k), "squircle", 0.80, ON_PLATE, (0.02, 0.02, 0.30))))
        write(folder + "ic_launcher_round.png",
              png_bytes(plate(round(48 * k), "circle", 0.88, ON_PLATE, (0.02, 0.02, 0.30))))
        write(folder + "ic_stat_logo.png", png_bytes(mark(silhouette("#ffffff"), round(24 * k), 22 / 24)))


if __name__ == "__main__":
    main()
