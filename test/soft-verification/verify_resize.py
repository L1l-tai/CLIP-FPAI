"""
Resize/Crop Verification Script
================================
Reads RTL testbench input data, runs the resize_crop golden model,
and writes expected output for RTL simulation comparison.

Usage:
    python verify_resize.py

Input:  ../input-data/resize-input-src.txt
Output: ../output-data/expect/resize-expected.txt

Parameters (match resize_sim.sv): 64x48 → crop 48x48 → resize 32x32
"""

import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from resize_golden import resize_crop_golden


def read_blocks(filepath: str) -> list:
    blocks = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                blocks.append(int(line, 16))
    return blocks


def write_blocks(filepath: str, blocks: list):
    with open(filepath, 'w') as f:
        for blk in blocks:
            f.write(f"{blk:0128x}\n")
    print(f"Wrote {len(blocks)} blocks to {filepath}")


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    input_file = os.path.join(base_dir, '..', 'input-data', 'resize-input-src.txt')
    output_dir = os.path.join(base_dir, '..', 'output-data', 'expect')
    output_file = os.path.join(output_dir, 'resize-expected.txt')

    # Parameters (match resize_sim.sv)
    SRC_W, SRC_H = 64, 48
    DST_W, DST_H = 32, 32
    CROP_ENABLE = True

    blocks = read_blocks(input_file)
    print(f"Input:  {len(blocks)} blocks ({SRC_W}x{SRC_H})")
    print(f"Config: crop={CROP_ENABLE} -> resize {DST_W}x{DST_H}")

    result = resize_crop_golden(blocks, SRC_W, SRC_H, DST_W, DST_H, CROP_ENABLE)

    write_blocks(output_file, result)
    print("Done.")


if __name__ == "__main__":
    main()
