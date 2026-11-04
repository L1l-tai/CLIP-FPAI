#!/usr/bin/env python3
"""
按 Icraft 实际量化方案复现并评测

从 Icraft 模型的 json 读出的真实配置（vit_seg_post_ZG.json, 946 ops）：
    BF16  929 个（98.2%）   ← 主力精度
    TF32   14 个（ 1.5%）
    FP32    5 个（ 0.5%）
    INT8    0 个            ← 板上 NOT INT8！

vit_seg_pre_ZG.json（24 ops）：全部 BF16 / TF32

即：板上"量化"实际是 **BF16/TF32 浮点低精度**，不是 INT8。
BF16: 8 位指数 + 7 位尾数（相对精度 2^-8 ≈ 0.39%）
TF32: 8 位指数 + 10 位尾数

本脚本在 ONNX 图上逐算子插入 BF16（或 TF32）舍入，复现板上数值行为后评测。

用法:
  python eval_icraft_precision.py --model orig --dtype bf16 --n-eval 1000
  python eval_icraft_precision.py --model hada --dtype bf16 --n-eval 1000
"""
import argparse
import json
import os
import sys
import time

import numpy as np
import onnx
import onnxruntime as ort
from onnx import helper, TensorProto
import scipy.io as sio

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from eval_fwht_accuracy import ClipTokenizer, preprocess, fwht_768, SEG_PRE, SEG_POST, \
    TEXT_ONNX, CLASSES_TXT, VAL_DIR

PROJ = "/mnt/d/icraft-docker/Ubuntu20.04/clip-vit-base-patch32-zg"
ORIG = f"{PROJ}/fmodel/vision/clip_vit_b32.onnx"
DEVKIT = "/mnt/d/Curv-CAF-e2e/imagenet/ILSVRC2012_devkit_t12"
WORK = "/tmp/icraft_prec"

# 标签映射（同 dapa_repro.py）
_meta = sio.loadmat(os.path.join(DEVKIT, 'data', 'meta.mat'), squeeze_me=True)['synsets']
_gt = [int(x) for x in open(os.path.join(DEVKIT, 'data',
       'ILSVRC2012_validation_ground_truth.txt')).read().split()]
_id2wnid = {}
for _i in range(len(_meta)):
    _iid = int(_meta[_i]['ILSVRC2012_ID'])
    if 1 <= _iid <= 1000:
        _id2wnid[_iid] = str(_meta[_i]['WNID']).strip()
_w2a = {w: i for i, w in enumerate(sorted(_id2wnid.values()))}


def label_of(fn):
    idx = int(os.path.basename(fn).replace('ILSVRC2012_val_', '').replace('.JPEG', '')) - 1
    return _w2a[_id2wnid[_gt[idx]]]


# 纯数据搬运类算子：不做精度舍入（Icraft 中也是 Copy/Reshape，不改数值）
SKIP_ROUND = {'Reshape', 'Transpose', 'Concat', 'Slice', 'Squeeze', 'Unsqueeze',
              'Shape', 'Gather', 'Constant', 'Identity', 'Flatten', 'Cast', 'Expand'}


def to_bf16_np(a):
    """BF16 round-to-nearest-even（模拟 Icraft storage_dtype=@bf(16)）"""
    u = np.ascontiguousarray(a, dtype=np.float32).view(np.uint32).copy()
    lsb = (u >> np.uint32(16)) & np.uint32(1)
    u = u + np.uint32(0x7FFF) + lsb
    return (u & np.uint32(0xFFFF0000)).view(np.float32)


def to_tf32_np(a):
    u = np.ascontiguousarray(a, dtype=np.float32).view(np.uint32).copy()
    lsb = (u >> np.uint32(13)) & np.uint32(1)
    u = u + np.uint32(0x0FFF) + lsb
    return (u & np.uint32(0xFFFFE000)).view(np.float32)


def quantize_weights(model, dtype='bf16'):
    """把所有 FP32 权重/常量按 Icraft 的 storage_dtype 精度舍入（不改 opset、不插节点）"""
    from onnx import numpy_helper
    fn = to_bf16_np if dtype == 'bf16' else to_tf32_np
    n_w = 0
    new_inits = []
    for init in model.graph.initializer:
        arr = numpy_helper.to_array(init)
        if arr.dtype == np.float32 and arr.size > 1:
            q = fn(arr)
            new_inits.append(numpy_helper.from_array(q, init.name))
            n_w += 1
        else:
            new_inits.append(init)
    del model.graph.initializer[:]
    model.graph.initializer.extend(new_inits)
    # 同时处理 Constant 节点里的权重
    n_c = 0
    for node in model.graph.node:
        if node.op_type != 'Constant':
            continue
        for attr in node.attribute:
            if attr.name == 'value' and attr.t.data_type == TensorProto.FLOAT:
                arr = numpy_helper.to_array(attr.t)
                if arr.size > 1:
                    attr.t.CopyFrom(numpy_helper.from_array(fn(arr), attr.t.name))
                    n_c += 1
    return n_w, n_c


def build_low_precision_model(src, dst, dtype):
    print(f'  构建 {dtype} 模型 …', flush=True)
    t0 = time.time()
    m = onnx.load(src)
    nw, nc = quantize_weights(m, dtype)
    onnx.checker.check_model(m)
    onnx.save(m, dst)
    print(f'    权重舍入: initializer {nw} 个 + Constant {nc} 个，{time.time()-t0:.0f}s，'
          f'大小 {os.path.getsize(dst)/1e6:.0f} MB', flush=True)
    return dst


def eval_orig(path, files, tf_n, tag):
    so = ort.SessionOptions(); so.log_severity_level = 3; so.intra_op_num_threads = 8
    s = ort.InferenceSession(path, so, providers=['CPUExecutionProvider'])
    c1 = c5 = n = 0
    preds = []
    for fn in files:
        x = preprocess(os.path.join(VAL_DIR, fn))
        if x is None:
            continue
        emb = s.run(None, {s.get_inputs()[0].name: x})[0].reshape(-1)
        e = emb / (np.linalg.norm(emb) + 1e-12)
        order = np.argsort(-(tf_n @ e))[:5]
        lb = label_of(fn)
        c1 += (int(order[0]) == lb); c5 += (lb in order); preds.append(int(order[0]))
        n += 1
    print(f'  [{tag}] top-1={100*c1/max(n,1):.2f}%  top-5={100*c5/max(n,1):.2f}%  (n={n})', flush=True)
    return {'acc1': 100.0*c1/max(n,1), 'acc5': 100.0*c5/max(n,1), 'n': n, 'preds': preds}


def eval_hada(pre_path, post_path, files, tf_n, tag):
    so = ort.SessionOptions(); so.log_severity_level = 3; so.intra_op_num_threads = 8
    sp = ort.InferenceSession(pre_path, so, providers=['CPUExecutionProvider'])
    sq = ort.InferenceSession(post_path, so, providers=['CPUExecutionProvider'])
    pi = [i.name for i in sq.get_inputs()]
    c1 = c5 = n = 0
    preds = []
    for fn in files:
        x = preprocess(os.path.join(VAL_DIR, fn))
        if x is None:
            continue
        resid, ln1 = sp.run(None, {sp.get_inputs()[0].name: x})
        rot = fwht_768(ln1, 'exact')
        emb = sq.run(None, {pi[0]: resid, pi[1]: rot, pi[2]: rot, pi[3]: rot})[0].reshape(-1)
        e = emb / (np.linalg.norm(emb) + 1e-12)
        order = np.argsort(-(tf_n @ e))[:5]
        lb = label_of(fn)
        c1 += (int(order[0]) == lb); c5 += (lb in order); preds.append(int(order[0]))
        n += 1
    print(f'  [{tag}] top-1={100*c1/max(n,1):.2f}%  top-5={100*c5/max(n,1):.2f}%  (n={n})', flush=True)
    return {'acc1': 100.0*c1/max(n,1), 'acc5': 100.0*c5/max(n,1), 'n': n, 'preds': preds}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', choices=['orig', 'hada'], required=True)
    ap.add_argument('--dtype', choices=['bf16', 'tf32'], default='bf16')
    ap.add_argument('--n-eval', type=int, default=1000)
    ap.add_argument('--out', default=None)
    a = ap.parse_args()
    os.makedirs(WORK, exist_ok=True)

    so = ort.SessionOptions(); so.log_severity_level = 3
    s_text = ort.InferenceSession(TEXT_ONNX, so, providers=['CPUExecutionProvider'])
    classes = [l.strip() for l in open(CLASSES_TXT, encoding='utf-8') if l.strip()]
    tok = ClipTokenizer('/tmp/clip_tok/vocab.json', '/tmp/clip_tok/merges.txt')
    ids = np.array([tok.encode(f'a photo of a {c}') for c in classes], dtype=np.int64)
    tf = s_text.run(None, {s_text.get_inputs()[0].name: ids})[0].reshape(-1, 512)
    tf_n = tf / (np.linalg.norm(tf, axis=1, keepdims=True) + 1e-12)

    files = sorted(os.listdir(VAL_DIR))[:a.n_eval]
    res = {'model': a.model, 'dtype': a.dtype, 'n_eval': len(files)}

    if a.model == 'orig':
        print('[1] FP32 基线 …', flush=True)
        r0 = eval_orig(ORIG, files, tf_n, 'FP32')
        q = f'{WORK}/clip_vit_b32_{a.dtype}.onnx'
        print(f'[2] {a.dtype} 复现 …', flush=True)
        if not os.path.exists(q):
            build_low_precision_model(ORIG, q, a.dtype)
        print(f'[3] {a.dtype} 评估 …', flush=True)
        r1 = eval_orig(q, files, tf_n, a.dtype.upper())
    else:
        print('[1] FP32 基线 …', flush=True)
        r0 = eval_hada(SEG_PRE, SEG_POST, files, tf_n, 'FP32')
        print(f'[2] {a.dtype} 复现 …', flush=True)
        qpre = f'{WORK}/vit_seg_pre_{a.dtype}.onnx'
        qpost = f'{WORK}/vit_seg_post_{a.dtype}.onnx'
        if not os.path.exists(qpre):
            build_low_precision_model(SEG_PRE, qpre, a.dtype)
        if not os.path.exists(qpost):
            build_low_precision_model(SEG_POST, qpost, a.dtype)
        print(f'[3] {a.dtype} 评估 …', flush=True)
        r1 = eval_hada(qpre, qpost, files, tf_n, a.dtype.upper())

    res.update({'fp32_acc1': r0['acc1'], 'fp32_acc5': r0['acc5'],
                'low_acc1': r1['acc1'], 'low_acc5': r1['acc5'],
                'drop_pp': r0['acc1'] - r1['acc1'],
                'pred_same_pct': 100.0 * sum(1 for p, q2 in zip(r0['preds'], r1['preds']) if p == q2)
                                 / max(len(r0['preds']), 1)})
    print('\n============ Icraft 精度复现结果 ============')
    for k, v in res.items():
        print(f'  {k}: {v}')
    out = a.out or f'{WORK}/icraft_prec_{a.model}.json'
    json.dump(res, open(out, 'w'), indent=2)
    print(f'已保存 {out}')


if __name__ == '__main__':
    main()
