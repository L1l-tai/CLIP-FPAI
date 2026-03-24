import sys
import os
import yaml
import cv2
import numpy as np
from tqdm import tqdm
from PIL import Image
import torchvision.transforms as transforms

# 1. 导入 icraft 相关库 (请确保路径与你的目录结构一致)
sys.path.append(R"F:\CICC2026\clip-vit-base-patch32-zg\deploy\Deps\modelzoo") 
import icraft
from icraft.xir import *
from icraft.xrt import *
from pyrtutils.icraft_utils import *
from pyrtutils.Netinfo import Netinfo

def l2_norm(vec):
    """对特征向量进行 L2 归一化，这是 CLIP 比较的标准动作"""
    norm = np.linalg.norm(vec)
    return vec / (norm + 1e-6)

if __name__ == "__main__":
    # --- 配置加载 ---
    if len(sys.argv) < 2:
        print("Usage: python icraft_launcher.py clip_inference.py <your_yaml_path>")
        sys.exit(1)
        
    yaml_path = sys.argv[1]
    cfg = yaml.safe_load(open(yaml_path, "r", encoding="utf-8"))
    
    # 路径解析
    model_dir = cfg["imodel"]["dir"]
    stage = cfg["imodel"]["stage"]
    run_backend = cfg["imodel"].get("runbackend", "host") # 默认 host 仿真
    ip = cfg["imodel"].get("ip", "192.168.125.166")
    
    img_root = os.path.abspath(cfg["dataset"]["dir"])
    img_list_path = os.path.abspath(cfg["dataset"]["list"])
    res_root = os.path.abspath(cfg["dataset"]["res"])
    
    if not os.path.exists(res_root):
        os.makedirs(res_root)

    # --- CLIP 标准预处理 (ViT-B/32) ---
    # 注意：如果你的 TOML 里已经写了 pre_mean/scale，这里只需要 Resize 和 Crop
    transform = transforms.Compose([
        transforms.Resize(224, interpolation=transforms.InterpolationMode.BICUBIC),
        transforms.CenterCrop(224),
        transforms.ToTensor(),
        transforms.Normalize(mean=(0.48145466, 0.4578275, 0.40821073), 
                             std=(0.26862954, 0.26130258, 0.27577711))
    ])

    # --- 初始化 icraft 会话 ---
    json_path, raw_path = getJrPath(model_dir, stage, run_backend)
    network = loadNetwork(json_path, raw_path)
    netinfo = Netinfo(network)
    
    # 仿真模式下 run_backend 为 'host'
    device = openDevice(run_backend, ip, netinfo.mmu, False)
    session = initSession(run_backend, network, device, 4, netinfo.mmu, False, False)
    session.apply()

    print(f"\n🚀 开始执行 CLIP 视觉特征提取 | 后端: {run_backend}")

    # --- 循环推理 ---
    for line in tqdm(open(img_list_path, "r")):
        img_name = line.strip()
        if not img_name: continue
        
        img_path = os.path.join(img_root, img_name)
        
        # 1. 预处理
        image = Image.open(img_path).convert('RGB')
        img_tensor = transform(image).numpy()
        img_tensor = np.expand_dims(img_tensor, 0) # 扩充为 [1, 3, 224, 224]
        
        # 针对诸葛架构，通常需要 NCHW 转 NHWC，numpy2Tensor 会自动处理
        input_tensor = numpy2Tensor(img_tensor, network)
        
        # 2. NPU 执行
        output_tensors = session.forward([input_tensor])
        
        # 3. 后处理：提取特征
        # output_tensors[0] 的形状应该是 [1, 768]
        feat = np.array(output_tensors[0]).astype(np.float32).flatten()
        
        # 必须做 L2 归一化，否则计算余弦相似度会不准
        feat_normalized = l2_norm(feat)
        
        # 4. 保存结果
        feat_file = os.path.join(res_root, img_name.split('.')[0] + ".npy")
        np.save(feat_file, feat_normalized)

    print(f"\n✅ 特征提取完成！结果保存在: {res_root}")
    
    if run_backend != "host":
        xrt.Device.Close(device)