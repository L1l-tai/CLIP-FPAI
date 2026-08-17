"""
生成板上 cpp(clip_vit_hadamard_split)所需的两个 bin,并顺带验证 fixed 版一致性。

产物(存到 board_data/,与 toml 的 [run] 路径一致):
  vit_pre_in.bin      : [224,224,3] FP32,HWC,RGB,已归一化 —— 板上 cpp 的输入
  vit_ref_embeds.bin  : [512] FP32,整模型输出 —— 板上比余弦的参考(ground truth)

用法:
  python gen_vit_board_io.py [测试图路径]
  不给图 -> 用确定性随机输入,做纯数值 board==host 通路检查(无语义)

依赖:onnxruntime, numpy, opencv(cv2);可选 fwht_golden.py(做 fixed 版一致性验证)
"""
import os, sys
import numpy as np
import onnxruntime as ort

# ------------------------------------------------------------------ 路径
import os as _os
HERE = _os.path.dirname(_os.path.abspath(__file__))
FMDIR = _os.path.join(HERE, "models")   # 大模型自行放入 models/
BOARD = "/mnt/d/icraft-docker/Ubuntu20.04/clip-hhx-new/addition/board_data"
FULL      = FMDIR + "/vision_model_hadamard_gs64.onnx"
SEG_PRE   = FMDIR + "/vit_seg_pre_fixed.onnx"
SEG_POST  = "/mnt/d/icraft-docker/Ubuntu20.04/clip-hhx-new/vit_seg_post_fixed.onnx"

# ------------------------------------------------------------------ CLIP 预处理常量(OpenAI)
MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)  # RGB
STD  = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)

def preprocess(img_path):
    """读图 -> 224x224 -> RGB -> /255 -> (x-mean)/std,返回 HWC RGB FP32 [224,224,3]。
       简化版直接缩到 224;若要严格复刻板上 resize 通路(640x480->crop480->224),
       把这里换成 board-style 即可(与 gen_board_baseline.py 一致)。"""
    import cv2
    img = cv2.imread(img_path)                                # BGR HWC uint8
    if img is None:
        raise FileNotFoundError(img_path)
    img = cv2.resize(img, (224, 224), interpolation=cv2.INTER_LINEAR)
    img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    x = img.astype(np.float32) / 255.0
    x = (x - MEAN) / STD
    return x.astype(np.float32)                               # [224,224,3] HWC RGB

def cos(a, b):
    a, b = a.ravel(), b.ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))

# ================================================================== 主流程
img_path = sys.argv[1] if len(sys.argv) > 1 else None
if img_path:
    x_hwc = preprocess(img_path)
    print(f"预处理图片: {img_path}")
else:
    print("未提供图片,用确定性随机输入(纯数值通路检查,无语义)")
    x_hwc = np.random.RandomState(0).randn(224, 224, 3).astype(np.float32)

os.makedirs(BOARD, exist_ok=True)

# ---- 1) 板上 cpp 输入:HWC RGB FP32 ----
x_hwc.tofile(os.path.join(BOARD, "vit_pre_in.bin"))
print("saved vit_pre_in.bin   ", x_hwc.shape, "HWC RGB FP32")

# ---- 2) 参考:整模型 fp32 输出(输入转 CHW 喂 onnx)----
x_chw = np.transpose(x_hwc, (2, 0, 1))[None].copy()          # [1,3,224,224]
full = ort.InferenceSession(FULL, providers=["CPUExecutionProvider"])
ref = full.run(None, {"pixel_values": x_chw})[0].ravel().astype(np.float32)
ref.tofile(os.path.join(BOARD, "vit_ref_embeds.bin"))
print("saved vit_ref_embeds.bin", ref.shape, " ref[:5] =", np.round(ref[:5], 5))

# ================================================================== 3) 顺带:fixed 版切分一致性
# 用 fixed 版 seg_pre/seg_post + golden FWHT 复跑同一输入,对整模型比余弦。
# 精确 float 旋转应 ~1.0(证明 fixed 版没被 shape 固定改坏);
# golden FP16 旋转 ~1.0(FWHT 那跳精度预览,注意:这不含 bf16,不预测板上)。
def _h64():
    H = np.array([[1]], dtype=np.float32)
    for _ in range(6): H = np.block([[H, H], [H, -H]])
    return H
def _bd(mats):
    n = sum(m.shape[0] for m in mats); out = np.zeros((n, n), np.float32); i = 0
    for m in mats:
        s = m.shape[0]; out[i:i+s, i:i+s] = m; i += s
    return out
H = _bd([_h64()] * 12)

try:
    pre  = ort.InferenceSession(SEG_PRE,  providers=["CPUExecutionProvider"])
    post = ort.InferenceSession(SEG_POST, providers=["CPUExecutionProvider"])
    in_pre  = pre.get_inputs()[0].name
    in_post = [i.name for i in post.get_inputs()]              # [残差, q, k, v]

    res, ln1 = pre.run(None, {in_pre: x_chw})

    # 精确 float 旋转
    rot_exact = (ln1.reshape(-1, 768) @ H).reshape(ln1.shape).astype(np.float32)
    feed = {in_post[0]: res, in_post[1]: rot_exact, in_post[2]: rot_exact, in_post[3]: rot_exact}
    emb_exact = post.run(None, feed)[0].ravel()
    print(f"\n[fixed 版一致性] 精确旋转 vs 整模型: cos={cos(ref, emb_exact):.10f}  max|d|={np.max(np.abs(ref-emb_exact)):.2e}")

    # golden FP16 旋转(可选)
    try:
        from fwht_golden import fwht_768x30_fp16, float_to_fp16, fp16_to_float
        v = ln1.reshape(-1, 768)
        flat = [float_to_fp16(float(t)) for t in v.reshape(-1)]
        g = fwht_768x30_fp16(flat, vec_dim=768, num_vectors=v.shape[0])
        rot_g = np.array([fp16_to_float(t) for t in g], np.float32).reshape(ln1.shape)
        feed = {in_post[0]: res, in_post[1]: rot_g, in_post[2]: rot_g, in_post[3]: rot_g}
        emb_g = post.run(None, feed)[0].ravel()
        print(f"[fixed 版一致性] golden FP16 旋转 vs 整模型: cos={cos(ref, emb_g):.10f}  max|d|={np.max(np.abs(ref-emb_g)):.2e}")
    except ImportError:
        print("[fixed 版一致性] golden 跳过(缺 fwht_golden.py)")
except Exception as e:
    print("\n[fixed 版一致性] 跳过:", e)
