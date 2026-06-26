"""
Generate Gather simulation input .mem files: 256x256 INT8 matrix + 77 indices.

Usage:
    python generate_gather_input.py
    -> gather-input-data-256x256.mem  (1024 blocks)
    -> gather-input-idx-256x256.mem   (5 blocks)
"""

import os, random, math
import numpy as np

N, D = 256, 256
M = 77
DATA_WIDTH_BEATS = 4           # 256 bytes/row = 4 beats
SRC_TOTAL_BLOCKS = N * DATA_WIDTH_BEATS  # 1024
IDX_BEATS = 5                  # ceil(77*4/64) = 5
BYTES_PER_BLOCK = 64
DEFAULT_SEED = 42


def write_blocks_hex(filename, blocks):
    """Write list of ints as hex blocks to file."""
    with open(filename, 'w') as f:
        for blk in blocks:
            f.write(f"{blk:0128x}\n")
    print(f"  Wrote {len(blocks)} blocks -> {filename}")


def generate_indices(seed=DEFAULT_SEED):
    """Generate 77 random 32-bit indices (0-255), packed into IDX_BEATS blocks."""
    rng = random.Random(seed)
    blocks = [0] * IDX_BEATS
    for i in range(M):
        val = rng.randint(0, N - 1)
        byte_off = i * 4
        blk_idx = byte_off // BYTES_PER_BLOCK
        intra_off = byte_off % BYTES_PER_BLOCK
        blocks[blk_idx] |= (val & 0xFFFFFFFF) << (intra_off * 8)
    return blocks


def generate_data():
    """Generate 256x256 INT8 rainbow matrix, packed into SRC_TOTAL_BLOCKS blocks.
    Byte order matches gather RTL: each 64B block = 16 pixels × 4 bytes (INT8 at byte 0).
    """
    blocks = [0] * SRC_TOTAL_BLOCKS
    for row in range(N):
        phase = row * 2.0 * math.pi / N
        for col in range(D):
            val = math.sin(col * 3.0 * math.pi / D + phase) * 0.6 \
                + math.sin(2.0 * col * math.pi / D + phase * 1.7) * 0.3 \
                + math.sin(3.0 * col * math.pi / D + phase * 0.5) * 0.1
            b = int((val + 1.0) * 127.5) & 0xFF
            # Each 64B block = 64 INT8 values, 4 blocks per row (= DATA_WIDTH_BEATS)
            block_idx = (col // 64) + row * DATA_WIDTH_BEATS
            byte_off = col % 64
            blocks[block_idx] |= b << (byte_off * 8)
    return blocks


def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))

    print(f"Generating {N}x{D} rainbow matrix ({SRC_TOTAL_BLOCKS} blocks)...")
    data_blks = generate_data()
    write_blocks_hex(os.path.join(out_dir, "gather-input-data-256x256.mem"), data_blks)

    print(f"Generating {M} random indices ({IDX_BEATS} blocks)...")
    idx_blks = generate_indices()
    write_blocks_hex(os.path.join(out_dir, "gather-input-idx-256x256.mem"), idx_blks)

    print(f"\nDone. {M} indices, {N}x{D} matrix, {SRC_TOTAL_BLOCKS} data blocks")


if __name__ == "__main__":
    main()
