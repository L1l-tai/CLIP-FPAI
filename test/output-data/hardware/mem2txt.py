"""
Copy .mem from Vivado sim directory and convert to .txt for comparison.

Usage:
    python mem2txt.py                                           # default paths
    python mem2txt.py --src D:/path/to/xsim                     # custom sim dir
    python mem2txt.py --fp16                                    # FP16 only
    python mem2txt.py --int8                                    # INT8 only
"""

import sys
import os
import shutil
import glob

# Default Vivado simulation directories (relative to project root)
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
SIM_BASE = os.path.join(PROJECT_ROOT, 'FPGA', '30TAI-PRJ', '30TAI-PRJ.sim')

SIM_DIRS = {
    'fp16': os.path.join(SIM_BASE, 'Hadamard_sim', 'behav', 'xsim'),
    'int8': os.path.join(SIM_BASE, 'hadamard_int8', 'behav', 'xsim'),
}

OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))

FILE_MAP = {
    'fp16': 'fwht-output-fp16',
    'int8': 'fwht-output-int8',
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

    print(f"  OK: {mem_file} → copied + {name}.txt ({block_count} blocks)")
    return True


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Copy Vivado .mem and convert to .txt")
    parser.add_argument('--src', default=None, help='Vivado xsim directory (overrides defaults)')
    parser.add_argument('--fp16', action='store_true', help='FP16 only')
    parser.add_argument('--int8', action='store_true', help='INT8 only')
    args = parser.parse_args()

    print(f"Output dir: {OUTPUT_DIR}")

    if args.src:
        sim_dirs = {'fp16': args.src, 'int8': args.src}
    else:
        sim_dirs = SIM_DIRS

    modes = []
    if args.fp16 and not args.int8:
        modes = ['fp16']
    elif args.int8 and not args.fp16:
        modes = ['int8']
    else:
        modes = ['fp16', 'int8']

    ok = 0
    for mode in modes:
        name = FILE_MAP[mode]
        sim_dir = sim_dirs[mode]
        print(f"\n[{mode.upper()}] Source: {sim_dir}")
        if copy_and_convert(sim_dir, name):
            ok += 1

    print(f"\nDone: {ok}/{len(modes)} converted.")

    if ok > 0:
        print("\nCompare with golden:")
        expect_dir = os.path.join(os.path.dirname(OUTPUT_DIR), 'expect')
        for mode in modes:
            name = FILE_MAP[mode]
            print(f"  diff {OUTPUT_DIR}/{name}.txt {expect_dir}/fwht-expected-{mode}.txt")


if __name__ == "__main__":
    main()
