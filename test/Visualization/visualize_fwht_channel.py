"""
Simplified FWHT single-channel waveform: input vs hardware output.
Called from C++ board test via system().

Usage:
    python visualize_fwht_channel.py -i input.mem -w hardware.mem -c 5 -o out.png
"""

import argparse
import sys, os
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'soft-verification'))
from fwht_golden import fp16_to_float

VEC_DIM, GROUP_SIZE = 768, 64


def read_mem(path):
    data = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and len(line) == 128:
                blk = int(line, 16)
                for j in range(32):
                    data.append((blk >> (16 * j)) & 0xFFFF)
    return [fp16_to_float(x) for x in data]


def plot_input_waveform(ax, data, title):
    x = np.arange(len(data))
    ax.plot(x, data, color='steelblue', linewidth=0.8, alpha=0.9)
    for g in range(1, VEC_DIM // GROUP_SIZE):
        ax.axvline(g * GROUP_SIZE, color='gray', linewidth=0.3, linestyle=':')
    std = np.std(data)
    if std > 0:
        mask = np.abs(data) > 5 * std
        if np.any(mask):
            ax.scatter(x[mask], np.array(data)[mask], color='red', s=14, zorder=5, alpha=0.8)
    ax.set_title(title, fontsize=9)
    ax.set_xlim(0, VEC_DIM - 1)


def plot_output_waveform(ax, data, title):
    ax.plot(np.arange(len(data)), data, color='seagreen', linewidth=0.8, alpha=0.9)
    ax.set_title(title, fontsize=9)
    ax.set_xlim(0, VEC_DIM - 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-i', '--input', required=True)
    parser.add_argument('-w', '--hardware', required=True)
    parser.add_argument('-c', '--channel', type=int, required=True)
    parser.add_argument('-o', '--output', default='fwht_channel.png')
    args = parser.parse_args()

    inp = read_mem(args.input)
    hw  = read_mem(args.hardware)
    ch  = args.channel
    base = ch * VEC_DIM
    vin = inp[base : base + VEC_DIM]
    vhw = hw[base : base + VEC_DIM]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 3.5))
    fig.suptitle(f'FWHT Channel {ch} (768x30, FP16)', fontsize=10, fontweight='bold')

    plot_input_waveform(ax1, vin, f'Channel {ch} — Input')
    plot_output_waveform(ax2, vhw, f'Channel {ch} — Hardware Output')

    plt.tight_layout()
    plt.savefig(args.output, dpi=120)
    plt.close()
    print(f"Saved {args.output}")


if __name__ == '__main__':
    main()
