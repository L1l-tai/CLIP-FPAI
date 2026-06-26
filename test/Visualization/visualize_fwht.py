"""
FWHT waveform visualization: compare input, golden output, hardware output,
and full Hadamard (H12 ⊗ H64) via NPU-compatible H12 mixing.

Usage:
    python visualize_fwht.py -i input.mem -g golden.mem -w hardware.mem -o out.png
"""

import argparse
import sys
import os
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'soft-verification'))
from fwht_golden import fp16_to_float


VEC_DIM = 768
GROUP_SIZE = 64
NUM_GROUPS = VEC_DIM // GROUP_SIZE  # 12
H12_SIZE = 12

VECTORS_TO_SHOW = [1, 10, 20, 30]  # 1-indexed


def _make_h12():
    """
    Construct 12×12 normalized Hadamard matrix.
    Paley Type I: n = q+1, q=11 (prime, ≡3 mod 4).
    C = [[0, 1^T], [-1, Q_jacob]],  H = I + C.
    """
    q = 11
    qr = set((j * j) % q for j in range(1, q))

    # Jacobsthal Q: Q[i,j] = χ(j-i) for i≠j, 0 on diagonal
    Q = np.zeros((q, q), dtype=np.float64)
    for i in range(q):
        for j in range(q):
            if i != j:
                d = (j - i) % q
                Q[i, j] = 1.0 if d in qr else -1.0

    # Build H = I_{q+1} + C where C = [[0, 1s], [-1s, Q]]
    H = np.eye(12, dtype=np.float64)
    H[0, 1:] = 1.0          # first row (except [0,0])
    H[1:, 0] = -1.0         # first col (except [0,0])
    H[1:, 1:] += Q          # add Jacobsthal to identity block

    # Verify
    prod = H @ H.T
    if not np.allclose(prod, np.eye(12) * 12.0, atol=1e-10):
        print(f"WARNING: H12 orthogonality check: max|err|={np.abs(prod - np.eye(12)*12).max():.2e}")

    return H / np.sqrt(H12_SIZE)


H12 = _make_h12()


def apply_h12_mix(vec: list) -> list:
    """
    Apply H12 mixing across groups.
    Reshape [768] → [12, 64], H12 @ [12, 64] → [12, 64], flatten.
    """
    mat = np.array(vec, dtype=np.float64).reshape(NUM_GROUPS, GROUP_SIZE)
    mixed = H12 @ mat
    return mixed.flatten().tolist()


def read_mem(path: str) -> list:
    """Read .mem file, extract FP16 values as float list."""
    data = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and len(line) == 128:
                blk = int(line, 16)
                for j in range(32):
                    data.append((blk >> (16 * j)) & 0xFFFF)
    return [fp16_to_float(x) for x in data]


def plot_waveform(ax, data, title, color='steelblue', mark_outliers=True,
                  overlay=None, overlay_label=None):
    """Plot 768-element waveform with group dividers and outlier markers."""
    x = np.arange(len(data))
    ax.plot(x, data, color=color, linewidth=0.4, alpha=0.9)

    if overlay is not None:
        ax.plot(x, overlay, color='darkorange', linewidth=0.4, alpha=0.6,
                linestyle='--', label=overlay_label)

    # Group dividers
    for g in range(1, NUM_GROUPS):
        ax.axvline(x=g * GROUP_SIZE, color='gray', linewidth=0.3, linestyle=':')

    # Outlier markers (>5 sigma)
    if mark_outliers and len(data) > 0:
        std = np.std(data)
        if std > 0:
            mask = np.abs(data) > 5 * std
            if np.any(mask):
                ax.scatter(x[mask], np.array(data)[mask], color='red', s=4,
                           zorder=5, alpha=0.7)

    ax.set_title(title, fontsize=7)
    ax.set_xlim(0, VEC_DIM - 1)


def main():
    parser = argparse.ArgumentParser(description="FWHT waveform visualization")
    parser.add_argument('-i', '--input', required=True, help='Input .mem file')
    parser.add_argument('-g', '--golden', required=True, help='Golden output .mem file')
    parser.add_argument('-w', '--hardware', required=True, help='Hardware output .mem file')
    parser.add_argument('-o', '--output', default='fwht_waveform.png', help='Output PNG path')
    args = parser.parse_args()

    # Read all data
    print(f"Loading input:    {args.input}")
    inp = read_mem(args.input)
    print(f"Loading golden:   {args.golden}")
    gold = read_mem(args.golden)
    print(f"Loading hardware: {args.hardware}")
    hw = read_mem(args.hardware)

    num_vectors = len(inp) // VEC_DIM
    print(f"Total vectors: {num_vectors}")

    # Build subplot grid: 4 rows × 6 cols
    # cols: Input | Golden(FWHT) | HW(FWHT) | Golden+H12 | HW+H12 | Error(H12)
    n_rows = len(VECTORS_TO_SHOW)
    n_cols = 5
    fig, axes = plt.subplots(n_rows, n_cols, figsize=(18, n_rows * 2.5))
    fig.suptitle('FWHT 768x30 -- Block-Diagonal FWHT vs Full Hadamard',
                 fontsize=12, fontweight='bold')

    col_titles = ['Input', 'Golden FWHT', 'HW FWHT',
                  'Error (HW-Golden)', 'Golden Full Hadamard']
    for c, title in enumerate(col_titles):
        axes[0, c].set_title(title, fontsize=8, fontweight='bold')

    for r, vec_idx in enumerate(VECTORS_TO_SHOW):
        v = vec_idx - 1
        if v >= num_vectors:
            continue

        base = v * VEC_DIM
        vin   = inp[base : base + VEC_DIM]
        vgold = gold[base : base + VEC_DIM]
        vhw   = hw[base : base + VEC_DIM]

        # Apply H12 mixing to golden only (as reference for full Hadamard)
        vgold_h12 = apply_h12_mix(vgold)
        verr      = [vhw[i] - vgold[i] for i in range(VEC_DIM)]
        max_err   = max(abs(e) for e in verr)

        # Row label
        axes[r, 0].set_ylabel(f'Vec {vec_idx}', fontsize=7)

        # Col 0: Input
        plot_waveform(axes[r, 0], vin, f'v{vec_idx} input', color='steelblue')

        # Col 1: Golden FWHT (64-pt block-diagonal)
        plot_waveform(axes[r, 1], vgold, f'v{vec_idx} golden', color='seagreen')

        # Col 2: HW FWHT (64-pt block-diagonal)
        plot_waveform(axes[r, 2], vhw, f'v{vec_idx} hardware', color='royalblue',
                      overlay=vgold, overlay_label='golden')
        axes[r, 2].legend(fontsize=5, loc='upper right')

        # Col 3: Error (HW - Golden, FWHT only)
        plot_waveform(axes[r, 3], verr,
                      f'v{vec_idx} error (max={max_err:.2f})',
                      color='crimson', mark_outliers=False)
        axes[r, 3].axhline(y=0, color='gray', linewidth=0.5)
        axes[r, 3].set_ylim(-0.5, 0.5)

        # Col 4: Golden Full Hadamard (H12 x H64) as reference
        plot_waveform(axes[r, 4], vgold_h12, f'v{vec_idx} full hadamard', color='teal')

    plt.tight_layout()
    plt.savefig(args.output, dpi=150)
    print(f"Saved to {args.output}")


if __name__ == '__main__':
    main()
