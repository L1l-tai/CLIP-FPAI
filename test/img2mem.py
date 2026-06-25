#!/usr/bin/env python3
"""
Convert image to .mem file for resize RTL simulation.

Pixel format: {0x00, R[7:0], G[7:0], B[7:0]}
Block format: 16 pixels (64 bytes) per 128-hex-char line
"""

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Error: Pillow required. Install: pip install Pillow")
    sys.exit(1)


def image_to_mem(img_path: str, mem_path: str, width: int, height: int):
    """Resize image to WxH and write .mem file for RTL simulation."""

    img = Image.open(img_path).convert("RGB")
    img = img.resize((width, height), Image.BILINEAR)

    blocks_per_row = (width + 15) // 16  # 16 pixels per 64-byte block
    pixels = img.load()

    with open(mem_path, "w") as f:
        for row in range(height):
            for block in range(blocks_per_row):
                # Build 64-byte block: 16 pixels × 4 bytes
                block_bytes = bytearray(64)
                for px in range(16):
                    col = block * 16 + px
                    if col < width:
                        r, g, b = pixels[col, row]
                        off = px * 4
                        # RTL input order: [B, G, R, X]
                        # [7:0]=B, [15:8]=G, [23:16]=R
                        block_bytes[off + 0] = b      # B
                        block_bytes[off + 1] = g      # G
                        block_bytes[off + 2] = r      # R
                        block_bytes[off + 3] = 0x00   # X
                # Reverse bytes to match C++ write_mem_file:
                # write_mem_file writes buf[63], buf[62], ..., buf[0] in order.
                # Byte reversal within each pixel is correct: [B,R,G,X]→[X,G,R,B]
                block_bytes.reverse()
                f.write(block_bytes.hex() + "\n")

    total_blocks = height * blocks_per_row
    print(f"Wrote {total_blocks} blocks ({width}x{height}) to {mem_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Convert image to .mem file for resize RTL")
    parser.add_argument("image", help="Input image path")
    parser.add_argument("--width", type=int, default=640,
                        help="Target width (default: 640)")
    parser.add_argument("--height", type=int, default=480,
                        help="Target height (default: 480)")
    parser.add_argument("--output", "-o", default=None,
                        help="Output .mem path (default: test/input-data/resize-input-WxH.mem)")
    args = parser.parse_args()

    if args.output is None:
        script_dir = Path(__file__).parent
        args.output = script_dir / "input-data" / f"resize-input-{args.width}x{args.height}.mem"

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    image_to_mem(args.image, str(args.output), args.width, args.height)


if __name__ == "__main__":
    main()
