import numpy as np


def l2_normalize(x: np.ndarray, eps: float = 1e-12) -> np.ndarray:
    norm = np.linalg.norm(x, axis=-1, keepdims=True)
    norm = np.maximum(norm, eps)
    return x / norm


if __name__ == "__main__":
    onnx_path = r"F:\CICC2026\test_text\deploy\pyrt\npy_out\image_onnx_feat.npy"
    zg_path = r"F:\CICC2026\test_text\deploy\pyrt\npy_out\clip_img_feat.npy"

    onnx_feat = np.load(onnx_path)
    zg_feat = np.load(zg_path)

    print("onnx_feat shape =", onnx_feat.shape)
    print("zg_feat shape   =", zg_feat.shape)

    if onnx_feat.ndim == 1:
        onnx_feat = np.expand_dims(onnx_feat, axis=0)
    if zg_feat.ndim == 1:
        zg_feat = np.expand_dims(zg_feat, axis=0)

    if onnx_feat.shape != zg_feat.shape:
        raise ValueError(f"Shape mismatch: {onnx_feat.shape} vs {zg_feat.shape}")

    onnx_feat_norm = l2_normalize(onnx_feat)
    zg_feat_norm = l2_normalize(zg_feat)

    cos_sim = np.sum(onnx_feat_norm * zg_feat_norm, axis=-1)
    mse = np.mean((onnx_feat - zg_feat) ** 2)
    max_abs_err = np.max(np.abs(onnx_feat - zg_feat))

    print("\nResults:")
    print("cosine similarity =", cos_sim)
    if cos_sim.size == 1:
        print("cosine similarity (scalar) =", float(cos_sim[0]))
    print("MSE =", float(mse))
    print("max abs error =", float(max_abs_err))