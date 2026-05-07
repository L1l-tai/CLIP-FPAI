import os
import json
import typing
from collections import OrderedDict
from packaging.version import Version

# Compatibility for some torchvision builds on Python 3.7.
if not hasattr(typing, "OrderedDict"):
    typing.OrderedDict = OrderedDict

# Compatibility for old packaging versions used by legacy environments.
if not hasattr(Version, "major"):
    Version.major = property(lambda self: self.release[0] if self.release else 0)
if not hasattr(Version, "minor"):
    Version.minor = property(lambda self: self.release[1] if len(self.release) > 1 else 0)

from torchvision import transforms
import numpy as np
from PIL import Image
import onnxruntime as ort
from transformers import AutoProcessor
import requests
from torchvision import datasets
from torch.utils.data import DataLoader
from tqdm import tqdm

def main():
    # ==========================================
    # 1. 配置参数
    # ==========================================
    # 【请根据你的实际情况修改这些路径】
    val_dataset_path = "E:/Code/Dataset/imagenet/val"  # 例如: ./data/imagenet/val
    model_dir = "./"  # 包含 processor 配置的文件夹
    onnx_text_path = "./fmodel/text_model.onnx"
    onnx_vision_path = "fmodel\clip_vit_hadamard_optimized.onnx"

    # ImageNet 标签文件 (确保这个文件存在)
    label_file_path = "imagenet_classes.txt"

    # 评估参数
    batch_size = 1  # 根据你的内存调整，ONNX 推理通常较快
    num_workers = 4

    # ==========================================
    # 2. 加载 ImageNet 标签
    # ==========================================
    try:
        with open(label_file_path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f.readlines() if line.strip()]
        
        # --- 修改点：添加提示模板 ---
        # 原来的 texts 只是单词列表，现在变成句子列表
        texts = [f"a photo of a {line}" for line in lines]
        
        print(f" 成功加载 {len(texts)} 个类别标签")
        # 可以打印前几个看看效果
        # print("示例:", texts[:3])
    except FileNotFoundError:
        print(f" 标签文件 {label_file_path} 未找到")
        exit()
    # ==========================================
    # 3. 初始化模型和预处理器
    # ==========================================
    print("正在加载模型...")
    processor = AutoProcessor.from_pretrained(model_dir)

    # 根据环境动态选择可用 provider，避免无 CUDA 时产生告警中断。
    available_providers = ort.get_available_providers()
    if 'CUDAExecutionProvider' in available_providers:
        providers = ['CUDAExecutionProvider', 'CPUExecutionProvider']
    else:
        providers = ['CPUExecutionProvider']

    # --- 文本模型 (只计算一次) ---
    text_session = ort.InferenceSession(
        onnx_text_path,
        providers=providers
    )
    text_inputs = processor(text=texts, padding='max_length', max_length=77, truncation=True, return_tensors="np")
    for key in text_inputs.keys():
        text_inputs[key] = text_inputs[key].astype(np.int64)

    text_input_names = [input_.name for input_ in text_session.get_inputs()]
    text_ort_inputs = {name: text_inputs[name] for name in text_input_names}
    text_outputs = text_session.run(None, text_ort_inputs)
    text_embeds = text_outputs[0]  # [1000, D]
    text_embeds = text_embeds / np.linalg.norm(text_embeds, axis=1, keepdims=True)  # 归一化

    # --- 视觉模型 ---
    vision_session = ort.InferenceSession(
        onnx_vision_path,
        providers=providers
    )
    vision_input_names = [input_.name for input_ in vision_session.get_inputs()]

    print("模型加载完成")

    # ==========================================
    # 4. 加载 ImageNet 验证集
    # ==========================================
    print(f"正在加载 ImageNet 验证集: {val_dataset_path}")

    # 注意：这里使用 torchvision 的 ImageFolder，它会自动根据文件夹结构识别标签
    # ImageNet val 文件夹通常需要先处理成 subfolder 结构，或者使用 custom loader
    # 如果你的 val 文件夹是平铺的，你需要先运行一个脚本来整理，或者使用 meta 文件
    # 这里假设你的 val 文件夹已经整理好 (每个类别一个子文件夹)
    # --- 假设你的模型输入尺寸是 224x224 ---
    # 请根据你的实际情况修改 (例如 384)
    INPUT_SIZE = 224

    # 定义 Transform：先调整大小，再转为 Tensor
    # 注意：这里不需要做 Normalize，因为 processor 会处理
    transform = transforms.Compose([
        transforms.Resize((INPUT_SIZE, INPUT_SIZE)),  # 强制调整为统一尺寸
        transforms.ToTensor()
    ])

    dataset = datasets.ImageFolder(val_dataset_path, transform=transform)
    dataloader = DataLoader(dataset, batch_size=batch_size, shuffle=False, num_workers=num_workers)

    # ==========================================
    # 5. 评估循环
    # ==========================================
    print("开始评估...")

    # --- 用于计算 Top-1 和 Top-5 准确率 ---
    top1_correct = 0
    top5_correct = 0
    total_samples = 0

    # --- 推理循环 ---
    for batch_idx, (images, target) in enumerate(tqdm(dataloader)):
        batch_size_current = images.size(0)

        # --- A. 图像预处理 ---
        # 注意：dataloader 返回的是 Tensor，我们需要转为 PIL 或直接处理
        # 这里我们手动解归一化并转为 PIL 进行处理 (或者直接在 numpy 上处理)
        # 更高效的做法是直接在 Tensor 上做 transform，但为了兼容 processor，我们转为 PIL List
        pil_images = []
        for img_tensor in images:
            # 将 Tensor 转回 PIL Image
            # 注意：如果 processor 有特定的 mean/std，这里最好用 processor 处理
            img_np = img_tensor.permute(1, 2, 0).numpy()  # CHW -> HWC
            img_np = (img_np * 255).astype(np.uint8)
            pil_images.append(Image.fromarray(img_np))

        # 使用 processor 处理 batch
        image_inputs = processor(images=pil_images, return_tensors="np")
        for key in image_inputs.keys():
            image_inputs[key] = image_inputs[key].astype(np.float32)

        # --- B. 视觉模型推理 ---
        vision_ort_inputs = {name: image_inputs[name] for name in vision_input_names}
        image_outputs = vision_session.run(None, vision_ort_inputs)
        image_embeds_batch = image_outputs[0]  # [B, D]

        # --- C. 计算相似度 ---
        image_embeds_batch = image_embeds_batch / np.linalg.norm(image_embeds_batch, axis=1, keepdims=True)

        # 计算 logits: [B, 1000]
        logits = np.dot(image_embeds_batch, text_embeds.T) * 100

        # --- D. 计算 Top-1 和 Top-5 ---
        # target 是 ground truth label index
        for i in range(logits.shape[0]):
            pred = logits[i]
            gt = target[i].item()

            # Top-1
            if np.argmax(pred) == gt:
                top1_correct += 1

            # Top-5
            top5_pred = np.argsort(pred)[-5:]
            if gt in top5_pred:
                top5_correct += 1

        total_samples += batch_size_current

        # --- E. 实时打印 ---
        if (batch_idx + 1) % 500 == 0:
            top1_acc = top1_correct / total_samples * 100
            top5_acc = top5_correct / total_samples * 100
            tqdm.write(f"Batch {batch_idx + 1}: Top-1 Acc: {top1_acc:.2f}%, Top-5 Acc: {top5_acc:.2f}%")

    # ==========================================
    # 6. 最终结果
    # ==========================================
    final_top1 = top1_correct / total_samples * 100
    final_top5 = top5_correct / total_samples * 100

    print("\n" + "=" * 50)
    print("评估完成！")
    print(f"总样本数: {total_samples}")
    print(f"Zero-Shot Top-1 准确率: {final_top1:.2f}%")
    print(f"Zero-Shot Top-5 准确率: {final_top5:.2f}%")
    print("=" * 50)


if __name__ == '__main__':
    main()