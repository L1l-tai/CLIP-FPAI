#!/usr/bin/env python3
"""
FWHT 硬算子精度影响评估 —— ImageNet-1K 零样本分类

对比两种 FWHT 实现：
  exact : float64 精确蝶形（= FP32 理想参考）
  fp16  : 模拟板上 FPGA 行为（输入转 FP16，每级蝶形加减后舍入 FP16）

链路：image → seg_pre(NPU/FP32) → [残差, LN1] → FWHT(LN1) → rot → seg_post → image_embeds
     → 与 1000 类文本嵌入算相似度 → top-1

用法：
  python eval_fwht_accuracy.py --limit 500
"""
import argparse
import json
import os
import sys
import time

import cv2
import numpy as np
import onnxruntime as ort

PROJ = "/mnt/d/icraft-docker/Ubuntu20.04/clip-vit-base-patch32-zg"
SEG_PRE  = f"{PROJ}/fmodel/vision/split/vit_seg_pre_fixed.onnx"
SEG_POST = f"{PROJ}/fmodel/vision/split/vit_seg_post_fixed.onnx"
TEXT_ONNX = f"{PROJ}/fmodel/text/text_model.onnx"
CLASSES_TXT = f"{PROJ}/web_ui/imagenet_classes.txt"

IMAGENET = "/mnt/d/Curv-CAF-e2e/imagenet"
VAL_DIR = f"{IMAGENET}/val"
GT_TXT = f"{IMAGENET}/ILSVRC2012_devkit_t12/data/ILSVRC2012_validation_ground_truth.txt"
TOK_DIR = "/tmp/clip_tok"

MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)

NAME_RESID = "/vision_model/pre_layrnorm/Add_1_output_0"
NAME_LN1 = "/vision_model/encoder/layers.0/layer_norm1/Add_1_output_0"


# ---------------- CLIP BPE tokenizer（无 transformers 依赖） ----------------
class ClipTokenizer:
    def __init__(self, vocab_json, merges_txt):
        self.enc = json.load(open(vocab_json, encoding="utf-8"))
        self.bpe_ranks = {}
        with open(merges_txt, encoding="utf-8") as f:
            lines = f.read().strip().split("\n")[1:]      # 跳过 #version
            for i, line in enumerate(lines):
                p = line.strip().split()
                if len(p) == 2:
                    self.bpe_ranks[(p[0], p[1])] = i
        self.byte_enc = self._bytes_to_unicode()

    @staticmethod
    def _bytes_to_unicode():
        bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) \
             + list(range(ord("®"), ord("ÿ") + 1))
        cs = bs[:]
        n = 0
        for b in range(256):
            if b not in bs:
                bs.append(b)
                cs.append(256 + n)
                n += 1
        return dict(zip(bs, [chr(c) for c in cs]))

    def _bpe(self, token):
        word = tuple(token[:-1]) + (token[-1] + "</w>",)
        if not word:
            return []
        while True:
            pairs = [(word[i], word[i + 1]) for i in range(len(word) - 1)]
            cand = [(self.bpe_ranks[p], p) for p in pairs if p in self.bpe_ranks]
            if not cand:
                break
            bigram = min(cand)[1]
            first, second = bigram
            new_word, i = [], 0
            while i < len(word):
                try:
                    j = word.index(first, i)
                except ValueError:
                    new_word.extend(word[i:])
                    break
                new_word.extend(word[i:j])
                i = j
                if i < len(word) - 1 and word[i] == first and word[i + 1] == second:
                    new_word.append(first + second)
                    i += 2
                else:
                    new_word.append(word[i])
                    i += 1
            word = tuple(new_word)
            if len(word) == 1:
                break
        return list(word)

    def encode(self, text, ctx=77):
        ids = []
        for tok in text.strip().lower().split():
            for piece in self._bpe("".join(self.byte_enc[b] for b in tok.encode("utf-8"))):
                if piece in self.enc:
                    ids.append(self.enc[piece])
        ids = [self.enc["<|startoftext|>"]] + ids + [self.enc["<|endoftext|>"]]
        ids = ids[:ctx]
        while len(ids) < ctx:
            ids.append(0)     # CLIP pad = 0
        return ids


# ---------------- FWHT 实现 ----------------
def fwht_64_exact(x):
    r = np.asarray(x, dtype=np.float64).copy()
    n, step = len(r), 1
    while step < n:
        for i in range(0, n, step * 2):
            a = r[i:i + step].copy()
            b = r[i + step:i + 2 * step].copy()
            r[i:i + step] = a + b
            r[i + step:i + 2 * step] = a - b
        step *= 2
    return r.astype(np.float32)


def fwht_64_fp16(x):
    """模拟板上 FPGA：输入转 FP16，每级蝶形加减后舍入 FP16"""
    r = np.asarray(x, dtype=np.float16).copy()
    n, step = len(r), 1
    while step < n:
        for i in range(0, n, step * 2):
            a = r[i:i + step].astype(np.float16)
            b = r[i + step:i + 2 * step].astype(np.float16)
            r[i:i + step] = (a + b).astype(np.float16)
            r[i + step:i + 2 * step] = (a - b).astype(np.float16)
        step *= 2
    return r.astype(np.float32)


def fwht_768(x, mode):
    """[1,50,768] → 12 组 64 点局部 FWHT"""
    fn = fwht_64_exact if mode == "exact" else fwht_64_fp16
    v = np.asarray(x, dtype=np.float32).reshape(-1, 768)
    out = np.empty((v.shape[0], 768), dtype=np.float32)
    for r in range(v.shape[0]):
        for g in range(12):
            out[r, g * 64:(g + 1) * 64] = fn(v[r, g * 64:(g + 1) * 64])
    return out.reshape(x.shape)


# ---------------- 预处理 ----------------
def preprocess(path, size=224):
    """与硬件一致：短边 resize 到 size + 中心裁剪 size×size（CLIP 官方预处理）"""
    img = cv2.imread(path)
    if img is None:
        return None
    h, w = img.shape[:2]
    scale = size / min(h, w)
    nh, nw = int(round(h * scale)), int(round(w * scale))
    img = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    top = (nh - size) // 2
    left = (nw - size) // 2
    img = img[top:top + size, left:left + size]
    img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    x = (img.astype(np.float32) / 255.0 - MEAN) / STD
    return np.transpose(x, (2, 0, 1))[None].astype(np.float32)   # [1,3,224,224]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=500, help="评估图片数（0=全部 46109）")
    ap.add_argument("--stride", type=int, default=1, help="抽样步长")
    ap.add_argument("--out", default="/tmp/fwht_acc_result.json")
    args = ap.parse_args()

    so = ort.SessionOptions()
    so.log_severity_level = 3
    so.intra_op_num_threads = 8

    print("[1/4] 载入模型 …", flush=True)
    t0 = time.time()
    s_pre = ort.InferenceSession(SEG_PRE, so, providers=["CPUExecutionProvider"])
    s_post = ort.InferenceSession(SEG_POST, so, providers=["CPUExecutionProvider"])
    s_text = ort.InferenceSession(TEXT_ONNX, so, providers=["CPUExecutionProvider"])
    print(f"      完成 {time.time()-t0:.1f}s", flush=True)

    print("[2/4] 文本嵌入（1000 类 prompt）…", flush=True)
    classes = [l.strip() for l in open(CLASSES_TXT, encoding="utf-8") if l.strip()]
    print(f"      类别数 = {len(classes)}")
    tok = ClipTokenizer(f"{TOK_DIR}/vocab.json", f"{TOK_DIR}/merges.txt")
    ids = np.array([tok.encode(f"a photo of a {c}") for c in classes], dtype=np.int64)
    text_out = s_text.run(None, {s_text.get_inputs()[0].name: ids})[0]
    text_feat = text_out.reshape(-1, 512)
    text_feat = text_feat / (np.linalg.norm(text_feat, axis=1, keepdims=True) + 1e-12)
    print(f"      text_feat {text_feat.shape}", flush=True)

    print("[3/4] 准备 ImageNet 样本 …", flush=True)
    gt = [int(x) for x in open(GT_TXT).read().split()]
    names = sorted(os.listdir(VAL_DIR))
    items = []
    for i, fn in enumerate(names):
        if i % args.stride != 0:
            continue
        idx = int(fn.split("_")[-1].split(".")[0]) - 1     # val_00000001 → 0
        if idx >= len(gt):
            continue
        items.append((os.path.join(VAL_DIR, fn), gt[idx] - 1))   # gt 是 1-based
        if args.limit and len(items) >= args.limit:
            break
    print(f"      样本数 = {len(items)}", flush=True)

    print("[4/4] 推理对比 …", flush=True)
    modes = ["exact", "fp16"]
    correct = {m: 0 for m in modes}
    emb_cos = []
    n_done = 0
    t_start = time.time()

    for k, (path, label) in enumerate(items):
        x = preprocess(path)
        if x is None:
            continue
        resid, ln1 = s_pre.run(None, {s_pre.get_inputs()[0].name: x})
        embs = {}
        for m in modes:
            rot = fwht_768(ln1, m)
            post_in = {
                NAME_RESID: resid,
                "/vision_model/encoder/layers.0/self_attn/q_proj/MatMul_hadamard_rotated_output": rot,
                "/vision_model/encoder/layers.0/self_attn/k_proj/MatMul_hadamard_rotated_output": rot,
                "/vision_model/encoder/layers.0/self_attn/v_proj/MatMul_hadamard_rotated_output": rot,
            }
            emb = s_post.run(None, post_in)[0].reshape(-1)
            embs[m] = emb
            e = emb / (np.linalg.norm(emb) + 1e-12)
            sims = text_feat @ e
            if int(np.argmax(sims)) == label:
                correct[m] += 1
        # exact vs fp16 的 embedding 相似度
        a, b = embs["exact"], embs["fp16"]
        emb_cos.append(float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12)))
        n_done += 1
        if n_done % 50 == 0:
            el = time.time() - t_start
            eta = el / n_done * (len(items) - n_done)
            print(f"      {n_done}/{len(items)}  exact={100*correct['exact']/n_done:.2f}%"
                  f"  fp16={100*correct['fp16']/n_done:.2f}%  "
                  f"emb_cos={np.mean(emb_cos):.6f}  ETA {eta/60:.1f}min", flush=True)

    res = {
        "n": n_done,
        "acc_exact": 100.0 * correct["exact"] / max(n_done, 1),
        "acc_fp16": 100.0 * correct["fp16"] / max(n_done, 1),
        "acc_diff": 100.0 * (correct["exact"] - correct["fp16"]) / max(n_done, 1),
        "emb_cos_mean": float(np.mean(emb_cos)) if emb_cos else None,
        "emb_cos_min": float(np.min(emb_cos)) if emb_cos else None,
        "correct_exact": correct["exact"],
        "correct_fp16": correct["fp16"],
    }
    print("\n================ 结果 ================")
    for k, v in res.items():
        print(f"  {k}: {v}")
    json.dump(res, open(args.out, "w"), indent=2)
    print(f"已保存 {args.out}")


if __name__ == "__main__":
    main()
