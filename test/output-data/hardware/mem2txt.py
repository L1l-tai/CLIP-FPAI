"""
Copy .mem from Vivado sim directory and convert to .txt for comparison.

Usage:
    python mem2txt.py                              # all: fp16 + int8 + gather
    python mem2txt.py --fp16                       # FP16 only
    python mem2txt.py --int8                       # INT8 only
    python mem2txt.py --gather                     # Gather only
    python mem2txt.py --src D:/path/to/xsim --all  # custom sim dir, all modes
"""

import sys
import os
import shutil
import glob

# Default Vivado simulation directories (relative to project root)
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
SIM_BASE = os.path.join(PROJECT_ROOT, 'FPGA', '30TAI-PRJ', '30TAI-PRJ.sim')

SIM_DIRS = {
    'fp16':   os.path.join(SIM_BASE, 'Hadamard_sim', 'behav', 'xsim'),
    'int8':   os.path.join(SIM_BASE, 'hadamard_int8', 'behav', 'xsim'),
    'gather': os.path.join(SIM_BASE, 'sim_1', 'behav', 'xsim'),
    'resize': os.path.join(SIM_BASE, 'resize_sim', 'behav', 'xsim'),
}

OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))
EXPECT_DIR = os.path.join(os.path.dirname(OUTPUT_DIR), 'expect')

FILE_MAP = {
    'fp16':   'fwht-output-fp16',
    'int8':   'fwht-output-int8',
    'gather': 'gather-output',
    'resize': 'resize-output',
}

EXPECT_MAP = {
    'fp16':   'fwht-expected-fp16.txt',
    'int8':   'fwht-expected-int8.txt',
    'gather': 'gather-expected.txt',
    'resize': 'resize-expected.txt',
}


def copy_and_convert(sim_dir: str, name: str):
    """Copy .mem from sim dir to output dir, then convert to .txt."""
    mem_file = f"{name}.mem"
    src = os.path.join(sim_dir, mem_file)
    dst_mem = os.path.join(OUTPUT_DIR, mem_file)
    dst_txt = os.path.join(OUTPUT_DIR, f"{name}.txt")

    if not os.path.exists(src):
        print(f"  SKIP: {src} not found")
        return False

    shutil.copy2(src, dst_mem)
    block_count = 0
    with open(dst_mem, 'r') as f_in:
        lines = [l.strip() for l in f_in if l.strip() and not l.startswith('#')]
        block_count = len(lines)
        with open(dst_txt, 'w') as f_out:
            for line in lines:
                f_out.write(line + '\n')

    print(f"  OK: {mem_file} -> copied + {name}.txt ({block_count} blocks)")
    return True


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Copy Vivado .mem and convert to .txt")
    parser.add_argument('--src', default=None, help='Vivado xsim directory (overrides defaults)')
    parser.add_argument('--fp16', action='store_true', help='FP16 only')
    parser.add_argument('--int8', action='store_true', help='INT8 only')
    parser.add_argument('--gather', action='store_true', help='Gather only')
    parser.add_argument('--resize', action='store_true', help='Resize only')
    parser.add_argument('--all', action='store_true', help='All modes (default if no --mode specified)')
    args = parser.parse_args()

    print(f"Output dir: {OUTPUT_DIR}")

    # Determine which modes to run
    mode_flags = [args.fp16, args.int8, args.gather, args.resize]
    if any(mode_flags):
        modes = [m for m, flag in zip(['fp16', 'int8', 'gather', 'resize'], mode_flags) if flag]
    else:
        modes = ['fp16', 'int8', 'gather', 'resize']

    ok = 0
    for mode in modes:
        name = FILE_MAP[mode]
        sim_dir = args.src if args.src else SIM_DIRS[mode]
        print(f"\n[{mode.upper()}] Source: {sim_dir}")
        if copy_and_convert(sim_dir, name):
            ok += 1

    print(f"\nDone: {ok}/{len(modes)} converted.")

    if ok > 0:
        print("\nCompare with golden:")
        for mode in modes:
            name = FILE_MAP[mode]
            expect = EXPECT_MAP[mode]
            print(f"  diff {OUTPUT_DIR}/{name}.txt {EXPECT_DIR}/{expect}")


if __name__ == "__main__":
    main()
