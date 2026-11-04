#!/usr/bin/env python3
"""生成 seg_post 的四输入 INT8 校准集（[残差, q_rot, k_rot, v_rot]）

输入图片取自 qtset/imagenet，经 seg_pre(FP32) → FWHT(exact) 生成校准特征。
输出：qtset/post_int8/{res,rot}_{i:03d}.bin + qtset/post_int8.txt
（txt 每行 4 个文件名，分号分隔，顺序 = [残差, q, k, v]）
"""
import os
import sys

import numpy as np
import onnxruntime as ort

PROJ = "/mnt/d/icraft-docker/Ubuntu20.04/clip-vit-base-patch32-zg"
sys.path.insert(0, f"{PROJ}/quant_optimize/split")
from eval_fwht_accuracy import preprocess, fwht_768, SEG_PRE

OUT_DIR = f"{PROJ}/qtset/post_int8"
LIST = f"{PROJ}/qtset/post_int8.txt"
N = 100

os.makedirs(OUT_DIR, exist_ok=True)
so = ort.SessionOptions(); so.log_severity_level = 3; so.intra_op_num_threads = 8
s_pre = ort.InferenceSession(SEG_PRE, so, providers=['CPUExecutionProvider'])

img_dir = f"{PROJ}/qtset/imagenet"
names = sorted([f for f in os.listdir(img_dir) if f.lower().endswith(('.jpg', '.jpeg', '.png'))])[:N]
print(f'校准图片 {len(names)} 张', flush=True)

lines = []
for i, fn in enumerate(names):
    x = preprocess(os.path.join(img_dir, fn))
    if x is None:
        continue
    resid, ln1 = s_pre.run(None, {s_pre.get_inputs()[0].name: x})
    rot = fwht_768(ln1, 'exact')
    nr, no = f'res_{i:03d}.bin', f'rot_{i:03d}.bin'
    resid.astype(np.float32).tofile(os.path.join(OUT_DIR, nr))
    rot.astype(np.float32).tofile(os.path.join(OUT_DIR, no))
    lines.append(f'{nr};{no};{no};{no}')     # [残差, q, k, v]
    if (i + 1) % 20 == 0:
        print(f'  {i+1}/{len(names)}', flush=True)

open(LIST, 'w').write('\n'.join(lines))
print(f'写出校准清单 {LIST}（{len(lines)} 行）')
print('样例:', lines[0])
