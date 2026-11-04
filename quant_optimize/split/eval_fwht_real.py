#!/usr/bin/env python3
"""
FWHT 硬算子精度影响 —— ImageNet-1K 真实评估（标签映射对齐 dapa_repro.py）

三条链路对比：
  A. 原始 FP32 模型（clip_vit_b32.onnx，无 Hadamard）        → 基线
  B. seg_pre + FWHT(exact) + seg_post                        → 理想 FP32 含 Hadamard
  C. seg_pre + FWHT(fp16 ) + seg_post                        → 模拟板上 FPGA（FP16 舍入）

关键指标：B − C = **FWHT 硬件实现引入的精度损失真实值**

用法: python eval_fwht_real.py [N]     (N=样本数, 默认 1000)
"""
import sys, os, json, time
import numpy as np
import onnxruntime as ort
import scipy.io as sio

sys.path.insert(0, '/mnt/d/icraft-docker/Ubuntu20.04/clip-vit-base-patch32-zg/quant_optimize/split')
from eval_fwht_accuracy import (ClipTokenizer, preprocess, fwht_768, SEG_PRE, SEG_POST,
                                TEXT_ONNX, CLASSES_TXT, VAL_DIR, NAME_RESID)

PROJ = "/mnt/d/icraft-docker/Ubuntu20.04/clip-vit-base-patch32-zg"
ORIG = f"{PROJ}/fmodel/vision/clip_vit_b32.onnx"
DEVKIT = "/mnt/d/Curv-CAF-e2e/imagenet/ILSVRC2012_devkit_t12"

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/fwht_real_result.json"

# ---------------- 正确标签映射（同 ViT/dapa_repro/scripts/dapa_repro.py） ----------------
meta = sio.loadmat(os.path.join(DEVKIT, 'data', 'meta.mat'), squeeze_me=True)['synsets']
gt = [int(x) for x in open(os.path.join(DEVKIT, 'data',
      'ILSVRC2012_validation_ground_truth.txt')).read().split()]
id2wnid = {}
for i in range(len(meta)):
    iid = int(meta[i]['ILSVRC2012_ID'])
    if 1 <= iid <= 1000:
        id2wnid[iid] = str(meta[i]['WNID']).strip()
w2a = {w: i for i, w in enumerate(sorted(id2wnid.values()))}


def label_of(fn):
    idx = int(os.path.basename(fn).replace('ILSVRC2012_val_', '').replace('.JPEG', '')) - 1
    return w2a[id2wnid[gt[idx]]]


def main():
    so = ort.SessionOptions()
    so.log_severity_level = 3
    so.intra_op_num_threads = 8

    print('[load] 三个模型 …', flush=True)
    s_orig = ort.InferenceSession(ORIG, so, providers=['CPUExecutionProvider'])
    s_pre = ort.InferenceSession(SEG_PRE, so, providers=['CPUExecutionProvider'])
    s_post = ort.InferenceSession(SEG_POST, so, providers=['CPUExecutionProvider'])
    s_text = ort.InferenceSession(TEXT_ONNX, so, providers=['CPUExecutionProvider'])

    classes = [l.strip() for l in open(CLASSES_TXT, encoding='utf-8') if l.strip()]
    tok = ClipTokenizer('/tmp/clip_tok/vocab.json', '/tmp/clip_tok/merges.txt')
    ids = np.array([tok.encode(f'a photo of a {c}') for c in classes], dtype=np.int64)
    tf = s_text.run(None, {s_text.get_inputs()[0].name: ids})[0].reshape(-1, 512)
    tf_n = tf / (np.linalg.norm(tf, axis=1, keepdims=True) + 1e-12)

    files = sorted(os.listdir(VAL_DIR))[:N]
    post_inputs = [i.name for i in s_post.get_inputs()]

    acc = {'A_orig_fp32': 0, 'B_exact': 0, 'C_fp16': 0}
    n = 0
    agree_B_C = 0
    emb_cos = []
    rot_cos = []
    t0 = time.time()

    for fn in files:
        p = os.path.join(VAL_DIR, fn)
        x = preprocess(p)
        if x is None:
            continue
        lb = label_of(fn)

        def classify(emb):
            e = emb / (np.linalg.norm(emb) + 1e-12)
            return int(np.argmax(tf_n @ e))

        # A) 原始 FP32（无 Hadamard）
        embA = s_orig.run(None, {s_orig.get_inputs()[0].name: x})[0].reshape(-1)
        acc['A_orig_fp32'] += (classify(embA) == lb)

        # 切分链路
        resid, ln1 = s_pre.run(None, {s_pre.get_inputs()[0].name: x})
        embs = {}
        rots = {}
        for m in ('exact', 'fp16'):
            rot = fwht_768(ln1, m)
            feed = {post_inputs[0]: resid, post_inputs[1]: rot,
                    post_inputs[2]: rot, post_inputs[3]: rot}
            embs[m] = s_post.run(None, feed)[0].reshape(-1)
            rots[m] = rot
        acc['B_exact'] += (classify(embs['exact']) == lb)
        acc['C_fp16'] += (classify(embs['fp16']) == lb)

        agree_B_C += (classify(embs['exact']) == classify(embs['fp16']))
        a, b = embs['exact'], embs['fp16']
        emb_cos.append(float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12)))
        ra, rb = rots['exact'].reshape(-1), rots['fp16'].reshape(-1)
        rot_cos.append(float(ra @ rb / (np.linalg.norm(ra) * np.linalg.norm(rb) + 1e-12)))

        n += 1
        if n % 100 == 0:
            el = time.time() - t0
            print(f'  {n}/{len(files)}  A={100*acc["A_orig_fp32"]/n:.2f}%  '
                  f'B={100*acc["B_exact"]/n:.2f}%  C={100*acc["C_fp16"]/n:.2f}%  '
                  f'一致={100*agree_B_C/n:.1f}%  emb_cos={np.mean(emb_cos):.7f}  '
                  f'{el:.0f}s ETA {el/n*(len(files)-n)/60:.1f}min', flush=True)

    res = {
        'n': n,
        'A_orig_fp32_acc': 100.0 * acc['A_orig_fp32'] / max(n, 1),
        'B_exact_acc': 100.0 * acc['B_exact'] / max(n, 1),
        'C_fp16_acc': 100.0 * acc['C_fp16'] / max(n, 1),
        'B_minus_C_pp': 100.0 * (acc['B_exact'] - acc['C_fp16']) / max(n, 1),
        'B_C_same_count': agree_B_C,
        'B_C_agree_pct': 100.0 * agree_B_C / max(n, 1),
        'emb_cos_mean': float(np.mean(emb_cos)),
        'emb_cos_min': float(np.min(emb_cos)),
        'rot_cos_mean': float(np.mean(rot_cos)),
        'rot_cos_min': float(np.min(rot_cos)),
    }
    print('\n================ 结果 ================')
    for k, v in res.items():
        print(f'  {k}: {v}')
    json.dump(res, open(OUT, 'w'), indent=2)
    print(f'已保存 {OUT}')


if __name__ == '__main__':
    main()
