"""
Generate Gather test data for RTL testbench and golden model verification.

Data layout (matching gather_sim.sv):
  Indices:  0x0000_1000 → mem[64]  (2 blocks for 20 x 32-bit)
  Data:     0x0000_2000 → mem[128] (32 rows x 8 blocks = 256 blocks)
  Output:   0x0001_0000 → mem[1024]

Usage:
  python generate_gather_input.py              # generate .mem + .txt
  python generate_gather_input.py -o custom    # custom output prefix
"""

import sys
import os
import random

# === Gather testbench parameters ===
INDICES_LEN = 20
DATA_LEN = 32          # number of source data rows
DATA_WIDTH = 8         # 8 blocks per row = 512 bytes
DEFAULT_SEED = 42

# Addresses (from gather_sim.sv)
IDX_BASE_ADDR = 0x0000_1000    # mem index 64
SRC_BASE_ADDR = 0x0000_2000    # mem index 128
DST_BASE_ADDR = 0x0001_0000    # mem index 1024

BYTES_PER_BLOCK = 64


def generate_indices_blocks():
    """Generate indices blocks at IDX_BASE_ADDR. Returns (start_mem_idx, [blocks])."""
    # 20 indices, each 4 bytes = 80 bytes = need 2 x 512-bit blocks
    blocks = [0, 0]
    mem_start = IDX_BASE_ADDR // BYTES_PER_BLOCK  # 64

    for i in range(INDICES_LEN):
        val = i % 16
        byte_offset = i * 4
        block_idx = byte_offset // BYTES_PER_BLOCK
        intra_offset = byte_offset % BYTES_PER_BLOCK
        # Write 32-bit value into block at byte intra_offset
        blocks[block_idx] |= (val & 0xFFFFFFFF) << (intra_offset * 8)

    return mem_start, blocks


def generate_data_blocks(seed: int = DEFAULT_SEED):
    """Generate random source data blocks at SRC_BASE_ADDR. Returns (start_mem_idx, [blocks])."""
    rng = random.Random(seed)
    blocks = []
    mem_start = SRC_BASE_ADDR // BYTES_PER_BLOCK  # 128

    for _ in range(DATA_LEN * DATA_WIDTH):
        blk = rng.getrandbits(512)
        blocks.append(blk)

    return mem_start, blocks


def write_blocks_file(filename, blocks):
    """Write list of blocks to a pure hex file."""
    with open(filename, 'w') as f:
        for blk in blocks:
            f.write(f"{blk:0128x}\n")
    print(f"Wrote {len(blocks)} blocks to {filename}")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Generate Gather test data")
    parser.add_argument('-o', '--output', default='gather-input',
                        help='Output file prefix (default: gather-input)')
    parser.add_argument('--seed', type=int, default=DEFAULT_SEED,
                        help=f'Random seed (default: {DEFAULT_SEED})')
    args = parser.parse_args()

    out_dir = os.path.dirname(os.path.abspath(__file__))
    prefix = os.path.join(out_dir, args.output)

    idx_start, idx_blks = generate_indices_blocks()
    data_start, data_blks = generate_data_blocks(seed=args.seed)

    # Write separate files (no zero padding)
    for ext in ['.mem', '.txt']:
        write_blocks_file(f"{prefix}-idx{ext}", idx_blks)
        write_blocks_file(f"{prefix}-data{ext}", data_blks)

    print(f"\nTestbench $readmemh usage:")
    print(f"  $readmemh(\"{args.output}-idx.mem\", mem, {idx_start});")
    print(f"  $readmemh(\"{args.output}-data.mem\", mem, {data_start});")


if __name__ == "__main__":
    main()
