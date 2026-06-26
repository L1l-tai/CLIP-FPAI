import argparse
import torch
import open_clip
import cv2
import numpy as np
from pathlib import Path
from PIL import Image
import time
from scipy.special import softmax

def get_args():
    p = argparse.ArgumentParser()
    # 移除了 dataset, shots, alpha, beta 等与摄像头实时识别无关的参数
    p.add_argument('--model', type=str, default='ViT-B-32')
    p.add_argument('--pretrained', type=str, default='ViT-B-32-laion2b-s34b-b79k/open_clip_pytorch_model.bin')
    p.add_argument('--batch-size', type=int, default=1)  # 实时识别通常 batch_size=1
    p.add_argument('--num-workers', type=int, default=0)  # 摄像头不需要多进程
    p.add_argument('--cuda', type=int, default=0)
    p.add_argument('--label-file', type=str, default='imagenet_classes.txt', help='类别标签文件路径')
    p.add_argument('--camera-id', type=int, default=0, help='摄像头设备ID')
    return p.parse_args()


def load_class_names(label_file):
    """加载类别名称"""
    try:
        with open(label_file, "r", encoding="utf-8") as f:
            texts = [line.strip() for line in f.readlines() if line.strip()]
        print(f" 成功加载 {len(texts)} 个类别标签")
        return texts
    except FileNotFoundError:
        print(f" 标签文件 {label_file} 未找到")
        return ["unknown"]


@torch.no_grad()  # 装饰器，减少显存消耗
def main():
    args = get_args()

    # --- 1. 设置设备 ---
    device = f'cuda:{args.cuda}' if torch.cuda.is_available() and args.cuda >= 0 else 'cpu'
    torch.cuda.set_device(device)
    print(f"🚀 使用设备: {device}")

    # --- 2. 加载模型和预处理器 ---
    print("🚀 正在加载 CLIP 模型...")
    model, _, preprocess = open_clip.create_model_and_transforms(
        args.model, pretrained=args.pretrained, device=device)
    model.eval()
    tokenizer = open_clip.get_tokenizer(args.model)

    # --- 3. 加载文本特征 (只计算一次) ---
    print("🚀 正在计算文本特征...")
    class_names = load_class_names(args.label_file)
    text_tokens = tokenizer(class_names).to(device)  # [N, 77]

    # 将文本送入模型编码
    text_embeddings = model.encode_text(text_tokens)  # [N, D]
    text_embeddings = text_embeddings / text_embeddings.norm(dim=-1, keepdim=True)  # 归一化
    text_embeddings = text_embeddings.cpu().numpy()  # 转为 numpy，方便后续计算 (也可以留在 GPU 上)

    print("模型和特征加载完成，启动摄像头...")

    # --- 4. 初始化摄像头 ---
    cap = cv2.VideoCapture(args.camera_id)
    if not cap.isOpened():
        print(f" 无法打开摄像头 {args.camera_id}")
        exit()

    # --- 5. 主循环：实时推理 ---
    print("📸 开始实时识别 (按 'q' 键退出)")
    try:
        while True:
            start_time = time.time()

            # --- A. 读取帧 ---
            ret, frame = cap.read()
            if not ret:
                print(" 无法读取摄像头画面")
                break

            # --- B. 图像预处理 (使用 open_clip 的 preprocess) ---
            # 注意：preprocess 返回的是 Tensor，我们需要先转回 PIL Image 或者手动处理
            # 这里我们直接在 Tensor 上操作以保持一致性
            image_pil = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            image_tensor = preprocess(image_pil).unsqueeze(0).to(device)  # [1, 3, H, W]

            # --- C. 视觉模型推理 ---
            image_embeddings = model.encode_image(image_tensor)  # [1, D]
            image_embeddings = image_embeddings / image_embeddings.norm(dim=-1, keepdim=True)

            # --- D. 计算相似度 ---
            # 将 image_embeddings 转回 CPU 进行 numpy 运算 (或者全程在 torch 上做)
            image_emb_np = image_embeddings.cpu().numpy()
            similarity = np.dot(image_emb_np, text_embeddings.T) * 100  # 乘以 100 是 CLIP 常见的温度系数
            probabilities = softmax(similarity[0])  # 转为概率

            # --- E. 获取 Top-5 结果 ---
            top5_indices = np.argsort(probabilities)[-5:][::-1]

            # --- F. 可视化 ---
            # 绘制 Top-5 结果
            for i, idx in enumerate(top5_indices):
                label = class_names[idx]
                prob = probabilities[idx] * 100
                text_str = f"{i + 1}. {label}: {prob:.2f}%"
                cv2.putText(frame, text_str, (10, 30 + i * 30),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)

            # 绘制 FPS
            fps = 1 / (time.time() - start_time)
            cv2.putText(frame, f"FPS: {fps:.2f}", (10, 240),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)

            # 显示图像
            cv2.imshow('MobileCLIP Real-time', frame)

            if cv2.waitKey(1) & 0xFF == ord('q'):
                break

    except KeyboardInterrupt:
        pass
    finally:
        cap.release()
        cv2.destroyAllWindows()


if __name__ == '__main__':
    main()