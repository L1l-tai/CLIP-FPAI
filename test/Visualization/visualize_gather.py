"""
Gather visualization: input matrix heatmap + index scatter + output heatmap.

Usage:
    python visualize_gather.py -i input.mem -x indices.mem -w output.mem -o out.png
"""

import argparse, struct
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

N, D = 256, 256
M = 77


def read_mem_flat(path, size):
    """Read .mem as flat uint8 array."""
    data = bytearray()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and len(line) == 128:
                blk = int(line, 16)
                for b in range(64):
                    data.append((blk >> (8 * b)) & 0xFF)
    return np.frombuffer(data[:size], dtype=np.uint8).copy()


def read_indices(path, count):
    """Read 32-bit indices from .mem file."""
    raw = read_mem_flat(path, count * 4)
    return np.frombuffer(raw, dtype=np.uint32).copy()[:count]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-i', '--input', required=True)
    parser.add_argument('-x', '--indices', default=None, help='Index .mem file')
    parser.add_argument('-w', '--hardware', required=True)
    parser.add_argument('-o', '--output', default='gather_board.png')
    args = parser.parse_args()

    inp = read_mem_flat(args.input, N * D)
    inp_mat = inp.reshape(N, D).astype(np.float64)
    out = read_mem_flat(args.hardware, M * D)
    out_mat = out.reshape(M, D).astype(np.float64)

    fig, axes = plt.subplots(1, 3, figsize=(18, 5))
    fig.suptitle(f'Gather: {N}x{D} -> {M}x{D}', fontsize=11, fontweight='bold')

    # 1. Input heatmap
    axes[0].imshow(inp_mat, aspect='auto', cmap='turbo', interpolation='nearest')
    axes[0].set_title(f'Input ({N}x{D})')
    axes[0].set_xlabel('Dim'); axes[0].set_ylabel('Row')

    # 2. Index scatter or placeholder
    if args.indices:
        idx = read_indices(args.indices, M)
        axes[1].scatter(range(M), idx, c='orange', s=6, alpha=0.8)
        axes[1].set_ylim(N, 0)
        axes[1].set_title(f'Index Mapping ({M} indices, {len(set(idx))} unique)')
        axes[1].set_xlabel('Output position'); axes[1].set_ylabel('Input row')
    else:
        axes[1].text(0.5, 0.5, f'{M} indices\n(pass -x idx.mem for scatter)',
                     transform=axes[1].transAxes, ha='center', va='center',
                     fontsize=13, color='#8a9bb5')
        axes[1].set_title('Index Mapping')
        axes[1].set_xticks([]); axes[1].set_yticks([])

    # 3. Output heatmap
    axes[2].imshow(out_mat, aspect='auto', cmap='turbo', interpolation='nearest')
    axes[2].set_title(f'Output ({M}x{D})')
    axes[2].set_xlabel('Dim'); axes[2].set_ylabel('Row')

    plt.tight_layout()
    plt.savefig(args.output, dpi=120)
    plt.close()
    print(f"Saved {args.output}")


if __name__ == '__main__':
    main()
