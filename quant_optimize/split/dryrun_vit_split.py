#!/usr/bin/env python3
"""
dryrun_vit_split.py — host 端 dry-run：seg_pre + FWHT + seg_post 三段链路验证。

在 host 上把"硬件 FWHT 一跳"用软件模拟(蝶形 FWHT / golden FP16)替掉,
跑通 图像 -> seg_pre -> FWHT -> seg_post -> image_embeds 全链,
与整模型 fp32 输出比余弦,提前暴露切分/替换/排布逻辑错误。
(板上行为——Icraft 多输入运行时、seg_pre 双输出顺序、seg_post 四输入顺序——不在本脚本覆盖范围,
  由 clip_vit_hadamard_split.cpp 首跑核对。)

用法:
  python dryrun_vit_split.py                            # 默认路径 + 确定性随机输入
  python dryrun_vit_split.py --image test.jpg           # 指定测试图(OpenAI CLIP 预处理)
  python dryrun_vit_split.py --full <整模型.onnx>       # 指定含 H 注入的整模型(比余弦)
  python dryrun_vit_split.py --mode fp16                # FWHT 模拟精度: exact|fp16|both(默认 both)
  python dryrun_vit_split.py --save-bins <dir>          # 顺带导出 cpp 输入/参考/结果 bin

依赖: onnxruntime, numpy; --mode fp16 需 fwht_golden.py(队友 golden,路径可 --fwht-path)。
"""
import argparse, os, sys
import numpy as np
import onnxruntime as ort

# ---------------------------------------------------------------- 默认路径(相对本脚本,可在 Windows/WSL 下跑)
HERE = os.path.dirname(os.path.abspath(__file__))
FMODEL   = os.path.join(HERE, "..", "..", "fmodel", "vision", "split")
SEG_PRE  = os.path.join(FMODEL, "vit_seg_pre_fixed.onnx")                    # 项目 fmodel/vision/split/ 已有
SEG_POST = os.path.join(HERE, "..", "..", "fmodel", "vision", "split", "vit_seg_post_fixed.onnx")  # 项目 fmodel/vision/split/ 已有
FULL_GUESSES = [
    os.path.join(HERE, "..", "..", "fmodel", "vision", "vision_model_hadamard_gs64.onnx"),  # 项目 fmodel/vision/ 已有
    os.path.join(HERE, "models", "vision_model_hadamard_gs64.onnx"),
]

# ---------------------------------------------------------------- CLIP 预处理常量(OpenAI,与 gen_vit_board_io 一致)
MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)  # RGB
STD  = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)

# ---------------------------------------------------------------- 切点 tensor 名(与 KB 文档第六节一致)
NAME_RESID = "/vision_model/pre_layrnorm/Add_1_output_0"        # 残差旁路
NAME_LN1   = "/vision_model/encoder/layers.0/layer_norm1/Add_1_output_0"  # 共享 LN1 输出


# ================================================================ FWHT 蝶形(与 fwht_golden.fwht_64 / RTL 一致)
def fwht_64(x: np.ndarray) -> np.ndarray:
    """64 点蝶形 FWHT,stride 1,2,4,8,16,32,纯加减无归一化。输出 = H64_Kronecker @ x(实测一致)。"""
    n = len(x)
    r = np.asarray(x, dtype=np.float64).copy()
    step = 1
    while step < n:
        for i in range(0, n, step * 2):
            for j in range(step):
                a, b = r[i + j], r[i + j + step]
                r[i + j] = a + b
                r[i + j + step] = a - b
        step *= 2
    return r


def fwht_768(x: np.ndarray) -> np.ndarray:
    """对 [..., 768] 张量做 12 组 64 点 FWHT(局部旋转,与硬件块组织一致)。"""
    shape = x.shape
    v = x.reshape(-1, 768).astype(np.float64)
    out = np.empty_like(v)
    for r in range(v.shape[0]):
        for g in range(12):
            out[r, g*64:(g+1)*64] = fwht_64(v[r, g*64:(g+1)*64])
    return out.reshape(shape)


# ================================================================ 工具
def preprocess(img_path):
    """读图 -> 224x224 -> RGB -> /255 -> (x-mean)/std,返回 [224,224,3] HWC RGB FP32。"""
    import cv2
    img = cv2.imread(img_path)
    if img is None:
        raise FileNotFoundError(img_path)
    img = cv2.resize(img, (224, 224), interpolation=cv2.INTER_LINEAR)
    img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    x = img.astype(np.float32) / 255.0
    x = (x - MEAN) / STD
    return x.astype(np.float32)


def cos(a, b):
    a, b = np.asarray(a).ravel(), np.asarray(b).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


# ================================================================ 出图
def _setup_font():
    """尝试加载中文字体(Windows 微软雅黑);失败则回退英文。"""
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib import font_manager
    for p in (r"C:\Windows\Fonts\msyh.ttc", "/mnt/c/Windows/Fonts/msyh.ttc"):
        try:
            font_manager.fontManager.addfont(p)
            import matplotlib.pyplot as plt
            plt.rcParams["font.family"] = ["Microsoft YaHei", "sans-serif"]
            plt.rcParams["axes.unicode_minus"] = False
            return plt
        except Exception:
            continue
    import matplotlib.pyplot as plt
    plt.rcParams["axes.unicode_minus"] = False
    return plt


def plot_results(base, ln1_2d, res_2d, results, ref):
    """出两张图:
    1) {base}_embeds.png : image_embeds dry-run vs 整模型参考(散点 y=x + 误差直方图)
    2) {base}_fwht.png   : LN1 输入波形 vs FWHT 输出波形(token 0,展示离群点打散)
    """
    plt = _setup_font()
    import math

    # 优先用 exact 数据画主图, fp16 标注进统计
    emb = None; rot = None; tag = ""
    for m in ("exact", "fp16"):
        if m in results:
            emb = results[m][1]; rot = results[m][0]; tag = m
            break

    # ---------- 图 1: 端到端一致性 ----------
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13.5, 5.6),
                                   gridspec_kw={"width_ratios": [2.0, 1.0]})
    fig.suptitle("图像编码器三段链路 dry-run 验证（seg_pre + FWHT + seg_post）",
                 fontsize=15, fontweight="bold", y=0.98)
    if ref is not None:
        err = ref - emb
        max_err = np.abs(err).max()
        rmse = math.sqrt((err**2).mean())
        c = cos(ref, emb)
        rng = max(np.abs(ref).max(), np.abs(emb).max()) * 1.05
        # 散点 zorder 高于参考线:散点压线,参考线透底,一致性更直观
        ax1.scatter(ref, emb, s=30, alpha=0.65, c="#1f77b4", edgecolors="none",
                    label="image_embeds 各维 (N=512)", zorder=3)
        ax1.plot([-rng, rng], [-rng, rng], "--", color="red", lw=1.2, label="y = x", zorder=2)
        ax1.set_xlim(-rng, rng); ax1.set_ylim(-rng, rng)
        ax1.set_aspect("equal"); ax1.grid(alpha=0.25)
        ax1.set_xlabel("整模型 fp32 参考值"); ax1.set_ylabel("dry-run 输出值")
        ax1.set_title("image_embeds 散点一致性")
        ax1.legend(loc="lower right", fontsize=10)
        stats = (f"N = 512\n"
                 f"余弦相似度 = {c:.7f}\n"
                 f"max |err| = {max_err:.5f}\n"
                 f"RMSE = {rmse:.5f}")
        ax1.text(0.03, 0.97, stats, transform=ax1.transAxes, fontsize=11,
                 va="top", ha="left",
                 bbox=dict(boxstyle="round,pad=0.4", facecolor="white", edgecolor="#888", alpha=0.92))
        # 误差直方图
        bins = np.linspace(-max_err, max_err, 41)
        ax2.hist(err, bins=bins, color="#2ca02c", alpha=0.85, edgecolor="white", lw=0.3)
        ax2.axvline(0, color="red", lw=1.2, ls="--")
        ax2.set_xlabel("误差 (参考 − dry-run)"); ax2.set_ylabel("维度数")
        ax2.set_title("逐元素误差分布")
        ax2.grid(alpha=0.25)
    else:
        ax1.text(0.5, 0.5, "无整模型参考(--full), 仅统计特征", ha="center", va="center", transform=ax1.transAxes)
        ax2.axis("off")
    plt.tight_layout(rect=[0, 0, 1, 0.94])
    p1 = base + "_embeds.png"
    fig.savefig(p1, dpi=180, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"[plot] saved {p1}")

    # ---------- 图 2: FWHT 效果(输入 vs 输出波形) ----------
    n = 768
    x = np.arange(n)
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 4.2))
    fig.suptitle(f"FWHT 一跳效果（token 0，{tag} 模式，768 维 = 12 组 64 点局部旋转）",
                 fontsize=14, fontweight="bold", y=0.98)
    ax1.plot(x, ln1_2d[0], color="steelblue", lw=0.7)
    std = np.std(ln1_2d[0])
    mask = np.abs(ln1_2d[0]) > 5 * std
    if mask.any():
        ax1.scatter(x[mask], ln1_2d[0][mask], color="red", s=18, zorder=5, label="离群点 (>5σ)")
    for g in range(1, 12):
        ax1.axvline(g * 64, color="gray", lw=0.3, ls=":")
    ax1.set_title("LN1 输出（FWHT 输入）"); ax1.set_xlim(0, n - 1)
    ax1.legend(loc="upper right", fontsize=9); ax1.grid(alpha=0.25)
    ax1.set_xlabel("维度索引"); ax1.set_ylabel("激活值")
    ax2.plot(x, rot[0], color="seagreen", lw=0.7)
    for g in range(1, 12):
        ax2.axvline(g * 64, color="gray", lw=0.3, ls=":")
    ax2.set_title("FWHT 旋转输出（喂 seg_post q/k/v）"); ax2.set_xlim(0, n - 1)
    ax2.grid(alpha=0.25); ax2.set_xlabel("维度索引"); ax2.set_ylabel("激活值")
    plt.tight_layout(rect=[0, 0, 1, 0.93])
    p2 = base + "_fwht.png"
    fig.savefig(p2, dpi=180, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"[plot] saved {p2}")


# ================================================================ main
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pre", default=SEG_PRE, help="seg_pre fixed onnx")
    ap.add_argument("--post", default=SEG_POST, help="seg_post fixed onnx")
    ap.add_argument("--full", default=None, help="含 H 注入的整模型 onnx(比余弦;默认自动探测)")
    ap.add_argument("--image", default=None, help="测试图;不填用确定性随机输入")
    ap.add_argument("--mode", default="both", choices=["exact", "fp16", "both"],
                    help="FWHT 一跳的模拟精度(exact=蝶形float64, fp16=golden FP16)")
    ap.add_argument("--fwht-path", default=None, help="fwht_golden.py 所在目录(仅 fp16 模式需要)")
    ap.add_argument("--save-bins", default=None, help="导出 cpp 输入/参考/结果 bin 到该目录")
    ap.add_argument("--plot", default=None, help="出图: 端到端一致性 + FWHT 效果 PNG 路径(不含扩展名, 生成 _embeds.png 和 _fwht.png)")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    # ---- 整模型探测 ----
    full = args.full
    if full is None:
        for g in FULL_GUESSES:
            if os.path.exists(g):
                full = g
                break
    if full is None:
        print("[WARN] 未找到整模型(--full),跳过端到端余弦对比;只打印统计特征。")
    else:
        print(f"[full] {full}")

    # ---- 输入 ----
    if args.image:
        x_hwc = preprocess(args.image)
        print(f"[input] 图片 {args.image}")
    else:
        x_hwc = np.random.RandomState(args.seed).randn(224, 224, 3).astype(np.float32)
        print("[input] 确定性随机输入(纯数值通路检查)")
    x_chw = np.transpose(x_hwc, (2, 0, 1))[None].copy()          # [1,3,224,224]

    # ---- 三段会话 ----
    print(f"[load] seg_pre:  {args.pre}")
    pre = ort.InferenceSession(args.pre, providers=["CPUExecutionProvider"])
    print(f"[load] seg_post: {args.post}")
    post = ort.InferenceSession(args.post, providers=["CPUExecutionProvider"])

    in_pre = pre.get_inputs()[0].name
    out_names = [o.name for o in pre.get_outputs()]
    in_post = [i.name for i in post.get_inputs()]
    print(f"  seg_pre 输入: {in_pre}")
    print(f"  seg_pre 输出: {out_names}")
    print(f"  seg_post 输入: {in_post}")
    print(f"  seg_post 输出: {[o.name for o in post.get_outputs()]}")

    # ---- 参考:整模型 fp32 ----
    if full:
        fs = ort.InferenceSession(full, providers=["CPUExecutionProvider"])
        ref = fs.run(None, {fs.get_inputs()[0].name: x_chw})[0].ravel().astype(np.float32)
        print(f"[ref] 整模型 image_embeds[:5] = {np.round(ref[:5], 5)}")

    # ---- seg_pre -> 按名取 残差 / LN1 ----
    outs = pre.run(None, {in_pre: x_chw})
    out_map = dict(zip(out_names, outs))
    res = np.asarray(out_map[NAME_RESID], np.float32)            # [1,50,768]
    ln1 = np.asarray(out_map[NAME_LN1], np.float32)              # [1,50,768]
    print(f"[seg_pre] 残差 shape={res.shape}  LN1 shape={ln1.shape}")
    print(f"  LN1 统计: mean={ln1.mean():.5f} std={ln1.std():.5f} "
          f"min={ln1.min():.3f} max={ln1.max():.3f}  (应近似零均值单位方差)")
    print(f"  残差统计: mean={res.mean():.5f} std={res.std():.5f}")

    # ---- FWHT 一跳(按 mode) ----
    ln1_2d = ln1[0]                                             # [50,768]
    rot = None
    results = {}                                                # mode -> (rot, emb)
    for mode in (["exact", "fp16"] if args.mode == "both" else [args.mode]):
        if mode == "exact":
            rot_exact = fwht_768(ln1_2d).astype(np.float32)
            feed = {in_post[0]: res, in_post[1]: rot_exact[None], in_post[2]: rot_exact[None], in_post[3]: rot_exact[None]}
            emb = post.run(None, feed)[0].ravel().astype(np.float32)
            tag = "exact 蝶形 FWHT"
        else:
            try:
                sys.path.insert(0, args.fwht_path or os.path.join(
                    os.path.dirname(HERE), "..", "clip-vit-base-patch32-zg", "test", "soft-verification"))
                from fwht_golden import fwht_768x30_fp16, float_to_fp16, fp16_to_float
            except ImportError:
                print("[skip] fp16 模式缺 fwht_golden.py(--fwht-path 指定目录)")
                continue
            flat = [float_to_fp16(float(t)) for t in ln1_2d.reshape(-1)]
            g = fwht_768x30_fp16(flat, vec_dim=768, num_vectors=ln1_2d.shape[0])
            rot_fp16 = np.array([fp16_to_float(t) for t in g], np.float32).reshape(ln1_2d.shape)
            feed = {in_post[0]: res, in_post[1]: rot_fp16[None], in_post[2]: rot_fp16[None], in_post[3]: rot_fp16[None]}
            emb = post.run(None, feed)[0].ravel().astype(np.float32)
            tag = "golden FP16 FWHT"

        results[mode] = (rot_exact if mode == "exact" else rot_fp16, emb)
        print(f"\n[{tag}] image_embeds[:5] = {np.round(emb[:5], 5)}")
        if full:
            print(f"[{tag}] cos vs 整模型 = {cos(ref, emb):.10f}  "
                  f"max|diff| = {np.max(np.abs(ref - emb)):.2e}")
        else:
            print(f"[{tag}] 无整模型参考,仅检查有限性: "
                  f"finite={np.isfinite(emb).all()},  norm={np.linalg.norm(emb):.4f}")
        if rot is None:
            rot = rot_exact if mode == "exact" else rot_fp16

    # ---- 可选:出图 ----
    if args.plot:
        try:
            # 先存中间数据,方便以后只重画不重推理
            np.savez(args.plot + "_data.npz",
                     ln1=ln1_2d, res=res[0],
                     emb_exact=results.get("exact", (None, None))[1],
                     rot_exact=results.get("exact", (None, None))[0],
                     emb_fp16=results.get("fp16", (None, None))[1],
                     rot_fp16=results.get("fp16", (None, None))[0],
                     ref=ref if full else None)
            plot_results(args.plot, ln1_2d, res[0], results, ref if full else None)
        except Exception as e:
            print(f"[plot] 失败: {e}")

    # ---- 可选:导出 bin(与 cpp / 板上比对) ----
    if args.save_bins:
        os.makedirs(args.save_bins, exist_ok=True)
        x_hwc.tofile(os.path.join(args.save_bins, "vit_pre_in.bin"))          # HWC RGB FP32
        emb.tofile(os.path.join(args.save_bins, "vit_split_embeds.bin"))      # 512 FP32
        if full:
            ref.tofile(os.path.join(args.save_bins, "vit_ref_embeds.bin"))    # 整模型参考
        print(f"[save] bins -> {args.save_bins}")


if __name__ == "__main__":
    main()
