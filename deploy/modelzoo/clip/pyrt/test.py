import numpy as np

# 替换成你生成的那个文件名
feat_path = r"F:\CICC2026\clip-vit-base-patch32-zg\deploy\modelzoo\clip\io\output_features\000000000139.npy" 
data = np.load(feat_path)

print("--- 特征向量检查 ---")
print(f"数据维度: {data.shape}")  # 预期应该是 (768,) 或 (1, 768)
print(f"前 5 个数值: {data.flatten()[:5]}") 
print(f"向量 L2 范数: {np.linalg.norm(data):.4f}") # 如果是 1.0 左右，说明归一化成功了