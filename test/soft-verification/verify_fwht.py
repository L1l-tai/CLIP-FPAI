"""
FWHT Verification Script
=========================
Reads RTL testbench input data (.txt, pure hex), runs the golden model,
and writes expected output for RTL simulation comparison.

Usage:
    python verify_fwht.py FP16   ../input-data/fwht-input-fp16.txt   ../output-data/expect/fwht-expected-fp16.txt
    python verify_fwht.py INT8   ../input-data/fwht-input-int8.txt   ../output-data/expect/fwht-expected-int8.txt

Input file format:  pure hex, one line per 512-bit block (128 hex chars)
Output file format: same, one line per 512-bit block
"""

import sys
import os
import struct

sys.path.insert(0, os.path.dirname(__file__))
from fwht_golden import fwht_fp16, fwht_int8, fp16_to_float, float_to_fp16


def read_blocks(filepath: str) -> list:
    """Read 512-bit hex blocks from file. Returns list of int (each 0..2^512-1)."""
    blocks = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                blocks.append(int(line, 16))
    return blocks


def write_blocks(filepath: str, blocks: list):
    """Write 512-bit hex blocks to file."""
    with open(filepath, 'w') as f:
        for blk in blocks:
            f.write(f"{blk:0128x}\n")
    print(f"Wrote {len(blocks)} blocks to {filepath}")


# =========================================================================
# FP16 verification
# =========================================================================

def fp16_block_to_values(block_lo: int, block_hi: int) -> list:
    """
    Convert 2 blocks (512-bit each) → 64 FP16 values.
    block_lo: lower 512 bits → values 0..31
    block_hi: upper 512 bits → values 32..63
    """
    values = []
    for blk in (block_lo, block_hi):
        for j in range(32):
            val = (blk >> (j * 16)) & 0xFFFF
            values.append(val)
    return values


def fp16_values_to_blocks(values: list) -> tuple:
    """Convert 64 FP16 values → 2 blocks (512-bit each)."""
    block_lo = 0
    block_hi = 0
    for i, v in enumerate(values):
        if i < 32:
            block_lo |= (int(v) & 0xFFFF) << (i * 16)
        else:
            block_hi |= (int(v) & 0xFFFF) << ((i - 32) * 16)
    return block_lo, block_hi


def verify_fp16(input_file: str, output_file: str):
    """FP16: 2 blocks per iteration = 64 FP16 values."""
    blocks = read_blocks(input_file)
    n_blocks = len(blocks)

    if n_blocks % 2 != 0:
        print(f"ERROR: FP16 mode expects even number of blocks, got {n_blocks}")
        sys.exit(1)

    expected = []
    for it in range(n_blocks // 2):
        blk_lo = blocks[it * 2]
        blk_hi = blocks[it * 2 + 1]
        in_vals = fp16_block_to_values(blk_lo, blk_hi)
        out_vals = fwht_fp16(in_vals)
        out_lo, out_hi = fp16_values_to_blocks(out_vals)
        expected.append(out_lo)
        expected.append(out_hi)

        # Show first and last value of each iteration
        print(f"  iter {it}: in[0..63] = FP16({fp16_to_float(in_vals[0]):.1f} .. "
              f"{fp16_to_float(in_vals[63]):.1f})"
              f"  →  out[0..63] = FP16({fp16_to_float(out_vals[0]):.1f} .. "
              f"{fp16_to_float(out_vals[63]):.1f})")

    write_blocks(output_file, expected)


# =========================================================================
# INT8 verification
# =========================================================================

def int8_block_to_values(block: int) -> list:
    """Convert 1 block (512-bit) → 64 INT8 values (signed Python ints)."""
    values = []
    for j in range(64):
        raw = (block >> (j * 8)) & 0xFF
        # Convert unsigned byte to signed int
        if raw & 0x80:
            values.append(raw - 256)
        else:
            values.append(raw)
    return values


def int8_values_to_block(values: list) -> int:
    """Convert 64 INT8 values → 1 block (512-bit)."""
    block = 0
    for i, v in enumerate(values):
        block |= (int(v) & 0xFF) << (i * 8)
    return block


def verify_int8(input_file: str, output_file: str):
    """INT8: 1 block per iteration = 64 INT8 values."""
    blocks = read_blocks(input_file)

    expected = []
    for it, blk in enumerate(blocks):
        in_vals = int8_block_to_values(blk)
        out_vals = fwht_int8(in_vals)
        out_blk = int8_values_to_block(out_vals)
        expected.append(out_blk)

        print(f"  iter {it}: in[0..7] = {in_vals[:8]}  →  out[0..7] = {out_vals[:8]}")

    write_blocks(output_file, expected)


# =========================================================================
# Main
# =========================================================================

def main():
    if len(sys.argv) != 4:
        print(__doc__)
        print("Arguments: <FP16|INT8> <input_file> <output_file>")
        sys.exit(1)

    fmt = sys.argv[1].upper()
    input_file = sys.argv[2]
    output_file = sys.argv[3]

    print(f"FWHT Verification: {fmt} mode")
    print(f"  Input:  {input_file}")
    print(f"  Output: {output_file}")

    if fmt == "FP16":
        verify_fp16(input_file, output_file)
    elif fmt == "INT8":
        verify_int8(input_file, output_file)
    else:
        print(f"ERROR: Unknown format '{fmt}'. Use FP16 or INT8.")
        sys.exit(1)

    print("Done.")


if __name__ == "__main__":
    main()
