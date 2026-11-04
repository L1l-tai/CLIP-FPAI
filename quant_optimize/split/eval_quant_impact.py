#!/usr/bin/env python3
"""
量化影响评测：FP32 vs INT8（ONNX Runtime PTQ 模拟 Icraft NPU 量化）

目的：量化 FWHT/Hadamard 的价值 —— 验证 Hadamard 变换是否能防止 INT8 量化掉点

对比：
  A. clip_vit_b32.onnx        （无 Hadamard）  FP32 → INT8
  B. seg_pre + seg_post       （有 Hadamard）  FP32 → INT8

用法：
  python eval_quant_impact.py --model orig --n-calib 100 --n-eval 1000
  python eval_quant_impact.py --model hada --n-calib 100 --n-eval 1000
"""
import argparse
import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort
import scipy.io as sio
from onnxruntime.quantization import quantize_static, CalibrationDataReader, QuantFormat, QuantType, CalibrationMethod

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from eval_fwht_accuracy import ClipTokenizer, preprocess, fwht_768, SEG_PRE, SEG_POST, \
    TEXT_ONNX, CLASSES_TXT, VAL_DIR

PROJ = "/mnt/d/icraft-docker/Ubuntu20.04/clip-vit-base-patch32-zg"
ORIG = f"{PROJ}/fmodel/vision/clip_vit_b32.onnx"
DEVKIT = "/mnt/d/Curv-CAF-e2e/imagenet/ILSVRC2012_devkit_t12"
WORK = "/tmp/quant_work"

# 正确标签映射（同 ViT/dapa_repro/scripts/dapa_repro.py）
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


class Reader(CalibrationDataReader):
    def __init__(self, files, input_name):
        self.items = []
        for fn in files:
            x = preprocess(os.path.join(VAL_DIR, fn))
            if x is not None:
                self.items.append({input_name: x})
        self.i = 0

    def get_next(self):
        if self.i >= len(self.items):
            return None
        d = self.items[self.i]
        self.i += 1
        return d

    def rewind(self):
        self.i = 0


def get_text_feat(sess):
    classes = [l.strip() for l in open(CLASSES_TXT, encoding='utf-8') if l.strip()]
    tok = ClipTokenizer('/tmp/clip_tok/vocab.json', '/tmp/clip_tok/merges.txt')
    ids = np.array([tok.encode(f'a photo of a {c}') for c in classes], dtype=np.int64)
    tf = sess.run(None, {sess.get_inputs()[0].name: ids})[0].reshape(-1, 512)
    return classes, tf / (np.linalg.norm(tf, axis=1, keepdims=True) + 1e-12)


def eval_orig(model_path, files, tf_n, use_fp16=False, tag=''):
    so = ort.SessionOptions(); so.log_severity_level = 3; so.intra_op_num_threads = 8
    s = ort.InferenceSession(model_path, so, providers=['CPUExecutionProvider'])
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
    return {'acc1': 100.0 * c1 / max(n, 1), 'acc5': 100.0 * c5 / max(n, 1), 'n': n, 'preds': preds}


def eval_hada(pre_path, post_path, files, tf_n, tag=''):
    so = ort.SessionOptions(); so.log_severity_level = 3; so.intra_op_num_threads = 8
    s_pre = ort.InferenceSession(pre_path, so, providers=['CPUExecutionProvider'])
    s_post = ort.InferenceSession(post_path, so, providers=['CPUExecutionProvider'])
    pi = [i.name for i in s_post.get_inputs()]
    c1 = c5 = n = 0
    preds = []
    for fn in files:
        x = preprocess(os.path.join(VAL_DIR, fn))
        if x is None:
            continue
        resid, ln1 = s_pre.run(None, {s_pre.get_inputs()[0].name: x})
        rot = fwht_768(ln1, 'exact')
        emb = s_post.run(None, {pi[0]: resid, pi[1]: rot, pi[2]: rot, pi[3]: rot})[0].reshape(-1)
        e = emb / (np.linalg.norm(emb) + 1e-12)
        order = np.argsort(-(tf_n @ e))[:5]
        lb = label_of(fn)
        c1 += (int(order[0]) == lb); c5 += (lb in order); preds.append(int(order[0]))
        n += 1
    print(f'  [{tag}] top-1={100*c1/max(n,1):.2f}%  top-5={100*c5/max(n,1):.2f}%  (n={n})', flush=True)
    return {'acc1': 100.0 * c1 / max(n, 1), 'acc5': 100.0 * c5 / max(n, 1), 'n': n, 'preds': preds}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', choices=['orig', 'hada'], required=True)
    ap.add_argument('--n-calib', type=int, default=100)
    ap.add_argument('--n-eval', type=int, default=1000)
    ap.add_argument('--calib', choices=['minmax','entropy'], default='entropy')
    ap.add_argument('--optypes', default='MatMul,Conv,Gemm',
                    help='只量化这些算子类型（混合精度），空字符串=全部量化')
    ap.add_argument('--out', default=None)
    a = ap.parse_args()
    os.makedirs(WORK, exist_ok=True)
    OPTYPES = [o.strip() for o in a.optypes.split(',') if o.strip()] or None
    tag_mp = ('mp_' + '_'.join(OPTYPES)) if OPTYPES else 'all'
    print(f'量化算子类型: {OPTYPES if OPTYPES else "全部"}', flush=True)

    so = ort.SessionOptions(); so.log_severity_level = 3
    s_text = ort.InferenceSession(TEXT_ONNX, so, providers=['CPUExecutionProvider'])
    classes, tf_n = get_text_feat(s_text)

    all_files = sorted(os.listdir(VAL_DIR))
    eval_files = all_files[:a.n_eval]
    calib_files = all_files[a.n_eval:a.n_eval + a.n_calib]
    print(f'评估 {len(eval_files)} 张 / 校准 {len(calib_files)} 张', flush=True)

    res = {'model': a.model, 'n_eval': len(eval_files), 'n_calib': len(calib_files)}

    if a.model == 'orig':
        print('[1] FP32 基线 …', flush=True)
        r_fp32 = eval_orig(ORIG, eval_files, tf_n, tag='orig FP32')
        # 量化
        print(f'[2] INT8 量化（per-channel, QDQ）…', flush=True)
        t0 = time.time()
        qmodel = f'{WORK}/clip_vit_b32_{tag_mp}_{a.calib}.onnx'
        if not os.path.exists(qmodel):
            reader = Reader(calib_files, 'pixel_values')
            quantize_static(
                ORIG, qmodel, reader,
                quant_format=QuantFormat.QOperator,
                per_channel=True,
                weight_type=QuantType.QInt8,
                activation_type=QuantType.QInt8,
                calibrate_method=(CalibrationMethod.Entropy if a.calib == 'entropy' else CalibrationMethod.MinMax),
                op_types_to_quantize=OPTYPES,
            )
        print(f'    量化完成 {time.time()-t0:.0f}s  大小 {os.path.getsize(qmodel)/1e6:.0f} MB', flush=True)
        print('[3] INT8 评估 …', flush=True)
        r_int8 = eval_orig(qmodel, eval_files, tf_n, tag='orig INT8')
        res.update({'fp32_acc1': r_fp32['acc1'], 'int8_acc1': r_int8['acc1'],
                    'drop_pp': r_fp32['acc1'] - r_int8['acc1'], 'fp32_acc5': r_fp32['acc5'],
                    'int8_acc5': r_int8['acc5'],
                    'pred_same_pct': 100.0 * sum(1 for p, q in zip(r_fp32['preds'], r_int8['preds']) if p == q) / max(len(r_fp32['preds']), 1)})
    else:
        print('[1] FP32/Hadamard 基线 …', flush=True)
        r_fp32 = eval_hada(SEG_PRE, SEG_POST, eval_files, tf_n, tag='hada FP32')
        print(f'[2] 量化 seg_pre / seg_post …', flush=True)
        qpre = f'{WORK}/vit_seg_pre_{tag_mp}_{a.calib}.onnx'
        qpost = f'{WORK}/vit_seg_post_{tag_mp}_{a.calib}.onnx'
        so2 = ort.SessionOptions(); so2.log_severity_level = 3
        t0 = time.time()
        if not os.path.exists(qpre):
            # seg_pre 输入名
            s_tmp = ort.InferenceSession(SEG_PRE, so2, providers=['CPUExecutionProvider'])
            reader = Reader(calib_files, s_tmp.get_inputs()[0].name)
            quantize_static(
                SEG_PRE, qpre, reader,
                quant_format=QuantFormat.QOperator,
                per_channel=True,
                weight_type=QuantType.QInt8,
                activation_type=QuantType.QInt8,
                calibrate_method=(CalibrationMethod.Entropy if a.calib == 'entropy' else CalibrationMethod.MinMax),
                op_types_to_quantize=OPTYPES,
            )
        if not os.path.exists(qpost):
            s_tmp2 = ort.InferenceSession(SEG_POST, so2, providers=['CPUExecutionProvider'])
            in_names = [i.name for i in s_tmp2.get_inputs()]

            class PostReader(CalibrationDataReader):
                def __init__(self):
                    self.files = calib_files
                    self.i = 0
                    s_p = ort.InferenceSession(SEG_PRE, so2, providers=['CPUExecutionProvider'])
                    self.sp = s_p
                    self.names = in_names

                def get_next(self):
                    while self.i < len(self.files):
                        fn = self.files[self.i]; self.i += 1
                        x = preprocess(os.path.join(VAL_DIR, fn))
                        if x is None:
                            continue
                        resid, ln1 = self.sp.run(None, {self.sp.get_inputs()[0].name: x})
                        rot = fwht_768(ln1, 'exact')
                        return {self.names[0]: resid, self.names[1]: rot,
                                self.names[2]: rot, self.names[3]: rot}
                    return None

            quantize_static(
                SEG_POST, qpost, PostReader(),
                quant_format=QuantFormat.QOperator,
                per_channel=True,
                weight_type=QuantType.QInt8,
                activation_type=QuantType.QInt8,
                calibrate_method=(CalibrationMethod.Entropy if a.calib == 'entropy' else CalibrationMethod.MinMax),
                op_types_to_quantize=OPTYPES,
            )
        print(f'    量化完成 {time.time()-t0:.0f}s  pre={os.path.getsize(qpre)/1e6:.1f}MB post={os.path.getsize(qpost)/1e6:.1f}MB', flush=True)
        print('[3] INT8 评估 …', flush=True)
        r_int8 = eval_hada(qpre, qpost, eval_files, tf_n, tag='hada INT8')
        res.update({'fp32_acc1': r_fp32['acc1'], 'int8_acc1': r_int8['acc1'],
                    'drop_pp': r_fp32['acc1'] - r_int8['acc1'], 'fp32_acc5': r_fp32['acc5'],
                    'int8_acc5': r_int8['acc5'],
                    'pred_same_pct': 100.0 * sum(1 for p, q in zip(r_fp32['preds'], r_int8['preds']) if p == q) / max(len(r_fp32['preds']), 1)})

    print('\n================ 量化影响 ================')
    for k, v in res.items():
        print(f'  {k}: {v}')
    out = a.out or f'/tmp/quant_impact_{a.model}.json'
    json.dump({k: v for k, v in res.items()}, open(out, 'w'), indent=2)
    print(f'已保存 {out}')


if __name__ == '__main__':
    main()
