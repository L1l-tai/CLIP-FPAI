"""
Visualize .txt/.mem data files as RGB images.

Pixel format: {8'b0, R[7:0], G[7:0], B[7:0]} = 32-bit per pixel.
Data layout: one 512-bit block per line (128 hex chars) = 16 pixels per block.
Multi-block rows: width > 16 uses ceil(width/16) blocks per row.

Usage:
    python visualize_data.py --file ../input-data/resize-input-src.txt --width 64 --height 48
    python visualize_data.py --file ../input-data/resize-input-src.txt -W 64 -H 48 -o output.png
    python visualize_data.py --file ../output-data/expect/gather-expected.txt -W 8 -H 20
"""

import sys
import os
import argparse
import numpy as np
from PIL import Image

PIXELS_PER_BLOCK = 16


def read_blocks(filepath: str) -> list:
    """Read 512-bit hex blocks from file. Returns list of int."""
    blocks = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                blocks.append(int(line, 16))
    return blocks


def blocks_to_image(blocks: list, width: int, is_input: bool = False) -> np.ndarray:
    """
    Convert list of 512-bit blocks → RGB image (H×W×3, uint8).

    .mem format (write_mem_file): buf[63] at hex[0:1], buf[0] at hex[126:127].
    So int(line,16) has pixel 0 at LSB. Read via blk >> (i*32).

    Input format  {X, G, R, B}: R at [15:8], G at [23:16], B at [7:0]
    Output format {0, R, G, B}: R at [23:16], G at [15:8], B at [7:0]
    """
    blocks_per_row = (width + PIXELS_PER_BLOCK - 1) // PIXELS_PER_BLOCK
    height = len(blocks) // blocks_per_row
    if len(blocks) % blocks_per_row != 0:
        print(f"WARNING: {len(blocks)} blocks not evenly divisible by "
              f"{blocks_per_row} blocks/row (width={width})")
        height = len(blocks) // blocks_per_row

    img = np.zeros((height, width, 3), dtype=np.uint8)
    for row in range(height):
        for b in range(blocks_per_row):
            blk = blocks[row * blocks_per_row + b]
            col_start = b * PIXELS_PER_BLOCK
            for i in range(PIXELS_PER_BLOCK):
                col = col_start + i
                if col >= width:
                    break
                px = (blk >> (i * 32)) & 0xFFFFFFFF
                # Input DDR [B,G,R,X] and output DDR [B,G,R,0] both map to
                # hex {X,R,G,B} per pixel → R=[23:16], G=[15:8], B=[7:0]
                img[row, col, 0] = (px >> 16) & 0xFF   # R
                img[row, col, 1] = (px >> 8) & 0xFF    # G
                img[row, col, 2] = px & 0xFF            # B
    return img


def main():
    parser = argparse.ArgumentParser(
        description="Visualize .txt/.mem data as RGB image")
    parser.add_argument('--file', '-f', required=True,
                        help='Input .txt or .mem file path')
    parser.add_argument('--width', '-W', type=int, required=True,
                        help='Image width in pixels')
    parser.add_argument('--height', '-H', type=int, default=None,
                        help='Image height in pixels (auto-detect if not given)')
    parser.add_argument('--output', '-o', default=None,
                        help='Save to image file (otherwise display window)')
    parser.add_argument('--input', action='store_true',
                        help='File is RTL input format (R/G swapped vs output)')
    args = parser.parse_args()

    # Read data
    blocks = read_blocks(args.file)
    print(f"Read {len(blocks)} blocks from {args.file}")

    # Determine dimensions
    width = args.width
    blocks_per_row = (width + PIXELS_PER_BLOCK - 1) // PIXELS_PER_BLOCK
    if args.height:
        height = args.height
        expected = height * blocks_per_row
        if len(blocks) != expected:
            print(f"WARNING: {len(blocks)} blocks, expected {expected} "
                  f"({height} rows × {blocks_per_row} blocks/row)")
    else:
        height = len(blocks) // blocks_per_row
        print(f"Auto height: {height} rows ({blocks_per_row} blocks/row)")

    # Convert to image
    img = blocks_to_image(blocks, width, is_input=args.input)
    img = img[:height, :width, :]  # trim to exact dimensions
    print(f"Image: {img.shape[1]}×{img.shape[0]}, "
          f"R range [{img[:,:,0].min()},{img[:,:,0].max()}], "
          f"G range [{img[:,:,1].min()},{img[:,:,1].max()}], "
          f"B range [{img[:,:,2].min()},{img[:,:,2].max()}]")

    if args.output:
        Image.fromarray(img).save(args.output)
        print(f"Saved to {args.output}")
    else:
        Image.fromarray(img).show()
        print("Displayed image window.")


if __name__ == "__main__":
    main()
