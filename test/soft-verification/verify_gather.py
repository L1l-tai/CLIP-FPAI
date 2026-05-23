"""
Gather Verification Script
===========================
Reads RTL testbench input data, runs the gather golden model,
and writes expected output for RTL simulation comparison.

Usage:
    python verify_gather.py

Input files:  ../input-data/gather-input-idx.txt + gather-input-data.txt
Output file: ../output-data/expect/gather-expected.txt
"""

import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from gather_golden import gather_golden_blocks


def read_blocks(filepath: str) -> list:
    """Read 512-bit hex blocks from file. Returns list of int."""
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


def extract_indices(idx_blocks: list, indices_len: int) -> list:
    """
    Extract 32-bit indices from packed 512-bit blocks.
    Each index is 4 bytes, packed sequentially into blocks.
    """
    indices = []
    for i in range(indices_len):
        byte_offset = i * 4
        block_idx = byte_offset // 64
        intra_offset = byte_offset % 64
        val = (idx_blocks[block_idx] >> (intra_offset * 8)) & 0xFFFFFFFF
        indices.append(val)
    return indices


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    input_dir = os.path.join(base_dir, '..', 'input-data')
    output_dir = os.path.join(base_dir, '..', 'output-data', 'expect')

    # Parameters (match gather_sim.sv)
    INDICES_LEN = 20
    DATA_WIDTH = 8  # blocks per row

    # Read input
    idx_blocks = read_blocks(os.path.join(input_dir, 'gather-input-idx.txt'))
    data_blocks = read_blocks(os.path.join(input_dir, 'gather-input-data.txt'))

    print(f"Indices: {len(idx_blocks)} blocks")
    print(f"Data:    {len(data_blocks)} blocks ({len(data_blocks) // DATA_WIDTH} rows x {DATA_WIDTH} blocks)")

    # Extract indices
    indices = extract_indices(idx_blocks, INDICES_LEN)
    print(f"Indices: {indices}")

    # Run golden model
    output = gather_golden_blocks(data_blocks, indices, DATA_WIDTH)
    print(f"Output:  {len(output)} blocks ({len(indices)} rows x {DATA_WIDTH} blocks)")

    # Write expected output
    out_file = os.path.join(output_dir, 'gather-expected.txt')
    write_blocks(out_file, output)

    print("Done.")


if __name__ == "__main__":
    main()
