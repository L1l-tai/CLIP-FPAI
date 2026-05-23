"""
Resize/Crop Golden Model for RTL Verification
===============================================
Center-crop to square + bilinear interpolation resize.
Matches RTL resize_crop module behavior.

Pixel format: {8'b0, R[7:0], G[7:0], B[7:0]} = 32-bit
  bit[23:16] = R, bit[15:8] = G, bit[7:0] = B

Each 512-bit block = 16 pixels (16 × 32 = 512 bits).
"""

import sys
import os
import numpy as np


# =========================================================================
# Pixel packing / unpacking
# =========================================================================

def unpack_block(block: int) -> np.ndarray:
    """Convert 512-bit int → 16 pixels [R, G, B] (shape 16×3, uint8)."""
    pixels = np.zeros((16, 3), dtype=np.uint8)
    for i in range(16):
        px = (block >> (i * 32)) & 0xFFFFFFFF
        pixels[i, 0] = (px >> 16) & 0xFF  # R
        pixels[i, 1] = (px >> 8) & 0xFF   # G
        pixels[i, 2] = px & 0xFF           # B
    return pixels


def pack_block(pixels: np.ndarray) -> int:
    """Convert 16 pixels [R, G, B] → 512-bit int."""
    block = 0
    for i in range(16):
        px = (int(pixels[i, 0]) << 16) | (int(pixels[i, 1]) << 8) | int(pixels[i, 2])
        block |= px << (i * 32)
    return block


def blocks_to_image(blocks: list, width: int) -> np.ndarray:
    """Convert list of 512-bit blocks → RGB image (H×W×3, float64)."""
    pixels_per_block = 16
    blocks_per_row = (width + pixels_per_block - 1) // pixels_per_block
    height = len(blocks) // blocks_per_row
    img = np.zeros((height, width, 3), dtype=np.float64)
    for row in range(height):
        for b in range(blocks_per_row):
            px = unpack_block(blocks[row * blocks_per_row + b])
            col_start = b * pixels_per_block
            col_end = min(col_start + pixels_per_block, width)
            img[row, col_start:col_end, :] = px[:col_end - col_start, :]
    return img


def image_to_blocks(img: np.ndarray) -> list:
    """Convert RGB image (H×W×3) → list of 512-bit blocks."""
    height, width = img.shape[:2]
    pixels_per_block = 16
    blocks_per_row = (width + pixels_per_block - 1) // pixels_per_block
    blocks = []
    for row in range(height):
        for b in range(blocks_per_row):
            pixels = np.zeros((pixels_per_block, 3), dtype=np.uint8)
            col_start = b * pixels_per_block
            col_end = min(col_start + pixels_per_block, width)
            for col in range(col_start, col_end):
                i = col - col_start
                for c in range(3):
                    v = img[row, col, c]
                    pixels[i, c] = max(0, min(255, int(round(v))))
            blocks.append(pack_block(pixels))
    return blocks


# =========================================================================
# Center crop
# =========================================================================

def center_crop_to_square(img: np.ndarray) -> np.ndarray:
    """Center-crop image to square using the shorter edge."""
    h, w = img.shape[:2]
    crop_size = min(h, w)
    off_x = (w - crop_size) // 2
    off_y = (h - crop_size) // 2
    return img[off_y:off_y + crop_size, off_x:off_x + crop_size, :]


# =========================================================================
# Bilinear interpolation resize
# =========================================================================

def bilinear_resize(src: np.ndarray, dst_h: int, dst_w: int) -> np.ndarray:
    """
    Bilinear interpolation resize.
    src: H×W×3 float64 image
    Returns dst_h×dst_w×3 float64 image.
    """
    src_h, src_w = src.shape[:2]
    dst = np.zeros((dst_h, dst_w, 3), dtype=np.float64)

    scale_x = src_w / dst_w
    scale_y = src_h / dst_h

    for dst_y in range(dst_h):
        for dst_x in range(dst_w):
            # Map destination pixel to source coordinates (match RTL convention:
            #   x_delta = ratio_greater × (k+1) → (dst_x + 1) × scale_x
            #   y_bias  = ratio_greater × row_idx → dst_y × scale_y (row starts at 0)
            src_x = (dst_x + 1) * scale_x - 1
            src_y = (dst_y + 1) * scale_y - 1

            # Clamp to source bounds
            src_x = max(0.0, min(src_w - 1.0, src_x))
            src_y = max(0.0, min(src_h - 1.0, src_y))

            # Integer parts
            x0 = int(np.floor(src_x))
            y0 = int(np.floor(src_y))
            x1 = min(x0 + 1, src_w - 1)
            y1 = min(y0 + 1, src_h - 1)

            # Fractional parts
            fx = src_x - x0
            fy = src_y - y0

            # Bilinear weights
            w00 = (1.0 - fx) * (1.0 - fy)
            w10 = fx * (1.0 - fy)
            w01 = (1.0 - fx) * fy
            w11 = fx * fy

            # Interpolate each channel
            for c in range(3):
                val = (w00 * src[y0, x0, c] +
                       w10 * src[y1, x0, c] +
                       w01 * src[y0, x1, c] +
                       w11 * src[y1, x1, c])
                dst[dst_y, dst_x, c] = val

    return dst


# =========================================================================
# Top-level golden model
# =========================================================================

def resize_crop_golden(src_blocks: list,
                       src_w: int, src_h: int,
                       dst_w: int, dst_h: int,
                       crop_enable: bool = True) -> list:
    """
    Resize/Crop golden model.

    Parameters
    ----------
    src_blocks : list of int
        Source image as 512-bit blocks (src_h blocks, each = 16 pixels).
        Width may be > 16; each row spans ceil(src_w/16) blocks.
        Currently only src_w ≤ 16 is supported (one block per row).
    src_w, src_h : int
        Source image dimensions in pixels.
    dst_w, dst_h : int
        Destination image dimensions in pixels.
    crop_enable : bool
        If True, center-crop to square before resize.

    Returns
    -------
    list of int
        Output image as 512-bit blocks (dst_h blocks).
    """
    # Unpack source blocks to image
    img = blocks_to_image(src_blocks, src_w)

    # Center crop
    if crop_enable:
        img = center_crop_to_square(img)
        crop_h, crop_w = img.shape[:2]
    else:
        crop_h, crop_w = src_h, src_w

    # Resize
    result = bilinear_resize(img, dst_h, dst_w)

    # Pack back to blocks
    return image_to_blocks(result)


# =========================================================================
# Test suite
# =========================================================================

def test_simple():
    """Simple test: 4×4 → crop 4×4 → resize 2×2."""
    print("=" * 60)
    print("test_simple: 4x4 → resize 2x2")
    print("=" * 60)

    # 4×4 image: each row = 4 pixels → packs into 1 block (16 pixels, 12 zero)
    blocks = []
    for row in range(4):
        pixels = np.zeros((16, 3), dtype=np.uint8)
        for col in range(4):
            pixels[col, 0] = row * 64 + col * 16       # R gradient
            pixels[col, 1] = 128 + row * 32 - col * 16  # G gradient
            pixels[col, 2] = (row + col) * 32            # B gradient
        blocks.append(pack_block(pixels))

    result = resize_crop_golden(blocks, 4, 4, 2, 2, crop_enable=False)

    # Unpack first output block
    out_px = unpack_block(result[0])
    print(f"Output[0,0]: R={out_px[0,0]} G={out_px[0,1]} B={out_px[0,2]}")
    print(f"Output[0,1]: R={out_px[1,0]} G={out_px[1,1]} B={out_px[1,2]}")

    out_px1 = unpack_block(result[1])
    print(f"Output[1,0]: R={out_px1[0,0]} G={out_px1[0,1]} B={out_px1[0,2]}")
    print(f"Output[1,1]: R={out_px1[1,0]} G={out_px1[1,1]} B={out_px1[1,2]}")
    print()


def test_center_crop():
    """Test center crop: 6×4 → crop 4×4 → resize 2×2."""
    print("=" * 60)
    print("test_center_crop: 6x4 → center-crop 4x4 → resize 2x2")
    print("=" * 60)

    blocks = []
    for row in range(4):
        pixels = np.zeros((16, 3), dtype=np.uint8)
        for col in range(6):
            pixels[col, 0] = col * 40       # R: 0, 40, 80, 120, 160, 200
            pixels[col, 1] = row * 60       # G: 0, 60, 120, 180
            pixels[col, 2] = 128
        blocks.append(pack_block(pixels))

    result = resize_crop_golden(blocks, 6, 4, 2, 2, crop_enable=True)

    out_px0 = unpack_block(result[0])
    out_px1 = unpack_block(result[1])
    print(f"After crop→resize (2×2):")
    print(f"  [0,0] R={out_px0[0,0]} G={out_px0[0,1]} B={out_px0[0,2]}")
    print(f"  [0,1] R={out_px0[1,0]} G={out_px0[1,1]} B={out_px0[1,2]}")
    print(f"  [1,0] R={out_px1[0,0]} G={out_px1[0,1]} B={out_px1[0,2]}")
    print(f"  [1,1] R={out_px1[1,0]} G={out_px1[1,1]} B={out_px1[1,2]}")

    # Crop should take columns 1-4 (0-indexed: col 1,2,3,4)
    # Col 1 R=40, col 4 R=160 → center two columns
    print()


def test_identity():
    """Identity test: same size, no crop, should be near-identical."""
    print("=" * 60)
    print("test_identity: 4x4 → resize 4x4 (no crop)")
    print("=" * 60)

    blocks = []
    for row in range(4):
        pixels = np.zeros((16, 3), dtype=np.uint8)
        for col in range(4):
            pixels[col, 0] = row * 64 + col * 16
            pixels[col, 1] = 128
            pixels[col, 2] = 255 - (row + col) * 16
        blocks.append(pack_block(pixels))

    result = resize_crop_golden(blocks, 4, 4, 4, 4, crop_enable=False)

    # Check each pixel is close to original
    max_err = 0
    for row in range(4):
        in_px = unpack_block(blocks[row])
        out_px = unpack_block(result[row])
        for col in range(4):
            for c in range(3):
                err = abs(int(in_px[col, c]) - int(out_px[col, c]))
                max_err = max(max_err, err)

    print(f"Max pixel error (identity): {max_err}")
    if max_err <= 1:
        print("PASS: identity near-perfect")
    else:
        print("FAIL: identity error too large")
    print()


if __name__ == "__main__":
    test_simple()
    test_center_crop()
    test_identity()
    print("Done.")
