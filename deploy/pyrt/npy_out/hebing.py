import os
import numpy as np


def l2_normalize(x: np.ndarray, eps: float = 1e-12) -> np.ndarray:
    norm = np.linalg.norm(x, axis=-1, keepdims=True)
    norm = np.maximum(norm, eps)
    return x / norm


base_dir = os.path.dirname(os.path.abspath(__file__))

print("script dir =", base_dir)
print("files in dir =", os.listdir(base_dir))

# 1. 读取图像特征
img_feat = np.load(os.path.join(base_dir, "clip_img_feat.npy"))   # shape: [1, 512]

# 2. 读取文本特征
dog_feat = np.load(os.path.join(base_dir, "text_dog.npy"))     # shape: [1, 512]
cat_feat = np.load(os.path.join(base_dir, "text_cat.npy"))        # shape: [1, 512]
bear_feat = np.load(os.path.join(base_dir, "text_bear.npy"))             # shape: [1, 512]

# 3. 拼成一个 text feature 矩阵
text_feats = np.concatenate(
    [dog_feat, cat_feat, bear_feat],
    axis=0
)   # shape: [3, 512]

labels = ["dog", "cat", "bear"]

# 4. L2 归一化
img_feat = l2_normalize(img_feat)
text_feats = l2_normalize(text_feats)

# 5. 计算相似度
sim = img_feat @ text_feats.T
sim = sim[0]

print("Similarity scores:")
for label, score in zip(labels, sim):
    print(f"{label:12s}: {score:.6f}")

# 6. 排序
sorted_idx = np.argsort(-sim)

print("\nRanking:")
for rank, idx in enumerate(sorted_idx, start=1):
    print(f"Top {rank}: {labels[idx]}  score={sim[idx]:.6f}")