from transformers import AutoModel, AutoProcessor, BitsAndBytesConfig
import torch

# ==========================================
# 1. 配置 8-bit 量化
# ==========================================
quantization_config = BitsAndBytesConfig(
    load_in_8bit=True, # 启用 8-bit 量化
    # 可选：如果你的 CPU 内存也不足，可以启用 CPU 卸载
    # llm_int8_enable_fp32_cpu_offload=True
)

# ==========================================
# 2. 加载模型和处理器
# ==========================================
model_name = "ViT-B-32-laion2b-s34b-b79k/open_clip_pytorch_model.bin" # 例如 openai/clip-vit-base-patch32 或你本地的路径

# --- 文本模型 ---
print("🚀 正在加载文本模型 (8-bit)...")
text_model = AutoModel.from_pretrained(
    model_name,
    subfolder="text_model", # 如果模型文件夹结构中有子文件夹
    quantization_config=quantization_config,
    device_map="auto" # 自动分配到可用的 GPU/CPU
)

# --- 视觉模型 ---
print("🚀 正在加载视觉模型 (8-bit)...")
vision_model = AutoModel.from_pretrained(
    model_name,
    subfolder="vision_model",
    quantization_config=quantization_config,
    device_map="auto"
)

# --- 处理器 ---
processor = AutoProcessor.from_pretrained(model_name)

print("✅ 模型加载完成，已应用 8-bit 量化")