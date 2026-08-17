import onnx
from onnx import helper, TensorProto
import numpy as np
import onnxruntime as ort

FMDIR = r"F:\CICC2026\clip-vit-base-patch32-zg\fmodel"
SRC   = FMDIR + r"\vit_seg_pre_fixed.onnx"
DST   = FMDIR + r"\vit_seg_pre_nhwc.onnx"

OLD_IN = "pixel_values"
NEW_IN = "pixel_values_nhwc"

# ---------- 1. 加输入 Transpose:NHWC -> NCHW ----------
m = onnx.load(SRC)
g = m.graph

old_vi = next((vi for vi in g.input if vi.name == OLD_IN), None)
assert old_vi is not None, "找不到 pixel_values 输入"

nhwc_vi = helper.make_tensor_value_info(NEW_IN, TensorProto.FLOAT, [1, 224, 224, 3])
transpose = helper.make_node(
    "Transpose", inputs=[NEW_IN], outputs=[OLD_IN],
    perm=[0, 3, 1, 2], name="input_nhwc_to_nchw",
)
g.input.remove(old_vi)
g.input.insert(0, nhwc_vi)
g.node.insert(0, transpose)
onnx.save(m, DST)
print("saved", DST)

# ---------- 2. 复核输入输出 ----------
s_nhwc  = ort.InferenceSession(DST, providers=["CPUExecutionProvider"])
s_fixed = ort.InferenceSession(SRC, providers=["CPUExecutionProvider"])
print("nhwc 版输入:", [(i.name, i.shape) for i in s_nhwc.get_inputs()])
print("nhwc 版输出:", [(o.name, o.shape) for o in s_nhwc.get_outputs()])

# ---------- 3. 数值一致性:同一份数据,两版应输出相同 ----------
np.random.seed(0)
x_nhwc = np.random.randn(1, 224, 224, 3).astype(np.float32)   # NHWC
x_nchw = np.transpose(x_nhwc, (0, 3, 1, 2)).copy()            # 对应 NCHW

out_nhwc  = s_nhwc.run(None,  {NEW_IN: x_nhwc})
out_fixed = s_fixed.run(None, {OLD_IN: x_nchw})

def cos(a, b):
    a, b = a.ravel(), b.ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))

print("\n数值一致性(nhwc 喂NHWC vs fixed 喂对应NCHW):")
for i, name in enumerate([o.name.split('/')[-1] for o in s_nhwc.get_outputs()]):
    c = cos(out_nhwc[i], out_fixed[i])
    d = float(np.max(np.abs(out_nhwc[i] - out_fixed[i])))
    print(f"  输出{i} {name}: cos={c:.10f}  max|diff|={d:.2e}")