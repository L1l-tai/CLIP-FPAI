import argparse, os, pathlib
import torch
import torch.nn.functional as F
import open_clip
from torch.utils.data import DataLoader
from torchvision.datasets import ImageFolder
from tqdm import tqdm

os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"

@torch.no_grad()
def eval_fn(model, preprocess, args):
    device = torch.device(args.device)
    
    # 3.1 类别 & 模板（lambda -> 字符串）
    classnames = open_clip.IMAGENET_CLASSNAMES
    templates  = [t('{}') for t in open_clip.ONE_IMAGENET_TEMPLATES]  # ✅ 实例化
    print(f"Using {len(classnames)} classes × {len(templates)} templates")
    
    # 3.2 文本特征（官方温度 + 先加和再归一化）
    logit_scale = model.logit_scale.exp().item()                         # ✅ 官方温度
    text_features_list = []
    for i in tqdm(range(0, len(classnames), 100), desc="Text encoding"):
        batch_cls = classnames[i:i+100]
        texts = [t.format(c) for c in batch_cls for t in templates]
        text_tokens = open_clip.tokenize(texts).to(device)
        text_feats = model.encode_text(text_tokens)
        text_feats = text_feats.view(len(batch_cls), len(templates), -1).sum(1)
        text_feats = F.normalize(text_feats, dim=-1) * logit_scale       # ✅ 先归一再放大
        text_features_list.append(text_feats.cpu())
        del text_tokens, text_feats
        torch.cuda.empty_cache()
    
    all_text_features = torch.cat(text_features_list, dim=0).to(device)  # [1000, dim]
    del text_features_list
    torch.cuda.empty_cache()
    
    # 3.3 数据加载
    dataset = ImageFolder(args.root, transform=preprocess)
    loader  = DataLoader(dataset, batch_size=args.batch_size, num_workers=args.num_workers,
                         pin_memory=True, shuffle=False, drop_last=False)
    
    # 3.4 推理循环
    top1, top5, n = 0, 0, 0
    pbar = tqdm(loader, ncols=100, unit='batch')
    for imgs, lbls in pbar:
        imgs, lbls = imgs.to(device, non_blocking=True), lbls.to(device, non_blocking=True)
        
        image_features = model.encode_image(imgs)
        image_features = F.normalize(image_features, dim=-1)
        logits = image_features @ all_text_features.T                    # [B, 1000]
        
        acc1 = (logits.argmax(1) == lbls).sum().item()
        acc5 = (logits.topk(5, dim=1)[1] == lbls.view(-1,1)).any(1).sum().item()
        top1 += acc1; top5 += acc5; n += lbls.size(0)
        pbar.set_postfix({'Top-1': f'{top1/n*100:.2f}%', 'Top-5': f'{top5/n*100:.2f}%'})
        
        del imgs, lbls, image_features, logits
        torch.cuda.empty_cache()
    top1 = top1/n*100
    top5 = top5/n*100
    print(f'\n{args.method}  {args.model}  Top-1 = {top1:.2f}%  Top-5 = {top5:.2f}%')
    return top1/n*100, top5/n*100