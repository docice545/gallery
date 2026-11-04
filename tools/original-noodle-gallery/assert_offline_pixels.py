#!/usr/bin/env python3
"""Require decoded fixture pixels inside Photos, not just colorful app chrome."""

import argparse
from pathlib import Path
import subprocess

# Paired, deliberately distinctive marks in the synthetic CI photo. A grey
# placeholder, blurhash, toolbar, date or bottom navigation cannot satisfy both.
MARKS = ((240, 26, 194), (25, 210, 138))


def check_pixels(width: int, height: int, pixels: bytes) -> list[int]:
    if width < 100 or height < 100 or width * height > 8_000_000:
        raise ValueError('unexpected screenshot dimensions')
    if len(pixels) != width * height * 3:
        raise ValueError('truncated RGB screenshot')
    counts = [0, 0]
    # Exclude system/app bars and bottom navigation. The detector checks the
    # actual photo area and demands contiguous marker pixels, not global color
    # diversity or an accessible date heading.
    for y in range(height // 5, height * 4 // 5 - 2):
        for x in range(width // 20, width * 19 // 20 - 2):
            at = (y * width + x) * 3
            for index, mark in enumerate(MARKS):
                if all(abs(pixels[at + c] - mark[c]) <= 12 for c in range(3)):
                    if all(
                        abs(pixels[((y + dy) * width + x + dx) * 3 + c] - mark[c]) <= 12
                        for dy in range(3) for dx in range(3) for c in range(3)
                    ):
                        counts[index] += 1
    if min(counts) < 40:
        raise ValueError(f'decoded photo markers missing in Timeline: {counts}')
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('screenshot', type=Path)
    args = parser.parse_args()
    dimensions = subprocess.check_output(['identify', '-format', '%w %h', str(args.screenshot)], text=True)
    width, height = map(int, dimensions.split())
    if width * height > 8_000_000:
        raise SystemExit('oversized screenshot refused')
    pixels = subprocess.check_output(['convert', str(args.screenshot), '-alpha', 'off', '-depth', '8', 'rgb:-'])
    counts = check_pixels(width, height, pixels)
    print(f'PASS decoded Timeline photo markers: {counts}')


if __name__ == '__main__':
    main()
