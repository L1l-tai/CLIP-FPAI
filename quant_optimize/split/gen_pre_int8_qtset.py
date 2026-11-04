#!/usr/bin/env python3
"""生成 seg_pre 的 INT8 校准集（float32 .bin，NHWC 归一化，与硬件一致）

toml 声明 inputs=[1,224,224,3] NHWC + pre_method=nop（不做归一化），
说明归一化在 CPU 侧完成，因此校准数据必须是**已归一化**的 float32。
按 短边 resize 224 + center crop 处理（与板上一致）。
"""
import os
import numpy as np
import cv2

PROJ = "/mnt/d/icraft-docker/Ubuntu20.04/clip-vit-base-patch32-zg"
SRC = f"{PROJ}/qtset/imagenet"
OUT = f"{PROJ}/qtset/pre_int8"
LIST = f"{PROJ}/qtset/pre_int8.txt"
MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)

os.makedirs(OUT, exist_ok=True)
files = sorted([f for f in os.listdir(SRC) if f.lower().endswith(('.jpg', '.jpeg', '.png'))])
lines = []
for i, fn in enumerate(files):
    img = cv2.imread(os.path.join(SRC, fn))
    if img is None:
        continue
    h, w = img.shape[:2]
    scale = 224 / min(h, w)
    nh, nw = int(round(h * scale)), int(round(w * scale))
    img = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    top, left = (nh - 224) // 2, (nw - 224) // 2
    img = img[top:top + 224, left:left + 224]
    img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    x = (img.astype(np.float32) / 255.0 - MEAN) / STD     # 归一化（NHWC）
    name = f'pre_{i:03d}.bin'
    x.astype(np.float32).tofile(os.path.join(OUT, name))
    lines.append(name)
    if (i + 1) % 25 == 0:
        print(f'  {i+1}/{len(files)}', flush=True)

open(LIST, 'w').write('\n'.join(lines))
print(f'生成 {len(lines)} 个校准 bin（NHWC 归一化 [224,224,3] float32）')
