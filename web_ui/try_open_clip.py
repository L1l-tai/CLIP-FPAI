import torch
from PIL import Image
import open_clip
 
# 加载模型与预处理工具
model, preprocess, _ = open_clip.create_model_and_transforms(
    model_name="ViT-B-32",
    pretrained="./download/ViT-B-32-laion2b-s34b-b79k/open_clip_pytorch_model.bin"  # 预训练权重标识
)
tokenizer = open_clip.get_tokenizer("ViT-B-32")
 
# 图像预处理
image = preprocess(Image.open("download/test_images/example3.jpg")).unsqueeze(0)
# 文本预处理
text = tokenizer(["a photo of a cat", "a photo of a dog","a photo of a Alpaca","a photo of a sheep"])
 
# 推理
with torch.no_grad():
    image_features = model.encode_image(image)
    text_features = model.encode_text(text)
    
    # 计算相似度
    image_features /= image_features.norm(dim=-1, keepdim=True)
    text_features /= text_features.norm(dim=-1, keepdim=True)
    similarity = (100.0 * image_features @ text_features.T).softmax(dim=-1)
 
print(f"类别概率: {similarity[0].tolist()}")