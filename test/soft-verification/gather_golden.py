"""
Gather Golden Model for RTL Verification
=========================================
ONNX Gather with axis=0, matching RTL gather.v behavior.

RTL addressing (from gather.v):
  src_addr = arbase_data + index * (data_width << 6)   // index * data_width * 64 bytes
  dst_addr = awbase_dout + out_pos  * (data_width << 6) // sequential output

Each "row" = data_width blocks of 512-bit (64 bytes).
"""

import numpy as np


def gather_golden(data: np.ndarray, indices: np.ndarray, data_width: int) -> np.ndarray:
    """
    axis=0 Gather, matching RTL behavior.

    Parameters
    ----------
    data : np.ndarray
        Input data, shape [D, W] where D = num_rows, W = data_width * 64 bytes.
        Each element is a uint8 byte. Two rows are data_width * 64 bytes apart.
    indices : np.ndarray
        Index array, shape [1, N] (2D), dtype int64. Values in [0, D).
    data_width : int
        Number of 512-bit blocks per row. Row size = data_width * 64 bytes.

    Returns
    -------
    np.ndarray
        Output data, shape [N, data_width * 64], same dtype as data.
    """
    data = np.asarray(data, dtype=np.uint8)
    indices = np.asarray(indices, dtype=np.int64).reshape(-1)
    D = data.shape[0] // (data_width * 64)

    row_bytes = data_width * 64
    data_2d = data.reshape(D, row_bytes)

    output = np.zeros((len(indices), row_bytes), dtype=np.uint8)
    for out_idx, idx in enumerate(indices):
        if idx < 0 or idx >= D:
            raise IndexError(f"Index {idx} out of range [0, {D})")
        output[out_idx] = data_2d[idx]

    return output


def gather_golden_blocks(data_blocks: list, indices: list, data_width: int) -> list:
    """
    Block-level gather: works on 512-bit block arrays.

    Parameters
    ----------
    data_blocks : list of int
        Input data as 512-bit ints (from hex). Total blocks = D * data_width.
    indices : list of int
        Index values in [0, D).
    data_width : int
        Number of 512-bit blocks per row.

    Returns
    -------
    list of int
        Output blocks: len(indices) * data_width blocks.
    """
    D = len(data_blocks) // data_width
    output = []
    for idx in indices:
        if idx < 0 or idx >= D:
            raise IndexError(f"Index {idx} out of range [0, {D})")
        start = idx * data_width
        output.extend(data_blocks[start:start + data_width])
    return output


# =========================================================================
# Test suite
# =========================================================================

def test_small():
    """Small test case: 4 rows x 2 blocks, pick indices [0,2,3]."""
    print("=" * 60)
    print("test_small")
    print("=" * 60)

    # 4 rows, each 2 blocks: 8 blocks total
    data_width = 2
    D = 4
    blocks = []
    for r in range(D):
        # Each block: fill with row+1 pattern (low byte = row+1)
        for b in range(data_width):
            blk = 0
            for j in range(64):
                blk |= ((r + 1) * (b + 1) + j) & 0xFF << (j * 8)
            blocks.append(blk)

    indices = [0, 2, 3]
    result = gather_golden_blocks(blocks, indices, data_width)

    print(f"Input: {len(blocks)} blocks ({D} rows x {data_width} blocks)")
    print(f"Indices: {indices}")
    print(f"Output: {len(result)} blocks ({len(indices)} rows x {data_width} blocks)")

    # Verify: row r should have block[0] low byte = (r+1)*1+0 = r+1
    for out_row, idx in enumerate(indices):
        for b in range(data_width):
            blk = result[out_row * data_width + b]
            expected_first = ((idx + 1) * (b + 1)) & 0xFF
            actual_first = blk & 0xFF
            ok = "OK" if actual_first == expected_first else "FAIL"
            print(f"  out[{out_row}][{b}][7:0] = {actual_first}, expected {expected_first} {ok}")

    print()


def test_clip_like():
    """CLIP-like: 49408 rows x 8 blocks, 77 indices."""
    print("=" * 60)
    print("test_clip_like")
    print("=" * 60)

    vocab_size = 49408
    data_width = 8  # 8 blocks per row = 512 bytes per embedding
    rng = np.random.RandomState(42)

    # Generate data blocks (each block is a random 512-bit value)
    import random
    total_blocks = vocab_size * data_width
    blocks = [random.getrandbits(512) for _ in range(total_blocks)]

    # CLIP tokenizer indices
    indices = [49406, 320, 1125, 539, 320, 1769, 4629] + [49407] * 70

    result = gather_golden_blocks(blocks, indices, data_width)

    print(f"Data: {vocab_size} rows x {data_width} blocks")
    print(f"Indices: {len(indices)} values")
    print(f"Output: {len(result)} blocks")

    # Verify: out[0] should match blocks[indices[0]*data_width]
    for i in range(min(5, len(indices))):
        idx = indices[i]
        src_start = idx * data_width
        for b in range(min(2, data_width)):
            match = result[i * data_width + b] == blocks[src_start + b]
            print(f"  out[{i}][{b}] = src[{idx}][{b}]? {'OK' if match else 'FAIL'}")

    print()


if __name__ == "__main__":
    test_small()
    test_clip_like()
    print("Done.")
