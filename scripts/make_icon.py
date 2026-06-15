#!/usr/bin/env python3
"""Generate a placeholder app icon (1024x1024 PNG) with stdlib only.

Dark navy background with a bold green "priority" chevron. Replace with a
real icon whenever one exists.
"""
import struct
import zlib

SIZE = 1024
BG = (11, 31, 58)       # navy
FG = (46, 204, 113)     # green chevron


def in_chevron(x, y):
    cx = SIZE / 2
    # two stacked upward chevrons
    thickness = SIZE * 0.13
    for y_off in (SIZE * 0.0, SIZE * 0.24):
        apex_y = SIZE * 0.22 + y_off
        dist = abs(x - cx)
        edge = apex_y + dist * 0.9
        if edge <= y <= edge + thickness and dist <= SIZE * 0.34:
            return True
    return False


def build():
    rows = bytearray()
    for y in range(SIZE):
        rows.append(0)  # filter type 0
        for x in range(SIZE):
            r, g, b = FG if in_chevron(x, y) else BG
            rows += bytes((r, g, b))
    return bytes(rows)


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def main():
    raw = build()
    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open("icon.png", "wb") as f:
        f.write(png)
    print(f"wrote icon.png ({len(png)} bytes)")


if __name__ == "__main__":
    main()
