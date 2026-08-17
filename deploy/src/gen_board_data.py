#!/usr/bin/env python3
"""生成板端文本编码数据文件 (token_emb.bin / pos_emb.bin / text_proj.bin / merges.txt)

从 fmodel/text/text_model.onnx 提取文本侧权重, 供板端 clip_app_split 等程序
在 data_dir (board_data/) 下加载。产出格式与 C++ 读取方一致 (float32 小端)。

用法:
    python3 gen_board_data.py --onnx fmodel/text/text_model.onnx \\
                              --merges processor/merges.txt \\
                              --outdir test/board_data/

注意:
    token_emb.bin : Token 嵌入表    49408×512 float32
    pos_emb.bin   : 位置嵌入表      77×512    float32
    text_proj.bin : 文本投影矩阵    512×512   float32
    merges.txt    : BPE 合并表 (拷贝自 processor/, 原样复制)
"""
import argparse
import numpy as np
import onnx
from onnx import numpy_helper
import os
import shutil

# 权重名 (text_model.onnx 实证, 见 fmodel/text 导出配置)
NAME_TOKEN_EMB  = "text_model.embeddings.token_embedding.weight"    # [49408, 512]
NAME_POS_EMB    = "text_model.embeddings.position_embedding.weight" # [77, 512]
NAME_TEXT_PROJ  = "onnx::MatMul_2539"                                # [512, 512] (输出 text_embeds 前 MatMul 权重)

# 期望维度 (防御性检查)
EXPECT = {
    NAME_TOKEN_EMB: (49408, 512),
    NAME_POS_EMB:   (77, 512),
    NAME_TEXT_PROJ: (512, 512),
}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--onnx", default="fmodel/text/text_model.onnx", help="文本模型 ONNX 路径")
    ap.add_argument("--merges", default="processor/merges.txt", help="BPE merges.txt 路径")
    ap.add_argument("--outdir", default="test/board_data/", help="输出目录 (板端 data_dir)")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    # ---- 加载 ONNX 权重 ----
    print(f"[load] {args.onnx}")
    m = onnx.load(args.onnx, load_external_data=False)
    weights = {t.name: numpy_helper.to_array(t) for t in m.graph.initializer}

    missing = [n for n in EXPECT if n not in weights]
    if missing:
        print(f"[ERROR] ONNX 缺少权重: {missing}")
        print("        可用权重示例:", [n for n in list(weights)[:5]])
        return 1

    # ---- 提取 + 防御性检查 ----
    for name, expect in EXPECT.items():
        w = weights[name]
        if w.shape != expect:
            print(f"[ERROR] {name} shape={w.shape} 期望 {expect}")
            return 1
        if w.dtype != np.float32:
            print(f"[WARN] {name} dtype={w.dtype}, 转 float32")
            w = w.astype(np.float32)
        weights[name] = np.ascontiguousarray(w)

    # ---- 写 bin (float32 小端) ----
    out_files = {
        NAME_TOKEN_EMB: "token_emb.bin",
        NAME_POS_EMB:   "pos_emb.bin",
        NAME_TEXT_PROJ: "text_proj.bin",
    }
    for name, fname in out_files.items():
        path = os.path.join(args.outdir, fname)
        weights[name].tofile(path)
        print(f"[save] {fname}: {weights[name].shape} -> {path}")

    # ---- 拷贝 merges.txt ----
    if os.path.isfile(args.merges):
        dst = os.path.join(args.outdir, "merges.txt")
        shutil.copy2(args.merges, dst)
        print(f"[save] merges.txt -> {dst}")
    else:
        print(f"[WARN] merges 未找到: {args.merges}")

    # ---- 校验 (读回对比) ----
    ok = True
    for name, fname in out_files.items():
        path = os.path.join(args.outdir, fname)
        back = np.fromfile(path, dtype=np.float32).reshape(weights[name].shape)
        if not np.array_equal(back, weights[name]):
            print(f"[ERROR] 校验失败: {fname}")
            ok = False
    print(f"[OK] 板端数据就绪: {args.outdir} (校验 {'通过' if ok else '失败'})")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
