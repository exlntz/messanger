#!/usr/bin/env python3
"""Generate the VOICE iOS marketing app icon with Python stdlib only."""
from __future__ import annotations

import binascii
import json
import math
import os
import struct
import zlib
from pathlib import Path

SIZE = 1024
ROOT = Path("ios/VOICE/Assets.xcassets")
APPICON = ROOT / "AppIcon.appiconset"
PNG_PATH = APPICON / "1024.png"


def blend(dst: tuple[int, int, int, int], src: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    sr, sg, sb, sa = src
    dr, dg, db, da = dst
    a = sa / 255.0
    inv = 1.0 - a
    return (
        int(sr * a + dr * inv),
        int(sg * a + dg * inv),
        int(sb * a + db * inv),
        255,
    )


def put_px(pixels: list[list[tuple[int, int, int, int]]], x: int, y: int, color: tuple[int, int, int, int]) -> None:
    if 0 <= x < SIZE and 0 <= y < SIZE:
        pixels[y][x] = blend(pixels[y][x], color)


def draw_disc(pixels: list[list[tuple[int, int, int, int]]], cx: float, cy: float, radius: float, color: tuple[int, int, int, int]) -> None:
    r = int(math.ceil(radius))
    r2 = radius * radius
    for y in range(int(cy) - r, int(cy) + r + 1):
        for x in range(int(cx) - r, int(cx) + r + 1):
            dx = x - cx
            dy = y - cy
            d2 = dx * dx + dy * dy
            if d2 <= r2:
                edge = max(0.0, min(1.0, (radius - math.sqrt(d2)) / 2.0))
                alpha = int(color[3] * max(0.35, edge))
                put_px(pixels, x, y, (color[0], color[1], color[2], alpha))


def draw_polyline(pixels: list[list[tuple[int, int, int, int]]], points: list[tuple[float, float]], color: tuple[int, int, int, int], width: int) -> None:
    radius = width / 2.0
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        dx = x1 - x0
        dy = y1 - y0
        steps = max(1, int(max(abs(dx), abs(dy))))
        for i in range(steps + 1):
            t = i / steps
            x = x0 + dx * t
            y = y0 + dy * t
            draw_disc(pixels, x, y, radius, color)


def make_png(path: Path, pixels: list[list[tuple[int, int, int, int]]]) -> None:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", binascii.crc32(tag + data) & 0xFFFFFFFF)

    raw_rows = []
    for row in pixels:
        raw_rows.append(b"\x00" + b"".join(bytes(px) for px in row))
    raw = b"".join(raw_rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def main() -> None:
    APPICON.mkdir(parents=True, exist_ok=True)

    pixels: list[list[tuple[int, int, int, int]]] = []
    for y in range(SIZE):
        row = []
        ny = y / (SIZE - 1)
        for x in range(SIZE):
            nx = x / (SIZE - 1)
            # Deep blue to violet gradient with soft center glow.
            glow = max(0.0, 1.0 - math.hypot(nx - 0.55, ny - 0.45) * 1.35)
            r = int(18 + 82 * nx + 70 * glow)
            g = int(50 + 42 * (1 - ny) + 35 * glow)
            b = int(132 + 96 * (1 - nx) + 55 * glow)
            row.append((min(r, 255), min(g, 255), min(b, 255), 255))
        pixels.append(row)

    # Rounded safe-area shadow.
    draw_disc(pixels, SIZE * 0.50, SIZE * 0.50, 360, (40, 190, 255, 42))
    draw_disc(pixels, SIZE * 0.50, SIZE * 0.50, 260, (178, 104, 255, 52))

    # Voice waves.
    for idx, amp in enumerate([58, 94, 132, 174]):
        points = []
        for x in range(150, 875, 6):
            t = (x - 150) / 724.0
            y = 512 + math.sin(t * math.tau * 2.2 + idx * 0.72) * amp * math.sin(math.pi * t)
            points.append((x, y))
        draw_polyline(pixels, points, (235, 246, 255, 118 - idx * 10), 15 - idx)

    # Central mark, microphone capsule plus small wave core.
    draw_disc(pixels, 512, 512, 116, (255, 255, 255, 70))
    draw_disc(pixels, 512, 512, 84, (70, 210, 255, 110))
    for y in range(402, 575):
        for x in range(468, 557):
            rx = (x - 512) / 44.0
            ry = (y - 488) / 86.0
            if rx * rx + ry * ry <= 1.0:
                put_px(pixels, x, y, (255, 255, 255, 220))
    draw_polyline(pixels, [(430, 532), (430, 582), (512, 646), (594, 582), (594, 532)], (255, 255, 255, 190), 22)
    draw_polyline(pixels, [(512, 646), (512, 716)], (255, 255, 255, 190), 22)
    draw_polyline(pixels, [(446, 716), (578, 716)], (255, 255, 255, 190), 22)

    make_png(PNG_PATH, pixels)

    (ROOT / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    (APPICON / "Contents.json").write_text(
        json.dumps(
            {
                "images": [
                    {
                        "filename": "1024.png",
                        "idiom": "universal",
                        "platform": "ios",
                        "size": "1024x1024",
                    }
                ],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Generated {PNG_PATH}")


if __name__ == "__main__":
    os.chdir(Path(__file__).resolve().parents[1])
    main()
