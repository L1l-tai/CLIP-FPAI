"""
Generate Resize/Crop test data for RTL testbench and golden model verification.

Pixel format: {8'b0, R[7:0], G[7:0], B[7:0]} = 32-bit per pixel
Each 512-bit block = 16 pixels per row (RS_WIDTH=1 in RTL).
Max source width = 16 pixels.

Usage:
    python generate_resize_input.py                     # gradient image, default params
    python generate_resize_input.py --src 16x12 --dst 8x8 --crop  # center crop test
    python generate_resize_input.py --load image.mem    # load external image data
"""

import sys
import os
import argparse
import random

# Default parameters (matching resize_sim.sv)
SRC_WIDTH = 64
SRC_HEIGHT = 48          # non-square to test center crop
DST_WIDTH = 32
DST_HEIGHT = 32
CROP_ENABLE = 1
DEFAULT_SEED = 42

SRC_BASE_ADDR = 0x0000_2000
DST_BASE_ADDR = 0x0001_0000
BYTES_PER_BLOCK = 64
PIXELS_PER_BLOCK = 16


def gen_gradient_image(width: int, height: int) -> list:
    """
    Generate gradient test image.
    R = x * 4, G = y * 5, B = (x + y) * 3
    Each row = ceil(width/16) blocks, row-major layout.
    Returns list of 512-bit blocks.
    """
    blocks = []
    blocks_per_row = (width + PIXELS_PER_BLOCK - 1) // PIXELS_PER_BLOCK
    for y in range(height):
        for blk_idx in range(blocks_per_row):
            pixels = [0] * PIXELS_PER_BLOCK
            for i in range(PIXELS_PER_BLOCK):
                x = blk_idx * PIXELS_PER_BLOCK + i
                if x < width:
                    r = int(x * 255 / max(width - 1, 1))
                    g = int(y * 255 / max(height - 1, 1))
                    blue = int((x + y) * 255 / max(width + height - 2, 1))
                    pixels[i] = (r << 16) | (g << 8) | blue
            blk = 0
            for i, px in enumerate(pixels):
                blk |= (px & 0xFFFFFFFF) << (i * 32)
            blocks.append(blk)
    return blocks


def gen_random_image(width: int, height: int, seed: int = DEFAULT_SEED) -> list:
    """Generate random test image."""
    rng = random.Random(seed)
    blocks = []
    blocks_per_row = (width + PIXELS_PER_BLOCK - 1) // PIXELS_PER_BLOCK
    for _ in range(height):
        for _ in range(blocks_per_row):
            pixels = [0] * PIXELS_PER_BLOCK
            for i in range(PIXELS_PER_BLOCK):
                rr = rng.randint(0, 255)
                gg = rng.randint(0, 255)
                bb = rng.randint(0, 255)
                pixels[i] = (rr << 16) | (gg << 8) | bb
            blk = 0
            for i, px in enumerate(pixels):
                blk |= (px & 0xFFFFFFFF) << (i * 32)
            blocks.append(blk)
    return blocks


def load_external_blocks(filepath: str) -> list:
    """Load blocks from an external .mem/.txt hex file."""
    blocks = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                blocks.append(int(line, 16))
    return blocks


def write_blocks(filename: str, blocks: list):
    """Write blocks to pure hex file."""
    with open(filename, 'w') as f:
        for blk in blocks:
            f.write(f"{blk:0128x}\n")
    print(f"Wrote {len(blocks)} blocks to {filename}")


def main():
    parser = argparse.ArgumentParser(description="Generate Resize/Crop test data")
    parser.add_argument('--src', default=f'{SRC_WIDTH}x{SRC_HEIGHT}',
                        help=f'Source image size WxH (default: {SRC_WIDTH}x{SRC_HEIGHT})')
    parser.add_argument('--dst', default=f'{DST_WIDTH}x{DST_HEIGHT}',
                        help=f'Destination size WxH (default: {DST_WIDTH}x{DST_HEIGHT})')
    parser.add_argument('--crop', type=int, choices=[0, 1], default=CROP_ENABLE,
                        help=f'Center crop enable (default: {CROP_ENABLE})')
    parser.add_argument('--seed', type=int, default=DEFAULT_SEED,
                        help=f'Random seed (default: {DEFAULT_SEED})')
    parser.add_argument('--mode', choices=['gradient', 'random'], default='gradient',
                        help='Image generation mode (default: gradient)')
    parser.add_argument('--load', default=None,
                        help='Load external .mem/.txt file as source image')
    parser.add_argument('-o', '--output', default='resize-input-src',
                        help='Output file prefix (default: resize-input-src)')
    args = parser.parse_args()

    sw, sh = map(int, args.src.split('x'))
    dw, dh = map(int, args.dst.split('x'))

    blocks_per_row = (sw + PIXELS_PER_BLOCK - 1) // PIXELS_PER_BLOCK

    out_dir = os.path.dirname(os.path.abspath(__file__))
    prefix = os.path.join(out_dir, args.output)

    # Generate or load source blocks
    if args.load:
        blocks = load_external_blocks(args.load)
        print(f"Loaded {len(blocks)} blocks from {args.load}")
        sh = len(blocks)
    elif args.mode == 'random':
        blocks = gen_random_image(sw, sh, args.seed)
    else:
        blocks = gen_gradient_image(sw, sh)

    # Write .mem + .txt
    for ext in ['.mem', '.txt']:
        write_blocks(f"{prefix}{ext}", blocks)

    print(f"\nParameters: src={sw}x{sh} dst={dw}x{dh} crop={args.crop}")
    print(f"Source blocks: {len(blocks)} ({sh} rows x {blocks_per_row} blocks, {sw} pixels wide)")
    print(f"$readmemh usage: $readmemh(\"{args.output}.mem\", mem, {SRC_BASE_ADDR // 64});")


if __name__ == "__main__":
    main()
