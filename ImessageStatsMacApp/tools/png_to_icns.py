#!/usr/bin/env python3
"""
Create a macOS .icns file from a single PNG.

We avoid relying on iconutil's iconset->icns conversion, which is flaky on some
systems/tooling environments. Instead we:
1) Use sips to render canonical PNG sizes into a temp dir.
2) Pack those PNGs into an ICNS container (modern ICNS stores PNG payloads).

Refs (type codes):
  icp4: 16x16
  icp5: 32x32
  icp6: 64x64
  ic07: 128x128
  ic08: 256x256
  ic09: 512x512
  ic10: 1024x1024
"""

from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


ICNS_PARTS: list[tuple[str, int]] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
]


def run(cmd: list[str]) -> None:
    subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def build_icns(input_png: Path, output_icns: Path) -> None:
    if not input_png.exists():
        raise FileNotFoundError(f"Input PNG not found: {input_png}")

    tmpdir = Path(tempfile.mkdtemp(prefix="png_to_icns_"))
    try:
        # Render sizes
        rendered: dict[int, Path] = {}
        for _, size in ICNS_PARTS:
            out = tmpdir / f"icon_{size}x{size}.png"
            run(["sips", "-z", str(size), str(size), str(input_png), "--out", str(out)])
            rendered[size] = out

        # Pack ICNS
        parts_bytes = bytearray()
        for type_code, size in ICNS_PARTS:
            data = rendered[size].read_bytes()
            parts_bytes += type_code.encode("ascii")
            parts_bytes += struct.pack(">I", 8 + len(data))
            parts_bytes += data

        blob = bytearray()
        blob += b"icns"
        blob += struct.pack(">I", 8 + len(parts_bytes))
        blob += parts_bytes

        output_icns.parent.mkdir(parents=True, exist_ok=True)
        output_icns.write_bytes(blob)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("Usage: png_to_icns.py <input.png> <output.icns>", file=sys.stderr)
        return 2

    input_png = Path(argv[1]).expanduser()
    output_icns = Path(argv[2]).expanduser()

    try:
        build_icns(input_png, output_icns)
    except Exception as e:
        print(f"Failed to create icns: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

