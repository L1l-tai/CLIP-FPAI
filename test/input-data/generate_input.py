"""
Generate FWHT input data files for RTL testbenches.

Usage:
    python generate_input.py FP16  8  > fwht-input-fp16.txt
    python generate_input.py INT8  8  > fwht-input-int8.txt
    python generate_input.py FP16  8  --output fwht-input.txt
"""

import sys
import os
import struct
import numpy as np

# Add parent soft-verification to path for golden model imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'soft-verification'))
from fwht_golden import float_to_fp16, fp16_to_float


def int8_to_bytes(val: int) -> int:
    """Convert signed INT8 to 8-bit unsigned byte representation."""
    return val & 0xFF


def generate_fp16_blocks(num_blocks: int, seed: int = 42) -> list:
    """
    Generate FP16 test blocks.
    Each block = 512 bits = 32 FP16 values.
    Values: 1..32, 33..64, ... sequential, using FP16 encoding.
    """
    rng = np.random.RandomState(seed)
    blocks = []

    for b in range(num_blocks):
        block_bytes = bytearray(64)  # 512 bits = 64 bytes

        for j in range(32):
            # FWHT 64x amplification: keep input within [-64,63] to avoid FP16 overflow
            val = j + 1 + b * 4  # values 1..32, 5..36, 9..40, ...
            if (j + b) % 3 == 0:
                val = -val // 2
            val = max(-64, min(63, val))
            fp16 = float_to_fp16(float(val))

            # $readmemh: hex last byte → reg[7:0] → fwht_regs[0][7:0]
            # SystemVerilog reg byte k = bytearray[63-k]
            # fwht_regs[j] = {byte[j*2+1], byte[j*2]} = {bytearray[62-j*2], bytearray[63-j*2]}
            byte_pos_hi = 62 - j * 2   # high byte of 16-bit value
            byte_pos_lo = 63 - j * 2   # low byte
            block_bytes[byte_pos_hi] = (fp16 >> 8) & 0xFF
            block_bytes[byte_pos_lo] = fp16 & 0xFF

        blocks.append(block_bytes.hex())

    return blocks


def generate_int8_blocks(num_blocks: int, seed: int = 42) -> list:
    """
    Generate INT8 test blocks.
    Each block = 512 bits = 64 INT8 values.
    Values: alternating positive/negative within [-128, 127].
    """
    rng = np.random.RandomState(seed)
    blocks = []

    for b in range(num_blocks):
        block_bytes = bytearray(64)

        for j in range(64):
            # 分散到 [-128,127]: 每 block 偏移使 8 个 block 各不同, 模运算避免全饱和
            mag = ((j // 2) + 1 + b * 16) % 129
            if mag == 0:
                mag = 1
            val = mag if j % 2 == 0 else -mag
            # $readmemh: hex last byte → LSB → din[7:0] → fwht_regs[0]
            # So j=0 must be at byte[63] (hex end), j=63 at byte[0] (hex start)
            block_bytes[63 - j] = int8_to_bytes(val)

        blocks.append(block_bytes.hex())

    return blocks


def write_file(filepath: str, format_type: str, blocks: list):
    """Write input file in testbench-compatible format (header + hex blocks)."""
    with open(filepath, 'w') as f:
        f.write(f"{format_type}\n")
        f.write(f"{len(blocks)}\n")
        for blk in blocks:
            f.write(f"{blk}\n")
    print(f"Wrote {len(blocks)} {format_type} blocks to {filepath}")


def write_readmemh_file(filepath: str, blocks: list):
    """Write pure hex file for $readmemh (no header, hex blocks only)."""
    with open(filepath, 'w') as f:
        for blk in blocks:
            f.write(f"{blk}\n")
    print(f"Wrote {len(blocks)} blocks (pure hex, $readmemh format) to {filepath}")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Generate FWHT input data for RTL testbench")
    parser.add_argument("format", choices=["FP16", "INT8"], help="Data format")
    parser.add_argument("blocks", type=int, default=8, nargs="?", help="Number of 512-bit blocks")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    parser.add_argument("--output", "-o", default=None, help="Output file (header format, default: stdout)")
    parser.add_argument("--readmemh", default=None, help="Output file for $readmemh (pure hex, no header)")
    args = parser.parse_args()

    if args.format == "FP16":
        blks = generate_fp16_blocks(args.blocks, args.seed)
    else:
        blks = generate_int8_blocks(args.blocks, args.seed)

    if args.output:
        write_file(args.output, args.format, blks)
    elif not args.readmemh:
        print(args.format)
        print(len(blks))
        for blk in blks:
            print(blk)

    # Always generate .mem for Vivado alongside .txt
    if args.readmemh:
        write_readmemh_file(args.readmemh, blks)
        # Also write a .mem copy for Vivado (same pure hex format, .mem extension)
        mem_path = args.readmemh.replace('.txt', '.mem')
        if mem_path == args.readmemh:
            mem_path = args.readmemh + '.mem'
        write_readmemh_file(mem_path, blks)


if __name__ == "__main__":
    main()
